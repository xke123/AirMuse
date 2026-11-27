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

        let routeRef = route.providerID.rawValue + ":" + String(describing: route.kind)
        let span = AppLogger.shared.beginSpan(
            eventName: "browse.page.requested",
            category: "BROWSE",
            level: .info,
            context: DiagnosticContext(providerID: route.providerID.rawValue, browseGeneration: expectedGen, routeRef: routeRef),
            fields: ["scopeRef": .string(String(describing: route.scope)), "routeKind": .string(String(describing: route.kind))],
            source: DiagnosticSourceLocation(module: "Application", component: "BrowseService", function: "fetchBrowsePage"),
            message: "Browse page requested (\(route.providerID.rawValue))"
        )

        let task: Task<BrowsePageModel, Error>
        if let existing = inFlightTasks[route] {
            task = existing
        } else {
            let registry = self.registry
            let capturedTrace = span.traceContext
            let newTask = Task<BrowsePageModel, Error> {
                try await DiagnosticTrace.withContext(capturedTrace) {
                    let adapter = try await registry.activate(providerID: route.providerID)
                    guard let browseProvider = adapter.browseProvider else {
                        throw CoreError.unsupported("Provider \(route.providerID.rawValue) does not support browsing")
                    }
                    let session = await registry.sessionContext(for: route.providerID)
                    return try await browseProvider.fetchBrowsePage(route: route, session: session)
                }
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
            let outcome: DiagnosticOutcome = (error is CancellationError || (error as? CoreError) == .cancelled) ? .cancelled : .failed
            AppLogger.shared.endSpan(
                span,
                endEventName: outcome == .cancelled ? "browse.page.cancelled" : "browse.page.loaded",
                outcome: outcome,
                error: LogSanitizer.sanitizeError(error, stage: "browse"),
                message: "Browse page \(outcome.rawValue)"
            )
            throw error
        }
        if inFlightTasks[route] == task {
            inFlightTasks.removeValue(forKey: route)
        }

        guard expectedGen == browseGeneration, activeRoute == route else {
            AppLogger.shared.endSpan(
                span,
                endEventName: "browse.page.discarded",
                outcome: .discarded,
                fields: ["expectedGeneration": .uint64(expectedGen), "actualGeneration": .uint64(browseGeneration)],
                message: "Discarded stale browse page (expectedGen=\(expectedGen), actual=\(browseGeneration))"
            )
            throw CoreError.superseded
        }
        let itemCount = page.sections.reduce(0) { $0 + $1.items.count }
        AppLogger.shared.endSpan(
            span,
            endEventName: "browse.page.loaded",
            outcome: .succeeded,
            fields: ["sectionCount": .int(page.sections.count), "itemCount": .int(itemCount)],
            message: "Browse page loaded (sections=\(page.sections.count), items=\(itemCount))"
        )
        return (expectedGen, page)
    }

    public func fetchSectionPage(cursor: PageCursor) async throws -> BrowseSectionModel {
        let adapter = try await registry.activate(providerID: cursor.providerID)
        guard let browseProvider = adapter.browseProvider else {
            throw CoreError.unsupported("Provider \(cursor.providerID.rawValue) does not support section pagination")
        }
        let session = await registry.sessionContext(for: cursor.providerID)
        let section = try await browseProvider.fetchSectionPage(cursor: cursor, session: session)
        AppLogger.shared.emit(
            eventName: "browse.section.page.completed",
            category: "BROWSE",
            level: .info,
            outcome: .succeeded,
            source: DiagnosticSourceLocation(module: "Application", component: "BrowseService", function: "fetchSectionPage"),
            payload: {
                DiagnosticEventPayload(
                    context: DiagnosticContext(providerID: cursor.providerID.rawValue),
                    fields: [
                        "cursorRef": .string(AppLogger.shared.hasher.reference(for: cursor.opaqueToken, prefix: "cur")),
                        "itemCount": .int(section.items.count),
                        "hasNext": .bool(section.nextCursor != nil)
                    ],
                    message: "Section page loaded (items=\(section.items.count))"
                )
            }
        )
        return section
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
        let span = AppLogger.shared.beginSpan(
            eventName: "search.requested",
            category: "BROWSE",
            level: .info,
            context: DiagnosticContext(providerID: providerID.rawValue, scopeRef: String(describing: scope)),
            fields: ["queryRef": .string(AppLogger.shared.hasher.reference(for: query, prefix: "qry"))],
            source: DiagnosticSourceLocation(module: "Application", component: "SearchCollectionService", function: "search"),
            message: "Search requested on \(providerID.rawValue)"
        )
        do {
            let adapter = try await registry.activate(providerID: providerID)
            guard let browseProvider = adapter.browseProvider else {
                throw CoreError.unsupported("Provider \(providerID.rawValue) does not support search")
            }
            let session = await registry.sessionContext(for: providerID)
            let route = BrowseRoute(providerID: providerID, scope: scope, kind: .search(query: query, scope: nil))
            let page = try await DiagnosticTrace.withContext(span.traceContext) {
                try await browseProvider.fetchBrowsePage(route: route, session: session)
            }
            let itemCount = page.sections.reduce(0) { $0 + $1.items.count }
            AppLogger.shared.endSpan(span, endEventName: "search.completed", outcome: .succeeded, fields: ["itemCount": .int(itemCount)], message: "Search completed (items=\(itemCount))")
            return page
        } catch {
            AppLogger.shared.endSpan(span, endEventName: "search.completed", outcome: .failed, error: LogSanitizer.sanitizeError(error, stage: "search"), message: "Search failed")
            throw error
        }
    }

    public func fetchCollectionTracks(identity: ResourceIdentity, cursor: PageCursor?) async throws -> CollectionTrackPage {
        let span = AppLogger.shared.beginSpan(
            eventName: "collection.detail.requested",
            category: "BROWSE",
            level: .info,
            context: DiagnosticContext(providerID: identity.providerID.rawValue, resourceRef: identity.opaqueID, resourceKind: identity.kind.rawValue),
            source: DiagnosticSourceLocation(module: "Application", component: "SearchCollectionService", function: "fetchCollectionTracks"),
            message: "Collection detail requested"
        )
        do {
            let adapter = try await registry.activate(providerID: identity.providerID)
            guard let browseProvider = adapter.browseProvider else {
                throw CoreError.unsupported("Provider \(identity.providerID.rawValue) does not support collection tracks")
            }
            let session = await registry.sessionContext(for: identity.providerID)
            let page = try await DiagnosticTrace.withContext(span.traceContext) {
                try await browseProvider.fetchCollectionTracks(identity: identity, cursor: cursor, session: session)
            }
            AppLogger.shared.endSpan(
                span,
                endEventName: "collection.detail.loaded",
                outcome: .succeeded,
                fields: ["itemCount": .int(page.tracks.count), "totalCount": page.totalCount.map { .int($0) } ?? .absent, "hasNext": .bool(page.nextCursor != nil)],
                message: "Collection detail loaded (tracks=\(page.tracks.count))"
            )
            return page
        } catch {
            AppLogger.shared.endSpan(span, endEventName: "collection.detail.failed", outcome: .failed, error: LogSanitizer.sanitizeError(error, stage: "collection"), message: "Collection detail failed")
            throw error
        }
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
        let intentID = UUID()
        let browsingPID = await registry.browsingProviderID
        let trace = DiagnosticTrace.currentOrRoot(
            context: DiagnosticContext(
                browsingProviderID: browsingPID?.rawValue,
                operationProviderID: targetProviderID.rawValue,
                intentID: intentID,
                scopeRef: String(describing: targetScope)
            )
        )
        AppLogger.shared.emit(
            eventName: "playback.intent.created",
            category: "PLAYBACK",
            level: .info,
            phase: .begin,
            traceContext: trace,
            source: DiagnosticSourceLocation(module: "Application", component: "PlaybackIntentService", function: "submit"),
            payload: {
                DiagnosticEventPayload(
                    fields: [
                        "intentKind": .string(String(describing: intent)),
                        "entryCount": .int(tracks.count),
                        "startIndex": .int(startIndex)
                    ],
                    message: "Playback intent created (\(intent), tracks=\(tracks.count))"
                )
            }
        )

        guard !targetProviderID.isUnknown, targetScope.isValid else {
            AppLogger.shared.emit(
                eventName: "playback.intent.rejected",
                category: "PLAYBACK",
                level: .warn,
                phase: .end,
                outcome: .rejected,
                traceContext: trace,
                source: DiagnosticSourceLocation(module: "Application", component: "PlaybackIntentService", function: "submit"),
                payload: { DiagnosticEventPayload(fields: ["reasonCode": .string("invalid_provider_or_scope")], message: "Rejected playback intent: invalid provider or scope") }
            )
            throw CoreError.unsupported("Cannot play resource with unknown provider or scope")
        }
        guard !tracks.isEmpty else {
            AppLogger.shared.emit(
                eventName: "playback.intent.rejected",
                category: "PLAYBACK",
                level: .warn,
                phase: .end,
                outcome: .rejected,
                traceContext: trace,
                source: DiagnosticSourceLocation(module: "Application", component: "PlaybackIntentService", function: "submit"),
                payload: { DiagnosticEventPayload(fields: ["reasonCode": .string("empty_tracks")], message: "Rejected playback intent: empty tracks") }
            )
            throw CoreError.notFound("没有可播放的曲目")
        }
        // Ensure all tracks belong to targetProviderID
        guard tracks.allSatisfy({ ProviderID(rawValue: $0.providerID) == targetProviderID }) else {
            AppLogger.shared.emit(
                eventName: "playback.intent.rejected",
                category: "PLAYBACK",
                level: .warn,
                phase: .end,
                outcome: .rejected,
                traceContext: trace,
                source: DiagnosticSourceLocation(module: "Application", component: "PlaybackIntentService", function: "submit"),
                payload: { DiagnosticEventPayload(fields: ["reasonCode": .string("mixed_provider_tracks")], message: "Rejected mixed-provider tracks") }
            )
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
                AppLogger.shared.emit(
                    eventName: "playback.intent.rejected",
                    category: "PLAYBACK",
                    level: .warn,
                    phase: .end,
                    outcome: .rejected,
                    traceContext: trace,
                    source: DiagnosticSourceLocation(module: "Application", component: "PlaybackIntentService", function: "submit"),
                    payload: {
                        DiagnosticEventPayload(
                            context: DiagnosticContext(playingProviderID: activeProvider.rawValue),
                            fields: ["reasonCode": .string("cross_platform_queue_mutation_denied")],
                            message: "Rejected cross-platform \(intent) while \(activeProvider.rawValue) active"
                        )
                    }
                )
                throw CoreError.unsupported("当前队列属于 \(activeProvider.rawValue)，不支持跨平台插播或追加 \(targetProviderID.rawValue)")
            }
        }

        AppLogger.shared.emit(
            eventName: "platform.operation.routed",
            category: "PLATFORM",
            level: .info,
            traceContext: trace,
            source: DiagnosticSourceLocation(module: "Application", component: "PlaybackIntentService", function: "submit"),
            payload: {
                DiagnosticEventPayload(
                    context: DiagnosticContext(browsingProviderID: browsingPID?.rawValue, playingProviderID: activeProvider?.rawValue, operationProviderID: targetProviderID.rawValue),
                    fields: ["operation": .string("playback_\(intent)")],
                    message: "Routed playback intent to \(targetProviderID.rawValue)"
                )
            }
        )

        _ = try await DiagnosticTrace.withContext(trace) {
            try await registry.activate(providerID: targetProviderID)
        }
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
        let browsingPID = await registry.browsingProviderID
        let trace = DiagnosticTrace.currentOrRoot(
            context: DiagnosticContext(browsingProviderID: browsingPID?.rawValue, operationProviderID: pid.rawValue, resourceRef: resource.normalizedKey)
        )
        AppLogger.shared.emit(
            eventName: "media.action.requested",
            category: "MEDIA_ACTION",
            level: .info,
            traceContext: trace,
            source: DiagnosticSourceLocation(module: "Application", component: "MediaActionService", function: "setFavorite"),
            payload: {
                DiagnosticEventPayload(
                    fields: ["action": .string(enabled ? "favorite_on" : "favorite_off"), "location": .string("application_service")],
                    message: "Media action setFavorite(\(enabled)) requested on \(pid.rawValue)"
                )
            }
        )
        guard !pid.isUnknown else {
            AppLogger.shared.emit(
                eventName: "media.action.rejected",
                category: "MEDIA_ACTION",
                level: .warn,
                outcome: .rejected,
                traceContext: trace,
                source: DiagnosticSourceLocation(module: "Application", component: "MediaActionService", function: "setFavorite"),
                payload: { DiagnosticEventPayload(fields: ["reasonCode": .string("unknown_provider")], message: "Rejected setFavorite: unknown provider") }
            )
            throw CoreError.unsupported("Unknown provider")
        }
        AppLogger.shared.emit(
            eventName: "platform.operation.routed",
            category: "PLATFORM",
            level: .info,
            traceContext: trace,
            source: DiagnosticSourceLocation(module: "Application", component: "MediaActionService", function: "setFavorite"),
            payload: {
                DiagnosticEventPayload(
                    context: DiagnosticContext(browsingProviderID: browsingPID?.rawValue, operationProviderID: pid.rawValue, resourceRef: resource.normalizedKey),
                    fields: ["operation": .string("setFavorite")],
                    message: "Routed setFavorite to \(pid.rawValue)"
                )
            }
        )
        let adapter = try await registry.activate(providerID: pid)
        guard let mutation = adapter.mutationProvider else {
            throw CoreError.unsupported("Provider \(pid.rawValue) does not support favorite mutation")
        }
        return try await DiagnosticTrace.withContext(trace) {
            try await mutation.setFavorite(resource, enabled: enabled)
        }
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
        AppLogger.shared.emit(
            eventName: "origin.navigation.requested",
            category: "ORIGIN",
            level: .info,
            source: DiagnosticSourceLocation(module: "Application", component: "NavigationService", function: "resolveOriginNavigation"),
            payload: {
                DiagnosticEventPayload(
                    fields: ["originKind": .string(String(describing: origin.kind))],
                    message: "Origin navigation requested"
                )
            }
        )
        guard origin.canNavigate, let target = origin.resolvedNavigationTarget, target.isNavigable else {
            AppLogger.shared.emit(
                eventName: "navigation.failed",
                category: "ORIGIN",
                level: .warn,
                outcome: .failed,
                source: DiagnosticSourceLocation(module: "Application", component: "NavigationService", function: "resolveOriginNavigation"),
                payload: { DiagnosticEventPayload(fields: ["reasonCode": .string("not_navigable")], message: "Origin cannot navigate internally") }
            )
            throw CoreError.notFound("该来源无法内部定位")
        }
        if case .resource(_, _, _, let providerIDStr) = target {
            let pid = ProviderID(rawValue: providerIDStr)
            guard !pid.isUnknown else {
                AppLogger.shared.emit(
                    eventName: "navigation.failed",
                    category: "ORIGIN",
                    level: .warn,
                    outcome: .failed,
                    source: DiagnosticSourceLocation(module: "Application", component: "NavigationService", function: "resolveOriginNavigation"),
                    payload: { DiagnosticEventPayload(fields: ["reasonCode": .string("unknown_provider")], message: "Unknown provider origin cannot navigate") }
                )
                throw CoreError.unsupported("未知平台来源无法导航")
            }
            await registry.setBrowsingProvider(pid)
            AppLogger.shared.emit(
                eventName: "navigation.route.resolved",
                category: "ORIGIN",
                level: .info,
                outcome: .succeeded,
                source: DiagnosticSourceLocation(module: "Application", component: "NavigationService", function: "resolveOriginNavigation"),
                payload: {
                    DiagnosticEventPayload(
                        context: DiagnosticContext(browsingProviderID: pid.rawValue),
                        fields: ["targetProviderID": .string(pid.rawValue), "causedPlaybackMutation": .bool(false)],
                        message: "Origin navigation resolved to \(pid.rawValue) (zero playback mutation)"
                    )
                }
            )
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
