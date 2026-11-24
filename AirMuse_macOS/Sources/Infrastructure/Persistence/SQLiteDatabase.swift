import Foundation
import SQLite3
import Domain

// MARK: - SQLiteDatabase

/// Actor-isolated SQLite database engine supporting versioned migrations,
/// atomic transactions (`BEGIN IMMEDIATE`), and automatic corruption recovery
/// for regenerable cache storage.
public actor SQLiteDatabase {
    public struct Migration: Sendable {
        public let version: Int32
        public let sql: String

        public init(version: Int32, sql: String) {
            self.version = version
            self.sql = sql
        }
    }

    private var db: OpaquePointer?
    public let dbURL: URL
    private let migrations: [Migration]
    public private(set) var didRecoverFromCorruption: Bool = false

    public init(dbURL: URL, migrations: [Migration] = []) {
        self.dbURL = dbURL
        self.migrations = migrations.sorted { $0.version < $1.version }
    }

    public func open() throws {
        if db != nil { return }
        let dir = dbURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        do {
            try openAndMigrate()
        } catch let err as CoreError where isCorruptionError(err) {
            quarantineCorruptFile()
            didRecoverFromCorruption = true
            try openAndMigrate()
        }
    }

    public func close() {
        guard let h = db else { return }
        sqlite3_close_v2(h)
        db = nil
    }

    public func userVersion() throws -> Int32 {
        let h = try requireHandle()
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(h, "PRAGMA user_version;", -1, &stmt, nil) == SQLITE_OK, let s = stmt else {
            throw CoreError.storage("PRAGMA user_version prepare failed: \(lastErrorMessage(h))")
        }
        defer { sqlite3_finalize(s) }
        guard sqlite3_step(s) == SQLITE_ROW else {
            throw CoreError.storage("PRAGMA user_version step failed: \(lastErrorMessage(h))")
        }
        return sqlite3_column_int(s, 0)
    }

    public func inTransaction<T>(_ body: (SQLiteConnection) throws -> T) throws -> T {
        let h = try requireHandle()
        try execRaw(h, sql: "BEGIN IMMEDIATE;")
        do {
            let conn = SQLiteConnection(handle: h)
            let result = try body(conn)
            try execRaw(h, sql: "COMMIT;")
            return result
        } catch {
            try? execRaw(h, sql: "ROLLBACK;")
            throw error
        }
    }

    public func execute(_ sql: String, bind: (OpaquePointer) -> Void = { _ in }) throws {
        let h = try requireHandle()
        try SQLiteConnection(handle: h).execute(sql, bind: bind)
    }

    public func query<T>(
        _ sql: String,
        bind: (OpaquePointer) -> Void = { _ in },
        map: (OpaquePointer) -> T
    ) throws -> [T] {
        let h = try requireHandle()
        return try SQLiteConnection(handle: h).query(sql, bind: bind, map: map)
    }

    // MARK: - Internal Open & Migration

    private func openAndMigrate() throws {
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        var handle: OpaquePointer?
        let rc = sqlite3_open_v2(dbURL.path, &handle, flags, nil)
        guard rc == SQLITE_OK, let h = handle else {
            let msg = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "open error \(rc)"
            if let handle { sqlite3_close_v2(handle) }
            throw CoreError.storage("SQLite open failed (\(rc)): \(msg)")
        }
        db = h

        do {
            try execRaw(h, sql: "PRAGMA journal_mode=WAL;")
            try execRaw(h, sql: "PRAGMA foreign_keys=ON;")
            try execRaw(h, sql: "PRAGMA synchronous=NORMAL;")

            let integrity = try SQLiteConnection(handle: h).query("PRAGMA quick_check(1);") { stmt in
                String(cString: sqlite3_column_text(stmt, 0))
            }
            if integrity.first?.lowercased() != "ok" {
                throw CoreError.storage("SQLITE_CORRUPT: quick_check returned \(integrity.first ?? "unknown")")
            }

            let currentVersion = try userVersion()
            for migration in migrations where migration.version > currentVersion {
                try inTransaction { conn in
                    try conn.execBatch(migration.sql)
                    try conn.execBatch("PRAGMA user_version = \(migration.version);")
                }
            }
        } catch {
            sqlite3_close_v2(h)
            db = nil
            throw error
        }
    }

    private func requireHandle() throws -> OpaquePointer {
        guard let h = db else {
            throw CoreError.storage("SQLiteDatabase is not open")
        }
        return h
    }

    private func execRaw(_ h: OpaquePointer, sql: String) throws {
        var errMsg: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(h, sql, nil, nil, &errMsg)
        if rc != SQLITE_OK {
            let msg = errMsg.map { String(cString: $0) } ?? lastErrorMessage(h)
            sqlite3_free(errMsg)
            throw CoreError.storage("SQLite exec failed (\(rc)): \(msg)")
        }
    }

    private func lastErrorMessage(_ h: OpaquePointer) -> String {
        String(cString: sqlite3_errmsg(h))
    }

    private func isCorruptionError(_ err: CoreError) -> Bool {
        if case .storage(let msg) = err {
            let upper = msg.uppercased()
            return upper.contains("CORRUPT") || upper.contains("NOTADB") || upper.contains("(26)") || upper.contains("(11)")
        }
        return false
    }

    private func quarantineCorruptFile() {
        let fm = FileManager.default
        let suffix = ".corrupt.\(Int(Date().timeIntervalSince1970))"
        let backupURL = URL(fileURLWithPath: dbURL.path + suffix)
        try? fm.moveItem(at: dbURL, to: backupURL)
        try? fm.removeItem(atPath: dbURL.path + "-wal")
        try? fm.removeItem(atPath: dbURL.path + "-shm")
    }
}

// MARK: - SQLiteConnection

public struct SQLiteConnection {
    private let handle: OpaquePointer

    init(handle: OpaquePointer) {
        self.handle = handle
    }

    public func execBatch(_ sql: String) throws {
        var errMsg: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(handle, sql, nil, nil, &errMsg)
        if rc != SQLITE_OK {
            let msg = errMsg.map { String(cString: $0) } ?? String(cString: sqlite3_errmsg(handle))
            sqlite3_free(errMsg)
            throw CoreError.storage("SQLite batch exec failed (\(rc)): \(msg)")
        }
    }

    public func execute(_ sql: String, bind: (OpaquePointer) -> Void = { _ in }) throws {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &stmt, nil) == SQLITE_OK, let s = stmt else {
            throw CoreError.storage("SQLite prepare failed: \(String(cString: sqlite3_errmsg(handle)))")
        }
        defer { sqlite3_finalize(s) }
        bind(s)
        let rc = sqlite3_step(s)
        guard rc == SQLITE_DONE || rc == SQLITE_ROW else {
            throw CoreError.storage("SQLite step failed (\(rc)): \(String(cString: sqlite3_errmsg(handle)))")
        }
    }

    public func query<T>(
        _ sql: String,
        bind: (OpaquePointer) -> Void = { _ in },
        map: (OpaquePointer) -> T
    ) throws -> [T] {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &stmt, nil) == SQLITE_OK, let s = stmt else {
            throw CoreError.storage("SQLite prepare failed: \(String(cString: sqlite3_errmsg(handle)))")
        }
        defer { sqlite3_finalize(s) }
        bind(s)
        var results: [T] = []
        while sqlite3_step(s) == SQLITE_ROW {
            results.append(map(s))
        }
        return results
    }
}

public let sqliteTransientDestructor = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
