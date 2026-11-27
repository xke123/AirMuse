import Foundation
import Testing
@testable import Domain
@testable import Playback

@Suite("PD08: PlaybackSnapshotStore Scope & Migration Tests (R47, R48, B18)")
struct SnapshotScopeTests {

    @Test("R47 & R48: Snapshot refuses unknown provider and cross-account/cross-provider restore")
    func testSnapshotScopeIsolation() async throws {
        let tmpURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("airmuse_snap_test_\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: tmpURL) }

        let store = PlaybackSnapshotStore(fileURL: tmpURL)
        let track = MusicTrack(
            id: "s-1",
            title: "Song 1",
            artistName: "Artist",
            albumTitle: "Album",
            durationMs: 120_000,
            providerID: "fixture_a",
            providerTrackID: "s-1"
        )
        let snapshot = PlaybackSnapshot(
            providerID: "fixture_a",
            accountID: "acct-1",
            storefront: "us",
            queueTracks: [track],
            currentIndex: 0,
            positionMs: 0,
            volume: 0.8,
            repeatMode: .off,
            shuffleEnabled: false
        )
        try await store.save(snapshot)

        // Matching provider + account succeeds
        let loaded = await store.load(expectedProviderID: "fixture_a", expectedAccountID: "acct-1")
        #expect(loaded != nil)
        #expect(loaded?.queueTracks.first?.id == track.id)

        // Mismatched provider refused
        #expect(await store.load(expectedProviderID: "apple_music", expectedAccountID: "acct-1") == nil)

        // Mismatched account refused
        #expect(await store.load(expectedProviderID: "fixture_a", expectedAccountID: "acct-2") == nil)

        // Unknown provider refused
        #expect(await store.load(expectedProviderID: ProviderID.unknown.rawValue, expectedAccountID: "acct-1") == nil)
    }
}
