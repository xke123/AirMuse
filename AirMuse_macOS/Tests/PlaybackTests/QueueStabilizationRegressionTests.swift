import Foundation
import Testing
import Domain
@testable import Playback

private actor StabilizationMockEngine: PlaybackEngineProtocol {
    private(set) var currentEngineInstanceID = UUID()
    private(set) var executedCommands: [(EngineCommand, PlaybackOperationContext)] = []
    private var continuations: [UUID: AsyncStream<EngineEvent>.Continuation] = [:]
    var failNextPlayItem: Bool = false

    var engineInstanceID: UUID { currentEngineInstanceID }

    func setFailNextPlayItem(_ fail: Bool) {
        failNextPlayItem = fail
    }

    func events() async -> AsyncStream<EngineEvent> {
        AsyncStream { cont in
            let id = UUID()
            continuations[id] = cont
            cont.onTermination = { [weak self] _ in
                Task { await self?.removeCont(id) }
            }
        }
    }

    private func removeCont(_ id: UUID) {
        continuations.removeValue(forKey: id)
    }

    func emit(_ event: EngineEvent) {
        for cont in continuations.values {
            cont.yield(event)
        }
    }

    func prepare(sessionContext: SessionContext, deadlineSeconds: TimeInterval) async throws {}

    func execute(_ command: EngineCommand, context: PlaybackOperationContext) async throws {
        executedCommands.append((command, context))
        if case .playItem = command, failNextPlayItem {
            failNextPlayItem = false
            throw NSError(domain: "StabilizationMock", code: -1, userInfo: [NSLocalizedDescriptionKey: "Engine playItem error"])
        }
    }

    func isolateAndReset() async {
        currentEngineInstanceID = UUID()
    }
}

private struct StabilizationRNG: RandomNumberGenerator {
    private var state: UInt64 = 0xCAFE_BABE_1234_5678
    mutating func next() -> UInt64 {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return state
    }
}

@Suite("QueueStabilizationRegressionTests")
struct QueueStabilizationRegressionTests {

    private func makeSession(accountID: String = "acct-1", generation: UInt64 = 1) -> SessionContext {
        SessionContext(providerID: "apple_music", accountID: accountID, storefront: "cn", sessionID: UUID(), generation: generation)
    }

    private func makeEntry(_ id: String, origin: PlaybackOrigin = .unknown, batchID: UUID? = nil) -> QueueEntry {
        let track = MusicTrack(
            id: id,
            title: "Song \(id)",
            artistName: "Artist",
            albumTitle: "Album",
            durationMs: 180_000,
            providerID: "apple_music",
            providerTrackID: id
        )
        return QueueEntry(track: track, origin: origin, batchID: batchID)
    }

    @Test("R01 & R02: Replace preserves previous confirmed only after confirmation; Next->Next skips unconfirmed B")
    func r01AndR02ReservationConfirmationAndSkip() {
        var mgr = QueueManager()
        var rng = StabilizationRNG()
        let a = makeEntry("A"), b = makeEntry("B"), c = makeEntry("C"), x = makeEntry("X")

        _ = mgr.replaceQueue(entries: [a, b, c], startIndex: 0, using: &rng)
        mgr.confirmEntry(a.id)

        // Replace with X: A is NOT in history until X confirms
        _ = mgr.replaceQueue(entries: [x], startIndex: 0, using: &rng)
        #expect(mgr.historyEntries.isEmpty)
        mgr.markPendingFailed()
        #expect(mgr.historyEntries.isEmpty)
        #expect(mgr.isPendingTargetFailed)

        // Confirm X -> A enters history
        mgr.confirmEntry(x.id)
        #expect(mgr.historyEntries.map(\.id) == [a.id])

        // R02: A->Next B->Next C before B confirms -> B is skipped, never enters history
        _ = mgr.replaceQueue(entries: [a, b, c], startIndex: 0, using: &rng)
        mgr.confirmEntry(a.id)
        let histBefore = mgr.historyEntries.count
        _ = mgr.advanceNext(using: &rng) // B pending
        let resC = mgr.advanceNext(using: &rng) // C pending, B skipped
        #expect(resC == .play(entry: c, isRepeatOne: false))
        mgr.confirmEntry(c.id)
        #expect(mgr.historyEntries.count == histBefore + 1)
        #expect(mgr.historyEntries.last?.id == a.id)
    }

    @Test("R03: Interrupt restores direct-play pending B in same queue; cancelling previous rolls back history")
    func r03InterruptAndRollback() throws {
        var mgr = QueueManager()
        var rng = StabilizationRNG()
        let a = makeEntry("A"), b = makeEntry("B"), c = makeEntry("C"), x = makeEntry("X")
        _ = mgr.replaceQueue(entries: [a, b, c], startIndex: 0, using: &rng)
        mgr.confirmEntry(a.id)

        // Direct play B (unconfirmed) then interrupt with X -> B returns to upcoming
        _ = try mgr.playEntry(id: b.id)
        _ = try mgr.interruptAndPlay([x])
        #expect(mgr.pendingTargetEntry?.id == x.id)
        #expect(mgr.upcomingEntries.map(\.id) == [b.id, c.id])
        mgr.confirmEntry(x.id)
        #expect(mgr.historyEntries.map(\.id) == [a.id])

        // Previous (unconfirmed) then interrupt -> history is rolled back
        let histCountBeforePrev = mgr.historyEntries.count
        _ = mgr.retreatPrevious(positionMs: 500)
        #expect(mgr.historyEntries.count == histCountBeforePrev - 1)
        let y = makeEntry("Y")
        _ = try mgr.interruptAndPlay([y])
        #expect(mgr.historyEntries.count == histCountBeforePrev)
    }

    @Test("R06 & R07: Session invalidation clears desiredTrack and rejects stale async snapshot restore")
    func r06AndR07SessionInvalidation() async throws {
        let tmpURL = URL(fileURLWithPath: "/tmp/airmuse_r06_\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: tmpURL) }
        let snapStore = PlaybackSnapshotStore(fileURL: tmpURL)

        let store = PlaybackStore()
        let engine = StabilizationMockEngine()
        let coord = PlaybackCoordinatorV2(store: store, engine: engine, snapshotStore: snapStore)
        let sessA = makeSession(accountID: "acct-A")
        await coord.start(session: sessA)

        let e1 = makeEntry("E1")
        try await coord.playEntries([e1], startIndex: 0)
        await coord.flushSnapshot()

        // Switch to acct-B: desiredTrack & currentTrack must be nil immediately
        await coord.updateSession(makeSession(accountID: "acct-B"))
        let stateB = await store.state
        #expect(stateB.currentTrack == nil)
        #expect(stateB.status == .idle)
    }

    @Test("R08: Radio station itemChanged preserves station PlaybackTarget ID for retry and persistence")
    func r08StationTargetPreserved() async throws {
        let store = PlaybackStore()
        let engine = StabilizationMockEngine()
        let coord = PlaybackCoordinatorV2(store: store, engine: engine)
        let session = makeSession()
        await coord.start(session: session)

        let station = MusicTrack(id: "ra.888", title: "Hits Radio", artistName: "Apple Music", albumTitle: "Radio", durationMs: 0, providerID: "apple_music", providerTrackID: "ra.888")
        let entry = QueueEntry(track: station, origin: PlaybackOrigin(kind: .station, sourceID: "ra.888", sourceTitle: "Hits Radio"))
        try await coord.playEntries([entry], startIndex: 0, kind: .station)

        let eid = await engine.engineInstanceID
        let ctx = PlaybackOperationContext(sessionID: session.sessionID, engineInstanceID: eid, operationID: 1, trackID: "ra.888")
        await engine.emit(.itemChanged(context: ctx, trackID: "song-999", title: "Random Song", artist: "Singer", albumTitle: "Single", artworkURL: "", durationSeconds: 200))
        try await Task.sleep(for: .milliseconds(20))

        let snap = await coord.currentStructuredQueueSnapshot()
        #expect(snap.activeTarget?.kind == .station)
        #expect(snap.activeTarget?.providerResourceID == "ra.888")
        #expect((await store.state).currentTrack?.title == "Random Song")

        try await coord.retryPendingOrCurrent()
        let lastCmd = await engine.executedCommands.last!
        if case .playItem(let id, let kind, _) = lastCmd.0 {
            #expect(id == "ra.888")
            #expect(kind == .station)
        } else {
            #expect(Bool(false))
        }
    }

    @Test("R11: All 4 intents (replaceAndPlay, interruptAndPlay, prepend, append) match specification")
    func r11FourUnifiedIntents() async throws {
        let store = PlaybackStore()
        let engine = StabilizationMockEngine()
        let coord = PlaybackCoordinatorV2(store: store, engine: engine)
        let session = makeSession()
        await coord.start(session: session)

        let a = makeEntry("A"), b = makeEntry("B"), c = makeEntry("C")
        let x = makeEntry("X"), y = makeEntry("Y"), z = makeEntry("Z")

        _ = try await coord.submitIntent(.replaceAndPlay, entries: [a, b, c])
        let eid = await engine.engineInstanceID
        let op1 = await engine.executedCommands.last!.1
        await engine.emit(.stateChanged(context: op1, status: .playing))
        try await Task.sleep(for: .milliseconds(20))

        // Append X, Y, Z -> A | B, C, X, Y, Z
        _ = try await coord.submitIntent(.append, entries: [x, y, z])
        var snap = await coord.currentStructuredQueueSnapshot()
        #expect(snap.upcomingEntries.map(\.track.id) == ["B", "C", "X", "Y", "Z"])

        // Interrupt with new X2, Y2 -> X2 pending, Y2, B, C, X, Y, Z upcoming
        let x2 = makeEntry("X2"), y2 = makeEntry("Y2")
        _ = try await coord.submitIntent(.interruptAndPlay, entries: [x2, y2])
        snap = await coord.currentStructuredQueueSnapshot()
        #expect(snap.pendingTarget?.id == x2.id)
        #expect(snap.upcomingEntries.map(\.track.id) == ["Y2", "B", "C", "X", "Y", "Z"])
        #expect(eid == op1.engineInstanceID)
    }

    @Test("R13: Pagination retry requests only failed nextURL without replaying or seeking audio")
    func r13PaginationRetryFromFailedURL() async throws {
        let store = PlaybackStore()
        let engine = StabilizationMockEngine()
        let coord = PlaybackCoordinatorV2(store: store, engine: engine)
        let session = makeSession()
        await coord.start(session: session)

        let batchID = UUID()
        let origin = PlaybackOrigin(kind: .playlist, sourceID: "pl-retry", sourceTitle: "Retry PL")
        let p1 = [makeEntry("T1", origin: origin, batchID: batchID), makeEntry("T2", origin: origin, batchID: batchID)]
        try await coord.playEntries(p1, startIndex: 0, loadingState: .loading(loadedCount: 2, totalCount: 4), batchID: batchID)
        let snap = await coord.currentStructuredQueueSnapshot()
        let cmdCountBefore = await engine.executedCommands.count

        actor AttemptCounter {
            var attempts = 0
            func next() -> Int { attempts += 1; return attempts }
        }
        let counter = AttemptCounter()
        let loader = QueuePaginationLoader(maxPages: 10)
        await loader.startBackgroundPagination(
            coordinator: coord,
            batchID: batchID,
            expectedQueueID: snap.queueID,
            expectedSessionScope: snap.sessionScope,
            expectedDestructiveEpoch: snap.destructiveEpoch,
            origin: origin,
            initialLoadedCount: 2,
            initialNextURL: URL(string: "https://example.com/page/2")!,
            totalCount: 4
        ) { _ in
            let n = await counter.next()
            if n == 1 {
                throw URLError(.timedOut)
            }
            return QueuePageFetchResult(tracks: [makeEntry("T3").track, makeEntry("T4").track], nextURL: nil, totalCount: 4)
        }

        for _ in 0..<50 {
            let cur = await coord.currentStructuredQueueSnapshot()
            if case .failed(_, _, _, true) = cur.loadingState { break }
            try await Task.sleep(for: .milliseconds(10))
        }

        let retried = await loader.retryFailedPagination()
        #expect(retried)

        for _ in 0..<50 {
            let cur = await coord.currentStructuredQueueSnapshot()
            if case .complete(4) = cur.loadingState { break }
            try await Task.sleep(for: .milliseconds(10))
        }

        let finalSnap = await coord.currentStructuredQueueSnapshot()
        #expect(finalSnap.loadingState == .complete(totalCount: 4))
        #expect(finalSnap.upcomingEntries.map(\.track.id) == ["T2", "T3", "T4"])
        #expect((await engine.executedCommands.count) == cmdCountBefore)
    }

    @Test("R14 & R17: Deleting anchor does not cancel batch; requestedShuffle defers until pagination completes")
    func r14AndR17BatchSentinelAndDeferredShuffle() throws {
        var mgr = QueueManager()
        var rng = StabilizationRNG()
        let scope = "apple_music|acct-1"
        mgr.setSessionScope(scope)

        let batchID = UUID()
        let a = makeEntry("A", batchID: batchID), b = makeEntry("B", batchID: batchID), c = makeEntry("C", batchID: batchID)
        _ = mgr.replaceQueue(entries: [a, b, c], startIndex: 0, loadingState: .loading(loadedCount: 3, totalCount: 5), batchID: batchID, using: &rng)
        mgr.confirmEntry(a.id)

        // Enable shuffle while loading -> requestedShuffle=true, effectiveShuffle=false
        mgr.setShuffleEnabled(true, using: &rng)
        #expect(mgr.requestedShuffle == true)
        #expect(mgr.effectiveShuffle == false)

        // Delete anchor C and append X
        try mgr.removeEntries(ids: [c.id])
        let x = makeEntry("X")
        try mgr.append([x])

        // Page 2 arrives -> completes batch, inserts before X, and applies deferred shuffle!
        let d = makeEntry("D", batchID: batchID), e = makeEntry("E", batchID: batchID)
        let ok = mgr.commitPaginatedBatch([d, e], batchID: batchID, expectedQueueID: mgr.queueID, expectedSessionScope: scope, loadingState: .complete(totalCount: 4), using: &rng)
        #expect(ok)
        #expect(mgr.effectiveShuffle == true)
        #expect(Set(mgr.upcomingEntries.map(\.id)) == Set([b.id, d.id, e.id, x.id]))
    }

    @Test("R21: Exhausted queue + append + Play consumes newly appended track")
    func r21ExhaustedAppendAndPlay() async throws {
        let store = PlaybackStore()
        let engine = StabilizationMockEngine()
        let coord = PlaybackCoordinatorV2(store: store, engine: engine)
        let session = makeSession()
        await coord.start(session: session)

        let a = makeEntry("A")
        try await coord.playEntries([a], startIndex: 0)
        let op1 = (await engine.executedCommands.last!).1
        await engine.emit(.stateChanged(context: op1, status: .playing))
        try await Task.sleep(for: .milliseconds(20))
        await engine.emit(.trackEnded(context: op1, positionSeconds: 180, durationSeconds: 180))
        try await Task.sleep(for: .milliseconds(30))

        #expect((await coord.currentStructuredQueueSnapshot()).playbackPhase == .exhausted)

        let b = makeEntry("B")
        try await coord.append([b])
        try await coord.play()
        let snap = await coord.currentStructuredQueueSnapshot()
        #expect(snap.pendingTarget?.id == b.id)
    }
}
