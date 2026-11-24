import Foundation
import Domain

// MARK: - PlaybackTimeAnchor

/// Monotonic-clock position anchor for smooth progress interpolation
/// without high-frequency JS polling.
public struct PlaybackTimeAnchor: Sendable, Equatable {
    public let positionMs: Int64
    public let durationMs: Int64
    public let monotonicNs: UInt64
    public let isPlaying: Bool

    public init(positionMs: Int64, durationMs: Int64, monotonicNs: UInt64, isPlaying: Bool) {
        self.positionMs = max(0, positionMs)
        self.durationMs = max(0, durationMs)
        self.monotonicNs = monotonicNs
        self.isPlaying = isPlaying
    }

    public func interpolatedPositionMs(at currentMonotonicNs: UInt64) -> Int64 {
        guard isPlaying, currentMonotonicNs >= monotonicNs else {
            return positionMs
        }
        let elapsedMs = Int64((currentMonotonicNs - monotonicNs) / 1_000_000)
        let raw = positionMs + elapsedMs
        if durationMs > 0 {
            return min(raw, durationMs)
        }
        return raw
    }
}

// MARK: - PlaybackCoordinatorV2

/// Authoritative Core V2 playback scheduler.
/// Guarantees Latest-Intent-Wins with serialized underlying engine execution,
/// queue ownership isolation (local vs remote radio), monotonic time anchoring,
/// and strict `(sessionID, engineInstanceID, operationID, trackID)` event filtering.
public actor PlaybackCoordinatorV2 {
    private let store: PlaybackStore
    private let engine: any PlaybackEngineProtocol
    private let clock: any ClockProtocol

    private var activeSession: SessionContext?
    private var operationID: UInt64 = 0
    private var activePlayOperationID: UInt64 = 0

    // Desired state (updated synchronously on user intent)
    private var desiredTrack: MusicTrack?
    private var desiredKind: PlayableKind = .song
    private var desiredStartIndex: Int = 0
    private var desiredTransport: DesiredTransport = .stopped
    private var pendingSeekSeconds: Double?
    private var desiredVolume: Float = 1.0

    // Actual engine-confirmed state
    private var actualStatus: PlaybackTransportStatus = .idle
    private var queue: PlaybackQueue = PlaybackQueue()
    private var queueOwner: QueueOwner = .localCoordinator
    private var repeatMode: PlaybackState.RepeatMode = .off
    private var shuffleEnabled: Bool = false
    private var timeAnchor: PlaybackTimeAnchor = PlaybackTimeAnchor(positionMs: 0, durationMs: 0, monotonicNs: 0, isPlaying: false)

    // Serial execution & deduplication
    private var isDraining: Bool = false
    private var needsPlayItemExecution: Bool = false
    private var needsTransportSync: Bool = false
    private var lastEndedOperationKey: String?

    private var eventTask: Task<Void, Never>?

    private enum DesiredTransport: Equatable {
        case playing
        case paused
        case stopped
    }

    public init(
        store: PlaybackStore,
        engine: any PlaybackEngineProtocol,
        clock: any ClockProtocol = SystemClock()
    ) {
        self.store = store
        self.engine = engine
        self.clock = clock
    }

    // MARK: - Lifecycle

    public func start(session: SessionContext? = nil) async {
        self.activeSession = session
        eventTask?.cancel()
        eventTask = Task { [weak self] in
            guard let self else { return }
            let stream = await self.engine.events()
            for await event in stream {
                if Task.isCancelled { break }
                await self.handleEngineEvent(event)
            }
        }
        await publishToStore()
    }

    public func updateSession(_ session: SessionContext?) async {
        let changed = activeSession?.sessionID != session?.sessionID || activeSession?.generation != session?.generation
        self.activeSession = session
        if changed && session == nil {
            try? await stop()
        }
    }

    public func shutdown() async {
        eventTask?.cancel()
        eventTask = nil
        try? await stop()
    }

    // MARK: - User Intents (Latest Intent Wins)

    public func playTrack(_ track: MusicTrack, in queue: PlaybackQueue, kind: PlayableKind? = nil, startIndex: Int = 0) async throws {
        operationID += 1
        activePlayOperationID = operationID
        self.queue = queue
        self.desiredTrack = track
        let resolvedKind: PlayableKind = kind ?? (track.providerTrackID.hasPrefix("ra.") || track.id.hasPrefix("ra.") ? .station : .song)
        self.desiredKind = resolvedKind
        self.desiredStartIndex = startIndex
        self.queueOwner = (resolvedKind == .station) ? .remoteEngine : .localCoordinator
        self.desiredTransport = .playing
        self.pendingSeekSeconds = nil
        self.actualStatus = .preparing
        self.timeAnchor = PlaybackTimeAnchor(positionMs: 0, durationMs: track.durationMs, monotonicNs: clock.monotonicNanoseconds, isPlaying: false)
        self.needsPlayItemExecution = true
        self.needsTransportSync = false

        await publishToStore()
        await drainCommands()
    }

    public func play() async throws {
        guard desiredTrack != nil else { return }
        operationID += 1
        desiredTransport = .playing
        needsTransportSync = true
        await drainCommands()
    }

    public func playPause() async throws {
        if desiredTransport == .playing {
            try await pause()
        } else {
            try await play()
        }
    }

    public func pause() async throws {
        operationID += 1
        desiredTransport = .paused
        if actualStatus == .preparing || actualStatus == .buffering {
            needsPlayItemExecution = false
        }
        needsTransportSync = true
        actualStatus = .paused
        let currentPos = timeAnchor.interpolatedPositionMs(at: clock.monotonicNanoseconds)
        timeAnchor = PlaybackTimeAnchor(positionMs: currentPos, durationMs: timeAnchor.durationMs, monotonicNs: clock.monotonicNanoseconds, isPlaying: false)
        await publishToStore()
        await drainCommands()
    }

    public func stop() async throws {
        operationID += 1
        activePlayOperationID = operationID
        desiredTransport = .stopped
        needsPlayItemExecution = false
        needsTransportSync = true
        actualStatus = .idle
        timeAnchor = PlaybackTimeAnchor(positionMs: 0, durationMs: 0, monotonicNs: clock.monotonicNanoseconds, isPlaying: false)
        await publishToStore()
        await drainCommands()
    }

    public func seek(toMs ms: Int64) async throws {
        operationID += 1
        let clampedMs = max(0, ms)
        pendingSeekSeconds = Double(clampedMs) / 1000.0
        timeAnchor = PlaybackTimeAnchor(
            positionMs: clampedMs,
            durationMs: timeAnchor.durationMs,
            monotonicNs: clock.monotonicNanoseconds,
            isPlaying: desiredTransport == .playing && actualStatus == .playing
        )
        await publishToStore()
        await drainCommands()
    }

    public func setVolume(_ volume: Float) async throws {
        let clamped = min(max(volume, 0), 1)
        desiredVolume = clamped
        let ctx = await currentContext(trackID: desiredTrack?.id ?? "")
        try? await engine.execute(.setVolume(clamped), context: ctx)
        await publishToStore()
    }

    public func setRepeatMode(_ mode: PlaybackState.RepeatMode) async {
        repeatMode = mode
        await publishToStore()
    }

    public func setShuffleEnabled(_ enabled: Bool) async {
        shuffleEnabled = enabled
        await publishToStore()
    }

    public func skipToNext() async throws {
        if queueOwner == .remoteEngine {
            let ctx = await currentContext(trackID: desiredTrack?.id ?? "")
            try await engine.execute(.skipNext, context: ctx)
            return
        }
        if let next = nextQueueTrack() {
            try await playTrack(next, in: queue)
        } else {
            try await stop()
        }
    }

    public func skipToPrevious() async throws {
        if queueOwner == .remoteEngine {
            let ctx = await currentContext(trackID: desiredTrack?.id ?? "")
            try await engine.execute(.skipPrevious, context: ctx)
            return
        }
        if let prev = queue.previousTrack {
            queue.retreat()
            try await playTrack(prev, in: queue)
        }
    }

    public func currentSnapshotState() async -> PlaybackState {
        await store.state
    }

    public func currentQueueSnapshot() -> PlaybackQueue {
        queue
    }

    // MARK: - Serialized Execution Loop

    private func drainCommands() async {
        guard !isDraining else { return }
        isDraining = true
        defer { isDraining = false }

        while needsPlayItemExecution || needsTransportSync || pendingSeekSeconds != nil {
            let sessionID = activeSession?.sessionID ?? UUID(uuidString: "00000000-0000-0000-0000-000000000000")!
            let engineID = await engine.engineInstanceID

            if needsPlayItemExecution, let track = desiredTrack, desiredTransport == .playing {
                needsPlayItemExecution = false
                let targetOpID = operationID
                let targetID = track.providerTrackID.isEmpty ? track.id : track.providerTrackID
                let ctx = PlaybackOperationContext(sessionID: sessionID, engineInstanceID: engineID, operationID: targetOpID, trackID: targetID)

                do {
                    try await engine.execute(.playItem(id: targetID, kind: desiredKind, startIndex: desiredStartIndex), context: ctx)
                } catch {
                    if targetOpID == operationID {
                        actualStatus = .failed(error.localizedDescription)
                        await publishToStore()
                    }
                }
                if targetOpID != operationID {
                    continue
                }
            }

            if let seekSec = pendingSeekSeconds {
                pendingSeekSeconds = nil
                let targetOpID = operationID
                let ctx = PlaybackOperationContext(sessionID: sessionID, engineInstanceID: engineID, operationID: targetOpID, trackID: desiredTrack?.id ?? "")
                try? await engine.execute(.seek(seconds: seekSec), context: ctx)
                if targetOpID != operationID {
                    continue
                }
            }

            if needsTransportSync {
                needsTransportSync = false
                let targetOpID = operationID
                let ctx = PlaybackOperationContext(sessionID: sessionID, engineInstanceID: engineID, operationID: targetOpID, trackID: desiredTrack?.id ?? "")
                switch desiredTransport {
                case .playing:
                    try? await engine.execute(.play, context: ctx)
                case .paused:
                    try? await engine.execute(.pause, context: ctx)
                case .stopped:
                    try? await engine.execute(.stop, context: ctx)
                }
            }
        }
    }

    // MARK: - Engine Event Filtering & Handling

    private func handleEngineEvent(_ event: EngineEvent) async {
        let currentEngineID = await engine.engineInstanceID

        switch event {
        case .readinessChanged:
            break

        case .stateChanged(let ctx, let status):
            guard ctx.engineInstanceID == currentEngineID, ctx.operationID == activePlayOperationID else { return }
            if desiredTransport == .paused && status == .playing { return }
            if desiredTransport == .stopped && status != .idle { return }
            let prevStatus = actualStatus
            let nowNs = clock.monotonicNanoseconds
            let currentPos = timeAnchor.interpolatedPositionMs(at: nowNs)
            if desiredTransport == .playing,
               queueOwner == .localCoordinator,
               prevStatus == .playing,
               (status == .paused || status == .idle || status == .ended),
               timeAnchor.durationMs > 5000,
               currentPos >= timeAnchor.durationMs - 1500 {
                await handleNaturalTrackEnd(operationID: ctx.operationID, trackID: ctx.trackID)
                return
            }
            actualStatus = status
            timeAnchor = PlaybackTimeAnchor(
                positionMs: currentPos,
                durationMs: timeAnchor.durationMs,
                monotonicNs: nowNs,
                isPlaying: status == .playing
            )
            await publishToStore()

        case .positionUpdated(let ctx, let posSec, let durSec):
            guard ctx.engineInstanceID == currentEngineID, ctx.operationID == activePlayOperationID else { return }
            let posMs = Int64(max(0, posSec) * 1000)
            let durMs = durSec > 0 ? Int64(durSec * 1000) : timeAnchor.durationMs
            timeAnchor = PlaybackTimeAnchor(
                positionMs: posMs,
                durationMs: durMs,
                monotonicNs: clock.monotonicNanoseconds,
                isPlaying: actualStatus == .playing
            )
            await publishToStore()

        case .itemChanged(let ctx, let trackID, let title, let artist, let albumTitle, let artworkURL, let durSec):
            guard ctx.engineInstanceID == currentEngineID, ctx.operationID == activePlayOperationID else { return }
            let nowNs = clock.monotonicNanoseconds
            var didMutate = false
            if queueOwner == .remoteEngine, !title.isEmpty, let current = desiredTrack {
                let effectiveID = trackID.isEmpty ? current.id : trackID
                let effectiveArtist = artist.isEmpty ? current.artistName : artist
                let effectiveAlbum = albumTitle.isEmpty ? current.albumTitle : albumTitle
                let effectiveArt = URL(string: artworkURL) ?? current.artworkURL
                let effectiveDurMs = durSec > 0 ? Int64(durSec * 1000) : current.durationMs
                let trackChanged = (current.title != title || current.artistName != effectiveArtist || (!trackID.isEmpty && current.providerTrackID != trackID))
                desiredTrack = MusicTrack(
                    id: effectiveID,
                    title: title,
                    artistName: effectiveArtist,
                    albumTitle: effectiveAlbum,
                    durationMs: effectiveDurMs,
                    artworkURL: effectiveArt,
                    providerID: current.providerID,
                    providerTrackID: effectiveID
                )
                timeAnchor = PlaybackTimeAnchor(
                    positionMs: trackChanged ? 0 : timeAnchor.interpolatedPositionMs(at: nowNs),
                    durationMs: effectiveDurMs,
                    monotonicNs: nowNs,
                    isPlaying: actualStatus == .playing
                )
                didMutate = true
            } else if durSec > 0 {
                timeAnchor = PlaybackTimeAnchor(
                    positionMs: timeAnchor.interpolatedPositionMs(at: nowNs),
                    durationMs: Int64(durSec * 1000),
                    monotonicNs: nowNs,
                    isPlaying: actualStatus == .playing
                )
                didMutate = true
            }
            if didMutate {
                await publishToStore()
            }

        case .trackEnded(let ctx, _, _):
            guard ctx.engineInstanceID == currentEngineID, ctx.operationID == activePlayOperationID else { return }
            await handleNaturalTrackEnd(operationID: ctx.operationID, trackID: ctx.trackID)

        case .crashed(let crashedID, _):
            guard crashedID == currentEngineID else { return }
            actualStatus = .recovering
            let nowNs = clock.monotonicNanoseconds
            timeAnchor = PlaybackTimeAnchor(
                positionMs: timeAnchor.interpolatedPositionMs(at: nowNs),
                durationMs: timeAnchor.durationMs,
                monotonicNs: nowNs,
                isPlaying: false
            )
            await publishToStore()
        }
    }

    // MARK: - Helpers

    private func handleNaturalTrackEnd(operationID opID: UInt64, trackID: String) async {
        let dedupKey = "\(opID)|\(trackID)"
        guard lastEndedOperationKey != dedupKey else { return }
        lastEndedOperationKey = dedupKey

        guard queueOwner == .localCoordinator else { return }

        if repeatMode == .one, let current = desiredTrack {
            try? await playTrack(current, in: queue)
        } else if let next = nextQueueTrack() {
            try? await playTrack(next, in: queue)
        } else {
            try? await stop()
        }
    }

    private func nextQueueTrack() -> MusicTrack? {
        if shuffleEnabled, queue.tracks.count > 1 {
            let candidates = queue.tracks.indices.filter { $0 != queue.currentIndex }
            if let pick = candidates.randomElement() {
                queue.currentIndex = pick
                return queue.currentTrack
            }
        }
        if queue.nextTrack != nil {
            queue.advance()
            return queue.currentTrack
        }
        if repeatMode == .all, !queue.tracks.isEmpty {
            queue.currentIndex = 0
            return queue.currentTrack
        }
        return nil
    }

    private func currentContext(trackID: String) async -> PlaybackOperationContext {
        let sid = activeSession?.sessionID ?? UUID(uuidString: "00000000-0000-0000-0000-000000000000")!
        let eid = await engine.engineInstanceID
        return PlaybackOperationContext(sessionID: sid, engineInstanceID: eid, operationID: operationID, trackID: trackID)
    }

    private func publishToStore() async {
        let domainStatus: PlaybackStatus = switch actualStatus {
        case .idle, .ended: .idle
        case .preparing: .loading
        case .buffering, .seeking, .recovering: .buffering
        case .playing: .playing
        case .paused: .paused
        case .failed: .failed
        }
        let errorMsg: String? = if case .failed(let msg) = actualStatus { msg } else { nil }
        let posMs = timeAnchor.interpolatedPositionMs(at: clock.monotonicNanoseconds)
        let state = PlaybackState(
            status: domainStatus,
            isPlaying: actualStatus == .playing,
            positionMs: posMs,
            durationMs: timeAnchor.durationMs,
            volume: desiredVolume,
            isMuted: desiredVolume <= 0.001,
            repeatMode: repeatMode,
            shuffleEnabled: shuffleEnabled,
            currentTrack: desiredTrack,
            providerID: desiredTrack?.providerID ?? "apple_music",
            sourceName: "Apple Music",
            artworkData: nil,
            timestampDate: clock.now,
            errorMessage: errorMsg
        )
        await store.update(state: state)
    }
}
