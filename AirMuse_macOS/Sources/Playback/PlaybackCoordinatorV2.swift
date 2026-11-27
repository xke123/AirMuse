import Foundation
import Domain
import Infrastructure

// MARK: - PlaybackTimeAnchor

/// Monotonic-clock position anchor for smooth progress interpolation
/// without high-frequency JS polling.
public struct PlaybackTimeAnchor: Sendable, Equatable {
    public let positionMs: Int64
    public let durationMs: Int64
    public let monotonicNs: UInt64
    public let isPlaying: Bool

    public static let zero = PlaybackTimeAnchor(positionMs: 0, durationMs: 0, monotonicNs: 0, isPlaying: false)

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

// MARK: - QueueRandomizer

/// Injectable random source for deterministic testing of shuffle and repeat-all transitions.
public protocol QueueRandomizer: Sendable {
    func nextUInt64() -> UInt64
}

public struct SystemQueueRandomizer: QueueRandomizer {
    public init() {}
    public func nextUInt64() -> UInt64 {
        var sys = SystemRandomNumberGenerator()
        return sys.next()
    }
}

private struct RandomizerAdapter: RandomNumberGenerator {
    let source: any QueueRandomizer
    mutating func next() -> UInt64 { source.nextUInt64() }
}

// MARK: - PlaybackCoordinatorV2

/// Authoritative Core V2 playback scheduler & sole queue writer.
/// Separates `playbackGeneration` (source selection), `transportRevision` (play/pause/seek),
/// `queueManager.revision` (structural edits), and `publishSequence` (monotonic atomic Store commits).
public actor PlaybackCoordinatorV2 {
    private let store: PlaybackStore
    private let engine: any PlaybackEngineProtocol
    private let clock: any ClockProtocol
    private let snapshotStore: PlaybackSnapshotStore?
    private let randomizer: any QueueRandomizer

    private var activeSession: SessionContext?
    private var playbackGeneration: UInt64 = 0
    private var transportRevision: UInt64 = 0
    private var activePlayGeneration: UInt64 = 0
    private var publishSequence: UInt64 = 0
    private var operationEntryMap: [UInt64: UUID] = [:]

    // Authoritative synchronous queue state
    private var queueManager = QueueManager()
    private var rngAdapter: RandomizerAdapter

    // Desired state (updated synchronously on user intent)
    private var desiredTrack: MusicTrack?
    private var activeTargetResource: PlaybackTarget?
    private var desiredTransport: DesiredTransport = .stopped
    private var pendingSeekSeconds: Double?
    private var desiredVolume: Float = 1.0
    private var restoredNeedsEngineLoad: Bool = false
    private var needsPlayItemOnResume: Bool = false

    // Actual engine-confirmed state
    private var actualStatus: PlaybackTransportStatus = .idle
    private var timeAnchor: PlaybackTimeAnchor = .zero

    // Serial execution & deduplication
    private var isDraining: Bool = false
    private var needsPlayItemExecution: Bool = false
    private var needsTransportSync: Bool = false
    private var lastEndedOperationKey: String?

    private var eventTask: Task<Void, Never>?
    private var snapshotSaveTask: Task<Void, Never>?
    private var lastProgressSnapshotSaveNs: UInt64 = 0
    private var hasRestoredForScope: String?

    private enum DesiredTransport: Equatable {
        case playing
        case paused
        case stopped
    }

    public init(
        store: PlaybackStore,
        engine: any PlaybackEngineProtocol,
        clock: any ClockProtocol = SystemClock(),
        snapshotStore: PlaybackSnapshotStore? = nil,
        randomizer: any QueueRandomizer = SystemQueueRandomizer()
    ) {
        self.store = store
        self.engine = engine
        self.clock = clock
        self.snapshotStore = snapshotStore
        self.randomizer = randomizer
        self.rngAdapter = RandomizerAdapter(source: randomizer)
    }

    // MARK: - Lifecycle & Session Invalidation (P0-01)

    public func start(session: SessionContext? = nil) async {
        self.activeSession = session
        queueManager.setSessionScope(Self.sessionScope(for: session))
        eventTask?.cancel()
        let stream = await self.engine.events()
        eventTask = Task { [weak self] in
            guard let self else { return }
            for await event in stream {
                if Task.isCancelled { break }
                await self.handleEngineEvent(event)
            }
        }
        await publishToStore(includeQueue: true)
    }

    public func updateSession(_ session: SessionContext?) async {
        let prevSession = activeSession
        let accountChanged = prevSession?.accountID != session?.accountID || prevSession?.providerID != session?.providerID
        let sessionChanged = prevSession?.sessionID != session?.sessionID || prevSession?.generation != session?.generation
        self.activeSession = session
        let newScope = Self.sessionScope(for: session)

        if session == nil && sessionChanged {
            AppLogger.shared.log(category: .queue, level: .info, message: "会话已退出，清空私有播放队列")
            await invalidatePlaybackSession(newScope: "")
            return
        }

        if accountChanged {
            AppLogger.shared.log(category: .queue, level: .info, message: "账户切换，重置并隔离播放队列")
            await invalidatePlaybackSession(newScope: newScope)
        } else if sessionChanged {
            queueManager.setSessionScope(newScope)
            await publishToStore(includeQueue: true)
        }
    }

    /// Synchronously invalidates all playback/queue/session state before stopping the engine,
    /// ensuring no stale account data or late engine events leak across sessions.
    public func invalidatePlaybackSession(newScope: String) async {
        snapshotSaveTask?.cancel()
        playbackGeneration &+= 1
        transportRevision &+= 1
        activePlayGeneration = 0
        operationEntryMap.removeAll()
        desiredTrack = nil
        activeTargetResource = nil
        desiredTransport = .stopped
        pendingSeekSeconds = nil
        restoredNeedsEngineLoad = false
        needsPlayItemOnResume = false
        needsPlayItemExecution = false
        needsTransportSync = false
        lastEndedOperationKey = nil
        actualStatus = .idle
        timeAnchor = .zero
        hasRestoredForScope = nil
        queueManager.resetForSessionInvalidation(newScope: newScope)

        // Publish clean state immediately before potentially blocking engine stop
        await publishToStore(includeQueue: true)
        let ctx = await currentContext(trackID: "")
        try? await engine.execute(.stop, context: ctx)
    }

    public func shutdown() async {
        snapshotSaveTask?.cancel()
        await flushSnapshot()
        eventTask?.cancel()
        eventTask = nil
        try? await stop()
    }

    // MARK: - Unified Four Playback & Queue Intents (Section 1.1–1.2)

    @discardableResult
    public func submitIntent(
        _ intent: QueueInsertionIntent,
        entries: [QueueEntry],
        startIndex: Int = 0,
        kind: PlayableKind? = nil,
        loadingState: QueueLoadingState? = nil,
        batchID: UUID? = nil,
        expectedQueueID: UUID? = nil,
        expectedDestructiveEpoch: UInt64? = nil,
        explicitShuffleMode: Bool? = nil
    ) async throws -> QueueCommandResult {
        guard !entries.isEmpty else { throw QueueEditError.emptyBatch }

        switch intent {
        case .replaceAndPlay:
            try await playEntries(
                entries,
                startIndex: startIndex,
                kind: kind,
                loadingState: loadingState,
                batchID: batchID,
                shuffleOverride: explicitShuffleMode,
                pickRandomFirstWhenShuffling: false
            )
            let snap = queueManager.makeSnapshot()
            return QueueCommandResult(
                queueID: snap.queueID,
                revision: snap.revision,
                destructiveEpoch: snap.destructiveEpoch,
                acceptedCount: entries.count,
                message: "已提交播放 \(entries.count) 首曲目"
            )

        case .shuffleAndPlay:
            try await playEntries(
                entries,
                startIndex: 0,
                kind: kind,
                loadingState: loadingState,
                batchID: batchID,
                shuffleOverride: true,
                pickRandomFirstWhenShuffling: true
            )
            let snap = queueManager.makeSnapshot()
            return QueueCommandResult(
                queueID: snap.queueID,
                revision: snap.revision,
                destructiveEpoch: snap.destructiveEpoch,
                acceptedCount: entries.count,
                message: "已提交随机播放 \(entries.count) 首曲目"
            )

        case .interruptAndPlay:
            let safeIndex = min(max(0, startIndex), entries.count - 1)
            let ordered = safeIndex == 0 ? entries : ([entries[safeIndex]] + entries.enumerated().filter { $0.offset != safeIndex }.map(\.element))
            let head = try queueManager.interruptAndPlay(ordered, batchID: batchID)
            AppLogger.shared.log(
                category: .queue,
                level: .info,
                correlationID: queueCorrelationID,
                message: "立即插播: \(head.track.title) (批次 \(ordered.count) 首, 原待播保留)"
            )
            let target = PlaybackTarget(
                kind: .song,
                providerResourceID: head.track.providerTrackID.isEmpty ? head.track.id : head.track.providerTrackID,
                title: head.track.title
            )
            await initiatePlayback(for: head, target: target)
            let snap = queueManager.makeSnapshot()
            return QueueCommandResult(
                queueID: snap.queueID,
                revision: snap.revision,
                destructiveEpoch: snap.destructiveEpoch,
                acceptedCount: ordered.count,
                message: ordered.count == 1 ? "已立即插播「\(head.track.title)」" : "已立即插播 \(ordered.count) 首歌曲"
            )

        case .prepend:
            try await insertNext(entries, expectedQueueID: expectedQueueID, expectedDestructiveEpoch: expectedDestructiveEpoch, batchID: batchID)
            let snap = queueManager.makeSnapshot()
            return QueueCommandResult(
                queueID: snap.queueID,
                revision: snap.revision,
                destructiveEpoch: snap.destructiveEpoch,
                acceptedCount: entries.count,
                message: entries.count == 1 ? "已将「\(entries[0].track.title)」加入下一首" : "已将 \(entries.count) 首歌曲加入下一首"
            )

        case .append:
            try await append(entries, expectedQueueID: expectedQueueID, expectedDestructiveEpoch: expectedDestructiveEpoch, batchID: batchID)
            let snap = queueManager.makeSnapshot()
            return QueueCommandResult(
                queueID: snap.queueID,
                revision: snap.revision,
                destructiveEpoch: snap.destructiveEpoch,
                acceptedCount: entries.count,
                message: entries.count == 1 ? "已将「\(entries[0].track.title)」添加到队列末尾" : "已添加 \(entries.count) 首歌曲到队列"
            )
        }
    }

    /// Atomically transitions from a remote radio session to a staged local queue without auto-playing.
    /// Captures and invalidates the old remote playback generation before issuing `.stop` with the old context.
    @discardableResult
    public func switchRemoteToStagedLocal(
        entries: [QueueEntry],
        loadingState: QueueLoadingState? = nil,
        batchID: UUID? = nil,
        expectedQueueID: UUID? = nil,
        expectedDestructiveEpoch: UInt64? = nil,
        expectedSessionScope: String? = nil
    ) async throws -> QueueCommandResult {
        guard !entries.isEmpty else {
            throw QueueEditError.emptyBatch
        }
        for e in entries where e.origin.kind == .station {
            throw QueueEditError.remoteStationMixedNotAllowed
        }
        if let expectedSessionScope, queueManager.sessionScope != expectedSessionScope {
            throw QueueEditError.sessionMismatch
        }
        if let expectedQueueID, queueManager.queueID != expectedQueueID {
            throw QueueEditError.queueMismatch(expected: expectedQueueID, actual: queueManager.queueID)
        }
        if let expectedDestructiveEpoch, queueManager.destructiveEpoch != expectedDestructiveEpoch {
            throw QueueEditError.staleEpoch
        }

        let oldStopCtx = await currentContext(trackID: desiredTrack?.id ?? "")
        playbackGeneration &+= 1
        transportRevision &+= 1
        activePlayGeneration = playbackGeneration
        operationEntryMap.removeAll()
        desiredTrack = nil
        activeTargetResource = nil
        desiredTransport = .stopped
        pendingSeekSeconds = nil
        restoredNeedsEngineLoad = false
        needsPlayItemExecution = false
        needsPlayItemOnResume = false
        needsTransportSync = false
        lastEndedOperationKey = nil
        actualStatus = .idle
        timeAnchor = .zero

        let resolvedLoading = loadingState ?? .complete(totalCount: entries.count)
        _ = queueManager.replaceQueue(
            entries: entries,
            startIndex: 0,
            owner: .localCoordinator,
            target: nil,
            capabilities: .fullLocal,
            loadingState: resolvedLoading,
            batchID: batchID,
            startPlayback: false,
            shuffleOverride: false,
            using: &rngAdapter
        )

        AppLogger.shared.log(
            category: .queue,
            level: .info,
            correlationID: queueCorrelationID,
            message: "结束电台并原子暂存本地队列: \(entries.count) 首 (不自动播放)"
        )
        await publishToStore(includeQueue: true)
        scheduleDebouncedSnapshotSave(immediate: true)
        try? await engine.execute(.stop, context: oldStopCtx)

        let snap = queueManager.makeSnapshot()
        return QueueCommandResult(
            queueID: snap.queueID,
            revision: snap.revision,
            destructiveEpoch: snap.destructiveEpoch,
            acceptedCount: entries.count,
            message: entries.count == 1 ? "已结束电台并建立队列「\(entries[0].track.title)」" : "已结束电台并建立 \(entries.count) 首待播队列"
        )
    }

    // MARK: - Playback Intents

    public func playEntries(
        _ entries: [QueueEntry],
        startIndex: Int = 0,
        kind: PlayableKind? = nil,
        loadingState: QueueLoadingState? = nil,
        batchID: UUID? = nil,
        shuffleOverride: Bool? = nil,
        pickRandomFirstWhenShuffling: Bool = false
    ) async throws {
        guard !entries.isEmpty else { return }
        let safeIndex = min(max(0, startIndex), entries.count - 1)
        let selected = entries[safeIndex]
        let resolvedKind: PlayableKind = kind ?? .song
        let owner: QueueOwner = (resolvedKind == .station) ? .remoteEngine : .localCoordinator
        if owner == .remoteEngine {
            guard entries.count == 1 else {
                throw QueueEditError.remoteStationMixedNotAllowed
            }
        } else {
            for e in entries where e.origin.kind == .station {
                throw QueueEditError.remoteStationMixedNotAllowed
            }
        }
        let resolvedLoading = loadingState ?? .complete(totalCount: entries.count)
        let resourceID: String
        let resolvedCaps: QueueCapabilities
        if resolvedKind == .station {
            let stationID = selected.origin.stationContext?.stationID
                ?? selected.origin.sourceID
                ?? (selected.track.providerTrackID.isEmpty ? selected.track.id : selected.track.providerTrackID)
            guard !stationID.isEmpty else {
                throw QueueEditError.invalidTarget(selected.id)
            }
            resourceID = stationID
            switch selected.origin.stationContext?.stationType ?? .unknown {
            case .algorithmic:
                resolvedCaps = .remoteStationAlgorithmic
            case .live:
                resolvedCaps = .remoteStationLive
            case .unknown:
                resolvedCaps = .remoteStationUnknown
            }
        } else {
            resourceID = selected.track.providerTrackID.isEmpty ? selected.track.id : selected.track.providerTrackID
            resolvedCaps = .fullLocal
        }
        let initialTarget = PlaybackTarget(
            kind: resolvedKind,
            providerResourceID: resourceID,
            title: selected.track.title,
            storefront: activeSession?.storefront
        )

        guard let chosen = queueManager.replaceQueue(
            entries: entries,
            startIndex: safeIndex,
            owner: owner,
            target: initialTarget,
            capabilities: resolvedCaps,
            loadingState: resolvedLoading,
            batchID: batchID,
            startPlayback: true,
            shuffleOverride: shuffleOverride,
            pickRandomFirstWhenShuffling: pickRandomFirstWhenShuffling,
            using: &rngAdapter
        ) else { return }

        let chosenResourceID: String
        if resolvedKind == .station {
            chosenResourceID = chosen.origin.sourceID ?? (chosen.track.providerTrackID.isEmpty ? chosen.track.id : chosen.track.providerTrackID)
        } else {
            chosenResourceID = chosen.track.providerTrackID.isEmpty ? chosen.track.id : chosen.track.providerTrackID
        }
        let target = PlaybackTarget(
            kind: resolvedKind,
            providerResourceID: chosenResourceID,
            title: chosen.track.title,
            storefront: activeSession?.storefront
        )

        AppLogger.shared.log(
            category: .queue,
            level: .info,
            correlationID: queueCorrelationID,
            message: "新建队列并播放: \(chosen.track.title) (共 \(entries.count) 首, startIndex=\(safeIndex), owner=\(owner.rawValue), 来源=\(chosen.origin.displayTitle))"
        )
        await initiatePlayback(for: chosen, target: target)
    }

    public func playTrack(_ track: MusicTrack, in queue: PlaybackQueue, kind: PlayableKind? = nil, startIndex: Int = 0) async throws {
        let entries: [QueueEntry]
        let effectiveIndex: Int
        if queue.entries.isEmpty {
            entries = [QueueEntry(track: track, origin: .unknown)]
            effectiveIndex = 0
        } else {
            entries = queue.entries
            if let idx = queue.currentIndex, entries.indices.contains(idx), entries[idx].track.id == track.id {
                effectiveIndex = idx
            } else if let idx = entries.firstIndex(where: { $0.track.id == track.id }) {
                effectiveIndex = idx
            } else {
                effectiveIndex = min(max(0, startIndex), entries.count - 1)
            }
        }
        if kind == .station {
            let single = entries[effectiveIndex]
            try await playEntries([single], startIndex: 0, kind: .station)
        } else {
            try await playEntries(entries, startIndex: effectiveIndex, kind: kind)
        }
    }

    public func play() async throws {
        // 1. Failed target -> explicit retry
        if queueManager.isPendingTargetFailed {
            try await retryPendingOrCurrent()
            return
        }

        // 2. Idle or exhausted queue with newly appended upcoming entries -> consume first upcoming
        if desiredTrack == nil || queueManager.playbackPhase == .exhausted {
            if case .play(let entry, _) = queueManager.advanceNext(using: &rngAdapter) {
                let target = PlaybackTarget(
                    kind: .song,
                    providerResourceID: entry.track.providerTrackID.isEmpty ? entry.track.id : entry.track.providerTrackID,
                    title: entry.track.title
                )
                await initiatePlayback(for: entry, target: target)
                return
            }
            // Exhausted with no new upcoming -> replay current/last track from 0
            if queueManager.playbackPhase == .exhausted, let current = queueManager.activeTargetEntry {
                let target = activeTargetResource ?? PlaybackTarget(
                    kind: queueManager.owner == .remoteEngine ? .station : .song,
                    providerResourceID: current.track.providerTrackID.isEmpty ? current.track.id : current.track.providerTrackID,
                    title: current.track.title
                )
                await initiatePlayback(for: current, target: target)
                return
            }
            return
        }

        // 3. Restored from snapshot or paused before engine loaded playItem -> load via playItem
        if (restoredNeedsEngineLoad || needsPlayItemOnResume), let entry = queueManager.activeTargetEntry {
            restoredNeedsEngineLoad = false
            needsPlayItemOnResume = false
            let isStation = (queueManager.owner == .remoteEngine)
            let target = activeTargetResource ?? PlaybackTarget(
                kind: isStation ? .station : .song,
                providerResourceID: entry.track.providerTrackID.isEmpty ? entry.track.id : entry.track.providerTrackID,
                title: entry.track.title
            )
            let resumePosSec = (!isStation && timeAnchor.positionMs > 0) ? Double(timeAnchor.positionMs) / 1000.0 : nil
            await initiatePlayback(for: entry, target: target, initialSeekSeconds: resumePosSec)
            return
        }

        // 4. Normal resume from pause / user stop
        transportRevision &+= 1
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
        if queueManager.owner == .remoteEngine {
            guard queueManager.capabilities.canPause else {
                AppLogger.shared.log(category: .queue, level: .warn, correlationID: queueCorrelationID, message: "拒绝暂停: 当前电台能力不支持暂停")
                throw QueueEditError.unsupportedCapability("当前电台不支持暂停")
            }
        }
        transportRevision &+= 1
        desiredTransport = .paused
        if needsPlayItemExecution {
            needsPlayItemExecution = false
            needsPlayItemOnResume = true
        }
        needsTransportSync = true
        actualStatus = .paused
        queueManager.setPlaybackPhase(.paused)
        let currentPos = timeAnchor.interpolatedPositionMs(at: clock.monotonicNanoseconds)
        timeAnchor = PlaybackTimeAnchor(positionMs: currentPos, durationMs: timeAnchor.durationMs, monotonicNs: clock.monotonicNanoseconds, isPlaying: false)
        await publishToStore(includeQueue: false)
        scheduleDebouncedSnapshotSave(immediate: false)
        await drainCommands()
    }

    public func stop() async throws {
        playbackGeneration &+= 1
        transportRevision &+= 1
        activePlayGeneration = playbackGeneration
        desiredTransport = .stopped
        needsPlayItemExecution = false
        needsPlayItemOnResume = false
        needsTransportSync = true
        actualStatus = .idle
        queueManager.clearPendingOnStop()
        timeAnchor = PlaybackTimeAnchor(positionMs: 0, durationMs: 0, monotonicNs: clock.monotonicNanoseconds, isPlaying: false)
        await publishToStore(includeQueue: true)
        await drainCommands()
    }

    public func seek(toMs ms: Int64) async throws {
        if queueManager.owner == .remoteEngine {
            guard queueManager.capabilities.canSeek else {
                AppLogger.shared.log(category: .queue, level: .warn, correlationID: queueCorrelationID, message: "拒绝进度跳转: 当前电台能力不支持 seek")
                throw QueueEditError.unsupportedCapability("当前电台不支持快进/快退")
            }
        }
        transportRevision &+= 1
        let clampedMs = max(0, ms)
        pendingSeekSeconds = Double(clampedMs) / 1000.0
        timeAnchor = PlaybackTimeAnchor(
            positionMs: clampedMs,
            durationMs: timeAnchor.durationMs,
            monotonicNs: clock.monotonicNanoseconds,
            isPlaying: desiredTransport == .playing && actualStatus == .playing
        )
        await publishToStore(includeQueue: false)
        await drainCommands()
    }

    public func setVolume(_ volume: Float) async throws {
        let clamped = min(max(volume, 0), 1)
        desiredVolume = clamped
        let ctx = await currentContext(trackID: desiredTrack?.id ?? "")
        try? await engine.execute(.setVolume(clamped), context: ctx)
        await publishToStore(includeQueue: false)
    }

    public func setRepeatMode(_ mode: PlaybackState.RepeatMode) async {
        guard (mode == .one && queueManager.capabilities.canRepeatOne) ||
              (mode == .all && queueManager.capabilities.canRepeatAll) ||
              mode == .off else {
            return
        }
        queueManager.setRepeatMode(mode)
        AppLogger.shared.log(
            category: .queue,
            level: .info,
            correlationID: queueCorrelationID,
            message: "切换循环模式: \(mode.rawValue)"
        )
        await publishToStore(includeQueue: true)
        scheduleDebouncedSnapshotSave(immediate: true)
    }

    public func setShuffleEnabled(_ enabled: Bool) async {
        guard queueManager.capabilities.canToggleShuffle || !enabled else {
            return
        }
        queueManager.setShuffleEnabled(enabled, using: &rngAdapter)
        AppLogger.shared.log(
            category: .queue,
            level: .info,
            correlationID: queueCorrelationID,
            message: "切换随机播放: \(enabled ? "开启" : "关闭") (effective=\(queueManager.effectiveShuffle), 待播 \(queueManager.upcomingEntries.count) 首)"
        )
        await publishToStore(includeQueue: true)
        scheduleDebouncedSnapshotSave(immediate: true)
    }

    public func skipToNext() async throws {
        if queueManager.owner == .remoteEngine {
            guard queueManager.capabilities.canSkipNext else {
                AppLogger.shared.log(category: .queue, level: .warn, correlationID: queueCorrelationID, message: "拒绝下一首: 当前电台能力不支持跳过")
                throw QueueEditError.unsupportedCapability("当前电台不支持下一首")
            }
            AppLogger.shared.log(category: .queue, level: .info, correlationID: queueCorrelationID, message: "远端电台切换下一首")
            let ctx = await currentContext(trackID: desiredTrack?.id ?? "")
            try await engine.execute(.skipNext, context: ctx)
            return
        }
        switch queueManager.advanceNext(using: &rngAdapter) {
        case .play(let next, _):
            AppLogger.shared.log(category: .queue, level: .info, correlationID: queueCorrelationID, message: "下一首推进: \(next.track.title) (剩余待播 \(queueManager.upcomingEntries.count) 首)")
            let target = PlaybackTarget(
                kind: .song,
                providerResourceID: next.track.providerTrackID.isEmpty ? next.track.id : next.track.providerTrackID,
                title: next.track.title
            )
            await initiatePlayback(for: next, target: target)
        case .waitingForPage(let bid):
            AppLogger.shared.log(category: .queue, level: .info, correlationID: queueCorrelationID, message: "到达未加载分页边界 (\(bid.uuidString.prefix(6)))，等待后续页加载")
            await publishToStore(includeQueue: true)
        case .exhausted, .seekToZero, .stop:
            AppLogger.shared.log(category: .queue, level: .info, correlationID: queueCorrelationID, message: "待播队列已耗尽")
            desiredTransport = .stopped
            actualStatus = .idle
            await publishToStore(includeQueue: true)
            let ctx = await currentContext(trackID: desiredTrack?.id ?? "")
            try? await engine.execute(.stop, context: ctx)
        }
    }

    public func skipToPrevious() async throws {
        if queueManager.owner == .remoteEngine {
            guard queueManager.capabilities.canSkipPrevious else {
                AppLogger.shared.log(category: .queue, level: .warn, correlationID: queueCorrelationID, message: "拒绝上一首: 当前电台能力不支持回退")
                throw QueueEditError.unsupportedCapability("当前电台不支持上一首")
            }
            let ctx = await currentContext(trackID: desiredTrack?.id ?? "")
            try await engine.execute(.skipPrevious, context: ctx)
            return
        }
        let currentPos = timeAnchor.interpolatedPositionMs(at: clock.monotonicNanoseconds)
        switch queueManager.retreatPrevious(positionMs: currentPos) {
        case .seekToZero:
            AppLogger.shared.log(category: .queue, level: .info, correlationID: queueCorrelationID, message: "上一首: 回到当前曲目开头 (pos=\(currentPos)ms)")
            try await seek(toMs: 0)
        case .play(let prev, _):
            AppLogger.shared.log(category: .queue, level: .info, correlationID: queueCorrelationID, message: "上一首回退历史: \(prev.track.title) (剩余历史 \(queueManager.historyEntries.count) 首)")
            let target = PlaybackTarget(
                kind: .song,
                providerResourceID: prev.track.providerTrackID.isEmpty ? prev.track.id : prev.track.providerTrackID,
                title: prev.track.title
            )
            await initiatePlayback(for: prev, target: target)
        case .waitingForPage, .exhausted, .stop:
            break
        }
    }

    public func retryPendingOrCurrent() async throws {
        guard let entry = queueManager.activeTargetEntry else { return }
        let isStation = (queueManager.owner == .remoteEngine)
        let target = activeTargetResource ?? PlaybackTarget(
            kind: isStation ? .station : .song,
            providerResourceID: entry.track.providerTrackID.isEmpty ? entry.track.id : entry.track.providerTrackID,
            title: entry.track.title,
            storefront: activeSession?.storefront
        )
        AppLogger.shared.log(category: .queue, level: .info, correlationID: queueCorrelationID, message: "重试播放目标: \(target.providerResourceID) (kind=\(target.kind.rawValue))")
        await initiatePlayback(for: entry, target: target)
    }

    public func skipFailedTarget() async throws {
        try await skipToNext()
    }

    public func advancePastWaitingBatch() async throws {
        if queueManager.owner == .remoteEngine {
            AppLogger.shared.log(category: .queue, level: .info, correlationID: queueCorrelationID, message: "远端电台播放结束事件: 停止传输 (不执行本地推进)")
            desiredTransport = .stopped
            actualStatus = .idle
            queueManager.setPlaybackPhase(.exhausted)
            await publishToStore(includeQueue: true)
            return
        }
        guard queueManager.owner == .localCoordinator else { return }
        if case .play(let next, _) = queueManager.advanceNext(using: &rngAdapter, allowCrossBatchBoundary: true) {
            let target = PlaybackTarget(
                kind: .song,
                providerResourceID: next.track.providerTrackID.isEmpty ? next.track.id : next.track.providerTrackID,
                title: next.track.title
            )
            await initiatePlayback(for: next, target: target)
        } else {
            try await stop()
        }
    }

    // MARK: - Queue Editing API (Single Authoritative Writer)

    public func insertNext(
        _ entries: [QueueEntry],
        expectedQueueID: UUID? = nil,
        expectedRevision: UInt64? = nil,
        expectedDestructiveEpoch: UInt64? = nil,
        batchID: UUID? = nil
    ) async throws {
        if queueManager.owner == .remoteEngine {
            throw QueueEditError.remoteQueueRequiresSwitch(stationTitle: queueManager.activeTargetEntry?.track.title)
        }
        try queueManager.validateEditContext(
            expectedQueueID: expectedQueueID,
            expectedRevision: expectedRevision,
            expectedDestructiveEpoch: expectedDestructiveEpoch
        )
        try queueManager.insertNext(entries, batchID: batchID)
        AppLogger.shared.log(
            category: .queue,
            level: .info,
            correlationID: queueCorrelationID,
            message: "插入下一首: \(entries.count) 首 (首曲: \(entries.first?.track.title ?? "-"), 待播共 \(queueManager.upcomingEntries.count) 首)"
        )
        await publishToStore(includeQueue: true)
        scheduleDebouncedSnapshotSave(immediate: true)
    }

    public func append(
        _ entries: [QueueEntry],
        expectedQueueID: UUID? = nil,
        expectedRevision: UInt64? = nil,
        expectedDestructiveEpoch: UInt64? = nil,
        batchID: UUID? = nil
    ) async throws {
        if queueManager.owner == .remoteEngine {
            throw QueueEditError.remoteQueueRequiresSwitch(stationTitle: queueManager.activeTargetEntry?.track.title)
        }
        try queueManager.validateEditContext(
            expectedQueueID: expectedQueueID,
            expectedRevision: expectedRevision,
            expectedDestructiveEpoch: expectedDestructiveEpoch
        )
        try queueManager.append(entries, batchID: batchID)
        AppLogger.shared.log(
            category: .queue,
            level: .info,
            correlationID: queueCorrelationID,
            message: "追加到队列末尾: \(entries.count) 首 (首曲: \(entries.first?.track.title ?? "-"), 待播共 \(queueManager.upcomingEntries.count) 首)"
        )
        await publishToStore(includeQueue: true)
        scheduleDebouncedSnapshotSave(immediate: true)
    }

    public func playEntry(id: UUID, expectedQueueID: UUID? = nil) async throws {
        try queueManager.validateEditContext(expectedQueueID: expectedQueueID)
        let result = try queueManager.playEntry(id: id)
        if let targetEntry = result.playbackTarget {
            AppLogger.shared.log(
                category: .queue,
                level: .info,
                correlationID: queueCorrelationID,
                message: "指定播放待播条目: \(targetEntry.track.title) (entry=\(id.uuidString.prefix(6)), 剩余待播 \(queueManager.upcomingEntries.count) 首)"
            )
            let target = PlaybackTarget(
                kind: .song,
                providerResourceID: targetEntry.track.providerTrackID.isEmpty ? targetEntry.track.id : targetEntry.track.providerTrackID,
                title: targetEntry.track.title
            )
            await initiatePlayback(for: targetEntry, target: target)
        }
    }

    public func removeEntries(ids: [UUID], expectedQueueID: UUID? = nil) async throws {
        try queueManager.validateEditContext(expectedQueueID: expectedQueueID)
        try queueManager.removeEntries(ids: ids)
        AppLogger.shared.log(
            category: .queue,
            level: .info,
            correlationID: queueCorrelationID,
            message: "移除待播条目: \(ids.count) 首 (剩余待播 \(queueManager.upcomingEntries.count) 首)"
        )
        await publishToStore(includeQueue: true)
        scheduleDebouncedSnapshotSave(immediate: true)
    }

    public func moveEntries(ids: [UUID], before targetID: UUID?, expectedQueueID: UUID? = nil) async throws {
        try queueManager.validateEditContext(expectedQueueID: expectedQueueID)
        try queueManager.moveEntries(ids: ids, before: targetID)
        let targetDesc = targetID.map { String($0.uuidString.prefix(6)) } ?? "末尾"
        AppLogger.shared.log(
            category: .queue,
            level: .info,
            correlationID: queueCorrelationID,
            message: "重排待播条目: 移动 \(ids.count) 首至 \(targetDesc)"
        )
        await publishToStore(includeQueue: true)
        scheduleDebouncedSnapshotSave(immediate: true)
    }

    public func clearUpcoming(expectedQueueID: UUID? = nil) async throws {
        try queueManager.validateEditContext(expectedQueueID: expectedQueueID)
        let prevCount = queueManager.upcomingEntries.count
        try queueManager.clearUpcoming()
        AppLogger.shared.log(
            category: .queue,
            level: .info,
            correlationID: queueCorrelationID,
            message: "清空待播队列: 已移除 \(prevCount) 首 (当前播放保持不变)"
        )
        await publishToStore(includeQueue: true)
        scheduleDebouncedSnapshotSave(immediate: true)
    }

    public func undoLastQueueEdit(expectedQueueID: UUID) async throws {
        try queueManager.undo(expectedQueueID: expectedQueueID, expectedSessionScope: queueManager.sessionScope)
        AppLogger.shared.log(
            category: .queue,
            level: .info,
            correlationID: queueCorrelationID,
            message: "撤销队列编辑成功 (恢复后待播 \(queueManager.upcomingEntries.count) 首)"
        )
        await publishToStore(includeQueue: true)
        scheduleDebouncedSnapshotSave(immediate: true)
    }

    // MARK: - Pagination & Remote Capability Updates

    @discardableResult
    public func commitPaginatedBatch(
        _ entries: [QueueEntry],
        batchID: UUID,
        expectedQueueID: UUID,
        expectedSessionScope: String,
        expectedDestructiveEpoch: UInt64? = nil,
        loadingState: QueueLoadingState
    ) async -> Bool {
        let wasWaiting = (queueManager.playbackPhase == .waitingForPage)
        let ok = queueManager.commitPaginatedBatch(
            entries,
            batchID: batchID,
            expectedQueueID: expectedQueueID,
            expectedSessionScope: expectedSessionScope,
            expectedDestructiveEpoch: expectedDestructiveEpoch,
            loadingState: loadingState,
            using: &rngAdapter
        )
        guard ok else { return false }

        // If playback was waiting at the batch boundary, resume automatically now that tracks arrived
        if wasWaiting, desiredTransport == .playing,
           case .play(let next, _) = queueManager.advanceNext(using: &rngAdapter) {
            let target = PlaybackTarget(
                kind: .song,
                providerResourceID: next.track.providerTrackID.isEmpty ? next.track.id : next.track.providerTrackID,
                title: next.track.title
            )
            await initiatePlayback(for: next, target: target)
            return true
        }

        await publishToStore(includeQueue: true)
        scheduleDebouncedSnapshotSave(immediate: false)
        return true
    }

    public func updateQueueLoadingState(
        _ state: QueueLoadingState,
        expectedQueueID: UUID,
        expectedSessionScope: String,
        expectedDestructiveEpoch: UInt64? = nil,
        batchID: UUID? = nil
    ) async {
        guard queueManager.queueID == expectedQueueID,
              queueManager.sessionScope == expectedSessionScope else { return }
        if let expectedDestructiveEpoch, expectedDestructiveEpoch != queueManager.destructiveEpoch {
            return
        }
        if let batchID {
            queueManager.finishOrFailBatch(batchID, loadingState: state)
        } else {
            queueManager.updateLoadingState(state)
        }
        await publishToStore(includeQueue: true)
    }

    public func updateRemoteCapabilities(_ capabilities: QueueCapabilities) async {
        guard queueManager.owner == .remoteEngine else { return }
        queueManager.updateCapabilities(capabilities)
        await publishToStore(includeQueue: true)
    }

    // MARK: - Snapshots & Streams

    public func currentSnapshotState() async -> PlaybackState {
        await store.state
    }

    public func currentStructuredQueueSnapshot() -> QueueSnapshot {
        queueManager.makeSnapshot()
    }

    public func currentQueueSnapshot() -> PlaybackQueue {
        var entries: [QueueEntry] = []
        var idx: Int?
        if let active = queueManager.activeTargetEntry {
            entries.append(active)
            idx = 0
        }
        entries.append(contentsOf: queueManager.upcomingEntries)
        return PlaybackQueue(entries: entries, currentIndex: idx)
    }

    public func queueStream() async -> AsyncStream<QueueSnapshot> {
        await store.queueStream()
    }

    // MARK: - Persistence (Q17, P0-01)

    public func restoreSnapshotIfNeeded(providerID: String, accountID: String?) async {
        guard let snapshotStore else { return }
        let scope = "\(providerID)|\(accountID ?? "guest")"
        guard hasRestoredForScope != scope else { return }
        guard queueManager.activeTargetEntry == nil, queueManager.upcomingEntries.isEmpty else {
            hasRestoredForScope = scope
            return
        }

        // Capture pre-await invariants (P0-01)
        let preScope = queueManager.sessionScope
        let prePlayGen = playbackGeneration
        let preEpoch = queueManager.destructiveEpoch
        let preQueueID = queueManager.queueID
        let preRevision = queueManager.revision

        let snap = await snapshotStore.load(expectedProviderID: providerID, expectedAccountID: accountID)

        // Re-verify post-await invariants before mutating state
        guard queueManager.sessionScope == preScope,
              playbackGeneration == prePlayGen,
              queueManager.destructiveEpoch == preEpoch,
              queueManager.queueID == preQueueID,
              queueManager.revision == preRevision,
              queueManager.activeTargetEntry == nil,
              queueManager.upcomingEntries.isEmpty else {
            return
        }

        hasRestoredForScope = scope
        guard let snap, let payload = snap.resolvedQueuePayload() else {
            return
        }

        let restoredCurrent = queueManager.restore(from: payload, sessionScope: queueManager.sessionScope)
        desiredVolume = min(max(snap.volume, 0), 1)
        desiredTrack = restoredCurrent?.track
        activeTargetResource = queueManager.makeSnapshot().activeTarget
        desiredTransport = .paused
        actualStatus = restoredCurrent != nil ? .paused : .idle
        restoredNeedsEngineLoad = (restoredCurrent != nil)
        let durMs = restoredCurrent?.track.durationMs ?? 0
        let clampedPos = (payload.owner == .remoteEngine) ? 0 : (durMs > 0 ? min(max(0, snap.positionMs), durMs) : max(0, snap.positionMs))
        timeAnchor = PlaybackTimeAnchor(positionMs: clampedPos, durationMs: durMs, monotonicNs: clock.monotonicNanoseconds, isPlaying: false)

        await publishToStore(includeQueue: true)
        AppLogger.shared.log(
            category: .queue,
            level: .info,
            correlationID: queueCorrelationID,
            message: "从本地快照暂停恢复队列: \(restoredCurrent?.track.title ?? "无当前曲目") (待播 \(queueManager.upcomingEntries.count) 首, pos=\(clampedPos)ms, account=\(accountID ?? "guest"))"
        )
    }

    public func flushSnapshot() async {
        guard let snapshotStore, let session = activeSession else { return }
        let expectedScope = Self.sessionScope(for: session)
        guard queueManager.sessionScope == expectedScope else { return }

        let payload = queueManager.exportPersistencePayload()
        guard payload.currentEntryID != nil || !payload.upcomingOrder.isEmpty else {
            await snapshotStore.clear()
            return
        }
        let posMs = timeAnchor.interpolatedPositionMs(at: clock.monotonicNanoseconds)
        let snap = PlaybackSnapshot(
            providerID: session.providerID,
            accountID: session.accountID,
            storefront: session.storefront,
            queueTracks: [],
            currentIndex: 0,
            queuePayload: payload,
            positionMs: posMs,
            volume: desiredVolume,
            repeatMode: payload.repeatMode,
            shuffleEnabled: payload.shuffleEnabled,
            savedAt: clock.now
        )
        try? await snapshotStore.save(snap)
    }

    private func scheduleDebouncedSnapshotSave(immediate: Bool) {
        guard snapshotStore != nil, activeSession != nil else { return }
        if !immediate {
            let now = clock.monotonicNanoseconds
            if now &- lastProgressSnapshotSaveNs < 10_000_000_000 {
                return
            }
            lastProgressSnapshotSaveNs = now
        }
        snapshotSaveTask?.cancel()
        snapshotSaveTask = Task { [weak self] in
            if !immediate {
                try? await Task.sleep(for: .milliseconds(350))
            }
            guard !Task.isCancelled, let self else { return }
            await self.flushSnapshot()
        }
    }

    // MARK: - Internal Playback Initiation & Drain (P0-03, P0-04)

    private func initiatePlayback(
        for entry: QueueEntry,
        target: PlaybackTarget,
        initialSeekSeconds: Double? = nil
    ) async {
        playbackGeneration &+= 1
        activePlayGeneration = playbackGeneration
        recordOperationEntry(gen: playbackGeneration, entryID: entry.id)

        restoredNeedsEngineLoad = false
        needsPlayItemOnResume = false
        desiredTrack = entry.track
        activeTargetResource = target
        desiredTransport = .playing
        pendingSeekSeconds = initialSeekSeconds
        actualStatus = .preparing
        timeAnchor = PlaybackTimeAnchor(
            positionMs: initialSeekSeconds.map { Int64($0 * 1000) } ?? 0,
            durationMs: entry.track.durationMs,
            monotonicNs: clock.monotonicNanoseconds,
            isPlaying: false
        )
        needsPlayItemExecution = true
        needsTransportSync = false

        await publishToStore(includeQueue: true)
        scheduleDebouncedSnapshotSave(immediate: true)
        await drainCommands()
    }

    private func recordOperationEntry(gen: UInt64, entryID: UUID) {
        operationEntryMap[gen] = entryID
        if operationEntryMap.count > 64, let oldestKey = operationEntryMap.keys.min() {
            operationEntryMap.removeValue(forKey: oldestKey)
        }
    }

    private func drainCommands() async {
        guard !isDraining else { return }
        isDraining = true
        defer { isDraining = false }

        while needsPlayItemExecution || needsTransportSync || pendingSeekSeconds != nil {
            let sessionID = activeSession?.sessionID ?? UUID(uuidString: "00000000-0000-0000-0000-000000000000")!
            let engineID = await engine.engineInstanceID

            if needsPlayItemExecution, let target = activeTargetResource, desiredTransport == .playing {
                needsPlayItemExecution = false
                let targetGen = playbackGeneration
                let ctx = PlaybackOperationContext(
                    sessionID: sessionID,
                    engineInstanceID: engineID,
                    operationID: targetGen,
                    trackID: target.providerResourceID
                )

                do {
                    try await engine.execute(.playItem(id: target.providerResourceID, kind: target.kind, startIndex: 0), context: ctx)
                } catch {
                    if targetGen == playbackGeneration {
                        actualStatus = .failed(error.localizedDescription)
                        queueManager.markPendingFailed()
                        await publishToStore(includeQueue: true)
                    }
                }
                if targetGen != playbackGeneration {
                    continue
                }
            }

            if let seekSec = pendingSeekSeconds {
                pendingSeekSeconds = nil
                let targetGen = playbackGeneration
                let targetRev = transportRevision
                let ctx = PlaybackOperationContext(sessionID: sessionID, engineInstanceID: engineID, operationID: targetGen, trackID: desiredTrack?.id ?? "")
                try? await engine.execute(.seek(seconds: seekSec), context: ctx)
                if targetGen != playbackGeneration || targetRev != transportRevision {
                    continue
                }
            }

            if needsTransportSync {
                needsTransportSync = false
                let targetGen = playbackGeneration
                let ctx = PlaybackOperationContext(sessionID: sessionID, engineInstanceID: engineID, operationID: targetGen, trackID: desiredTrack?.id ?? "")
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
            guard ctx.engineInstanceID == currentEngineID, ctx.operationID == activePlayGeneration else { return }
            if desiredTransport == .paused && status == .playing { return }
            if desiredTransport == .stopped && status != .idle { return }
            let nowNs = clock.monotonicNanoseconds
            let currentPos = timeAnchor.interpolatedPositionMs(at: nowNs)

            if case .failed(let msg) = status {
                actualStatus = .failed(msg)
                queueManager.markPendingFailed()
                timeAnchor = PlaybackTimeAnchor(positionMs: currentPos, durationMs: timeAnchor.durationMs, monotonicNs: nowNs, isPlaying: false)
                await publishToStore(includeQueue: true)
                return
            }

            var queueChanged = false
            if status == .playing,
               let entryID = operationEntryMap[ctx.operationID],
               queueManager.pendingReservationID == entryID {
                queueManager.confirmEntry(entryID)
                queueChanged = true
            }

            actualStatus = status
            timeAnchor = PlaybackTimeAnchor(
                positionMs: currentPos,
                durationMs: timeAnchor.durationMs,
                monotonicNs: nowNs,
                isPlaying: status == .playing
            )
            await publishToStore(includeQueue: queueChanged)

        case .positionUpdated(let ctx, let posSec, let durSec):
            guard ctx.engineInstanceID == currentEngineID, ctx.operationID == activePlayGeneration else { return }
            let posMs = Int64(max(0, posSec) * 1000)
            let durMs = durSec > 0 ? Int64(durSec * 1000) : timeAnchor.durationMs
            timeAnchor = PlaybackTimeAnchor(
                positionMs: posMs,
                durationMs: durMs,
                monotonicNs: clock.monotonicNanoseconds,
                isPlaying: actualStatus == .playing
            )
            // High-frequency position updates NEVER republish QueueSnapshot
            await publishToStore(includeQueue: false)
            scheduleDebouncedSnapshotSave(immediate: false)

        case .itemChanged(let ctx, let trackID, let title, let artist, let albumTitle, let artworkURL, let durSec):
            guard ctx.engineInstanceID == currentEngineID, ctx.operationID == activePlayGeneration else { return }
            let nowNs = clock.monotonicNanoseconds
            var didMutateState = false
            var didMutateQueue = false

            if queueManager.owner == .remoteEngine, !title.isEmpty, let current = desiredTrack {
                let idChanged = !trackID.isEmpty && !current.providerTrackID.isEmpty && current.providerTrackID != trackID
                let titleChanged = current.title != title
                let trackChanged = idChanged || titleChanged
                let effectiveID = trackID.isEmpty ? (trackChanged ? title : current.id) : trackID
                let effectiveArtist = trackChanged ? artist : (artist.isEmpty ? current.artistName : artist)
                let effectiveAlbum = trackChanged ? albumTitle : (albumTitle.isEmpty ? current.albumTitle : albumTitle)
                let effectiveArt = trackChanged ? URL(string: artworkURL) : (URL(string: artworkURL) ?? current.artworkURL)
                let effectiveDurMs = trackChanged ? (durSec > 0 ? Int64(durSec * 1000) : 0) : (durSec > 0 ? Int64(durSec * 1000) : current.durationMs)
                let updatedTrack = MusicTrack(
                    id: effectiveID,
                    title: title,
                    artistName: effectiveArtist,
                    albumTitle: effectiveAlbum,
                    durationMs: effectiveDurMs,
                    artworkURL: effectiveArt,
                    providerID: current.providerID,
                    providerTrackID: effectiveID
                )
                desiredTrack = updatedTrack
                // NOTE: activeTargetResource stays pointing to the original station ID! (P0-04)
                queueManager.updateRemoteCurrentTrack(updatedTrack)
                AppLogger.shared.log(
                    category: .queue,
                    level: .info,
                    correlationID: queueCorrelationID,
                    message: trackChanged
                        ? "远端电台切歌元数据更新: \(title) (trackID=\(effectiveID), station=\(activeTargetResource?.providerResourceID ?? "-"), 缺失字段已置空)"
                        : "远端电台同曲元数据增量补全: \(title) (trackID=\(effectiveID))"
                )
                timeAnchor = PlaybackTimeAnchor(
                    positionMs: trackChanged ? 0 : timeAnchor.interpolatedPositionMs(at: nowNs),
                    durationMs: effectiveDurMs,
                    monotonicNs: nowNs,
                    isPlaying: actualStatus == .playing
                )
                didMutateState = true
                didMutateQueue = true
            } else if durSec > 0 {
                timeAnchor = PlaybackTimeAnchor(
                    positionMs: timeAnchor.interpolatedPositionMs(at: nowNs),
                    durationMs: Int64(durSec * 1000),
                    monotonicNs: nowNs,
                    isPlaying: actualStatus == .playing
                )
                didMutateState = true
            }
            if didMutateState {
                await publishToStore(includeQueue: didMutateQueue)
            }

        case .trackEnded(let ctx, _, _):
            guard ctx.engineInstanceID == currentEngineID, ctx.operationID == activePlayGeneration else { return }
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
            await publishToStore(includeQueue: false)
        }
    }

    // MARK: - Helpers

    private func handleNaturalTrackEnd(operationID opID: UInt64, trackID: String) async {
        let dedupKey = "\(opID)|\(trackID)"
        guard lastEndedOperationKey != dedupKey else { return }
        lastEndedOperationKey = dedupKey

        if queueManager.owner == .remoteEngine {
            AppLogger.shared.log(category: .queue, level: .info, correlationID: queueCorrelationID, message: "远端电台播放结束事件: 停止传输 (不执行本地推进)")
            desiredTransport = .stopped
            actualStatus = .idle
            queueManager.setPlaybackPhase(.exhausted)
            await publishToStore(includeQueue: true)
            return
        }
        guard queueManager.owner == .localCoordinator else { return }
        // Only advance if the ended operation corresponds to the current active entry
        guard let endedEntryID = operationEntryMap[opID] else { return }
        if queueManager.pendingReservationID == endedEntryID {
            // Confirming a track that finished without an explicit stateChanged(.playing) only if it wasn't failed
            guard !queueManager.isPendingTargetFailed else { return }
            queueManager.confirmEntry(endedEntryID)
        } else if queueManager.confirmedCurrentID != endedEntryID {
            return
        }

        switch queueManager.advanceOnNaturalEnd(using: &rngAdapter) {
        case .play(let next, _):
            let target = PlaybackTarget(
                kind: .song,
                providerResourceID: next.track.providerTrackID.isEmpty ? next.track.id : next.track.providerTrackID,
                title: next.track.title
            )
            await initiatePlayback(for: next, target: target)
        case .waitingForPage:
            await publishToStore(includeQueue: true)
        case .exhausted, .seekToZero, .stop:
            desiredTransport = .stopped
            actualStatus = .idle
            await publishToStore(includeQueue: true)
            let ctx = await currentContext(trackID: desiredTrack?.id ?? "")
            try? await engine.execute(.stop, context: ctx)
        }
    }

    private var queueCorrelationID: String {
        "q-\(queueManager.queueID.uuidString.prefix(6))-r\(queueManager.revision)"
    }

    private func currentContext(trackID: String) async -> PlaybackOperationContext {
        let sid = activeSession?.sessionID ?? UUID(uuidString: "00000000-0000-0000-0000-000000000000")!
        let eid = await engine.engineInstanceID
        return PlaybackOperationContext(sessionID: sid, engineInstanceID: eid, operationID: playbackGeneration, trackID: trackID)
    }

    private static func sessionScope(for session: SessionContext?) -> String {
        guard let session else { return "" }
        return "\(session.providerID)|\(session.accountID)|\(session.sessionID.uuidString)|\(session.generation)"
    }

    private func publishToStore(includeQueue: Bool) async {
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
            repeatMode: queueManager.repeatMode,
            shuffleEnabled: queueManager.effectiveShuffle,
            currentTrack: desiredTrack,
            providerID: desiredTrack?.providerID ?? "apple_music",
            sourceName: "Apple Music",
            artworkData: nil,
            timestampDate: clock.now,
            errorMessage: errorMsg
        )
        publishSequence &+= 1
        let seq = publishSequence
        let qSnap = includeQueue ? queueManager.makeSnapshot() : nil
        await store.commitAtomic(state: state, queueSnapshot: qSnap, publishSequence: seq)
    }
}
