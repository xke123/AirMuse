import Foundation

// MARK: - MusicAlbum

public struct MusicAlbum: Sendable, Identifiable, Hashable, Codable {
    public let id: String
    public var title: String
    public var artistName: String
    public var artworkURL: URL?
    public var trackCount: Int
    public var releaseDate: Date?
    public var genreNames: [String]
    public var isExplicit: Bool
    public var providerID: String
    public var providerAlbumID: String

    public init(
        id: String,
        title: String,
        artistName: String,
        artworkURL: URL? = nil,
        trackCount: Int = 0,
        releaseDate: Date? = nil,
        genreNames: [String] = [],
        isExplicit: Bool = false,
        providerID: String,
        providerAlbumID: String
    ) {
        self.id = id
        self.title = title
        self.artistName = artistName
        self.artworkURL = artworkURL
        self.trackCount = trackCount
        self.releaseDate = releaseDate
        self.genreNames = genreNames
        self.isExplicit = isExplicit
        self.providerID = providerID
        self.providerAlbumID = providerAlbumID
    }

    public init(
        id: String,
        title: String,
        artistName: String,
        artworkURL: URL? = nil,
        releaseYear: Int? = nil,
        trackCount: Int? = nil,
        source: MusicSource = .unknown
    ) {
        self.id = id
        self.title = title
        self.artistName = artistName
        self.artworkURL = artworkURL
        self.trackCount = trackCount ?? 0
        if let y = releaseYear {
            var comps = DateComponents()
            comps.year = y
            self.releaseDate = Calendar.current.date(from: comps)
        } else {
            self.releaseDate = nil
        }
        self.genreNames = []
        self.isExplicit = false
        self.providerID = source.rawValue
        self.providerAlbumID = id
    }
}
