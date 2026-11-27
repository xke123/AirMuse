import Foundation
import Testing
import Domain
@testable import Playback

private actor OriginTestEngine: PlaybackEngineProtocol {
    private(set) var currentEngineInstanceID = UUID()
    private(set) var executedCommands: [(EngineCommand, PlaybackOperationContext)] = []
    private var continuations: [UUID: AsyncStream<EngineEvent>.Continuation] = [:]
    var shouldFailNextPlayItem = false

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
            throw NSError(domain: "OriginTestEngine", code: -1, userInfo: [NSLocalizedDescriptionKey: "Simulated failure"])
        }
    }

    func isolateAndReset() async {
        currentEngineInstanceID = UUID()
    }
}

private struct FixedTestRandomizer: QueueRandomizer {
    func nextUInt64() -> UInt64 { 0xCAFE_BABE_1234_5678 }
}

@Suite("PlaybackOriginQueueTests")
struct PlaybackOriginQueueTests {

    private func makeSession(accountID: String = "acct-A", generation: UInt64 = 1) -> SessionContext {
        SessionContext(
            providerID: "apple_music",
            accountID: accountID,
            storefront: "cn",
            sessionID: UUID(),
            generation: generation
        )
    }

    private func makeTrack(_ id: String, title: String? = nil) -> MusicTrack {
        MusicTrack(
            id: id,
            title: title ?? "Track \(id)",
            artistName: "Artist",
            albumTitle: "Album",
            durationMs: 180_000,
            providerID: "apple_music",
            providerTrackID: id
        )
    }

    @Test("P01 & P06: Same track from two playlists has distinct UUID/origin; move/clear/append keep current origin")
    func sameTrackDistinctOriginsAndMutationPreservation() async throws {
        let store = PlaybackStore()
        let engine = OriginTestEngine()
        let coord = PlaybackCoordinatorV2(store: store, engine: engine, randomizer: FixedTestRandomizer())
        let session = makeSession()
        await coord.start(session: session)

        let origin1 = PlaybackOrigin(
            kind: .playlist,
            sourceID: "pl.1",
            sourceTitle: "Playlist One",
            navigationTarget: .resource(kind: .playlist, id: "pl.1", isLibrary: false, providerID: "apple_music")
        )
        let origin2 = PlaybackOrigin(
            kind: .playlist,
            sourceID: "pl.2",
            sourceTitle: "Playlist Two",
            navigationTarget: .resource(kind: .playlist, id: "pl.2", isLibrary: false, providerID: "apple_music")
        )
        let track = makeTrack("song-dup")
        let entry1 = QueueEntry(track: track, origin: origin1)
        let entry2 = QueueEntry(track: track, origin: origin2)
        let entry3 = QueueEntry(track: makeTrack("song-3"), origin: origin2)

        _ = try await coord.submitIntent(.replaceAndPlay, entries: [entry1, entry2], startIndex: 0)
        let eid = await engine.engineInstanceID
        await engine.emit(.stateChanged(context: PlaybackOperationContext(sessionID: session.sessionID, engineInstanceID: eid, operationID: 1, trackID: "song-dup"), status: .playing))
        try await Task.sleep(for: .milliseconds(20))

        var snap = await coord.currentStructuredQueueSnapshot()
        #expect(snap.confirmedCurrent?.id == entry1.id)
        #expect(snap.confirmedCurrent?.origin.sourceID == "pl.1")
        #expect(snap.upcomingEntries.first?.id == entry2.id)
        #expect(snap.upcomingEntries.first?.origin.sourceID == "pl.2")
        #expect(entry1.id != entry2.id)

        // Append and move
        _ = try await coord.submitIntent(.append, entries: [entry3], expectedQueueID: snap.queueID, expectedDestructiveEpoch: snap.destructiveEpoch)
        snap = await coord.currentStructuredQueueSnapshot()
        try await coord.moveEntries(ids: [entry3.id], before: entry2.id, expectedQueueID: snap.queueID)
        snap = await coord.currentStructuredQueueSnapshot()
        #expect(snap.upcomingEntries.map(\.id) == [entry3.id, entry2.id])
        #expect(snap.confirmedCurrent?.origin.sourceID == "pl.1")

        // Clear upcoming keeps confirmedCurrent & origin
        try await coord.clearUpcoming(expectedQueueID: snap.queueID)
        snap = await coord.currentStructuredQueueSnapshot()
        #expect(snap.upcomingEntries.isEmpty)
        #expect(snap.confirmedCurrent?.id == entry1.id)
        #expect(snap.confirmedCurrent?.origin.sourceID == "pl.1")
    }

    @Test("P07 & P08: Stage-only has no confirmedCurrent until Play; preparing/failed does not fake confirmedCurrent")
    func stageOnlyAndPendingNotConfirmed() async throws {
        let store = PlaybackStore()
        let engine = OriginTestEngine()
        let coord = PlaybackCoordinatorV2(store: store, engine: engine, randomizer: FixedTestRandomizer())
        let session = makeSession()
        await coord.start(session: session)

        let origin = PlaybackOrigin(kind: .album, sourceID: "alb-1", sourceTitle: "Album One")
        let e1 = QueueEntry(track: makeTrack("S1"), origin: origin)
        let e2 = QueueEntry(track: makeTrack("S2"), origin: origin)

        // Stage-only append when idle
        _ = try await coord.submitIntent(.append, entries: [e1, e2])
        var snap = await coord.currentStructuredQueueSnapshot()
        #expect(snap.confirmedCurrent == nil)
        #expect(snap.pendingTarget == nil)
        #expect(snap.upcomingEntries.map(\.id) == [e1.id, e2.id])
        let cmdsBeforePlay = await engine.executedCommands
        #expect(cmdsBeforePlay.isEmpty)

        // Play starts from head (e1) with failure -> pendingTarget marked failed, confirmedCurrent still nil
        await engine.setShouldFailNextPlayItem(true)
        try await coord.playPause()
        snap = await coord.currentStructuredQueueSnapshot()
        #expect(snap.confirmedCurrent == nil)
        #expect(snap.pendingTarget?.id == e1.id)
        #expect(snap.isPendingTargetFailed == true)

        // QueueManager persistence payload does NOT promote failed/pending entry to confirmedCurrent
        var qm = QueueManager()
        var rng = SystemRandomNumberGenerator()
        _ = qm.replaceQueue(entries: [e1, e2], startIndex: 0, startPlayback: true, using: &rng)
        qm.markPendingFailed()
        let payload = qm.exportPersistencePayload()
        #expect(payload.currentEntryID == nil)
    }

    @Test("P36: Account switch isolates sessionScope and rejects stale queue operations")
    func accountSwitchIsolation() async throws {
        let store = PlaybackStore()
        let engine = OriginTestEngine()
        let coord = PlaybackCoordinatorV2(store: store, engine: engine, randomizer: FixedTestRandomizer())
        let sessionA = makeSession(accountID: "acct-A", generation: 1)
        await coord.start(session: sessionA)

        let eA = QueueEntry(track: makeTrack("A1"), origin: PlaybackOrigin(kind: .library, sourceID: "lib_songs", sourceTitle: "歌曲", isLibrary: true))
        _ = try await coord.submitIntent(.replaceAndPlay, entries: [eA])
        let snapA = await coord.currentStructuredQueueSnapshot()

        let sessionB = makeSession(accountID: "acct-B", generation: 2)
        await coord.updateSession(sessionB)
        let snapB = await coord.currentStructuredQueueSnapshot()
        #expect(snapB.sessionScope != snapA.sessionScope)
        #expect(snapB.upcomingEntries.isEmpty)
        #expect(snapB.confirmedCurrent == nil)

        let eStale = QueueEntry(track: makeTrack("B1"), origin: .unknown)
        do {
            _ = try await coord.submitIntent(.append, entries: [eStale], expectedQueueID: snapA.queueID, expectedDestructiveEpoch: snapA.destructiveEpoch)
            Issue.record("Expected stale queueID error after account switch")
        } catch {
            // Expected QueueEditError
        }
    }

    @Test("P41 & P42: 1000 high-frequency position/volume updates emit zero queueStream events")
    func highFrequencyUpdatesDoNotEmitQueueStream() async throws {
        let store = PlaybackStore()
        let engine = OriginTestEngine()
        let coord = PlaybackCoordinatorV2(store: store, engine: engine, randomizer: FixedTestRandomizer())
        let session = makeSession()
        await coord.start(session: session)

        let origin = PlaybackOrigin(kind: .album, sourceID: "alb-perf", sourceTitle: "Perf Album")
        let entry = QueueEntry(track: makeTrack("P1"), origin: origin)
        _ = try await coord.submitIntent(.replaceAndPlay, entries: [entry])

        let eid = await engine.engineInstanceID
        let ctx = PlaybackOperationContext(sessionID: session.sessionID, engineInstanceID: eid, operationID: 1, trackID: "P1")
        await engine.emit(.stateChanged(context: ctx, status: .playing))
        try await Task.sleep(for: .milliseconds(20))

        let stream = await coord.queueStream()
        var iterator = stream.makeAsyncIterator()
        _ = await iterator.next() // consume initial snapshot

        for i in 0..<1000 {
            await engine.emit(.positionUpdated(context: ctx, positionSeconds: Double(i % 180), durationSeconds: 180))
            if i % 10 == 0 {
                try await coord.setVolume(Float(i % 100) / 100.0)
            }
        }
        try await Task.sleep(for: .milliseconds(30))

        // Trigger one real structural change so next() resolves with that single snapshot
        let entry2 = QueueEntry(track: makeTrack("P2"), origin: origin)
        let snapNow = await coord.currentStructuredQueueSnapshot()
        _ = try await coord.submitIntent(.append, entries: [entry2], expectedQueueID: snapNow.queueID, expectedDestructiveEpoch: snapNow.destructiveEpoch)

        let nextSnap = await iterator.next()
        #expect(nextSnap?.upcomingEntries.map(\.id) == [entry2.id])
    }
}
