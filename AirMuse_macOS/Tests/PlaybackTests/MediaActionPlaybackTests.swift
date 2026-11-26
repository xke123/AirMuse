import Foundation
import Testing
import Domain
@testable import Playback

private actor MediaActionMockEngine: PlaybackEngineProtocol {
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
            throw NSError(domain: "MediaActionMock", code: -1, userInfo: [NSLocalizedDescriptionKey: "Engine playItem error"])
        }
    }

    func isolateAndReset() async {
        currentEngineInstanceID = UUID()
    }
}

@Suite("MediaActionPlaybackTests")
struct MediaActionPlaybackTests {

    private func makeEntry(_ id: String, origin: PlaybackOrigin = .unknown) -> QueueEntry {
        QueueEntry(
            track: MusicTrack(
                id: id,
                title: "Track \(id)",
                artistName: "Artist",
                albumTitle: "Album",
                durationMs: 180_000,
                providerID: "apple_music",
                providerTrackID: id
            ),
            origin: origin
        )
    }

    private func makeSession() -> SessionContext {
        SessionContext(
            providerID: "apple_music",
            accountID: "acc-ma02",
            storefront: "cn",
            sessionID: UUID(),
            generation: 1
        )
    }

    @Test("T06/T07: shuffleAndPlay shuffles entire collection atomically and explicit replaceAndPlay clears shuffle")
    func testAtomicShuffleAndExplicitSequentialPlay() async throws {
        let store = PlaybackStore()
        let engine = MediaActionMockEngine()
        let coord = PlaybackCoordinatorV2(store: store, engine: engine)
        await coord.start(session: makeSession())

        let entries = ["1", "2", "3", "4", "5", "6"].map { makeEntry($0) }
        let shuffleRes = try await coord.submitIntent(.shuffleAndPlay, entries: entries)
        #expect(shuffleRes.acceptedCount == 6)

        var snap = await coord.currentStructuredQueueSnapshot()
        #expect(snap.requestedShuffle == true)
        #expect(snap.effectiveShuffle == true)
        let firstShuffled = snap.pendingTarget?.track.id
        #expect(firstShuffled != nil)
        let allShuffledIDs = [firstShuffled!] + snap.upcomingEntries.map(\.track.id)
        #expect(Set(allShuffledIDs) == Set(["1", "2", "3", "4", "5", "6"]))
        #expect(allShuffledIDs.count == 6)

        // Explicit sequential play from page menu turns shuffle off in the same decision
        let seqEntries = ["X", "Y", "Z"].map { makeEntry($0) }
        let seqRes = try await coord.submitIntent(.replaceAndPlay, entries: seqEntries, explicitShuffleMode: false)
        #expect(seqRes.acceptedCount == 3)
        snap = await coord.currentStructuredQueueSnapshot()
        #expect(snap.requestedShuffle == false)
        #expect(snap.effectiveShuffle == false)
        #expect(snap.pendingTarget?.track.id == "X")
        #expect(snap.upcomingEntries.map(\.track.id) == ["Y", "Z"])
    }

    @Test("T08: Explicit prepend/append/interrupt batches are never scrambled during shuffle")
    func testExplicitBatchOrderPreservedUnderShuffle() async throws {
        let store = PlaybackStore()
        let engine = MediaActionMockEngine()
        let coord = PlaybackCoordinatorV2(store: store, engine: engine)
        await coord.start(session: makeSession())

        let base = ["A", "B", "C", "D"].map { makeEntry($0) }
        _ = try await coord.submitIntent(.shuffleAndPlay, entries: base)
        let op1 = await engine.executedCommands.last!.1
        await engine.emit(.stateChanged(context: op1, status: .playing))
        try await Task.sleep(for: .milliseconds(20))

        let batch1 = ["X", "Y", "Z"].map { makeEntry($0) }
        _ = try await coord.submitIntent(.prepend, entries: batch1)
        var snap = await coord.currentStructuredQueueSnapshot()
        #expect(Array(snap.upcomingEntries.prefix(3).map(\.track.id)) == ["X", "Y", "Z"])

        let batch2 = ["M", "N"].map { makeEntry($0) }
        _ = try await coord.submitIntent(.append, entries: batch2)
        snap = await coord.currentStructuredQueueSnapshot()
        #expect(Array(snap.upcomingEntries.suffix(2).map(\.track.id)) == ["M", "N"])

        let batch3 = ["I1", "I2"].map { makeEntry($0) }
        _ = try await coord.submitIntent(.interruptAndPlay, entries: batch3)
        snap = await coord.currentStructuredQueueSnapshot()
        #expect(snap.pendingTarget?.track.id == "I1")
        #expect(snap.upcomingEntries.first?.track.id == "I2")
    }

    @Test("T11: Prepend/append when idle builds upcoming queue without auto-playing")
    func testPrependAppendWhileIdleDoesNotAutoPlay() async throws {
        let store = PlaybackStore()
        let engine = MediaActionMockEngine()
        let coord = PlaybackCoordinatorV2(store: store, engine: engine)
        await coord.start(session: makeSession())

        let x = makeEntry("X"), y = makeEntry("Y"), z = makeEntry("Z")
        _ = try await coord.submitIntent(.append, entries: [x, y, z])
        let snap = await coord.currentStructuredQueueSnapshot()
        #expect(snap.activeTarget == nil)
        #expect(snap.pendingTarget == nil)
        #expect(snap.confirmedCurrent == nil)
        #expect(snap.upcomingEntries.map(\.track.id) == ["X", "Y", "Z"])
        let cmds = await engine.executedCommands
        #expect(cmds.isEmpty)
    }

    @Test("T17: QueueCommandResult acceptance does not imply engine playback confirmation on failure")
    func testCommandAcceptedButEngineFails() async throws {
        let store = PlaybackStore()
        let engine = MediaActionMockEngine()
        await engine.setFailNextPlayItem(true)
        let coord = PlaybackCoordinatorV2(store: store, engine: engine)
        await coord.start(session: makeSession())

        let res = try await coord.submitIntent(.replaceAndPlay, entries: [makeEntry("F1"), makeEntry("F2")])
        #expect(res.acceptedCount == 2)

        let snap = await coord.currentStructuredQueueSnapshot()
        #expect(snap.isPendingTargetFailed == true)
        #expect(snap.confirmedCurrent == nil)
        #expect(snap.playbackPhase == .failed)
        #expect(snap.upcomingEntries.map(\.track.id) == ["F2"])
    }
}
