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
    private var _queueSnapshot: QueueSnapshot = .empty
    private var _publishSequence: UInt64 = 0

    // MARK: - Continuations for async streams

    private var stateContinuations: [UUID: AsyncStream<PlaybackState>.Continuation] = [:]
    private var lyricsContinuations: [UUID: AsyncStream<LyricsDocument>.Continuation] = [:]
    private var queueContinuations: [UUID: AsyncStream<QueueSnapshot>.Continuation] = [:]

    public init() {}

    // MARK: - Atomic Combined Update

    /// Atomically commits `PlaybackState` and `QueueSnapshot` in a single actor hop.
    /// Rejects stale publications via monotonic `publishSequence`, and only notifies `queueContinuations`
    /// when `queueSnapshot` has actually changed.
    public func commitAtomic(state: PlaybackState, queueSnapshot: QueueSnapshot?, publishSequence: UInt64) {
        guard publishSequence >= _publishSequence else { return }
        _publishSequence = publishSequence

        applyStateUpdate(state)
        if let queueSnapshot {
            applyQueueSnapshotUpdate(queueSnapshot)
        }
    }

    // MARK: - State

    public var state: PlaybackState { _state }

    public func update(state: PlaybackState) {
        applyStateUpdate(state)
    }

    private func applyStateUpdate(_ state: PlaybackState) {
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
    public var queueSnapshot: QueueSnapshot { _queueSnapshot }

    public func update(queue: PlaybackQueue) {
        _queue = queue
    }

    /// Publishes an authoritative `QueueSnapshot` only if it represents a newer or changed structural state.
    public func update(queueSnapshot: QueueSnapshot) {
        applyQueueSnapshotUpdate(queueSnapshot)
    }

    private func applyQueueSnapshotUpdate(_ queueSnapshot: QueueSnapshot) {
        if queueSnapshot.sessionScope == _queueSnapshot.sessionScope,
           queueSnapshot.queueID == _queueSnapshot.queueID,
           queueSnapshot.revision < _queueSnapshot.revision {
            return
        }
        guard queueSnapshot != _queueSnapshot else { return }
        _queueSnapshot = queueSnapshot
        queueContinuations.values.forEach { $0.yield(queueSnapshot) }
    }

    /// Subscribe to structural queue snapshot changes (`bufferingNewest(1)`).
    /// Progress, volume, and lyrics updates do not emit on this stream.
    public func queueStream() -> AsyncStream<QueueSnapshot> {
        AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let id = UUID()
            queueContinuations[id] = continuation
            continuation.yield(_queueSnapshot)
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeQueueContinuation(id: id) }
            }
        }
    }

    private func removeQueueContinuation(id: UUID) {
        queueContinuations.removeValue(forKey: id)
    }
}
