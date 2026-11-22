import Foundation

// MARK: - PlaybackSession

/// Represents a live playback session bound to one provider.
public struct PlaybackSession: Sendable, Identifiable {
    public let id: UUID
    public var providerID: String
    public var currentTrack: MusicTrack?
    public var source: MusicSource
    public var state: PlaybackStatus
    public var queue: PlaybackQueue
    public var positionSeconds: Double
    public var volume: Float
    public var startedAt: Date

    public static let idle = PlaybackSession()

    public init(
        id: UUID = .init(),
        providerID: String = "",
        currentTrack: MusicTrack? = nil,
        source: MusicSource = .unknown,
        state: PlaybackStatus = .idle,
        queue: PlaybackQueue = PlaybackQueue(),
        positionSeconds: Double = 0,
        volume: Float = 1.0,
        startedAt: Date = .now
    ) {
        self.id = id
        self.providerID = providerID.isEmpty ? source.rawValue : providerID
        self.currentTrack = currentTrack ?? queue.currentTrack
        self.source = source
        self.state = state
        self.queue = queue
        self.positionSeconds = positionSeconds
        self.volume = volume
        self.startedAt = startedAt
    }
}
