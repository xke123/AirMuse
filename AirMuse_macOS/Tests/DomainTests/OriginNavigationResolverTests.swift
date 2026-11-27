import Foundation
import Testing
@testable import Domain

@Suite("OriginNavigationResolverTests")
struct OriginNavigationResolverTests {

    @Test("P26 & P27: Origin menu emits pure navigation and deduplicates matching album/artist")
    func deduplicatesOriginAndTrackAlbumArtist() {
        let artists = [
            MediaArtistRef(id: "art-1", name: "Artist 1"),
            MediaArtistRef(id: "art-2", name: "Artist 2")
        ]
        let track = MusicTrack(
            id: "song-1",
            title: "Song 1",
            artistName: "Artist 1, Artist 2",
            albumTitle: "Album 1",
            durationMs: 200_000,
            providerID: "apple_music",
            providerTrackID: "song-1",
            albumID: "alb-1",
            artists: artists
        )
        let origin = PlaybackOrigin(
            kind: .album,
            sourceID: "alb-1",
            sourceTitle: "Album 1",
            navigationTarget: .resource(kind: .album, id: "alb-1", isLibrary: false, providerID: "apple_music")
        )
        let entry = QueueEntry(track: track, origin: origin)

        let menu = MediaActionResolver.resolveOriginMenu(for: entry, owner: .localCoordinator, currentDetail: nil)
        let allActions = menu.sections.flatMap(\.actions)

        // All three fixed options are present: navigateToOriginConcise(alb-1), navigateToAlbum(alb-1), navigateToArtistsSubmenu([art-1, art-2])
        #expect(allActions.contains(where: { if case .navigateToOriginConcise = $0 { return true }; return false }))
        #expect(allActions.contains(where: { if case .navigateToAlbum(let id, _, _) = $0 { return id == "alb-1" }; return false }))
        // Multiple artists -> submenu with both
        #expect(allActions.contains(where: {
            if case .navigateToArtistsSubmenu(let refs) = $0 { return refs.map(\.id) == ["art-1", "art-2"] }
            return false
        }))
        // Pure navigation: zero play/queue/library/favorite actions
        for action in allActions {
            switch action {
            case .play, .playQueueEntry, .addToLibrary, .removeFromLibrary, .favorite, .unfavorite, .startSongStation, .startArtistStation:
                Issue.record("Unexpected non-navigation action in origin menu: \(action)")
            default:
                break
            }
        }
    }

    @Test("P28: Duplicate artist IDs are deduplicated in submenu")
    func deduplicatesRepeatedArtistIDs() {
        let artists = [
            MediaArtistRef(id: "art-1", name: "Same Artist"),
            MediaArtistRef(id: "art-1", name: "Same Artist Dup"),
            MediaArtistRef(id: "art-2", name: "Other Artist")
        ]
        let track = MusicTrack(
            id: "song-2",
            title: "Song 2",
            artistName: "Same Artist, Other Artist",
            albumTitle: "Album 2",
            durationMs: 180_000,
            providerID: "apple_music",
            providerTrackID: "song-2",
            albumID: "alb-2",
            artists: artists
        )
        let entry = QueueEntry(track: track, origin: .unknown)
        let menu = MediaActionResolver.resolveOriginMenu(for: entry, owner: .localCoordinator, currentDetail: nil)
        let allActions = menu.sections.flatMap(\.actions)
        #expect(allActions.contains(where: {
            if case .navigateToArtistsSubmenu(let refs) = $0 { return refs.map(\.id) == ["art-1", "art-2"] }
            return false
        }))
    }

    @Test("P29: Station seed artist and current track artist are both shown distinctly")
    func stationSeedAndCurrentTrackArtistDistinct() {
        let seed = StationSeedResource(kind: .artist, id: "art-jay", title: "周杰伦")
        let origin = PlaybackOrigin(
            kind: .station,
            sourceID: "ra.jay",
            sourceTitle: "周杰伦电台",
            navigationTarget: .browseSection(id: "radio_am", title: "AM 电台"),
            stationContext: StationOriginContext(stationID: "ra.jay", stationType: .algorithmic, seedResource: seed)
        )
        let track = MusicTrack(
            id: "song-jj",
            title: "江南",
            artistName: "林俊杰",
            albumTitle: "第二天堂",
            durationMs: 240_000,
            providerID: "apple_music",
            providerTrackID: "song-jj",
            albumID: "alb-jj",
            artists: [MediaArtistRef(id: "art-jj", name: "林俊杰")]
        )
        let entry = QueueEntry(track: track, origin: origin)
        let menu = MediaActionResolver.resolveOriginMenu(for: entry, owner: .remoteEngine, currentDetail: nil)
        let allActions = menu.sections.flatMap(\.actions)

        #expect(allActions.contains(where: { if case .navigateToOriginConcise = $0 { return true }; return false }))
        #expect(allActions.contains(where: {
            if case .navigateToSeedArtist(let ref) = $0 { return ref.id == "art-jay" && ref.name == "周杰伦" }
            return false
        }))
        #expect(allActions.contains(where: {
            if case .navigateToAlbum(let id, _, _) = $0 { return id == "alb-jj" }
            return false
        }))
        #expect(allActions.contains(where: {
            if case .navigateToArtist(let ref) = $0 { return ref.id == "art-jj" }
            return false
        }))
    }

    @Test("P30: Search, library, and chart origins are navigable via typed targets")
    func searchLibraryChartNavigable() {
        let searchOrigin = PlaybackOrigin(
            kind: .search,
            sourceID: "稻香",
            sourceTitle: "搜索「稻香」",
            navigationTarget: .search(query: "稻香", scope: "catalog", sectionID: "songs")
        )
        let libOrigin = PlaybackOrigin(
            kind: .library,
            sourceID: "lib_songs",
            sourceTitle: "歌曲",
            isLibrary: true,
            navigationTarget: .librarySection(id: "lib_songs", title: "歌曲")
        )
        let chartOrigin = PlaybackOrigin(
            kind: .chart,
            sourceID: "chart_top",
            sourceTitle: "今日热门",
            navigationTarget: .chart(id: "chart_top", title: "今日热门", isLibrary: false)
        )
        #expect(searchOrigin.canNavigate == true)
        #expect(libOrigin.canNavigate == true)
        #expect(chartOrigin.canNavigate == true)
        #expect(PlaybackOrigin.unknown.canNavigate == false)
    }
}
