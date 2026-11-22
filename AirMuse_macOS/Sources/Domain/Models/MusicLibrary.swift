import Foundation

// MARK: - MusicLibrary

/// Snapshot of a user's library for a specific provider.
public struct MusicLibrary: Sendable, Codable {
    public var providerID: String
    public var tracks: [MusicTrack]
    public var albums: [MusicAlbum]
    public var artists: [MusicArtist]
    public var playlists: [MusicPlaylist]
    public var lastSyncDate: Date?

    public init(
        providerID: String = "",
        tracks: [MusicTrack] = [],
        albums: [MusicAlbum] = [],
        artists: [MusicArtist] = [],
        playlists: [MusicPlaylist] = [],
        lastSyncDate: Date? = nil
    ) {
        self.providerID = providerID
        self.tracks = tracks
        self.albums = albums
        self.artists = artists
        self.playlists = playlists
        self.lastSyncDate = lastSyncDate
    }
}
