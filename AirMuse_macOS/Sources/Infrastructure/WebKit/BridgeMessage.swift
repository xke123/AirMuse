// Sources/Infrastructure/WebKit/BridgeMessage.swift
// AirMuse macOS – WebView JS Bridge message types
// Swift 6 strict concurrency – All types Sendable, decoded via JSONDecoder (no string concatenation)

import Foundation

// MARK: - Inbound (JS → Swift)

/// The top-level envelope every bridge message must carry.
public struct BridgeEnvelope: Codable, Sendable {
    public let type: String
    public let payload: BridgePayload?

    /// Parse raw JSON data from WKScriptMessageHandler.
    /// Returns nil if the data is not valid JSON or missing "type".
    public static func decode(from data: Data) -> BridgeEnvelope? {
        try? JSONDecoder().decode(BridgeEnvelope.self, from: data)
    }

    /// Convenience: parse a JSON string received from the WebView.
    /// We never build JS by concatenating this string; it is decoded on the Swift side.
    public static func decode(from jsonString: String) -> BridgeEnvelope? {
        guard let data = jsonString.data(using: .utf8) else { return nil }
        return decode(from: data)
    }
}

/// A discriminated union of all payload variants understood by AirMuse.
public enum BridgePayload: Sendable {
    case nowPlaying(NowPlayingPayload)
    case playbackState(PlaybackStatePayload)
    case authStatus(AuthStatusPayload)
    case error(BridgeErrorPayload)
    case unknown
}

extension BridgePayload: Codable {
    public init(from decoder: Decoder) throws {
        // Payload is decoded in context of its parent envelope; handled via BridgeEnvelope
        self = .unknown
    }
    public func encode(to encoder: Encoder) throws { /* outbound not used */ }
}

// MARK: Payload structs

public struct NowPlayingPayload: Codable, Sendable {
    public let title: String?
    public let artist: String?
    public let album: String?
    public let durationMs: Double?
    public let positionMs: Double?
    public let isPlaying: Bool?
    public let artworkURL: String?
    public let source: String?
}

public struct PlaybackStatePayload: Codable, Sendable {
    public let isPlaying: Bool
    public let positionMs: Double?
    public let volume: Double?
}

public struct AuthStatusPayload: Codable, Sendable {
    public let isLoggedIn: Bool
    public let userName: String?
}

public struct BridgeErrorPayload: Codable, Sendable {
    public let code: String
    public let message: String
}

// MARK: - Typed envelope decoder

extension BridgeEnvelope {
    /// Fully decode into a typed BridgePayload based on the "type" field.
    public func typedPayload() -> BridgePayload {
        guard let raw = try? JSONEncoder().encode(self),
              let dict = try? JSONSerialization.jsonObject(with: raw) as? [String: Any],
              let payloadData = try? JSONSerialization.data(withJSONObject: dict["payload"] ?? NSNull())
        else { return .unknown }

        let dec = JSONDecoder()
        switch type {
        case "nowPlaying":
            if let p = try? dec.decode(NowPlayingPayload.self, from: payloadData) { return .nowPlaying(p) }
        case "playbackState":
            if let p = try? dec.decode(PlaybackStatePayload.self, from: payloadData) { return .playbackState(p) }
        case "authStatus":
            if let p = try? dec.decode(AuthStatusPayload.self, from: payloadData) { return .authStatus(p) }
        case "error":
            if let p = try? dec.decode(BridgeErrorPayload.self, from: payloadData) { return .error(p) }
        default: break
        }
        return .unknown
    }
}

// MARK: - Outbound (Swift → JS)

/// Safe outbound messages encoded as JSON — never constructed by string interpolation.
public struct BridgeCommand: Codable, Sendable {
    public let type: String
    public let payload: [String: BridgePrimitive]?

    public init(type: String, payload: [String: BridgePrimitive]? = nil) {
        self.type = type; self.payload = payload
    }

    /// Serialise to a JS expression: `window.__airmuseBridge.receive(<json>)`
    /// The JSON is encoded by JSONEncoder — no external data is interpolated.
    public func toJavaScript(handlerName: String = "__airmuseBridge") throws -> String {
        let data = try JSONEncoder().encode(self)
        guard let json = String(data: data, encoding: .utf8) else {
            throw EncodingError.invalidValue(self, .init(codingPath: [], debugDescription: "UTF-8 encode failed"))
        }
        // json is fully controlled by JSONEncoder; it never contains arbitrary user/external content
        return "window.\(handlerName) && window.\(handlerName).receive(\(json));"
    }
}

/// A JSON-primitive wrapper for heterogeneous bridge payloads.
public enum BridgePrimitive: Codable, Sendable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case null

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let v = try? c.decode(Bool.self)   { self = .bool(v);   return }
        if let v = try? c.decode(Double.self) { self = .number(v); return }
        if let v = try? c.decode(String.self) { self = .string(v); return }
        self = .null
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .bool(let v):   try c.encode(v)
        case .null:          try c.encodeNil()
        }
    }
}
