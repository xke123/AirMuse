import Foundation

// MARK: - ProviderCapability

public enum ProviderCapability: String, Sendable, Codable, Hashable {
    case supported
    case requiresSubscription
    case requiresAuthorization
    case unsupported
}

// MARK: - MusicProviderCapabilities

/// Declares what a music provider can and cannot do.
public struct MusicProviderCapabilities: Sendable, Codable, Hashable {
    // Playback flags
    public var canPlay: Bool
    public var canPause: Bool
    public var canStop: Bool
    public var canSeek: Bool
    public var canSetVolume: Bool
    public var canSkipNext: Bool
    public var canSkipPrevious: Bool

    // Queue / Library flags
    public var canBrowseCatalog: Bool
    public var canBrowseLibrary: Bool
    public var canSearch: Bool
    public var canFetchLyrics: Bool
    public var canEditPlaylists: Bool

    // Tristate capabilities
    public var catalogSearch: ProviderCapability
    public var libraryAccess: ProviderCapability
    public var playback: ProviderCapability
    public var lyricsAccess: ProviderCapability
    public var radioStations: ProviderCapability

    // Auth
    public var requiresAuthentication: Bool

    public init(
        canPlay: Bool = true,
        canPause: Bool = true,
        canStop: Bool = true,
        canSeek: Bool = true,
        canSetVolume: Bool = true,
        canSkipNext: Bool = true,
        canSkipPrevious: Bool = true,
        canBrowseCatalog: Bool = false,
        canBrowseLibrary: Bool = false,
        canSearch: Bool = false,
        canFetchLyrics: Bool = false,
        canEditPlaylists: Bool = false,
        catalogSearch: ProviderCapability = .unsupported,
        libraryAccess: ProviderCapability = .unsupported,
        playback: ProviderCapability = .supported,
        lyricsAccess: ProviderCapability = .unsupported,
        radioStations: ProviderCapability = .unsupported,
        requiresAuthentication: Bool = false
    ) {
        self.canPlay = canPlay
        self.canPause = canPause
        self.canStop = canStop
        self.canSeek = canSeek
        self.canSetVolume = canSetVolume
        self.canSkipNext = canSkipNext
        self.canSkipPrevious = canSkipPrevious
        self.canBrowseCatalog = canBrowseCatalog
        self.canBrowseLibrary = canBrowseLibrary
        self.canSearch = canSearch
        self.canFetchLyrics = canFetchLyrics
        self.canEditPlaylists = canEditPlaylists
        self.catalogSearch = catalogSearch
        self.libraryAccess = libraryAccess
        self.playback = playback
        self.lyricsAccess = lyricsAccess
        self.radioStations = radioStations
        self.requiresAuthentication = requiresAuthentication
    }
}
