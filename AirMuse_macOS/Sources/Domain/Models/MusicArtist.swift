import Foundation

// MARK: - MusicArtist

public struct MusicArtist: Sendable, Identifiable, Hashable, Codable {
    public let id: String
    public var name: String
    public var artworkURL: URL?
    public var genreNames: [String]
    public var providerID: String
    public var providerArtistID: String

    public init(
        id: String,
        name: String,
        artworkURL: URL? = nil,
        genreNames: [String] = [],
        providerID: String,
        providerArtistID: String
    ) {
        self.id = id
        self.name = name
        self.artworkURL = artworkURL
        self.genreNames = genreNames
        self.providerID = providerID
        self.providerArtistID = providerArtistID
    }

    public init(
        id: String,
        name: String,
        artworkURL: URL? = nil,
        source: MusicSource = .unknown
    ) {
        self.id = id
        self.name = name
        self.artworkURL = artworkURL
        self.genreNames = []
        self.providerID = source.rawValue
        self.providerArtistID = id
    }
}
