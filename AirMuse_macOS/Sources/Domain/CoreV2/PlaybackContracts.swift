import Foundation

// MARK: - PlaybackOperationContext

/// Context binding every playback command, result, and engine event to a specific
/// session, engine instance, operation sequence, and target track.
public struct PlaybackOperationContext: Sendable, Equatable, Hashable {
    public let sessionID: UUID
    public let engineInstanceID: UUID
    public let operationID: UInt64
    public let trackID: String

    public init(
        sessionID: UUID,
        engineInstanceID: UUID,
        operationID: UInt64,
        trackID: String
    ) {
        self.sessionID = sessionID
        self.engineInstanceID = engineInstanceID
        self.operationID = operationID
        self.trackID = trackID
    }
}

// MARK: - PlaybackTransportStatus

public enum PlaybackTransportStatus: Sendable, Equatable {
    case idle
    case preparing
    case buffering
    case playing
    case paused
    case seeking
    case recovering
    case ended
    case failed(String)
}

public enum PlayableKind: String, Sendable, Equatable, Codable {
    case song
    case album
    case playlist
    case station
}

/// Identifies the authoritative provider resource for engine execution (e.g. a radio station ID
/// that must remain constant even as `itemChanged` updates the currently displayed track).
public struct PlaybackTarget: Sendable, Equatable, Codable {
    public let kind: PlayableKind
    public let providerResourceID: String
    public let providerID: ProviderID
    public let scope: ResourceScope
    public let title: String?
    public let storefront: String?

    public var identity: ResourceIdentity? {
        guard !providerResourceID.isEmpty, !providerID.isUnknown else { return nil }
        let resourceKind: ResourceKind = switch kind {
        case .song: .song
        case .album: .album
        case .playlist: .playlist
        case .station: .station
        }
        return ResourceIdentity(
            providerID: providerID,
            kind: resourceKind,
            opaqueID: providerResourceID,
            scope: scope
        )
    }

    public init(
        kind: PlayableKind,
        providerResourceID: String,
        providerID: ProviderID = .unknown,
        scope: ResourceScope = .unknown,
        title: String? = nil,
        storefront: String? = nil
    ) {
        self.kind = kind
        self.providerResourceID = providerResourceID
        self.providerID = providerID
        self.scope = scope
        self.title = title
        self.storefront = storefront
    }
}

public enum QueueOwner: String, Sendable, Equatable, Codable {
    case localCoordinator
    case remoteEngine
}

// MARK: - EngineCommand & EngineEvent

public enum EngineCommand: Sendable, Equatable {
    case playItem(id: String, kind: PlayableKind, startIndex: Int)
    case play
    case pause
    case stop
    case seek(seconds: Double)
    case setVolume(Float)
    case skipNext
    case skipPrevious
}

public enum EngineEvent: Sendable, Equatable {
    case readinessChanged(engineInstanceID: UUID, isReady: Bool, isAuthorized: Bool)
    case stateChanged(context: PlaybackOperationContext, status: PlaybackTransportStatus)
    case positionUpdated(context: PlaybackOperationContext, positionSeconds: Double, durationSeconds: Double)
    case itemChanged(
        context: PlaybackOperationContext,
        trackID: String,
        title: String,
        artist: String,
        albumTitle: String,
        artworkURL: String,
        durationSeconds: Double
    )
    case trackEnded(context: PlaybackOperationContext, positionSeconds: Double, durationSeconds: Double)
    case crashed(engineInstanceID: UUID, reason: String)
}

public protocol PlaybackEngineProtocol: Sendable {
    var engineInstanceID: UUID { get async }
    func events() async -> AsyncStream<EngineEvent>
    func prepare(sessionContext: SessionContext, deadlineSeconds: TimeInterval) async throws
    func execute(_ command: EngineCommand, context: PlaybackOperationContext) async throws
    func isolateAndReset() async
}
