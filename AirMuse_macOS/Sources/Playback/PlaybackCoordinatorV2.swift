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
/// Guarantees Latest-Intent-Wins with serialized underlying engine execution,
/// queue ownership isolation (local vs remote radio), monotonic time anchoring,
/// strict `(sessionID, engineInstanceID, operationID, trackID)` event filtering,
/// and deterministic `QueueManager` state transitions.
public actor PlaybackCoordinatorV2 {
    private let store: PlaybackStore
    private let engine: any PlaybackEngineProtocol
    private let clock: any ClockProtocol
    private let snapshotStore: PlaybackSnapshotStore?
    private let randomizer: any QueueRandomizer

    private var activeSession: SessionContext?
    private var operationID: UInt64 = 0
    private var activePlayOperationID: UInt64 = 0
    private var operationEntryMap: [UInt64: UUID] = [:]

    // Authoritative synchronous queue state
    private var queueManager = QueueManager()
    private var rngAdapter: RandomizerAdapter

    // Desired state (updated synchronously on user intent)
    private var desiredTrack: MusicTrack?
    private var desiredKind: PlayableKind = .song
    private var desiredStartIndex: Int = 0
    private var desiredTransport: DesiredTransport = .stopped
    private var pendingSeekSeconds: Double?
    private var desiredVolume: Float = 1.0
    private var restoredNeedsEngineLoad: Bool = false

    // Actual engine-confirmed state
    private var actualStatus: PlaybackTransportStatus = .idle
    private var timeAnchor: PlaybackTimeAnchor = PlaybackTimeAnchor(positionMs: 0, durationMs: 0, monotonicNs: 0, isPlaying: false)

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

    // MARK: - Lifecycle

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
            snapshotSaveTask?.cancel()
            queueManager.resetForSessionInvalidation(newScope: "")
            operationEntryMap.removeAll()
            restoredNeedsEngineLoad = false
            hasRestoredForScope = nil
            AppLogger.shared.log(category: .queue, level: .info, message: "会话已退出，清空私有播放队列")
            try? await stop()
            await publishToStore(includeQueue: true)
            return
        }

        if accountChanged {
            snapshotSaveTask?.cancel()
            queueManager.resetForSessionInvalidation(newScope: newScope)
            operationEntryMap.removeAll()
            restoredNeedsEngineLoad = false
            hasRestoredForScope = nil
            AppLogger.shared.log(category: .queue, level: .info, message: "账户切换，重置并隔离播放队列")
            try? await stop()
            await publishToStore(includeQueue: true)
        } else if sessionChanged {
            queueManager.setSessionScope(newScope)
            await publishToStore(includeQueue: true)
        }
    }

    public func shutdown() async {
        snapshotSaveTask?.cancel()
        await flushSnapshot()
        eventTask?.cancel()
        eventTask = nil
        try? await stop()
    }

    // MARK: - User Intents (Playback & Queue Replacement)

    public func playEntries(
        _ entries: [QueueEntry],
        startIndex: Int = 0,
        kind: PlayableKind? = nil,
        loadingState: QueueLoadingState? = nil,
        batchID: UUID? = nil
    ) async throws {
        guard !entries.isEmpty else { return }
        let safeIndex = min(max(0, startIndex), entries.count - 1)
        let selected = entries[safeIndex]
        let resolvedKind: PlayableKind = kind ?? (
            selected.track.providerTrackID.hasPrefix("ra.") || selected.track.id.hasPrefix("ra.")
                ? .station
                : .song
        )
        let owner: QueueOwner = (resolvedKind == .station) ? .remoteEngine : .localCoordinator
        let resolvedLoading = loadingState ?? .complete(totalCount: entries.count)

        guard let target = queueManager.replaceQueue(
            entries: entries,
            startIndex: safeIndex,
            owner: owner,
            loadingState: resolvedLoading,
            batchID: batchID,
            startPlayback: true,
            using: &rngAdapter
        ) else { return }

        AppLogger.shared.log(
            category: .queue,
            level: .info,
            correlationID: queueCorrelationID,
            message: "新建队列并播放: \(target.track.title) (共 \(entries.count) 首, startIndex=\(safeIndex), owner=\(owner.rawValue), 来源=\(target.origin.displayTitle))"
        )
        await initiatePlayback(for: target, kind: resolvedKind, startIndex: 0)
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
        try await playEntries(entries, startIndex: effectiveIndex, kind: kind)
    }

    public func play() async throws {
        if desiredTrack == nil {
            // Idle queue with upcoming entries: Play consumes the first upcoming item
            if case .play(let entry, _) = queueManager.advanceNext(using: &rngAdapter) {
                await initiatePlayback(for: entry, kind: .song, startIndex: 0)
                return
            }
            return
        }

        if restoredNeedsEngineLoad, let entry = queueManager.activeTargetEntry {
            restoredNeedsEngineLoad = false
            let resumePosSec = Double(max(0, timeAnchor.positionMs)) / 1000.0
            let kind: PlayableKind = (queueManager.owner == .remoteEngine) ? .station : .song
            await initiatePlayback(for: entry, kind: kind, startIndex: 0, initialSeekSeconds: resumePosSec > 0 ? resumePosSec : nil)
            return
        }

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
        await publishToStore(includeQueue: false)
        scheduleDebouncedSnapshotSave(immediate: false)
        await drainCommands()
    }

    public func stop() async throws {
        operationID += 1
        activePlayOperationID = operationID
        desiredTransport = .stopped
        needsPlayItemExecution = false
        needsTransportSync = true
        actualStatus = .idle
        queueManager.clearPendingOnStop()
        timeAnchor = PlaybackTimeAnchor(positionMs: 0, durationMs: 0, monotonicNs: clock.monotonicNanoseconds, isPlaying: false)
        await publishToStore(includeQueue: true)
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
        guard queueManager.capabilities.canRepeatOne || queueManager.capabilities.canRepeatAll || mode == .off else {
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
            message: "切换随机播放: \(enabled ? "开启" : "关闭") (待播 \(queueManager.upcomingEntries.count) 首)"
        )
        await publishToStore(includeQueue: true)
        scheduleDebouncedSnapshotSave(immediate: true)
    }

    public func skipToNext() async throws {
        if queueManager.owner == .remoteEngine {
            AppLogger.shared.log(category: .queue, level: .info, correlationID: queueCorrelationID, message: "远端电台切换下一首")
            let ctx = await currentContext(trackID: desiredTrack?.id ?? "")
            try await engine.execute(.skipNext, context: ctx)
            return
        }
        switch queueManager.advanceNext(using: &rngAdapter) {
        case .play(let next, _):
            AppLogger.shared.log(category: .queue, level: .info, correlationID: queueCorrelationID, message: "下一首推进: \(next.track.title) (剩余待播 \(queueManager.upcomingEntries.count) 首)")
            await initiatePlayback(for: next, kind: .song, startIndex: 0)
        case .seekToZero, .stop:
            AppLogger.shared.log(category: .queue, level: .info, correlationID: queueCorrelationID, message: "待播队列已耗尽，停止播放")
            try await stop()
        }
    }

    public func skipToPrevious() async throws {
        if queueManager.owner == .remoteEngine {
            guard queueManager.capabilities.canSkipPrevious else { return }
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
            await initiatePlayback(for: prev, kind: .song, startIndex: 0)
        case .stop:
            break
        }
    }

    public func retryPendingOrCurrent() async throws {
        if let target = queueManager.activeTargetEntry {
            let kind: PlayableKind = (queueManager.owner == .remoteEngine) ? .station : .song
            await initiatePlayback(for: target, kind: kind, startIndex: 0)
        }
    }

    // MARK: - Queue Editing API (Single Authoritative Writer)

    public func insertNext(
        _ entries: [QueueEntry],
        expectedQueueID: UUID? = nil,
        expectedRevision: UInt64? = nil,
        batchID: UUID? = nil
    ) async throws {
        if queueManager.owner == .remoteEngine {
            throw QueueEditError.remoteQueueRequiresSwitch(stationTitle: queueManager.activeTargetEntry?.track.title)
        }
        try queueManager.validateEditContext(expectedQueueID: expectedQueueID, expectedRevision: expectedRevision)
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
        batchID: UUID? = nil
    ) async throws {
        if queueManager.owner == .remoteEngine {
            throw QueueEditError.remoteQueueRequiresSwitch(stationTitle: queueManager.activeTargetEntry?.track.title)
        }
        try queueManager.validateEditContext(expectedQueueID: expectedQueueID, expectedRevision: expectedRevision)
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
        if let target = result.playbackTarget {
            AppLogger.shared.log(
                category: .queue,
                level: .info,
                correlationID: queueCorrelationID,
                message: "指定播放待播条目: \(target.track.title) (entry=\(id.uuidString.prefix(6)), 剩余待播 \(queueManager.upcomingEntries.count) 首)"
            )
            await initiatePlayback(for: target, kind: .song, startIndex: 0)
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
        loadingState: QueueLoadingState
    ) async -> Bool {
        let ok = queueManager.commitPaginatedBatch(
            entries,
            batchID: batchID,
            expectedQueueID: expectedQueueID,
            expectedSessionScope: expectedSessionScope
        )
        guard ok else { return false }
        queueManager.updateLoadingState(loadingState)
        await publishToStore(includeQueue: true)
        scheduleDebouncedSnapshotSave(immediate: false)
        return true
    }

    public func updateQueueLoadingState(
        _ state: QueueLoadingState,
        expectedQueueID: UUID,
        expectedSessionScope: String
    ) async {
        guard queueManager.queueID == expectedQueueID,
              queueManager.sessionScope == expectedSessionScope else { return }
        queueManager.updateLoadingState(state)
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

    // MARK: - Persistence (Q17)

    public func restoreSnapshotIfNeeded(providerID: String, accountID: String?) async {
        guard let snapshotStore else { return }
        let scope = "\(providerID)|\(accountID ?? "guest")"
        guard hasRestoredForScope != scope else { return }
        // Do not overwrite an already-active playing queue
        guard queueManager.activeTargetEntry == nil, queueManager.upcomingEntries.isEmpty else {
            hasRestoredForScope = scope
            return
        }
        hasRestoredForScope = scope

        guard let snap = await snapshotStore.load(expectedProviderID: providerID, expectedAccountID: accountID),
              let payload = snap.resolvedQueuePayload() else {
            return
        }

        let restoredCurrent = queueManager.restore(from: payload, sessionScope: queueManager.sessionScope)
        desiredVolume = min(max(snap.volume, 0), 1)
        desiredTrack = restoredCurrent?.track
        desiredKind = (payload.owner == .remoteEngine) ? .station : .song
        desiredTransport = .paused
        actualStatus = restoredCurrent != nil ? .paused : .idle
        restoredNeedsEngineLoad = (restoredCurrent != nil)
        let durMs = restoredCurrent?.track.durationMs ?? 0
        let clampedPos = durMs > 0 ? min(max(0, snap.positionMs), durMs) : max(0, snap.positionMs)
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
            if now &- lastProgressSnapshotSaveNs < 10_000_000_000 { // 10s throttle for progress/pause
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

    // MARK: - Internal Playback Initiation & Drain

    private func initiatePlayback(
        for entry: QueueEntry,
        kind: PlayableKind,
        startIndex: Int,
        initialSeekSeconds: Double? = nil
    ) async {
        operationID += 1
        activePlayOperationID = operationID
        recordOperationEntry(opID: operationID, entryID: entry.id)

        restoredNeedsEngineLoad = false
        desiredTrack = entry.track
        desiredKind = kind
        desiredStartIndex = startIndex
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

    private func recordOperationEntry(opID: UInt64, entryID: UUID) {
        operationEntryMap[opID] = entryID
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
                        queueManager.markPendingFailed()
                        await publishToStore(includeQueue: true)
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
               queueManager.owner == .localCoordinator,
               prevStatus == .playing,
               (status == .paused || status == .idle || status == .ended),
               timeAnchor.durationMs > 5000,
               currentPos >= timeAnchor.durationMs - 1500 {
                await handleNaturalTrackEnd(operationID: ctx.operationID, trackID: ctx.trackID)
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
            guard ctx.engineInstanceID == currentEngineID, ctx.operationID == activePlayOperationID else { return }
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
            guard ctx.engineInstanceID == currentEngineID, ctx.operationID == activePlayOperationID else { return }
            let nowNs = clock.monotonicNanoseconds
            var didMutateState = false
            var didMutateQueue = false

            if queueManager.owner == .remoteEngine, !title.isEmpty, let current = desiredTrack {
                let effectiveID = trackID.isEmpty ? current.id : trackID
                let effectiveArtist = artist.isEmpty ? current.artistName : artist
                let effectiveAlbum = albumTitle.isEmpty ? current.albumTitle : albumTitle
                let effectiveArt = URL(string: artworkURL) ?? current.artworkURL
                let effectiveDurMs = durSec > 0 ? Int64(durSec * 1000) : current.durationMs
                let trackChanged = (current.title != title || current.artistName != effectiveArtist || (!trackID.isEmpty && current.providerTrackID != trackID))
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
                queueManager.updateRemoteCurrentTrack(updatedTrack)
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
            await publishToStore(includeQueue: false)
        }
    }

    // MARK: - Helpers

    private func handleNaturalTrackEnd(operationID opID: UInt64, trackID: String) async {
        let dedupKey = "\(opID)|\(trackID)"
        guard lastEndedOperationKey != dedupKey else { return }
        lastEndedOperationKey = dedupKey

        guard queueManager.owner == .localCoordinator else { return }

        // Ensure current playing entry is confirmed before advancing
        if let entryID = operationEntryMap[opID], queueManager.pendingReservationID == entryID {
            queueManager.confirmEntry(entryID)
        }

        switch queueManager.advanceOnNaturalEnd(using: &rngAdapter) {
        case .play(let next, _):
            await initiatePlayback(for: next, kind: .song, startIndex: 0)
        case .seekToZero, .stop:
            try? await stop()
        }
    }

    private var queueCorrelationID: String {
        "q-\(queueManager.queueID.uuidString.prefix(6))-r\(queueManager.revision)"
    }

    private func currentContext(trackID: String) async -> PlaybackOperationContext {
        let sid = activeSession?.sessionID ?? UUID(uuidString: "00000000-0000-0000-0000-000000000000")!
        let eid = await engine.engineInstanceID
        return PlaybackOperationContext(sessionID: sid, engineInstanceID: eid, operationID: operationID, trackID: trackID)
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
            shuffleEnabled: queueManager.shuffleEnabled,
            currentTrack: desiredTrack,
            providerID: desiredTrack?.providerID ?? "apple_music",
            sourceName: "Apple Music",
            artworkData: nil,
            timestampDate: clock.now,
            errorMessage: errorMsg
        )
        await store.update(state: state)
        if includeQueue {
            await store.update(queueSnapshot: queueManager.makeSnapshot())
        }
    }
}
