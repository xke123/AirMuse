// Sources/Providers/AppleMusic/AppleMusicAmpClient.swift
// AirMuse macOS – Direct client for Apple Music Amp-API (Web REST API)
// Ported from AirMuse_Remastered apple_music_provider.js
// Swift 6 strict concurrency

import Foundation
import Domain
import Infrastructure

// MARK: - Editorial Models

public struct AmpCategoryItem: Sendable, Identifiable, Codable {
    public let id: String
    public let title: String
    public let subtitle: String
    public let type: String  // "song", "album", "playlist", "station", "artist", "item"
    public let artworkURL: URL?
    public let durationMs: Int64?
    public let track: MusicTrack?
    public let album: MusicAlbum?
    public let playlist: MusicPlaylist?
    public let artist: MusicArtist?
    public let isLibrary: Bool

    public init(
        id: String,
        title: String,
        subtitle: String,
        type: String,
        artworkURL: URL? = nil,
        durationMs: Int64? = nil,
        track: MusicTrack? = nil,
        album: MusicAlbum? = nil,
        playlist: MusicPlaylist? = nil,
        artist: MusicArtist? = nil,
        isLibrary: Bool = false
    ) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.type = type
        self.artworkURL = artworkURL
        self.durationMs = durationMs
        self.track = track
        self.album = album
        self.playlist = playlist
        self.artist = artist
        self.isLibrary = isLibrary
    }
}

public struct AmpCategory: Sendable, Identifiable, Codable {
    public let id: String
    public let title: String
    public let items: [AmpCategoryItem]
    public let nextURL: URL?

    public init(id: String, title: String, items: [AmpCategoryItem], nextURL: URL? = nil) {
        self.id = id
        self.title = title
        self.items = items
        self.nextURL = nextURL
    }
}

/// Actor-isolated client for directly querying the Apple Music Amp-API.
/// Operates without hardcoded tokens or secrets.
/// Uses dynamic developer token captured from official Web sessions and user media-user-token.
public actor AppleMusicAmpClient {

    public static let shared = AppleMusicAmpClient()

    private var devToken: String?
    private var userToken: String?
    private var storefront: String = "cn"
    private var activeGeneration: Int = 0
    private var resolvedCatalogIDs: [String: String] = [:]
    private let session: URLSession

    public private(set) var onSessionExpired: (@Sendable () -> Void)?

    public func setOnSessionExpired(_ handler: (@Sendable () -> Void)?) {
        self.onSessionExpired = handler
    }

    public init(devToken: String? = nil, userToken: String? = nil) {
        self.devToken = devToken
        self.userToken = userToken
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15
        self.session = URLSession(configuration: config)

        AppLogger.shared.log(
            category: .ampAPI,
            level: .info,
            message: "AppleMusicAmpClient 初始化完成",
            details: "Developer Token: \(devToken != nil ? "已设置 (\(devToken!.count) 字符)" : "未就绪 (等待 Web 会话捕获)") | 用户登录令牌: \(userToken != nil ? "已设置" : "未登录 (访客模式)")"
        )
    }

    public func setActiveGeneration(_ generation: Int) {
        self.activeGeneration = generation
    }

    public func setStorefront(_ storefront: String?) {
        let trimmed = storefront?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        self.storefront = (trimmed?.isEmpty == false) ? trimmed! : "cn"
    }

    public func currentGeneration() -> Int {
        activeGeneration
    }

    public func setUserToken(_ token: String?) {
        self.userToken = token
        AppLogger.shared.log(
            category: .auth,
            level: .info,
            message: "更新 media-user-token 状态",
            details: token != nil ? "已加载用户令牌 (\(token!.prefix(12))...)" : "已清除用户令牌"
        )
    }

    public func setDeveloperToken(_ token: String?) {
        self.devToken = token
        AppLogger.shared.log(
            category: .auth,
            level: .info,
            message: "更新 Apple Music Developer Token",
            details: token != nil ? "Token 长度: \(token!.count) 字符" : "Token 已清除"
        )
    }

    public func hasDeveloperToken() -> Bool {
        guard let dt = devToken, !dt.isEmpty else { return false }
        return true
    }

    public func hasUserToken() -> Bool {
        guard let ut = userToken, !ut.isEmpty else { return false }
        return true
    }

    // MARK: - Token Verification

    /// Verifies the validity of an Apple Music user token against official Apple backend.
    /// Returns verified storefront ID and optional real account name.
    public func verifyUserToken(userToken: String, devToken: String) async throws -> (isValid: Bool, storefront: String?, accountName: String?) {
        guard let url = URL(string: "https://amp-api.music.apple.com/v1/me/storefront?l=zh-Hans-CN&platform=web") else {
            return (false, nil, nil)
        }
        var req = URLRequest(url: url)
        req.setValue("Bearer \(devToken)", forHTTPHeaderField: "authorization")
        req.setValue(userToken, forHTTPHeaderField: "music-user-token")
        req.setValue("https://music.apple.com", forHTTPHeaderField: "origin")
        req.setValue("https://music.apple.com/", forHTTPHeaderField: "referer")
        req.setValue("zh-Hans-CN", forHTTPHeaderField: "accept-language")

        let start = CFAbsoluteTimeGetCurrent()
        AppLogger.shared.log(
            category: .ampAPI,
            level: .info,
            message: "发起会话校验请求: GET /v1/me/storefront"
        )

        do {
            let (data, response) = try await session.data(for: req)
            let durationMs = Int((CFAbsoluteTimeGetCurrent() - start) * 1000)
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
            AppLogger.shared.log(
                category: .ampAPI,
                level: statusCode == 200 ? .info : .warn,
                message: "会话校验响应 [HTTP \(statusCode)] (耗时: \(durationMs)ms, 大小: \(data.count) 字节)"
            )
            if statusCode == 200 {
                var storefrontId: String? = nil
                var accountName: String? = nil
                if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let dataArr = json["data"] as? [[String: Any]],
                   let first = dataArr.first {
                    storefrontId = first["id"] as? String
                    let attrs = first["attributes"] as? [String: Any]
                    if let name = attrs?["name"] as? String, !name.isEmpty {
                        accountName = name
                    }
                }
                return (true, storefrontId, accountName)
            } else if statusCode == 401 || statusCode == 403 {
                throw AppleMusicSessionError.tokenVerificationFailed(statusCode: statusCode, message: "Apple 拒绝了该用户令牌或令牌已失效")
            } else {
                throw AppleMusicSessionError.tokenVerificationFailed(statusCode: statusCode, message: "HTTP \(statusCode)")
            }
        } catch let err as AppleMusicSessionError {
            throw err
        } catch {
            let durationMs = Int((CFAbsoluteTimeGetCurrent() - start) * 1000)
            AppLogger.shared.log(
                category: .ampAPI,
                level: .warn,
                message: "会话校验请求异常 (耗时: \(durationMs)ms): \(error.localizedDescription)"
            )
            if (error as? URLError)?.code == .notConnectedToInternet {
                throw AppleMusicSessionError.networkUnavailable
            }
            throw error
        }
    }

    // MARK: - Dynamic Developer Token Auto-Discovery

    public func ensureDeveloperToken() async throws -> String {
        if let devToken, !devToken.isEmpty {
            return devToken
        }
        let token = try await fetchPublicDeveloperToken()
        self.devToken = token
        AppLogger.shared.log(
            category: .auth,
            level: .info,
            message: "动态获取 Apple Music 官方 Web 端 Developer Token 成功 (长度: \(token.count) 字符)"
        )
        return token
    }

    private func fetchPublicDeveloperToken() async throws -> String {
        guard let pageURL = URL(string: "https://music.apple.com/cn/browse") else {
            throw AppleMusicSessionError.developerTokenMissing
        }
        var pageReq = URLRequest(url: pageURL)
        pageReq.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko)", forHTTPHeaderField: "User-Agent")

        let (htmlData, _) = try await session.data(for: pageReq)
        guard let html = String(data: htmlData, encoding: .utf8) else {
            throw AppleMusicSessionError.developerTokenMissing
        }

        // Find /assets/index~...js
        let pattern = "(/assets/index~[^\"]+\\.js)"
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
              let range = Range(match.range(at: 1), in: html) else {
            throw AppleMusicSessionError.developerTokenMissing
        }

        let scriptPath = String(html[range])
        guard let scriptURL = URL(string: "https://music.apple.com\(scriptPath)") else {
            throw AppleMusicSessionError.developerTokenMissing
        }

        var scriptReq = URLRequest(url: scriptURL)
        scriptReq.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
        let (jsData, _) = try await session.data(for: scriptReq)
        guard let js = String(data: jsData, encoding: .utf8) else {
            throw AppleMusicSessionError.developerTokenMissing
        }

        let tokenPattern = "eyJ0eXAiOiJKV1Qi[a-zA-Z0-9_-]+\\.[a-zA-Z0-9_-]+\\.[a-zA-Z0-9_-]+"
        guard let tokenRegex = try? NSRegularExpression(pattern: tokenPattern),
              let tokenMatch = tokenRegex.firstMatch(in: js, range: NSRange(js.startIndex..., in: js)),
              let tokenRange = Range(tokenMatch.range(at: 0), in: js) else {
            throw AppleMusicSessionError.developerTokenMissing
        }

        return String(js[tokenRange])
    }

    // MARK: - HTTP Request Execution & Logging

    private func execute(url: URL, needAuth: Bool = false, generation: Int? = nil) async throws -> Data {
        if let reqGen = generation, reqGen != activeGeneration {
            throw AppleMusicSessionError.sessionGenerationMismatch
        }

        let currentDevToken: String
        if let dt = devToken, !dt.isEmpty {
            currentDevToken = dt
        } else {
            do {
                currentDevToken = try await ensureDeveloperToken()
            } catch {
                AppLogger.shared.log(category: .error, level: .warn, message: "未能获取 Developer Token，拒绝执行 Amp-API 请求: \(url.path)")
                throw AppleMusicSessionError.developerTokenMissing
            }
        }

        var req = URLRequest(url: url)
        req.setValue("Bearer \(currentDevToken)", forHTTPHeaderField: "authorization")
        req.setValue("https://music.apple.com", forHTTPHeaderField: "origin")
        req.setValue("https://music.apple.com/", forHTTPHeaderField: "referer")
        req.setValue("zh-Hans-CN", forHTTPHeaderField: "accept-language")
        if needAuth, let ut = userToken {
            req.setValue(ut, forHTTPHeaderField: "music-user-token")
        }

        let maxAttempts = 3
        var lastError: Error?

        for attempt in 0..<maxAttempts {
            try Task.checkCancellation()
            if let reqGen = generation, reqGen != activeGeneration {
                throw AppleMusicSessionError.sessionGenerationMismatch
            }

            let start = CFAbsoluteTimeGetCurrent()
            if attempt == 0 {
                let devSnippet = currentDevToken.prefix(12)
                let userSnippet = userToken.map { $0.prefix(12) + "..." } ?? "未登录"
                AppLogger.shared.log(
                    category: .ampAPI,
                    level: .info,
                    message: "发起 Amp-API 请求: GET \(url.path)",
                    details: "URL: \(url.absoluteString)\nNeedAuth: \(needAuth), UserToken: \(userToken != nil) [\(userSnippet)], DevToken: \(devSnippet)..."
                )
            }

            do {
                let (data, response) = try await session.data(for: req)
                if let reqGen = generation, reqGen != activeGeneration {
                    AppLogger.shared.log(category: .ampAPI, level: .warn, message: "丢弃过期会话数据 (请求世代: \(reqGen) != 当前世代: \(self.activeGeneration))")
                    throw AppleMusicSessionError.sessionGenerationMismatch
                }

                let durationMs = Int((CFAbsoluteTimeGetCurrent() - start) * 1000)
                let http = response as? HTTPURLResponse
                let statusCode = http?.statusCode ?? 0

                if statusCode == 200 {
                    var summary = "路径: \(url.path)"
                    if let contentType = http?.value(forHTTPHeaderField: "Content-Type") {
                        summary += "\n类型: \(contentType)"
                    }
                    if let cacheControl = http?.value(forHTTPHeaderField: "Cache-Control") {
                        summary += "\n缓存头: \(cacheControl)"
                    }
                    if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                        if let dataArr = json["data"] as? [[String: Any]] {
                            summary += "\n返回数据项: 共 \(dataArr.count) 条"
                            if let first = dataArr.first, let attrs = first["attributes"] as? [String: Any] {
                                let name = (attrs["name"] as? String) ?? (attrs["title"] as? String) ?? ""
                                summary += " (首项: \(name.isEmpty ? (first["id"] as? String ?? "") : name))"
                            }
                        } else if let results = json["results"] as? [String: Any] {
                            summary += "\n检索结果模块: \(results.keys.joined(separator: ", "))"
                        }
                    }
                    AppLogger.shared.log(
                        category: .ampAPI,
                        level: .info,
                        message: "Amp-API 请求成功 [HTTP 200 OK] (耗时: \(durationMs)ms, 大小: \(data.count) 字节)",
                        details: summary
                    )
                    return data
                } else if statusCode == 401 || statusCode == 403 {
                    let bodySnippet = String(data: data.prefix(500), encoding: .utf8) ?? "(binary)"
                    AppLogger.shared.log(
                        category: .auth,
                        level: .warn,
                        message: "Amp-API 鉴权失效 [HTTP \(statusCode)] (耗时: \(durationMs)ms)",
                        details: "路径: \(url.path)\n响应内容: \(bodySnippet)"
                    )
                    if needAuth {
                        onSessionExpired?()
                        throw AuthenticationError.tokenExpired
                    }
                    throw AppleMusicSessionError.tokenVerificationFailed(statusCode: statusCode, message: "未授权")
                } else if (statusCode == 429 || (500..<600).contains(statusCode)) && attempt < maxAttempts - 1 {
                    let retryAfterHeader = http?.value(forHTTPHeaderField: "Retry-After").flatMap(Double.init)
                    let waitSeconds = retryAfterHeader ?? pow(2.0, Double(attempt)) * 0.5
                    AppLogger.shared.log(
                        category: .ampAPI,
                        level: .warn,
                        message: "Amp-API 遇到 [HTTP \(statusCode)]，\(String(format: "%.1f", waitSeconds))s 后重试 [\(attempt + 1)/\(maxAttempts - 1)]"
                    )
                    lastError = AppleMusicSessionError.tokenVerificationFailed(statusCode: statusCode, message: "HTTP \(statusCode)")
                    try await Task.sleep(nanoseconds: UInt64(waitSeconds * 1_000_000_000))
                    continue
                } else {
                    let bodySnippet = String(data: data.prefix(500), encoding: .utf8) ?? "(binary)"
                    AppLogger.shared.log(
                        category: .error,
                        level: .error,
                        message: "Amp-API 状态码异常 [HTTP \(statusCode)] (耗时: \(durationMs)ms)",
                        details: "路径: \(url.path)\n响应内容: \(bodySnippet)"
                    )
                    throw AppleMusicSessionError.tokenVerificationFailed(statusCode: statusCode, message: "HTTP \(statusCode)")
                }
            } catch let err as URLError where err.code == .notConnectedToInternet {
                throw AppleMusicSessionError.networkUnavailable
            } catch let err as URLError where (err.code == .timedOut || err.code == .networkConnectionLost) && attempt < maxAttempts - 1 {
                lastError = err
                let delay = UInt64(pow(2.0, Double(attempt)) * 500_000_000)
                try await Task.sleep(nanoseconds: delay)
            }
        }
        throw lastError ?? AppleMusicSessionError.networkUnavailable
    }

    private func formatArtworkURL(_ raw: String?, size: Int = 240) -> URL? {
        guard let raw else { return nil }
        let formatted = raw
            .replacingOccurrences(of: "{w}x{h}", with: "\(size)x\(size)")
            .replacingOccurrences(of: "{c}", with: "bb")
            .replacingOccurrences(of: "{f}", with: "webp")
        return URL(string: formatted)
    }

    // MARK: - Public API: Charts (Top Songs)

    public func fetchCharts(limit: Int = 25, generation: Int? = nil) async throws -> [MusicTrack] {
        guard let url = URL(string: "https://amp-api.music.apple.com/v1/catalog/\(storefront)/charts?types=songs&limit=\(limit)&l=zh-Hans-CN&platform=web") else {
            return []
        }
        let data = try await execute(url: url, generation: generation)
        let songs = parseChartsSongs(data: data)
        AppLogger.shared.log(
            category: .ampAPI,
            level: .info,
            message: "解析 Top Charts 曲目完成: 获得 \(songs.count) 首歌曲",
            details: songs.first.map { "首曲: \($0.title) - \($0.artistName)" }
        )
        return songs
    }

    // MARK: - Public API: New Releases (Albums)

    public func fetchNewReleases(limit: Int = 25, generation: Int? = nil) async throws -> [MusicAlbum] {
        guard let url = URL(string: "https://amp-api.music.apple.com/v1/catalog/\(storefront)/charts?types=albums&limit=\(limit)&l=zh-Hans-CN&platform=web") else {
            return []
        }
        let data = try await execute(url: url, generation: generation)
        let albums = parseChartsAlbums(data: data)
        AppLogger.shared.log(
            category: .ampAPI,
            level: .info,
            message: "解析新发布专辑完成: 获得 \(albums.count) 张专辑",
            details: albums.first.map { "首张: \($0.title) - \($0.artistName)" }
        )
        return albums
    }

    // MARK: - Public API: Search

    public func search(term: String, limit: Int = 25, generation: Int? = nil) async throws -> MusicSearchResult {
        guard !term.trimmingCharacters(in: .whitespaces).isEmpty,
              let encoded = term.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "https://amp-api.music.apple.com/v1/catalog/\(storefront)/search?term=\(encoded)&types=songs,albums,artists,playlists&limit=\(limit)&relate[songs]=artists&include[songs]=artists&include[albums]=artists&art[url]=f&l=zh-Hans-CN&platform=web") else {
            return MusicSearchResult()
        }
        let data = try await execute(url: url, generation: generation)
        let result = parseSearchResult(data: data)
        AppLogger.shared.log(
            category: .ampAPI,
            level: .info,
            message: "目录搜索 \"\(term)\" 完成: \(result.tracks.count) 首单曲, \(result.albums.count) 张专辑, \(result.artists.count) 位艺人, \(result.playlists.count) 个歌单"
        )
        return result
    }

    public func searchLibrary(term: String, limit: Int = 25, generation: Int? = nil) async throws -> MusicSearchResult {
        guard !term.trimmingCharacters(in: .whitespaces).isEmpty,
              let encoded = term.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              userToken != nil,
              let url = URL(string: "https://amp-api.music.apple.com/v1/me/library/search?term=\(encoded)&types=library-songs,library-albums,library-artists,library-playlists&limit=\(limit)&include=catalog&art[url]=f&l=zh-Hans-CN&platform=web") else {
            return MusicSearchResult()
        }
        let data = try await execute(url: url, needAuth: true, generation: generation)
        let result = parseLibrarySearchResult(data: data)
        AppLogger.shared.log(
            category: .ampAPI,
            level: .info,
            message: "资料库搜索 \"\(term)\" 完成: \(result.tracks.count) 首单曲, \(result.albums.count) 张专辑, \(result.artists.count) 位艺人, \(result.playlists.count) 个歌单"
        )
        return result
    }

    // MARK: - Public API: Personal Recommendations (Listen Now / 听见)

    public func fetchPersonalRecommendations(generation: Int? = nil) async throws -> [AmpCategory] {
        guard userToken != nil else { return [] }
        guard let url = URL(string: "https://amp-api.music.apple.com/v1/me/recommendations?art%5Burl%5D=f&displayFilter%5Bkind%5D=MusicCircleCoverShelf%2CMusicConcertsEmptyShelf%2CMusicCoverGrid%2CMusicCoverShelf%2CMusicNotesHeroShelf%2CMusicSocialCardShelf%2CMusicSuperHeroShelf&extend=editorialArtwork%2CeditorialVideo%2CplainEditorialCard%2CplainEditorialNotes&extend%5Bplaylists%5D=artistNames&extend%5Bstations%5D=airTime%2CsupportsAirTimeUpdates&fields%5Bartists%5D=name%2Cartwork%2Curl&format%5Bresources%5D=map&include%5Balbums%5D=artists&include%5Blibrary-playlists%5D=catalog&include%5Bpersonal-recommendation%5D=primary-content&include%5Bstations%5D=radio-show&l=zh-Hans-CN&meta%5Bstations%5D=inflectionPoints&name=listen-now&omit%5Bresource%5D=autos&platform=web&timezone=%2B08%3A00&types=activities%2Calbums%2Capple-curators%2Cartists%2Cconcerts%2Ccurators%2Ceditorial-items%2Clibrary-albums%2Clibrary-playlists%2Cmusic-movies%2Cmusic-videos%2Cplaylists%2Csocial-profiles%2Csocial-upsells%2Csongs%2Cstations%2Ctv-episodes%2Ctv-shows%2Cuploaded-audios%2Cuploaded-videos&with=friendsMix%2Clibrary%2Csocial") else {
            return []
        }
        let data = try await execute(url: url, needAuth: true, generation: generation)
        let categories = parsePersonalRecommendations(data: data)
        AppLogger.shared.log(
            category: .ampAPI,
            level: .info,
            message: "拉取个性化推荐 (Listen Now) 成功: 获得 \(categories.count) 个推荐板块",
            details: categories.map(\.title).joined(separator: ", ")
        )
        return categories
    }

    // MARK: - Public API: Recently Added Items

    public func fetchRecentlyAdded(limit: Int = 25, generation: Int? = nil) async throws -> [AmpCategoryItem] {
        guard userToken != nil,
              let url = URL(string: "https://amp-api.music.apple.com/v1/me/library/recently-added?art[url]=f&limit=\(limit)&l=zh-Hans-CN&platform=web") else {
            return []
        }
        let data = try await execute(url: url, needAuth: true, generation: generation)
        return parseRecentlyAdded(data: data)
    }

    // MARK: - Public API: Lyrics & Catalog Resolution

    public func resolveCatalogSongID(librarySongID: String, generation: Int? = nil) async -> String? {
        if let cached = resolvedCatalogIDs[librarySongID] { return cached }
        let cleanID = librarySongID.hasPrefix("i.") ? String(librarySongID.dropFirst(2)) : (librarySongID.hasPrefix("a.") ? String(librarySongID.dropFirst(2)) : librarySongID)
        guard userToken != nil,
              let url = URL(string: "https://amp-api.music.apple.com/v1/me/library/songs/\(cleanID)?include=catalog&platform=web&l=zh-Hans-CN") else {
            return nil
        }
        guard let data = try? await execute(url: url, needAuth: true, generation: generation),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let dataArr = json["data"] as? [[String: Any]],
              let first = dataArr.first,
              let rel = first["relationships"] as? [String: Any],
              let cat = rel["catalog"] as? [String: Any],
              let catData = cat["data"] as? [[String: Any]],
              let firstCat = catData.first,
              let cid = firstCat["id"] as? String else {
            return nil
        }
        resolvedCatalogIDs[librarySongID] = cid
        return cid
    }

    public func fetchSongLyricsTTML(songID: String, generation: Int? = nil) async throws -> String? {
        if songID.hasPrefix("ra.") { return nil }
        var effectiveID = songID
        if songID.hasPrefix("a.") || songID.hasPrefix("i.") {
            if let resolved = await resolveCatalogSongID(librarySongID: songID, generation: generation) {
                effectiveID = resolved
            } else {
                let stripped = songID.dropFirst(2)
                if CharacterSet.decimalDigits.isSuperset(of: CharacterSet(charactersIn: String(stripped))) {
                    effectiveID = String(stripped)
                }
            }
        }
        guard userToken != nil,
              let url = URL(string: "https://amp-api.music.apple.com/v1/catalog/\(storefront)/songs/\(effectiveID)/lyrics?l=zh-Hans-CN&platform=web") else {
            return nil
        }
        let data = try await execute(url: url, needAuth: true, generation: generation)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let dataArr = json["data"] as? [[String: Any]],
              let first = dataArr.first,
              let attrs = first["attributes"] as? [String: Any],
              let ttml = attrs["ttml"] as? String else {
            AppLogger.shared.log(category: .ampAPI, level: .info, message: "Amp-API 响应中无可用 TTML 歌词 (ID: \(effectiveID))")
            return nil
        }
        AppLogger.shared.log(category: .ampAPI, level: .info, message: "Amp-API 成功提取曲目 [\(effectiveID)] 官方 TTML 歌词 (长度: \(ttml.count) 字符)")
        return ttml
    }

    public func fetchFavoriteSongsPlaylist(generation: Int? = nil) async throws -> [MusicTrack] {
        guard userToken != nil else { return [] }
        let playlists = (try? await fetchLibraryPlaylists(limit: 100, generation: generation)) ?? []
        guard let favPlaylist = playlists.first(where: {
            let lower = $0.name.lowercased()
            return lower == "favorite songs" || $0.name == "喜爱的歌曲" || $0.name == "我喜欢的音乐"
        }) else {
            return []
        }
        return (try? await fetchPlaylistTracks(playlistID: favPlaylist.id, isLibrary: true, limit: 100, generation: generation)) ?? []
    }

    // MARK: - Public API: Library Artists

    public func fetchLibraryArtists(limit: Int = 50, generation: Int? = nil) async throws -> [MusicArtist] {
        guard userToken != nil,
              let url = URL(string: "https://amp-api.music.apple.com/v1/me/library/artists?include=catalog&art[url]=f&limit=\(limit)&l=zh-Hans-CN&platform=web") else {
            return []
        }
        let data = try await execute(url: url, needAuth: true, generation: generation)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = json["data"] as? [[String: Any]] else {
            return []
        }
        return items.compactMap { parseLibraryArtistItem($0) }
    }

    // MARK: - Public API: Made For You Playlists

    public func fetchMadeForYouPlaylists(generation: Int? = nil) async throws -> [MusicPlaylist] {
        guard userToken != nil,
              let url = URL(string: "https://amp-api.music.apple.com/v1/me/library/playlists?sort=type&filter[featured]=made-for-you&include[library-playlists]=catalog&fields[library-playlists]=artwork,dateAdded,name,playParams&l=zh-Hans-CN&platform=web") else {
            return []
        }
        let data = try await execute(url: url, needAuth: true, generation: generation)
        return parsePlaylistsData(data: data)
    }

    // MARK: - Public API: Playlists Split (User Created vs Favorite / Subscribed)

    public func fetchLibraryPlaylistsSplit(limit: Int = 100, generation: Int? = nil) async throws -> (all: [MusicPlaylist], user: [MusicPlaylist], favorite: [MusicPlaylist]) {
        guard userToken != nil,
              let url = URL(string: "https://amp-api.music.apple.com/v1/me/library/playlists?art[url]=f&include=catalog&limit=\(limit)&l=zh-Hans-CN&platform=web") else {
            return ([], [], [])
        }
        let data = try await execute(url: url, needAuth: true, generation: generation)
        let all = parsePlaylistsData(data: data)
        let user = all.filter { $0.isEditable }
        let favorite = all.filter { !$0.isEditable }
        return (all, user, favorite)
    }

    // MARK: - Public API: Library Items (User Authenticated or Charts Fallback)

    public func fetchLibrarySongs(limit: Int = 50, generation: Int? = nil) async throws -> [MusicTrack] {
        guard userToken != nil,
              let url = URL(string: "https://amp-api.music.apple.com/v1/me/library/songs?include=catalog&limit=\(limit)&l=zh-Hans-CN&platform=web") else {
            AppLogger.shared.log(category: .auth, level: .info, message: "未登录个人资料库，回退至精选热门榜单")
            return try await fetchCharts(limit: limit, generation: generation)
        }
        do {
            let data = try await execute(url: url, needAuth: true, generation: generation)
            let tracks = parseSongsData(data: data)
            return tracks.isEmpty ? (try await fetchCharts(limit: limit, generation: generation)) : tracks
        } catch {
            return try await fetchCharts(limit: limit, generation: generation)
        }
    }

    public func fetchLibraryPlaylists(limit: Int = 50, generation: Int? = nil) async throws -> [MusicPlaylist] {
        guard userToken != nil,
              let url = URL(string: "https://amp-api.music.apple.com/v1/me/library/playlists?limit=\(limit)&l=zh-Hans-CN&platform=web") else {
            AppLogger.shared.log(category: .auth, level: .info, message: "未登录个人歌单，返回空歌单列表")
            return []
        }
        let data = try await execute(url: url, needAuth: true, generation: generation)
        return parsePlaylistsData(data: data)
    }

    public func fetchLibraryAlbums(limit: Int = 50, generation: Int? = nil) async throws -> [MusicAlbum] {
        guard userToken != nil,
              let url = URL(string: "https://amp-api.music.apple.com/v1/me/library/albums?limit=\(limit)&l=zh-Hans-CN&platform=web") else {
            AppLogger.shared.log(category: .auth, level: .info, message: "未登录个人专辑，回退至新发行专辑榜")
            return try await fetchNewReleases(limit: limit, generation: generation)
        }
        do {
            let data = try await execute(url: url, needAuth: true, generation: generation)
            let albums = parseAlbumsData(data: data)
            return albums.isEmpty ? (try await fetchNewReleases(limit: limit, generation: generation)) : albums
        } catch {
            return try await fetchNewReleases(limit: limit, generation: generation)
        }
    }

    // MARK: - Collection Detail Tracks (Albums & Playlists & Artists)

    public func fetchAlbumTracks(albumID: String, isLibrary: Bool? = nil, limit: Int = 100, generation: Int? = nil) async throws -> [MusicTrack] {
        let isLib = isLibrary ?? (albumID.hasPrefix("l.") || albumID.hasPrefix("i."))
        let urlStr = isLib
            ? "https://amp-api.music.apple.com/v1/me/library/albums/\(albumID)/tracks?include=catalog&limit=\(limit)&l=zh-Hans-CN&platform=web"
            : "https://amp-api.music.apple.com/v1/catalog/\(storefront)/albums/\(albumID)/tracks?limit=\(limit)&l=zh-Hans-CN&platform=web"

        guard let url = URL(string: urlStr) else { return [] }
        let data = try await execute(url: url, needAuth: isLib, generation: generation)
        let tracks = parseSongsData(data: data)
        AppLogger.shared.log(
            category: .ampAPI,
            level: .info,
            message: "拉取\(isLib ? "资料库" : "目录")专辑 [\(albumID)] 曲目列表完成: 共 \(tracks.count) 首",
            details: tracks.first.map { "首曲: \($0.title) - \($0.artistName)" }
        )
        return tracks
    }

    public func fetchPlaylistTracks(playlistID: String, isLibrary: Bool? = nil, limit: Int = 100, generation: Int? = nil) async throws -> [MusicTrack] {
        let isLib = isLibrary ?? (playlistID.hasPrefix("p.") || playlistID.hasPrefix("l."))
        let urlStr = isLib
            ? "https://amp-api.music.apple.com/v1/me/library/playlists/\(playlistID)/tracks?include=catalog&limit=\(limit)&l=zh-Hans-CN&platform=web"
            : "https://amp-api.music.apple.com/v1/catalog/\(storefront)/playlists/\(playlistID)/tracks?limit=\(limit)&l=zh-Hans-CN&platform=web"

        guard let url = URL(string: urlStr) else { return [] }
        let data = try await execute(url: url, needAuth: isLib, generation: generation)
        let tracks = parseSongsData(data: data)
        AppLogger.shared.log(
            category: .ampAPI,
            level: .info,
            message: "拉取\(isLib ? "资料库" : "目录")歌单 [\(playlistID)] 曲目列表完成: 共 \(tracks.count) 首",
            details: tracks.first.map { "首曲: \($0.title) - \($0.artistName)" }
        )
        return tracks
    }

    public func fetchArtistTopSongs(artistID: String, isLibrary: Bool? = nil, limit: Int = 100, generation: Int? = nil) async throws -> [MusicTrack] {
        let isLib = isLibrary ?? (artistID.hasPrefix("l.") || artistID.hasPrefix("i."))
        let urlStr = isLib
            ? "https://amp-api.music.apple.com/v1/me/library/artists/\(artistID)/tracks?limit=\(limit)&l=zh-Hans-CN&platform=web"
            : "https://amp-api.music.apple.com/v1/catalog/\(storefront)/artists/\(artistID)/view/top-songs?limit=\(limit)&l=zh-Hans-CN&platform=web"

        guard let url = URL(string: urlStr) else { return [] }
        let data = try await execute(url: url, needAuth: isLib, generation: generation)
        let tracks = parseSongsData(data: data)
        AppLogger.shared.log(
            category: .ampAPI,
            level: .info,
            message: "拉取\(isLib ? "资料库" : "目录")艺人 [\(artistID)] 曲目列表完成: 共 \(tracks.count) 首"
        )
        return tracks
    }

    // MARK: - Public API: Pagination Support

    public func fetchNextPage(nextURL: URL, isLibrary: Bool, generation: Int? = nil) async throws -> (items: [AmpCategoryItem], nextURL: URL?) {
        let data = try await execute(url: nextURL, needAuth: isLibrary, generation: generation)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let dataArr = json["data"] as? [[String: Any]] else {
            return ([], nil)
        }
        var next: URL? = nil
        if let nextStr = json["next"] as? String {
            let fullStr = nextStr.hasPrefix("http") ? nextStr : "https://amp-api.music.apple.com\(nextStr)"
            next = URL(string: fullStr)
        }
        var items: [AmpCategoryItem] = []
        for d in dataArr {
            let dtype = d["type"] as? String ?? ""
            let did = d["id"] as? String ?? ""
            if dtype.contains("song") {
                if let tr = parseTrackItem(d) {
                    items.append(AmpCategoryItem(id: did, title: tr.title, subtitle: tr.artistName, type: "song", artworkURL: tr.artworkURL, durationMs: tr.durationMs, track: tr, isLibrary: isLibrary))
                }
            } else if dtype.contains("album") {
                if let al = parseAlbumItem(d) {
                    items.append(AmpCategoryItem(id: did, title: al.title, subtitle: al.artistName, type: "album", artworkURL: al.artworkURL, album: al, isLibrary: isLibrary))
                }
            } else if dtype.contains("artist") {
                let ar = isLibrary ? parseLibraryArtistItem(d) : parseArtistItem(d)
                if let ar {
                    items.append(AmpCategoryItem(id: did, title: ar.name, subtitle: "艺人", type: "artist", artworkURL: ar.artworkURL, artist: ar, isLibrary: isLibrary))
                }
            } else if dtype.contains("playlist") {
                if let pl = parsePlaylistItem(d) {
                    items.append(AmpCategoryItem(id: did, title: pl.name, subtitle: pl.ownerName ?? "歌单", type: "playlist", artworkURL: pl.artworkURL, playlist: pl, isLibrary: isLibrary))
                }
            }
        }
        return (items, next)
    }

    // MARK: - Public API: Editorial Groupings (Browse / Radio)

    public func fetchEditorialGroupings(name: String = "music", generation: Int? = nil) async throws -> [AmpCategory] {
        guard let url = URL(string: "https://amp-api-edge.music.apple.com/v1/editorial/\(storefront)/groupings?art[url]=c,f&format[resources]=map&include[albums]=artists&include[music-videos]=artists&include[songs]=artists&include[stations]=events,radio-show&l=zh-Hans-CN&name=\(name)&platform=web&tabs=subscriber") else {
            return []
        }
        let data = try await execute(url: url, generation: generation)
        return parseEditorialGroupings(data: data)
    }

    // MARK: - Parsing Helpers

    private func parseEditorialGroupings(data: Data) -> [AmpCategory] {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let res = json["resources"] as? [String: Any],
              let groupings = res["groupings"] as? [String: Any],
              let dataArr = json["data"] as? [[String: Any]],
              let firstId = dataArr.first?["id"] as? String,
              let grp = groupings[firstId] as? [String: Any],
              let rel = grp["relationships"] as? [String: Any],
              let tabsData = (rel["tabs"] as? [String: Any])?["data"] as? [[String: Any]],
              let tabId = tabsData.first?["id"] as? String,
              let editorialElements = res["editorial-elements"] as? [String: Any],
              let tab = editorialElements[tabId] as? [String: Any],
              let children = ((tab["relationships"] as? [String: Any])?["children"] as? [String: Any])?["data"] as? [[String: Any]] else {
            return []
        }

        var result: [AmpCategory] = []

        for c in children {
            guard let ctype = c["type"] as? String,
                  let cid = c["id"] as? String,
                  let el = (res[ctype] as? [String: Any])?[cid] as? [String: Any] else {
                continue
            }
            let attrs = el["attributes"] as? [String: Any] ?? [:]
            let titleObj = attrs["title"] as? [String: Any]
            let title = titleObj?["stringForDisplay"] as? String ?? attrs["name"] as? String
            guard let title = title, !title.isEmpty else { continue }

            let elRel = el["relationships"] as? [String: Any] ?? [:]
            let contents = ((elRel["contents"] as? [String: Any])?["data"] as? [[String: Any]])
                        ?? ((elRel["children"] as? [String: Any])?["data"] as? [[String: Any]]) ?? []

            var items: [AmpCategoryItem] = []
            for itemRef in contents {
                guard let itype = itemRef["type"] as? String,
                      let iid = itemRef["id"] as? String,
                      let itemData = (res[itype] as? [String: Any])?[iid] as? [String: Any] else {
                    continue
                }
                let iAttrs = itemData["attributes"] as? [String: Any] ?? [:]
                let name = iAttrs["name"] as? String ?? ""
                let artist = iAttrs["artistName"] as? String ?? ""
                let rawArt = (iAttrs["artwork"] as? [String: Any])?["url"] as? String
                let artURL = formatArtworkURL(rawArt)

                switch itype {
                case "songs":
                    let duration = (iAttrs["durationInMillis"] as? NSNumber)?.int64Value
                    let track = parseTrackItem(itemData)
                    items.append(AmpCategoryItem(
                        id: iid,
                        title: name,
                        subtitle: artist,
                        type: "song",
                        artworkURL: artURL,
                        durationMs: duration,
                        track: track,
                        album: nil,
                        playlist: nil
                    ))
                case "albums":
                    let count = iAttrs["trackCount"] as? Int ?? 0
                    let album = parseAlbumItem(itemData)
                    items.append(AmpCategoryItem(
                        id: iid,
                        title: name,
                        subtitle: "\(artist) · \(count) 首",
                        type: "album",
                        artworkURL: artURL,
                        durationMs: nil,
                        track: nil,
                        album: album,
                        playlist: nil
                    ))
                case "playlists":
                    let playlist = MusicPlaylist(
                        id: iid,
                        name: name,
                        artworkURL: artURL,
                        trackIDs: [],
                        providerID: "apple_music",
                        providerPlaylistID: iid
                    )
                    items.append(AmpCategoryItem(
                        id: iid,
                        title: name,
                        subtitle: artist.isEmpty ? "歌单" : artist,
                        type: "playlist",
                        artworkURL: artURL,
                        durationMs: nil,
                        track: nil,
                        album: nil,
                        playlist: playlist
                    ))
                case "stations":
                    items.append(AmpCategoryItem(
                        id: iid,
                        title: name,
                        subtitle: artist.isEmpty ? "电台" : artist,
                        type: "station",
                        artworkURL: artURL,
                        durationMs: nil,
                        track: MusicTrack(id: iid, title: name, artistName: artist, source: .appleMusic),
                        album: nil,
                        playlist: nil
                    ))
                default:
                    break
                }
            }

            if !items.isEmpty {
                result.append(AmpCategory(id: cid, title: title, items: items))
            }
        }

        AppLogger.shared.log(
            category: .ampAPI,
            level: .info,
            message: "解析 Editorial Groupings [\(result.count) 个分类]: \(result.map(\.title).joined(separator: ", "))"
        )
        return result
    }

    private func parseChartsSongs(data: Data) -> [MusicTrack] {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = json["results"] as? [String: Any],
              let songs = results["songs"] as? [[String: Any]],
              let firstChart = songs.first,
              let chartData = firstChart["data"] as? [[String: Any]] else {
            return []
        }
        return chartData.compactMap { parseTrackItem($0) }
    }

    private func parseChartsAlbums(data: Data) -> [MusicAlbum] {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = json["results"] as? [String: Any],
              let albums = results["albums"] as? [[String: Any]],
              let firstChart = albums.first,
              let chartData = firstChart["data"] as? [[String: Any]] else {
            return []
        }
        return chartData.compactMap { parseAlbumItem($0) }
    }

    private func parseSearchResult(data: Data) -> MusicSearchResult {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = json["results"] as? [String: Any] else {
            return MusicSearchResult()
        }

        var tracks: [MusicTrack] = []
        if let songsSection = results["songs"] as? [String: Any],
           let items = songsSection["data"] as? [[String: Any]] {
            tracks = items.compactMap { parseTrackItem($0) }
        }

        var albums: [MusicAlbum] = []
        if let albumsSection = results["albums"] as? [String: Any],
           let items = albumsSection["data"] as? [[String: Any]] {
            albums = items.compactMap { parseAlbumItem($0) }
        }

        var artists: [MusicArtist] = []
        if let artistsSection = results["artists"] as? [String: Any],
           let items = artistsSection["data"] as? [[String: Any]] {
            artists = items.compactMap { parseArtistItem($0) }
        }

        var playlists: [MusicPlaylist] = []
        if let playlistsSection = results["playlists"] as? [String: Any],
           let items = playlistsSection["data"] as? [[String: Any]] {
            playlists = items.compactMap { parsePlaylistItem($0) }
        }

        return MusicSearchResult(tracks: tracks, albums: albums, artists: artists, playlists: playlists)
    }

    private func parseLibrarySearchResult(data: Data) -> MusicSearchResult {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = json["results"] as? [String: Any] else {
            return MusicSearchResult()
        }

        var tracks: [MusicTrack] = []
        if let sec = results["library-songs"] as? [String: Any],
           let items = sec["data"] as? [[String: Any]] {
            tracks = items.compactMap { parseTrackItem($0) }
        }

        var albums: [MusicAlbum] = []
        if let sec = results["library-albums"] as? [String: Any],
           let items = sec["data"] as? [[String: Any]] {
            albums = items.compactMap { parseAlbumItem($0) }
        }

        var artists: [MusicArtist] = []
        if let sec = results["library-artists"] as? [String: Any],
           let items = sec["data"] as? [[String: Any]] {
            artists = items.compactMap { parseLibraryArtistItem($0) }
        }

        var playlists: [MusicPlaylist] = []
        if let sec = results["library-playlists"] as? [String: Any],
           let items = sec["data"] as? [[String: Any]] {
            playlists = items.compactMap { parsePlaylistItem($0) }
        }

        return MusicSearchResult(tracks: tracks, albums: albums, artists: artists, playlists: playlists)
    }

    private func parseRecentlyAdded(data: Data) -> [AmpCategoryItem] {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = json["data"] as? [[String: Any]] else {
            return []
        }
        var result: [AmpCategoryItem] = []
        for item in items {
            guard let id = item["id"] as? String else { continue }
            let itemType = item["type"] as? String ?? ""
            let attrs = item["attributes"] as? [String: Any] ?? [:]
            let name = attrs["name"] as? String ?? "未知项目"
            let artist = attrs["artistName"] as? String ?? "资料库"
            let rawArt = (attrs["artwork"] as? [String: Any])?["url"] as? String
            let artURL = formatArtworkURL(rawArt)
            let duration = (attrs["durationInMillis"] as? NSNumber)?.int64Value

            if itemType == "library-albums" || itemType == "albums" {
                let album = parseAlbumItem(item)
                result.append(AmpCategoryItem(id: id, title: name, subtitle: artist, type: "album", artworkURL: artURL, album: album, isLibrary: true))
            } else if itemType == "library-playlists" || itemType == "playlists" {
                let pl = parsePlaylistItem(item)
                result.append(AmpCategoryItem(id: id, title: name, subtitle: artist, type: "playlist", artworkURL: artURL, playlist: pl, isLibrary: true))
            } else if itemType == "library-songs" || itemType == "songs" {
                let tr = parseTrackItem(item)
                result.append(AmpCategoryItem(id: id, title: name, subtitle: artist, type: "song", artworkURL: artURL, durationMs: duration, track: tr, isLibrary: true))
            } else if itemType == "library-artists" || itemType == "artists" {
                let ar = parseLibraryArtistItem(item)
                result.append(AmpCategoryItem(id: id, title: name, subtitle: artist, type: "artist", artworkURL: artURL, artist: ar, isLibrary: true))
            }
        }
        return result
    }

    private func parsePersonalRecommendations(data: Data) -> [AmpCategory] {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let dataArr = json["data"] as? [[String: Any]],
              let resources = json["resources"] as? [String: Any] else {
            return []
        }
        let recs = resources["personal-recommendation"] as? [String: Any] ?? [:]
        var categories: [AmpCategory] = []

        for (idx, d) in dataArr.enumerated() {
            guard let id = d["id"] as? String,
                  let rec = recs[id] as? [String: Any] else {
                continue
            }
            let attrs = rec["attributes"] as? [String: Any] ?? [:]
            let titleObj = attrs["title"] as? [String: Any]
            let title = titleObj?["stringForDisplay"] as? String ?? titleObj?["text"] as? String ?? attrs["name"] as? String ?? "推荐板块 \(idx + 1)"

            let rel = rec["relationships"] as? [String: Any] ?? [:]
            let contentsData = (rel["contents"] as? [String: Any])?["data"] as? [[String: Any]] ?? []

            var items: [AmpCategoryItem] = []
            for ref in contentsData {
                if let item = resolveResourceItem(ref: ref, resources: resources) {
                    items.append(item)
                }
            }
            if !items.isEmpty {
                categories.append(AmpCategory(id: "section-\(idx + 1)", title: title, items: items))
            }
        }
        return categories
    }

    private func resolveResourceItem(ref: [String: Any], resources: [String: Any]) -> AmpCategoryItem? {
        guard let refType = ref["type"] as? String,
              let refId = ref["id"] as? String,
              let item = (resources[refType] as? [String: Any])?[refId] as? [String: Any] else {
            return nil
        }
        var target = item
        var targetType = item["type"] as? String ?? refType
        var targetId = item["id"] as? String ?? refId

        if let rel = item["relationships"] as? [String: Any],
           let contents = rel["contents"] as? [String: Any],
           let cData = contents["data"] as? [[String: Any]],
           let firstRef = cData.first,
           let fType = firstRef["type"] as? String,
           let fId = firstRef["id"] as? String,
           let nested = (resources[fType] as? [String: Any])?[fId] as? [String: Any] {
            target = nested
            targetType = nested["type"] as? String ?? fType
            targetId = nested["id"] as? String ?? fId
        }

        let attrs = target["attributes"] as? [String: Any] ?? item["attributes"] as? [String: Any] ?? [:]
        let name = attrs["name"] as? String ?? attrs["title"] as? String ?? (item["attributes"] as? [String: Any])?["designBadge"] as? String ?? "推荐精选"

        let artistName = attrs["artistName"] as? String
        let curatorName = attrs["curatorName"] as? String
        let descStandard = (attrs["description"] as? [String: Any])?["standard"] as? String
        let subtitle = artistName ?? curatorName ?? (descStandard != nil ? String(descStandard!.prefix(36)) : "Apple Music")

        let rawArt = (attrs["artwork"] as? [String: Any])?["url"] as? String ?? (attrs["editorialArtwork"] as? [String: Any])?["url"] as? String
        let artURL = formatArtworkURL(rawArt)
        let duration = (attrs["durationInMillis"] as? NSNumber)?.int64Value

        let isLib = targetType.contains("library") || targetId.hasPrefix("p.") || targetId.hasPrefix("l.") || targetId.hasPrefix("i.")

        if targetType.contains("song") {
            let track = parseTrackItem(target)
            return AmpCategoryItem(id: targetId, title: name, subtitle: subtitle, type: "song", artworkURL: artURL, durationMs: duration, track: track, isLibrary: isLib)
        } else if targetType.contains("album") {
            let album = parseAlbumItem(target)
            return AmpCategoryItem(id: targetId, title: name, subtitle: subtitle, type: "album", artworkURL: artURL, album: album, isLibrary: isLib)
        } else if targetType.contains("playlist") {
            let pl = MusicPlaylist(
                id: targetId,
                name: name,
                description: descStandard ?? "",
                artworkURL: artURL,
                trackIDs: [],
                isEditable: attrs["canEdit"] as? Bool ?? false,
                ownerName: curatorName,
                providerID: "apple_music",
                providerPlaylistID: targetId
            )
            return AmpCategoryItem(id: targetId, title: name, subtitle: subtitle, type: "playlist", artworkURL: artURL, playlist: pl, isLibrary: isLib)
        } else if targetType.contains("station") {
            let tr = MusicTrack(id: targetId, title: name, artistName: subtitle, source: .appleMusic)
            return AmpCategoryItem(id: targetId, title: name, subtitle: subtitle, type: "station", artworkURL: artURL, track: tr, isLibrary: isLib)
        } else if targetType.contains("artist") {
            let ar = parseArtistItem(target)
            return AmpCategoryItem(id: targetId, title: name, subtitle: subtitle, type: "artist", artworkURL: artURL, artist: ar, isLibrary: isLib)
        } else {
            return AmpCategoryItem(id: targetId, title: name, subtitle: subtitle, type: "item", artworkURL: artURL, isLibrary: isLib)
        }
    }

    private func parseSongsData(data: Data) -> [MusicTrack] {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = json["data"] as? [[String: Any]] else {
            return []
        }
        return items.compactMap { parseTrackItem($0) }
    }

    private func parseAlbumsData(data: Data) -> [MusicAlbum] {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = json["data"] as? [[String: Any]] else {
            return []
        }
        return items.compactMap { parseAlbumItem($0) }
    }

    private func parsePlaylistsData(data: Data) -> [MusicPlaylist] {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = json["data"] as? [[String: Any]] else {
            return []
        }
        return items.compactMap { parsePlaylistItem($0) }
    }

    private func parsePlaylistItem(_ item: [String: Any]) -> MusicPlaylist? {
        guard let id = item["id"] as? String else { return nil }
        let attrs = item["attributes"] as? [String: Any] ?? [:]
        let name = attrs["name"] as? String ?? "未命名歌单"
        let desc = (attrs["description"] as? [String: Any])?["standard"] as? String ?? ""
        let rawArt = (attrs["artwork"] as? [String: Any])?["url"] as? String
        return MusicPlaylist(
            id: id,
            name: name,
            description: desc,
            artworkURL: formatArtworkURL(rawArt),
            trackIDs: [],
            isEditable: attrs["canEdit"] as? Bool ?? false,
            ownerName: attrs["curatorName"] as? String,
            providerID: "apple_music",
            providerPlaylistID: id
        )
    }

    private func parseLibraryArtistItem(_ item: [String: Any]) -> MusicArtist? {
        guard let id = item["id"] as? String else { return nil }
        let attrs = item["attributes"] as? [String: Any] ?? [:]
        let rel = item["relationships"] as? [String: Any]
        let catItem = (rel?["catalog"] as? [String: Any])?["data"] as? [[String: Any]]
        let catAttrs = catItem?.first?["attributes"] as? [String: Any]

        let name = attrs["name"] as? String ?? catAttrs?["name"] as? String ?? "未知艺人"
        let genres = catAttrs?["genreNames"] as? [String] ?? []
        let rawArt = (attrs["artwork"] as? [String: Any])?["url"] as? String ?? (catAttrs?["artwork"] as? [String: Any])?["url"] as? String

        return MusicArtist(
            id: id,
            name: name,
            artworkURL: formatArtworkURL(rawArt),
            genreNames: genres,
            providerID: "apple_music",
            providerArtistID: id
        )
    }

    private func parseTrackItem(_ item: [String: Any]) -> MusicTrack? {
        guard let id = item["id"] as? String else { return nil }
        var attrs = item["attributes"] as? [String: Any] ?? [:]

        var catalogID: String? = nil
        if let rel = item["relationships"] as? [String: Any],
           let cat = rel["catalog"] as? [String: Any],
           let catData = cat["data"] as? [[String: Any]],
           let firstCat = catData.first {
            catalogID = firstCat["id"] as? String
            if let catAttrs = firstCat["attributes"] as? [String: Any] {
                if attrs["artwork"] == nil, catAttrs["artwork"] != nil {
                    attrs["artwork"] = catAttrs["artwork"]
                }
                if (attrs["durationInMillis"] as? NSNumber)?.int64Value == nil, catAttrs["durationInMillis"] != nil {
                    attrs["durationInMillis"] = catAttrs["durationInMillis"]
                }
            }
        }
        if let cid = catalogID {
            resolvedCatalogIDs[id] = cid
        }

        let name = attrs["name"] as? String ?? "未知单曲"
        let artist = attrs["artistName"] as? String ?? "Apple Music"
        let album = attrs["albumName"] as? String ?? ""
        let durationMs = (attrs["durationInMillis"] as? NSNumber)?.int64Value ?? 0
        let rawArt = (attrs["artwork"] as? [String: Any])?["url"] as? String

        let effectiveTrackID = catalogID ?? id
        return MusicTrack(
            id: id,
            title: name,
            artistName: artist,
            albumTitle: album,
            durationMs: durationMs,
            artworkURL: formatArtworkURL(rawArt),
            providerID: "apple_music",
            providerTrackID: effectiveTrackID
        )
    }

    private func parseAlbumItem(_ item: [String: Any]) -> MusicAlbum? {
        guard let id = item["id"] as? String else { return nil }
        let attrs = item["attributes"] as? [String: Any] ?? [:]
        let name = attrs["name"] as? String ?? "未知专辑"
        let artist = attrs["artistName"] as? String ?? "Apple Music"
        let rawArt = (attrs["artwork"] as? [String: Any])?["url"] as? String
        let count = attrs["trackCount"] as? Int ?? 0

        return MusicAlbum(
            id: id,
            title: name,
            artistName: artist,
            artworkURL: formatArtworkURL(rawArt),
            trackCount: count,
            providerID: "apple_music",
            providerAlbumID: id
        )
    }

    private func parseArtistItem(_ item: [String: Any]) -> MusicArtist? {
        guard let id = item["id"] as? String else { return nil }
        let attrs = item["attributes"] as? [String: Any] ?? [:]
        let name = attrs["name"] as? String ?? "未知艺人"
        let genres = attrs["genreNames"] as? [String] ?? []
        let rawArt = (attrs["artwork"] as? [String: Any])?["url"] as? String

        return MusicArtist(
            id: id,
            name: name,
            artworkURL: formatArtworkURL(rawArt),
            genreNames: genres,
            providerID: "apple_music",
            providerArtistID: id
        )
    }
}
