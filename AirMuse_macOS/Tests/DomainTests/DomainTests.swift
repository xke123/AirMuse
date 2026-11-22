import XCTest
import Domain

final class MusicTrackTests: XCTestCase {

    func testTrackKey() {
        let track = MusicTrack(
            id: "1",
            title: "Bohemian Rhapsody",
            artistName: "Queen",
            albumTitle: "A Night at the Opera",
            durationMs: 354_000,
            providerID: "applemusic",
            providerTrackID: "am-001"
        )
        // trackKey is now provider-scoped: providerID|providerTrackID
        XCTAssertEqual(track.trackKey, "applemusic|am-001")
    }

    func testPlaybackQueueAdvance() {
        let tracks = (1...3).map {
            MusicTrack(id: "\($0)", title: "Track \($0)", artistName: "Artist",
                       albumTitle: "Album", durationMs: 180_000,
                       providerID: "test", providerTrackID: "t\($0)")
        }
        var queue = PlaybackQueue(tracks: tracks, currentIndex: 0)
        XCTAssertEqual(queue.currentTrack?.id, "1")
        queue.advance()
        XCTAssertEqual(queue.currentTrack?.id, "2")
        queue.advance()
        XCTAssertEqual(queue.currentTrack?.id, "3")
        // Cannot advance past end
        queue.advance()
        XCTAssertEqual(queue.currentTrack?.id, "3")
    }

    func testLyricsDocumentActiveLine() {
        let lines = [
            LyricsLine(timeMs: 0,    text: "Intro"),
            LyricsLine(timeMs: 1000, text: "Verse 1"),
            LyricsLine(timeMs: 3000, text: "Chorus"),
        ]
        let doc = LyricsDocument(trackKey: "test|artist", lines: lines)
        XCTAssertEqual(doc.activeLine(atMs: 500)?.text, "Intro")
        XCTAssertEqual(doc.activeLine(atMs: 2000)?.text, "Verse 1")
        XCTAssertEqual(doc.activeLine(atMs: 5000)?.text, "Chorus")
    }
}
