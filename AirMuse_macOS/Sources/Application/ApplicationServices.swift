import Foundation
import Domain
import Playback
import PlatformRuntime
import Infrastructure

// MARK: - BrowseService

@MainActor
public final class BrowseService {
    private let registry: ProviderSessionRegistry
    private var browseGeneration: UInt64 = 0
    private var activeRoute: BrowseRoute?
    private var inFlightTasks: [BrowseRoute: Task<BrowsePageModel, Error>] = [:]

    public init(registry: ProviderSessionRegistry) {
        self.registry = registry
    }

    public var currentGeneration: UInt64 { browseGeneration }

    public func advanceGeneration() -> UInt64 {
        browseGeneration &+= 1
        return browseGeneration
    }

    public func fetchBrowsePage(route: BrowseRoute) async throws -> (generation: UInt64, page: BrowsePageModel) {
        let expectedGen: UInt64
        if activeRoute == route {
            expectedGen = browseGeneration
        } else {
            activeRoute = route
            expectedGen = advanceGeneration()
        }

        let task: Task<BrowsePageModel, Error>
        if let existing = inFlightTasks[route] {
            task = existing
        } else {
            let registry = self.registry
            let newTask = Task<BrowsePageModel, Error> {
                let adapter = try await registry.activate(providerID: route.providerID)
                guard let browseProvider = adapter.browseProvider else {
                    throw CoreError.unsupported("Provider \(route.providerID.rawValue) does not support browsing")
                }
                let session = await registry.sessionContext(for: route.providerID)
                return try await browseProvider.fetchBrowsePage(route: route, session: session)
            }
            inFlightTasks[route] = newTask
            task = newTask
        }

        let page: BrowsePageModel
        do {
            page = try await task.value
        } catch {
            if inFlightTasks[route] == task {
                inFlightTasks.removeValue(forKey: route)
            }
            throw error
        }
        if inFlightTasks[route] == task {
            inFlightTasks.removeValue(forKey: route)
        }

        guard expectedGen == browseGeneration, activeRoute == route else {
            throw CoreError.superseded
        }
        return (expectedGen, page)
    }

    public func fetchSectionPage(cursor: PageCursor) async throws -> BrowseSectionModel {
        let adapter = try await registry.activate(providerID: cursor.providerID)
        guard let browseProvider = adapter.browseProvider else {
            throw CoreError.unsupported("Provider \(cursor.providerID.rawValue) does not support section pagination")
        }
        let session = await registry.sessionContext(for: cursor.providerID)
        return try await browseProvider.fetchSectionPage(cursor: cursor, session: session)
    }
}

// MARK: - SearchCollectionService

@MainActor
public final class SearchCollectionService {
    private let registry: ProviderSessionRegistry

    public init(registry: ProviderSessionRegistry) {
        self.registry = registry
    }

    public func search(providerID: ProviderID, scope: ResourceScope, query: String) async throws -> BrowsePageModel {
        let adapter = try await registry.activate(providerID: providerID)
        guard let browseProvider = adapter.browseProvider else {
            throw CoreError.unsupported("Provider \(providerID.rawValue) does not support search")
        }
        let session = await registry.sessionContext(for: providerID)
        let route = BrowseRoute(providerID: providerID, scope: scope, kind: .search(query: query, scope: nil))
        return try await browseProvider.fetchBrowsePage(route: route, session: session)
    }

    public func fetchCollectionTracks(identity: ResourceIdentity, cursor: PageCursor?) async throws -> CollectionTrackPage {
        let adapter = try await registry.activate(providerID: identity.providerID)
        guard let browseProvider = adapter.browseProvider else {
            throw CoreError.unsupported("Provider \(identity.providerID.rawValue) does not support collection tracks")
        }
        let session = await registry.sessionContext(for: identity.providerID)
        return try await browseProvider.fetchCollectionTracks(identity: identity, cursor: cursor, session: session)
    }

    public func fetchArtistDetail(identity: ResourceIdentity) async throws -> MusicArtistDetail {
        let adapter = try await registry.activate(providerID: identity.providerID)
        guard let browseProvider = adapter.browseProvider else {
            throw CoreError.unsupported("Provider \(identity.providerID.rawValue) does not support artist detail")
        }
        let session = await registry.sessionContext(for: identity.providerID)
        return try await browseProvider.fetchArtistDetail(identity: identity, session: session)
    }

    public func fetchArtistStation(providerID: ProviderID, artistID: String, scope: ResourceScope) async throws -> MusicStation? {
        let adapter = try await registry.activate(providerID: providerID)
        guard let browseProvider = adapter.browseProvider else {
            throw CoreError.unsupported("Provider \(providerID.rawValue) does not support artist stations")
        }
        return try await browseProvider.fetchArtistStation(artistID: artistID, scope: scope)
    }

    public func fetchSongStation(providerID: ProviderID, songID: String, scope: ResourceScope) async throws -> MusicStation? {
        let adapter = try await registry.activate(providerID: providerID)
        guard let browseProvider = adapter.browseProvider else {
            throw CoreError.unsupported("Provider \(providerID.rawValue) does not support song stations")
        }
        return try await browseProvider.fetchSongStation(songID: songID, scope: scope)
    }

    public func resolveTrackRelationships(for track: MusicTrack) async -> MusicTrack? {
        let pid = ProviderID(rawValue: track.providerID)
        guard !pid.isUnknown,
              let adapter = try? await registry.activate(providerID: pid),
              let browseProvider = adapter.browseProvider else {
            return nil
        }
        return await browseProvider.resolveTrackRelationships(for: track)
    }
}

// MARK: - PlaybackIntentService

@MainActor
public final class PlaybackIntentService {
    private let coordinator: PlaybackCoordinatorV2
    private let registry: ProviderSessionRegistry

    public init(coordinator: PlaybackCoordinatorV2, registry: ProviderSessionRegistry) {
        self.coordinator = coordinator
        self.registry = registry
    }

    /// Validates single-platform queue scope before forwarding to `PlaybackCoordinatorV2`.
    /// Cross-platform `replaceAndPlay` / `shuffleAndPlay` are allowed (via EngineRouter handoff);
    /// cross-platform `interruptAndPlay` / `prepend` / `append` are rejected with zero side effects.
    public func submit(
        intent: MediaPlayIntent,
        tracks: [MusicTrack],
        startIndex: Int = 0,
        origin: PlaybackOrigin,
        targetProviderID: ProviderID,
        targetScope: ResourceScope,
        kind: PlayableKind? = nil
    ) async throws {
        guard !targetProviderID.isUnknown, targetScope.isValid else {
            throw CoreError.unsupported("Cannot play resource with unknown provider or scope")
        }
        guard !tracks.isEmpty else {
            throw CoreError.notFound("没有可播放的曲目")
        }
        // Ensure all tracks belong to targetProviderID
        guard tracks.allSatisfy({ ProviderID(rawValue: $0.providerID) == targetProviderID }) else {
            throw CoreError.unsupported("拒绝混合不同平台的曲目进入单平台队列")
        }

        let currentSnapshot = await coordinator.currentStructuredQueueSnapshot()
        let activeProviderStr = currentSnapshot.confirmedCurrent?.track.providerID
            ?? currentSnapshot.pendingTarget?.track.providerID
            ?? currentSnapshot.upcomingEntries.first?.track.providerID
            ?? (currentSnapshot.activeTarget?.providerID.isUnknown == false ? currentSnapshot.activeTarget?.providerID.rawValue : nil)
        let activeProvider = activeProviderStr.map { ProviderID(rawValue: $0) }

        if let activeProvider, !activeProvider.isUnknown, activeProvider != targetProviderID {
            switch intent {
            case .replaceAndPlay, .shuffleAndPlay:
                break // Allowed cross-platform replacement
            case .interruptAndPlay, .prepend, .append:
                throw CoreError.unsupported("当前队列属于 \(activeProvider.rawValue)，不支持跨平台插播或追加 \(targetProviderID.rawValue)")
            }
        }

        _ = try await registry.activate(providerID: targetProviderID)
        let entries = tracks.map { QueueEntry(track: $0, origin: origin) }
        let queueIntent: QueueInsertionIntent
        let explicitShuffle: Bool?
        switch intent {
        case .replaceAndPlay:
            queueIntent = .replaceAndPlay
            explicitShuffle = false
        case .shuffleAndPlay:
            queueIntent = .replaceAndPlay
            explicitShuffle = true
        case .interruptAndPlay:
            queueIntent = .interruptAndPlay
            explicitShuffle = nil
        case .prepend:
            queueIntent = .prepend
            explicitShuffle = nil
        case .append:
            queueIntent = .append
            explicitShuffle = nil
        }
        try await coordinator.submitIntent(
            queueIntent,
            entries: entries,
            startIndex: startIndex,
            kind: kind,
            explicitShuffleMode: explicitShuffle
        )
    }
}

// MARK: - MediaActionService

@MainActor
public final class MediaActionService {
    private let registry: ProviderSessionRegistry

    public init(registry: ProviderSessionRegistry) {
        self.registry = registry
    }

    public func capabilities(for resource: MediaResourceReference) async -> MediaActionCapabilities {
        let pid = ProviderID(rawValue: resource.providerID)
        guard !pid.isUnknown else { return .playbackOnly }
        guard let adapter = try? await registry.activate(providerID: pid),
              let mutation = adapter.mutationProvider else {
            return .playbackOnly
        }
        return await mutation.mediaActionCapabilities(for: resource)
    }

    public func fetchResourceState(for resource: MediaResourceReference) async throws -> MediaResourceState {
        let pid = ProviderID(rawValue: resource.providerID)
        guard !pid.isUnknown else {
            throw CoreError.unsupported("Unknown provider for resource state")
        }
        let adapter = try await registry.activate(providerID: pid)
        guard let mutation = adapter.mutationProvider else {
            throw CoreError.unsupported("Provider \(pid.rawValue) does not support resource state")
        }
        return try await mutation.fetchResourceState(resource)
    }

    public func addToLibrary(_ resource: MediaResourceReference) async throws -> MediaMutationReceipt {
        let pid = ProviderID(rawValue: resource.providerID)
        guard !pid.isUnknown else { throw CoreError.unsupported("Unknown provider") }
        let adapter = try await registry.activate(providerID: pid)
        guard let mutation = adapter.mutationProvider else {
            throw CoreError.unsupported("Provider \(pid.rawValue) does not support library mutation")
        }
        return try await mutation.addToLibrary(resource)
    }

    public func removeFromLibrary(_ resource: MediaResourceReference) async throws -> MediaMutationReceipt {
        let pid = ProviderID(rawValue: resource.providerID)
        guard !pid.isUnknown else { throw CoreError.unsupported("Unknown provider") }
        let adapter = try await registry.activate(providerID: pid)
        guard let mutation = adapter.mutationProvider else {
            throw CoreError.unsupported("Provider \(pid.rawValue) does not support library mutation")
        }
        return try await mutation.removeFromLibrary(resource)
    }

    public func setFavorite(_ resource: MediaResourceReference, enabled: Bool) async throws -> MediaMutationReceipt {
        let pid = ProviderID(rawValue: resource.providerID)
        guard !pid.isUnknown else { throw CoreError.unsupported("Unknown provider") }
        let adapter = try await registry.activate(providerID: pid)
        guard let mutation = adapter.mutationProvider else {
            throw CoreError.unsupported("Provider \(pid.rawValue) does not support favorite mutation")
        }
        return try await mutation.setFavorite(resource, enabled: enabled)
    }
}

// MARK: - NavigationService

@MainActor
public final class NavigationService {
    private let registry: ProviderSessionRegistry

    public init(registry: ProviderSessionRegistry) {
        self.registry = registry
    }

    /// Resolves a pure internal navigation target from a `PlaybackOrigin`, switching
    /// only the browsing context (never playback/audio/queue).
    public func resolveOriginNavigation(_ origin: PlaybackOrigin) async throws -> OriginNavigationTarget {
        guard origin.canNavigate, let target = origin.resolvedNavigationTarget, target.isNavigable else {
            throw CoreError.notFound("该来源无法内部定位")
        }
        if case .resource(_, _, _, let providerIDStr) = target {
            let pid = ProviderID(rawValue: providerIDStr)
            guard !pid.isUnknown else {
                throw CoreError.unsupported("未知平台来源无法导航")
            }
            await registry.setBrowsingProvider(pid)
        }
        return target
    }
}

// MARK: - AccountService

@MainActor
public final class AccountService {
    private let registry: ProviderSessionRegistry
    private var authPresenters: [ProviderID: any PlatformAuthPresenterProtocol] = [:]

    public init(registry: ProviderSessionRegistry) {
        self.registry = registry
    }

    public func registerAuthPresenter(_ presenter: any PlatformAuthPresenterProtocol) {
        authPresenters[presenter.providerID] = presenter
    }

    public func presentAuthentication(for providerID: ProviderID) {
        authPresenters[providerID]?.presentAuthenticationWindow()
    }

    public func signOut(providerID: ProviderID) async {
        await registry.signOut(providerID: providerID)
    }

    public func sessionRecord(for providerID: ProviderID) async -> ProviderSessionRecord? {
        await registry.sessionRecord(for: providerID)
    }
}
