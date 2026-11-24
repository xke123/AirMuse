import Foundation
import SQLite3
import Domain
import Playback
import Infrastructure

// MARK: - LyricsRepositoryV2

/// Core V2 lyrics repository backed by SQLite persistence (`lyrics_cache_v2`).
/// Keys lyrics by `(trackKey, source)`, persists user time offsets across restarts,
/// never blocks audio playback, and prevents stale track fetches from overwriting newer tracks.
public actor LyricsRepositoryV2 {
    private let store: PlaybackStore
    private let db: SQLiteDatabase
    private var providers: [any MusicLyricsProvider] = []
    private var activeTrackKey: String?
    private var fetchTasks: [String: Task<Void, Never>] = [:]
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public static let migrations: [SQLiteDatabase.Migration] = [
        SQLiteDatabase.Migration(
            version: 1,
            sql: """
            CREATE TABLE IF NOT EXISTS lyrics_cache_v2 (
                track_key TEXT NOT NULL,
                source TEXT NOT NULL,
                fetched_at INTEGER NOT NULL,
                payload BLOB NOT NULL,
                PRIMARY KEY (track_key, source)
            );
            CREATE TABLE IF NOT EXISTS lyrics_offsets_v2 (
                track_key TEXT PRIMARY KEY,
                offset_ms INTEGER NOT NULL DEFAULT 0
            );
            """
        )
    ]

    public init(store: PlaybackStore, dbURL: URL) {
        self.store = store
        self.db = SQLiteDatabase(dbURL: dbURL, migrations: Self.migrations)
    }

    public func open() async throws {
        try await db.open()
    }

    public func close() async {
        for task in fetchTasks.values { task.cancel() }
        fetchTasks.removeAll()
        await db.close()
    }

    public func register(provider: any MusicLyricsProvider) {
        providers.append(provider)
    }

    public func requestLyrics(for track: MusicTrack) async {
        let key = track.trackKey
        activeTrackKey = key

        let savedOffset = await loadOffset(trackKey: key)
        if var cached = await loadCachedDocument(trackKey: key) {
            cached.offsetMs = savedOffset
            guard activeTrackKey == key else { return }
            await store.update(lyrics: cached)
            return
        }

        fetchTasks[key]?.cancel()
        let loading = LyricsDocument(trackKey: key, isLoading: true, statusText: "加载歌词中…")
        await store.update(lyrics: loading)

        fetchTasks[key] = Task { [weak self] in
            await self?.fetchAndPersist(track: track)
        }
    }

    public func adjustOffset(trackKey: String, deltaMs: Int64) async {
        let updated = await loadOffset(trackKey: trackKey) + deltaMs
        try? await db.execute(
            "INSERT OR REPLACE INTO lyrics_offsets_v2 (track_key, offset_ms) VALUES (?, ?);"
        ) { stmt in
            sqlite3_bind_text(stmt, 1, trackKey, -1, sqliteTransientDestructor)
            sqlite3_bind_int64(stmt, 2, updated)
        }
        if activeTrackKey == trackKey, var doc = await loadCachedDocument(trackKey: trackKey) {
            doc.offsetMs = updated
            await store.update(lyrics: doc)
        }
    }

    // MARK: - Private

    private func fetchAndPersist(track: MusicTrack) async {
        let key = track.trackKey
        defer { fetchTasks.removeValue(forKey: key) }

        for provider in providers {
            guard !Task.isCancelled, activeTrackKey == key else { return }
            do {
                if var doc = try await provider.fetchLyrics(for: track), !doc.lines.isEmpty {
                    let source = provider.providerID
                    await saveCachedDocument(doc, trackKey: key, source: source)
                    guard !Task.isCancelled, activeTrackKey == key else { return }
                    doc.offsetMs = await loadOffset(trackKey: key)
                    await store.update(lyrics: doc)
                    return
                }
            } catch {
                continue
            }
        }

        guard !Task.isCancelled, activeTrackKey == key else { return }
        let empty = LyricsDocument(trackKey: key, statusText: "暂无歌词")
        await store.update(lyrics: empty)
    }

    private func loadOffset(trackKey: String) async -> Int64 {
        let rows: [Int64]? = try? await db.query(
            "SELECT offset_ms FROM lyrics_offsets_v2 WHERE track_key = ? LIMIT 1;",
            bind: { stmt in
                sqlite3_bind_text(stmt, 1, trackKey, -1, sqliteTransientDestructor)
            },
            map: { sqlite3_column_int64($0, 0) }
        )
        return rows?.first ?? 0
    }

    private func loadCachedDocument(trackKey: String) async -> LyricsDocument? {
        let rows: [Data]? = try? await db.query(
            "SELECT payload FROM lyrics_cache_v2 WHERE track_key = ? ORDER BY fetched_at DESC LIMIT 1;",
            bind: { stmt in
                sqlite3_bind_text(stmt, 1, trackKey, -1, sqliteTransientDestructor)
            },
            map: { stmt in
                let ptr = sqlite3_column_blob(stmt, 0)
                let len = Int(sqlite3_column_bytes(stmt, 0))
                return ptr.map { Data(bytes: $0, count: len) } ?? Data()
            }
        )
        guard let data = rows?.first, !data.isEmpty else { return nil }
        return try? decoder.decode(LyricsDocument.self, from: data)
    }

    private func saveCachedDocument(_ doc: LyricsDocument, trackKey: String, source: String) async {
        guard let data = try? encoder.encode(doc) else { return }
        let nowSec = Int64(Date().timeIntervalSince1970)
        try? await db.inTransaction { conn in
            try conn.execute(
                "INSERT OR REPLACE INTO lyrics_cache_v2 (track_key, source, fetched_at, payload) VALUES (?, ?, ?, ?);"
            ) { stmt in
                sqlite3_bind_text(stmt, 1, trackKey, -1, sqliteTransientDestructor)
                sqlite3_bind_text(stmt, 2, source, -1, sqliteTransientDestructor)
                sqlite3_bind_int64(stmt, 3, nowSec)
                _ = data.withUnsafeBytes { rawBuf in
                    sqlite3_bind_blob(stmt, 4, rawBuf.baseAddress, Int32(data.count), sqliteTransientDestructor)
                }
            }
        }
    }
}
