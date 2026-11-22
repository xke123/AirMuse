import Foundation

// MARK: - PlaybackStatus

public enum PlaybackStatus: String, Sendable, Codable, Equatable {
    case idle
    case loading
    case ready
    case playing
    case paused
    case buffering
    case seeking
    case stopped
    case failed
    case unavailable
}

// MARK: - PlaybackState

/// The complete playback state snapshot broadcast by PlaybackCoordinator.
public struct PlaybackState: Sendable, Equatable {
    public var status: PlaybackStatus
    public var isPlaying: Bool
    public var positionMs: Int64
    public var durationMs: Int64
    public var volume: Float             // 0.0 … 1.0
    public var isMuted: Bool
    public var repeatMode: RepeatMode
    public var shuffleEnabled: Bool
    public var currentTrack: MusicTrack?
    public var providerID: String?
    public var sourceName: String        // display name, e.g. "Apple Music"
    public var artworkData: Data?        // cached artwork bytes
    public var timestampDate: Date       // wall-clock when positionMs was sampled
    public var errorMessage: String?

    public enum RepeatMode: String, Sendable, Codable {
        case off
        case one
        case all
    }

    /// Computed estimated position accounting for elapsed wall-clock time.
    public var estimatedPositionMs: Int64 {
        guard isPlaying else { return positionMs }
        let elapsed = Int64(Date.now.timeIntervalSince(timestampDate) * 1000)
        let est = positionMs + elapsed
        guard durationMs > 0 else { return est }
        return min(est, durationMs)
    }

    public static let idle = PlaybackState(
        status: .idle,
        isPlaying: false,
        positionMs: 0,
        durationMs: 0,
        volume: 0.8,
        isMuted: false,
        repeatMode: .off,
        shuffleEnabled: false,
        currentTrack: nil,
        providerID: nil,
        sourceName: "Ready",
        artworkData: nil,
        timestampDate: .now,
        errorMessage: nil
    )

    public init(
        status: PlaybackStatus = .idle,
        isPlaying: Bool = false,
        positionMs: Int64 = 0,
        durationMs: Int64 = 0,
        volume: Float = 0.8,
        isMuted: Bool = false,
        repeatMode: RepeatMode = .off,
        shuffleEnabled: Bool = false,
        currentTrack: MusicTrack? = nil,
        providerID: String? = nil,
        sourceName: String = "Ready",
        artworkData: Data? = nil,
        timestampDate: Date = .now,
        errorMessage: String? = nil
    ) {
        self.status = status
        self.isPlaying = isPlaying || (status == .playing)
        self.positionMs = positionMs
        self.durationMs = durationMs
        self.volume = volume
        self.isMuted = isMuted
        self.repeatMode = repeatMode
        self.shuffleEnabled = shuffleEnabled
        self.currentTrack = currentTrack
        self.providerID = providerID
        self.sourceName = sourceName
        self.artworkData = artworkData
        self.timestampDate = timestampDate
        self.errorMessage = errorMessage
    }
}
