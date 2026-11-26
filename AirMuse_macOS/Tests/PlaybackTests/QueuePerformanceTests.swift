import Foundation
import Testing
import Domain
@testable import Playback

@Suite("QueuePerformanceTests")
struct QueuePerformanceTests {

    private func makeEntries(count: Int) -> [QueueEntry] {
        (0..<count).map { i in
            let t = MusicTrack(
                id: "perf-\(i)",
                title: "Perf Song \(i)",
                artistName: "Artist \(i % 50)",
                albumTitle: "Album \(i % 20)",
                durationMs: 200_000,
                providerID: "apple_music",
                providerTrackID: "perf-\(i)"
            )
            return QueueEntry(track: t, origin: PlaybackOrigin(kind: .playlist, sourceID: "pl-perf", sourceTitle: "Perf Playlist"))
        }
    }

    @Test("Queue operations & snapshot serialization latency for 100 / 1000 / 10000 entries")
    func benchmarkQueueScales() async throws {
        var sysRNG = SystemRandomNumberGenerator()
        for count in [100, 1_000, 10_000] {
            var mgr = QueueManager()
            let entries = makeEntries(count: count)

            let t0 = ContinuousClock.now
            _ = mgr.replaceQueue(entries: entries, startIndex: 0, using: &sysRNG)
            let replaceElapsed = t0.duration(to: .now)

            let t1 = ContinuousClock.now
            mgr.setShuffleEnabled(true, using: &sysRNG)
            let shuffleElapsed = t1.duration(to: .now)

            let upcoming = mgr.upcomingEntries
            if upcoming.count >= 3 {
                try mgr.moveEntries(ids: [upcoming[0].id], before: upcoming[2].id)
            }

            let t2 = ContinuousClock.now
            let payload = mgr.exportPersistencePayload()
            let snap = PlaybackSnapshot(
                providerID: "apple_music",
                accountID: "perf-acct",
                queuePayload: payload,
                positionMs: 12_000,
                volume: 0.8,
                repeatMode: .off,
                shuffleEnabled: true
            )
            let tmpURL = URL(fileURLWithPath: "/tmp/airmuse_perf_\(count)_\(UUID().uuidString).json")
            defer { try? FileManager.default.removeItem(at: tmpURL) }
            let store = PlaybackSnapshotStore(fileURL: tmpURL)
            try await store.save(snap)
            let saveElapsed = t2.duration(to: .now)

            print("[QUEUE_PERF] count=\(count) replace=\(replaceElapsed) shuffle=\(shuffleElapsed) save=\(saveElapsed)")
            #expect(replaceElapsed < .seconds(1))
            #expect(shuffleElapsed < .seconds(1))
            #expect(saveElapsed < .seconds(2))
        }
    }
}
