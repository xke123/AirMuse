import Foundation
import Testing
import Domain
@testable import Playback

private actor RadioTestEngine: PlaybackEngineProtocol {
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

@Suite("RadioSessionTests")
struct RadioSessionTests {

    private func makeSession() -> SessionContext {
        SessionContext(
            providerID: "apple_music",
            accountID: "acct-radio",
            storefront: "cn",
            sessionID: UUID(),
            generation: 1
        )
    }

    private func makeStationEntry(
        stationID: String = "ra.123",
        title: String = "Test Radio",
        stationType: StationKind = .algorithmic
    ) -> QueueEntry {
        let track = MusicTrack(
            id: stationID,
            title: title,
            artistName: "Apple Music",
            albumTitle: "Radio",
            durationMs: 0,
            providerID: "apple_music",
            providerTrackID: stationID
        )
        let origin = PlaybackOrigin(
            kind: .station,
            sourceID: stationID,
            sourceTitle: title,
            stationContext: StationOriginContext(stationID: stationID, stationType: stationType)
        )
        return QueueEntry(track: track, origin: origin)
    }

    @Test("P11: Coordinator rejects multiple entries for remote station and station entries in local queue")
    func rejectsMultipleOrMixedStationEntries() async throws {
        let store = PlaybackStore()
        let engine = RadioTestEngine()
        let coord = PlaybackCoordinatorV2(store: store, engine: engine)
        await coord.start(session: makeSession())

        let r1 = makeStationEntry(stationID: "ra.1", title: "R1")
        let r2 = makeStationEntry(stationID: "ra.2", title: "R2")

        do {
            try await coord.playEntries([r1, r2], startIndex: 0, kind: .station)
            Issue.record("Expected remoteStationMixedNotAllowed for multiple station entries")
        } catch let err as QueueEditError {
            #expect(err == .remoteStationMixedNotAllowed)
        }

        do {
            try await coord.playEntries([r1], startIndex: 0, kind: .song)
            Issue.record("Expected remoteStationMixedNotAllowed for station entry in local queue")
        } catch let err as QueueEditError {
            #expect(err == .remoteStationMixedNotAllowed)
        }
    }

    @Test("P13, P14 & P15: Remote itemChanged updates track without inheriting stale fields or faking playing")
    func remoteItemChangedMetadataAndTransportSeparation() async throws {
        let store = PlaybackStore()
        let engine = RadioTestEngine()
        let coord = PlaybackCoordinatorV2(store: store, engine: engine)
        let session = makeSession()
        await coord.start(session: session)

        let station = makeStationEntry(stationID: "ra.888", title: "Chill Radio", stationType: .algorithmic)
        try await coord.playEntries([station], startIndex: 0, kind: .station)

        let eid = await engine.engineInstanceID
        let opCtx = PlaybackOperationContext(sessionID: session.sessionID, engineInstanceID: eid, operationID: 1, trackID: "ra.888")

        // 1. itemChanged arrives BEFORE stateChanged(.playing) -> must NOT confirm playing!
        await engine.emit(.itemChanged(
            context: opCtx,
            trackID: "song-1",
            title: "First Song",
            artist: "Artist A",
            albumTitle: "Album A",
            artworkURL: "https://example.com/a.jpg",
            durationSeconds: 200
        ))
        try await Task.sleep(for: .milliseconds(20))
        var snap = await coord.currentStructuredQueueSnapshot()
        #expect(snap.confirmedCurrent == nil)
        #expect(snap.playbackPhase == .preparing)

        // 2. stateChanged(.playing) confirms
        await engine.emit(.stateChanged(context: opCtx, status: .playing))
        try await Task.sleep(for: .milliseconds(20))
        snap = await coord.currentStructuredQueueSnapshot()
        #expect(snap.confirmedCurrent?.track.title == "First Song")
        #expect(snap.confirmedCurrent?.origin.sourceID == "ra.888")
        #expect(snap.activeTarget?.providerResourceID == "ra.888")

        // 3. Natural track change with missing artist/album/artwork/duration -> must NOT inherit from First Song!
        await engine.emit(.itemChanged(
            context: opCtx,
            trackID: "song-2",
            title: "Second Song",
            artist: "",
            albumTitle: "",
            artworkURL: "",
            durationSeconds: 0
        ))
        try await Task.sleep(for: .milliseconds(20))
        snap = await coord.currentStructuredQueueSnapshot()
        #expect(snap.confirmedCurrent?.track.title == "Second Song")
        #expect(snap.confirmedCurrent?.track.artistName == "")
        #expect(snap.confirmedCurrent?.track.albumTitle == "")
        #expect(snap.confirmedCurrent?.track.artworkURL == nil)
        #expect(snap.confirmedCurrent?.track.durationMs == 0)
        #expect(snap.activeTarget?.providerResourceID == "ra.888")

        // 4. Pause followed by itemChanged does NOT resurrect .playing phase
        try await coord.pause()
        await engine.emit(.itemChanged(
            context: opCtx,
            trackID: "song-2",
            title: "Second Song",
            artist: "Artist B",
            albumTitle: "",
            artworkURL: "",
            durationSeconds: 180
        ))
        try await Task.sleep(for: .milliseconds(20))
        snap = await coord.currentStructuredQueueSnapshot()
        #expect(snap.playbackPhase == .paused)
        #expect(snap.confirmedCurrent?.track.artistName == "Artist B")
    }

    @Test("P16, P17 & P18: Conservative capabilities on live/unknown stations enforced by coordinator")
    func stationCapabilitiesEnforced() async throws {
        let store = PlaybackStore()
        let engine = RadioTestEngine()
        let coord = PlaybackCoordinatorV2(store: store, engine: engine)
        let session = makeSession()
        await coord.start(session: session)

        let unknownStation = makeStationEntry(stationID: "ra.unknown", title: "Unknown Radio", stationType: .unknown)
        try await coord.playEntries([unknownStation], startIndex: 0, kind: .station)

        let snap = await coord.currentStructuredQueueSnapshot()
        #expect(snap.capabilities.canSkipNext == false)
        #expect(snap.capabilities.canSkipPrevious == false)
        #expect(snap.capabilities.canSeek == false)
        #expect(snap.capabilities.canRead == false)

        do {
            try await coord.skipToNext()
            Issue.record("Expected unsupportedCapability for skipToNext on unknown station")
        } catch let err as QueueEditError {
            if case .unsupportedCapability = err {} else { Issue.record("Unexpected error: \(err)") }
        }

        do {
            try await coord.seek(toMs: 10_000)
            Issue.record("Expected unsupportedCapability for seek on unknown station")
        } catch let err as QueueEditError {
            if case .unsupportedCapability = err {} else { Issue.record("Unexpected error: \(err)") }
        }

        // P16: trackEnded on remote station does NOT local advance
        let eid = await engine.engineInstanceID
        let opCtx = PlaybackOperationContext(sessionID: session.sessionID, engineInstanceID: eid, operationID: 1, trackID: "ra.unknown")
        await engine.emit(.trackEnded(context: opCtx, positionSeconds: 100, durationSeconds: 100))
        try await Task.sleep(for: .milliseconds(20))
        let endedSnap = await coord.currentStructuredQueueSnapshot()
        #expect(endedSnap.playbackPhase == .exhausted)
    }
}
