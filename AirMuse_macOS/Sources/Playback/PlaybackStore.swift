import Foundation
import Domain

// MARK: - PlaybackStore

/// Thread-safe, actor-isolated store for the application's playback state.
/// Observers receive updates via AsyncStream.
public actor PlaybackStore {

    // MARK: - Stored state

    private var _state: PlaybackState = .idle
    private var _lyrics: LyricsDocument = .empty
    private var _queue: PlaybackQueue = .init()

    // MARK: - Continuations for async streams

    private var stateContinuations: [UUID: AsyncStream<PlaybackState>.Continuation] = [:]
    private var lyricsContinuations: [UUID: AsyncStream<LyricsDocument>.Continuation] = [:]

    public init() {}

    // MARK: - State

    public var state: PlaybackState { _state }

    public func update(state: PlaybackState) {
        // Preserve cached artwork when the track key hasn't changed.
        if state.artworkData == nil,
           let existing = _state.artworkData,
           state.currentTrack?.trackKey == _state.currentTrack?.trackKey {
            var patched = state
            patched.artworkData = existing
            _state = patched
        } else {
            _state = state
        }
        stateContinuations.values.forEach { $0.yield(_state) }
    }

    /// Subscribe to playback state changes.
    public func stateStream() -> AsyncStream<PlaybackState> {
        AsyncStream { continuation in
            let id = UUID()
            stateContinuations[id] = continuation
            continuation.yield(_state)          // emit current state immediately
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeStateContinuation(id: id) }
            }
        }
    }

    public func playbackStream() -> AsyncStream<PlaybackState> {
        stateStream()
    }

    private func removeStateContinuation(id: UUID) {
        stateContinuations.removeValue(forKey: id)
    }

    // MARK: - Lyrics

    public var lyrics: LyricsDocument { _lyrics }

    public func update(lyrics: LyricsDocument) {
        _lyrics = lyrics
        lyricsContinuations.values.forEach { $0.yield(lyrics) }
    }

    public func lyricsStream() -> AsyncStream<LyricsDocument> {
        AsyncStream { continuation in
            let id = UUID()
            lyricsContinuations[id] = continuation
            continuation.yield(_lyrics)
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeLyricsContinuation(id: id) }
            }
        }
    }

    private func removeLyricsContinuation(id: UUID) {
        lyricsContinuations.removeValue(forKey: id)
    }

    // MARK: - Queue

    public var queue: PlaybackQueue { _queue }

    public func update(queue: PlaybackQueue) {
        _queue = queue
    }
}
