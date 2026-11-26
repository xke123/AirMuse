import Foundation

// MARK: - ArtistViewKind

/// Normalized section keys for Apple Music artist detail views.
public enum ArtistViewKind: String, Sendable, Codable, Hashable {
    case topSongs = "top-songs"
    case latestRelease = "latest-release"
    case fullAlbums = "full-albums"
    case singles = "singles"
    case liveAlbums = "live-albums"
    case compilationAlbums = "compilation-albums"
    case featuredPlaylists = "featured-playlists"
    case similarArtists = "similar-artists"
    case unknown = "unknown"

    public init(viewKey: String) {
        self = ArtistViewKind(rawValue: viewKey) ?? .unknown
    }

    public var displayTitle: String {
        switch self {
        case .topSongs:          return "热门歌曲"
        case .latestRelease:     return "最新发布"
        case .fullAlbums:        return "专辑"
        case .singles:           return "单曲与 EP"
        case .liveAlbums:        return "现场专辑"
        case .compilationAlbums: return "合辑"
        case .featuredPlaylists: return "精选歌单"
        case .similarArtists:    return "相似艺人"
        case .unknown:           return "更多"
        }
    }
}

// MARK: - ArtistViewSection

/// A single dynamic section on an artist detail page.
public struct ArtistViewSection: Sendable, Codable, Identifiable {
    public let id: String
    public let kind: ArtistViewKind
    public let title: String
    public var items: [MusicSearchItem]
    public var nextURL: String?

    public init(
        id: String,
        kind: ArtistViewKind,
        title: String? = nil,
        items: [MusicSearchItem] = [],
        nextURL: String? = nil
    ) {
        self.id = id
        self.kind = kind
        self.title = (title?.isEmpty == false) ? title! : kind.displayTitle
        self.items = items
        self.nextURL = nextURL
    }
}

// MARK: - MusicArtistDetail

/// Complete artist detail payload including bio, genres, favorite/dislike state, and dynamic views.
public struct MusicArtistDetail: Sendable, Codable {
    public let artist: MusicArtist
    public let editorialNotes: String?
    public let genreNames: [String]
    public var isFavorited: Bool
    public var isSuggestLess: Bool
    public var views: [ArtistViewSection]

    public init(
        artist: MusicArtist,
        editorialNotes: String? = nil,
        genreNames: [String] = [],
        isFavorited: Bool = false,
        isSuggestLess: Bool = false,
        views: [ArtistViewSection] = []
    ) {
        self.artist = artist
        self.editorialNotes = editorialNotes
        self.genreNames = genreNames
        self.isFavorited = isFavorited
        self.isSuggestLess = isSuggestLess
        self.views = views
    }
}
