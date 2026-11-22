// Sources/Infrastructure/SQLiteStore.swift
// AirMuse macOS – SQLite3 wrapper for lyrics cache, play history and settings
// All DB access runs on a dedicated SerialExecutor (background thread).

import Foundation
import SQLite3

// MARK: - Errors

public enum SQLiteError: Error, Sendable {
    case openFailed(String)
    case prepareFailed(String)
    case stepFailed(String)
    case bindFailed(String)
}

// MARK: - SQLiteStore Actor

/// A background actor that owns a single SQLite connection.
/// All public methods are automatically serialised by the actor executor.
public actor SQLiteStore {

    // ── State ──────────────────────────────────────────────────────────────
    private var db: OpaquePointer?
    private let dbURL: URL

    // ── Lifecycle ──────────────────────────────────────────────────────────

    public init(dbURL: URL) {
        self.dbURL = dbURL
    }

    /// Open (or create) the database and migrate schema.
    public func open() throws {
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        var handle: OpaquePointer?
        let rc = sqlite3_open_v2(dbURL.path, &handle, flags, nil)
        guard rc == SQLITE_OK, let h = handle else {
            let msg = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            throw SQLiteError.openFailed(msg)
        }
        db = h
        sqlite3_exec(h, "PRAGMA journal_mode=WAL;", nil, nil, nil)
        sqlite3_exec(h, "PRAGMA foreign_keys=ON;", nil, nil, nil)
        try createSchema()
        AppLogger.shared.log(category: .database, level: .info, message: "SQLite 数据库引擎就绪 (WAL模式): \(dbURL.lastPathComponent)")
    }

    /// Close the database.
    public func close() {
        guard let h = db else { return }
        sqlite3_close_v2(h)
        db = nil
    }

    // ── Schema ─────────────────────────────────────────────────────────────

    private func createSchema() throws {
        let ddl = """
        CREATE TABLE IF NOT EXISTS lyrics_cache (
            track_key   TEXT NOT NULL PRIMARY KEY,
            lrc_text    TEXT NOT NULL,
            offset_ms   INTEGER NOT NULL DEFAULT 0,
            fetched_at  INTEGER NOT NULL,
            source      TEXT
        );

        CREATE TABLE IF NOT EXISTS play_history (
            id          INTEGER PRIMARY KEY AUTOINCREMENT,
            track_id    TEXT NOT NULL,
            title       TEXT NOT NULL,
            artist      TEXT NOT NULL,
            played_at   INTEGER NOT NULL,
            duration_ms INTEGER NOT NULL DEFAULT 0
        );

        CREATE INDEX IF NOT EXISTS idx_play_history_played_at ON play_history(played_at DESC);

        CREATE TABLE IF NOT EXISTS user_settings (
            key         TEXT NOT NULL PRIMARY KEY,
            value       TEXT NOT NULL
        );
        """
        guard let h = db else { return }
        var errMsg: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(h, ddl, nil, nil, &errMsg)
        if rc != SQLITE_OK {
            let msg = errMsg.map { String(cString: $0) } ?? "unknown"
            sqlite3_free(errMsg)
            throw SQLiteError.stepFailed(msg)
        }
    }

    // MARK: - Lyrics Cache

    /// Store raw LRC text for a track.
    public func saveLyrics(trackKey: String, lrcText: String, offsetMs: Int64 = 0, source: String? = nil) throws {
        let sql = """
        INSERT OR REPLACE INTO lyrics_cache (track_key, lrc_text, offset_ms, fetched_at, source)
        VALUES (?, ?, ?, ?, ?);
        """
        try execute(sql: sql) { stmt in
            sqlite3_bind_text(stmt, 1, trackKey, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 2, lrcText, -1, SQLITE_TRANSIENT)
            sqlite3_bind_int64(stmt, 3, offsetMs)
            sqlite3_bind_int64(stmt, 4, Int64(Date.now.timeIntervalSince1970))
            if let src = source {
                sqlite3_bind_text(stmt, 5, src, -1, SQLITE_TRANSIENT)
            } else {
                sqlite3_bind_null(stmt, 5)
            }
        }
    }

    /// Load cached LRC for a track, returning nil if not found.
    public func loadLyrics(trackKey: String) throws -> (lrcText: String, offsetMs: Int64)? {
        let sql = "SELECT lrc_text, offset_ms FROM lyrics_cache WHERE track_key = ? LIMIT 1;"
        return try query(sql: sql, bind: { stmt in
            sqlite3_bind_text(stmt, 1, trackKey, -1, SQLITE_TRANSIENT)
        }, map: { stmt -> (String, Int64) in
            let text = String(cString: sqlite3_column_text(stmt, 0))
            let offset = sqlite3_column_int64(stmt, 1)
            return (text, offset)
        }).first
    }

    /// Delete stale lyrics entries older than `days`.
    public func pruneLyricsCache(olderThanDays days: Int) throws {
        let cutoff = Int64(Date.now.timeIntervalSince1970) - Int64(days * 86400)
        try execute(sql: "DELETE FROM lyrics_cache WHERE fetched_at < ?;") { stmt in
            sqlite3_bind_int64(stmt, 1, cutoff)
        }
    }

    // MARK: - Play History

    public func recordPlay(trackID: String, title: String, artist: String, durationMs: Int64) throws {
        let sql = """
        INSERT INTO play_history (track_id, title, artist, played_at, duration_ms)
        VALUES (?, ?, ?, ?, ?);
        """
        try execute(sql: sql) { stmt in
            sqlite3_bind_text(stmt, 1, trackID, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 2, title, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 3, artist, -1, SQLITE_TRANSIENT)
            sqlite3_bind_int64(stmt, 4, Int64(Date.now.timeIntervalSince1970))
            sqlite3_bind_int64(stmt, 5, durationMs)
        }
    }

    public func recentPlays(limit: Int = 50) throws -> [(trackID: String, title: String, artist: String, playedAt: Date)] {
        let sql = "SELECT track_id, title, artist, played_at FROM play_history ORDER BY played_at DESC LIMIT ?;"
        return try query(sql: sql, bind: { stmt in
            sqlite3_bind_int64(stmt, 1, Int64(limit))
        }, map: { stmt in
            let tid  = String(cString: sqlite3_column_text(stmt, 0))
            let title = String(cString: sqlite3_column_text(stmt, 1))
            let artist = String(cString: sqlite3_column_text(stmt, 2))
            let ts = sqlite3_column_int64(stmt, 3)
            return (tid, title, artist, Date(timeIntervalSince1970: TimeInterval(ts)))
        })
    }

    // MARK: - User Settings

    public func saveSetting(key: String, value: String) throws {
        try execute(sql: "INSERT OR REPLACE INTO user_settings (key, value) VALUES (?, ?);") { stmt in
            sqlite3_bind_text(stmt, 1, key, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 2, value, -1, SQLITE_TRANSIENT)
        }
    }

    public func loadSetting(key: String) throws -> String? {
        let sql = "SELECT value FROM user_settings WHERE key = ? LIMIT 1;"
        return try query(sql: sql, bind: { stmt in
            sqlite3_bind_text(stmt, 1, key, -1, SQLITE_TRANSIENT)
        }, map: { stmt -> String in
            String(cString: sqlite3_column_text(stmt, 0))
        }).first
    }

    // MARK: - Helpers

    private func execute(sql: String, bind: (OpaquePointer) -> Void) throws {
        guard let h = db else { return }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(h, sql, -1, &stmt, nil) == SQLITE_OK, let s = stmt else {
            throw SQLiteError.prepareFailed(String(cString: sqlite3_errmsg(h)))
        }
        defer { sqlite3_finalize(s) }
        bind(s)
        let rc = sqlite3_step(s)
        guard rc == SQLITE_DONE || rc == SQLITE_ROW else {
            throw SQLiteError.stepFailed(String(cString: sqlite3_errmsg(h)))
        }
    }

    private func query<T>(
        sql: String,
        bind: (OpaquePointer) -> Void,
        map: (OpaquePointer) -> T
    ) throws -> [T] {
        guard let h = db else { return [] }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(h, sql, -1, &stmt, nil) == SQLITE_OK, let s = stmt else {
            throw SQLiteError.prepareFailed(String(cString: sqlite3_errmsg(h)))
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

// MARK: - SQLITE_TRANSIENT helper
private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
