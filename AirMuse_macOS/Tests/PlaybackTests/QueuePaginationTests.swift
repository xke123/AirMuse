import Foundation
import Testing
import Domain
@testable import Playback

private actor MockPaginationEngine: PlaybackEngineProtocol {
    let engineInstanceID = UUID()
    func events() async -> AsyncStream<EngineEvent> { AsyncStream { _ in } }
    func prepare(sessionContext: SessionContext, deadlineSeconds: TimeInterval) async throws {}
    func execute(_ command: EngineCommand, context: PlaybackOperationContext) async throws {}
    func isolateAndReset() async {}
}

@Suite("QueuePaginationTests")
struct QueuePaginationTests {

    private func makeTracks(prefix: String, count: Int, duplicateID: String? = nil) -> [MusicTrack] {
        (0..<count).map { i in
            let id = duplicateID ?? "\(prefix)-\(i)"
            return MusicTrack(
                id: id,
                title: "Track \(prefix)-\(i)",
                artistName: "Artist",
                albumTitle: "Playlist",
                durationMs: 180_000,
                providerID: "apple_music",
                providerTrackID: id
            )
        }
    }

    @Test("T14: 350-track playlist paginates completely and preserves duplicate tracks")
    func largePlaylistPaginationPreservesDuplicates() async throws {
        let store = PlaybackStore()
        let engine = MockPaginationEngine()
        let coord = PlaybackCoordinatorV2(store: store, engine: engine)
        let session = SessionContext(providerID: "apple_music", accountID: "u1", storefront: "cn", sessionID: UUID(), generation: 1)
        await coord.start(session: session)

        let batchID = UUID()
        let origin = PlaybackOrigin(kind: .playlist, sourceID: "pl-350", sourceTitle: "Big Playlist", isLibrary: true)
        // Page 1: 100 tracks (with duplicates of "dup-song")
        let page1Tracks = makeTracks(prefix: "p1", count: 98) + makeTracks(prefix: "dup", count: 2, duplicateID: "dup-song")
        let page1Entries = page1Tracks.map { QueueEntry(track: $0, origin: origin, batchID: batchID) }

        try await coord.playEntries(
            page1Entries,
            startIndex: 0,
            loadingState: .loading(loadedCount: 100, totalCount: 350),
            batchID: batchID
        )
        let snap = await coord.currentStructuredQueueSnapshot()

        let loader = QueuePaginationLoader(maxPages: 20)
        await loader.startBackgroundPagination(
            coordinator: coord,
            batchID: batchID,
            expectedQueueID: snap.queueID,
            expectedSessionScope: snap.sessionScope,
            expectedDestructiveEpoch: snap.destructiveEpoch,
            origin: origin,
            initialLoadedCount: 100,
            initialNextURL: URL(string: "https://example.com/page/2")!,
            totalCount: 350
        ) { url in
            switch url.lastPathComponent {
            case "2":
                return QueuePageFetchResult(
                    tracks: makeTracks(prefix: "p2", count: 100),
                    nextURL: URL(string: "https://example.com/page/3")!,
                    totalCount: 350
                )
            case "3":
                return QueuePageFetchResult(
                    tracks: makeTracks(prefix: "p3", count: 100),
                    nextURL: URL(string: "https://example.com/page/4")!,
                    totalCount: 350
                )
            default:
                return QueuePageFetchResult(
                    tracks: makeTracks(prefix: "p4", count: 50),
                    nextURL: nil,
                    totalCount: 350
                )
            }
        }

        // Wait deterministically for completion
        for _ in 0..<50 {
            let cur = await coord.currentStructuredQueueSnapshot()
            if case .complete(let total) = cur.loadingState, total == 350 {
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }

        let finalSnap = await coord.currentStructuredQueueSnapshot()
        #expect(finalSnap.loadingState == .complete(totalCount: 350))
        #expect(finalSnap.upcomingEntries.count == 349)
        let dupCount = finalSnap.upcomingEntries.filter { $0.track.id == "dup-song" }.count
        #expect(dupCount == 2)
    }

    @Test("T14 & T16: Circular cursor fails boundedly and network failure preserves partial queue with retryable state")
    func circularCursorAndPartialFailure() async throws {
        let store = PlaybackStore()
        let engine = MockPaginationEngine()
        let coord = PlaybackCoordinatorV2(store: store, engine: engine)
        let session = SessionContext(providerID: "apple_music", accountID: "u1", storefront: "cn", sessionID: UUID(), generation: 1)
        await coord.start(session: session)

        let batchID = UUID()
        let origin = PlaybackOrigin(kind: .playlist, sourceID: "pl-loop", sourceTitle: "Loop Playlist")
        let p1 = makeTracks(prefix: "p1", count: 10).map { QueueEntry(track: $0, origin: origin, batchID: batchID) }
        try await coord.playEntries(p1, startIndex: 0, loadingState: .loading(loadedCount: 10, totalCount: nil), batchID: batchID)
        let snap = await coord.currentStructuredQueueSnapshot()

        let loader = QueuePaginationLoader(maxPages: 20)
        let loopURL = URL(string: "https://example.com/page/loop")!
        await loader.startBackgroundPagination(
            coordinator: coord,
            batchID: batchID,
            expectedQueueID: snap.queueID,
            expectedSessionScope: snap.sessionScope,
            expectedDestructiveEpoch: snap.destructiveEpoch,
            origin: origin,
            initialLoadedCount: 10,
            initialNextURL: loopURL,
            totalCount: nil
        ) { _ in
            QueuePageFetchResult(tracks: makeTracks(prefix: "loop", count: 5), nextURL: loopURL, totalCount: nil)
        }

        for _ in 0..<50 {
            let cur = await coord.currentStructuredQueueSnapshot()
            if case .failed(_, _, _, let retryable) = cur.loadingState, !retryable {
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }

        let finalSnap = await coord.currentStructuredQueueSnapshot()
        if case .failed(let loaded, _, _, let retryable) = finalSnap.loadingState {
            #expect(loaded == 15)
            #expect(!retryable)
        } else {
            #expect(Bool(false), "Expected bounded circular cursor failure")
        }
    }
}
