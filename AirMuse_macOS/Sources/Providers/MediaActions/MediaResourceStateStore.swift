import Foundation
import Domain

// MARK: - MediaResourceStateStore

/// Account-scoped, bounded shared state cache and serialized mutation coordinator
/// for library membership and favorite status across all UI surfaces.
@MainActor
public final class MediaResourceStateStore {

    public struct Scope: Sendable, Equatable, Hashable {
        public let providerID: String
        public let accountID: String
        public let storefront: String

        public init(providerID: String = "apple_music", accountID: String = "", storefront: String = "") {
            self.providerID = providerID
            self.accountID = accountID
            self.storefront = storefront
        }
    }

    public typealias StateObserver = @MainActor (String, MediaResourceState) -> Void

    private var currentScope: Scope = Scope()
    private var scopeGeneration: UInt64 = 0
    private var states: [String: MediaResourceState] = [:]
    private var keyOrder: [String] = []
    private let maxCachedEntries: Int

    private var inFlightReads: [String: Task<MediaResourceState, Error>] = [:]
    private var activeWriteTasks: [String: Task<MediaResourceState, Error>] = [:]
    private var latestFavoriteIntent: [String: (operationID: UUID, target: Bool)] = [:]
    private var latestLibraryIntent: [String: (operationID: UUID, target: Bool)] = [:]
    private var observers: [UUID: StateObserver] = [:]

    private weak var providerRef: (any MediaResourceMutationProvider & AnyObject)?
    private var strongProvider: (any MediaResourceMutationProvider)?

    public init(maxCachedEntries: Int = 1000) {
        self.maxCachedEntries = max(64, maxCachedEntries)
    }

    public func configure(provider: (any MediaResourceMutationProvider)?) {
        self.strongProvider = provider
        self.providerRef = provider as? (any MediaResourceMutationProvider & AnyObject)
    }

    private var activeProvider: (any MediaResourceMutationProvider)? {
        strongProvider ?? providerRef
    }

    /// Switches account/storefront scope, cancelling all in-flight reads/writes and clearing stale state.
    public func setScope(_ scope: Scope) {
        guard scope != currentScope else { return }
        currentScope = scope
        scopeGeneration &+= 1
        for (_, task) in inFlightReads { task.cancel() }
        for (_, task) in activeWriteTasks { task.cancel() }
        inFlightReads.removeAll()
        activeWriteTasks.removeAll()
        latestFavoriteIntent.removeAll()
        latestLibraryIntent.removeAll()
        states.removeAll()
        keyOrder.removeAll()
    }

    public func addObserver(_ observer: @escaping StateObserver) -> UUID {
        let id = UUID()
        observers[id] = observer
        return id
    }

    public func removeObserver(_ id: UUID) {
        observers.removeValue(forKey: id)
    }

    public func state(for resource: MediaResourceReference) -> MediaResourceState {
        states[scopedKey(for: resource)] ?? .unknown
    }

    public func state(forNormalizedKey normalizedKey: String) -> MediaResourceState {
        states["\(currentScope.providerID)|\(currentScope.accountID)|\(currentScope.storefront)|\(normalizedKey)"] ?? .unknown
    }

    /// Seeds known state from already-fetched library/detail responses without guessing `false` from absence.
    public func seedKnownState(
        for resource: MediaResourceReference,
        libraryMembership: Bool? = nil,
        favorite: Bool? = nil
    ) {
        let key = scopedKey(for: resource)
        var current = states[key] ?? .unknown
        var changed = false
        if let lib = libraryMembership, !current.libraryMembership.isPending {
            let next = MediaToggleState.known(lib)
            if current.libraryMembership != next {
                current.libraryMembership = next
                changed = true
            }
        }
        if let fav = favorite, !current.favorite.isPending {
            let next = MediaToggleState.known(fav)
            if current.favorite != next {
                current.favorite = next
                changed = true
            }
        }
        if changed {
            storeState(current, forKey: key, normalizedKey: resource.normalizedKey)
        }
    }

    /// Deduplicates concurrent state reads for the same resource within the current account scope.
    @discardableResult
    public func refreshState(for resource: MediaResourceReference) async throws -> MediaResourceState {
        guard let provider = activeProvider else {
            return state(for: resource)
        }
        let key = scopedKey(for: resource)
        if let existing = inFlightReads[key] {
            return try await existing.value
        }

        let capturedGen = scopeGeneration
        let task = Task<MediaResourceState, Error> {
            try await provider.fetchResourceState(resource)
        }
        inFlightReads[key] = task
        defer { inFlightReads.removeValue(forKey: key) }

        let fetched = try await task.value
        guard capturedGen == scopeGeneration, !Task.isCancelled else {
            throw MediaActionError.accountMismatch
        }
        let merged = mergeFetchedState(fetched, withExisting: states[key] ?? .unknown, key: key)
        storeState(merged, forKey: key, normalizedKey: resource.normalizedKey)
        return merged
    }

    /// Sets favorite status with per-resource serialization, latest-intent coalescing,
    /// timeout read-back reconciliation, and safe error rollback.
    @discardableResult
    public func setFavorite(_ resource: MediaResourceReference, enabled: Bool) async throws -> MediaResourceState {
        if case .playlist(let ownership) = resource.kind, !ownership.isContainerWritable {
            throw MediaActionError.readOnlyPlaylist
        }
        guard let provider = activeProvider else {
            throw MediaActionError.unsupportedCapability("未连接数据源")
        }

        let key = scopedKey(for: resource)
        let capturedGen = scopeGeneration
        let opID = UUID()
        let previousKnown = states[key]?.favorite.effectiveBool
        latestFavoriteIntent[key] = (opID, enabled)

        var pendingState = states[key] ?? .unknown
        pendingState.favorite = .pending(target: enabled, previous: previousKnown, operationID: opID)
        storeState(pendingState, forKey: key, normalizedKey: resource.normalizedKey)

        let priorTask = activeWriteTasks[key]
        let task = Task<MediaResourceState, Error> {
            if let priorTask {
                _ = try? await priorTask.value
            }
            guard capturedGen == self.scopeGeneration, !Task.isCancelled else {
                throw MediaActionError.accountMismatch
            }
            // If a newer intent superseded this one while waiting, skip redundant network write
            if let latest = self.latestFavoriteIntent[key], latest.operationID != opID {
                return self.states[key] ?? .unknown
            }

            do {
                let receipt = try await provider.setFavorite(resource, enabled: enabled)
                guard capturedGen == self.scopeGeneration, !Task.isCancelled else {
                    throw MediaActionError.accountMismatch
                }
                if let latest = self.latestFavoriteIntent[key], latest.operationID != opID {
                    return self.states[key] ?? .unknown
                }
                var next = receipt.state
                if case .unknown = next.favorite {
                    next.favorite = .known(enabled)
                }
                self.storeState(next, forKey: key, normalizedKey: resource.normalizedKey)
                return next
            } catch {
                guard capturedGen == self.scopeGeneration, !Task.isCancelled else {
                    throw MediaActionError.accountMismatch
                }
                if let latest = self.latestFavoriteIntent[key], latest.operationID != opID {
                    return self.states[key] ?? .unknown
                }
                // On timeout, reconcile with authoritative server state instead of blind retry
                if Self.isTimeoutError(error) {
                    if let reconciled = try? await provider.fetchResourceState(resource),
                       capturedGen == self.scopeGeneration {
                        self.storeState(reconciled, forKey: key, normalizedKey: resource.normalizedKey)
                        return reconciled
                    }
                }
                var failedState = self.states[key] ?? .unknown
                failedState.favorite = .failed(lastKnown: previousKnown, errorMessage: error.localizedDescription)
                self.storeState(failedState, forKey: key, normalizedKey: resource.normalizedKey)
                throw error
            }
        }
        activeWriteTasks[key] = task
        return try await task.value
    }

    /// Adds or removes a resource from the library with read-only playlist protection and reconciliation.
    @discardableResult
    public func setLibraryMembership(_ resource: MediaResourceReference, inLibrary: Bool) async throws -> MediaResourceState {
        if case .playlist(let ownership) = resource.kind, !ownership.isContainerWritable {
            throw MediaActionError.readOnlyPlaylist
        }
        if resource.kind == .artist || resource.kind == .station {
            throw MediaActionError.unsupportedCapability("该资源不支持资料库操作")
        }
        guard let provider = activeProvider else {
            throw MediaActionError.unsupportedCapability("未连接数据源")
        }

        let key = scopedKey(for: resource)
        let capturedGen = scopeGeneration
        let opID = UUID()
        let previousKnown = states[key]?.libraryMembership.effectiveBool
        latestLibraryIntent[key] = (opID, inLibrary)

        var pendingState = states[key] ?? .unknown
        pendingState.libraryMembership = .pending(target: inLibrary, previous: previousKnown, operationID: opID)
        storeState(pendingState, forKey: key, normalizedKey: resource.normalizedKey)

        let priorTask = activeWriteTasks[key]
        let task = Task<MediaResourceState, Error> {
            if let priorTask {
                _ = try? await priorTask.value
            }
            guard capturedGen == self.scopeGeneration, !Task.isCancelled else {
                throw MediaActionError.accountMismatch
            }
            if let latest = self.latestLibraryIntent[key], latest.operationID != opID {
                return self.states[key] ?? .unknown
            }

            do {
                let receipt = inLibrary
                    ? try await provider.addToLibrary(resource)
                    : try await provider.removeFromLibrary(resource)
                guard capturedGen == self.scopeGeneration, !Task.isCancelled else {
                    throw MediaActionError.accountMismatch
                }
                if let latest = self.latestLibraryIntent[key], latest.operationID != opID {
                    return self.states[key] ?? .unknown
                }
                var next = receipt.state
                if case .unknown = next.libraryMembership {
                    next.libraryMembership = .known(inLibrary)
                }
                self.storeState(next, forKey: key, normalizedKey: resource.normalizedKey)
                return next
            } catch {
                guard capturedGen == self.scopeGeneration, !Task.isCancelled else {
                    throw MediaActionError.accountMismatch
                }
                if let latest = self.latestLibraryIntent[key], latest.operationID != opID {
                    return self.states[key] ?? .unknown
                }
                if Self.isTimeoutError(error) {
                    if let reconciled = try? await provider.fetchResourceState(resource),
                       capturedGen == self.scopeGeneration {
                        self.storeState(reconciled, forKey: key, normalizedKey: resource.normalizedKey)
                        return reconciled
                    }
                }
                var failedState = self.states[key] ?? .unknown
                failedState.libraryMembership = .failed(lastKnown: previousKnown, errorMessage: error.localizedDescription)
                self.storeState(failedState, forKey: key, normalizedKey: resource.normalizedKey)
                throw error
            }
        }
        activeWriteTasks[key] = task
        return try await task.value
    }

    // MARK: - Helpers

    private func scopedKey(for resource: MediaResourceReference) -> String {
        "\(currentScope.providerID)|\(currentScope.accountID)|\(currentScope.storefront)|\(resource.normalizedKey)"
    }

    private func mergeFetchedState(
        _ fetched: MediaResourceState,
        withExisting existing: MediaResourceState,
        key: String
    ) -> MediaResourceState {
        var result = existing
        if !existing.libraryMembership.isPending, case .known = fetched.libraryMembership {
            result.libraryMembership = fetched.libraryMembership
        } else if case .unknown = existing.libraryMembership {
            result.libraryMembership = fetched.libraryMembership
        }
        if !existing.favorite.isPending, case .known = fetched.favorite {
            result.favorite = fetched.favorite
        } else if case .unknown = existing.favorite {
            result.favorite = fetched.favorite
        }
        return result
    }

    private func storeState(_ state: MediaResourceState, forKey key: String, normalizedKey: String) {
        if states[key] == nil {
            keyOrder.append(key)
            if keyOrder.count > maxCachedEntries {
                let oldest = keyOrder.removeFirst()
                states.removeValue(forKey: oldest)
            }
        }
        states[key] = state
        for observer in observers.values {
            observer(normalizedKey, state)
        }
    }

    private static func isTimeoutError(_ error: Error) -> Bool {
        if let actionErr = error as? MediaActionError, case .networkTimeout = actionErr {
            return true
        }
        if let urlErr = error as? URLError, urlErr.code == .timedOut {
            return true
        }
        return false
    }
}
