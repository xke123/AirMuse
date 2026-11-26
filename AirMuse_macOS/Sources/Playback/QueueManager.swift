import Foundation
import Domain

// MARK: - QueueAdvancementResult

public enum QueueAdvancementResult: Sendable, Equatable {
    case play(entry: QueueEntry, isRepeatOne: Bool)
    case seekToZero
    case stop
}

// MARK: - QueueMutationResult

public struct QueueMutationResult: Sendable {
    public let snapshot: QueueSnapshot
    public let cancelledPendingEntry: QueueEntry?
    public let playbackTarget: QueueEntry?

    public init(
        snapshot: QueueSnapshot,
        cancelledPendingEntry: QueueEntry? = nil,
        playbackTarget: QueueEntry? = nil
    ) {
        self.snapshot = snapshot
        self.cancelledPendingEntry = cancelledPendingEntry
        self.playbackTarget = playbackTarget
    }
}

// MARK: - QueuePersistencePayload

/// Serializable representation of `QueueManager` state for `PlaybackSnapshotStore` (schema v2).
public struct QueuePersistencePayload: Codable, Sendable, Equatable {
    public let queueID: UUID
    public let entries: [QueueEntry]
    public let baselineOrder: [UUID]
    public let upcomingOrder: [UUID]
    public let history: [QueueEntry]
    public let currentEntryID: UUID?
    public let shuffleEnabled: Bool
    public let repeatMode: PlaybackState.RepeatMode
    public let owner: QueueOwner

    public init(
        queueID: UUID,
        entries: [QueueEntry],
        baselineOrder: [UUID],
        upcomingOrder: [UUID],
        history: [QueueEntry],
        currentEntryID: UUID?,
        shuffleEnabled: Bool,
        repeatMode: PlaybackState.RepeatMode,
        owner: QueueOwner
    ) {
        self.queueID = queueID
        self.entries = entries
        self.baselineOrder = baselineOrder
        self.upcomingOrder = upcomingOrder
        self.history = history
        self.currentEntryID = currentEntryID
        self.shuffleEnabled = shuffleEnabled
        self.repeatMode = repeatMode
        self.owner = owner
    }
}

// MARK: - QueueManager

/// Authoritative, synchronous value-type queue state machine owned exclusively by `PlaybackCoordinatorV2`.
/// Guarantees:
/// - Every entry has a unique `UUID` and `PlaybackOrigin`.
/// - `upcomingOrder` is 100% identical to what `advanceNext` consumes.
/// - `history` is independent of `baselineOrder` (deleted/cleared entries stay in bounded history without resurrecting in repeat).
/// - Reservation / confirmation separation: only confirmed playback enters history.
public struct QueueManager: Sendable {

    private enum PendingSource: Equatable {
        case newQueue
        case next
        case previous
        case directPlay
        case repeatOne
    }

    private struct UndoRecord: Sendable {
        let queueID: UUID
        let sessionScope: String
        let postEditRevision: UInt64
        let previousBaselineOrder: [UUID]
        let previousUpcomingOrder: [UUID]
        let removedEntries: [UUID: QueueEntry]
        let description: String
    }

    private struct BatchAnchor: Sendable {
        let batchID: UUID
        var lastEntryID: UUID?
        var isInvalidated: Bool = false
    }

    public static let maxHistoryCount = 200

    public private(set) var queueID: UUID = UUID()
    public private(set) var revision: UInt64 = 0
    public private(set) var sessionScope: String = ""
    public private(set) var owner: QueueOwner = .localCoordinator
    public private(set) var capabilities: QueueCapabilities = .fullLocal
    public private(set) var loadingState: QueueLoadingState = .idle

    private var entriesByID: [UUID: QueueEntry] = [:]
    private var baselineOrder: [UUID] = []
    private var upcomingOrder: [UUID] = []
    private var history: [QueueEntry] = []

    public private(set) var confirmedCurrentID: UUID?
    public private(set) var pendingReservationID: UUID?
    private var pendingSource: PendingSource?
    private var lastFailedTarget: QueueEntry?

    public private(set) var shuffleEnabled: Bool = false
    public private(set) var repeatMode: PlaybackState.RepeatMode = .off

    private var batchAnchors: [UUID: BatchAnchor] = [:]
    private var undoRecord: UndoRecord?

    public init() {}

    // MARK: - Accessors

    public var confirmedCurrentEntry: QueueEntry? {
        guard let id = confirmedCurrentID else { return nil }
        return entriesByID[id]
    }

    public var pendingTargetEntry: QueueEntry? {
        guard let id = pendingReservationID else { return nil }
        return entriesByID[id]
    }

    /// The effective target entry (pending if preparing/buffering, otherwise confirmed current).
    public var activeTargetEntry: QueueEntry? {
        pendingTargetEntry ?? confirmedCurrentEntry
    }

    public var upcomingEntries: [QueueEntry] {
        upcomingOrder.compactMap { entriesByID[$0] }
    }

    public var historyEntries: [QueueEntry] {
        history
    }

    public func entry(for id: UUID) -> QueueEntry? {
        entriesByID[id]
    }

    public func makeSnapshot() -> QueueSnapshot {
        let canUndoNow: Bool
        let undoDesc: String?
        if let u = undoRecord,
           u.queueID == queueID,
           u.sessionScope == sessionScope,
           u.postEditRevision == revision {
            canUndoNow = true
            undoDesc = u.description
        } else {
            canUndoNow = false
            undoDesc = nil
        }

        let canGoNextNow: Bool = switch owner {
        case .remoteEngine:
            capabilities.canSkipNext
        case .localCoordinator:
            !upcomingOrder.isEmpty || (repeatMode == .all && !baselineOrder.isEmpty)
        }

        let canGoPrevNow: Bool = switch owner {
        case .remoteEngine:
            capabilities.canSkipPrevious
        case .localCoordinator:
            !history.isEmpty || activeTargetEntry != nil
        }

        return QueueSnapshot(
            queueID: queueID,
            revision: revision,
            sessionScope: sessionScope,
            owner: owner,
            confirmedCurrent: confirmedCurrentEntry,
            pendingTarget: pendingTargetEntry,
            upcomingEntries: upcomingEntries,
            historyCount: history.count,
            canGoPrevious: canGoPrevNow,
            canGoNext: canGoNextNow,
            shuffleEnabled: shuffleEnabled,
            repeatMode: repeatMode,
            capabilities: capabilities,
            loadingState: loadingState,
            canUndo: canUndoNow,
            undoDescription: undoDesc
        )
    }

    // MARK: - Session & Scope

    public mutating func setSessionScope(_ scope: String) {
        sessionScope = scope
        undoRecord = nil
    }

    public mutating func resetForSessionInvalidation(newScope: String) {
        queueID = UUID()
        revision &+= 1
        sessionScope = newScope
        owner = .localCoordinator
        capabilities = .fullLocal
        loadingState = .idle
        entriesByID.removeAll()
        baselineOrder.removeAll()
        upcomingOrder.removeAll()
        history.removeAll()
        confirmedCurrentID = nil
        pendingReservationID = nil
        pendingSource = nil
        lastFailedTarget = nil
        batchAnchors.removeAll()
        undoRecord = nil
    }

    public mutating func updateLoadingState(_ state: QueueLoadingState) {
        loadingState = state
        revision &+= 1
    }

    public mutating func updateCapabilities(_ newCapabilities: QueueCapabilities) {
        capabilities = newCapabilities
        revision &+= 1
    }

    // MARK: - Replace Queue (Play from Library / New Context)

    /// Replaces the current queue with a new set of entries starting at `startIndex`.
    /// When `startPlayback` is true, `entries[startIndex]` becomes `pendingReservationID` and
    /// `upcomingOrder` contains the remaining entries after `startIndex` (or shuffled if `shuffleEnabled`).
    public mutating func replaceQueue<R: RandomNumberGenerator>(
        entries: [QueueEntry],
        startIndex: Int = 0,
        owner: QueueOwner = .localCoordinator,
        capabilities: QueueCapabilities? = nil,
        loadingState: QueueLoadingState = .idle,
        batchID: UUID? = nil,
        startPlayback: Bool = true,
        using rng: inout R
    ) -> QueueEntry? {
        queueID = UUID()
        revision &+= 1
        self.owner = owner
        self.capabilities = capabilities ?? (owner == .remoteEngine ? .remoteStationDefault : .fullLocal)
        self.loadingState = loadingState

        entriesByID.removeAll()
        baselineOrder.removeAll()
        upcomingOrder.removeAll()
        batchAnchors.removeAll()
        undoRecord = nil
        lastFailedTarget = nil

        // Preserve existing confirmedCurrent in history if we are replacing with a new playing track
        if startPlayback, let prevConfirmed = confirmedCurrentID, let prevEntry = entriesByIDSnapshotForHistory(prevConfirmed) {
            appendToHistory(prevEntry)
        }
        confirmedCurrentID = nil
        pendingReservationID = nil
        pendingSource = nil

        guard !entries.isEmpty else {
            return nil
        }

        for entry in entries {
            entriesByID[entry.id] = entry
            baselineOrder.append(entry.id)
        }

        if let batchID {
            batchAnchors[batchID] = BatchAnchor(batchID: batchID, lastEntryID: entries.last?.id, isInvalidated: false)
        }

        let safeIndex = min(max(0, startIndex), entries.count - 1)
        if startPlayback {
            let target = entries[safeIndex]
            pendingReservationID = target.id
            pendingSource = .newQueue
            // Upcoming starts with items after safeIndex; items before safeIndex remain in baselineOrder for repeat-all.
            var remaining = Array(entries[(safeIndex + 1)...].map(\.id))
            if shuffleEnabled && owner == .localCoordinator {
                // In shuffle mode, shuffle all other baseline members as the current round's upcoming
                var others = baselineOrder.filter { $0 != target.id }
                others.shuffle(using: &rng)
                remaining = others
            }
            upcomingOrder = remaining
            pruneUnreferencedEntries()
            return target
        } else {
            var allIDs = entries.map(\.id)
            if shuffleEnabled && owner == .localCoordinator {
                allIDs.shuffle(using: &rng)
            }
            upcomingOrder = allIDs
            pruneUnreferencedEntries()
            return nil
        }
    }

    private func entriesByIDSnapshotForHistory(_ id: UUID) -> QueueEntry? {
        entriesByID[id]
    }

    // MARK: - Confirmation & Failure

    /// Called when the engine confirms playback has actually started for `entryID`.
    public mutating func confirmEntry(_ entryID: UUID) {
        if let prevID = confirmedCurrentID, prevID != entryID {
            if pendingSource != .previous, let prevEntry = entriesByID[prevID] {
                appendToHistory(prevEntry)
            }
        }
        confirmedCurrentID = entryID
        if pendingReservationID == entryID {
            pendingReservationID = nil
            pendingSource = nil
        }
        lastFailedTarget = nil
        revision &+= 1
        pruneUnreferencedEntries()
    }

    /// Updates metadata for the confirmed remote station track (e.g. MusicKit itemChanged)
    /// while preserving its `PlaybackOrigin` and `UUID`.
    public mutating func updateRemoteCurrentTrack(_ track: MusicTrack) {
        guard owner == .remoteEngine else { return }
        if let id = pendingReservationID ?? confirmedCurrentID, let existing = entriesByID[id] {
            let updated = QueueEntry(
                id: existing.id,
                track: track,
                origin: existing.origin,
                batchID: existing.batchID,
                addedAt: existing.addedAt
            )
            entriesByID[id] = updated
            if pendingReservationID == id {
                confirmedCurrentID = id
                pendingReservationID = nil
                pendingSource = nil
            }
            revision &+= 1
        }
    }

    /// Marks the pending reservation as failed without adding it to history or faking confirmedCurrent.
    public mutating func markPendingFailed() {
        if let pendingID = pendingReservationID {
            lastFailedTarget = entriesByID[pendingID]
        }
        revision &+= 1
    }

    /// Clears pending reservation on explicit stop without touching confirmed history.
    public mutating func clearPendingOnStop() {
        pendingReservationID = nil
        pendingSource = nil
        revision &+= 1
        pruneUnreferencedEntries()
    }

    // MARK: - Advancement & History (Q02, Q03, Q04, Q05, Q16)

    /// Advances on natural track end. Respects `.one`, `.all`, and `shuffleEnabled`.
    public mutating func advanceOnNaturalEnd<R: RandomNumberGenerator>(using rng: inout R) -> QueueAdvancementResult {
        guard owner == .localCoordinator else { return .stop }

        if repeatMode == .one, let current = confirmedCurrentEntry ?? pendingTargetEntry {
            pendingReservationID = current.id
            pendingSource = .repeatOne
            revision &+= 1
            return .play(entry: current, isRepeatOne: true)
        }

        return advanceNext(using: &rng)
    }

    /// Manual Next (ignores repeat-one, consumes upcoming or regenerates repeat-all cycle).
    public mutating func advanceNext<R: RandomNumberGenerator>(using rng: inout R) -> QueueAdvancementResult {
        guard owner == .localCoordinator else { return .stop }

        // If a pending reservation from .previous or .directPlay wasn't confirmed, handle cleanly:
        // For rapid Next -> Next, the skipped pending entry was already popped from upcomingOrder.
        if !upcomingOrder.isEmpty {
            let nextID = upcomingOrder.removeFirst()
            guard let nextEntry = entriesByID[nextID] else {
                return advanceNext(using: &rng)
            }
            pendingReservationID = nextEntry.id
            pendingSource = .next
            revision &+= 1
            return .play(entry: nextEntry, isRepeatOne: false)
        }

        if repeatMode == .all, !baselineOrder.isEmpty {
            var nextRound = baselineOrder
            if shuffleEnabled {
                nextRound.shuffle(using: &rng)
                if nextRound.count > 1,
                   let currentID = confirmedCurrentID ?? pendingReservationID,
                   nextRound.first == currentID {
                    let swapIdx = Int.random(in: 1..<nextRound.count, using: &rng)
                    nextRound.swapAt(0, swapIdx)
                }
            }
            upcomingOrder = nextRound
            let nextID = upcomingOrder.removeFirst()
            if let nextEntry = entriesByID[nextID] {
                pendingReservationID = nextEntry.id
                pendingSource = .next
                revision &+= 1
                return .play(entry: nextEntry, isRepeatOne: false)
            }
        }

        return .stop
    }

    /// Manual Previous: if `positionMs > 3000`, returns `.seekToZero`.
    /// Otherwise pops from `history`, pushes current target to head of `upcomingOrder` (deduplicated) as forward candidate.
    public mutating func retreatPrevious(positionMs: Int64) -> QueueAdvancementResult {
        guard owner == .localCoordinator else { return .stop }
        if positionMs > 3_000 {
            return .seekToZero
        }
        guard let prevEntry = history.popLast() else {
            return .seekToZero
        }

        // Push current active target to the front of upcomingOrder as forward candidate (deduped)
        if let current = activeTargetEntry, current.id != prevEntry.id {
            entriesByID[current.id] = current
            upcomingOrder.removeAll { $0 == current.id }
            upcomingOrder.insert(current.id, at: 0)
        }

        entriesByID[prevEntry.id] = prevEntry
        pendingReservationID = prevEntry.id
        pendingSource = .previous
        revision &+= 1
        return .play(entry: prevEntry, isRepeatOne: false)
    }

    // MARK: - Playback Modes (Q03, Q04, Q05)

    public mutating func setRepeatMode(_ mode: PlaybackState.RepeatMode) {
        repeatMode = mode
        revision &+= 1
    }

    public mutating func setShuffleEnabled<R: RandomNumberGenerator>(_ enabled: Bool, using rng: inout R) {
        guard shuffleEnabled != enabled else { return }
        shuffleEnabled = enabled

        if enabled {
            upcomingOrder.shuffle(using: &rng)
        } else {
            // Restore relative order from baselineOrder while keeping only remaining upcoming entries
            let rank = Dictionary(uniqueKeysWithValues: baselineOrder.enumerated().map { ($1, $0) })
            upcomingOrder.sort { (lhs, rhs) in
                (rank[lhs] ?? Int.max) < (rank[rhs] ?? Int.max)
            }
        }
        revision &+= 1
    }

    // MARK: - Queue Editing (Q06 - Q15, Q20)

    public mutating func validateEditContext(
        expectedQueueID: UUID? = nil,
        expectedSessionScope: String? = nil,
        expectedRevision: UInt64? = nil
    ) throws {
        if let expectedQueueID, expectedQueueID != queueID {
            throw QueueEditError.queueMismatch(expected: expectedQueueID, actual: queueID)
        }
        if let expectedSessionScope, expectedSessionScope != sessionScope {
            throw QueueEditError.sessionMismatch
        }
        if let expectedRevision, expectedRevision != revision {
            // Allow safe relocation if only non-conflicting changes occurred?
            // Callers can pass nil if they want ID-based relocation; explicit revision checks throw conflict.
            throw QueueEditError.revisionConflict(expected: expectedRevision, actual: revision)
        }
    }

    /// Q13: Insert entries at the head of upcomingOrder (preserving batch order).
    /// Also inserts into baselineOrder after current entry so turning off shuffle keeps them at the front.
    public mutating func insertNext(
        _ entries: [QueueEntry],
        batchID: UUID? = nil
    ) throws {
        guard capabilities.canInsertNext else {
            throw QueueEditError.unsupportedCapability("当前播放模式不支持插入下一首。")
        }
        guard !entries.isEmpty else { throw QueueEditError.emptyBatch }

        undoRecord = nil
        for entry in entries {
            entriesByID[entry.id] = entry
        }

        let newIDs = entries.map(\.id)
        upcomingOrder.insert(contentsOf: newIDs, at: 0)

        if let currentID = activeTargetEntry?.id, let idx = baselineOrder.firstIndex(of: currentID) {
            baselineOrder.insert(contentsOf: newIDs, at: idx + 1)
        } else {
            baselineOrder.insert(contentsOf: newIDs, at: 0)
        }

        if let batchID {
            batchAnchors[batchID] = BatchAnchor(batchID: batchID, lastEntryID: entries.last?.id, isInvalidated: false)
        }

        revision &+= 1
    }

    /// Q12: Append entries to the tail of upcomingOrder and baselineOrder without re-shuffling.
    public mutating func append(
        _ entries: [QueueEntry],
        batchID: UUID? = nil
    ) throws {
        guard capabilities.canAppend else {
            throw QueueEditError.unsupportedCapability("当前播放模式不支持添加到队列。")
        }
        guard !entries.isEmpty else { throw QueueEditError.emptyBatch }

        undoRecord = nil
        for entry in entries {
            entriesByID[entry.id] = entry
        }

        let newIDs = entries.map(\.id)
        upcomingOrder.append(contentsOf: newIDs)
        baselineOrder.append(contentsOf: newIDs)

        if let batchID {
            batchAnchors[batchID] = BatchAnchor(batchID: batchID, lastEntryID: entries.last?.id, isInvalidated: false)
        }

        revision &+= 1
    }

    /// Q07: Play a specific upcoming entry by ID without disturbing the relative order of remaining upcoming entries.
    public mutating func playEntry(id: UUID) throws -> QueueMutationResult {
        guard capabilities.canRead else {
            throw QueueEditError.unsupportedCapability("当前播放模式不支持选择待播曲目。")
        }
        guard upcomingOrder.contains(id), let target = entriesByID[id] else {
            throw QueueEditError.entryNotFound(id)
        }

        undoRecord = nil
        var cancelled: QueueEntry?
        if let pendingID = pendingReservationID, pendingID != id {
            cancelled = entriesByID[pendingID]
            if pendingSource == .next, let cancelled {
                // Restore unconfirmed Next reservation to front of upcoming so it isn't silently lost
                upcomingOrder.insert(cancelled.id, at: 0)
            }
        }

        // Remove target from upcomingOrder (after potential restore)
        upcomingOrder.removeAll { $0 == id }
        pendingReservationID = target.id
        pendingSource = .directPlay
        revision &+= 1

        return QueueMutationResult(
            snapshot: makeSnapshot(),
            cancelledPendingEntry: cancelled,
            playbackTarget: target
        )
    }

    /// Q08 / Q15: Remove one or more upcoming entries by ID. Never removes confirmedCurrent or history.
    public mutating func removeEntries(ids: [UUID]) throws {
        guard capabilities.canRemove else {
            throw QueueEditError.unsupportedCapability("当前播放模式不支持移除待播曲目。")
        }
        let idSet = Set(ids)
        let validRemovals = upcomingOrder.filter { idSet.contains($0) }
        guard !validRemovals.isEmpty else {
            throw QueueEditError.entryNotFound(ids.first ?? UUID())
        }

        let prevBaseline = baselineOrder
        let prevUpcoming = upcomingOrder
        var removedMap: [UUID: QueueEntry] = [:]
        for id in validRemovals {
            if let entry = entriesByID[id] {
                removedMap[id] = entry
            }
        }

        upcomingOrder.removeAll { idSet.contains($0) }
        baselineOrder.removeAll { idSet.contains($0) }

        // Update batch anchors if the anchor entry was removed
        for (bid, var anchor) in batchAnchors {
            if let lastID = anchor.lastEntryID, idSet.contains(lastID) {
                let replacement = upcomingOrder.last { entriesByID[$0]?.batchID == bid }
                anchor.lastEntryID = replacement
                if replacement == nil {
                    anchor.isInvalidated = true
                }
                batchAnchors[bid] = anchor
            }
        }

        revision &+= 1
        undoRecord = UndoRecord(
            queueID: queueID,
            sessionScope: sessionScope,
            postEditRevision: revision,
            previousBaselineOrder: prevBaseline,
            previousUpcomingOrder: prevUpcoming,
            removedEntries: removedMap,
            description: validRemovals.count == 1 ? "移除 1 首曲目" : "移除 \(validRemovals.count) 首曲目"
        )
        pruneUnreferencedEntries()
    }

    /// Q09 / Q10 / Q11 / Q15: Move one or more upcoming entries before `targetID` (or to the end if `targetID == nil`).
    /// Updates both `upcomingOrder` and `baselineOrder` so explicit edits survive turning shuffle off.
    public mutating func moveEntries(ids: [UUID], before targetID: UUID?) throws {
        guard capabilities.canReorder else {
            throw QueueEditError.unsupportedCapability("当前播放模式不支持调整队列顺序。")
        }
        guard !ids.isEmpty else { throw QueueEditError.emptyBatch }

        let idSet = Set(ids)
        // Preserve existing relative order in upcomingOrder
        let movingIDs = upcomingOrder.filter { idSet.contains($0) }
        guard movingIDs.count == idSet.count else {
            let missing = idSet.first { !upcomingOrder.contains($0) } ?? UUID()
            throw QueueEditError.entryNotFound(missing)
        }

        if let targetID {
            guard !idSet.contains(targetID), upcomingOrder.contains(targetID) else {
                throw QueueEditError.invalidTarget(targetID)
            }
        }

        undoRecord = nil

        // Update upcomingOrder
        upcomingOrder.removeAll { idSet.contains($0) }
        if let targetID, let insertIdx = upcomingOrder.firstIndex(of: targetID) {
            upcomingOrder.insert(contentsOf: movingIDs, at: insertIdx)
        } else {
            upcomingOrder.append(contentsOf: movingIDs)
        }

        // Update baselineOrder with the same relative placement
        baselineOrder.removeAll { idSet.contains($0) }
        if let targetID, let baseIdx = baselineOrder.firstIndex(of: targetID) {
            baselineOrder.insert(contentsOf: movingIDs, at: baseIdx)
        } else {
            baselineOrder.append(contentsOf: movingIDs)
        }

        revision &+= 1
    }

    /// Q06: Clear all upcoming entries and cycle members (`baselineOrder`), invalidate active pagination batches.
    /// Keeps current audio, position, history, and repeat/shuffle mode settings.
    public mutating func clearUpcoming() throws {
        guard capabilities.canClear else {
            throw QueueEditError.unsupportedCapability("当前播放模式不支持清空队列。")
        }

        let prevBaseline = baselineOrder
        let prevUpcoming = upcomingOrder
        var removedMap: [UUID: QueueEntry] = [:]
        for id in Set(prevBaseline).union(prevUpcoming) {
            if id != confirmedCurrentID && id != pendingReservationID, let entry = entriesByID[id] {
                removedMap[id] = entry
            }
        }

        upcomingOrder.removeAll()
        baselineOrder.removeAll()
        for bid in batchAnchors.keys {
            batchAnchors[bid]?.isInvalidated = true
        }

        revision &+= 1
        if !prevUpcoming.isEmpty || !prevBaseline.isEmpty {
            undoRecord = UndoRecord(
                queueID: queueID,
                sessionScope: sessionScope,
                postEditRevision: revision,
                previousBaselineOrder: prevBaseline,
                previousUpcomingOrder: prevUpcoming,
                removedEntries: removedMap,
                description: "清空待播队列"
            )
        }
        pruneUnreferencedEntries()
    }

    /// Q20: Single-step safe undo for `removeEntries` and `clearUpcoming`.
    /// Only succeeds if `queueID`, `sessionScope`, and `revision` match the post-edit state.
    public mutating func undo(expectedQueueID: UUID, expectedSessionScope: String) throws {
        guard let record = undoRecord else {
            throw QueueEditError.undoUnavailable("没有可撤销的操作。")
        }
        guard record.queueID == expectedQueueID,
              record.queueID == queueID,
              record.sessionScope == expectedSessionScope,
              record.sessionScope == sessionScope,
              record.postEditRevision == revision else {
            undoRecord = nil
            throw QueueEditError.undoUnavailable("队列状态已变更，无法撤销。")
        }

        for (id, entry) in record.removedEntries {
            entriesByID[id] = entry
        }
        baselineOrder = record.previousBaselineOrder
        upcomingOrder = record.previousUpcomingOrder
        undoRecord = nil
        revision &+= 1
    }

    // MARK: - Pagination Batch Commits (Q18)

    /// Commits a page of entries belonging to `batchID` right after the batch's anchor in `upcomingOrder` and `baselineOrder`,
    /// so user-appended items after the batch are never overtaken and user-dragged items are not overwritten.
    @discardableResult
    public mutating func commitPaginatedBatch(
        _ entries: [QueueEntry],
        batchID: UUID,
        expectedQueueID: UUID,
        expectedSessionScope: String
    ) -> Bool {
        guard expectedQueueID == queueID,
              expectedSessionScope == sessionScope,
              let anchor = batchAnchors[batchID],
              !anchor.isInvalidated else {
            return false
        }

        guard !entries.isEmpty else { return true }

        for entry in entries {
            entriesByID[entry.id] = entry
        }
        let newIDs = entries.map(\.id)

        if let anchorID = anchor.lastEntryID, let upIdx = upcomingOrder.firstIndex(of: anchorID) {
            upcomingOrder.insert(contentsOf: newIDs, at: upIdx + 1)
        } else {
            upcomingOrder.append(contentsOf: newIDs)
        }

        if let anchorID = anchor.lastEntryID, let baseIdx = baselineOrder.firstIndex(of: anchorID) {
            baselineOrder.insert(contentsOf: newIDs, at: baseIdx + 1)
        } else {
            baselineOrder.append(contentsOf: newIDs)
        }

        batchAnchors[batchID] = BatchAnchor(batchID: batchID, lastEntryID: entries.last?.id, isInvalidated: false)
        revision &+= 1
        return true
    }

    public mutating func invalidateBatch(_ batchID: UUID) {
        batchAnchors[batchID]?.isInvalidated = true
    }

    // MARK: - Persistence Export / Restore (Q17)

    public func exportPersistencePayload() -> QueuePersistencePayload {
        var referencedIDs = Set(baselineOrder).union(upcomingOrder)
        if let confirmedCurrentID { referencedIDs.insert(confirmedCurrentID) }
        if let pendingReservationID { referencedIDs.insert(pendingReservationID) }

        let persistedEntries = referencedIDs.compactMap { entriesByID[$0] }
        return QueuePersistencePayload(
            queueID: queueID,
            entries: persistedEntries,
            baselineOrder: baselineOrder,
            upcomingOrder: upcomingOrder,
            history: history,
            currentEntryID: activeTargetEntry?.id,
            shuffleEnabled: shuffleEnabled,
            repeatMode: repeatMode,
            owner: owner
        )
    }

    /// Restores queue state from a persisted payload, validating all IDs and integrity.
    public mutating func restore(from payload: QueuePersistencePayload, sessionScope: String) -> QueueEntry? {
        self.queueID = payload.queueID
        self.revision &+= 1
        self.sessionScope = sessionScope
        self.owner = payload.owner
        self.capabilities = payload.owner == .remoteEngine ? .remoteStationDefault : .fullLocal
        self.loadingState = .idle
        self.shuffleEnabled = payload.shuffleEnabled
        self.repeatMode = payload.repeatMode
        self.undoRecord = nil
        self.batchAnchors.removeAll()
        self.lastFailedTarget = nil

        var map: [UUID: QueueEntry] = [:]
        for e in payload.entries {
            map[e.id] = e
        }
        for h in payload.history {
            if map[h.id] == nil {
                map[h.id] = h
            }
        }
        self.entriesByID = map
        self.baselineOrder = payload.baselineOrder.filter { map[$0] != nil }
        self.upcomingOrder = payload.upcomingOrder.filter { map[$0] != nil }
        self.history = Array(payload.history.suffix(Self.maxHistoryCount))

        if let cid = payload.currentEntryID, map[cid] != nil {
            self.confirmedCurrentID = cid
        } else {
            self.confirmedCurrentID = nil
        }
        self.pendingReservationID = nil
        self.pendingSource = nil

        pruneUnreferencedEntries()
        return confirmedCurrentEntry
    }

    // MARK: - Internal Helpers

    private mutating func appendToHistory(_ entry: QueueEntry) {
        history.append(entry)
        if history.count > Self.maxHistoryCount {
            history.removeFirst(history.count - Self.maxHistoryCount)
        }
    }

    private mutating func pruneUnreferencedEntries() {
        var keep = Set(baselineOrder).union(upcomingOrder)
        if let confirmedCurrentID { keep.insert(confirmedCurrentID) }
        if let pendingReservationID { keep.insert(pendingReservationID) }
        if let lastFailed = lastFailedTarget?.id { keep.insert(lastFailed) }
        for h in history { keep.insert(h.id) }
        if let u = undoRecord {
            keep.formUnion(u.removedEntries.keys)
        }
        entriesByID = entriesByID.filter { keep.contains($0.key) }
    }
}
