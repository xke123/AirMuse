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
        providerPlaylistID: String
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
    }
}
