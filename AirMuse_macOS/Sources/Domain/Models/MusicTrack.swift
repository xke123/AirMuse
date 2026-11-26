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
    public var isExplicit: Bool
    public var trackNumber: Int?
    public var discNumber: Int?
    public var genreNames: [String]
    public var releaseDate: Date?
    public var providerID: String          // which provider owns this track
    public var providerTrackID: String     // provider-specific identifier
    public var albumID: String?
    public var artists: [MediaArtistRef]

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
        isExplicit: Bool = false,
        trackNumber: Int? = nil,
        discNumber: Int? = nil,
        genreNames: [String] = [],
        releaseDate: Date? = nil,
        providerID: String,
        providerTrackID: String,
        albumID: String? = nil,
        artists: [MediaArtistRef] = []
    ) {
        self.id = id
        self.title = title
        self.artistName = artistName
        self.albumTitle = albumTitle
        self.durationMs = durationMs
        self.artworkURL = artworkURL
        self.isExplicit = isExplicit
        self.trackNumber = trackNumber
        self.discNumber = discNumber
        self.genreNames = genreNames
        self.releaseDate = releaseDate
        self.providerID = providerID
        self.providerTrackID = providerTrackID
        self.albumID = albumID
        self.artists = artists
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
        self.isExplicit = isExplicit
        self.trackNumber = nil
        self.discNumber = nil
        self.genreNames = []
        self.releaseDate = nil
        self.providerID = source.rawValue
        self.providerTrackID = id
        self.albumID = nil
        self.artists = []
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
        self.isExplicit = false
        self.trackNumber = nil
        self.discNumber = nil
        self.genreNames = []
        self.releaseDate = nil
        self.providerID = source.rawValue
        self.providerTrackID = id.isEmpty ? "\(title)|\(artist)" : id
        self.albumID = nil
        self.artists = []
        self._accountID = accountID
    }

    enum CodingKeys: String, CodingKey {
        case id, title, artistName, albumTitle, durationMs, artworkURL, isExplicit
        case trackNumber, discNumber, genreNames, releaseDate, providerID, providerTrackID
        case albumID, artists, _accountID
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        artistName = try c.decode(String.self, forKey: .artistName)
        albumTitle = try c.decode(String.self, forKey: .albumTitle)
        durationMs = try c.decode(Int64.self, forKey: .durationMs)
        artworkURL = try c.decodeIfPresent(URL.self, forKey: .artworkURL)
        isExplicit = try c.decode(Bool.self, forKey: .isExplicit)
        trackNumber = try c.decodeIfPresent(Int.self, forKey: .trackNumber)
        discNumber = try c.decodeIfPresent(Int.self, forKey: .discNumber)
        genreNames = try c.decodeIfPresent([String].self, forKey: .genreNames) ?? []
        releaseDate = try c.decodeIfPresent(Date.self, forKey: .releaseDate)
        providerID = try c.decode(String.self, forKey: .providerID)
        providerTrackID = try c.decode(String.self, forKey: .providerTrackID)
        albumID = try c.decodeIfPresent(String.self, forKey: .albumID)
        artists = try c.decodeIfPresent([MediaArtistRef].self, forKey: .artists) ?? []
        _accountID = try c.decodeIfPresent(String.self, forKey: ._accountID) ?? ""
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
