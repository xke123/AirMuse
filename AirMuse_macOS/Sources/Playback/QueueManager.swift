import Foundation
import Domain

// MARK: - QueueAdvancementResult

public enum QueueAdvancementResult: Sendable, Equatable {
    case play(entry: QueueEntry, isRepeatOne: Bool)
    case waitingForPage(batchID: UUID)
    case seekToZero
    case exhausted
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
    public let activeTarget: PlaybackTarget?
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
        activeTarget: PlaybackTarget? = nil,
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
        self.activeTarget = activeTarget
        self.shuffleEnabled = shuffleEnabled
        self.repeatMode = repeatMode
        self.owner = owner
    }
}

// MARK: - QueueManager

/// Authoritative, synchronous value-type queue state machine owned exclusively by `PlaybackCoordinatorV2`.
/// Guarantees:
/// - Every entry has a unique `UUID` and `PlaybackOrigin`.
/// - Logical `batchTail` sentinels keep pagination boundaries stable even if anchor tracks are consumed or deleted.
/// - `ReservationRecord` isolates pending/failed playback from `confirmedCurrent` and `history`.
/// - `requestedShuffle` vs `effectiveShuffle` prevents premature/partial shuffle during large collection loading.
public struct QueueManager: Sendable {

    private enum PendingSource: Equatable {
        case replace
        case interrupt
        case next
        case previous
        case directPlay(originalUpcomingIndex: Int?)
        case repeatOne
    }

    private enum QueueSlot: Equatable, Sendable {
        case entry(UUID)
        case batchTail(UUID)

        var entryID: UUID? {
            if case .entry(let id) = self { return id }
            return nil
        }

        var batchID: UUID? {
            if case .batchTail(let id) = self { return id }
            return nil
        }
    }

    private struct ReservationRecord: Sendable {
        let id: UUID
        var entry: QueueEntry
        let source: PendingSource
        let previousConfirmed: QueueEntry?
        let forwardCandidate: QueueEntry?
        var isFailed: Bool = false
    }

    private struct UndoRecord: Sendable {
        let queueID: UUID
        let sessionScope: String
        let postEditRevision: UInt64
        let previousBaselineSlots: [QueueSlot]
        let previousUpcomingSlots: [QueueSlot]
        let removedEntries: [UUID: QueueEntry]
        let description: String
    }

    public static let maxHistoryCount = 200

    public private(set) var queueID: UUID = UUID()
    public private(set) var revision: UInt64 = 0
    public private(set) var destructiveEpoch: UInt64 = 0
    public private(set) var sessionScope: String = ""
    public private(set) var owner: QueueOwner = .localCoordinator
    public private(set) var activeTarget: PlaybackTarget?
    public private(set) var capabilities: QueueCapabilities = .fullLocal
    public private(set) var loadingState: QueueLoadingState = .idle
    public private(set) var playbackPhase: QueuePlaybackPhase = .idle

    private var entriesByID: [UUID: QueueEntry] = [:]
    private var baselineSlots: [QueueSlot] = []
    private var upcomingSlots: [QueueSlot] = []
    private var history: [QueueEntry] = []

    private var confirmedCurrent: QueueEntry?
    private var reservation: ReservationRecord?

    public private(set) var requestedShuffle: Bool = false
    public private(set) var effectiveShuffle: Bool = false
    public var shuffleEnabled: Bool { requestedShuffle }
    public private(set) var repeatMode: PlaybackState.RepeatMode = .off

    private var activeBatches: Set<UUID> = []
    private var undoRecord: UndoRecord?

    public init() {}

    // MARK: - Accessors

    public var confirmedCurrentEntry: QueueEntry? {
        confirmedCurrent
    }

    public var pendingTargetEntry: QueueEntry? {
        reservation?.entry
    }

    public var pendingReservationID: UUID? {
        reservation?.entry.id
    }

    public var confirmedCurrentID: UUID? {
        confirmedCurrent?.id
    }

    public var isPendingTargetFailed: Bool {
        reservation?.isFailed ?? false
    }

    /// The effective target entry (pending if preparing/buffering/failed, otherwise confirmed current).
    public var activeTargetEntry: QueueEntry? {
        reservation?.entry ?? confirmedCurrent
    }

    public var upcomingEntries: [QueueEntry] {
        upcomingSlots.compactMap { slot in
            guard case .entry(let id) = slot else { return nil }
            return entriesByID[id]
        }
    }

    private var baselineEntryIDs: [UUID] {
        baselineSlots.compactMap(\.entryID)
    }

    private var upcomingEntryIDs: [UUID] {
        upcomingSlots.compactMap(\.entryID)
    }

    public var historyEntries: [QueueEntry] {
        history
    }

    public func entry(for id: UUID) -> QueueEntry? {
        entriesByID[id]
    }

    public var hasActiveBatch: Bool {
        !activeBatches.isEmpty
    }

    public var canClearUpcoming: Bool {
        capabilities.canClear && (!upcomingEntryIDs.isEmpty || !baselineEntryIDs.isEmpty || !activeBatches.isEmpty)
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

        let upcoming = upcomingEntries
        let canGoNextNow: Bool = switch owner {
        case .remoteEngine:
            capabilities.canSkipNext
        case .localCoordinator:
            !upcoming.isEmpty || (repeatMode == .all && !baselineEntryIDs.isEmpty)
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
            destructiveEpoch: destructiveEpoch,
            sessionScope: sessionScope,
            owner: owner,
            activeTarget: activeTarget,
            confirmedCurrent: confirmedCurrent,
            pendingTarget: reservation?.entry,
            isPendingTargetFailed: reservation?.isFailed ?? false,
            upcomingEntries: upcoming,
            historyCount: history.count,
            canGoPrevious: canGoPrevNow,
            canGoNext: canGoNextNow,
            canClearUpcoming: canClearUpcoming,
            shuffleEnabled: requestedShuffle,
            requestedShuffle: requestedShuffle,
            effectiveShuffle: effectiveShuffle,
            repeatMode: repeatMode,
            capabilities: capabilities,
            loadingState: loadingState,
            playbackPhase: playbackPhase,
            canUndo: canUndoNow,
            undoDescription: undoDesc
        )
    }

    // MARK: - Session & Scope

    public mutating func setSessionScope(_ scope: String) {
        sessionScope = scope
        undoRecord = nil
    }

    public mutating func setPlaybackPhase(_ phase: QueuePlaybackPhase) {
        playbackPhase = phase
    }

    public mutating func resetForSessionInvalidation(newScope: String) {
        queueID = UUID()
        revision &+= 1
        destructiveEpoch &+= 1
        sessionScope = newScope
        owner = .localCoordinator
        activeTarget = nil
        capabilities = .fullLocal
        loadingState = .idle
        playbackPhase = .idle
        entriesByID.removeAll()
        baselineSlots.removeAll()
        upcomingSlots.removeAll()
        history.removeAll()
        confirmedCurrent = nil
        reservation = nil
        requestedShuffle = false
        effectiveShuffle = false
        repeatMode = .off
        activeBatches.removeAll()
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

    // MARK: - Replace & Interrupt (1.1 Unified Intents)

    /// `replaceAndPlay` / `replaceQueue`: replaces upcoming and cycle members with `entries`,
    /// preserving the previous `confirmedCurrent` inside `reservation.previousConfirmed` until confirmed.
    public mutating func replaceQueue<R: RandomNumberGenerator>(
        entries: [QueueEntry],
        startIndex: Int = 0,
        owner: QueueOwner = .localCoordinator,
        target: PlaybackTarget? = nil,
        capabilities: QueueCapabilities? = nil,
        loadingState: QueueLoadingState = .idle,
        batchID: UUID? = nil,
        startPlayback: Bool = true,
        shuffleOverride: Bool? = nil,
        pickRandomFirstWhenShuffling: Bool = false,
        using rng: inout R
    ) -> QueueEntry? {
        let prevConfirmed = confirmedCurrent
        let ownerChanged = (self.owner != owner)

        queueID = UUID()
        revision &+= 1
        destructiveEpoch &+= 1
        self.owner = owner
        if ownerChanged {
            history.removeAll()
        }
        self.capabilities = capabilities ?? (owner == .remoteEngine ? .remoteStationDefault : .fullLocal)
        self.loadingState = loadingState
        if let shuffleOverride {
            self.requestedShuffle = (owner == .localCoordinator) ? shuffleOverride : false
        }

        entriesByID.removeAll()
        baselineSlots.removeAll()
        upcomingSlots.removeAll()
        activeBatches.removeAll()
        undoRecord = nil
        confirmedCurrent = nil
        reservation = nil

        guard !entries.isEmpty else {
            self.activeTarget = nil
            self.playbackPhase = .idle
            self.effectiveShuffle = false
            return nil
        }

        for entry in entries {
            entriesByID[entry.id] = entry
            baselineSlots.append(.entry(entry.id))
        }

        if let batchID, loadingState.isLoading {
            activeBatches.insert(batchID)
            baselineSlots.append(.batchTail(batchID))
        }

        let safeIndex = min(max(0, startIndex), entries.count - 1)
        if startPlayback {
            let chosen: QueueEntry
            var remainingSlots: [QueueSlot]

            if requestedShuffle && owner == .localCoordinator && !loadingState.isLoading && pickRandomFirstWhenShuffling {
                var shuffledSlots = entries.map { QueueSlot.entry($0.id) }
                shuffledSlots.shuffle(using: &rng)
                if let firstSlot = shuffledSlots.first,
                   case .entry(let firstID) = firstSlot,
                   let firstEntry = entriesByID[firstID] {
                    chosen = firstEntry
                    remainingSlots = Array(shuffledSlots.dropFirst())
                    effectiveShuffle = true
                } else {
                    chosen = entries[safeIndex]
                    remainingSlots = entries[(safeIndex + 1)...].map { .entry($0.id) }
                    effectiveShuffle = false
                }
            } else {
                chosen = entries[safeIndex]
                remainingSlots = entries[(safeIndex + 1)...].map { .entry($0.id) }
                if let batchID, loadingState.isLoading {
                    remainingSlots.append(.batchTail(batchID))
                }

                if requestedShuffle && owner == .localCoordinator {
                    if loadingState.isLoading {
                        // Defer full shuffle until pagination finishes (P1-02)
                        effectiveShuffle = false
                    } else {
                        var others = entries.filter { $0.id != chosen.id }.map { QueueSlot.entry($0.id) }
                        others.shuffle(using: &rng)
                        remainingSlots = others
                        effectiveShuffle = true
                    }
                } else {
                    effectiveShuffle = false
                }
            }

            if let target {
                self.activeTarget = PlaybackTarget(
                    kind: target.kind,
                    providerResourceID: owner == .remoteEngine
                        ? target.providerResourceID
                        : (chosen.track.providerTrackID.isEmpty ? chosen.track.id : chosen.track.providerTrackID),
                    title: chosen.track.title,
                    storefront: target.storefront
                )
            } else {
                self.activeTarget = PlaybackTarget(
                    kind: owner == .remoteEngine ? .station : .song,
                    providerResourceID: chosen.track.providerTrackID.isEmpty ? chosen.track.id : chosen.track.providerTrackID,
                    title: chosen.track.title
                )
            }
            self.playbackPhase = .preparing

            reservation = ReservationRecord(
                id: UUID(),
                entry: chosen,
                source: .replace,
                previousConfirmed: prevConfirmed,
                forwardCandidate: nil
            )

            upcomingSlots = remainingSlots
            pruneUnreferencedEntries()
            return chosen
        } else {
            self.activeTarget = nil
            self.playbackPhase = .idle
            var allSlots = entries.map { QueueSlot.entry($0.id) }
            if let batchID, loadingState.isLoading {
                allSlots.append(.batchTail(batchID))
            }
            if requestedShuffle && owner == .localCoordinator && !loadingState.isLoading {
                allSlots.shuffle(using: &rng)
                effectiveShuffle = true
            } else {
                effectiveShuffle = false
            }
            upcomingSlots = allSlots
            pruneUnreferencedEntries()
            return nil
        }
    }

    /// `interruptAndPlay`: immediately plays `entries[0]` and places `entries[1...]` before existing upcoming entries.
    /// Does not replace `queueID` or clear `history`.
    public mutating func interruptAndPlay(_ entries: [QueueEntry], batchID: UUID? = nil) throws -> QueueEntry {
        guard !entries.isEmpty else { throw QueueEditError.emptyBatch }
        if owner == .remoteEngine {
            throw QueueEditError.remoteQueueRequiresSwitch(stationTitle: activeTargetEntry?.track.title)
        }
        for e in entries where e.origin.kind == .station {
            throw QueueEditError.remoteStationMixedNotAllowed
        }

        undoRecord = nil

        // Cancel any unconfirmed reservation cleanly before interrupting
        let baseConfirmed = cancelPendingReservationForSameQueue()

        for entry in entries {
            entriesByID[entry.id] = entry
        }

        let head = entries[0]
        let tail = Array(entries.dropFirst())
        let tailSlots = tail.map { QueueSlot.entry($0.id) }
        if !tailSlots.isEmpty {
            upcomingSlots.insert(contentsOf: tailSlots, at: 0)
        }

        // Insert entire batch into baselineSlots after baseConfirmed (or at 0)
        let allNewSlots = entries.map { QueueSlot.entry($0.id) }
        if let baseID = baseConfirmed?.id, let idx = baselineSlots.firstIndex(of: .entry(baseID)) {
            baselineSlots.insert(contentsOf: allNewSlots, at: idx + 1)
        } else {
            baselineSlots.insert(contentsOf: allNewSlots, at: 0)
        }

        if let batchID, loadingState.isLoading {
            activeBatches.insert(batchID)
        }

        activeTarget = PlaybackTarget(
            kind: .song,
            providerResourceID: head.track.providerTrackID.isEmpty ? head.track.id : head.track.providerTrackID,
            title: head.track.title
        )
        playbackPhase = .preparing
        reservation = ReservationRecord(
            id: UUID(),
            entry: head,
            source: .interrupt,
            previousConfirmed: baseConfirmed,
            forwardCandidate: nil
        )
        revision &+= 1
        return head
    }

    // MARK: - Confirmation & Failure (P0-02)

    /// Called when the engine confirms playback has actually started for `entryID`.
    /// Finalizes `reservation` at most once and records `previousConfirmed` in `history`.
    public mutating func confirmEntry(_ entryID: UUID) {
        guard let res = reservation, res.entry.id == entryID else {
            // Already confirmed or mismatched reservation
            return
        }

        if res.source != .previous && res.source != .repeatOne, let prev = res.previousConfirmed {
            appendToHistory(prev)
        }

        entriesByID[res.entry.id] = res.entry
        confirmedCurrent = res.entry
        reservation = nil
        playbackPhase = .playing
        revision &+= 1
        pruneUnreferencedEntries()
    }

    /// Updates metadata for the remote station track (e.g. MusicKit itemChanged)
    /// while preserving `PlaybackOrigin`, `UUID`, and `activeTarget` (the station resource ID).
    /// Metadata updates NEVER confirm transport playing on their own.
    public mutating func updateRemoteCurrentTrack(_ track: MusicTrack) {
        guard owner == .remoteEngine else { return }
        if var res = reservation {
            let updated = QueueEntry(
                id: res.entry.id,
                track: track,
                origin: res.entry.origin,
                batchID: res.entry.batchID,
                addedAt: res.entry.addedAt
            )
            res.entry = updated
            reservation = res
            entriesByID[updated.id] = updated
            revision &+= 1
        } else if let cur = confirmedCurrent {
            let updated = QueueEntry(
                id: cur.id,
                track: track,
                origin: cur.origin,
                batchID: cur.batchID,
                addedAt: cur.addedAt
            )
            entriesByID[updated.id] = updated
            confirmedCurrent = updated
            revision &+= 1
        }
    }

    /// Marks the pending reservation as failed without adding it to history or faking `confirmedCurrent`.
    public mutating func markPendingFailed() {
        guard reservation != nil else { return }
        reservation?.isFailed = true
        playbackPhase = .failed
        revision &+= 1
    }

    /// Cancels reservation on explicit user stop; unconfirmed `.next` / `.directPlay` entries return to upcoming.
    public mutating func clearPendingOnStop() {
        defer {
            playbackPhase = .stoppedByUser
            revision &+= 1
            pruneUnreferencedEntries()
        }
        guard let res = reservation else { return }
        reservation = nil

        switch res.source {
        case .next:
            if !res.isFailed && baselineSlots.contains(.entry(res.entry.id)) {
                entriesByID[res.entry.id] = res.entry
                upcomingSlots.insert(.entry(res.entry.id), at: 0)
            }
        case .directPlay(let origIdx):
            if !res.isFailed && baselineSlots.contains(.entry(res.entry.id)) {
                entriesByID[res.entry.id] = res.entry
                let insertAt = min(origIdx ?? 0, upcomingSlots.count)
                upcomingSlots.insert(.entry(res.entry.id), at: insertAt)
            }
        case .previous:
            rollbackPreviousReservation(res)
        case .replace, .interrupt, .repeatOne:
            break
        }
    }

    // MARK: - Advancement & History (Q02, Q03, Q04, Q05, Q16)

    /// Advances on natural track end. Respects `.one`, `.all`, `requestedShuffle`, and unfinished batch boundaries.
    public mutating func advanceOnNaturalEnd<R: RandomNumberGenerator>(using rng: inout R) -> QueueAdvancementResult {
        guard owner == .localCoordinator else { return .stop }

        if repeatMode == .one, let current = confirmedCurrent ?? reservation?.entry {
            reservation = ReservationRecord(
                id: UUID(),
                entry: current,
                source: .repeatOne,
                previousConfirmed: confirmedCurrent,
                forwardCandidate: nil
            )
            activeTarget = PlaybackTarget(
                kind: .song,
                providerResourceID: current.track.providerTrackID.isEmpty ? current.track.id : current.track.providerTrackID,
                title: current.track.title
            )
            playbackPhase = .preparing
            revision &+= 1
            return .play(entry: current, isRepeatOne: true)
        }

        return advanceNext(using: &rng)
    }

    /// Manual Next (ignores repeat-one, skips any unconfirmed/failed reservation without adding it to history,
    /// and respects unfinished pagination batch boundaries).
    public mutating func advanceNext<R: RandomNumberGenerator>(using rng: inout R, allowCrossBatchBoundary: Bool = false) -> QueueAdvancementResult {
        guard owner == .localCoordinator else { return .stop }

        // If a reservation was pending/failed, it is explicitly skipped (never enters history).
        let baseConfirmed = confirmedCurrent
        reservation = nil

        while let headSlot = upcomingSlots.first {
            switch headSlot {
            case .batchTail(let batchID):
                if activeBatches.contains(batchID) && !allowCrossBatchBoundary {
                    playbackPhase = .waitingForPage
                    revision &+= 1
                    return .waitingForPage(batchID: batchID)
                } else {
                    upcomingSlots.removeFirst()
                    continue
                }
            case .entry(let nextID):
                upcomingSlots.removeFirst()
                guard let nextEntry = entriesByID[nextID] else {
                    continue
                }
                reservation = ReservationRecord(
                    id: UUID(),
                    entry: nextEntry,
                    source: .next,
                    previousConfirmed: baseConfirmed,
                    forwardCandidate: nil
                )
                activeTarget = PlaybackTarget(
                    kind: .song,
                    providerResourceID: nextEntry.track.providerTrackID.isEmpty ? nextEntry.track.id : nextEntry.track.providerTrackID,
                    title: nextEntry.track.title
                )
                playbackPhase = .preparing
                revision &+= 1
                return .play(entry: nextEntry, isRepeatOne: false)
            }
        }

        // Do not start a new repeat-all round while a batch is still loading
        if !activeBatches.isEmpty && !allowCrossBatchBoundary {
            if let bid = activeBatches.first {
                playbackPhase = .waitingForPage
                revision &+= 1
                return .waitingForPage(batchID: bid)
            }
        }

        if repeatMode == .all {
            var candidateIDs = baselineEntryIDs
            if !candidateIDs.isEmpty {
                if requestedShuffle {
                    candidateIDs.shuffle(using: &rng)
                    effectiveShuffle = true
                    if candidateIDs.count > 1,
                       let currentID = baseConfirmed?.id,
                       candidateIDs.first == currentID {
                        let swapIdx = Int.random(in: 1..<candidateIDs.count, using: &rng)
                        candidateIDs.swapAt(0, swapIdx)
                    }
                } else {
                    effectiveShuffle = false
                }
                upcomingSlots = candidateIDs.map { .entry($0) }
                let nextID = upcomingSlots.removeFirst().entryID!
                if let nextEntry = entriesByID[nextID] {
                    reservation = ReservationRecord(
                        id: UUID(),
                        entry: nextEntry,
                        source: .next,
                        previousConfirmed: baseConfirmed,
                        forwardCandidate: nil
                    )
                    activeTarget = PlaybackTarget(
                        kind: .song,
                        providerResourceID: nextEntry.track.providerTrackID.isEmpty ? nextEntry.track.id : nextEntry.track.providerTrackID,
                        title: nextEntry.track.title
                    )
                    playbackPhase = .preparing
                    revision &+= 1
                    return .play(entry: nextEntry, isRepeatOne: false)
                }
            }
        }

        playbackPhase = .exhausted
        revision &+= 1
        return .exhausted
    }

    /// Manual Previous: if `positionMs > 3000`, returns `.seekToZero`.
    /// Otherwise pops from `history`, pushes current target to head of `upcomingSlots` (deduplicated) as forward candidate.
    public mutating func retreatPrevious(positionMs: Int64) -> QueueAdvancementResult {
        guard owner == .localCoordinator else { return .stop }
        if positionMs > 3_000 {
            return .seekToZero
        }
        guard let prevEntry = history.popLast() else {
            return .seekToZero
        }

        let currentTarget = activeTargetEntry
        if let current = currentTarget, current.id != prevEntry.id {
            entriesByID[current.id] = current
            upcomingSlots.removeAll { $0 == .entry(current.id) }
            upcomingSlots.insert(.entry(current.id), at: 0)
        }

        entriesByID[prevEntry.id] = prevEntry
        reservation = ReservationRecord(
            id: UUID(),
            entry: prevEntry,
            source: .previous,
            previousConfirmed: confirmedCurrent,
            forwardCandidate: currentTarget
        )
        activeTarget = PlaybackTarget(
            kind: .song,
            providerResourceID: prevEntry.track.providerTrackID.isEmpty ? prevEntry.track.id : prevEntry.track.providerTrackID,
            title: prevEntry.track.title
        )
        playbackPhase = .preparing
        revision &+= 1
        return .play(entry: prevEntry, isRepeatOne: false)
    }

    // MARK: - Playback Modes (Q03, Q04, Q05, P1-02)

    public mutating func setRepeatMode(_ mode: PlaybackState.RepeatMode) {
        repeatMode = mode
        revision &+= 1
    }

    public mutating func setShuffleEnabled<R: RandomNumberGenerator>(_ enabled: Bool, using rng: inout R) {
        guard requestedShuffle != enabled else { return }
        requestedShuffle = enabled

        if enabled {
            if loadingState.isLoading {
                // P1-02: Do not pretend partial collection is fully shuffled while loading
                effectiveShuffle = false
            } else {
                applyFullShuffleToUpcoming(using: &rng)
                effectiveShuffle = true
            }
        } else {
            effectiveShuffle = false
            restoreBaselineRelativeOrderForUpcoming()
        }
        revision &+= 1
    }

    private mutating func applyFullShuffleToUpcoming<R: RandomNumberGenerator>(using rng: inout R) {
        var entryIDs = upcomingEntryIDs
        entryIDs.shuffle(using: &rng)
        // Preserve any trailing batchTail sentinels if present (empty when not loading)
        let tails = upcomingSlots.filter { $0.batchID != nil }
        upcomingSlots = entryIDs.map { .entry($0) } + tails
    }

    private mutating func restoreBaselineRelativeOrderForUpcoming() {
        let rank = Dictionary(uniqueKeysWithValues: baselineEntryIDs.enumerated().map { ($1, $0) })
        let entryIDs = upcomingEntryIDs.sorted { (lhs, rhs) in
            (rank[lhs] ?? Int.max) < (rank[rhs] ?? Int.max)
        }
        let tails = upcomingSlots.filter { $0.batchID != nil }
        upcomingSlots = entryIDs.map { .entry($0) } + tails
    }

    // MARK: - Queue Editing (Q06 - Q15, Q20)

    public func validateEditContext(
        expectedQueueID: UUID? = nil,
        expectedSessionScope: String? = nil,
        expectedRevision: UInt64? = nil,
        expectedDestructiveEpoch: UInt64? = nil
    ) throws {
        if let expectedQueueID, expectedQueueID != queueID {
            throw QueueEditError.queueMismatch(expected: expectedQueueID, actual: queueID)
        }
        if let expectedSessionScope, expectedSessionScope != sessionScope {
            throw QueueEditError.sessionMismatch
        }
        if let expectedDestructiveEpoch, expectedDestructiveEpoch != destructiveEpoch {
            throw QueueEditError.staleEpoch
        }
        if let expectedRevision, expectedRevision != revision {
            throw QueueEditError.revisionConflict(expected: expectedRevision, actual: revision)
        }
    }

    /// Q13 / `prepend`: Insert entries at the head of upcoming (preserving batch order).
    /// Inserts into `baselineSlots` right after the active target so turning off shuffle keeps them ahead of later upcoming items.
    public mutating func insertNext(
        _ entries: [QueueEntry],
        batchID: UUID? = nil
    ) throws {
        guard capabilities.canInsertNext else {
            throw QueueEditError.unsupportedCapability("当前播放模式不支持插入下一首。")
        }
        guard !entries.isEmpty else { throw QueueEditError.emptyBatch }
        for e in entries where e.origin.kind == .station {
            throw QueueEditError.remoteStationMixedNotAllowed
        }

        undoRecord = nil
        for entry in entries {
            entriesByID[entry.id] = entry
        }

        let newSlots = entries.map { QueueSlot.entry($0.id) }
        upcomingSlots.insert(contentsOf: newSlots, at: 0)

        if let currentID = activeTargetEntry?.id, let idx = baselineSlots.firstIndex(of: .entry(currentID)) {
            baselineSlots.insert(contentsOf: newSlots, at: idx + 1)
        } else {
            baselineSlots.insert(contentsOf: newSlots, at: 0)
        }

        if let batchID, loadingState.isLoading {
            activeBatches.insert(batchID)
        }

        revision &+= 1
    }

    /// Q12 / `append`: Append entries to the tail of upcoming and baseline without re-shuffling.
    public mutating func append(
        _ entries: [QueueEntry],
        batchID: UUID? = nil
    ) throws {
        guard capabilities.canAppend else {
            throw QueueEditError.unsupportedCapability("当前播放模式不支持添加到队列。")
        }
        guard !entries.isEmpty else { throw QueueEditError.emptyBatch }
        for e in entries where e.origin.kind == .station {
            throw QueueEditError.remoteStationMixedNotAllowed
        }

        undoRecord = nil
        for entry in entries {
            entriesByID[entry.id] = entry
        }

        let newSlots = entries.map { QueueSlot.entry($0.id) }
        upcomingSlots.append(contentsOf: newSlots)
        baselineSlots.append(contentsOf: newSlots)

        if let batchID, loadingState.isLoading {
            activeBatches.insert(batchID)
        }

        revision &+= 1
    }

    /// Q07 / `playExistingEntry`: Play a specific upcoming entry by ID without disturbing the relative order of remaining entries.
    public mutating func playEntry(id: UUID) throws -> QueueMutationResult {
        guard capabilities.canPlayEntry else {
            throw QueueEditError.unsupportedCapability("当前播放模式不支持选择待播曲目。")
        }
        guard let origIdx = upcomingSlots.firstIndex(of: .entry(id)), let target = entriesByID[id] else {
            throw QueueEditError.entryNotFound(id)
        }

        undoRecord = nil
        let cancelledEntry = reservation?.entry
        let baseConfirmed = cancelPendingReservationForSameQueue()

        // Re-locate after potential restore
        let actualIdx = upcomingSlots.firstIndex(of: .entry(id)) ?? origIdx
        upcomingSlots.remove(at: actualIdx)

        reservation = ReservationRecord(
            id: UUID(),
            entry: target,
            source: .directPlay(originalUpcomingIndex: actualIdx),
            previousConfirmed: baseConfirmed,
            forwardCandidate: nil
        )
        activeTarget = PlaybackTarget(
            kind: .song,
            providerResourceID: target.track.providerTrackID.isEmpty ? target.track.id : target.track.providerTrackID,
            title: target.track.title
        )
        playbackPhase = .preparing
        revision &+= 1

        return QueueMutationResult(
            snapshot: makeSnapshot(),
            cancelledPendingEntry: cancelledEntry,
            playbackTarget: target
        )
    }

    /// Q08 / Q15: Remove one or more upcoming entries by ID. Never removes confirmedCurrent or history.
    /// Does NOT invalidate active pagination batches when a page's last item is deleted (BUG-08).
    public mutating func removeEntries(ids: [UUID]) throws {
        guard capabilities.canRemove else {
            throw QueueEditError.unsupportedCapability("当前播放模式不支持移除待播曲目。")
        }
        let idSet = Set(ids)
        let validRemovals = upcomingEntryIDs.filter { idSet.contains($0) }
        guard !validRemovals.isEmpty else {
            throw QueueEditError.entryNotFound(ids.first ?? UUID())
        }

        let prevBaseline = baselineSlots
        let prevUpcoming = upcomingSlots
        var removedMap: [UUID: QueueEntry] = [:]
        for id in validRemovals {
            if let entry = entriesByID[id] {
                removedMap[id] = entry
            }
        }

        upcomingSlots.removeAll { slot in
            if case .entry(let id) = slot { return idSet.contains(id) }
            return false
        }
        baselineSlots.removeAll { slot in
            if case .entry(let id) = slot { return idSet.contains(id) }
            return false
        }

        revision &+= 1
        undoRecord = UndoRecord(
            queueID: queueID,
            sessionScope: sessionScope,
            postEditRevision: revision,
            previousBaselineSlots: prevBaseline,
            previousUpcomingSlots: prevUpcoming,
            removedEntries: removedMap,
            description: validRemovals.count == 1 ? "移除 1 首曲目" : "移除 \(validRemovals.count) 首曲目"
        )
        pruneUnreferencedEntries()
    }

    /// Q09 / Q10 / Q11 / Q15: Move one or more upcoming entries before `targetID` (or to the end if `targetID == nil`).
    public mutating func moveEntries(ids: [UUID], before targetID: UUID?) throws {
        guard capabilities.canReorder else {
            throw QueueEditError.unsupportedCapability("当前播放模式不支持调整队列顺序。")
        }
        guard !ids.isEmpty else { throw QueueEditError.emptyBatch }

        let idSet = Set(ids)
        let currentUpcomingIDs = upcomingEntryIDs
        let movingIDs = currentUpcomingIDs.filter { idSet.contains($0) }
        guard movingIDs.count == idSet.count else {
            let missing = idSet.first { !currentUpcomingIDs.contains($0) } ?? UUID()
            throw QueueEditError.entryNotFound(missing)
        }

        if let targetID {
            guard !idSet.contains(targetID), currentUpcomingIDs.contains(targetID) else {
                throw QueueEditError.invalidTarget(targetID)
            }
        }

        undoRecord = nil
        let movingSlots = movingIDs.map { QueueSlot.entry($0) }

        upcomingSlots.removeAll { slot in
            if case .entry(let id) = slot { return idSet.contains(id) }
            return false
        }
        if let targetID, let insertIdx = upcomingSlots.firstIndex(of: .entry(targetID)) {
            upcomingSlots.insert(contentsOf: movingSlots, at: insertIdx)
        } else {
            upcomingSlots.append(contentsOf: movingSlots)
        }

        baselineSlots.removeAll { slot in
            if case .entry(let id) = slot { return idSet.contains(id) }
            return false
        }
        if let targetID, let baseIdx = baselineSlots.firstIndex(of: .entry(targetID)) {
            baselineSlots.insert(contentsOf: movingSlots, at: baseIdx)
        } else {
            baselineSlots.append(contentsOf: movingSlots)
        }

        revision &+= 1
    }

    /// Q06 / P1-04: Clear all upcoming entries, cycle members, and active pagination batches.
    /// Keeps current audio, reservation (if preparing), history, and repeat/shuffle mode settings.
    public mutating func clearUpcoming() throws {
        guard capabilities.canClear else {
            throw QueueEditError.unsupportedCapability("当前播放模式不支持清空队列。")
        }

        let prevBaseline = baselineSlots
        let prevUpcoming = upcomingSlots
        var removedMap: [UUID: QueueEntry] = [:]
        for id in Set(baselineEntryIDs).union(upcomingEntryIDs) {
            if id != confirmedCurrent?.id && id != reservation?.entry.id, let entry = entriesByID[id] {
                removedMap[id] = entry
            }
        }

        let hadContent = !upcomingEntryIDs.isEmpty || !baselineEntryIDs.isEmpty || !activeBatches.isEmpty
        upcomingSlots.removeAll()
        baselineSlots.removeAll()
        activeBatches.removeAll()
        if loadingState.isLoading || loadingState.totalCount != nil {
            loadingState = .idle
        }
        destructiveEpoch &+= 1
        revision &+= 1

        if hadContent {
            undoRecord = UndoRecord(
                queueID: queueID,
                sessionScope: sessionScope,
                postEditRevision: revision,
                previousBaselineSlots: prevBaseline,
                previousUpcomingSlots: prevUpcoming,
                removedEntries: removedMap,
                description: "清空待播队列"
            )
        }
        pruneUnreferencedEntries()
    }

    /// Q20: Single-step safe undo for `removeEntries` and `clearUpcoming`.
    /// Note: playback progress does not invalidate undo; only structural `revision` changes or session/queue changes do.
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
            throw QueueEditError.undoUnavailable("队列已变化，无法撤销。")
        }

        for (id, entry) in record.removedEntries {
            entriesByID[id] = entry
        }
        // Do not resurrect invalidated pagination batch sentinels
        baselineSlots = record.previousBaselineSlots.filter { $0.batchID == nil }
        upcomingSlots = record.previousUpcomingSlots.filter { $0.batchID == nil }
        undoRecord = nil
        revision &+= 1
    }

    // MARK: - Pagination Batch Commits (P1-01, P1-02)

    /// Commits a page of entries belonging to `batchID` right before `.batchTail(batchID)` in `upcomingSlots` and `baselineSlots`.
    /// When `isComplete` is true and `requestedShuffle` is true, performs the deferred full Fisher–Yates shuffle (P1-02).
    @discardableResult
    public mutating func commitPaginatedBatch<R: RandomNumberGenerator>(
        _ entries: [QueueEntry],
        batchID: UUID,
        expectedQueueID: UUID,
        expectedSessionScope: String,
        expectedDestructiveEpoch: UInt64? = nil,
        loadingState: QueueLoadingState,
        using rng: inout R
    ) -> Bool {
        guard expectedQueueID == queueID,
              expectedSessionScope == sessionScope,
              activeBatches.contains(batchID) else {
            return false
        }
        if let expectedDestructiveEpoch, expectedDestructiveEpoch != destructiveEpoch {
            return false
        }

        for entry in entries {
            entriesByID[entry.id] = entry
        }
        let newSlots = entries.map { QueueSlot.entry($0.id) }

        if !newSlots.isEmpty {
            if let tailIdx = upcomingSlots.firstIndex(of: .batchTail(batchID)) {
                upcomingSlots.insert(contentsOf: newSlots, at: tailIdx)
            } else {
                upcomingSlots.append(contentsOf: newSlots)
            }

            if let baseTailIdx = baselineSlots.firstIndex(of: .batchTail(batchID)) {
                baselineSlots.insert(contentsOf: newSlots, at: baseTailIdx)
            } else {
                baselineSlots.append(contentsOf: newSlots)
            }
        }

        self.loadingState = loadingState
        if case .complete = loadingState {
            activeBatches.remove(batchID)
            upcomingSlots.removeAll { $0 == .batchTail(batchID) }
            baselineSlots.removeAll { $0 == .batchTail(batchID) }

            if requestedShuffle && !effectiveShuffle && owner == .localCoordinator {
                applyFullShuffleToUpcoming(using: &rng)
                effectiveShuffle = true
            }
        }

        revision &+= 1
        return true
    }

    public mutating func finishOrFailBatch(_ batchID: UUID, loadingState: QueueLoadingState) {
        guard activeBatches.contains(batchID) else { return }
        self.loadingState = loadingState
        if case .complete = loadingState {
            activeBatches.remove(batchID)
            upcomingSlots.removeAll { $0 == .batchTail(batchID) }
            baselineSlots.removeAll { $0 == .batchTail(batchID) }
        } else if case .failed(_, _, _, let isRetryable) = loadingState, !isRetryable {
            activeBatches.remove(batchID)
            upcomingSlots.removeAll { $0 == .batchTail(batchID) }
            baselineSlots.removeAll { $0 == .batchTail(batchID) }
        }
        revision &+= 1
    }

    public mutating func invalidateBatch(_ batchID: UUID) {
        activeBatches.remove(batchID)
        upcomingSlots.removeAll { $0 == .batchTail(batchID) }
        baselineSlots.removeAll { $0 == .batchTail(batchID) }
        revision &+= 1
    }

    // MARK: - Persistence Export / Restore (Q17, P0-01, P0-04)

    public func exportPersistencePayload() -> QueuePersistencePayload {
        var referencedIDs = Set(baselineEntryIDs).union(upcomingEntryIDs)
        if let cid = confirmedCurrent?.id { referencedIDs.insert(cid) }
        if let pid = reservation?.entry.id { referencedIDs.insert(pid) }

        let persistedEntries = referencedIDs.compactMap { entriesByID[$0] }
        return QueuePersistencePayload(
            queueID: queueID,
            entries: persistedEntries,
            baselineOrder: baselineEntryIDs,
            upcomingOrder: upcomingEntryIDs,
            history: history,
            currentEntryID: confirmedCurrent?.id,
            activeTarget: activeTarget,
            shuffleEnabled: requestedShuffle,
            repeatMode: repeatMode,
            owner: owner
        )
    }

    /// Restores queue state from a persisted payload, validating all IDs and integrity.
    public mutating func restore(from payload: QueuePersistencePayload, sessionScope: String) -> QueueEntry? {
        self.queueID = payload.queueID
        self.revision &+= 1
        self.destructiveEpoch &+= 1
        self.sessionScope = sessionScope
        self.owner = payload.owner
        self.activeTarget = payload.activeTarget
        self.capabilities = payload.owner == .remoteEngine ? .remoteStationDefault : .fullLocal
        self.loadingState = .idle
        self.requestedShuffle = payload.shuffleEnabled
        self.effectiveShuffle = payload.shuffleEnabled
        self.repeatMode = payload.repeatMode
        self.undoRecord = nil
        self.activeBatches.removeAll()
        self.reservation = nil

        var map: [UUID: QueueEntry] = [:]
        for e in payload.entries {
            map[e.id] = e
        }
        for h in payload.history where map[h.id] == nil {
            map[h.id] = h
        }
        self.entriesByID = map
        self.baselineSlots = payload.baselineOrder.compactMap { map[$0] != nil ? .entry($0) : nil }
        self.upcomingSlots = payload.upcomingOrder.compactMap { map[$0] != nil ? .entry($0) : nil }
        self.history = Array(payload.history.suffix(Self.maxHistoryCount))

        if let cid = payload.currentEntryID, let restored = map[cid] {
            if payload.owner == .remoteEngine {
                let stationID = payload.activeTarget?.providerResourceID ?? (restored.origin.kind == .station ? restored.origin.sourceID : nil)
                if let stationID, !stationID.isEmpty {
                    self.confirmedCurrent = restored
                    self.playbackPhase = .paused
                    if self.activeTarget == nil {
                        self.activeTarget = PlaybackTarget(
                            kind: .station,
                            providerResourceID: stationID,
                            title: restored.origin.sourceTitle ?? restored.track.title
                        )
                    }
                } else {
                    self.confirmedCurrent = nil
                    self.playbackPhase = .idle
                    self.owner = .localCoordinator
                    self.capabilities = .fullLocal
                }
            } else {
                self.confirmedCurrent = restored
                self.playbackPhase = .paused
                if self.activeTarget == nil {
                    self.activeTarget = PlaybackTarget(
                        kind: .song,
                        providerResourceID: restored.track.providerTrackID.isEmpty ? restored.track.id : restored.track.providerTrackID,
                        title: restored.track.title
                    )
                }
            }
        } else {
            self.confirmedCurrent = nil
            self.playbackPhase = .idle
        }

        pruneUnreferencedEntries()
        return confirmedCurrent
    }

    // MARK: - Internal Helpers

    private mutating func cancelPendingReservationForSameQueue() -> QueueEntry? {
        guard let res = reservation else { return confirmedCurrent }
        reservation = nil

        switch res.source {
        case .next:
            if !res.isFailed && baselineSlots.contains(.entry(res.entry.id)) {
                entriesByID[res.entry.id] = res.entry
                upcomingSlots.insert(.entry(res.entry.id), at: 0)
            }
            return res.previousConfirmed
        case .directPlay(let origIdx):
            if !res.isFailed && baselineSlots.contains(.entry(res.entry.id)) {
                entriesByID[res.entry.id] = res.entry
                let insertAt = min(origIdx ?? 0, upcomingSlots.count)
                upcomingSlots.insert(.entry(res.entry.id), at: insertAt)
            }
            return res.previousConfirmed
        case .previous:
            rollbackPreviousReservation(res)
            return res.previousConfirmed
        case .replace, .interrupt, .repeatOne:
            return res.previousConfirmed
        }
    }

    private mutating func rollbackPreviousReservation(_ res: ReservationRecord) {
        if let fwd = res.forwardCandidate {
            upcomingSlots.removeAll { $0 == .entry(fwd.id) }
        }
        appendToHistory(res.entry)
    }

    private mutating func appendToHistory(_ entry: QueueEntry) {
        history.append(entry)
        if history.count > Self.maxHistoryCount {
            history.removeFirst(history.count - Self.maxHistoryCount)
        }
    }

    private mutating func pruneUnreferencedEntries() {
        var keep = Set(baselineEntryIDs).union(upcomingEntryIDs)
        if let cid = confirmedCurrent?.id { keep.insert(cid) }
        if let pid = reservation?.entry.id { keep.insert(pid) }
        if let prevID = reservation?.previousConfirmed?.id { keep.insert(prevID) }
        for h in history { keep.insert(h.id) }
        if let u = undoRecord {
            keep.formUnion(u.removedEntries.keys)
        }
        entriesByID = entriesByID.filter { keep.contains($0.key) }
    }
}
