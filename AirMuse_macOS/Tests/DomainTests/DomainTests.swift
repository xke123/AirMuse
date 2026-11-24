import Testing
import Domain

@Suite("DomainTests")
struct MusicTrackTests {

    @Test func trackKey() {
        let track = MusicTrack(
            id: "1",
            title: "Bohemian Rhapsody",
            artistName: "Queen",
            albumTitle: "A Night at the Opera",
            durationMs: 354_000,
            providerID: "applemusic",
            providerTrackID: "am-001"
        )
        #expect(track.trackKey == "applemusic|am-001")
    }

    @Test func playbackQueueAdvance() {
        let tracks = (1...3).map {
            MusicTrack(id: "\($0)", title: "Track \($0)", artistName: "Artist",
                       albumTitle: "Album", durationMs: 180_000,
                       providerID: "test", providerTrackID: "t\($0)")
        }
        var queue = PlaybackQueue(tracks: tracks, currentIndex: 0)
        #expect(queue.currentTrack?.id == "1")
        queue.advance()
        #expect(queue.currentTrack?.id == "2")
        queue.advance()
        #expect(queue.currentTrack?.id == "3")
        // Cannot advance past end
        queue.advance()
        #expect(queue.currentTrack?.id == "3")
    }

    @Test func lyricsDocumentActiveLine() {
        let lines = [
            LyricsLine(timeMs: 0,    text: "Intro"),
            LyricsLine(timeMs: 1000, text: "Verse 1"),
            LyricsLine(timeMs: 3000, text: "Chorus"),
        ]
        let doc = LyricsDocument(trackKey: "test|artist", lines: lines)
        #expect(doc.activeLine(atMs: 500)?.text == "Intro")
        #expect(doc.activeLine(atMs: 2000)?.text == "Verse 1")
        #expect(doc.activeLine(atMs: 5000)?.text == "Chorus")
    }
}
