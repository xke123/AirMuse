// Sources/Providers/AppleMusic/AppleMusicProvider.swift
// AirMuse macOS – Apple Music provider via MusicKit
// Swift 6 strict concurrency

import Foundation
import MusicKit
import Domain
import Infrastructure

public typealias MusicTrack = Domain.MusicTrack

// MARK: - Errors

public enum AppleMusicError: Error, Sendable {
    case notAuthorized
    case requiresSubscription
    case searchFailed(String)
    case playbackFailed(String)
    case lyricsNotAvailable
}

// MARK: - Provider actor

public actor AppleMusicProvider:
    MusicCatalogProvider,
    MusicLibraryProvider,
    MusicSearchProvider,
    MusicPlaybackProvider,
    MusicAuthenticationProvider,
    MusicLyricsProvider
{
    // MARK: MusicProvider

    public let providerID: String = "apple_music"
    public let source: MusicSource = .appleMusic

    // MARK: - Session & Adapter

    public let sessionAdapter: any AppleMusicSessionAdapter
    private let ampClient: AppleMusicAmpClient
    private var currentPlayingTrack: MusicTrack?
    private var catalogIDCache: [String: String] = [:]
    private var currentVolume: Float = 1.0

    private enum ActiveEngine: Sendable {
        case none
        case webPlayer
        case musicKit
    }

    private var activeEngine: ActiveEngine = .none
    private var stateContinuations: [UUID: AsyncStream<PlaybackState>.Continuation] = [:]
    public var onPlaybackEnded: (@Sendable () -> Void)?

    public func setOnPlaybackEnded(_ block: (@Sendable () -> Void)?) {
        self.onPlaybackEnded = block
    }

    public func stateUpdates() async -> AsyncStream<PlaybackState>? {
        AsyncStream { continuation in
            let id = UUID()
            stateContinuations[id] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeStateContinuation(id: id) }
            }
        }
    }

    private func removeStateContinuation(id: UUID) {
        stateContinuations.removeValue(forKey: id)
    }

    private func emitCurrentState() async {
        let snapshot = await getState()
        for continuation in stateContinuations.values {
            continuation.yield(snapshot)
        }
    }

    public var webSessionState: AppleMusicWebSessionState {
        get async {
            await sessionAdapter.webSessionState
        }
    }

    public var apiAuthorizationState: AppleMusicAPIAuthorizationState {
        get async {
            await sessionAdapter.apiAuthorizationState
        }
    }

    /// Capabilities are computed honestly from live web session & API authorization state.
    /// Without paid Apple Developer credentials, full personal library is never falsely claimed.
    public var capabilities: MusicProviderCapabilities {
        get async {
            let apiState = await sessionAdapter.apiAuthorizationState
            let webState = await sessionAdapter.webSessionState

            if apiState.isAuthorized {
                let hasSubscription = await checkSubscription()
                let playbackCap: ProviderCapability = hasSubscription ? .supported : .requiresSubscription
                return MusicProviderCapabilities(
                    catalogSearch:  .supported,
                    libraryAccess:  hasSubscription ? .supported : .requiresSubscription,
                    playback:       playbackCap,
                    lyricsAccess:   .supported,
                    radioStations:  playbackCap,
                    requiresAuthentication: false
                )
            }

            // Web Session Mode (No Developer Credentials)
            if webState.isLoggedIn {
                return MusicProviderCapabilities(
                    catalogSearch:  .supported,
                    libraryAccess:  .requiresSubscription,
                    playback:       .supported,  // Full web playback
                    lyricsAccess:   .supported,  // Native Apple Music TTML synced lyrics
                    radioStations:  .supported,
                    requiresAuthentication: true
                )
            }

            // Unauthenticated Guest Web Mode
            return MusicProviderCapabilities(
                catalogSearch:  .supported,
                libraryAccess:  .requiresAuthorization,
                playback:       .requiresAuthorization,  // 严禁降级试听，未登录必须要求授权/登录
                lyricsAccess:   .unsupported,
                radioStations:  .unsupported,
                requiresAuthentication: true
            )
        }
    }

    // MARK: - Init

    @MainActor
    public init(
        sessionAdapter: (any AppleMusicSessionAdapter)? = nil,
        ampClient: AppleMusicAmpClient = .shared
    ) {
        let adapter = sessionAdapter ?? AppleMusicWebSessionAdapter(manager: .shared)
        self.sessionAdapter = adapter
        self.ampClient = ampClient
        AppleMusicSessionManager.shared.webPlayer.onStateChanged = { [weak self] in
            Task { [weak self] in
                await self?.emitCurrentState()
            }
        }
    }

    // MARK: - MusicAuthenticationProvider

    public var isAuthenticated: Bool {
        get async {
            let apiAuth = (MusicAuthorization.currentStatus == .authorized)
            let webAuth = await sessionAdapter.webSessionState.isLoggedIn
            return apiAuth || webAuth
        }
    }

    public func authenticate() async throws {
        AppLogger.shared.log(category: .auth, level: .info, message: "启动 Apple Music 官方网页安全认证流程...")
        try await sessionAdapter.authenticateWeb()
    }

    public func signOut() async throws {
        AppLogger.shared.log(category: .auth, level: .info, message: "执行 Apple Music 退出登录并重置会话...")
        try await sessionAdapter.signOut()
    }

    public func currentAccount() async -> MusicAccount? {
        await sessionAdapter.currentAccount
    }

    // MARK: - MusicCatalogProvider

    public func searchCatalog(query: String, limit: Int) async throws -> MusicSearchResult {
        do {
            try requireAuthorization()
            var request = MusicCatalogSearchRequest(term: query,
                                                    types: [Song.self, Album.self, Artist.self])
            request.limit = limit
            let response = try await request.response()
            return MusicSearchResult(
                tracks:  response.songs.map(\.asMusicTrack),
                albums:  response.albums.map(\.asMusicAlbum),
                artists: response.artists.map(\.asMusicArtist)
            )
        } catch {
            return try await ampClient.search(term: query, limit: limit)
        }
    }

    public func fetchTopCharts(genre: String? = nil) async throws -> [MusicTrack] {
        return try await ampClient.fetchCharts()
    }

    public func fetchNewReleases() async throws -> [MusicAlbum] {
        return try await ampClient.fetchNewReleases()
    }

    public func fetchRecommendations() async throws -> [AmpCategory] {
        let gen = await sessionAdapter.currentGeneration
        guard await sessionAdapter.webSessionState.isLoggedIn else {
            return []
        }
        return try await ampClient.fetchPersonalRecommendations(generation: gen)
    }

    public func fetchRecentlyAdded() async throws -> [AmpCategoryItem] {
        let gen = await sessionAdapter.currentGeneration
        guard await sessionAdapter.webSessionState.isLoggedIn else {
            return []
        }
        return try await ampClient.fetchRecentlyAdded(limit: 50, generation: gen)
    }

    public func fetchFavoriteSongs() async throws -> [MusicTrack] {
        let gen = await sessionAdapter.currentGeneration
        guard await sessionAdapter.webSessionState.isLoggedIn else {
            return []
        }
        let favs = try await ampClient.fetchFavoriteSongsPlaylist(generation: gen)
        if !favs.isEmpty { return favs }
        return try await ampClient.fetchLibrarySongs(limit: 100, generation: gen)
    }

    public func fetchMadeForYouPlaylists() async throws -> [MusicPlaylist] {
        let gen = await sessionAdapter.currentGeneration
        guard await sessionAdapter.webSessionState.isLoggedIn else {
            return []
        }
        return try await ampClient.fetchMadeForYouPlaylists(generation: gen)
    }

    public func fetchUserPlaylists() async throws -> [MusicPlaylist] {
        let gen = await sessionAdapter.currentGeneration
        guard await sessionAdapter.webSessionState.isLoggedIn else {
            return []
        }
        let split = try await ampClient.fetchLibraryPlaylistsSplit(generation: gen)
        return split.user
    }

    public func fetchFavoritePlaylists() async throws -> [MusicPlaylist] {
        let gen = await sessionAdapter.currentGeneration
        guard await sessionAdapter.webSessionState.isLoggedIn else {
            return []
        }
        let split = try await ampClient.fetchLibraryPlaylistsSplit(generation: gen)
        return split.favorite
    }

    public func fetchAlbumTracks(albumID: String, isLibrary: Bool? = nil) async throws -> [MusicTrack] {
        let gen = await sessionAdapter.currentGeneration
        return try await ampClient.fetchAlbumTracks(albumID: albumID, isLibrary: isLibrary, generation: gen)
    }

    public func fetchPlaylistTracks(playlistID: String, isLibrary: Bool? = nil) async throws -> [MusicTrack] {
        let gen = await sessionAdapter.currentGeneration
        return try await ampClient.fetchPlaylistTracks(playlistID: playlistID, isLibrary: isLibrary, generation: gen)
    }

    public func fetchArtistTopSongs(artistID: String, isLibrary: Bool? = nil) async throws -> [MusicTrack] {
        let gen = await sessionAdapter.currentGeneration
        return try await ampClient.fetchArtistTopSongs(artistID: artistID, isLibrary: isLibrary, generation: gen)
    }

    public func fetchEditorialCategories(name: String = "music") async throws -> [AmpCategory] {
        return try await ampClient.fetchEditorialGroupings(name: name)
    }

    // MARK: - MusicSearchProvider

    public func search(query: String) async throws -> MusicSearchResult {
        try await searchCatalog(query: query, limit: 25)
    }

    public func searchLibrary(query: String) async throws -> MusicSearchResult {
        let gen = await sessionAdapter.currentGeneration
        guard await sessionAdapter.webSessionState.isLoggedIn else {
            return MusicSearchResult()
        }
        return try await ampClient.searchLibrary(term: query, limit: 30, generation: gen)
    }

    // MARK: - MusicLibraryProvider

    public func fetchLibrary() async throws -> Domain.MusicLibrary {
        let gen = await sessionAdapter.currentGeneration
        do {
            try requireAuthorization()
            guard await checkSubscription() else {
                throw AppleMusicError.requiresSubscription
            }
            async let songsResponse  = MusicLibraryRequest<Song>().response()
            async let albumsResponse = MusicLibraryRequest<Album>().response()
            let (songs, albums) = try await (songsResponse, albumsResponse)
            return Domain.MusicLibrary(
                providerID: "apple_music",
                tracks: songs.items.map(\.asMusicTrack),
                albums: albums.items.map(\.asMusicAlbum)
            )
        } catch {
            guard await sessionAdapter.webSessionState.isLoggedIn else {
                throw AuthenticationError.requiresAuthorization
            }
            async let songsTask = ampClient.fetchLibrarySongs(generation: gen)
            async let albumsTask = ampClient.fetchLibraryAlbums(generation: gen)
            async let artistsTask = ampClient.fetchLibraryArtists(generation: gen)
            async let playlistsTask = ampClient.fetchLibraryPlaylists(generation: gen)

            let (songs, albums, artists, playlists) = try await (songsTask, albumsTask, artistsTask, playlistsTask)
            return Domain.MusicLibrary(
                providerID: "apple_music",
                tracks: songs,
                albums: albums,
                artists: artists,
                playlists: playlists
            )
        }
    }

    public func fetchLibraryTracks() async throws -> [MusicTrack] {
        let gen = await sessionAdapter.currentGeneration
        do {
            try requireAuthorization()
            let response = try await MusicLibraryRequest<Song>().response()
            let tracks = response.items.map(\.asMusicTrack)
            if !tracks.isEmpty { return tracks }
        } catch {}
        guard await sessionAdapter.webSessionState.isLoggedIn else {
            throw AuthenticationError.requiresAuthorization
        }
        return try await ampClient.fetchLibrarySongs(generation: gen)
    }

    public func fetchLibraryAlbums() async throws -> [MusicAlbum] {
        let gen = await sessionAdapter.currentGeneration
        do {
            try requireAuthorization()
            let response = try await MusicLibraryRequest<Album>().response()
            let albums = response.items.map(\.asMusicAlbum)
            if !albums.isEmpty { return albums }
        } catch {}
        guard await sessionAdapter.webSessionState.isLoggedIn else {
            throw AuthenticationError.requiresAuthorization
        }
        return try await ampClient.fetchLibraryAlbums(generation: gen)
    }

    public func fetchLibraryArtists() async throws -> [MusicArtist] {
        let gen = await sessionAdapter.currentGeneration
        do {
            try requireAuthorization()
            let response = try await MusicLibraryRequest<Artist>().response()
            let artists = response.items.map(\.asMusicArtist)
            if !artists.isEmpty { return artists }
        } catch {}
        guard await sessionAdapter.webSessionState.isLoggedIn else {
            throw AuthenticationError.requiresAuthorization
        }
        return try await ampClient.fetchLibraryArtists(generation: gen)
    }

    public func fetchLibraryPlaylists() async throws -> [MusicPlaylist] {
        let gen = await sessionAdapter.currentGeneration
        do {
            try requireAuthorization()
            let response = try await MusicLibraryRequest<Playlist>().response()
            let playlists = response.items.map { pl in
                MusicPlaylist(
                    id: pl.id.rawValue,
                    name: pl.name,
                    artworkURL: pl.artwork?.url(width: 200, height: 200),
                    trackIDs: [],
                    providerID: "apple_music",
                    providerPlaylistID: pl.id.rawValue
                )
            }
            if !playlists.isEmpty { return playlists }
        } catch {}
        guard await sessionAdapter.webSessionState.isLoggedIn else {
            throw AuthenticationError.requiresAuthorization
        }
        return try await ampClient.fetchLibraryPlaylists(generation: gen)
    }

    // MARK: - MusicPlaybackProvider

    public func play(track: MusicTrack) async throws {
        self.currentPlayingTrack = track

        let rawID = track.providerTrackID.isEmpty ? track.id : track.providerTrackID
        let isStation = rawID.hasPrefix("ra.") || track.id.hasPrefix("ra.")

        // 1. Fail-Fast 契约：已登录 Web 会话时严格走官方 WebKit 全曲播放，禁止静默降级为 30s 试听流
        if await sessionAdapter.webSessionState.isLoggedIn {
            self.activeEngine = .webPlayer
            await sessionAdapter.beginTrackTransition()
            let success: Bool
            if isStation {
                AppLogger.shared.log(category: .playback, level: .info, message: "Apple Music Web 播放器接入电台: \(track.title)")
                success = try await sessionAdapter.playTrack(id: rawID, type: "station")
            } else {
                var targetID = rawID
                if targetID.hasPrefix("i.") || targetID.hasPrefix("a.") {
                    if let cached = catalogIDCache[targetID] {
                        targetID = cached
                    } else if let resolved = await ampClient.resolveCatalogSongID(librarySongID: targetID) {
                        catalogIDCache[targetID] = resolved
                        targetID = resolved
                    }
                }
                AppLogger.shared.log(category: .playback, level: .info, message: "Apple Music 官方 Web 播放器就绪: 正在以会员身份从 0:00 播放全曲: \(track.title) - \(track.artistName) (ID: \(targetID))")
                success = try await sessionAdapter.playTrack(id: targetID, type: "song")
            }
            if success {
                self.activeEngine = .webPlayer
                await emitCurrentState()
                return
            }
            AppLogger.shared.log(category: .playback, level: .error, message: "Web 播放器调度播放失败: \(track.title)")
            throw AppleMusicError.playbackFailed("Web 播放器未能启动播放")
        }

        // 2. 尝试系统原生 MusicKit 开发者框架授权 (若具备付费开发者凭据)
        if !isStation {
            do {
                try requireAuthorization()
                guard await checkSubscription() else { throw AppleMusicError.requiresSubscription }
                guard let songID = MusicItemID(rawValue: track.id) as MusicItemID? else {
                    throw AppleMusicError.playbackFailed("Invalid track ID")
                }
                var request = MusicCatalogResourceRequest<Song>(matching: \.id, equalTo: songID)
                request.limit = 1
                let response = try await request.response()
                guard let song = response.items.first else {
                    throw AppleMusicError.playbackFailed("Song not found in catalog")
                }
                let player = ApplicationMusicPlayer.shared
                player.queue = [song]
                try await player.play()
                self.activeEngine = .musicKit
                AppLogger.shared.log(category: .playback, level: .info, message: "MusicKit 播放成功: \(track.title) - \(track.artistName)")
                return
            } catch {}
        }

        // 3. 未登录或无会员：严禁降级试听或提供劣质音频，直接阻断并主动引导用户去登录
        AppLogger.shared.log(category: .playback, level: .warn, message: "未登录 Apple Music 官方账号，已拦截播放并引导登录: \(track.title)")
        NotificationCenter.default.post(name: .appleMusicRequiresAuthentication, object: nil)
        throw AppleMusicError.notAuthorized
    }

    public func pause() async throws {
        switch activeEngine {
        case .webPlayer:
            _ = try? await sessionAdapter.pause()
        case .musicKit:
            try? requireAuthorization()
            ApplicationMusicPlayer.shared.pause()
        case .none:
            break
        }
    }

    public func play() async throws {
        switch activeEngine {
        case .webPlayer:
            _ = try? await sessionAdapter.play()
        case .musicKit:
            try requireAuthorization()
            try await ApplicationMusicPlayer.shared.play()
        case .none:
            break
        }
    }

    public func playPause() async throws {
        let session = await currentSession()
        if session.state == .playing {
            try await pause()
        } else {
            try await play()
        }
    }

    public func stop() async throws {
        switch activeEngine {
        case .webPlayer:
            try? await sessionAdapter.stop()
        case .musicKit:
            try? requireAuthorization()
            ApplicationMusicPlayer.shared.stop()
        case .none:
            break
        }
        activeEngine = .none
    }

    public func skipToNext() async throws {
        switch activeEngine {
        case .webPlayer:
            try? await sessionAdapter.skipToNext()
        case .musicKit:
            try requireAuthorization()
            try await ApplicationMusicPlayer.shared.skipToNextEntry()
        case .none:
            break
        }
    }

    public func skipToPrevious() async throws {
        switch activeEngine {
        case .webPlayer:
            try? await sessionAdapter.skipToPrevious()
        case .musicKit:
            try requireAuthorization()
            try await ApplicationMusicPlayer.shared.skipToPreviousEntry()
        case .none:
            break
        }
    }

    public func seek(to seconds: Double) async throws {
        switch activeEngine {
        case .webPlayer:
            try? await sessionAdapter.seek(to: seconds)
        case .musicKit:
            try requireAuthorization()
            ApplicationMusicPlayer.shared.playbackTime = seconds
        case .none:
            break
        }
    }

    public func setVolume(_ volume: Float) async throws {
        currentVolume = min(max(volume, 0), 1)
        try? await sessionAdapter.setVolume(currentVolume)
    }

    public func getState() async -> PlaybackState {
        switch activeEngine {
        case .webPlayer:
            let snap = await sessionAdapter.currentPlaybackSnapshot()
            let trackDur: Int64
            if let ct = currentPlayingTrack, ct.durationMs > 0 {
                trackDur = ct.durationMs
            } else if snap.duration > 0 {
                trackDur = Int64(snap.duration * 1000)
            } else {
                trackDur = 0
            }
            let resolvedStatus: PlaybackStatus
            let effectivePlaying: Bool
            if snap.hasStartedAudio && snap.isPlaying {
                resolvedStatus = .playing
                effectivePlaying = true
            } else if !snap.hasStartedAudio && (snap.isBuffering || snap.isPlaying) {
                resolvedStatus = snap.isBuffering ? .buffering : .loading
                effectivePlaying = false
            } else if snap.isBuffering {
                resolvedStatus = .buffering
                effectivePlaying = false
            } else {
                resolvedStatus = .paused
                effectivePlaying = false
            }
            return PlaybackState(
                status: resolvedStatus,
                isPlaying: effectivePlaying,
                positionMs: snap.hasStartedAudio ? Int64(snap.position * 1000) : 0,
                durationMs: trackDur,
                volume: snap.volume,
                isMuted: snap.volume <= 0.001,
                repeatMode: .off,
                shuffleEnabled: false,
                currentTrack: currentPlayingTrack,
                providerID: providerID,
                sourceName: source.displayName,
                artworkData: nil,
                timestampDate: .now
            )

        case .musicKit:
            let player = ApplicationMusicPlayer.shared
            let isPlaying = (player.state.playbackStatus == .playing)
            let posMs = Int64(player.playbackTime * 1000)
            let durMs = currentPlayingTrack?.durationMs ?? 0
            return PlaybackState(
                status: isPlaying ? .playing : .paused,
                isPlaying: isPlaying,
                positionMs: posMs,
                durationMs: durMs,
                volume: 1.0,
                isMuted: false,
                repeatMode: .off,
                shuffleEnabled: false,
                currentTrack: currentPlayingTrack,
                providerID: providerID,
                sourceName: source.displayName,
                artworkData: nil,
                timestampDate: .now
            )

        case .none:
            return .idle
        }
    }

    public func currentSession() async -> PlaybackSession {
        switch activeEngine {
        case .webPlayer:
            let (pos, _, isPlaying) = await sessionAdapter.currentPlaybackPosition()
            return PlaybackSession(
                currentTrack: currentPlayingTrack,
                source: .appleMusic,
                state: isPlaying ? .playing : .paused,
                queue: PlaybackQueue(items: currentPlayingTrack.map { [$0] } ?? [], currentIndex: 0),
                positionSeconds: pos
            )
        case .musicKit:
            let player = ApplicationMusicPlayer.shared
            let status = player.state.playbackStatus
            let sessionStatus: PlaybackStatus = switch status {
            case .playing: .playing
            case .paused:  .paused
            case .stopped: .stopped
            default:       .idle
            }
            return PlaybackSession(
                currentTrack: currentPlayingTrack,
                source: .appleMusic,
                state: sessionStatus,
                queue: PlaybackQueue(items: currentPlayingTrack.map { [$0] } ?? [], currentIndex: 0),
                positionSeconds: player.playbackTime
            )
        case .none:
            return PlaybackSession.idle
        }
    }

    // MARK: - MusicLyricsProvider

    public func fetchLyrics(for track: MusicTrack) async throws -> LyricsDocument? {
        let gen = await sessionAdapter.currentGeneration
        let songID = track.providerTrackID.isEmpty ? track.id : track.providerTrackID

        // 0. 电台无歌词
        if songID.hasPrefix("ra.") || track.id.hasPrefix("ra.") {
            AppLogger.shared.log(category: .lyrics, level: .info, message: "广播电台曲目，跳过歌词检索: \(track.title)")
            return LyricsDocument(trackKey: track.trackKey, lines: [], statusText: "广播电台（无歌词）")
        }

        AppLogger.shared.log(
            category: .lyrics,
            level: .info,
            message: "开始检索全量同步歌词: [\(track.title) - \(track.artistName)] (ID: \(songID))"
        )

        // 1. 优先尝试 Apple Music 官方 Web 端原生 TTML 逐句同步歌词 (若已登录 Web 会话)
        if await sessionAdapter.webSessionState.isLoggedIn {
            do {
                if let ttml = try await ampClient.fetchSongLyricsTTML(songID: songID, generation: gen), !ttml.isEmpty {
                    let doc = parseTTMLLyrics(ttml: ttml, trackKey: track.trackKey)
                    if !doc.lines.isEmpty {
                        let firstLineStr = doc.lines.first.map { "[\(String(format: "%.1f", $0.startTime))s] \($0.text)" } ?? "无"
                        let lastLineStr = doc.lines.last.map { "[\(String(format: "%.1f", $0.startTime))s] \($0.text)" } ?? "无"
                        AppLogger.shared.log(
                            category: .lyrics,
                            level: .info,
                            message: "获取到 Apple Music 官方原版全量同步歌词: 共 \(doc.lines.count) 行 (\(track.title))",
                            details: "首句: \(firstLineStr)\n末句: \(lastLineStr)\nTTML 原始大小: \(ttml.count) 字符"
                        )
                        return doc
                    }
                }
            } catch {
                AppLogger.shared.log(
                    category: .lyrics,
                    level: .info,
                    message: "Apple Music 官方未收录该曲目 TTML 原生歌词 (\(error.localizedDescription))，启动外部引擎检索..."
                )
            }
        }

        // 2. 外部高精度同步歌词引擎回退 (LRCLIB 同步源)
        if let doc = await fetchPublicSyncedLyrics(track: track) {
            let firstLineStr = doc.lines.first.map { "[\(String(format: "%.1f", $0.startTime))s] \($0.text)" } ?? "无"
            let lastLineStr = doc.lines.last.map { "[\(String(format: "%.1f", $0.startTime))s] \($0.text)" } ?? "无"
            AppLogger.shared.log(
                category: .lyrics,
                level: .info,
                message: "获取到 LRCLIB 同步歌词: 共 \(doc.lines.count) 行 (\(track.title))",
                details: "首句: \(firstLineStr)\n末句: \(lastLineStr)"
            )
            return doc
        }

        // 3. 网易云音乐歌词备用引擎 (针对纯音乐、华语及小众音乐的高覆盖率回退)
        if let doc = await fetchNetEaseLyrics(track: track) {
            let firstLineStr = doc.lines.first.map { "[\(String(format: "%.1f", $0.startTime))s] \($0.text)" } ?? "无"
            let lastLineStr = doc.lines.last.map { "[\(String(format: "%.1f", $0.startTime))s] \($0.text)" } ?? "无"
            let translationCount = doc.lines.filter { $0.translation != nil }.count
            AppLogger.shared.log(
                category: .lyrics,
                level: .info,
                message: "获取到网易云备用同步歌词: 共 \(doc.lines.count) 行 (含双语翻译: \(translationCount) 行) (\(track.title))",
                details: "首句: \(firstLineStr)\n末句: \(lastLineStr)"
            )
            return doc
        }

        AppLogger.shared.log(category: .lyrics, level: .warn, message: "未能从任何歌词库检索到可用歌词 (纯音乐或暂无收录): \(track.title)")
        return LyricsDocument(trackKey: track.trackKey, lines: [], statusText: "纯音乐或暂无歌词")
    }

    package static func unescapeXMLEntities(_ str: String) -> String {
        var res = str
        res = res.replacingOccurrences(of: "&apos;", with: "'")
        res = res.replacingOccurrences(of: "&#39;", with: "'")
        res = res.replacingOccurrences(of: "&quot;", with: "\"")
        res = res.replacingOccurrences(of: "&amp;", with: "&")
        res = res.replacingOccurrences(of: "&lt;", with: "<")
        res = res.replacingOccurrences(of: "&gt;", with: ">")
        res = res.replacingOccurrences(of: "&nbsp;", with: " ")
        return res
    }

    nonisolated package func parseTTMLLyrics(ttml: String, trackKey: String) -> LyricsDocument {
        var lines: [LyricsLine] = []
        // Match both <p ...> tags and attributes with double or single quotes
        let pPattern = #"<p(\s+[^>]*)?>(.*?)</p>"#
        guard let pRegex = try? NSRegularExpression(pattern: pPattern, options: [.dotMatchesLineSeparators]) else {
            return LyricsDocument(trackKey: trackKey, lines: [], statusText: "歌词解析错误")
        }

        let beginAttrRegex = try? NSRegularExpression(pattern: #"begin=["']([^"']+)["']"#, options: [])
        let roleAttrRegex = try? NSRegularExpression(pattern: #"(?:role|itunes:key)=["']([^"']+)["']"#, options: [])
        let spanBeginRegex = try? NSRegularExpression(pattern: #"<span\s+[^>]*begin=["']([^"']+)["'][^>]*>(.*?)</span>"#, options: [.dotMatchesLineSeparators])

        let nsString = ttml as NSString
        let matches = pRegex.matches(in: ttml, range: NSRange(location: 0, length: nsString.length))

        for match in matches {
            guard match.numberOfRanges >= 3 else { continue }
            let attrsStr = match.range(at: 1).location != NSNotFound ? nsString.substring(with: match.range(at: 1)) : ""
            let innerContent = nsString.substring(with: match.range(at: 2))

            // 1. Resolve begin timestamp from <p> attributes or from the first child <span>
            var resolvedBegin: String? = nil
            let attrsNS = attrsStr as NSString
            if let beginMatch = beginAttrRegex?.firstMatch(in: attrsStr, range: NSRange(location: 0, length: attrsNS.length)),
               beginMatch.numberOfRanges >= 2 {
                resolvedBegin = attrsNS.substring(with: beginMatch.range(at: 1))
            } else {
                let innerNS = innerContent as NSString
                if let spanMatch = spanBeginRegex?.firstMatch(in: innerContent, range: NSRange(location: 0, length: innerNS.length)),
                   spanMatch.numberOfRanges >= 2 {
                    resolvedBegin = innerNS.substring(with: spanMatch.range(at: 1))
                }
            }

            guard let timeStr = resolvedBegin, let ms = Self.parseTimestampToMs(timeStr) else { continue }

            // 2. Extract clean text
            let textStripped = innerContent.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            let textClean = Self.unescapeXMLEntities(textStripped).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !textClean.isEmpty else { continue }

            // 3. Check for translation role
            var isTranslation = false
            if let roleMatch = roleAttrRegex?.firstMatch(in: attrsStr, range: NSRange(location: 0, length: attrsNS.length)),
               roleMatch.numberOfRanges >= 2 {
                let roleVal = attrsNS.substring(with: roleMatch.range(at: 1)).lowercased()
                isTranslation = (roleVal == "translation" || roleVal == "transcription")
            }

            if isTranslation {
                if let idx = lines.firstIndex(where: { abs($0.timeMs - ms) < 500 }) {
                    lines[idx].translation = textClean
                } else {
                    lines.append(LyricsLine(timeMs: ms, text: textClean))
                }
            } else {
                // If a line with exact same timestamp already exists, merge as translation
                if let idx = lines.firstIndex(where: { $0.timeMs == ms }) {
                    if lines[idx].translation == nil && lines[idx].text != textClean {
                        lines[idx].translation = textClean
                    }
                } else {
                    lines.append(LyricsLine(timeMs: ms, text: textClean))
                }
            }
        }

        lines.sort(by: { $0.timeMs < $1.timeMs })
        return LyricsDocument(trackKey: trackKey, lines: lines, statusText: lines.isEmpty ? "暂无歌词" : "歌词同步中")
    }

    private static func parseTimestampToMs(_ str: String) -> Int64? {
        var clean = str.trimmingCharacters(in: .whitespacesAndNewlines)
        if clean.hasSuffix("s") {
            clean = String(clean.dropLast())
        }
        if let directVal = Double(clean) {
            return Int64(directVal * 1000.0)
        }
        let parts = clean.components(separatedBy: ":")
        if parts.count == 2 {
            let m = Double(parts[0]) ?? 0
            let s = Double(parts[1]) ?? 0
            return Int64((m * 60.0 + s) * 1000.0)
        } else if parts.count == 3 {
            let h = Double(parts[0]) ?? 0
            let m = Double(parts[1]) ?? 0
            let s = Double(parts[2]) ?? 0
            return Int64((h * 3600.0 + m * 60.0 + s) * 1000.0)
        }
        return nil
    }

    private func fetchPublicSyncedLyrics(track: MusicTrack) async -> LyricsDocument? {
        guard let titleEnc = track.title.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let artistEnc = track.artistName.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else {
            return nil
        }
        var urlStr = "https://lrclib.net/api/get?track_name=\(titleEnc)&artist_name=\(artistEnc)"
        if track.durationMs > 1000 {
            urlStr += "&duration=\(track.durationMs / 1000)"
        }
        guard let url = URL(string: urlStr) else { return nil }

        var req = URLRequest(url: url)
        req.timeoutInterval = 4.0
        req.setValue("AirMuse/2.0 (macOS)", forHTTPHeaderField: "User-Agent")

        AppLogger.shared.log(category: .network, level: .debug, message: "发起 LRCLIB 歌词请求: \(urlStr)")
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              let http = resp as? HTTPURLResponse, http.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let synced = json["syncedLyrics"] as? String, !synced.isEmpty else {
            return nil
        }

        var lines: [LyricsLine] = []
        let lrcLines = synced.components(separatedBy: "\n")
        let lrcRegex = try? NSRegularExpression(pattern: #"^\[(\d{2}):(\d{2}(?:\.\d+)?)\](.*)$"#)

        for line in lrcLines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let regex = lrcRegex else { continue }
            let ns = trimmed as NSString
            let matches = regex.matches(in: trimmed, range: NSRange(location: 0, length: ns.length))
            if let match = matches.first, match.numberOfRanges >= 4 {
                let min = Double(ns.substring(with: match.range(at: 1))) ?? 0
                let sec = Double(ns.substring(with: match.range(at: 2))) ?? 0
                let rawText = ns.substring(with: match.range(at: 3)).trimmingCharacters(in: .whitespaces)
                let text = Self.unescapeXMLEntities(rawText)
                let ms = Int64((min * 60.0 + sec) * 1000.0)
                if !text.isEmpty {
                    lines.append(LyricsLine(timeMs: ms, text: text))
                }
            }
        }
        lines.sort(by: { $0.timeMs < $1.timeMs })
        return lines.isEmpty ? nil : LyricsDocument(trackKey: track.trackKey, lines: lines, statusText: "歌词同步中")
    }

    private func fetchNetEaseLyrics(track: MusicTrack) async -> LyricsDocument? {
        guard let titleEnc = track.title.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let artistEnc = track.artistName.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else {
            return nil
        }
        let searchURLStr = "https://music.163.com/api/search/get/web?s=\(titleEnc)%20\(artistEnc)&type=1&limit=1"
        guard let searchURL = URL(string: searchURLStr) else { return nil }

        var searchReq = URLRequest(url: searchURL)
        searchReq.timeoutInterval = 4.0
        searchReq.setValue("https://music.163.com/", forHTTPHeaderField: "Referer")
        searchReq.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")

        AppLogger.shared.log(category: .network, level: .debug, message: "发起网易云歌词搜索请求: \(track.title)")
        guard let (sData, sResp) = try? await URLSession.shared.data(for: searchReq),
              let sHttp = sResp as? HTTPURLResponse, sHttp.statusCode == 200,
              let sJson = try? JSONSerialization.jsonObject(with: sData) as? [String: Any],
              let result = sJson["result"] as? [String: Any],
              let songs = result["songs"] as? [[String: Any]],
              let firstSong = songs.first,
              let songId = firstSong["id"] as? Int else {
            return nil
        }

        let lyricURLStr = "https://music.163.com/api/song/lyric?id=\(songId)&lv=1&tv=1"
        guard let lyricURL = URL(string: lyricURLStr) else { return nil }

        var lyricReq = URLRequest(url: lyricURL)
        lyricReq.timeoutInterval = 4.0
        lyricReq.setValue("https://music.163.com/", forHTTPHeaderField: "Referer")
        lyricReq.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")

        guard let (lData, lResp) = try? await URLSession.shared.data(for: lyricReq),
              let lHttp = lResp as? HTTPURLResponse, lHttp.statusCode == 200,
              let lJson = try? JSONSerialization.jsonObject(with: lData) as? [String: Any],
              let lrcObj = lJson["lrc"] as? [String: Any],
              let lyricText = lrcObj["lyric"] as? String, !lyricText.isEmpty else {
            return nil
        }

        var lines: [LyricsLine] = []
        let lrcLines = lyricText.components(separatedBy: "\n")
        let lrcRegex = try? NSRegularExpression(pattern: #"^\[(\d{2}):(\d{2}(?:\.\d+)?)\](.*)$"#)

        for line in lrcLines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let regex = lrcRegex else { continue }
            let ns = trimmed as NSString
            let matches = regex.matches(in: trimmed, range: NSRange(location: 0, length: ns.length))
            if let match = matches.first, match.numberOfRanges >= 4 {
                let min = Double(ns.substring(with: match.range(at: 1))) ?? 0
                let sec = Double(ns.substring(with: match.range(at: 2))) ?? 0
                let rawText = ns.substring(with: match.range(at: 3)).trimmingCharacters(in: .whitespaces)
                let text = Self.unescapeXMLEntities(rawText)
                let ms = Int64((min * 60.0 + sec) * 1000.0)
                if !text.isEmpty {
                    lines.append(LyricsLine(timeMs: ms, text: text))
                }
            }
        }

        // Parse optional translation lyrics (tlyric) from NetEase
        if let tlyricObj = lJson["tlyric"] as? [String: Any],
           let tlyricText = tlyricObj["lyric"] as? String, !tlyricText.isEmpty {
            let tLines = tlyricText.components(separatedBy: "\n")
            for tline in tLines {
                let trimmed = tline.trimmingCharacters(in: .whitespacesAndNewlines)
                guard let regex = lrcRegex else { continue }
                let ns = trimmed as NSString
                let matches = regex.matches(in: trimmed, range: NSRange(location: 0, length: ns.length))
                if let match = matches.first, match.numberOfRanges >= 4 {
                    let min = Double(ns.substring(with: match.range(at: 1))) ?? 0
                    let sec = Double(ns.substring(with: match.range(at: 2))) ?? 0
                    let tRaw = ns.substring(with: match.range(at: 3)).trimmingCharacters(in: .whitespaces)
                    let tText = Self.unescapeXMLEntities(tRaw)
                    let ms = Int64((min * 60.0 + sec) * 1000.0)
                    if !tText.isEmpty, let idx = lines.firstIndex(where: { abs($0.timeMs - ms) < 500 }) {
                        lines[idx].translation = tText
                    }
                }
            }
        }

        lines.sort(by: { $0.timeMs < $1.timeMs })
        return lines.isEmpty ? nil : LyricsDocument(trackKey: track.trackKey, lines: lines, statusText: "歌词同步中")
    }

    // MARK: - Private helpers

    private func requireAuthorization() throws {
        guard MusicAuthorization.currentStatus == .authorized else {
            throw AppleMusicError.notAuthorized
        }
    }

    /// Heuristic: attempt a minimal catalog request; MusicSubscriptionOffer indicates no subscription.
    private func checkSubscription() async -> Bool {
        do {
            var req = MusicCatalogSearchRequest(term: "test", types: [Song.self])
            req.limit = 1
            _ = try await req.response()
            return true
        } catch {
            // MusicKit throws specific errors for missing subscription
            return false
        }
    }
}

// MARK: - MusicKit ↔ Domain model conversions

private extension Song {
    var asMusicTrack: MusicTrack {
        MusicTrack(
            id: id.rawValue,
            title: title,
            artistName: artistName,
            albumTitle: albumTitle,
            durationSeconds: duration,
            artworkURL: artwork?.url(width: 300, height: 300),
            source: .appleMusic,
            isExplicit: contentRating == .explicit
        )
    }
}

private extension Album {
    var asMusicAlbum: MusicAlbum {
        MusicAlbum(
            id: id.rawValue,
            title: title,
            artistName: artistName,
            artworkURL: artwork?.url(width: 300, height: 300),
            releaseYear: releaseDate.map { Calendar.current.component(.year, from: $0) },
            trackCount: trackCount
        )
    }
}

private extension Artist {
    var asMusicArtist: MusicArtist {
        MusicArtist(
            id: id.rawValue,
            name: name,
            artworkURL: artwork?.url(width: 300, height: 300)
        )
    }
}

public extension Notification.Name {
    static let appleMusicRequiresAuthentication = Notification.Name("AirMuseAppleMusicRequiresAuthenticationNotification")
}
