import Testing
import Foundation
@testable import Domain
@testable import Infrastructure
@testable import Providers

private actor DummySessionValidator: SessionCoordinatorProtocol {
    var activeSnapshot: SessionSnapshot
    var validContextIDs: Set<UUID> = []

    init(snapshot: SessionSnapshot) {
        self.activeSnapshot = snapshot
        if let ctx = snapshot.context {
            validContextIDs.insert(ctx.sessionID)
        }
    }

    var snapshot: SessionSnapshot { activeSnapshot }
    func snapshots() async -> AsyncStream<SessionSnapshot> {
        AsyncStream { $0.finish() }
    }
    func setValid(_ valid: Bool, for sessionID: UUID) {
        if valid { validContextIDs.insert(sessionID) } else { validContextIDs.remove(sessionID) }
    }
    func validate(context: SessionContext) async -> Bool {
        validContextIDs.contains(context.sessionID)
    }
}

@Suite("CacheRepositoryTests")
struct CacheRepositoryTests {

    @Test func sqliteCacheIsolatesAccountsEnforcesMaxStaleAndEvictsLRU() async throws {
        let dir = URL(fileURLWithPath: "/tmp/corev2_cache_\(UUID().uuidString)")
        let dbURL = dir.appendingPathComponent("cache.sqlite")
        defer { try? FileManager.default.removeItem(at: dir) }

        let clock = TestClock()
        let cache = SQLiteCacheStore(dbURL: dbURL, clock: clock, maxDiskBytes: 2048)
        try await cache.open()

        let keyA = CacheKey(providerID: "apple_music", scope: .private, accountID: "acct-A", storefront: "cn", resource: "favs")
        let keyB = CacheKey(providerID: "apple_music", scope: .private, accountID: "acct-B", storefront: "cn", resource: "favs")

        try await cache.write(["song-a"], for: keyA, ttlSeconds: 60, maxStaleSeconds: 300)
        // Account B must NEVER read Account A's private cache
        let readByB = try await cache.read([String].self, for: keyA, activeAccountID: "acct-B")
        #expect(readByB == nil)
        let readBKey = try await cache.read([String].self, for: keyB, activeAccountID: "acct-B")
        #expect(readBKey == nil)

        // Within maxStaleSeconds -> returns stale
        clock.advance(seconds: 120)
        let staleRead = try await cache.read([String].self, for: keyA, activeAccountID: "acct-A")
        #expect(staleRead?.isStale == true)
        #expect(staleRead?.value == ["song-a"])

        // Beyond maxStaleSeconds -> must NOT return expired private cache
        clock.advance(seconds: 250)
        let expiredRead = try await cache.read([String].self, for: keyA, activeAccountID: "acct-A")
        #expect(expiredRead == nil)

        // Stale session validator rejects write
        do {
            try await cache.write(["bad"], for: keyA, ttlSeconds: 60, maxStaleSeconds: 300) { false }
            #expect(Bool(false), "Expected staleSession error")
        } catch let err as CoreError {
            #expect(err == .staleSession)
        }

        // LRU eviction under disk budget
        for i in 0..<10 {
            let k = CacheKey(providerID: "apple_music", scope: .public, storefront: "cn", resource: "big_\(i)")
            try await cache.write(String(repeating: "z", count: 400), for: k, ttlSeconds: 60, maxStaleSeconds: 300)
        }
        #expect(try await cache.totalCachedBytes() <= 2048)
        await cache.close()
    }

    @Test func libraryRepositorySWRCircularCursorAndSearchGeneration() async throws {
        let dir = URL(fileURLWithPath: "/tmp/corev2_repo_\(UUID().uuidString)")
        let dbURL = dir.appendingPathComponent("repo.sqlite")
        defer { try? FileManager.default.removeItem(at: dir) }

        let clock = TestClock()
        let cache = SQLiteCacheStore(dbURL: dbURL, clock: clock)
        try await cache.open()

        let ctx = SessionContext(providerID: "apple_music", accountID: "acct-1", storefront: "cn", sessionID: UUID(), generation: 1)
        let snap = SessionSnapshot(
            context: ctx,
            sessionState: .authenticated,
            clientCredentialState: .available,
            userCredentialState: .available,
            subscriptionState: .active,
            catalogState: .available,
            engineState: .ready,
            account: nil
        )
        let coord = DummySessionValidator(snapshot: snap)
        let repo = LibraryRepositoryV2(cache: cache, sessionCoordinator: coord)

        let key = CacheKey(providerID: "apple_music", scope: .private, accountID: "acct-1", storefront: "cn", resource: "lib_songs")
        let outcome1 = await repo.load([String].self, key: key, ttlPolicy: .personalLibrary, sessionContext: ctx) {
            ["track1", "track2"]
        }
        if case .loaded(let val, let isStale, _) = outcome1 {
            #expect(val == ["track1", "track2"])
            #expect(!isStale)
        } else {
            #expect(Bool(false), "Expected loaded")
        }

        // Advance past TTL (300s) and inject network error -> must preserve allowed stale cache
        clock.advance(seconds: 400)
        let outcome2 = await repo.load([String].self, key: key, ttlPolicy: .personalLibrary, sessionContext: ctx) {
            throw CoreError.offline
        }
        if case .error(let err, let fallback) = outcome2 {
            #expect(err == .offline)
            #expect(fallback == ["track1", "track2"])
        } else {
            #expect(Bool(false), "Expected error with cached fallback")
        }

        // Circular cursor detection
        let paged = try await repo.fetchAllPages { cursor in
            if cursor == nil {
                return PaginatedPage(items: ["a", "b"], nextCursor: "c1")
            }
            return PaginatedPage(items: ["b", "c"], nextCursor: "c1") // circular cursor!
        }
        #expect(paged.items == ["a", "b", "c"])
        #expect(paged.completeness == .partial)

        await cache.close()
    }

    @Test func imageCacheCoalescesConcurrentRequestsByURLAndPixelSize() async throws {
        let dir = URL(fileURLWithPath: "/tmp/corev2_img_\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }

        let transport = MockHTTPTransport { req, _, _ in
            // Minimal 1x1 PNG bytes
            let pngBase64 = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
            let data = Data(base64Encoded: pngBase64)!
            return HTTPResponse(statusCode: 200, data: data, url: req.url)
        }
        let http = HTTPClient(transport: transport, clock: TestClock())
        let imgCache = ImageCacheV2(httpClient: http, diskDirectoryURL: dir)
        let url = URL(string: "https://example.com/cover.png")!

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<8 {
                group.addTask {
                    let img = await imgCache.image(for: url, targetPixelSize: 300)
                    #expect(img != nil)
                }
            }
        }
        #expect(await transport.callCount == 1)
    }
}
