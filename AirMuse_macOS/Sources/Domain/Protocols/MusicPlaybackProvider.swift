import Foundation

// MARK: - MusicPlaybackProvider

/// Controls playback for a specific provider (play, pause, seek, volume, queue).
/// All methods are async and actor-safe.
public protocol MusicPlaybackProvider: Sendable {
    var providerID: String { get }
    var source: MusicSource { get }
    var capabilities: MusicProviderCapabilities { get async }

    // State
    func getState() async -> PlaybackState
    func currentSession() async -> PlaybackSession
    func stateUpdates() async -> AsyncStream<PlaybackState>?

    // Transport
    func play() async throws
    func pause() async throws
    func playPause() async throws
    func stop() async throws
    func skipToNext() async throws
    func skipToPrevious() async throws
    func seek(toMs position: Int64) async throws
    func seek(to seconds: Double) async throws

    // Volume
    func setVolume(_ volume: Float) async throws   // 0.0 … 1.0
    func setMuted(_ muted: Bool) async throws

    // Queue / Track
    func play(track: MusicTrack) async throws
    func playTrack(_ track: MusicTrack, in queue: PlaybackQueue) async throws
    func getQueue() async -> PlaybackQueue
    func setRepeatMode(_ mode: PlaybackState.RepeatMode) async throws
    func setShuffleEnabled(_ enabled: Bool) async throws
}

// MARK: - Default Protocol Implementations

extension MusicPlaybackProvider {
    public var providerID: String { source.rawValue }
    public var source: MusicSource { .unknown }

    public func stateUpdates() async -> AsyncStream<PlaybackState>? { nil }

    public func play() async throws { try await playPause() }
    public func pause() async throws { try await playPause() }
    public func playPause() async throws { try await play() }
    public func seek(toMs position: Int64) async throws { try await seek(to: Double(position) / 1000.0) }
    public func seek(to seconds: Double) async throws { try await seek(toMs: Int64(seconds * 1000.0)) }
    public func setMuted(_ muted: Bool) async throws {}
    public func play(track: MusicTrack) async throws {
        try await playTrack(track, in: PlaybackQueue(items: [track], currentIndex: 0))
    }
    public func playTrack(_ track: MusicTrack, in queue: PlaybackQueue) async throws {
        try await play(track: track)
    }
    public func getQueue() async -> PlaybackQueue {
        await currentSession().queue
    }
    public func setRepeatMode(_ mode: PlaybackState.RepeatMode) async throws {}
    public func setShuffleEnabled(_ enabled: Bool) async throws {}

    public func getState() async -> PlaybackState {
        let session = await currentSession()
        let isPlaying = session.state == .playing
        return PlaybackState(
            status: session.state,
            isPlaying: isPlaying,
            positionMs: Int64(session.positionSeconds * 1000),
            durationMs: session.queue.currentTrack?.durationMs ?? 0,
            volume: session.volume,
            isMuted: false,
            repeatMode: .off,
            shuffleEnabled: false,
            currentTrack: session.queue.currentTrack,
            providerID: providerID,
            sourceName: source.displayName,
            artworkData: nil,
            timestampDate: .now
        )
    }

    public func currentSession() async -> PlaybackSession {
        let state = await getState()
        return PlaybackSession(
            providerID: providerID,
            currentTrack: state.currentTrack,
            source: source,
            state: state.status,
            queue: await getQueue(),
            positionSeconds: Double(state.positionMs) / 1000.0,
            volume: state.volume
        )
    }
}
