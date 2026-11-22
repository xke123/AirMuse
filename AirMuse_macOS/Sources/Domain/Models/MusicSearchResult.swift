import Foundation

// MARK: - MusicSearchResult

/// Unified container for search query results across catalog types.
public struct MusicSearchResult: Sendable, Codable {
    public var tracks: [MusicTrack]
    public var albums: [MusicAlbum]
    public var artists: [MusicArtist]
    public var playlists: [MusicPlaylist]

    public init(
        tracks: [MusicTrack] = [],
        albums: [MusicAlbum] = [],
        artists: [MusicArtist] = [],
        playlists: [MusicPlaylist] = []
    ) {
        self.tracks = tracks
        self.albums = albums
        self.artists = artists
        self.playlists = playlists
    }

    public var isEmpty: Bool {
        tracks.isEmpty && albums.isEmpty && artists.isEmpty && playlists.isEmpty
    }
}

// MARK: - MusicSearchItem

/// An individual search item for unified list presentations.
public enum MusicSearchItem: Sendable, Identifiable {
    case track(MusicTrack)
    case album(MusicAlbum)
    case artist(MusicArtist)
    case playlist(MusicPlaylist)

    public var id: String {
        switch self {
        case .track(let t):   return "track:\(t.id)"
        case .album(let a):   return "album:\(a.id)"
        case .artist(let a):  return "artist:\(a.id)"
        case .playlist(let p): return "playlist:\(p.id)"
        }
    }

    public var displayTitle: String {
        switch self {
        case .track(let t):   return t.title
        case .album(let a):   return a.title
        case .artist(let a):  return a.name
        case .playlist(let p): return p.name
        }
    }

    public var displaySubtitle: String {
        switch self {
        case .track(let t):    return t.artistName
        case .album(let a):    return a.artistName
        case .artist:          return "Artist"
        case .playlist(let p): return p.ownerName ?? ""
        }
    }
}
