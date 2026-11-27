import Foundation
import Testing
@testable import Domain

@Suite("MediaActionResolverTests")
struct MediaActionResolverTests {

    private let fullCaps = MediaActionCapabilities(
        isAuthenticated: true,
        canPlay: true,
        canReadLibraryMembership: true,
        canAddToLibrary: true,
        canRemoveFromLibrary: true,
        canReadFavorite: true,
        canSetFavorite: true,
        canStartSongStation: true,
        canStartArtistStation: true,
        canReorderQueue: true,
        canRemoveFromQueue: true
    )

    @Test("T01: Six resource kinds produce expected menu groups and actions")
    func testSixResourceKindsMenu() {
        let songRef = MediaResourceReference(
            kind: .song,
            canonicalID: "song-1",
            title: "Song 1",
            albumID: "alb-1",
            albumTitle: "Album 1",
            artists: [MediaArtistRef(id: "art-1", name: "Artist 1")]
        )
        let songMenu = MediaActionResolver.resolveContextMenu(for: MediaActionContext(
            resource: songRef,
            location: .trackRow,
            state: MediaResourceState(libraryMembership: .known(false), favorite: .known(false)),
            capabilities: fullCaps
        ))
        #expect(songMenu.sections.count == 3)
        #expect(songMenu.sections[0].actions.map(\.title) == ["仅播放此歌曲", "立即插播", "加入队列开头", "加入队列末尾"])
        #expect(songMenu.sections[1].actions.map(\.title) == ["添加到资料库", "收藏"])
        #expect(songMenu.sections[2].actions.map(\.title) == ["歌曲电台", "查看专辑", "查看歌手"])

        let albumRef = MediaResourceReference(
            kind: .album,
            canonicalID: "alb-1",
            title: "Album 1",
            artists: [MediaArtistRef(id: "art-1", name: "Artist 1")]
        )
        let albumMenu = MediaActionResolver.resolveContextMenu(for: MediaActionContext(
            resource: albumRef,
            location: .card,
            state: MediaResourceState(libraryMembership: .known(true), favorite: .known(true)),
            capabilities: fullCaps
        ))
        #expect(albumMenu.sections[0].actions.map(\.title) == ["播放", "随机播放", "立即插播", "加入队列开头", "加入队列末尾"])
        #expect(albumMenu.sections[1].actions.map(\.title) == ["从资料库移除", "取消收藏"])
        #expect(albumMenu.sections[2].actions.map(\.title) == ["查看专辑", "查看歌手"])

        let artistRef = MediaResourceReference(kind: .artist, canonicalID: "art-1", title: "Artist 1")
        let artistMenu = MediaActionResolver.resolveContextMenu(for: MediaActionContext(
            resource: artistRef,
            location: .card,
            state: MediaResourceState(libraryMembership: .unknown, favorite: .known(false)),
            capabilities: fullCaps
        ))
        #expect(artistMenu.sections[0].actions.map(\.title) == ["播放热门歌曲", "随机播放热门歌曲", "立即插播热门歌曲", "热门歌曲加入队列开头", "热门歌曲加入队列末尾"])
        #expect(artistMenu.sections[1].actions.map(\.title) == ["收藏"])
        #expect(artistMenu.sections[2].actions.map(\.title) == ["艺人电台", "查看歌手"])

        let stationRef = MediaResourceReference(kind: .station, canonicalID: "ra.1", title: "Chill Radio", hasStationDetail: false)
        let stationMenu = MediaActionResolver.resolveContextMenu(for: MediaActionContext(
            resource: stationRef,
            location: .card,
            capabilities: fullCaps
        ))
        #expect(stationMenu.sections.count == 1)
        #expect(stationMenu.sections[0].actions.map(\.title) == ["收听"])

        let entryID = UUID()
        let queueRef = MediaResourceReference(
            kind: .queueEntry,
            canonicalID: "song-1",
            title: "Song 1",
            albumID: "alb-1",
            artists: [MediaArtistRef(id: "art-1", name: "Artist 1")],
            queueEntryID: entryID,
            origin: PlaybackOrigin(kind: .playlist, sourceID: "pl-1", sourceTitle: "My Mix")
        )
        let queueMenu = MediaActionResolver.resolveContextMenu(for: MediaActionContext(
            resource: queueRef,
            location: .queueRow,
            state: MediaResourceState(libraryMembership: .known(false), favorite: .known(true)),
            capabilities: fullCaps,
            selectedQueueEntryIDs: [entryID]
        ))
        #expect(queueMenu.sections.count == 4)
        #expect(queueMenu.sections[0].actions.map(\.title) == ["立即播放", "移到下一首", "移到末尾"])
        #expect(queueMenu.sections[1].actions.map(\.title) == ["添加到资料库", "取消收藏"])
        #expect(queueMenu.sections[2].actions.map(\.title) == ["前往来源（My Mix）", "查看专辑", "查看歌手"])
        #expect(queueMenu.sections[3].actions.map(\.title) == ["移除"])
    }

    @Test("T02: Personal, collaborative, and unknown playlists have zero container write actions")
    func testReadOnlyPlaylistsForbidContainerWrites() {
        for ownership in [PlaylistOwnership.personal, .collaborative, .unknown] {
            let ref = MediaResourceReference(kind: .playlist(ownership), canonicalID: "p.123", title: "Personal")
            let menu = MediaActionResolver.resolveContextMenu(for: MediaActionContext(
                resource: ref,
                location: .card,
                state: MediaResourceState(libraryMembership: .known(true), favorite: .known(false)),
                capabilities: fullCaps
            ))
            let titles = menu.allActions.map(\.title)
            #expect(!titles.contains("添加到资料库"))
            #expect(!titles.contains("从资料库移除"))
            #expect(!titles.contains("收藏"))
            #expect(!titles.contains("取消收藏"))
            #expect(titles.contains("查看歌单"))
        }

        let platformRef = MediaResourceReference(kind: .playlist(.platform), canonicalID: "pl.123", title: "Editorial")
        let platformMenu = MediaActionResolver.resolveContextMenu(for: MediaActionContext(
            resource: platformRef,
            location: .card,
            state: MediaResourceState(libraryMembership: .known(true), favorite: .known(false)),
            capabilities: fullCaps
        ))
        let platformTitles = platformMenu.allActions.map(\.title)
        #expect(platformTitles.contains("从资料库移除"))
        #expect(platformTitles.contains("收藏"))
    }

    @Test("T04: Current detail navigation deduplicates by exact resource ID and supports collaborative artists")
    func testCurrentDetailNavigationDeduplication() {
        let songRef = MediaResourceReference(
            kind: .song,
            canonicalID: "song-1",
            title: "Collab Song",
            albumID: "alb-1",
            albumTitle: "Album 1",
            artists: [
                MediaArtistRef(id: "art-1", name: "Artist 1"),
                MediaArtistRef(id: "art-2", name: "Artist 2")
            ]
        )

        let inAlbumMenu = MediaActionResolver.resolveContextMenu(for: MediaActionContext(
            resource: songRef,
            location: .trackRow,
            capabilities: fullCaps,
            currentDetail: .album(id: "alb-1")
        ))
        #expect(!inAlbumMenu.allActions.map(\.title).contains("查看专辑"))
        #expect(inAlbumMenu.allActions.contains {
            if case .navigateToArtistsSubmenu(let list) = $0 { return list.count == 2 }
            return false
        })

        let inArtist1Menu = MediaActionResolver.resolveContextMenu(for: MediaActionContext(
            resource: songRef,
            location: .trackRow,
            capabilities: fullCaps,
            currentDetail: .artist(id: "art-1")
        ))
        #expect(inArtist1Menu.allActions.contains(.navigateToAlbum(id: "alb-1", title: "Album 1", isLibrary: false)))
        #expect(inArtist1Menu.allActions.contains(.navigateToArtist(MediaArtistRef(id: "art-2", name: "Artist 2"))))
    }

    @Test("T18: Unknown membership/favorite never masquerades as false or offers toggle")
    func testUnknownStateSafety() {
        let songRef = MediaResourceReference(kind: .song, canonicalID: "song-1", title: "Song 1")
        let menu = MediaActionResolver.resolveContextMenu(for: MediaActionContext(
            resource: songRef,
            location: .trackRow,
            state: .unknown,
            capabilities: fullCaps
        ))
        for action in menu.allActions {
            if case .addToLibrary = action { Issue.record("Unknown membership must not offer addToLibrary") }
            if case .removeFromLibrary = action { Issue.record("Unknown membership must not offer removeFromLibrary") }
            if case .favorite = action { Issue.record("Unknown favorite must not offer favorite") }
            if case .unfavorite = action { Issue.record("Unknown favorite must not offer unfavorite") }
        }
        #expect(menu.allActions.contains(.libraryStatusPlaceholder(title: "资料库状态查询中…")))
        #expect(menu.allActions.contains(.favoriteStatusPlaceholder(title: "收藏状态查询中…")))
    }

    @Test("MAS-R03/R04: Identity separation and trusted delete ID guard")
    func testIdentitySeparationAndDeleteGuard() {
        let catalogTrack = MusicTrack(
            id: "123456",
            title: "Catalog Song",
            artistName: "Artist",
            albumTitle: "Album",
            durationMs: 180_000,
            providerID: "apple_music",
            providerTrackID: "123456"
        )
        let catalogRef = MediaResourceReference.from(track: catalogTrack)
        #expect(catalogRef.catalogID == "123456")
        #expect(catalogRef.libraryID == nil)
        #expect(!catalogRef.isLibrary)

        let libraryTrack = MusicTrack(
            id: "i.abc123",
            title: "Library Song",
            artistName: "Artist",
            albumTitle: "Album",
            durationMs: 180_000,
            providerID: "apple_music",
            providerTrackID: "123456",
            isLibrary: true,
            catalogID: "123456",
            libraryID: "i.abc123"
        )
        let libraryRef = MediaResourceReference.from(track: libraryTrack)
        #expect(libraryRef.catalogID == "123456")
        #expect(libraryRef.libraryID == "i.abc123")
        #expect(libraryRef.isLibrary)
        #expect(libraryRef.hasTrustedLibraryDeleteIdentity)

        let unmappedLibRef = MediaResourceReference(
            kind: .album,
            canonicalID: "l.999",
            catalogID: nil,
            libraryID: nil,
            title: "Unmapped Lib Album",
            isLibrary: true
        )
        #expect(!unmappedLibRef.hasTrustedLibraryDeleteIdentity)

        for ownership in [PlaylistOwnership.personal, .collaborative, .unknown] {
            let plRef = MediaResourceReference(kind: .playlist(ownership), canonicalID: "p.1", libraryID: "p.1", title: "RO", isLibrary: true)
            #expect(!plRef.hasTrustedLibraryDeleteIdentity)
        }
    }

    @Test("MAS-R34: Queue entry navigation deduplicates origin album/artist and preserves isLibrary")
    func testQueueEntryNavigationDeduplication() {
        let entryID = UUID()
        let ref = MediaResourceReference(
            kind: .queueEntry,
            canonicalID: "s-1",
            title: "Song",
            isLibrary: true,
            albumID: "alb-1",
            albumTitle: "Album 1",
            artists: [
                MediaArtistRef(id: "art-1", name: "Artist 1", isLibrary: true),
                MediaArtistRef(id: "art-1", name: "Artist 1", isLibrary: true),
                MediaArtistRef(id: "art-2", name: "Artist 2", isLibrary: false)
            ],
            queueEntryID: entryID,
            origin: PlaybackOrigin(kind: .album, sourceID: "alb-1", sourceTitle: "Album 1", isLibrary: true)
        )
        let menu = MediaActionResolver.resolveContextMenu(for: MediaActionContext(
            resource: ref,
            location: .queueRow,
            capabilities: fullCaps,
            selectedQueueEntryIDs: [entryID]
        ))
        let titles = menu.allActions.map(\.title)
        #expect(titles.contains("前往来源（Album 1）"))
        #expect(!titles.contains("查看专辑"))
        let artistSubmenu = menu.allActions.first {
            if case .navigateToArtistsSubmenu(let list) = $0 { return list.count == 2 }
            return false
        }
        #expect(artistSubmenu != nil)
    }

    @Test("MAS-R44: Backward-compatible decoding for MusicTrack and MusicPlaylist")
    func testLegacyCodableCompatibility() throws {
        let legacyTrackJSON = """
        {
          "id": "i.legacy1",
          "title": "Legacy",
          "artistName": "Artist",
          "albumTitle": "Album",
          "durationMs": 120000,
          "isExplicit": false,
          "providerID": "apple_music",
          "providerTrackID": "i.legacy1"
        }
        """.data(using: .utf8)!
        let decodedTrack = try JSONDecoder().decode(MusicTrack.self, from: legacyTrackJSON)
        #expect(decodedTrack.isLibrary)
        #expect(decodedTrack.libraryID == "i.legacy1")
        #expect(decodedTrack.catalogID == nil)

        let legacyPlaylistJSON = """
        {
          "id": "p.legacy",
          "name": "My Playlist",
          "description": "",
          "trackIDs": [],
          "isEditable": true,
          "providerID": "apple_music",
          "providerPlaylistID": "p.legacy"
        }
        """.data(using: .utf8)!
        let decodedPlaylist = try JSONDecoder().decode(MusicPlaylist.self, from: legacyPlaylistJSON)
        #expect(decodedPlaylist.ownership == .unknown)
        #expect(decodedPlaylist.catalogID == nil)
    }
}
