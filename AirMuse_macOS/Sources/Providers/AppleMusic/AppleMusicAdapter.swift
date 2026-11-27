import Foundation
import Domain
import Infrastructure

// MARK: - AppleMusicAdapter

/// Encapsulates Apple Music provider, browse/pagination mapping, and lazy engine creation
/// behind the generic `PlatformAdapter` and `PlatformBrowseProvider` contracts.
public final class AppleMusicAdapter: PlatformAdapter, PlatformBrowseProvider, @unchecked Sendable {
    public let descriptor: PlatformDescriptor
    public let provider: AppleMusicProvider
    private let engineFactory: @Sendable () async -> any PlaybackEngineProtocol

    public var catalogProvider: (any MusicCatalogProvider)? { provider }
    public var libraryProvider: (any MusicLibraryProvider)? { provider }
    public var searchProvider: (any MusicSearchProvider)? { provider }
    public var mutationProvider: (any MediaResourceMutationProvider)? { provider }
    public var authProvider: (any MusicAuthenticationProvider)? { provider }
    public var browseProvider: (any PlatformBrowseProvider)? { self }
    public var lyricsProvider: (any MusicLyricsProvider)? { provider }

    public var providerID: ProviderID { .appleMusic }

    public init(
        provider: AppleMusicProvider,
        descriptor: PlatformDescriptor = AppleMusicAdapterFactory.defaultDescriptor,
        engineFactory: @escaping @Sendable () async -> any PlaybackEngineProtocol
    ) {
        self.provider = provider
        self.descriptor = descriptor
        self.engineFactory = engineFactory
    }

    public func makePlaybackEngine() async -> (any PlaybackEngineProtocol)? {
        await engineFactory()
    }

    // MARK: - PlatformBrowseProvider

    public func fetchBrowsePage(route: BrowseRoute, session: SessionContext?) async throws -> BrowsePageModel {
        guard route.providerID == .appleMusic else {
            throw CoreError.unsupported("Route provider \(route.providerID.rawValue) does not match apple_music")
        }
        let scope = route.scope
        switch route.kind {
        case .tab(let tabID):
            switch tabID {
            case "home":
                let categories = try await provider.fetchRecommendations()
                return BrowsePageModel(
                    route: route,
                    title: "主页",
                    sections: categories.map { Self.mapCategory($0, scope: scope, routeFingerprint: "tab:home") }
                )
            case "browse":
                let categories = try await provider.fetchEditorialCategories(name: "music")
                return BrowsePageModel(
                    route: route,
                    title: "浏览",
                    sections: categories.map { Self.mapCategory($0, scope: scope, routeFingerprint: "tab:browse") }
                )
            case "radio":
                let categories = try await provider.fetchEditorialCategories(name: "radio")
                return BrowsePageModel(
                    route: route,
                    title: "广播",
                    sections: categories.map { Self.mapCategory($0, scope: scope, routeFingerprint: "tab:radio") }
                )
            case "library":
                let recent = try await provider.fetchRecentlyAdded()
                let recentSection = BrowseSectionModel(
                    id: "library-recent",
                    title: "最近添加",
                    items: recent.map { Self.mapItem($0, scope: scope) }
                )
                return BrowsePageModel(route: route, title: "资料库", sections: [recentSection])
            default:
                throw CoreError.unsupported("Unknown Apple Music tab: \(tabID)")
            }

        case .search(let query, _):
            let result = try await provider.search(query: query)
            let sections = result.sections.map { sec in
                let cards = sec.items.map { item -> MediaCardModel in
                    let kind: ResourceKind
                    let rawID: String
                    let artworkURL: URL?
                    let track: MusicTrack?
                    switch item {
                    case .track(let t):
                        kind = .song; rawID = t.id; artworkURL = t.artworkURL; track = t
                    case .album(let a):
                        kind = .album; rawID = a.id; artworkURL = a.artworkURL; track = nil
                    case .artist(let a):
                        kind = .artist; rawID = a.id; artworkURL = a.artworkURL; track = nil
                    case .playlist(let p):
                        kind = .playlist; rawID = p.id; artworkURL = p.artworkURL; track = nil
                    case .station(let s):
                        kind = .station; rawID = s.id; artworkURL = s.artworkURL; track = nil
                    case .musicVideo(let v):
                        kind = .song; rawID = v.id; artworkURL = v.artworkURL; track = v
                    case .curator(let id, _, _, let art):
                        kind = .section; rawID = id; artworkURL = art; track = nil
                    }
                    let id = ResourceIdentity(providerID: .appleMusic, kind: kind, opaqueID: rawID, scope: scope)
                    return MediaCardModel(
                        identity: id,
                        title: item.displayTitle,
                        subtitle: item.displaySubtitle,
                        artworkURL: artworkURL,
                        track: track
                    )
                }
                let next = sec.nextURL.map {
                    PageCursor(
                        opaqueToken: $0,
                        providerID: .appleMusic,
                        scope: scope,
                        routeFingerprint: "search:\(query):\(sec.id)"
                    )
                }
                return BrowseSectionModel(id: sec.id, title: sec.title, items: cards, nextCursor: next)
            }
            return BrowsePageModel(route: route, title: "搜索: \(query)", sections: sections)

        case .section(let id, let title):
            return BrowsePageModel(route: route, title: title ?? id, sections: [])

        case .detail(let identity):
            return BrowsePageModel(route: route, title: identity.opaqueID, sections: [])
        }
    }

    public func fetchSectionPage(cursor: PageCursor, session: SessionContext?) async throws -> BrowseSectionModel {
        guard cursor.providerID == .appleMusic,
              let url = URL(string: cursor.opaqueToken) else {
            throw CoreError.invalidCursor
        }
        let page = try await provider.fetchTracksPage(nextURL: url, isLibrary: cursor.scope.isLibrary)
        let cards = page.tracks.map { track in
            let id = ResourceIdentity(
                providerID: .appleMusic,
                kind: .song,
                opaqueID: track.id,
                scope: cursor.scope
            )
            return MediaCardModel(
                identity: id,
                title: track.title,
                subtitle: track.artistName,
                artworkURL: track.artworkURL,
                isExplicit: track.isExplicit,
                track: track
            )
        }
        let next = page.nextURL.map {
            PageCursor(
                opaqueToken: $0.absoluteString,
                providerID: .appleMusic,
                scope: cursor.scope,
                routeFingerprint: cursor.routeFingerprint
            )
        }
        return BrowseSectionModel(id: cursor.routeFingerprint, title: "", items: cards, nextCursor: next)
    }

    public func fetchCollectionTracks(
        identity: ResourceIdentity,
        cursor: PageCursor?,
        session: SessionContext?
    ) async throws -> CollectionTrackPage {
        guard identity.providerID == .appleMusic else {
            throw CoreError.unsupported("Identity provider mismatch")
        }
        let fingerprint = "collection:\(identity.kind.rawValue):\(identity.opaqueID)"
        let isLibrary = identity.scope.isLibrary || Self.isAppleMusicLibraryID(identity.opaqueID)
        let page: AppleMusicAmpClient.TrackPage
        if let cursor {
            guard cursor.matches(providerID: .appleMusic, scope: identity.scope, routeFingerprint: fingerprint),
                  let nextURL = URL(string: cursor.opaqueToken) else {
                throw CoreError.invalidCursor
            }
            page = try await provider.fetchTracksPage(nextURL: nextURL, isLibrary: isLibrary)
        } else {
            switch identity.kind {
            case .album:
                page = try await provider.fetchAlbumTracksPage(albumID: identity.opaqueID, isLibrary: isLibrary)
            case .playlist:
                page = try await provider.fetchPlaylistTracksPage(playlistID: identity.opaqueID, isLibrary: isLibrary)
            case .artist:
                let tracks = try await provider.fetchArtistTopSongs(artistID: identity.opaqueID, isLibrary: isLibrary)
                page = AppleMusicAmpClient.TrackPage(tracks: tracks, nextURL: nil, totalCount: tracks.count)
            default:
                throw CoreError.unsupported("Collection kind \(identity.kind.rawValue) unsupported")
            }
        }

        let nextCursor = page.nextURL.map {
            PageCursor(
                opaqueToken: $0.absoluteString,
                providerID: .appleMusic,
                scope: identity.scope,
                routeFingerprint: fingerprint
            )
        }
        return CollectionTrackPage(tracks: page.tracks, nextCursor: nextCursor, totalCount: page.totalCount)
    }

    public func fetchArtistDetail(identity: ResourceIdentity, session: SessionContext?) async throws -> MusicArtistDetail {
        guard identity.providerID == .appleMusic else {
            throw CoreError.unsupported("Identity provider mismatch")
        }
        return try await provider.fetchArtistDetail(artistID: identity.opaqueID, isLibrary: identity.scope.isLibrary)
    }

    public func fetchArtistStation(artistID: String, scope: ResourceScope) async throws -> MusicStation? {
        try await provider.fetchArtistStation(artistID: artistID)
    }

    public func fetchSongStation(songID: String, scope: ResourceScope) async throws -> MusicStation? {
        try await provider.fetchSongStation(songID: songID)
    }

    public func resolveTrackRelationships(for track: MusicTrack) async -> MusicTrack? {
        await provider.resolveTrackRelationships(for: track)
    }

    // MARK: - Mappers

    static func mapCategory(_ category: AmpCategory, scope: ResourceScope, routeFingerprint: String) -> BrowseSectionModel {
        let nextCursor = category.nextURL.map {
            PageCursor(
                opaqueToken: $0.absoluteString,
                providerID: .appleMusic,
                scope: scope,
                routeFingerprint: "\(routeFingerprint):\(category.id)"
            )
        }
        return BrowseSectionModel(
            id: category.id,
            title: category.title,
            items: category.items.map { mapItem($0, scope: scope) },
            nextCursor: nextCursor
        )
    }

    static func mapItem(_ item: AmpCategoryItem, scope: ResourceScope) -> MediaCardModel {
        let kind: ResourceKind = switch item.type {
        case "song", "songs": .song
        case "album", "albums": .album
        case "playlist", "playlists": .playlist
        case "artist", "artists": .artist
        case "station", "stations": .station
        default: .unknown
        }
        let isLibraryItem = item.isLibrary || Self.isAppleMusicLibraryID(item.id)
        let libraryAccountID: String = if case .library(let accountID, _) = scope { accountID } else { "" }
        let itemScope: ResourceScope = isLibraryItem
            ? (scope.isLibrary ? scope : .library(accountID: libraryAccountID, region: scope.region))
            : (scope.isLibrary ? .catalog(region: scope.region) : scope)
        let identity = ResourceIdentity(
            providerID: .appleMusic,
            kind: kind,
            opaqueID: item.id,
            scope: itemScope
        )
        return MediaCardModel(
            identity: identity,
            title: item.title,
            subtitle: item.subtitle,
            artworkURL: item.artworkURL,
            isExplicit: item.track?.isExplicit ?? false,
            track: item.track
        )
    }

    static func isAppleMusicLibraryID(_ id: String) -> Bool {
        id.hasPrefix("p.") || id.hasPrefix("l.") || id.hasPrefix("i.") || id.hasPrefix("r.")
    }
}

// MARK: - AppleMusicAdapterFactory

public final class AppleMusicAdapterFactory: PlatformAdapterFactory, @unchecked Sendable {
    public static let defaultDescriptor = PlatformDescriptor(
        providerID: .appleMusic,
        displayName: "Apple Music",
        symbolName: "music.note",
        isAvailableInProduction: true,
        supportedBrowseTabs: [
            BrowseTabDescriptor(id: "home", title: "主页", symbolName: "house"),
            BrowseTabDescriptor(id: "browse", title: "浏览", symbolName: "square.grid.2x2"),
            BrowseTabDescriptor(id: "radio", title: "广播", symbolName: "dot.radiowaves.left.and.right"),
            BrowseTabDescriptor(id: "library", title: "资料库", symbolName: "music.note.list")
        ],
        capabilities: MusicProviderCapabilities(
            canBrowseCatalog: true,
            canBrowseLibrary: true,
            canSearch: true,
            canFetchLyrics: true,
            catalogSearch: .supported,
            libraryAccess: .requiresAuthorization,
            playback: .requiresAuthorization,
            lyricsAccess: .supported,
            radioStations: .supported,
            requiresAuthentication: true
        )
    )

    public let descriptor: PlatformDescriptor
    private let adapterBuilder: @Sendable () async -> AppleMusicAdapter

    public init(
        descriptor: PlatformDescriptor = AppleMusicAdapterFactory.defaultDescriptor,
        adapterBuilder: @escaping @Sendable () async -> AppleMusicAdapter
    ) {
        self.descriptor = descriptor
        self.adapterBuilder = adapterBuilder
    }

    public func makeAdapter() async -> any PlatformAdapter {
        await adapterBuilder()
    }
}
