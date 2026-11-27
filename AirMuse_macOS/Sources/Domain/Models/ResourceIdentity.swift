import Foundation

// MARK: - ProviderID

/// Opaque, stable identifier for a music platform/adapter.
/// Never use display names as primary keys or default unknown providers to Apple Music.
public struct ProviderID: RawRepresentable, Hashable, Codable, Sendable, ExpressibleByStringLiteral, CustomStringConvertible {
    public let rawValue: String

    public init(rawValue: String) {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        self.rawValue = trimmed.isEmpty ? "unknown" : trimmed
    }

    public init(stringLiteral value: String) {
        self.init(rawValue: value)
    }

    public var isUnknown: Bool {
        rawValue.isEmpty || rawValue == "unknown"
    }

    public var description: String { rawValue }

    public static let unknown = ProviderID(rawValue: "unknown")
    public static let appleMusic = ProviderID(rawValue: "apple_music")
    public static let spotify = ProviderID(rawValue: "spotify")
    public static let qqMusic = ProviderID(rawValue: "qq_music")
    public static let local = ProviderID(rawValue: "local")
}

// MARK: - ResourceKind

public enum ResourceKind: String, Hashable, Codable, Sendable {
    case song
    case album
    case playlist
    case artist
    case station
    case queueEntry
    case section
    case chart
    case unknown

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = (try? container.decode(String.self)) ?? ""
        self = ResourceKind(rawValue: raw) ?? .unknown
    }
}

// MARK: - ResourceScope

/// Explicit scope isolating catalog regions, private user accounts, and local namespaces.
public enum ResourceScope: Hashable, Codable, Sendable {
    case catalog(region: String?)
    case library(accountID: String, region: String?)
    case local(namespace: String)
    case unknown

    public var isUnknown: Bool {
        if case .unknown = self { return true }
        return false
    }

    public var isLibrary: Bool {
        if case .library = self { return true }
        return false
    }

    public var accountID: String? {
        if case .library(let accountID, _) = self {
            return accountID.isEmpty ? nil : accountID
        }
        return nil
    }

    public var region: String? {
        switch self {
        case .catalog(let region), .library(_, let region):
            return region?.isEmpty == true ? nil : region
        case .local, .unknown:
            return nil
        }
    }

    public var isValid: Bool {
        switch self {
        case .catalog:
            return true
        case .library(let accountID, _):
            return !accountID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .local(let namespace):
            return !namespace.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .unknown:
            return false
        }
    }

    /// Collision-safe canonical string representation for cache/storage keys.
    public var scopeKeyComponent: String {
        switch self {
        case .catalog(let region):
            return "cat:\(Self.escape(region ?? ""))"
        case .library(let accountID, let region):
            return "lib:\(Self.escape(accountID)):\(Self.escape(region ?? ""))"
        case .local(let namespace):
            return "loc:\(Self.escape(namespace))"
        case .unknown:
            return "unk"
        }
    }

    private static func escape(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? value
    }
}

// MARK: - ResourceIdentity

/// Canonical cross-platform resource identity.
/// Two resources are equal only if provider, kind, opaqueID, and scope all match.
public struct ResourceIdentity: Hashable, Codable, Sendable {
    public let providerID: ProviderID
    public let kind: ResourceKind
    public let opaqueID: String
    public let scope: ResourceScope

    public init(
        providerID: ProviderID,
        kind: ResourceKind,
        opaqueID: String,
        scope: ResourceScope
    ) {
        self.providerID = providerID
        self.kind = kind
        self.opaqueID = opaqueID
        self.scope = scope
    }

    public var isValid: Bool {
        !providerID.isUnknown && kind != .unknown && !opaqueID.isEmpty && scope.isValid
    }

    /// Collision-safe key for caches, deduplication, and persistence.
    public var scopedKey: String {
        let p = Self.escape(providerID.rawValue)
        let k = Self.escape(kind.rawValue)
        let id = Self.escape(opaqueID)
        return "\(p)/\(k)/\(id)/\(scope.scopeKeyComponent)"
    }

    private static func escape(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? value
    }
}
