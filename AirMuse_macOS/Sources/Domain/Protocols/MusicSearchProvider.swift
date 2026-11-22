import Foundation

// MARK: - MusicSearchProvider

/// Full-text and filtered search across a provider's catalog.
public protocol MusicSearchProvider: Sendable {
    var providerID: String { get }

    func search(query: String) async throws -> MusicSearchResult
    func search(query: String, limit: Int) async throws -> [MusicSearchResult]
    func searchTracks(query: String, limit: Int) async throws -> [MusicTrack]
    func searchAlbums(query: String, limit: Int) async throws -> [MusicAlbum]
    func searchArtists(query: String, limit: Int) async throws -> [MusicArtist]
    func searchPlaylists(query: String, limit: Int) async throws -> [MusicPlaylist]
}

extension MusicSearchProvider {
    public func search(query: String, limit: Int) async throws -> [MusicSearchResult] {
        [try await search(query: query)]
    }
    public func searchTracks(query: String, limit: Int) async throws -> [MusicTrack] {
        try await search(query: query).tracks
    }
    public func searchAlbums(query: String, limit: Int) async throws -> [MusicAlbum] {
        try await search(query: query).albums
    }
    public func searchArtists(query: String, limit: Int) async throws -> [MusicArtist] {
        try await search(query: query).artists
    }
    public func searchPlaylists(query: String, limit: Int) async throws -> [MusicPlaylist] {
        try await search(query: query).playlists
    }
}
