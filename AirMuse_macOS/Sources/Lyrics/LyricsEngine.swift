import Foundation
import Domain
import Playback
import Infrastructure

// MARK: - LyricsEngine

/// Actor-isolated engine that fetches, caches, and delivers timed lyrics.
/// Corresponds to airmuse::LyricsEngine on the Windows side.
public actor LyricsEngine {

    private let store: PlaybackStore
    private var cache: [String: LyricsDocument] = [:]
    private var offsets: [String: Int64] = [:]
    private var fetchTasks: [String: Task<Void, Never>] = [:]
    private var providers: [any MusicLyricsProvider] = []

    public init(store: PlaybackStore) {
        self.store = store
    }

    // MARK: - Provider registration

    public func register(provider: any MusicLyricsProvider) {
        providers.append(provider)
    }

    // MARK: - Playback Stream Observation

    public func startObserving() {
        Task { [weak self] in
            guard let self else { return }
            let stream = await self.store.playbackStream()
            var lastTrackKey: String? = nil
            for await state in stream {
                guard let track = state.currentTrack else { continue }
                if track.trackKey != lastTrackKey {
                    lastTrackKey = track.trackKey
                    await self.requestLyrics(for: track)
                }
            }
        }
    }

    // MARK: - Fetch

    public func requestLyrics(for track: MusicTrack) {
        let key = track.trackKey

        // Return cache immediately if available.
        if var cached = cache[key] {
            cached.offsetMs = offsets[key] ?? 0
            AppLogger.shared.log(category: .cache, level: .info, message: "【歌词缓存命中】使用内存缓存歌词: \(track.title) (\(cached.lines.count) 行)")
            Task { await self.store.update(lyrics: cached) }
            return
        }

        // Cancel any in-flight fetch for this key.
        fetchTasks[key]?.cancel()

        // Emit loading state.
        let loading = LyricsDocument(trackKey: key, isLoading: true, statusText: "加载歌词中…")
        Task { await self.store.update(lyrics: loading) }

        // Kick off fetch.
        let task = Task { [weak self] in
            guard let self else { return }
            await self.fetch(track: track)
        }
        fetchTasks[key] = task
    }

    public func adjustOffset(trackKey: String, deltaMs: Int64) async {
        let current = offsets[trackKey] ?? 0
        let newOffset = current + deltaMs
        offsets[trackKey] = newOffset
        AppLogger.shared.log(category: .userAction, level: .info, message: "用户调整歌词同步偏移: 增量 \(deltaMs)ms -> 总偏移 \(newOffset)ms (\(trackKey))")
        if var doc = cache[trackKey] {
            doc.offsetMs = newOffset
            await store.update(lyrics: doc)
        }
    }

    // MARK: - Private

    private func fetch(track: MusicTrack) async {
        let key = track.trackKey
        for provider in providers {
            guard !Task.isCancelled else { return }
            do {
                if let doc = try await provider.fetchLyrics(for: track) {
                    var result = doc
                    result.offsetMs = offsets[key] ?? 0
                    cache[key] = result
                    fetchTasks.removeValue(forKey: key)
                    await store.update(lyrics: result)
                    return
                }
            } catch {
                // Try next provider.
                continue
            }
        }
        // No provider succeeded.
        let empty = LyricsDocument(trackKey: key, statusText: "暂无歌词")
        cache[key] = empty
        fetchTasks.removeValue(forKey: key)
        await store.update(lyrics: empty)
    }
}
