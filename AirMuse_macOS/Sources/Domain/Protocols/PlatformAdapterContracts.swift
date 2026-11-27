import Foundation

// MARK: - PlatformDescriptor

/// Static metadata describing a registered music platform adapter.
/// Registration stores only descriptors and lazy factories—never instantiates WebKit or network clients.
public struct PlatformDescriptor: Sendable, Hashable, Identifiable {
    public var id: ProviderID { providerID }
    public let providerID: ProviderID
    public let displayName: String
    public let symbolName: String
    public let isAvailableInProduction: Bool
    public let supportedBrowseTabs: [BrowseTabDescriptor]
    public let capabilities: MusicProviderCapabilities

    public init(
        providerID: ProviderID,
        displayName: String,
        symbolName: String,
        isAvailableInProduction: Bool,
        supportedBrowseTabs: [BrowseTabDescriptor],
        capabilities: MusicProviderCapabilities
    ) {
        self.providerID = providerID
        self.displayName = displayName
        self.symbolName = symbolName
        self.isAvailableInProduction = isAvailableInProduction
        self.supportedBrowseTabs = supportedBrowseTabs
        self.capabilities = capabilities
    }
}

// MARK: - PlatformBrowseProvider

public protocol PlatformBrowseProvider: Sendable {
    var providerID: ProviderID { get }
    func fetchBrowsePage(route: BrowseRoute, session: SessionContext?) async throws -> BrowsePageModel
    func fetchSectionPage(cursor: PageCursor, session: SessionContext?) async throws -> BrowseSectionModel
    func fetchCollectionTracks(identity: ResourceIdentity, cursor: PageCursor?, session: SessionContext?) async throws -> CollectionTrackPage
    func fetchArtistDetail(identity: ResourceIdentity, session: SessionContext?) async throws -> MusicArtistDetail
    func fetchArtistStation(artistID: String, scope: ResourceScope) async throws -> MusicStation?
    func fetchSongStation(songID: String, scope: ResourceScope) async throws -> MusicStation?
    func resolveTrackRelationships(for track: MusicTrack) async -> MusicTrack?
}

public extension PlatformBrowseProvider {
    func fetchArtistStation(artistID: String, scope: ResourceScope) async throws -> MusicStation? {
        throw MusicProviderError.unsupported
    }
    func fetchSongStation(songID: String, scope: ResourceScope) async throws -> MusicStation? {
        throw MusicProviderError.unsupported
    }
    func resolveTrackRelationships(for track: MusicTrack) async -> MusicTrack? {
        nil
    }
}

// MARK: - PlatformAdapter & Factory

/// Cohesive bundle of fine-grained capabilities exposed by a platform adapter.
public protocol PlatformAdapter: Sendable {
    var descriptor: PlatformDescriptor { get }
    var catalogProvider: (any MusicCatalogProvider)? { get }
    var libraryProvider: (any MusicLibraryProvider)? { get }
    var searchProvider: (any MusicSearchProvider)? { get }
    var mutationProvider: (any MediaResourceMutationProvider)? { get }
    var authProvider: (any MusicAuthenticationProvider)? { get }
    var browseProvider: (any PlatformBrowseProvider)? { get }
    var lyricsProvider: (any MusicLyricsProvider)? { get }

    func makePlaybackEngine() async -> (any PlaybackEngineProtocol)?
}

public protocol PlatformAdapterFactory: Sendable {
    var descriptor: PlatformDescriptor { get }
    func makeAdapter() async -> any PlatformAdapter
}

// MARK: - PlatformAuthPresenterProtocol

/// Injected by platform integration UI layers so generic UI never imports concrete adapters.
@MainActor
public protocol PlatformAuthPresenterProtocol: AnyObject {
    var providerID: ProviderID { get }
    func presentAuthenticationWindow()
    func closeAuthenticationWindow()
}

// MARK: - PlaybackEngineRouterProtocol

/// Domain-level engine router contract so Playback never imports concrete EngineRouter or adapters.
public protocol PlaybackEngineRouterProtocol: PlaybackEngineProtocol {
    func prepareCandidate(
        target: PlaybackTarget,
        sessionContext: SessionContext,
        deadlineSeconds: TimeInterval
    ) async throws -> UUID

    func activateCandidate(
        candidateEngineID: UUID,
        quiesceTimeoutSeconds: TimeInterval
    ) async throws

    func quiesceActiveEngine(timeoutSeconds: TimeInterval) async throws
}
