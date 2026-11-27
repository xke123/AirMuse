import Foundation

// MARK: - MusicPlaylist

public struct MusicPlaylist: Sendable, Identifiable, Hashable, Codable {
    public let id: String
    public var name: String
    public var description: String
    public var artworkURL: URL?
    public var trackIDs: [String]        // ordered track identifiers
    public var isEditable: Bool
    public var ownerName: String?
    public var providerID: String
    public var providerPlaylistID: String
    public var ownership: PlaylistOwnership
    public var catalogID: String?

    public var trackCount: Int {
        trackIDs.count
    }

    public init(
        id: String,
        name: String,
        description: String = "",
        artworkURL: URL? = nil,
        trackIDs: [String] = [],
        isEditable: Bool = false,
        ownerName: String? = nil,
        providerID: String,
        providerPlaylistID: String,
        ownership: PlaylistOwnership = .unknown,
        catalogID: String? = nil
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.artworkURL = artworkURL
        self.trackIDs = trackIDs
        self.isEditable = isEditable
        self.ownerName = ownerName
        self.providerID = providerID
        self.providerPlaylistID = providerPlaylistID
        self.ownership = ownership
        self.catalogID = catalogID
    }

    enum CodingKeys: String, CodingKey {
        case id, name, description, artworkURL, trackIDs, isEditable, ownerName, providerID, providerPlaylistID, ownership, catalogID
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        description = try c.decode(String.self, forKey: .description)
        artworkURL = try c.decodeIfPresent(URL.self, forKey: .artworkURL)
        trackIDs = try c.decodeIfPresent([String].self, forKey: .trackIDs) ?? []
        isEditable = try c.decodeIfPresent(Bool.self, forKey: .isEditable) ?? false
        ownerName = try c.decodeIfPresent(String.self, forKey: .ownerName)
        providerID = try c.decode(String.self, forKey: .providerID)
        providerPlaylistID = try c.decode(String.self, forKey: .providerPlaylistID)
        ownership = try c.decodeIfPresent(PlaylistOwnership.self, forKey: .ownership) ?? .unknown
        catalogID = try c.decodeIfPresent(String.self, forKey: .catalogID)
    }
}
