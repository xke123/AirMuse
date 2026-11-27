import Foundation
import Testing
import Domain
@testable import Playback

private actor MockQueueEngine: PlaybackEngineProtocol {
    private(set) var currentEngineInstanceID = UUID()
    private(set) var executedCommands: [(EngineCommand, PlaybackOperationContext)] = []
    private var continuations: [UUID: AsyncStream<EngineEvent>.Continuation] = [:]
    var shouldFailNextPlayItem: Bool = false

    var engineInstanceID: UUID { currentEngineInstanceID }

    func setShouldFailNextPlayItem(_ fail: Bool) {
        shouldFailNextPlayItem = fail
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
        if case .playItem = command, shouldFailNextPlayItem {
            shouldFailNextPlayItem = false
            throw NSError(domain: "MockEngine", code: -1, userInfo: [NSLocalizedDescriptionKey: "Simulated playItem failure"])
        }
    }

    func isolateAndReset() async {
        currentEngineInstanceID = UUID()
    }
}

private struct FixedQueueRandomizer: QueueRandomizer {
    func nextUInt64() -> UInt64 { 0x1234_5678_9ABC_DEF0 }
}

@Suite("PlaybackCoordinatorQueueTests")
struct PlaybackCoordinatorQueueTests {

    private func makeSession(accountID: String = "acct-A", generation: UInt64 = 1) -> SessionContext {
        SessionContext(
            providerID: "apple_music",
            accountID: accountID,
            storefront: "cn",
            sessionID: UUID(),
            generation: generation
        )
    }

    private func makeEntry(_ id: String, kind: PlaybackOrigin.Kind = .album, sourceID: String = "alb-1") -> QueueEntry {
        let track = MusicTrack(
            id: id,
            title: "Song \(id)",
            artistName: "Artist",
            albumTitle: "Album",
            durationMs: 180_000,
            providerID: "apple_music",
            providerTrackID: id
        )
        return QueueEntry(track: track, origin: PlaybackOrigin(kind: kind, sourceID: sourceID, sourceTitle: "Source \(sourceID)"))
    }

    @Test("T12: Stale engine/opID/duplicate trackEnded events do not mis-advance")
    func staleAndDuplicateTrackEndedIgnored() async throws {
        let store = PlaybackStore()
        let engine = MockQueueEngine()
        let coord = PlaybackCoordinatorV2(store: store, engine: engine, randomizer: FixedQueueRandomizer())
        let session = makeSession()
        await coord.start(session: session)

        let e1 = makeEntry("T1"), e2 = makeEntry("T1"), e3 = makeEntry("T3")
        try await coord.playEntries([e1, e2, e3], startIndex: 0)

        let eid = await engine.engineInstanceID
        // Confirm e1 playing
        let op1Ctx = PlaybackOperationContext(sessionID: session.sessionID, engineInstanceID: eid, operationID: 1, trackID: "T1")
        await engine.emit(.stateChanged(context: op1Ctx, status: .playing))
        try await Task.sleep(for: .milliseconds(20))

        // Stale opID=999 or wrong engineInstanceID should be ignored
        let staleOpCtx = PlaybackOperationContext(sessionID: session.sessionID, engineInstanceID: eid, operationID: 999, trackID: "T1")
        let wrongEngineCtx = PlaybackOperationContext(sessionID: session.sessionID, engineInstanceID: UUID(), operationID: 1, trackID: "T1")
        await engine.emit(.trackEnded(context: staleOpCtx, positionSeconds: 180, durationSeconds: 180))
        await engine.emit(.trackEnded(context: wrongEngineCtx, positionSeconds: 180, durationSeconds: 180))
        try await Task.sleep(for: .milliseconds(20))

        let snapBefore = await coord.currentStructuredQueueSnapshot()
        #expect(snapBefore.confirmedCurrent?.id == e1.id)
        #expect(snapBefore.upcomingEntries.map(\.id) == [e2.id, e3.id])

        // Valid end advances once to e2 (even though e2 has same trackID "T1"), duplicate is ignored
        await engine.emit(.trackEnded(context: op1Ctx, positionSeconds: 180, durationSeconds: 180))
        await engine.emit(.trackEnded(context: op1Ctx, positionSeconds: 180, durationSeconds: 180))
        try await Task.sleep(for: .milliseconds(30))

        let snapAfter = await coord.currentStructuredQueueSnapshot()
        #expect(snapAfter.pendingTarget?.id == e2.id)
        #expect(snapAfter.upcomingEntries.map(\.id) == [e3.id])
    }

    @Test("T13: Play failure does not fake confirmedCurrent and preserves retryable target")
    func playFailurePreservesRetryableTarget() async throws {
        let store = PlaybackStore()
        let engine = MockQueueEngine()
        let coord = PlaybackCoordinatorV2(store: store, engine: engine)
        await coord.start(session: makeSession())

        let e1 = makeEntry("S1"), e2 = makeEntry("S2")
        await engine.setShouldFailNextPlayItem(true)
        try await coord.playEntries([e1, e2], startIndex: 0)

        let state = await store.state
        #expect(state.status == .failed)
        let qSnap = await store.queueSnapshot
        #expect(qSnap.confirmedCurrent == nil)
        #expect(qSnap.pendingTarget?.id == e1.id)
        #expect(qSnap.upcomingEntries.map(\.id) == [e2.id])

        // Retry succeeds
        try await coord.retryPendingOrCurrent()
        let eid = await engine.engineInstanceID
        let lastCmd = await engine.executedCommands.last!
        await engine.emit(.stateChanged(context: lastCmd.1, status: .playing))
        try await Task.sleep(for: .milliseconds(20))
        #expect(eid == lastCmd.1.engineInstanceID)
        #expect((await store.queueSnapshot).confirmedCurrent?.id == e1.id)
    }

    @Test("T17: Remote station disables local editing and rejects insertNext/append without stopping station")
    func remoteStationCapabilitiesAndRejection() async throws {
        let store = PlaybackStore()
        let engine = MockQueueEngine()
        let coord = PlaybackCoordinatorV2(store: store, engine: engine)
        await coord.start(session: makeSession())

        let stationTrack = MusicTrack(
            id: "ra.999",
            title: "Chill Radio",
            artistName: "Apple Music",
            albumTitle: "Radio",
            durationMs: 0,
            providerID: "apple_music",
            providerTrackID: "ra.999"
        )
        let stationOrigin = PlaybackOrigin(kind: .station, sourceID: "ra.999", sourceTitle: "Chill Radio")
        let stationEntry = QueueEntry(track: stationTrack, origin: stationOrigin)
        try await coord.playEntries([stationEntry], startIndex: 0, kind: .station)

        let snap = await coord.currentStructuredQueueSnapshot()
        #expect(snap.owner == .remoteEngine)
        #expect(!snap.capabilities.canInsertNext)
        #expect(!snap.capabilities.canClear)

        let song = makeEntry("SONG1")
        await #expect(throws: QueueEditError.self) {
            try await coord.append([song])
        }
        // Station still active
        #expect((await coord.currentStructuredQueueSnapshot()).activeTargetEntrySafe?.id == stationEntry.id)
    }

    @Test("T18 & T19: Snapshot persistence, v1 migration, corruption safety, and account isolation")
    func persistenceMigrationAndAccountIsolation() async throws {
        let tmpURL = URL(fileURLWithPath: "/tmp/airmuse_q_snap_\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: tmpURL) }
        let snapStore = PlaybackSnapshotStore(fileURL: tmpURL)

        // 1. Corrupt file returns nil safely
        try Data("not-json".utf8).write(to: tmpURL)
        #expect(await snapStore.load(expectedProviderID: "apple_music", expectedAccountID: "acct-A") == nil)

        // 2. V1 snapshot migrates cleanly with .unknown origin
        let v1Track = MusicTrack(id: "v1t", title: "V1", artistName: "A", albumTitle: "Al", durationMs: 120_000, providerID: "apple_music", providerTrackID: "v1t")
        let v1Snap = PlaybackSnapshot(
            schemaVersion: 1,
            providerID: "apple_music",
            accountID: "acct-A",
            queueTracks: [v1Track],
            currentIndex: 0,
            positionMs: 15_000,
            volume: 0.7,
            repeatMode: .off,
            shuffleEnabled: false
        )
        try await snapStore.save(v1Snap)
        let loadedV1 = await snapStore.load(expectedProviderID: "apple_music", expectedAccountID: "acct-A")
        let migrated = loadedV1?.resolvedQueuePayload()
        #expect(migrated?.entries.count == 1)
        #expect(migrated?.entries.first?.origin == .unknown)
        #expect(await snapStore.load(expectedProviderID: "apple_music", expectedAccountID: "acct-B") == nil)

        // 3. Coordinator v2 save + paused restore + signout isolation
        let store1 = PlaybackStore()
        let engine1 = MockQueueEngine()
        let coord1 = PlaybackCoordinatorV2(store: store1, engine: engine1, snapshotStore: snapStore)
        let sessA = makeSession(accountID: "acct-A")
        await coord1.start(session: sessA)

        let e1 = makeEntry("E1"), e2 = makeEntry("E2")
        try await coord1.playEntries([e1, e2], startIndex: 0)
        let eid1 = await engine1.engineInstanceID
        await engine1.emit(.stateChanged(context: PlaybackOperationContext(sessionID: sessA.sessionID, engineInstanceID: eid1, operationID: 1, trackID: "E1"), status: .playing))
        try await Task.sleep(for: .milliseconds(20))
        await coord1.setShuffleEnabled(true)
        await coord1.flushSnapshot()

        // New coordinator restores acct-A in paused state without issuing playItem
        let store2 = PlaybackStore()
        let engine2 = MockQueueEngine()
        let coord2 = PlaybackCoordinatorV2(store: store2, engine: engine2, snapshotStore: snapStore)
        await coord2.start(session: sessA)
        await coord2.restoreSnapshotIfNeeded(providerID: "apple_music", accountID: "acct-A")

        let restoredState = await store2.state
        #expect(restoredState.status == .paused)
        #expect(restoredState.currentTrack?.id == "E1")
        #expect(restoredState.shuffleEnabled == true)
        #expect((await engine2.executedCommands).isEmpty)

        // Switching to acct-B clears acct-A's queue
        await coord2.updateSession(makeSession(accountID: "acct-B"))
        let bSnap = await coord2.currentStructuredQueueSnapshot()
        #expect(bSnap.confirmedCurrent == nil)
        #expect(bSnap.upcomingEntries.isEmpty)
    }

    @Test("T20: Position/volume updates do not emit on queueStream")
    func queueStreamIgnoresPositionAndVolume() async throws {
        let store = PlaybackStore()
        let engine = MockQueueEngine()
        let coord = PlaybackCoordinatorV2(store: store, engine: engine)
        let session = makeSession()
        await coord.start(session: session)

        let e1 = makeEntry("P1"), e2 = makeEntry("P2")
        try await coord.playEntries([e1, e2], startIndex: 0)

        let stream = await coord.queueStream()
        let counterTask = Task { () -> Int in
            var count = 0
            for await _ in stream {
                count += 1
                if count >= 2 { break }
            }
            return count
        }

        try await Task.sleep(for: .milliseconds(20))
        let eid = await engine.engineInstanceID
        let ctx = PlaybackOperationContext(sessionID: session.sessionID, engineInstanceID: eid, operationID: 1, trackID: "P1")
        // Emit 5 position updates and 2 volume updates
        for i in 1...5 {
            await engine.emit(.positionUpdated(context: ctx, positionSeconds: Double(i), durationSeconds: 180))
        }
        try await coord.setVolume(0.5)
        try await coord.setVolume(0.8)
        try await Task.sleep(for: .milliseconds(30))

        // Trigger 1 real structural change so stream gets its 2nd item and finishes
        try await coord.removeEntries(ids: [e2.id])
        let total = await counterTask.value
        #expect(total == 2)
    }
}

private extension QueueSnapshot {
    var activeTargetEntrySafe: QueueEntry? {
        pendingTarget ?? confirmedCurrent
    }
}
