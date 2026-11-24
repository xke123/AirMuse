import Foundation
import Testing
import Domain
import Playback

@Suite("PlaybackStoreTests")
struct PlaybackStoreTests {

    @Test func storeUpdatesState() async {
        let store = PlaybackStore()
        let initial = await store.state
        #expect(!initial.isPlaying)

        var updated = PlaybackState.idle
        updated.isPlaying = true
        updated.sourceName = "Test"

        await store.update(state: updated)
        let after = await store.state
        #expect(after.isPlaying)
        #expect(after.sourceName == "Test")
    }

    @Test func artworkPreservation() async {
        let store = PlaybackStore()

        let artData = Data([0xFF, 0xD8, 0xFF])
        let track = MusicTrack(id: "1", title: "Song", artistName: "Band",
                               albumTitle: "Album", durationMs: 120_000,
                               providerID: "test", providerTrackID: "t1")

        var stateWithArt = PlaybackState.idle
        stateWithArt.currentTrack = track
        stateWithArt.artworkData = artData
        await store.update(state: stateWithArt)

        var stateNoArt = PlaybackState.idle
        stateNoArt.currentTrack = track
        stateNoArt.artworkData = nil
        await store.update(state: stateNoArt)

        let result = await store.state
        #expect(result.artworkData == artData)
    }
}

private actor TestMockPlaybackEngine: PlaybackEngineProtocol {
    private(set) var currentEngineInstanceID = UUID()
    private(set) var executedCommands: [(EngineCommand, PlaybackOperationContext)] = []
    private var continuations: [UUID: AsyncStream<EngineEvent>.Continuation] = [:]

    var engineInstanceID: UUID { currentEngineInstanceID }

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
    }

    func isolateAndReset() async {
        currentEngineInstanceID = UUID()
    }
}

@Suite("PlaybackCoordinatorV2Tests")
struct PlaybackCoordinatorV2Tests {

    private func makeTrack(_ id: String, durationMs: Int64 = 180_000) -> MusicTrack {
        MusicTrack(
            id: id,
            title: "Track \(id)",
            artistName: "Artist",
            albumTitle: "Album",
            durationMs: durationMs,
            providerID: "apple_music",
            providerTrackID: id
        )
    }

    @Test func rapidTenTrackSwitchesEndOnFinalTrack() async throws {
        let store = PlaybackStore()
        let engine = TestMockPlaybackEngine()
        let coord = PlaybackCoordinatorV2(store: store, engine: engine)
        await coord.start()

        let tracks = (1...10).map { makeTrack("t\($0)") }
        let queue = PlaybackQueue(tracks: tracks, currentIndex: 0)

        for t in tracks {
            try await coord.playTrack(t, in: queue)
        }

        let state = await store.state
        #expect(state.currentTrack?.id == "t10")
        let cmds = await engine.executedCommands
        if let last = cmds.last {
            if case .playItem(let id, _, _) = last.0 {
                #expect(id == "t10")
            } else {
                #expect(Bool(false), "Expected playItem as last command")
            }
        } else {
            #expect(Bool(false), "Expected executed commands")
        }
    }

    @Test func pauseDuringBufferingIgnoresLatePlayingEvent() async throws {
        let store = PlaybackStore()
        let engine = TestMockPlaybackEngine()
        let coord = PlaybackCoordinatorV2(store: store, engine: engine)
        await coord.start()

        let track = makeTrack("t1")
        let queue = PlaybackQueue(tracks: [track], currentIndex: 0)
        try await coord.playTrack(track, in: queue)
        try await coord.pause()

        let stateAfterPause = await store.state
        #expect(stateAfterPause.status == .paused)
        #expect(!stateAfterPause.isPlaying)

        let eid = await engine.engineInstanceID
        let staleCtx = PlaybackOperationContext(
            sessionID: UUID(),
            engineInstanceID: eid,
            operationID: 1,
            trackID: "t1"
        )
        await engine.emit(.stateChanged(context: staleCtx, status: .playing))
        try await Task.sleep(for: .milliseconds(30))
        #expect((await store.state).status == .paused)
        #expect(!(await store.state).isPlaying)
    }

    @Test func trackEndedDeduplicatesAndRemoteStationDoesNotDoubleAdvance() async throws {
        let store = PlaybackStore()
        let engine = TestMockPlaybackEngine()
        let coord = PlaybackCoordinatorV2(store: store, engine: engine)
        await coord.start()

        let t1 = makeTrack("s1")
        let t2 = makeTrack("s2")
        let t3 = makeTrack("s3")
        let queue = PlaybackQueue(tracks: [t1, t2, t3], currentIndex: 0)

        try await coord.playTrack(t1, in: queue)
        let eid = await engine.engineInstanceID
        let op1Ctx = PlaybackOperationContext(sessionID: UUID(), engineInstanceID: eid, operationID: 1, trackID: "s1")

        await engine.emit(.trackEnded(context: op1Ctx, positionSeconds: 180, durationSeconds: 180))
        await engine.emit(.trackEnded(context: op1Ctx, positionSeconds: 180, durationSeconds: 180))
        try await Task.sleep(for: .milliseconds(50))

        #expect((await store.state).currentTrack?.id == "s2")

        let station = makeTrack("ra.12345")
        try await coord.playTrack(station, in: PlaybackQueue(tracks: [station, t3], currentIndex: 0), kind: .station)
        let stationCtx = PlaybackOperationContext(sessionID: UUID(), engineInstanceID: eid, operationID: 3, trackID: "ra.12345")
        await engine.emit(.trackEnded(context: stationCtx, positionSeconds: 200, durationSeconds: 200))
        try await Task.sleep(for: .milliseconds(30))
        #expect((await store.state).currentTrack?.id == "ra.12345")
    }

    @Test func timeAnchorInterpolatesAndSnapshotIsolatesAccounts() async throws {
        let anchor = PlaybackTimeAnchor(positionMs: 10_000, durationMs: 60_000, monotonicNs: 1_000_000_000, isPlaying: true)
        #expect(anchor.interpolatedPositionMs(at: 6_000_000_000) == 15_000)
        #expect(anchor.interpolatedPositionMs(at: 90_000_000_000) == 60_000)

        let snapURL = URL(fileURLWithPath: "/tmp/corev2_snap_\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: snapURL) }
        let snapStore = PlaybackSnapshotStore(fileURL: snapURL)

        let snap = PlaybackSnapshot(
            providerID: "apple_music",
            accountID: "acct-A",
            queueTracks: [makeTrack("x1")],
            currentIndex: 0,
            positionMs: 42_000,
            volume: 0.8,
            repeatMode: .all,
            shuffleEnabled: true
        )
        try await snapStore.save(snap)
        let loadedA = await snapStore.load(expectedAccountID: "acct-A")
        #expect(loadedA?.positionMs == 42_000)
        let loadedB = await snapStore.load(expectedAccountID: "acct-B")
        #expect(loadedB == nil)
        let loadedNil = await snapStore.load(expectedAccountID: nil)
        #expect(loadedNil == nil)
    }
}
