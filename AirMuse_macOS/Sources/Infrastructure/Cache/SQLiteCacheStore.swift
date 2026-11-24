import Foundation
import SQLite3
import Domain

// MARK: - CacheScope & CacheKey

public enum CacheScope: String, Sendable, Equatable {
    case `public` = "pub"
    case `private` = "priv"
}

public enum CacheCompleteness: String, Sendable, Codable, Equatable {
    case complete
    case partial
}

public struct CacheKey: Sendable, Equatable, Hashable {
    public let providerID: String
    public let scope: CacheScope
    public let accountID: String?
    public let storefront: String
    public let resource: String
    public let normalizedParameters: String
    public let schemaVersion: Int

    public init(
        providerID: String,
        scope: CacheScope,
        accountID: String? = nil,
        storefront: String,
        resource: String,
        normalizedParameters: String = "",
        schemaVersion: Int = 1
    ) {
        self.providerID = providerID
        self.scope = scope
        self.accountID = (scope == .private) ? accountID : nil
        self.storefront = storefront
        self.resource = resource
        self.normalizedParameters = normalizedParameters
        self.schemaVersion = schemaVersion
    }

    public var rawKey: String {
        let acct = accountID ?? "_"
        return "\(providerID)|\(scope.rawValue)|\(acct)|\(storefront)|\(resource)|\(normalizedParameters)|v\(schemaVersion)"
    }
}

public struct CacheReadResult<T: Sendable>: Sendable {
    public let value: T
    public let isFresh: Bool
    public let isStale: Bool
    public let fetchedAt: Date
    public let completeness: CacheCompleteness
}

// MARK: - SQLiteCacheStore

/// Namespaced, TTL/max-stale-enforcing, LRU-bounded SQLite cache store.
/// Strictly partitions private data by `(providerID, accountID, storefront)` and
/// validates session context atomically before committing private writes.
public actor SQLiteCacheStore {
    private let db: SQLiteDatabase
    private let clock: any ClockProtocol
    private let maxDiskBytes: Int
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public static let defaultMigrations: [SQLiteDatabase.Migration] = [
        SQLiteDatabase.Migration(
            version: 1,
            sql: """
            CREATE TABLE IF NOT EXISTS cache_entries (
                cache_key TEXT PRIMARY KEY,
                provider_id TEXT NOT NULL,
                scope TEXT NOT NULL,
                account_id TEXT,
                storefront TEXT NOT NULL,
                fetched_at INTEGER NOT NULL,
                expires_at INTEGER NOT NULL,
                max_stale_at INTEGER NOT NULL,
                last_accessed_at INTEGER NOT NULL,
                completeness TEXT NOT NULL,
                byte_size INTEGER NOT NULL,
                payload BLOB NOT NULL
            );
            CREATE INDEX IF NOT EXISTS idx_cache_account ON cache_entries(provider_id, account_id);
            CREATE INDEX IF NOT EXISTS idx_cache_lru ON cache_entries(last_accessed_at ASC);
            """
        )
    ]

    public init(
        dbURL: URL,
        clock: any ClockProtocol = SystemClock(),
        maxDiskBytes: Int = 100 * 1024 * 1024
    ) {
        self.db = SQLiteDatabase(dbURL: dbURL, migrations: Self.defaultMigrations)
        self.clock = clock
        self.maxDiskBytes = max(1024, maxDiskBytes)
    }

    public func open() async throws {
        try await db.open()
    }

    public func close() async {
        await db.close()
    }

    public func read<T: Decodable & Sendable>(
        _ type: T.Type,
        for key: CacheKey,
        activeAccountID: String?
    ) async throws -> CacheReadResult<T>? {
        if key.scope == .private {
            guard let keyAcct = key.accountID, !keyAcct.isEmpty, keyAcct == activeAccountID else {
                return nil
            }
        }

        let nowSec = Int64(clock.now.timeIntervalSince1970)
        let rawKey = key.rawKey

        let rows: [(Int64, Int64, Int64, String, Data)] = try await db.query(
            "SELECT fetched_at, expires_at, max_stale_at, completeness, payload FROM cache_entries WHERE cache_key = ? LIMIT 1;",
            bind: { stmt in
                sqlite3_bind_text(stmt, 1, rawKey, -1, sqliteTransientDestructor)
            },
            map: { stmt in
                let fetched = sqlite3_column_int64(stmt, 0)
                let expires = sqlite3_column_int64(stmt, 1)
                let maxStale = sqlite3_column_int64(stmt, 2)
                let comp = String(cString: sqlite3_column_text(stmt, 3))
                let bytesPtr = sqlite3_column_blob(stmt, 4)
                let byteLen = Int(sqlite3_column_bytes(stmt, 4))
                let data = bytesPtr.map { Data(bytes: $0, count: byteLen) } ?? Data()
                return (fetched, expires, maxStale, comp, data)
            }
        )

        guard let row = rows.first else { return nil }
        let (fetchedSec, expiresSec, maxStaleSec, compStr, data) = row

        // Never serve entries beyond maxStaleAt (especially private caches)
        if nowSec > maxStaleSec {
            try? await db.execute("DELETE FROM cache_entries WHERE cache_key = ?;") { stmt in
                sqlite3_bind_text(stmt, 1, rawKey, -1, sqliteTransientDestructor)
            }
            return nil
        }

        guard let decoded = try? decoder.decode(T.self, from: data) else {
            return nil
        }

        try? await db.execute("UPDATE cache_entries SET last_accessed_at = ? WHERE cache_key = ?;") { stmt in
            sqlite3_bind_int64(stmt, 1, nowSec)
            sqlite3_bind_text(stmt, 2, rawKey, -1, sqliteTransientDestructor)
        }

        let isFresh = nowSec <= expiresSec
        return CacheReadResult(
            value: decoded,
            isFresh: isFresh,
            isStale: !isFresh,
            fetchedAt: Date(timeIntervalSince1970: TimeInterval(fetchedSec)),
            completeness: CacheCompleteness(rawValue: compStr) ?? .complete
        )
    }

    public func write<T: Encodable & Sendable>(
        _ value: T,
        for key: CacheKey,
        ttlSeconds: TimeInterval,
        maxStaleSeconds: TimeInterval,
        completeness: CacheCompleteness = .complete,
        sessionValidator: (@Sendable () async -> Bool)? = nil
    ) async throws {
        if key.scope == .private {
            guard key.accountID?.isEmpty == false else {
                throw CoreError.staleSession
            }
        }
        if let validator = sessionValidator {
            let valid = await validator()
            guard valid else { throw CoreError.staleSession }
        }

        let data = try encoder.encode(value)
        let nowSec = Int64(clock.now.timeIntervalSince1970)
        let expiresSec = nowSec + Int64(max(0, ttlSeconds))
        let maxStaleSec = nowSec + Int64(max(ttlSeconds, maxStaleSeconds))

        // Re-check session validity immediately before synchronous DB transaction commit
        if let validator = sessionValidator {
            let valid = await validator()
            guard valid else { throw CoreError.staleSession }
        }

        try await db.inTransaction { conn in
            let sql = """
            INSERT OR REPLACE INTO cache_entries
            (cache_key, provider_id, scope, account_id, storefront, fetched_at, expires_at, max_stale_at, last_accessed_at, completeness, byte_size, payload)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
            """
            try conn.execute(sql) { stmt in
                sqlite3_bind_text(stmt, 1, key.rawKey, -1, sqliteTransientDestructor)
                sqlite3_bind_text(stmt, 2, key.providerID, -1, sqliteTransientDestructor)
                sqlite3_bind_text(stmt, 3, key.scope.rawValue, -1, sqliteTransientDestructor)
                if let acct = key.accountID {
                    sqlite3_bind_text(stmt, 4, acct, -1, sqliteTransientDestructor)
                } else {
                    sqlite3_bind_null(stmt, 4)
                }
                sqlite3_bind_text(stmt, 5, key.storefront, -1, sqliteTransientDestructor)
                sqlite3_bind_int64(stmt, 6, nowSec)
                sqlite3_bind_int64(stmt, 7, expiresSec)
                sqlite3_bind_int64(stmt, 8, maxStaleSec)
                sqlite3_bind_int64(stmt, 9, nowSec)
                sqlite3_bind_text(stmt, 10, completeness.rawValue, -1, sqliteTransientDestructor)
                sqlite3_bind_int64(stmt, 11, Int64(data.count))
                _ = data.withUnsafeBytes { rawBuf in
                    sqlite3_bind_blob(stmt, 12, rawBuf.baseAddress, Int32(data.count), sqliteTransientDestructor)
                }
            }
        }

        try? await evictIfOverBudget()
    }

    public func clearAccount(providerID: String, accountID: String) async throws {
        try await db.execute(
            "DELETE FROM cache_entries WHERE provider_id = ? AND scope = 'priv' AND account_id = ?;"
        ) { stmt in
            sqlite3_bind_text(stmt, 1, providerID, -1, sqliteTransientDestructor)
            sqlite3_bind_text(stmt, 2, accountID, -1, sqliteTransientDestructor)
        }
    }

    public func totalCachedBytes() async throws -> Int {
        let rows = try await db.query("SELECT COALESCE(SUM(byte_size), 0) FROM cache_entries;") { stmt in
            Int(sqlite3_column_int64(stmt, 0))
        }
        return rows.first ?? 0
    }

    private func evictIfOverBudget() async throws {
        let initialTotal = try await totalCachedBytes()
        let budget = maxDiskBytes
        if initialTotal <= budget { return }

        let candidates: [(String, Int)] = try await db.query(
            "SELECT cache_key, byte_size FROM cache_entries ORDER BY last_accessed_at ASC LIMIT 64;"
        ) { stmt in
            let k = String(cString: sqlite3_column_text(stmt, 0))
            let b = Int(sqlite3_column_int64(stmt, 1))
            return (k, b)
        }

        try await db.inTransaction { conn in
            var runningTotal = initialTotal
            for (k, bytes) in candidates {
                if runningTotal <= budget { break }
                try conn.execute("DELETE FROM cache_entries WHERE cache_key = ?;") { stmt in
                    sqlite3_bind_text(stmt, 1, k, -1, sqliteTransientDestructor)
                }
                runningTotal -= bytes
            }
        }
    }
}
