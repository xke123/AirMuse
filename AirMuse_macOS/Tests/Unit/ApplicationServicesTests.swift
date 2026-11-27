import Foundation
import Testing
@testable import Domain
@testable import Playback
@testable import PlatformRuntime
@testable import Application

// MARK: - FixturePlatformAdapter

final class FixtureEngineProbe: @unchecked Sendable {
    var activeCount: Int = 0
    var commandCount: Int = 0
    var createdEngineCount: Int = 0
}

actor FixturePlaybackEngine: PlaybackEngineProtocol {
    let id = UUID()
    let probe: FixtureEngineProbe
    private var continuations: [UUID: AsyncStream<EngineEvent>.Continuation] = [:]

    init(probe: FixtureEngineProbe) {
        self.probe = probe
        probe.createdEngineCount += 1
    }

    var engineInstanceID: UUID { id }

    func events() async -> AsyncStream<EngineEvent> {
        AsyncStream { continuation in
            let cid = UUID()
            continuations[cid] = continuation
        }
    }

    func prepare(sessionContext: SessionContext, deadlineSeconds: TimeInterval) async throws {}

    func execute(_ command: EngineCommand, context: PlaybackOperationContext) async throws {
        probe.commandCount += 1
        switch command {
        case .playItem, .play:
            probe.activeCount = 1
            for c in continuations.values {
                c.yield(.stateChanged(context: context, status: .playing))
            }
        case .stop:
            probe.activeCount = 0
            for c in continuations.values {
                c.yield(.stateChanged(context: context, status: .idle))
            }
        default:
            break
        }
    }

    func isolateAndReset() async {
        probe.activeCount = 0
    }
}

final class FixtureMutationProvider: MediaResourceMutationProvider, @unchecked Sendable {
    var favoritedIDs: Set<String> = []
    let providerID: ProviderID

    init(providerID: ProviderID) {
        self.providerID = providerID
    }

    func mediaActionCapabilities(for resource: MediaResourceReference) async -> MediaActionCapabilities {
        MediaActionCapabilities(isAuthenticated: true, canPlay: true, canReadLibraryMembership: true, canAddToLibrary: true, canRemoveFromLibrary: true, canReadFavorite: true, canSetFavorite: true)
    }

    func fetchResourceState(_ resource: MediaResourceReference) async throws -> MediaResourceState {
        MediaResourceState(libraryMembership: .known(false), favorite: .known(favoritedIDs.contains(resource.canonicalID)))
    }

    func addToLibrary(_ resource: MediaResourceReference) async throws -> MediaMutationReceipt {
        MediaMutationReceipt(state: MediaResourceState(libraryMembership: .known(true), favorite: .known(favoritedIDs.contains(resource.canonicalID))))
    }

    func removeFromLibrary(_ resource: MediaResourceReference) async throws -> MediaMutationReceipt {
        MediaMutationReceipt(state: MediaResourceState(libraryMembership: .known(false), favorite: .known(favoritedIDs.contains(resource.canonicalID))))
    }

    func setFavorite(_ resource: MediaResourceReference, enabled: Bool) async throws -> MediaMutationReceipt {
        if enabled { favoritedIDs.insert(resource.canonicalID) } else { favoritedIDs.remove(resource.canonicalID) }
        return MediaMutationReceipt(state: MediaResourceState(libraryMembership: .known(false), favorite: .known(enabled)))
    }
}

final class FixtureBrowseProvider: PlatformBrowseProvider, @unchecked Sendable {
    let providerID: ProviderID
    var tracksByCollection: [String: [MusicTrack]] = [:]

    init(providerID: ProviderID) {
        self.providerID = providerID
    }

    func fetchBrowsePage(route: BrowseRoute, session: SessionContext?) async throws -> BrowsePageModel {
        let item = MediaCardModel(
            identity: ResourceIdentity(providerID: providerID, kind: .album, opaqueID: "shared-id-1", scope: route.scope),
            title: "\(providerID.rawValue) Album",
            subtitle: "Fixture Artist"
        )
        return BrowsePageModel(route: route, title: providerID.rawValue, sections: [BrowseSectionModel(id: "sec-1", title: "Home", items: [item])])
    }

    func fetchSectionPage(cursor: PageCursor, session: SessionContext?) async throws -> BrowseSectionModel {
        BrowseSectionModel(id: cursor.routeFingerprint, title: "", items: [])
    }

    func fetchCollectionTracks(identity: ResourceIdentity, cursor: PageCursor?, session: SessionContext?) async throws -> CollectionTrackPage {
        CollectionTrackPage(tracks: tracksByCollection[identity.opaqueID] ?? [], nextCursor: nil, totalCount: nil)
    }

    func fetchArtistDetail(identity: ResourceIdentity, session: SessionContext?) async throws -> MusicArtistDetail {
        throw CoreError.unsupported("Not needed")
    }
}

final class FixturePlatformAdapter: PlatformAdapter, @unchecked Sendable {
    let descriptor: PlatformDescriptor
    let browseImpl: FixtureBrowseProvider
    let mutationImpl: FixtureMutationProvider
    let probe: FixtureEngineProbe

    var catalogProvider: (any MusicCatalogProvider)? { nil }
    var libraryProvider: (any MusicLibraryProvider)? { nil }
    var searchProvider: (any MusicSearchProvider)? { nil }
    var mutationProvider: (any MediaResourceMutationProvider)? { mutationImpl }
    var authProvider: (any MusicAuthenticationProvider)? { nil }
    var browseProvider: (any PlatformBrowseProvider)? { browseImpl }
    var lyricsProvider: (any MusicLyricsProvider)? { nil }

    init(providerID: ProviderID, probe: FixtureEngineProbe) {
        self.descriptor = PlatformDescriptor(
            providerID: providerID,
            displayName: "Fixture \(providerID.rawValue)",
            symbolName: "waveform",
            isAvailableInProduction: false,
            supportedBrowseTabs: [BrowseTabDescriptor(id: "home", title: "Home", symbolName: "house")],
            capabilities: MusicProviderCapabilities(canBrowseCatalog: true, canSearch: true, catalogSearch: .supported, playback: .supported)
        )
        self.browseImpl = FixtureBrowseProvider(providerID: providerID)
        self.mutationImpl = FixtureMutationProvider(providerID: providerID)
        self.probe = probe
    }

    func makePlaybackEngine() async -> (any PlaybackEngineProtocol)? {
        FixturePlaybackEngine(probe: probe)
    }
}

final class FixtureAdapterFactory: PlatformAdapterFactory, @unchecked Sendable {
    let descriptor: PlatformDescriptor
    let probe: FixtureEngineProbe
    var activationCount: Int = 0

    init(providerID: ProviderID, probe: FixtureEngineProbe) {
        self.descriptor = PlatformDescriptor(
            providerID: providerID,
            displayName: "Fixture \(providerID.rawValue)",
            symbolName: "waveform",
            isAvailableInProduction: false,
            supportedBrowseTabs: [BrowseTabDescriptor(id: "home", title: "Home", symbolName: "house")],
            capabilities: MusicProviderCapabilities(canBrowseCatalog: true, canSearch: true, catalogSearch: .supported, playback: .supported)
        )
        self.probe = probe
    }

    func makeAdapter() async -> any PlatformAdapter {
        activationCount += 1
        return FixturePlatformAdapter(providerID: descriptor.providerID, probe: probe)
    }
}

@Suite("PD04 & PD06: PlatformRuntime & Application Services Tests (R15, R18, R23–R26, R39, R45)")
struct ApplicationServicesTests {

    @Test("R23 & R24: Registering platforms creates zero adapters or engines until activated")
    func testLazyRegistrationZeroOverhead() async {
        let registry = ProviderSessionRegistry()
        let probeA = FixtureEngineProbe()
        let probeB = FixtureEngineProbe()
        let factoryA = FixtureAdapterFactory(providerID: ProviderID("fixture_a"), probe: probeA)
        let factoryB = FixtureAdapterFactory(providerID: ProviderID("fixture_b"), probe: probeB)

        await registry.register(factory: factoryA)
        await registry.register(factory: factoryB)

        #expect(factoryA.activationCount == 0)
        #expect(factoryB.activationCount == 0)
        #expect(probeA.createdEngineCount == 0)
        #expect(probeB.createdEngineCount == 0)
        #expect(await registry.registeredDescriptors(includeNonProduction: false).isEmpty)
        #expect(await registry.registeredDescriptors(includeNonProduction: true).count == 2)
    }

    @Test("R18 & R45: Browsing B while playing A routes favorite to A and origin navigation to A without audio commands")
    @MainActor
    func testIndependentBrowseFavoriteAndNavigationRouting() async throws {
        let registry = ProviderSessionRegistry()
        let probeA = FixtureEngineProbe()
        let probeB = FixtureEngineProbe()
        let factoryA = FixtureAdapterFactory(providerID: ProviderID("fixture_a"), probe: probeA)
        let factoryB = FixtureAdapterFactory(providerID: ProviderID("fixture_b"), probe: probeB)
        await registry.register(factory: factoryA)
        await registry.register(factory: factoryB)

        let store = PlaybackStore()
        let engineA = FixturePlaybackEngine(probe: probeA)
        let coordinator = PlaybackCoordinatorV2(store: store, engine: engineA)
        let intentService = PlaybackIntentService(coordinator: coordinator, registry: registry)
        let browseService = BrowseService(registry: registry)
        let actionService = MediaActionService(registry: registry)
        let navService = NavigationService(registry: registry)

        let trackA = MusicTrack(
            id: "s-1",
            title: "Track A",
            artistName: "Artist A",
            albumTitle: "Album A",
            durationMs: 180_000,
            providerID: "fixture_a",
            providerTrackID: "s-1"
        )
        let originA = PlaybackOrigin(
            kind: .album,
            sourceID: "alb-1",
            sourceTitle: "Album A",
            providerID: "fixture_a",
            scope: .catalog(region: "us")
        )
        try await intentService.submit(
            intent: .replaceAndPlay,
            tracks: [trackA],
            origin: originA,
            targetProviderID: ProviderID("fixture_a"),
            targetScope: .catalog(region: "us")
        )

        // Browse B
        await registry.setBrowsingProvider(ProviderID("fixture_b"))
        let (_, pageB) = try await browseService.fetchBrowsePage(
            route: BrowseRoute(providerID: ProviderID("fixture_b"), scope: .catalog(region: "us"), kind: .tab(id: "home"))
        )
        #expect(pageB.title == "fixture_b")
        #expect(probeB.commandCount == 0)

        // Favorite A's track while browsing B
        let refA = MediaResourceReference.from(track: trackA, origin: originA)
        let receipt = try await actionService.setFavorite(refA, enabled: true)
        #expect(receipt.state.favorite == .known(true))

        // Navigate to A's origin while browsing B -> switches browse to A, zero new audio commands
        let cmdsBeforeNav = probeA.commandCount
        let target = try await navService.resolveOriginNavigation(originA)
        #expect(target.isNavigable)
        #expect(await registry.browsingProviderID == ProviderID("fixture_a"))
        #expect(probeA.commandCount == cmdsBeforeNav)

        // R39: Cross-platform append from B into A's active queue is rejected with zero side effects
        let trackB = MusicTrack(
            id: "s-1",
            title: "Track B",
            artistName: "Artist B",
            albumTitle: "Album B",
            durationMs: 180_000,
            providerID: "fixture_b",
            providerTrackID: "s-1"
        )
        let originB = PlaybackOrigin(kind: .album, sourceID: "alb-b", providerID: "fixture_b", scope: .catalog(region: "us"))
        do {
            try await intentService.submit(
                intent: .append,
                tracks: [trackB],
                origin: originB,
                targetProviderID: ProviderID("fixture_b"),
                targetScope: .catalog(region: "us")
            )
            Issue.record("Expected cross-platform append to throw")
        } catch CoreError.unsupported {
            // Expected
        }
    }

    @Test("R16: BrowseService coalesces concurrent identical routes without false superseded")
    @MainActor
    func testBrowseServiceCoalescesIdenticalRoutes() async throws {
        let registry = ProviderSessionRegistry()
        let probe = FixtureEngineProbe()
        await registry.register(factory: FixtureAdapterFactory(providerID: ProviderID("fixture_a"), probe: probe))
        let browseService = BrowseService(registry: registry)
        let route = BrowseRoute(providerID: ProviderID("fixture_a"), scope: .catalog(region: "us"), kind: .tab(id: "browse"))

        async let p1 = browseService.fetchBrowsePage(route: route)
        async let p2 = browseService.fetchBrowsePage(route: route)
        let (r1, r2) = try await (p1, p2)
        #expect(r1.page.title == "fixture_a")
        #expect(r2.page.title == "fixture_a")
        #expect(r1.generation == r2.generation)
    }
}
