import Testing
import Foundation
import SQLite3
@testable import Domain
@testable import Infrastructure
@testable import Providers

@Suite("VaultDatabaseLogTests")
struct VaultDatabaseLogTests {

    @Test func credentialVaultPersistsScopesPropagatesErrorsAndMigratesSafely() async throws {
        let store = FailingSecureStore()
        let vault = CredentialVault(store: store)

        let userRec = CredentialRecord(kind: .user, value: "user-val-a")
        try await vault.save(userRec, providerID: "apple_music", accountID: "acct-a")
        let loaded = try await vault.load(providerID: "apple_music", accountID: "acct-a", kind: .user)
        #expect(loaded?.value == "user-val-a")

        let otherLoaded = try await vault.load(providerID: "apple_music", accountID: "acct-b", kind: .user)
        #expect(otherLoaded == nil)

        try store.save("legacy-val", forKey: "old_key")
        store.failOnSave = KeychainError.unexpectedStatus(-25308)
        do {
            _ = try await vault.migrateLegacyKeyIfNeeded(
                legacyKey: "old_key",
                providerID: "apple_music",
                accountID: nil,
                kind: .client
            )
            #expect(Bool(false), "Expected storage error")
        } catch {
            #expect(store.exists(key: "old_key"))
        }

        store.failOnSave = nil
        let migrated = try await vault.migrateLegacyKeyIfNeeded(
            legacyKey: "old_key",
            providerID: "apple_music",
            accountID: nil,
            kind: .client
        )
        #expect(migrated == true)
        let clientLoaded = try await vault.load(providerID: "apple_music", accountID: nil, kind: .client)
        #expect(clientLoaded?.value == "legacy-val")
    }

    @Test func sqliteDatabaseSupportsMigrationsRollbackAndCorruptionRecovery() async throws {
        let tempDir = URL(fileURLWithPath: "/tmp/corev2_db_\(UUID().uuidString)")
        let dbURL = tempDir.appendingPathComponent("cache.sqlite")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let migrations = [
            SQLiteDatabase.Migration(version: 1, sql: "CREATE TABLE items (id TEXT PRIMARY KEY, val TEXT NOT NULL);")
        ]
        let db = SQLiteDatabase(dbURL: dbURL, migrations: migrations)
        try await db.open()
        #expect(try await db.userVersion() == 1)

        do {
            try await db.inTransaction { conn in
                try conn.execute("INSERT INTO items (id, val) VALUES ('k1', 'v1');")
                throw CoreError.storage("forced rollback")
            }
            #expect(Bool(false), "Expected forced error")
        } catch {}

        let countAfterRollback = try await db.query("SELECT COUNT(*) FROM items;") { Int(sqlite3_column_int64($0, 0)) }
        #expect(countAfterRollback.first == 0)
        await db.close()

        try Data("CORRUPT_HEADER_GARBAGE_BYTES".utf8).write(to: dbURL, options: .atomic)
        let recoveredDB = SQLiteDatabase(dbURL: dbURL, migrations: migrations)
        try await recoveredDB.open()
        #expect(await recoveredDB.didRecoverFromCorruption == true)
        #expect(try await recoveredDB.userVersion() == 1)
        await recoveredDB.close()
    }

    @Test func logSanitizerRedactsAndAppLoggerRotatesWithinBudget() throws {
        let clean = LogSanitizer.redact("Bearer sampleValue123")
        #expect(!clean.contains("sampleValue123"))

        let logDir = URL(fileURLWithPath: "/tmp/corev2_logs_\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: logDir) }

        let logger = AppLogger(logDirectoryURL: logDir, maxFileBytes: 1024, maxRotatedFiles: 2)
        for i in 0..<40 {
            logger.log(category: .network, level: .info, correlationID: "req-\(i)", message: String(repeating: "x", count: 80))
        }

        let files = try FileManager.default.contentsOfDirectory(at: logDir, includingPropertiesForKeys: [.fileSizeKey])
        #expect(files.count <= 3)
    }

    @Test func originValidatorAndWebBridgeParserEnforceBoundaries() {
        #expect(OriginValidator.isAllowedHost("music.apple.com"))
        #expect(OriginValidator.isAllowedHost("amp-api.music.apple.com"))
        #expect(!OriginValidator.isAllowedHost("apple.com.invalid"))
        #expect(!OriginValidator.isAllowedHost("notapple.com"))
        #expect(OriginValidator.isAllowedCookieDomain(".music.apple.com"))
        #expect(!OriginValidator.isAllowedCookieDomain(".invalid.org"))
        #expect(OriginValidator.isAllowedScriptOrigin(protocol: "https", host: "music.apple.com", isMainFrame: true))
        #expect(!OriginValidator.isAllowedScriptOrigin(protocol: "https", host: "music.apple.com", isMainFrame: false))

        let activeID = UUID()
        let staleID = UUID()
        #expect(WebBridgeParser.parse(body: "invalid", expectedEngineID: activeID) == nil)
        let stalePayload: [String: Any] = [
            "event": "playbackEnded",
            "engineInstanceID": staleID.uuidString,
            "operationID": 5,
            "currentPlaybackTime": 180.0,
            "currentPlaybackDuration": 180.0
        ]
        #expect(WebBridgeParser.parse(body: stalePayload, expectedEngineID: activeID) == nil)

        let validPayload: [String: Any] = [
            "event": "playbackStateDidChange",
            "engineInstanceID": activeID.uuidString,
            "operationID": 7,
            "playbackState": 2,
            "isPlaying": true,
            "isBuffering": false,
            "isPaused": false
        ]
        #expect(WebBridgeParser.parse(body: validPayload, expectedEngineID: activeID) == .playbackStateDidChange(
            engineInstanceID: activeID,
            operationID: 7,
            rawState: 2,
            isPlaying: true,
            isBuffering: false,
            isPaused: false
        ))
    }
}
