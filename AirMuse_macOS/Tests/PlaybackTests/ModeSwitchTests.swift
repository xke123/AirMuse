import Foundation
import Testing
import Domain
@testable import Playback

private actor ModeSwitchTestEngine: PlaybackEngineProtocol {
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

@Suite("ModeSwitchTests")
struct ModeSwitchTests {

    private func makeSession() -> SessionContext {
        SessionContext(
            providerID: "apple_music",
            accountID: "acct-switch",
            storefront: "cn",
            sessionID: UUID(),
            generation: 1
        )
    }

    private func makeSong(_ id: String) -> QueueEntry {
        let track = MusicTrack(
            id: id,
            title: "Song \(id)",
            artistName: "Artist",
            albumTitle: "Album",
            durationMs: 180_000,
            providerID: "apple_music",
            providerTrackID: id
        )
        return QueueEntry(track: track, origin: PlaybackOrigin(kind: .album, sourceID: "alb-1", sourceTitle: "Album 1"))
    }

    private func makeStation(_ id: String) -> QueueEntry {
        let track = MusicTrack(
            id: id,
            title: "Station \(id)",
            artistName: "Apple Music",
            albumTitle: "Radio",
            durationMs: 0,
            providerID: "apple_music",
            providerTrackID: id
        )
        return QueueEntry(
            track: track,
            origin: PlaybackOrigin(
                kind: .station,
                sourceID: id,
                sourceTitle: "Station \(id)",
                stationContext: StationOriginContext(stationID: id, stationType: .algorithmic)
            )
        )
    }

    @Test("P19, P20 & P25: Local -> Station R -> Station S -> Local replace clears cross-mode history")
    func localRemoteSwitchAndHistoryIsolation() async throws {
        let store = PlaybackStore()
        let engine = ModeSwitchTestEngine()
        let coord = PlaybackCoordinatorV2(store: store, engine: engine)
        let session = makeSession()
        await coord.start(session: session)

        let a = makeSong("A"), b = makeSong("B"), c = makeSong("C")
        try await coord.playEntries([a, b, c], startIndex: 0)
        let eid = await engine.engineInstanceID
        await engine.emit(.stateChanged(context: PlaybackOperationContext(sessionID: session.sessionID, engineInstanceID: eid, operationID: 1, trackID: "A"), status: .playing))
        try await Task.sleep(for: .milliseconds(15))
        try await coord.skipToNext()
        await engine.emit(.stateChanged(context: PlaybackOperationContext(sessionID: session.sessionID, engineInstanceID: eid, operationID: 2, trackID: "B"), status: .playing))
        try await Task.sleep(for: .milliseconds(15))

        var snap = await coord.currentStructuredQueueSnapshot()
        #expect(snap.historyCount == 1)

        // Local -> Station R
        let r = makeStation("ra.R")
        try await coord.playEntries([r], startIndex: 0, kind: .station)
        snap = await coord.currentStructuredQueueSnapshot()
        #expect(snap.owner == .remoteEngine)
        #expect(snap.historyCount == 0)
        #expect(snap.upcomingEntries.isEmpty)

        // Station R -> Station S
        let s = makeStation("ra.S")
        try await coord.playEntries([s], startIndex: 0, kind: .station)
        snap = await coord.currentStructuredQueueSnapshot()
        #expect(snap.owner == .remoteEngine)
        #expect(snap.activeTarget?.providerResourceID == "ra.S")
        #expect(snap.historyCount == 0)

        // Station S -> Local replace X Y
        let x = makeSong("X"), y = makeSong("Y")
        try await coord.playEntries([x, y], startIndex: 0, kind: .song)
        snap = await coord.currentStructuredQueueSnapshot()
        #expect(snap.owner == .localCoordinator)
        #expect(snap.historyCount == 0)
        #expect(snap.upcomingEntries.map(\.id) == [y.id])
    }

    @Test("P22 & P24: Atomic switchRemoteToStagedLocal stages without auto-play and rejects stale context")
    func atomicSwitchRemoteToStagedLocal() async throws {
        let store = PlaybackStore()
        let engine = ModeSwitchTestEngine()
        let coord = PlaybackCoordinatorV2(store: store, engine: engine)
        let session = makeSession()
        await coord.start(session: session)

        let r = makeStation("ra.R")
        try await coord.playEntries([r], startIndex: 0, kind: .station)
        let eid = await engine.engineInstanceID
        await engine.emit(.stateChanged(context: PlaybackOperationContext(sessionID: session.sessionID, engineInstanceID: eid, operationID: 1, trackID: "ra.R"), status: .playing))
        try await Task.sleep(for: .milliseconds(15))

        let remoteSnap = await coord.currentStructuredQueueSnapshot()
        let x = makeSong("X"), y = makeSong("Y")

        // Stale queueID is rejected without disturbing remote station
        do {
            _ = try await coord.switchRemoteToStagedLocal(
                entries: [x, y],
                expectedQueueID: UUID(),
                expectedDestructiveEpoch: remoteSnap.destructiveEpoch,
                expectedSessionScope: remoteSnap.sessionScope
            )
            Issue.record("Expected queueMismatch for stale queueID")
        } catch let err as QueueEditError {
            if case .queueMismatch = err {} else { Issue.record("Unexpected error: \(err)") }
        }
        #expect((await coord.currentStructuredQueueSnapshot()).owner == .remoteEngine)

        // Valid atomic switch -> staged local [X, Y], no current, no playItem
        let cmdsBefore = (await engine.executedCommands).count
        let res = try await coord.switchRemoteToStagedLocal(
            entries: [x, y],
            expectedQueueID: remoteSnap.queueID,
            expectedDestructiveEpoch: remoteSnap.destructiveEpoch,
            expectedSessionScope: remoteSnap.sessionScope
        )
        #expect(res.acceptedCount == 2)

        let stagedSnap = await coord.currentStructuredQueueSnapshot()
        #expect(stagedSnap.owner == .localCoordinator)
        #expect(stagedSnap.confirmedCurrent == nil)
        #expect(stagedSnap.pendingTarget == nil)
        #expect(stagedSnap.upcomingEntries.map(\.id) == [x.id, y.id])
        #expect(stagedSnap.playbackPhase == .idle)

        let cmdsAfter = await engine.executedCommands
        #expect(cmdsAfter.count == cmdsBefore + 1)
        if case .stop = cmdsAfter.last?.0 {
            #expect(cmdsAfter.last?.1.operationID == 1) // Old context
        } else {
            Issue.record("Expected .stop command with old context")
        }

        // Subsequent Play consumes X
        try await coord.play()
        let afterPlaySnap = await coord.currentStructuredQueueSnapshot()
        #expect(afterPlaySnap.pendingTarget?.id == x.id)
        #expect(afterPlaySnap.upcomingEntries.map(\.id) == [y.id])
    }
}
