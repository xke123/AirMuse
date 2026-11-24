import Foundation
import Domain
import Infrastructure

// MARK: - LibraryLoadOutcome

public enum LibraryLoadOutcome<T: Sendable>: Sendable {
    case loaded(value: T, isStale: Bool, completeness: CacheCompleteness)
    case empty(isStale: Bool)
    case unauthorized(CoreError)
    case error(CoreError, cachedFallback: T?)
}

// MARK: - PaginatedPage

public struct PaginatedPage<Item: Sendable>: Sendable {
    public let items: [Item]
    public let nextCursor: String?

    public init(items: [Item], nextCursor: String? = nil) {
        self.items = items
        self.nextCursor = nextCursor
    }
}

// MARK: - LibraryRepositoryV2

/// Authoritative Core V2 repository for public catalog and private user library data.
/// Owns SWR caching via `SQLiteCacheStore`, pagination with circular-cursor detection,
/// query generation isolation for search, and strict error semantics without fake fallbacks.
public actor LibraryRepositoryV2 {
    public struct TTLPolicy: Sendable {
        public let ttlSeconds: TimeInterval
        public let maxStaleSeconds: TimeInterval

        public init(ttlSeconds: TimeInterval, maxStaleSeconds: TimeInterval) {
            self.ttlSeconds = ttlSeconds
            self.maxStaleSeconds = maxStaleSeconds
        }

        public static let publicCatalog = TTLPolicy(ttlSeconds: 3600, maxStaleSeconds: 7 * 86400)
        public static let personalLibrary = TTLPolicy(ttlSeconds: 300, maxStaleSeconds: 86400)
        public static let recommendations = TTLPolicy(ttlSeconds: 900, maxStaleSeconds: 86400)
        public static let trackDetail = TTLPolicy(ttlSeconds: 86400, maxStaleSeconds: 7 * 86400)
    }

    private let cache: SQLiteCacheStore
    private let sessionCoordinator: any SessionCoordinatorProtocol
    private var searchGeneration: UInt64 = 0

    public init(cache: SQLiteCacheStore, sessionCoordinator: any SessionCoordinatorProtocol) {
        self.cache = cache
        self.sessionCoordinator = sessionCoordinator
    }

    // MARK: - SWR Loader

    public func load<T: Codable & Sendable>(
        _ type: T.Type,
        key: CacheKey,
        ttlPolicy: TTLPolicy,
        forceRefresh: Bool = false,
        sessionContext: SessionContext? = nil,
        isEmptyValue: @Sendable (T) -> Bool = { _ in false },
        remoteFetch: @Sendable () async throws -> T
    ) async -> LibraryLoadOutcome<T> {
        let snapshot = await sessionCoordinator.snapshot

        if key.scope == .private {
            guard let ctx = sessionContext ?? snapshot.context,
                  snapshot.sessionState.allowsCachedPrivateRead,
                  ctx.accountID == key.accountID else {
                return .unauthorized(.userCredentialInvalid)
            }
        }

        let activeAcct = snapshot.context?.accountID
        let cached = try? await cache.read(T.self, for: key, activeAccountID: activeAcct)

        if !forceRefresh, let cached, cached.isFresh {
            if isEmptyValue(cached.value) {
                return .empty(isStale: false)
            }
            return .loaded(value: cached.value, isStale: false, completeness: cached.completeness)
        }

        do {
            let fresh = try await remoteFetch()

            if key.scope == .private {
                guard let ctx = sessionContext ?? snapshot.context else {
                    return .unauthorized(.staleSession)
                }
                try await cache.write(
                    fresh,
                    for: key,
                    ttlSeconds: ttlPolicy.ttlSeconds,
                    maxStaleSeconds: ttlPolicy.maxStaleSeconds,
                    completeness: .complete,
                    sessionValidator: { [sessionCoordinator] in
                        await sessionCoordinator.validate(context: ctx)
                    }
                )
            } else {
                try await cache.write(
                    fresh,
                    for: key,
                    ttlSeconds: ttlPolicy.ttlSeconds,
                    maxStaleSeconds: ttlPolicy.maxStaleSeconds,
                    completeness: .complete
                )
            }

            if isEmptyValue(fresh) {
                return .empty(isStale: false)
            }
            return .loaded(value: fresh, isStale: false, completeness: .complete)
        } catch let err as CoreError {
            if err == .userCredentialInvalid || err == .subscriptionRequired {
                return .unauthorized(err)
            }
            if let cached {
                return .error(err, cachedFallback: cached.value)
            }
            return .error(err, cachedFallback: nil)
        } catch {
            let mapped = CoreError.transport(statusCode: nil, message: error.localizedDescription)
            return .error(mapped, cachedFallback: cached?.value)
        }
    }

    // MARK: - Paginated Loader with Circular Cursor Detection

    public func fetchAllPages<Item: Sendable & Hashable>(
        maxPages: Int = 20,
        fetchPage: @Sendable (_ cursor: String?) async throws -> PaginatedPage<Item>
    ) async throws -> (items: [Item], completeness: CacheCompleteness) {
        var collected: [Item] = []
        var seenItems: Set<Item> = []
        var visitedCursors: Set<String> = []
        var cursor: String? = nil
        var pagesFetched = 0

        while pagesFetched < maxPages {
            try Task.checkCancellation()
            if let c = cursor {
                if visitedCursors.contains(c) {
                    return (collected, .partial)
                }
                visitedCursors.insert(c)
            }

            let page = try await fetchPage(cursor)
            pagesFetched += 1

            for item in page.items where !seenItems.contains(item) {
                seenItems.insert(item)
                collected.append(item)
            }

            guard let next = page.nextCursor, !next.isEmpty else {
                return (collected, .complete)
            }
            cursor = next
        }

        return (collected, .partial)
    }

    // MARK: - Generation-Isolated Search

    public func executeSearch<Result: Sendable>(
        query: String,
        perform: @Sendable (String) async throws -> Result
    ) async throws -> Result {
        searchGeneration += 1
        let myGen = searchGeneration
        let result = try await perform(query)
        guard myGen == searchGeneration else {
            throw CoreError.cancelled
        }
        return result
    }
}
