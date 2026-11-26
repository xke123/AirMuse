import Foundation

// MARK: - SearchCategoryKind

/// Normalized search result category keys returned dynamically by AMP search responses.
public enum SearchCategoryKind: String, Sendable, Codable, Hashable {
    case topResults = "top"
    case songs = "songs"
    case albums = "albums"
    case artists = "artists"
    case playlists = "playlists"
    case stations = "stations"
    case musicVideos = "music-videos"
    case curators = "curators"
    case unknown = "unknown"

    public init(ampKey: String) {
        switch ampKey {
        case "top", "topResults":
            self = .topResults
        case "songs", "library-songs":
            self = .songs
        case "albums", "library-albums":
            self = .albums
        case "artists", "library-artists":
            self = .artists
        case "playlists", "library-playlists":
            self = .playlists
        case "stations":
            self = .stations
        case "music-videos", "library-music-videos":
            self = .musicVideos
        case "curators", "apple-curators":
            self = .curators
        default:
            self = .unknown
        }
    }

    public var displayTitle: String {
        switch self {
        case .topResults:  return "最佳结果"
        case .songs:       return "歌曲"
        case .albums:      return "专辑"
        case .artists:     return "艺人"
        case .playlists:   return "播放列表"
        case .stations:    return "广播单集"
        case .musicVideos: return "音乐视频"
        case .curators:    return "类别"
        case .unknown:     return "其他"
        }
    }
}

// MARK: - SearchSection

/// Dynamic search result section ordered by API response metadata, with per-section pagination cursor.
public struct SearchSection: Sendable, Codable, Identifiable {
    public let id: String
    public let kind: SearchCategoryKind
    public let title: String
    public var items: [MusicSearchItem]
    public var nextURL: String?

    public init(
        id: String,
        kind: SearchCategoryKind,
        title: String? = nil,
        items: [MusicSearchItem] = [],
        nextURL: String? = nil
    ) {
        self.id = id
        self.kind = kind
        self.title = title ?? kind.displayTitle
        self.items = items
        self.nextURL = nextURL
    }
}

// MARK: - MusicSearchResult

/// Unified container for search query results across catalog types.
public struct MusicSearchResult: Sendable, Codable {
    public var tracks: [MusicTrack]
    public var albums: [MusicAlbum]
    public var artists: [MusicArtist]
    public var playlists: [MusicPlaylist]
    public var stations: [MusicStation]
    public var sections: [SearchSection]

    public init(
        tracks: [MusicTrack] = [],
        albums: [MusicAlbum] = [],
        artists: [MusicArtist] = [],
        playlists: [MusicPlaylist] = [],
        stations: [MusicStation] = [],
        sections: [SearchSection] = []
    ) {
        self.tracks = tracks
        self.albums = albums
        self.artists = artists
        self.playlists = playlists
        self.stations = stations
        self.sections = sections
    }

    public var isEmpty: Bool {
        tracks.isEmpty && albums.isEmpty && artists.isEmpty && playlists.isEmpty && stations.isEmpty && sections.isEmpty
    }
}

// MARK: - MusicSearchItem

/// An individual search item for unified list presentations.
public enum MusicSearchItem: Sendable, Codable, Identifiable {
    case track(MusicTrack)
    case album(MusicAlbum)
    case artist(MusicArtist)
    case playlist(MusicPlaylist)
    case station(MusicStation)
    case musicVideo(MusicTrack)
    case curator(id: String, name: String, subtitle: String?, artworkURL: URL?)

    public var id: String {
        switch self {
        case .track(let t):            return "track:\(t.id)"
        case .album(let a):            return "album:\(a.id)"
        case .artist(let a):           return "artist:\(a.id)"
        case .playlist(let p):         return "playlist:\(p.id)"
        case .station(let s):          return "station:\(s.id)"
        case .musicVideo(let v):       return "mv:\(v.id)"
        case .curator(let id, _, _, _): return "curator:\(id)"
        }
    }

    public var displayTitle: String {
        switch self {
        case .track(let t):              return t.title
        case .album(let a):              return a.title
        case .artist(let a):             return a.name
        case .playlist(let p):           return p.name
        case .station(let s):            return s.name
        case .musicVideo(let v):         return v.title
        case .curator(_, let name, _, _): return name
        }
    }

    public var displaySubtitle: String {
        switch self {
        case .track(let t):               return t.artistName
        case .album(let a):               return a.artistName
        case .artist:                     return "艺人"
        case .playlist(let p):            return p.ownerName ?? "播放列表"
        case .station(let s):             return s.description.isEmpty ? "广播单集" : s.description
        case .musicVideo(let v):          return v.artistName
        case .curator(_, _, let sub, _):  return sub ?? "类别"
        }
    }
}
