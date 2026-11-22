import Foundation

// MARK: - MusicLibraryProvider

/// Access to the user's saved music library.
public protocol MusicLibraryProvider: Sendable {
    var providerID: String { get }

    func fetchLibrary() async throws -> MusicLibrary
    func fetchLibraryTracks() async throws -> [MusicTrack]
    func fetchLibraryAlbums() async throws -> [MusicAlbum]
    func fetchLibraryArtists() async throws -> [MusicArtist]
    func fetchLibraryPlaylists() async throws -> [MusicPlaylist]
    func addTrackToLibrary(trackID: String) async throws
    func removeTrackFromLibrary(trackID: String) async throws
    func isTrackInLibrary(trackID: String) async throws -> Bool
}

extension MusicLibraryProvider {
    public func fetchLibraryTracks() async throws -> [MusicTrack] { try await fetchLibrary().tracks }
    public func fetchLibraryAlbums() async throws -> [MusicAlbum] { try await fetchLibrary().albums }
    public func fetchLibraryArtists() async throws -> [MusicArtist] { try await fetchLibrary().artists }
    public func fetchLibraryPlaylists() async throws -> [MusicPlaylist] { try await fetchLibrary().playlists }
    public func addTrackToLibrary(trackID: String) async throws {}
    public func removeTrackFromLibrary(trackID: String) async throws {}
    public func isTrackInLibrary(trackID: String) async throws -> Bool { false }
}
