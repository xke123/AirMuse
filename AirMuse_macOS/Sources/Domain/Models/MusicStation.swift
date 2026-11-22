import Foundation

// MARK: - MusicStation

/// A radio / algorithmic station (e.g. Apple Music Radio, Spotify Radio).
public struct MusicStation: Sendable, Identifiable, Hashable, Codable {
    public let id: String
    public var name: String
    public var description: String
    public var artworkURL: URL?
    public var stationURL: URL?
    public var isLive: Bool              // live broadcast (no seek)
    public var providerID: String
    public var providerStationID: String

    public init(
        id: String,
        name: String,
        description: String = "",
        artworkURL: URL? = nil,
        stationURL: URL? = nil,
        isLive: Bool = false,
        providerID: String,
        providerStationID: String
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.artworkURL = artworkURL
        self.stationURL = stationURL
        self.isLive = isLive
        self.providerID = providerID
        self.providerStationID = providerStationID
    }
}
