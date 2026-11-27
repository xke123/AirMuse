import Foundation

// MARK: - MusicCatalogProvider

/// Provides catalog browsing: albums, artists, featured content.
public protocol MusicCatalogProvider: Sendable {
    var providerID: String { get }

    func searchCatalog(query: String, limit: Int) async throws -> MusicSearchResult
    func fetchAlbum(id: String) async throws -> MusicAlbum
    func fetchArtist(id: String) async throws -> MusicArtist
    func fetchAlbumTracks(albumID: String) async throws -> [MusicTrack]
    func fetchArtistAlbums(artistID: String) async throws -> [MusicAlbum]
    func fetchFeaturedPlaylists() async throws -> [MusicPlaylist]
    func fetchNewReleases() async throws -> [MusicAlbum]
    func fetchTopCharts(genre: String?) async throws -> [MusicTrack]
}

extension MusicCatalogProvider {
    public func fetchAlbum(id: String) async throws -> MusicAlbum { throw MusicProviderError.unsupported }
    public func fetchArtist(id: String) async throws -> MusicArtist { throw MusicProviderError.unsupported }
    public func fetchAlbumTracks(albumID: String) async throws -> [MusicTrack] { throw MusicProviderError.unsupported }
    public func fetchArtistAlbums(artistID: String) async throws -> [MusicAlbum] { throw MusicProviderError.unsupported }
    public func fetchFeaturedPlaylists() async throws -> [MusicPlaylist] { throw MusicProviderError.unsupported }
    public func fetchNewReleases() async throws -> [MusicAlbum] { throw MusicProviderError.unsupported }
    public func fetchTopCharts(genre: String?) async throws -> [MusicTrack] { throw MusicProviderError.unsupported }
}
