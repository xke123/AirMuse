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

        public init(providerID: String = ProviderID.unknown.rawValue, accountID: String = "", storefront: String = "") {
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
    private var cachedCapabilities: [String: MediaActionCapabilities] = [:]

    private var inFlightReads: [String: (id: UUID, task: Task<MediaResourceState, Error>)] = [:]
    private var activeWriteTasks: [String: (id: UUID, task: Task<MediaMutationOutcome, Error>)] = [:]
    private var latestFavoriteIntent: [String: (operationID: UUID, target: Bool)] = [:]
    private var latestLibraryIntent: [String: (operationID: UUID, target: Bool)] = [:]
    private var fieldRevisions: [String: (library: UInt64, favorite: UInt64)] = [:]
    private var observers: [UUID: StateObserver] = [:]

    private weak var providerRef: (any MediaResourceMutationProvider & AnyObject)?
    private var strongProvider: (any MediaResourceMutationProvider)?
    private var providerResolver: (@MainActor (ProviderID) -> (any MediaResourceMutationProvider)?)?

    private struct DiskSnapshotEntry: Codable {
        let normalizedKey: String
        let libraryMembership: Bool?
        let favorite: Bool?
        let updatedAt: TimeInterval
    }

    private var persistenceDirectory: URL?
    private var persistenceTTL: TimeInterval = 900
    private var diskSaveTask: Task<Void, Never>?

    public init(maxCachedEntries: Int = 1000) {
        self.maxCachedEntries = max(64, maxCachedEntries)
    }

    public func configure(provider: (any MediaResourceMutationProvider)?) {
        self.strongProvider = provider
        self.providerRef = provider as? (any MediaResourceMutationProvider & AnyObject)
    }

    public func configureProviderResolver(_ resolver: @escaping @MainActor (ProviderID) -> (any MediaResourceMutationProvider)?) {
        self.providerResolver = resolver
    }

    /// Enables opt-in account-scoped SWR disk persistence for confirmed states.
    public func configurePersistence(directory: URL?, ttlSeconds: TimeInterval = 900) {
        self.persistenceDirectory = directory
        self.persistenceTTL = max(30, ttlSeconds)
        hydrateFromDiskIfNeeded()
    }

    private var activeProvider: (any MediaResourceMutationProvider)? {
        strongProvider ?? providerRef
    }

    private func provider(for resource: MediaResourceReference) -> (any MediaResourceMutationProvider)? {
        let pid = ProviderID(rawValue: resource.providerID)
        if !pid.isUnknown, let resolved = providerResolver?(pid) {
            return resolved
        }
        return activeProvider
    }

    /// Switches account/storefront scope, cancelling all in-flight reads/writes and clearing stale state.
    public func setScope(_ scope: Scope) {
        guard scope != currentScope else { return }
        diskSaveTask?.cancel()
        diskSaveTask = nil
        currentScope = scope
        scopeGeneration &+= 1
        for (_, entry) in inFlightReads { entry.task.cancel() }
        for (_, entry) in activeWriteTasks { entry.task.cancel() }
        inFlightReads.removeAll()
        activeWriteTasks.removeAll()
        latestFavoriteIntent.removeAll()
        latestLibraryIntent.removeAll()
        fieldRevisions.removeAll()
        states.removeAll()
        keyOrder.removeAll()
        cachedCapabilities.removeAll()
        hydrateFromDiskIfNeeded()
    }

    /// Synchronous capability snapshot backed by the configured Provider (no hardcoded UI fallback).
    public func capabilities(for resource: MediaResourceReference) -> MediaActionCapabilities {
        cachedCapabilities[capabilityKey(for: resource)] ?? .playbackOnly
    }

    @discardableResult
    public func refreshCapabilities(for resource: MediaResourceReference) async -> MediaActionCapabilities {
        guard let provider = provider(for: resource) else {
            return .playbackOnly
        }
        let capturedGen = scopeGeneration
        let caps = await provider.mediaActionCapabilities(for: resource)
        guard capturedGen == scopeGeneration, !Task.isCancelled else {
            return capabilities(for: resource)
        }
        cachedCapabilities[capabilityKey(for: resource)] = caps
        return caps
    }

    public func prefetchCapabilities(for resources: [MediaResourceReference]) async {
        for resource in resources {
            _ = await refreshCapabilities(for: resource)
        }
    }

    private func capabilityKey(for resource: MediaResourceReference) -> String {
        switch resource.kind {
        case .song: return "song"
        case .queueEntry: return "queueEntry"
        case .album: return "album"
        case .playlist(let ownership): return "playlist_\(ownership.rawValue)"
        case .artist: return "artist"
        case .station: return "station"
        }
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
        var rev = fieldRevisions[key] ?? (0, 0)
        var changed = false
        if let lib = libraryMembership, !current.libraryMembership.isPending {
            let next = MediaToggleState.known(lib)
            if current.libraryMembership != next {
                current.libraryMembership = next
                rev.library &+= 1
                changed = true
            }
        }
        if let fav = favorite, !current.favorite.isPending {
            let next = MediaToggleState.known(fav)
            if current.favorite != next {
                current.favorite = next
                rev.favorite &+= 1
                changed = true
            }
        }
        if changed {
            fieldRevisions[key] = rev
            storeState(current, forKey: key, normalizedKey: resource.normalizedKey)
        }
    }

    /// Deduplicates concurrent state reads for the same resource within the current account scope.
    @discardableResult
    public func refreshState(for resource: MediaResourceReference) async throws -> MediaResourceState {
        guard let provider = provider(for: resource) else {
            return state(for: resource)
        }
        let key = scopedKey(for: resource)
        if let existing = inFlightReads[key] {
            return try await existing.task.value
        }

        let capturedGen = scopeGeneration
        let capturedRevs = fieldRevisions[key] ?? (0, 0)
        let readID = UUID()
        let task = Task<MediaResourceState, Error> { @MainActor [weak self] in
            let fetched = try await provider.fetchResourceState(resource)
            guard let self, capturedGen == self.scopeGeneration, !Task.isCancelled else {
                throw MediaActionError.accountMismatch
            }
            let merged = self.mergeFetchedState(
                fetched,
                withExisting: self.states[key] ?? .unknown,
                capturedRevisions: capturedRevs,
                key: key
            )
            self.storeState(merged, forKey: key, normalizedKey: resource.normalizedKey)
            return merged
        }
        inFlightReads[key] = (readID, task)
        defer {
            if inFlightReads[key]?.id == readID {
                inFlightReads.removeValue(forKey: key)
            }
        }
        return try await task.value
    }

    /// Batch-refreshes unknown resource states in a single provider batch call per resource type.
    public func refreshStates(for resources: [MediaResourceReference]) async {
        guard !resources.isEmpty, let provider = provider(for: resources[0]) else { return }
        let capturedGen = scopeGeneration
        var pending: [(resource: MediaResourceReference, key: String, revs: (library: UInt64, favorite: UInt64))] = []
        var seen = Set<String>()

        for resource in resources {
            let key = scopedKey(for: resource)
            guard seen.insert(key).inserted else { continue }
            guard inFlightReads[key] == nil, activeWriteTasks[key] == nil else { continue }
            let existing = states[key] ?? .unknown
            if existing.libraryMembership == .unknown || existing.favorite == .unknown {
                pending.append((resource, key, fieldRevisions[key] ?? (0, 0)))
            }
        }
        guard !pending.isEmpty else { return }

        guard let fetchedMap = try? await provider.fetchResourceStates(for: pending.map(\.resource)) else {
            return
        }
        guard capturedGen == scopeGeneration, !Task.isCancelled else { return }

        for entry in pending {
            guard let fetched = fetchedMap[entry.resource.normalizedKey] else { continue }
            let merged = mergeFetchedState(
                fetched,
                withExisting: states[entry.key] ?? .unknown,
                capturedRevisions: entry.revs,
                key: entry.key
            )
            storeState(merged, forKey: entry.key, normalizedKey: entry.resource.normalizedKey)
        }
    }

    /// Sets favorite status with per-resource serialization, latest-intent coalescing,
    /// timeout read-back reconciliation, and safe error rollback.
    @discardableResult
    public func setFavorite(_ resource: MediaResourceReference, enabled: Bool) async throws -> MediaResourceState {
        try await setFavoriteWithOutcome(resource, enabled: enabled).state
    }

    public func setFavoriteWithOutcome(_ resource: MediaResourceReference, enabled: Bool) async throws -> MediaMutationOutcome {
        if case .playlist(let ownership) = resource.kind, !ownership.isContainerWritable {
            throw MediaActionError.readOnlyPlaylist
        }
        guard let provider = provider(for: resource) else {
            throw MediaActionError.unsupportedCapability("未连接数据源")
        }

        let key = scopedKey(for: resource)
        let capturedGen = scopeGeneration
        let opID = UUID()
        let writeID = UUID()
        let previousConfirmed = states[key]?.favorite.confirmedBool
        latestFavoriteIntent[key] = (opID, enabled)

        var pendingState = states[key] ?? .unknown
        pendingState.favorite = .pending(target: enabled, previous: previousConfirmed, operationID: opID)
        var rev = fieldRevisions[key] ?? (0, 0)
        rev.favorite &+= 1
        fieldRevisions[key] = rev
        storeState(pendingState, forKey: key, normalizedKey: resource.normalizedKey)

        let priorTask = activeWriteTasks[key]?.task
        let task = Task<MediaMutationOutcome, Error> { @MainActor [weak self] in
            if let priorTask {
                _ = try? await priorTask.value
            }
            guard let self, capturedGen == self.scopeGeneration, !Task.isCancelled else {
                throw MediaActionError.accountMismatch
            }
            if let latest = self.latestFavoriteIntent[key], latest.operationID != opID {
                return .superseded(self.states[key] ?? .unknown)
            }

            do {
                let receipt = try await provider.setFavorite(resource, enabled: enabled)
                guard capturedGen == self.scopeGeneration, !Task.isCancelled else {
                    throw MediaActionError.accountMismatch
                }
                if let latest = self.latestFavoriteIntent[key], latest.operationID != opID {
                    return .superseded(self.states[key] ?? .unknown)
                }
                let merged = self.mergeMutationReceipt(
                    receipt.state,
                    into: self.states[key] ?? .unknown,
                    key: key,
                    primaryField: .favorite,
                    primaryFallbackKnown: nil,
                    opID: opID
                )
                self.storeState(merged, forKey: key, normalizedKey: resource.normalizedKey)
                if case .unknown = merged.favorite {
                    return .unknownOutcome(merged, message: "收藏状态尚待确认")
                }
                return .confirmed(merged, message: receipt.message)
            } catch {
                guard capturedGen == self.scopeGeneration, !Task.isCancelled else {
                    throw MediaActionError.accountMismatch
                }
                if let latest = self.latestFavoriteIntent[key], latest.operationID != opID {
                    return .superseded(self.states[key] ?? .unknown)
                }
                if Self.isTimeoutError(error) {
                    if let reconciled = try? await provider.fetchResourceState(resource) {
                        guard capturedGen == self.scopeGeneration, !Task.isCancelled else {
                            throw MediaActionError.accountMismatch
                        }
                        if let latest = self.latestFavoriteIntent[key], latest.operationID != opID {
                            return .superseded(self.states[key] ?? .unknown)
                        }
                        let merged = self.mergeMutationReceipt(
                            reconciled,
                            into: self.states[key] ?? .unknown,
                            key: key,
                            primaryField: .favorite,
                            primaryFallbackKnown: nil,
                            opID: opID
                        )
                        self.storeState(merged, forKey: key, normalizedKey: resource.normalizedKey)
                        if case .known(let actual) = merged.favorite {
                            if actual == enabled {
                                return .confirmed(merged, message: nil)
                            }
                            return .reconciledDifferent(merged, actual: actual)
                        }
                    }
                    var unknownState = self.states[key] ?? .unknown
                    unknownState.favorite = .failed(lastKnown: previousConfirmed, errorMessage: "请求超时，状态未知")
                    self.storeState(unknownState, forKey: key, normalizedKey: resource.normalizedKey)
                    return .unknownOutcome(unknownState, message: "请求超时，收藏状态未知")
                }
                var failedState = self.states[key] ?? .unknown
                failedState.favorite = .failed(lastKnown: previousConfirmed, errorMessage: error.localizedDescription)
                self.storeState(failedState, forKey: key, normalizedKey: resource.normalizedKey)
                throw error
            }
        }
        activeWriteTasks[key] = (writeID, task)
        defer {
            if activeWriteTasks[key]?.id == writeID {
                activeWriteTasks.removeValue(forKey: key)
                if latestFavoriteIntent[key]?.operationID == opID {
                    latestFavoriteIntent.removeValue(forKey: key)
                }
            }
        }
        return try await task.value
    }

    /// Adds or removes a resource from the library with read-only playlist protection and reconciliation.
    @discardableResult
    public func setLibraryMembership(_ resource: MediaResourceReference, inLibrary: Bool) async throws -> MediaResourceState {
        try await setLibraryMembershipWithOutcome(resource, inLibrary: inLibrary).state
    }

    public func setLibraryMembershipWithOutcome(_ resource: MediaResourceReference, inLibrary: Bool) async throws -> MediaMutationOutcome {
        if case .playlist(let ownership) = resource.kind, !ownership.isContainerWritable {
            throw MediaActionError.readOnlyPlaylist
        }
        if resource.kind == .artist || resource.kind == .station {
            throw MediaActionError.unsupportedCapability("该资源不支持资料库操作")
        }
        guard let provider = provider(for: resource) else {
            throw MediaActionError.unsupportedCapability("未连接数据源")
        }

        let key = scopedKey(for: resource)
        let capturedGen = scopeGeneration
        let opID = UUID()
        let writeID = UUID()
        let previousConfirmed = states[key]?.libraryMembership.confirmedBool
        latestLibraryIntent[key] = (opID, inLibrary)

        var pendingState = states[key] ?? .unknown
        pendingState.libraryMembership = .pending(target: inLibrary, previous: previousConfirmed, operationID: opID)
        var rev = fieldRevisions[key] ?? (0, 0)
        rev.library &+= 1
        fieldRevisions[key] = rev
        storeState(pendingState, forKey: key, normalizedKey: resource.normalizedKey)

        let priorTask = activeWriteTasks[key]?.task
        let task = Task<MediaMutationOutcome, Error> { @MainActor [weak self] in
            if let priorTask {
                _ = try? await priorTask.value
            }
            guard let self, capturedGen == self.scopeGeneration, !Task.isCancelled else {
                throw MediaActionError.accountMismatch
            }
            if let latest = self.latestLibraryIntent[key], latest.operationID != opID {
                return .superseded(self.states[key] ?? .unknown)
            }

            do {
                let receipt = inLibrary
                    ? try await provider.addToLibrary(resource)
                    : try await provider.removeFromLibrary(resource)
                guard capturedGen == self.scopeGeneration, !Task.isCancelled else {
                    throw MediaActionError.accountMismatch
                }
                if let latest = self.latestLibraryIntent[key], latest.operationID != opID {
                    return .superseded(self.states[key] ?? .unknown)
                }
                let merged = self.mergeMutationReceipt(
                    receipt.state,
                    into: self.states[key] ?? .unknown,
                    key: key,
                    primaryField: .library,
                    primaryFallbackKnown: nil,
                    opID: opID
                )
                self.storeState(merged, forKey: key, normalizedKey: resource.normalizedKey)
                if case .unknown = merged.libraryMembership {
                    return .unknownOutcome(merged, message: "资料库状态尚待确认")
                }
                return .confirmed(merged, message: receipt.message)
            } catch {
                guard capturedGen == self.scopeGeneration, !Task.isCancelled else {
                    throw MediaActionError.accountMismatch
                }
                if let latest = self.latestLibraryIntent[key], latest.operationID != opID {
                    return .superseded(self.states[key] ?? .unknown)
                }
                if Self.isTimeoutError(error) {
                    if let reconciled = try? await provider.fetchResourceState(resource) {
                        guard capturedGen == self.scopeGeneration, !Task.isCancelled else {
                            throw MediaActionError.accountMismatch
                        }
                        if let latest = self.latestLibraryIntent[key], latest.operationID != opID {
                            return .superseded(self.states[key] ?? .unknown)
                        }
                        let merged = self.mergeMutationReceipt(
                            reconciled,
                            into: self.states[key] ?? .unknown,
                            key: key,
                            primaryField: .library,
                            primaryFallbackKnown: nil,
                            opID: opID
                        )
                        self.storeState(merged, forKey: key, normalizedKey: resource.normalizedKey)
                        if case .known(let actual) = merged.libraryMembership {
                            if actual == inLibrary {
                                return .confirmed(merged, message: nil)
                            }
                            return .reconciledDifferent(merged, actual: actual)
                        }
                    }
                    var unknownState = self.states[key] ?? .unknown
                    unknownState.libraryMembership = .failed(lastKnown: previousConfirmed, errorMessage: "请求超时，状态未知")
                    self.storeState(unknownState, forKey: key, normalizedKey: resource.normalizedKey)
                    return .unknownOutcome(unknownState, message: "请求超时，资料库状态未知")
                }
                var failedState = self.states[key] ?? .unknown
                failedState.libraryMembership = .failed(lastKnown: previousConfirmed, errorMessage: error.localizedDescription)
                self.storeState(failedState, forKey: key, normalizedKey: resource.normalizedKey)
                throw error
            }
        }
        activeWriteTasks[key] = (writeID, task)
        defer {
            if activeWriteTasks[key]?.id == writeID {
                activeWriteTasks.removeValue(forKey: key)
                if latestLibraryIntent[key]?.operationID == opID {
                    latestLibraryIntent.removeValue(forKey: key)
                }
            }
        }
        return try await task.value
    }

    // MARK: - Helpers

    private enum ResourceField {
        case library
        case favorite
    }

    private func scopedKey(for resource: MediaResourceReference) -> String {
        "\(currentScope.providerID)|\(currentScope.accountID)|\(currentScope.storefront)|\(resource.normalizedKey)"
    }

    private func mergeMutationReceipt(
        _ receiptState: MediaResourceState,
        into existing: MediaResourceState,
        key: String,
        primaryField: ResourceField,
        primaryFallbackKnown: Bool?,
        opID: UUID
    ) -> MediaResourceState {
        var result = existing
        var rev = fieldRevisions[key] ?? (0, 0)

        // Library field patch
        switch primaryField {
        case .library:
            if case .known = receiptState.libraryMembership {
                result.libraryMembership = receiptState.libraryMembership
                rev.library &+= 1
            } else if let fallback = primaryFallbackKnown {
                result.libraryMembership = .known(fallback)
                rev.library &+= 1
            } else {
                result.libraryMembership = .unknown
                rev.library &+= 1
            }
            if !existing.favorite.isPending, case .known = receiptState.favorite {
                result.favorite = receiptState.favorite
                rev.favorite &+= 1
            }
        case .favorite:
            if case .known = receiptState.favorite {
                result.favorite = receiptState.favorite
                rev.favorite &+= 1
            } else if let fallback = primaryFallbackKnown {
                result.favorite = .known(fallback)
                rev.favorite &+= 1
            } else {
                result.favorite = .unknown
                rev.favorite &+= 1
            }
            if !existing.libraryMembership.isPending, case .known = receiptState.libraryMembership {
                result.libraryMembership = receiptState.libraryMembership
                rev.library &+= 1
            }
        }

        _ = opID
        fieldRevisions[key] = rev
        return result
    }

    private func mergeFetchedState(
        _ fetched: MediaResourceState,
        withExisting existing: MediaResourceState,
        capturedRevisions: (library: UInt64, favorite: UInt64),
        key: String
    ) -> MediaResourceState {
        var result = existing
        let currentRevs = fieldRevisions[key] ?? (0, 0)
        if currentRevs.library == capturedRevisions.library, !existing.libraryMembership.isPending {
            if case .known = fetched.libraryMembership {
                result.libraryMembership = fetched.libraryMembership
            } else if case .unknown = existing.libraryMembership {
                result.libraryMembership = fetched.libraryMembership
            }
        }
        if currentRevs.favorite == capturedRevisions.favorite, !existing.favorite.isPending {
            if case .known = fetched.favorite {
                result.favorite = fetched.favorite
            } else if case .unknown = existing.favorite {
                result.favorite = fetched.favorite
            }
        }
        return result
    }

    private func storeState(_ state: MediaResourceState, forKey key: String, normalizedKey: String) {
        if states[key] == nil {
            keyOrder.append(key)
            if keyOrder.count > maxCachedEntries {
                // Evict oldest non-pending, inactive entry
                if let evictIdx = keyOrder.firstIndex(where: { candidate in
                    guard candidate != key else { return false }
                    if activeWriteTasks[candidate] != nil || inFlightReads[candidate] != nil { return false }
                    if let st = states[candidate], st.libraryMembership.isPending || st.favorite.isPending { return false }
                    return true
                }) {
                    let evicted = keyOrder.remove(at: evictIdx)
                    states.removeValue(forKey: evicted)
                    fieldRevisions.removeValue(forKey: evicted)
                }
            }
        }
        states[key] = state
        for observer in observers.values {
            observer(normalizedKey, state)
        }
        scheduleDiskFlushIfNeeded()
    }

    private func persistenceFileURL() -> URL? {
        guard let dir = persistenceDirectory,
              !currentScope.accountID.isEmpty else { return nil }
        let safeScope = "\(currentScope.providerID)_\(currentScope.accountID)_\(currentScope.storefront)"
            .replacingOccurrences(of: "[^A-Za-z0-9._-]", with: "_", options: .regularExpression)
        return dir.appendingPathComponent("media_state_\(safeScope).json")
    }

    private func hydrateFromDiskIfNeeded() {
        guard let fileURL = persistenceFileURL(),
              let data = try? Data(contentsOf: fileURL),
              let entries = try? JSONDecoder().decode([DiskSnapshotEntry].self, from: data) else {
            return
        }
        let now = Date().timeIntervalSince1970
        for entry in entries where (now - entry.updatedAt) <= persistenceTTL {
            let key = "\(currentScope.providerID)|\(currentScope.accountID)|\(currentScope.storefront)|\(entry.normalizedKey)"
            guard states[key] == nil else { continue }
            let libState: MediaToggleState = entry.libraryMembership.map { .known($0) } ?? .unknown
            let favState: MediaToggleState = entry.favorite.map { .known($0) } ?? .unknown
            if libState != .unknown || favState != .unknown {
                if keyOrder.count < maxCachedEntries {
                    keyOrder.append(key)
                    states[key] = MediaResourceState(libraryMembership: libState, favorite: favState)
                }
            }
        }
    }

    private func scheduleDiskFlushIfNeeded() {
        guard persistenceFileURL() != nil else { return }
        diskSaveTask?.cancel()
        let capturedGen = scopeGeneration
        diskSaveTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(350))
            guard let self, capturedGen == self.scopeGeneration, !Task.isCancelled else { return }
            self.flushDiskSnapshot()
        }
    }

    private func flushDiskSnapshot() {
        guard let fileURL = persistenceFileURL() else { return }
        let prefix = "\(currentScope.providerID)|\(currentScope.accountID)|\(currentScope.storefront)|"
        let now = Date().timeIntervalSince1970
        var entries: [DiskSnapshotEntry] = []
        entries.reserveCapacity(min(keyOrder.count, maxCachedEntries))
        for key in keyOrder {
            guard key.hasPrefix(prefix), let st = states[key] else { continue }
            let lib = st.libraryMembership.confirmedBool
            let fav = st.favorite.confirmedBool
            guard lib != nil || fav != nil else { continue }
            let normalizedKey = String(key.dropFirst(prefix.count))
            entries.append(DiskSnapshotEntry(normalizedKey: normalizedKey, libraryMembership: lib, favorite: fav, updatedAt: now))
        }
        if let dir = persistenceDirectory {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        if let encoded = try? JSONEncoder().encode(entries) {
            try? encoded.write(to: fileURL, options: .atomic)
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
