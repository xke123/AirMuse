// Tests/Unit/CacheKeyTests.swift
// AirMuse macOS – Account-scoped cache-key isolation tests

import Testing
import Foundation
@testable import Domain

struct CacheKeyTests {

    // MARK: - MusicTrack.trackKey isolation

    @Test func trackKeyIsAccountScoped() {
        let trackA = MusicTrack(
            id: "123",
            title: "Song",
            artist: "Artist",
            album: "Album",
            source: .appleMusic,
            accountID: "user-a"
        )
        let trackB = MusicTrack(
            id: "123",
            title: "Song",
            artist: "Artist",
            album: "Album",
            source: .appleMusic,
            accountID: "user-b"
        )
        // Same resource ID, different accounts → different cache keys
        #expect(trackA.trackKey != trackB.trackKey)
    }

    @Test func trackKeyStableForSameAccount() {
        let t1 = MusicTrack(id: "abc", title: "X", artist: "Y", album: "Z",
                            source: .spotify, accountID: "u1")
        let t2 = MusicTrack(id: "abc", title: "X", artist: "Y", album: "Z",
                            source: .spotify, accountID: "u1")
        #expect(t1.trackKey == t2.trackKey)
    }

    @Test func trackKeyDifferentProviders() {
        let am = MusicTrack(id: "42", title: "Track", artist: "A", album: "B",
                            source: .appleMusic, accountID: "u")
        let sp = MusicTrack(id: "42", title: "Track", artist: "A", album: "B",
                            source: .spotify, accountID: "u")
        // Same ID but different provider → different key
        #expect(am.trackKey != sp.trackKey)
    }

    @Test func trackKeyNoIDFallback() {
        // When resourceID is empty, key must still be deterministic and unique per title+artist
        let t = MusicTrack(id: "", title: "FallbackSong", artist: "FallbackArtist",
                           album: "", source: .qqMusic, accountID: "u")
        #expect(!t.trackKey.isEmpty)
    }

    // MARK: - MusicSource rawValue stability

    @Test func sourceRawValuesStable() {
        #expect(MusicSource.appleMusic.rawValue == "apple_music")
        #expect(MusicSource.spotify.rawValue    == "spotify")
        #expect(MusicSource.qqMusic.rawValue    == "qq_music")
        #expect(MusicSource.unknown.rawValue    == "unknown")
    }
}

