import Foundation

// MARK: - MusicLyricsProvider

/// Fetches and caches timed lyrics for a track.
public protocol MusicLyricsProvider: Sendable {
    var providerID: String { get }

    /// Fetch lyrics for the given track. Returns nil if none found.
    func fetchLyrics(for track: MusicTrack) async throws -> LyricsDocument?

    /// Apply a user-defined timing offset (positive = shift later).
    func adjustOffset(trackKey: String, deltaMs: Int64) async
}

extension MusicLyricsProvider {
    public func adjustOffset(trackKey: String, deltaMs: Int64) async {}
}
