import Foundation

// MARK: - MusicTrack

/// Represents a single audio track from any provider.
public struct MusicTrack: Sendable, Identifiable, Hashable, Codable {
    public let id: String
    public var title: String
    public var artistName: String
    public var albumTitle: String
    public var durationMs: Int64
    public var artworkURL: URL?
    public var previewURL: URL?
    public var isExplicit: Bool
    public var trackNumber: Int?
    public var discNumber: Int?
    public var genreNames: [String]
    public var releaseDate: Date?
    public var providerID: String          // which provider owns this track
    public var providerTrackID: String     // provider-specific identifier

    public var durationSeconds: Double {
        Double(durationMs) / 1000.0
    }

    public init(
        id: String,
        title: String,
        artistName: String,
        albumTitle: String,
        durationMs: Int64,
        artworkURL: URL? = nil,
        previewURL: URL? = nil,
        isExplicit: Bool = false,
        trackNumber: Int? = nil,
        discNumber: Int? = nil,
        genreNames: [String] = [],
        releaseDate: Date? = nil,
        providerID: String,
        providerTrackID: String
    ) {
        self.id = id
        self.title = title
        self.artistName = artistName
        self.albumTitle = albumTitle
        self.durationMs = durationMs
        self.artworkURL = artworkURL
        self.previewURL = previewURL
        self.isExplicit = isExplicit
        self.trackNumber = trackNumber
        self.discNumber = discNumber
        self.genreNames = genreNames
        self.releaseDate = releaseDate
        self.providerID = providerID
        self.providerTrackID = providerTrackID
    }

    public init(
        id: String,
        title: String,
        artistName: String,
        albumTitle: String? = nil,
        durationSeconds: Double? = nil,
        artworkURL: URL? = nil,
        source: MusicSource = .unknown,
        isExplicit: Bool = false
    ) {
        self.id = id
        self.title = title
        self.artistName = artistName
        self.albumTitle = albumTitle ?? ""
        self.durationMs = Int64((durationSeconds ?? 0) * 1000)
        self.artworkURL = artworkURL
        self.previewURL = nil
        self.isExplicit = isExplicit
        self.trackNumber = nil
        self.discNumber = nil
        self.genreNames = []
        self.releaseDate = nil
        self.providerID = source.rawValue
        self.providerTrackID = id
    }

    /// Convenience init used in tests with accountID-scoped cache keys.
    public init(
        id: String,
        title: String,
        artist: String,
        album: String = "",
        source: MusicSource = .unknown,
        accountID: String = ""
    ) {
        self.id = id
        self.title = title
        self.artistName = artist
        self.albumTitle = album
        self.durationMs = 0
        self.artworkURL = nil
        self.previewURL = nil
        self.isExplicit = false
        self.trackNumber = nil
        self.discNumber = nil
        self.genreNames = []
        self.releaseDate = nil
        self.providerID = source.rawValue
        self.providerTrackID = id.isEmpty ? "\(title)|\(artist)" : id
        self._accountID = accountID
    }

    private var _accountID: String = ""

    /// Stable key for lyrics / artwork caching; account-scoped to prevent cross-account bleed.
    public var trackKey: String {
        let acct = _accountID.isEmpty ? "" : "|\(_accountID)"
        let pid = providerID.isEmpty ? "unknown" : providerID
        let rid = providerTrackID.isEmpty ? "\(title)|\(artistName)" : providerTrackID
        return "\(pid)|\(rid)\(acct)"
    }
}
