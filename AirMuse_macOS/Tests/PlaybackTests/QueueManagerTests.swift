import Foundation
import Testing
import Domain
@testable import Playback

private struct SeededRNG: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { self.state = seed == 0 ? 0x9E3779B97F4A7C15 : seed }
    mutating func next() -> UInt64 {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return state
    }
}

@Suite("QueueManagerTests")
struct QueueManagerTests {

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

    private func makeEntry(_ id: String, origin: PlaybackOrigin = .unknown, batchID: UUID? = nil) -> QueueEntry {
        QueueEntry(track: makeTrack(id), origin: origin, batchID: batchID)
    }

    @Test("T01: Sequential advancement consumes upcoming head and stops when exhausted")
    func sequentialAdvancement() {
        var mgr = QueueManager()
        var rng = SeededRNG(seed: 1)
        let a = makeEntry("A"), b = makeEntry("B"), c = makeEntry("C"), d = makeEntry("D")

        let first = mgr.replaceQueue(entries: [a, b, c, d], startIndex: 0, using: &rng)
        #expect(first?.id == a.id)
        mgr.confirmEntry(a.id)
        #expect(mgr.upcomingEntries.map(\.id) == [b.id, c.id, d.id])

        let r1 = mgr.advanceOnNaturalEnd(using: &rng)
        #expect(r1 == .play(entry: b, isRepeatOne: false))
        mgr.confirmEntry(b.id)
        #expect(mgr.upcomingEntries.map(\.id) == [c.id, d.id])
        #expect(mgr.historyEntries.map(\.id) == [a.id])

        _ = mgr.advanceOnNaturalEnd(using: &rng)
        mgr.confirmEntry(c.id)
        _ = mgr.advanceOnNaturalEnd(using: &rng)
        mgr.confirmEntry(d.id)
        #expect(mgr.upcomingEntries.isEmpty)

        let end = mgr.advanceOnNaturalEnd(using: &rng)
        #expect(end == .exhausted)
    }

    @Test("T02: Duplicate track IDs from different origins have independent identities")
    func duplicateTrackIDsDifferentOrigins() throws {
        var mgr = QueueManager()
        var rng = SeededRNG(seed: 2)
        let origin1 = PlaybackOrigin(kind: .album, sourceID: "alb1", sourceTitle: "Album 1")
        let origin2 = PlaybackOrigin(kind: .playlist, sourceID: "pl1", sourceTitle: "Playlist 1")
        let a = makeEntry("A", origin: origin1)
        let dup1 = makeEntry("DUP", origin: origin1)
        let dup2 = makeEntry("DUP", origin: origin2)

        _ = mgr.replaceQueue(entries: [a, dup1, dup2], startIndex: 0, using: &rng)
        mgr.confirmEntry(a.id)
        try mgr.removeEntries(ids: [dup2.id])

        #expect(mgr.upcomingEntries.count == 1)
        #expect(mgr.upcomingEntries.first?.id == dup1.id)
        #expect(mgr.upcomingEntries.first?.origin == origin1)
    }

    @Test("T03: Shuffle consumes each upcoming entry once per round and toggling off restores base relative order")
    func shuffleRoundAndRestore() {
        var mgr = QueueManager()
        var rng = SeededRNG(seed: 42)
        let entries = ["A", "B", "C", "D", "E", "F"].map { makeEntry($0) }
        _ = mgr.replaceQueue(entries: entries, startIndex: 0, using: &rng)
        mgr.confirmEntry(entries[0].id)

        mgr.setShuffleEnabled(true, using: &rng)
        let shuffledIDs = mgr.upcomingEntries.map(\.id)
        #expect(Set(shuffledIDs) == Set(entries.dropFirst().map(\.id)))
        #expect(shuffledIDs.count == 5)

        // Consume two items
        guard case .play(let p1, false) = mgr.advanceNext(using: &rng) else {
            #expect(Bool(false))
            return
        }
        mgr.confirmEntry(p1.id)
        guard case .play(let p2, false) = mgr.advanceNext(using: &rng) else {
            #expect(Bool(false))
            return
        }
        mgr.confirmEntry(p2.id)

        // Turn shuffle off: only unplayed items remain, in their original relative order
        mgr.setShuffleEnabled(false, using: &rng)
        let remaining = mgr.upcomingEntries.map(\.id)
        let expectedRemaining = entries.dropFirst().map(\.id).filter { $0 != p1.id && $0 != p2.id }
        #expect(remaining == expectedRemaining)
    }

    @Test("T04: Explicit move during shuffle persists in baselineOrder when shuffle is turned off")
    func explicitMovePersistsAcrossShuffleToggle() throws {
        var mgr = QueueManager()
        var rng = SeededRNG(seed: 7)
        let a = makeEntry("A"), b = makeEntry("B"), c = makeEntry("C"), d = makeEntry("D")
        _ = mgr.replaceQueue(entries: [a, b, c, d], startIndex: 0, using: &rng)
        mgr.confirmEntry(a.id)

        mgr.setShuffleEnabled(true, using: &rng)
        // Move D before B in upcoming
        try mgr.moveEntries(ids: [d.id], before: b.id)

        mgr.setShuffleEnabled(false, using: &rng)
        let ids = mgr.upcomingEntries.map(\.id)
        let dIdx = ids.firstIndex(of: d.id)!
        let bIdx = ids.firstIndex(of: b.id)!
        #expect(dIdx < bIdx)
    }

    @Test("T05: Repeat one replays current on natural end, but manual Next consumes upcoming")
    func repeatOneNaturalVsManualNext() {
        var mgr = QueueManager()
        var rng = SeededRNG(seed: 3)
        let a = makeEntry("A"), b = makeEntry("B")
        _ = mgr.replaceQueue(entries: [a, b], startIndex: 0, using: &rng)
        mgr.confirmEntry(a.id)
        mgr.setRepeatMode(.one)

        let nat = mgr.advanceOnNaturalEnd(using: &rng)
        #expect(nat == .play(entry: a, isRepeatOne: true))
        #expect(mgr.upcomingEntries.map(\.id) == [b.id])

        let man = mgr.advanceNext(using: &rng)
        #expect(man == .play(entry: b, isRepeatOne: false))
        #expect(mgr.upcomingEntries.isEmpty)
    }

    @Test("T06 & T07: Repeat all regenerates cycle excluding deleted entries; clearUpcoming stops repeat-all resurrection")
    func repeatAllAndClearUpcoming() throws {
        var mgr = QueueManager()
        var rng = SeededRNG(seed: 9)
        let a = makeEntry("A"), b = makeEntry("B"), c = makeEntry("C")
        _ = mgr.replaceQueue(entries: [a, b, c], startIndex: 0, using: &rng)
        mgr.confirmEntry(a.id)
        mgr.setRepeatMode(.all)

        try mgr.removeEntries(ids: [b.id])
        _ = mgr.advanceOnNaturalEnd(using: &rng)
        mgr.confirmEntry(c.id)

        // Cycle regenerates without deleted B
        let nextRound = mgr.advanceOnNaturalEnd(using: &rng)
        #expect(nextRound == .play(entry: a, isRepeatOne: false))
        mgr.confirmEntry(a.id)
        #expect(mgr.upcomingEntries.map(\.id) == [c.id])

        // Clear upcoming: A keeps playing, repeat-all does not resurrect C
        try mgr.clearUpcoming()
        #expect(mgr.confirmedCurrentID == a.id)
        #expect(mgr.upcomingEntries.isEmpty)
        #expect(mgr.advanceOnNaturalEnd(using: &rng) == .exhausted)

        // Repeat-one still replays A even after clearUpcoming
        mgr.setRepeatMode(.one)
        #expect(mgr.advanceOnNaturalEnd(using: &rng) == .play(entry: a, isRepeatOne: true))
    }

    @Test("T08: playEntry plays target D while preserving B, C, E relative order")
    func playSpecificEntryPreservesOthers() throws {
        var mgr = QueueManager()
        var rng = SeededRNG(seed: 10)
        let a = makeEntry("A"), b = makeEntry("B"), c = makeEntry("C"), d = makeEntry("D"), e = makeEntry("E")
        _ = mgr.replaceQueue(entries: [a, b, c, d, e], startIndex: 0, using: &rng)
        mgr.confirmEntry(a.id)

        let res = try mgr.playEntry(id: d.id)
        #expect(res.playbackTarget?.id == d.id)
        mgr.confirmEntry(d.id)
        #expect(mgr.upcomingEntries.map(\.id) == [b.id, c.id, e.id])
    }

    @Test("T10: Batch insertNext preserves order at head; append adds to tail without auto-play")
    func batchInsertNextAndAppend() throws {
        var mgr = QueueManager()
        let x = makeEntry("X"), y = makeEntry("Y"), z = makeEntry("Z"), w = makeEntry("W")

        // Idle append does not start playback
        try mgr.append([w])
        #expect(mgr.confirmedCurrentID == nil)
        #expect(mgr.upcomingEntries.map(\.id) == [w.id])

        try mgr.insertNext([x, y, z])
        #expect(mgr.upcomingEntries.map(\.id) == [x.id, y.id, z.id, w.id])
    }

    @Test("T11: Previous obeys 3s threshold and navigates history/forward candidate without duplicating history")
    func previousAndForwardCandidate() {
        var mgr = QueueManager()
        var rng = SeededRNG(seed: 12)
        let a = makeEntry("A"), b = makeEntry("B"), c = makeEntry("C")
        _ = mgr.replaceQueue(entries: [a, b, c], startIndex: 0, using: &rng)
        mgr.confirmEntry(a.id)
        _ = mgr.advanceNext(using: &rng)
        mgr.confirmEntry(b.id)

        // > 3s seeks to zero
        #expect(mgr.retreatPrevious(positionMs: 4500) == .seekToZero)

        // <= 3s goes back to A, and B becomes forward candidate at head of upcoming
        #expect(mgr.retreatPrevious(positionMs: 1200) == .play(entry: a, isRepeatOne: false))
        mgr.confirmEntry(a.id)
        #expect(mgr.historyEntries.isEmpty)
        #expect(mgr.upcomingEntries.map(\.id) == [b.id, c.id])

        // Next returns to B and puts A back in history
        #expect(mgr.advanceNext(using: &rng) == .play(entry: b, isRepeatOne: false))
        mgr.confirmEntry(b.id)
        #expect(mgr.historyEntries.map(\.id) == [a.id])
    }

    @Test("T15: Paginated batch commit preserves anchor and ignores invalidated batches")
    func paginatedBatchCommit() throws {
        var mgr = QueueManager()
        var rng = SeededRNG(seed: 13)
        let scope = "apple_music|acct1"
        mgr.setSessionScope(scope)

        let batchID = UUID()
        let a = makeEntry("A", batchID: batchID), b = makeEntry("B", batchID: batchID)
        _ = mgr.replaceQueue(entries: [a, b], startIndex: 0, loadingState: .loading(loadedCount: 2, totalCount: 4), batchID: batchID, using: &rng)
        mgr.confirmEntry(a.id)

        // User appends Z after initial page
        let z = makeEntry("Z")
        try mgr.append([z])

        // Page 2 arrives: should insert after B and BEFORE Z!
        let c = makeEntry("C", batchID: batchID), d = makeEntry("D", batchID: batchID)
        let committed = mgr.commitPaginatedBatch([c, d], batchID: batchID, expectedQueueID: mgr.queueID, expectedSessionScope: scope, loadingState: .complete(totalCount: 4), using: &rng)
        #expect(committed)
        #expect(mgr.upcomingEntries.map(\.id) == [b.id, c.id, d.id, z.id])

        // Clear invalidates batch; late page is rejected
        try mgr.clearUpcoming()
        let e = makeEntry("E", batchID: batchID)
        let lateCommitted = mgr.commitPaginatedBatch([e], batchID: batchID, expectedQueueID: mgr.queueID, expectedSessionScope: scope, loadingState: .complete(totalCount: 5), using: &rng)
        #expect(!lateCommitted)
        #expect(mgr.upcomingEntries.isEmpty)
    }

    @Test("T24: Safe undo restores removed/cleared items only when revision and session match")
    func safeUndo() throws {
        var mgr = QueueManager()
        var rng = SeededRNG(seed: 14)
        mgr.setSessionScope("scope1")
        let a = makeEntry("A"), b = makeEntry("B"), c = makeEntry("C")
        _ = mgr.replaceQueue(entries: [a, b, c], startIndex: 0, using: &rng)
        mgr.confirmEntry(a.id)

        try mgr.removeEntries(ids: [b.id])
        #expect(mgr.makeSnapshot().canUndo)
        try mgr.undo(expectedQueueID: mgr.queueID, expectedSessionScope: "scope1")
        #expect(mgr.upcomingEntries.map(\.id) == [b.id, c.id])
        #expect(!mgr.makeSnapshot().canUndo)

        // Intervening edit invalidates undo
        try mgr.clearUpcoming()
        #expect(mgr.makeSnapshot().canUndo)
        try mgr.append([makeEntry("D")])
        #expect(!mgr.makeSnapshot().canUndo)
        #expect(throws: QueueEditError.self) {
            try mgr.undo(expectedQueueID: mgr.queueID, expectedSessionScope: "scope1")
        }
    }
}
