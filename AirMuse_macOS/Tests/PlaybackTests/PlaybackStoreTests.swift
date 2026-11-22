import XCTest
import Domain
import Playback

final class PlaybackStoreTests: XCTestCase {

    func testStoreUpdatesState() async {
        let store = PlaybackStore()
        let initial = await store.state
        XCTAssertFalse(initial.isPlaying)

        var updated = PlaybackState.idle
        updated.isPlaying = true
        updated.sourceName = "Test"

        await store.update(state: updated)
        let after = await store.state
        XCTAssertTrue(after.isPlaying)
        XCTAssertEqual(after.sourceName, "Test")
    }

    func testArtworkPreservation() async {
        let store = PlaybackStore()

        let artData = Data([0xFF, 0xD8, 0xFF])  // fake JPEG header
        let track = MusicTrack(id: "1", title: "Song", artistName: "Band",
                               albumTitle: "Album", durationMs: 120_000,
                               providerID: "test", providerTrackID: "t1")

        var stateWithArt = PlaybackState.idle
        stateWithArt.currentTrack = track
        stateWithArt.artworkData = artData
        await store.update(state: stateWithArt)

        // Update without artwork – should preserve cached art.
        var stateNoArt = PlaybackState.idle
        stateNoArt.currentTrack = track
        stateNoArt.artworkData = nil
        await store.update(state: stateNoArt)

        let result = await store.state
        XCTAssertEqual(result.artworkData, artData, "Artwork should be preserved when track key matches")
    }
}
