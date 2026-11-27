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
    private var inFlightDevTokenTask: Task<String, Error>?
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
        if let existingTask = inFlightDevTokenTask {
            return try await existingTask.value
        }
        let task = Task<String, Error> {
            try await self.fetchPublicDeveloperToken()
        }
        inFlightDevTokenTask = task
        defer { inFlightDevTokenTask = nil }
        let token = try await task.value
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
            } catch is CancellationError {
                throw CancellationError()
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
        let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return MusicSearchResult() }
        var components = URLComponents()
        components.scheme = "https"
        components.host = "amp-api.music.apple.com"
        components.path = "/v1/catalog/\(storefront)/search"
        components.queryItems = [
            URLQueryItem(name: "term", value: trimmed),
            URLQueryItem(name: "types", value: "songs,albums,artists,playlists,stations,music-videos,apple-curators,curators"),
            URLQueryItem(name: "limit", value: "\(limit)"),
            URLQueryItem(name: "with", value: "topResults"),
            URLQueryItem(name: "relate[songs]", value: "artists"),
            URLQueryItem(name: "include[songs]", value: "artists"),
            URLQueryItem(name: "include[albums]", value: "artists"),
            URLQueryItem(name: "art[url]", value: "f"),
            URLQueryItem(name: "l", value: "zh-Hans-CN"),
            URLQueryItem(name: "platform", value: "web")
        ]
        guard let url = components.url else { return MusicSearchResult() }
        let data = try await execute(url: url, generation: generation)
        let result = parseSearchResult(data: data)
        AppLogger.shared.log(
            category: .ampAPI,
            level: .info,
            message: "目录搜索 \"\(trimmed)\" 完成: \(result.sections.count) 个分类, \(result.tracks.count) 首单曲, \(result.albums.count) 张专辑, \(result.artists.count) 位艺人, \(result.playlists.count) 个歌单, \(result.stations.count) 个电台"
        )
        return result
    }

    public func searchLibrary(term: String, limit: Int = 25, generation: Int? = nil) async throws -> MusicSearchResult {
        let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, userToken != nil else { return MusicSearchResult() }
        var components = URLComponents()
        components.scheme = "https"
        components.host = "amp-api.music.apple.com"
        components.path = "/v1/me/library/search"
        components.queryItems = [
            URLQueryItem(name: "term", value: trimmed),
            URLQueryItem(name: "types", value: "library-songs,library-albums,library-artists,library-playlists"),
            URLQueryItem(name: "limit", value: "\(limit)"),
            URLQueryItem(name: "include", value: "catalog"),
            URLQueryItem(name: "art[url]", value: "f"),
            URLQueryItem(name: "l", value: "zh-Hans-CN"),
            URLQueryItem(name: "platform", value: "web")
        ]
        guard let url = components.url else { return MusicSearchResult() }
        let data = try await execute(url: url, needAuth: true, generation: generation)
        let result = parseLibrarySearchResult(data: data)
        AppLogger.shared.log(
            category: .ampAPI,
            level: .info,
            message: "资料库搜索 \"\(trimmed)\" 完成: \(result.sections.count) 个分类, \(result.tracks.count) 首单曲, \(result.albums.count) 张专辑, \(result.artists.count) 位艺人, \(result.playlists.count) 个歌单"
        )
        return result
    }

    /// Fetches the next page of results for a specific search section using the AMP `next` cursor path/URL.
    public func fetchSearchPage(
        nextPath: String,
        isLibrary: Bool,
        limit: Int = 25,
        generation: Int? = nil
    ) async throws -> (items: [MusicSearchItem], nextURL: String?) {
        let trimmed = nextPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return ([], nil) }
        if isLibrary && userToken == nil { return ([], nil) }

        let base = trimmed.hasPrefix("http") ? trimmed : "https://amp-api.music.apple.com\(trimmed)"
        var components = URLComponents(string: base)
        var queryItems = components?.queryItems ?? []
        if !queryItems.contains(where: { $0.name == "limit" }) {
            queryItems.append(URLQueryItem(name: "limit", value: "\(limit)"))
        }
        if !queryItems.contains(where: { $0.name == "art[url]" }) {
            queryItems.append(URLQueryItem(name: "art[url]", value: "f"))
        }
        if !queryItems.contains(where: { $0.name == "l" }) {
            queryItems.append(URLQueryItem(name: "l", value: "zh-Hans-CN"))
        }
        if !queryItems.contains(where: { $0.name == "platform" }) {
            queryItems.append(URLQueryItem(name: "platform", value: "web"))
        }
        components?.queryItems = queryItems
        guard let url = components?.url else { return ([], nil) }

        let data = try await execute(url: url, needAuth: isLibrary, generation: generation)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return ([], nil)
        }
        let rawList: [[String: Any]]
        if let direct = json["data"] as? [[String: Any]] {
            rawList = direct
        } else if let results = json["results"] as? [String: Any],
                  let firstSection = results.values.compactMap({ $0 as? [String: Any] }).first,
                  let nested = firstSection["data"] as? [[String: Any]] {
            rawList = nested
        } else {
            rawList = []
        }
        let parsed = rawList.compactMap { parseSearchItem(raw: $0, sectionKey: nil) }
        let next = json["next"] as? String
            ?? ((json["results"] as? [String: Any])?.values.compactMap({ $0 as? [String: Any] }).first?["next"] as? String)
        return (parsed, next)
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

    public struct TrackPage: Sendable, Equatable {
        public let tracks: [MusicTrack]
        public let nextURL: URL?
        public let totalCount: Int?

        public init(tracks: [MusicTrack], nextURL: URL? = nil, totalCount: Int? = nil) {
            self.tracks = tracks
            self.nextURL = nextURL
            self.totalCount = totalCount
        }
    }

    /// Fetches a single song with `albums` and `artists` relationships for bounded on-demand origin navigation.
    public func fetchSongWithRelationships(songID: String, isLibrary: Bool, generation: Int? = nil) async throws -> MusicTrack? {
        guard !songID.isEmpty else { return nil }
        let isLib = isLibrary || songID.hasPrefix("i.")
        let urlString = isLib
            ? "https://amp-api.music.apple.com/v1/me/library/songs/\(songID)?include=albums,artists,catalog&l=zh-Hans-CN&platform=web"
            : "https://amp-api.music.apple.com/v1/catalog/\(storefront)/songs/\(songID)?include=albums,artists&l=zh-Hans-CN&platform=web"
        guard let url = URL(string: urlString) else { return nil }
        let data = try await execute(url: url, needAuth: isLib, generation: generation)
        return parseSongsPage(data: data).tracks.first
    }

    public func fetchAlbumTracks(albumID: String, isLibrary: Bool? = nil, limit: Int = 100, generation: Int? = nil) async throws -> [MusicTrack] {
        try await fetchAlbumTracksPage(albumID: albumID, isLibrary: isLibrary, limit: limit, generation: generation).tracks
    }

    public func fetchAlbumTracksPage(albumID: String, isLibrary: Bool? = nil, limit: Int = 100, generation: Int? = nil) async throws -> TrackPage {
        let isLib = isLibrary ?? (albumID.hasPrefix("l.") || albumID.hasPrefix("i."))
        let urlStr = isLib
            ? "https://amp-api.music.apple.com/v1/me/library/albums/\(albumID)/tracks?include=catalog&limit=\(limit)&l=zh-Hans-CN&platform=web"
            : "https://amp-api.music.apple.com/v1/catalog/\(storefront)/albums/\(albumID)/tracks?limit=\(limit)&l=zh-Hans-CN&platform=web"

        guard let url = URL(string: urlStr) else { return TrackPage(tracks: []) }
        let data = try await execute(url: url, needAuth: isLib, generation: generation)
        let page = parseSongsPage(data: data)
        AppLogger.shared.log(
            category: .ampAPI,
            level: .info,
            message: "拉取\(isLib ? "资料库" : "目录")专辑 [\(albumID)] 曲目页完成: 共 \(page.tracks.count) 首 (hasNext=\(page.nextURL != nil))",
            details: page.tracks.first.map { "首曲: \($0.title) - \($0.artistName)" }
        )
        return page
    }

    public func fetchPlaylistTracks(playlistID: String, isLibrary: Bool? = nil, limit: Int = 100, generation: Int? = nil) async throws -> [MusicTrack] {
        try await fetchPlaylistTracksPage(playlistID: playlistID, isLibrary: isLibrary, limit: limit, generation: generation).tracks
    }

    public func fetchPlaylistTracksPage(playlistID: String, isLibrary: Bool? = nil, limit: Int = 100, generation: Int? = nil) async throws -> TrackPage {
        let isLib = isLibrary ?? (playlistID.hasPrefix("p.") || playlistID.hasPrefix("l."))
        let urlStr = isLib
            ? "https://amp-api.music.apple.com/v1/me/library/playlists/\(playlistID)/tracks?include=catalog&limit=\(limit)&l=zh-Hans-CN&platform=web"
            : "https://amp-api.music.apple.com/v1/catalog/\(storefront)/playlists/\(playlistID)/tracks?limit=\(limit)&l=zh-Hans-CN&platform=web"

        guard let url = URL(string: urlStr) else { return TrackPage(tracks: []) }
        let data = try await execute(url: url, needAuth: isLib, generation: generation)
        let page = parseSongsPage(data: data)
        AppLogger.shared.log(
            category: .ampAPI,
            level: .info,
            message: "拉取\(isLib ? "资料库" : "目录")歌单 [\(playlistID)] 曲目页完成: 共 \(page.tracks.count) 首 (hasNext=\(page.nextURL != nil))",
            details: page.tracks.first.map { "首曲: \($0.title) - \($0.artistName)" }
        )
        return page
    }

    public func fetchTracksPage(nextURL: URL, isLibrary: Bool, generation: Int? = nil) async throws -> TrackPage {
        let data = try await execute(url: nextURL, needAuth: isLibrary, generation: generation)
        return parseSongsPage(data: data)
    }

    private func parseSongsPage(data: Data) -> TrackPage {
        let tracks = parseSongsData(data: data)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return TrackPage(tracks: tracks)
        }
        var nextURL: URL?
        if let nextStr = json["next"] as? String, !nextStr.isEmpty {
            let fullStr = nextStr.hasPrefix("http") ? nextStr : "https://amp-api.music.apple.com\(nextStr)"
            nextURL = URL(string: fullStr)
        }
        let total = (json["meta"] as? [String: Any])?["total"] as? Int
        return TrackPage(tracks: tracks, nextURL: nextURL, totalCount: total)
    }

    public func fetchArtistTopSongs(artistID: String, isLibrary: Bool? = nil, limit: Int = 100, generation: Int? = nil) async throws -> [MusicTrack] {
        let isLib = isLibrary ?? (artistID.hasPrefix("r.") || artistID.hasPrefix("l.") || artistID.hasPrefix("i."))
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

    // MARK: - Full Artist Page Detail & Actions

    public func fetchArtistDetail(
        artistID: String,
        isLibrary: Bool? = nil,
        generation: Int? = nil
    ) async throws -> MusicArtistDetail {
        let isLib = isLibrary ?? (artistID.hasPrefix("r.") || artistID.hasPrefix("l.") || artistID.hasPrefix("i."))
        var resolvedCatalogID = artistID

        if isLib {
            if let cid = await resolveCatalogArtistID(artistID: artistID, generation: generation) {
                resolvedCatalogID = cid
            } else {
                let tracks = (try? await fetchArtistTopSongs(artistID: artistID, isLibrary: true, generation: generation)) ?? []
                let artist = MusicArtist(id: artistID, name: tracks.first?.artistName ?? "资料库艺人", providerID: "apple_music", providerArtistID: artistID)
                let sections: [ArtistViewSection] = tracks.isEmpty ? [] : [
                    ArtistViewSection(id: "top-songs", kind: .topSongs, items: tracks.map { .track($0) })
                ]
                return MusicArtistDetail(artist: artist, views: sections)
            }
        }

        let viewsParam = "top-songs,latest-release,full-albums,singles,live-albums,compilation-albums,featured-playlists,similar-artists"
        guard let url = URL(string: "https://amp-api.music.apple.com/v1/catalog/\(storefront)/artists/\(resolvedCatalogID)?views=\(viewsParam)&extend=editorialArtwork,editorialNotes&art[url]=f&l=zh-Hans-CN&platform=web") else {
            return MusicArtistDetail(artist: MusicArtist(id: resolvedCatalogID, name: "艺人", providerID: "apple_music", providerArtistID: resolvedCatalogID))
        }

        let data = try await execute(url: url, needAuth: false, generation: generation)
        var detail = parseArtistDetail(data: data, fallbackID: resolvedCatalogID)

        if userToken != nil {
            if let isFav = try? await fetchRating(resourceType: "artists", catalogID: resolvedCatalogID, generation: generation) {
                detail.isRatingKnown = true
                detail.isFavorited = isFav
            }
        }
        return detail
    }

    /// Resolves a catalog song/album/playlist's library membership and library ID via `?relate=library`.
    public func fetchLibraryMembership(
        catalogID: String,
        resourceType: String,
        generation: Int? = nil
    ) async throws -> (inLibrary: Bool, libraryID: String?) {
        guard userToken != nil else { throw AppleMusicError.notAuthorized }
        guard let url = URL(string: "https://amp-api.music.apple.com/v1/catalog/\(storefront)/\(resourceType)/\(catalogID)?relate=library&l=zh-Hans-CN&platform=web") else {
            throw URLError(.badURL)
        }
        let data = try await executeUncached(url: url, needAuth: true, generation: generation)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let first = (json["data"] as? [[String: Any]])?.first,
              let rel = (first["relationships"] as? [String: Any])?["library"] as? [String: Any],
              let libData = rel["data"] as? [[String: Any]] else {
            return (false, nil)
        }
        let libID = libData.first?["id"] as? String
        return (!libData.isEmpty, libID)
    }

    public func addToLibrary(catalogID: String, resourceType: String, generation: Int? = nil) async throws {
        guard userToken != nil,
              let url = URL(string: "https://amp-api.music.apple.com/v1/me/library?ids[\(resourceType)]=\(catalogID)&l=zh-Hans-CN&platform=web") else {
            throw AppleMusicError.notAuthorized
        }
        _ = try await executeMutation(method: "POST", url: url, body: nil, generation: generation)
    }

    public func removeFromLibrary(libraryID: String, resourceType: String, generation: Int? = nil) async throws {
        guard userToken != nil,
              let url = URL(string: "https://amp-api.music.apple.com/v1/me/library/\(resourceType)/\(libraryID)?l=zh-Hans-CN&platform=web") else {
            throw AppleMusicError.notAuthorized
        }
        _ = try await executeMutation(method: "DELETE", url: url, body: nil, generation: generation)
    }

    /// Batch-resolves catalog songs/albums/playlists library membership via `?ids=...&relate=library`.
    public func fetchLibraryMemberships(
        catalogIDs: [String],
        resourceType: String,
        generation: Int? = nil
    ) async throws -> [String: (inLibrary: Bool, libraryID: String?)] {
        guard userToken != nil else { throw AppleMusicError.notAuthorized }
        let uniqueIDs = Array(Set(catalogIDs.filter { !$0.isEmpty })).sorted()
        guard !uniqueIDs.isEmpty else { return [:] }

        var result: [String: (inLibrary: Bool, libraryID: String?)] = [:]
        let chunkSize = 100
        for startIdx in stride(from: 0, to: uniqueIDs.count, by: chunkSize) {
            let chunk = Array(uniqueIDs[startIdx..<min(startIdx + chunkSize, uniqueIDs.count)])
            let joined = chunk.joined(separator: ",")
            guard let encoded = joined.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
                  let url = URL(string: "https://amp-api.music.apple.com/v1/catalog/\(storefront)/\(resourceType)?ids=\(encoded)&relate=library&l=zh-Hans-CN&platform=web") else {
                continue
            }
            let data = try await executeUncached(url: url, needAuth: true, generation: generation)
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let dataArr = json["data"] as? [[String: Any]] else {
                continue
            }
            for item in dataArr {
                guard let id = item["id"] as? String else { continue }
                if let rel = (item["relationships"] as? [String: Any])?["library"] as? [String: Any],
                   let libData = rel["data"] as? [[String: Any]] {
                    result[id] = (!libData.isEmpty, libData.first?["id"] as? String)
                } else {
                    result[id] = (false, nil)
                }
            }
        }
        return result
    }

    /// Reads user rating for `songs`, `albums`, `playlists`, or `artists`.
    /// HTTP 404 (40400) is Apple Music's authoritative "unrated" response (`false`), distinct from auth/network errors.
    public func fetchRating(resourceType: String, catalogID: String, generation: Int? = nil) async throws -> Bool {
        let batch = try await fetchRatings(resourceType: resourceType, catalogIDs: [catalogID], generation: generation)
        return batch[catalogID] ?? false
    }

    /// Batch-reads user ratings for `songs`, `albums`, `playlists`, or `artists` via `/v1/me/ratings/{type}?ids=...`.
    public func fetchRatings(
        resourceType: String,
        catalogIDs: [String],
        generation: Int? = nil
    ) async throws -> [String: Bool] {
        guard userToken != nil else { throw AppleMusicError.notAuthorized }
        let uniqueIDs = Array(Set(catalogIDs.filter { !$0.isEmpty })).sorted()
        guard !uniqueIDs.isEmpty else { return [:] }

        var result: [String: Bool] = [:]
        let chunkSize = 100
        for startIdx in stride(from: 0, to: uniqueIDs.count, by: chunkSize) {
            let chunk = Array(uniqueIDs[startIdx..<min(startIdx + chunkSize, uniqueIDs.count)])
            let joined = chunk.joined(separator: ",")
            guard let encoded = joined.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
                  let url = URL(string: "https://amp-api.music.apple.com/v1/me/ratings/\(resourceType)?ids=\(encoded)&l=zh-Hans-CN&platform=web") else {
                continue
            }
            let currentDevToken: String
            if let dt = devToken, !dt.isEmpty { currentDevToken = dt } else { currentDevToken = try await ensureDeveloperToken() }
            var req = URLRequest(url: url)
            req.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
            req.timeoutInterval = 12
            req.setValue("Bearer \(currentDevToken)", forHTTPHeaderField: "Authorization")
            if let ut = userToken { req.setValue(ut, forHTTPHeaderField: "Music-User-Token") }
            req.setValue("https://music.apple.com", forHTTPHeaderField: "Origin")
            req.setValue("https://music.apple.com/", forHTTPHeaderField: "Referer")

            let start = CFAbsoluteTimeGetCurrent()
            let (data, response) = try await session.data(for: req)
            let durationMs = Int((CFAbsoluteTimeGetCurrent() - start) * 1000)
            if let reqGen = generation, reqGen != activeGeneration {
                throw AppleMusicSessionError.sessionGenerationMismatch
            }
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            if code == 404 {
                AppLogger.shared.log(category: .ampAPI, level: .info, message: "Amp-API 评分查询完成 [HTTP 404 未评分] (耗时: \(durationMs)ms, 数量: \(chunk.count))", details: "路径: \(url.path)")
                for id in chunk { result[id] = false }
                continue
            }
            if code == 401 || code == 403 {
                throw AppleMusicError.notAuthorized
            }
            guard (200...299).contains(code) else {
                throw URLError(.badServerResponse)
            }
            AppLogger.shared.log(category: .ampAPI, level: .info, message: "Amp-API 评分批量查询成功 [HTTP \(code)] (耗时: \(durationMs)ms, 数量: \(chunk.count))", details: "路径: \(url.path)")
            var returnedIDs = Set<String>()
            if let rJson = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let dataArr = rJson["data"] as? [[String: Any]] {
                for item in dataArr {
                    guard let id = item["id"] as? String else { continue }
                    returnedIDs.insert(id)
                    let val = (item["attributes"] as? [String: Any])?["value"] as? Int
                    result[id] = (val == 1)
                }
            }
            for id in chunk where !returnedIDs.contains(id) {
                result[id] = false
            }
        }
        return result
    }

    @discardableResult
    public func setRating(resourceType: String, catalogID: String, value: Int?, generation: Int? = nil) async throws -> Bool {
        guard userToken != nil,
              let url = URL(string: "https://amp-api.music.apple.com/v1/me/ratings/\(resourceType)/\(catalogID)?l=zh-Hans-CN&platform=web") else {
            throw AppleMusicError.notAuthorized
        }
        if let value {
            let payload: [String: Any] = ["type": "rating", "attributes": ["value": value]]
            let body = try JSONSerialization.data(withJSONObject: payload)
            let data = try await executeMutation(method: "PUT", url: url, body: body, generation: generation)
            if let rJson = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let rFirst = (rJson["data"] as? [[String: Any]])?.first,
               let confirmedVal = (rFirst["attributes"] as? [String: Any])?["value"] as? Int {
                return confirmedVal == 1
            }
            return value == 1
        } else {
            _ = try await executeMutation(method: "DELETE", url: url, body: nil, generation: generation)
            return false
        }
    }

    private func executeUncached(url: URL, needAuth: Bool, generation: Int? = nil) async throws -> Data {
        let currentDevToken: String
        if let dt = devToken, !dt.isEmpty { currentDevToken = dt } else { currentDevToken = try await ensureDeveloperToken() }
        var req = URLRequest(url: url)
        req.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        req.timeoutInterval = 12
        req.setValue("Bearer \(currentDevToken)", forHTTPHeaderField: "Authorization")
        if needAuth, let ut = userToken { req.setValue(ut, forHTTPHeaderField: "Music-User-Token") }
        req.setValue("https://music.apple.com", forHTTPHeaderField: "Origin")
        req.setValue("https://music.apple.com/", forHTTPHeaderField: "Referer")

        let (data, response) = try await session.data(for: req)
        if let reqGen = generation, reqGen != activeGeneration {
            throw AppleMusicSessionError.sessionGenerationMismatch
        }
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        if code == 401 || code == 403 {
            throw AppleMusicError.notAuthorized
        }
        guard (200...299).contains(code) else {
            throw URLError(.badServerResponse)
        }
        return data
    }

    private func executeMutation(method: String, url: URL, body: Data?, generation: Int? = nil) async throws -> Data {
        let currentDevToken: String
        if let dt = devToken, !dt.isEmpty { currentDevToken = dt } else { currentDevToken = try await ensureDeveloperToken() }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.timeoutInterval = 15
        req.setValue("Bearer \(currentDevToken)", forHTTPHeaderField: "Authorization")
        if let ut = userToken { req.setValue(ut, forHTTPHeaderField: "Music-User-Token") }
        req.setValue("https://music.apple.com", forHTTPHeaderField: "Origin")
        req.setValue("https://music.apple.com/", forHTTPHeaderField: "Referer")
        if let body {
            req.httpBody = body
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await session.data(for: req)
        if let reqGen = generation, reqGen != activeGeneration {
            throw AppleMusicSessionError.sessionGenerationMismatch
        }
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        if code == 401 || code == 403 {
            throw AppleMusicError.notAuthorized
        }
        guard (200...299).contains(code) else {
            throw URLError(.badServerResponse)
        }
        return data
    }

    public func fetchSongStation(songID: String, generation: Int? = nil) async throws -> MusicStation? {
        guard let url = URL(string: "https://amp-api.music.apple.com/v1/catalog/\(storefront)/songs/\(songID)/station?art[url]=f&l=zh-Hans-CN&platform=web") else {
            return nil
        }
        let data = try await execute(url: url, needAuth: false, generation: generation)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let first = (json["data"] as? [[String: Any]])?.first else {
            return nil
        }
        return parseStationItem(first)
    }

    private func resolveCatalogArtistID(artistID: String, generation: Int? = nil) async -> String? {
        if !artistID.hasPrefix("r.") && !artistID.hasPrefix("l.") {
            return artistID
        }
        if let catURL = URL(string: "https://amp-api.music.apple.com/v1/me/library/artists/\(artistID)?include=catalog&l=zh-Hans-CN&platform=web"),
           let catData = try? await execute(url: catURL, needAuth: true, generation: generation),
           let json = try? JSONSerialization.jsonObject(with: catData) as? [String: Any],
           let first = (json["data"] as? [[String: Any]])?.first,
           let rel = (first["relationships"] as? [String: Any])?["catalog"] as? [String: Any],
           let cid = (rel["data"] as? [[String: Any]])?.first?["id"] as? String {
            return cid
        }
        return nil
    }

    public func setArtistRating(artistID: String, value: Int?, generation: Int? = nil) async throws {
        guard userToken != nil else {
            throw AppleMusicError.notAuthorized
        }
        guard let targetID = await resolveCatalogArtistID(artistID: artistID, generation: generation),
              let url = URL(string: "https://amp-api.music.apple.com/v1/me/ratings/artists/\(targetID)?l=zh-Hans-CN&platform=web") else {
            throw MediaActionError.unsupportedCapability("无法解析艺人的目录 ID")
        }
        let currentDevToken: String
        if let dt = devToken, !dt.isEmpty {
            currentDevToken = dt
        } else {
            currentDevToken = try await ensureDeveloperToken()
        }
        var req = URLRequest(url: url)
        req.timeoutInterval = 12
        req.setValue("Bearer \(currentDevToken)", forHTTPHeaderField: "Authorization")
        if let ut = userToken { req.setValue(ut, forHTTPHeaderField: "Music-User-Token") }
        req.setValue("https://music.apple.com", forHTTPHeaderField: "Origin")
        req.setValue("https://music.apple.com/", forHTTPHeaderField: "Referer")

        if let value {
            req.httpMethod = "PUT"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            let payload: [String: Any] = ["type": "rating", "attributes": ["value": value]]
            req.httpBody = try JSONSerialization.data(withJSONObject: payload)
        } else {
            req.httpMethod = "DELETE"
        }

        let (_, response) = try await session.data(for: req)
        if let reqGen = generation, reqGen != activeGeneration {
            throw AppleMusicSessionError.sessionGenerationMismatch
        }
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200...299).contains(code) else {
            throw URLError(.badServerResponse)
        }
    }

    public func fetchArtistStation(artistID: String, generation: Int? = nil) async throws -> MusicStation? {
        guard let targetID = await resolveCatalogArtistID(artistID: artistID, generation: generation),
              let url = URL(string: "https://amp-api.music.apple.com/v1/catalog/\(storefront)/artists/\(targetID)/station?art[url]=f&l=zh-Hans-CN&platform=web") else {
            return nil
        }
        let data = try await execute(url: url, needAuth: false, generation: generation)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let first = (json["data"] as? [[String: Any]])?.first else {
            return nil
        }
        return parseStationItem(first)
    }

    private func parseArtistDetail(data: Data, fallbackID: String) -> MusicArtistDetail {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let first = (json["data"] as? [[String: Any]])?.first else {
            return MusicArtistDetail(artist: MusicArtist(id: fallbackID, name: "艺人", providerID: "apple_music", providerArtistID: fallbackID))
        }

        let artist = parseArtistItem(first) ?? MusicArtist(id: fallbackID, name: "艺人", providerID: "apple_music", providerArtistID: fallbackID)
        let attrs = first["attributes"] as? [String: Any] ?? [:]
        let genres = attrs["genreNames"] as? [String] ?? []
        let notesObj = attrs["editorialNotes"] as? [String: Any]
        let notes = (notesObj?["standard"] as? String) ?? (notesObj?["short"] as? String)

        let viewsDict = first["views"] as? [String: Any] ?? [:]
        let preferredOrder = [
            "top-songs", "latest-release", "full-albums", "singles",
            "live-albums", "compilation-albums", "featured-playlists", "similar-artists"
        ]
        var orderedKeys: [String] = []
        for k in preferredOrder where viewsDict[k] != nil { orderedKeys.append(k) }
        for k in viewsDict.keys.sorted() where !orderedKeys.contains(k) { orderedKeys.append(k) }

        var sections: [ArtistViewSection] = []
        for key in orderedKeys {
            guard let vDict = viewsDict[key] as? [String: Any],
                  let rawData = vDict["data"] as? [[String: Any]],
                  !rawData.isEmpty else { continue }
            let vAttrs = vDict["attributes"] as? [String: Any]
            let title = vAttrs?["title"] as? String
            let kind = ArtistViewKind(viewKey: key)
            let items = rawData.compactMap { parseSearchItem(raw: $0, sectionKey: nil) }
            guard !items.isEmpty else { continue }
            let nextURL = vDict["next"] as? String
            sections.append(ArtistViewSection(id: key, kind: kind, title: title, items: items, nextURL: nextURL))
        }

        return MusicArtistDetail(
            artist: artist,
            editorialNotes: notes,
            genreNames: genres,
            views: sections
        )
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
                        providerPlaylistID: iid,
                        ownership: iid.hasPrefix("pl.") ? .platform : .unknown,
                        catalogID: iid.hasPrefix("pl.") ? iid : nil
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

        let metaOrder = ((json["meta"] as? [String: Any])?["results"] as? [String: Any])?["order"] as? [String] ?? []
        var orderedKeys: [String] = []
        for topKey in ["topResults", "top"] where results[topKey] != nil && !orderedKeys.contains(topKey) {
            orderedKeys.append(topKey)
        }
        for key in metaOrder where results[key] != nil && !orderedKeys.contains(key) {
            orderedKeys.append(key)
        }
        for key in results.keys.sorted() where !orderedKeys.contains(key) {
            orderedKeys.append(key)
        }

        var tracks: [MusicTrack] = []
        var albums: [MusicAlbum] = []
        var artists: [MusicArtist] = []
        var playlists: [MusicPlaylist] = []
        var stations: [MusicStation] = []
        var sections: [SearchSection] = []

        for key in orderedKeys {
            guard let sectionDict = results[key] as? [String: Any],
                  let rawItems = sectionDict["data"] as? [[String: Any]],
                  !rawItems.isEmpty else { continue }

            let kind = SearchCategoryKind(ampKey: key)
            let parsedItems = rawItems.compactMap { parseSearchItem(raw: $0, sectionKey: key) }
            guard !parsedItems.isEmpty else { continue }

            let nextURL = sectionDict["next"] as? String
            sections.append(SearchSection(id: key, kind: kind, title: kind.displayTitle, items: parsedItems, nextURL: nextURL))

            switch kind {
            case .songs:
                tracks.append(contentsOf: parsedItems.compactMap { if case .track(let t) = $0 { return t } else { return nil } })
            case .albums:
                albums.append(contentsOf: parsedItems.compactMap { if case .album(let a) = $0 { return a } else { return nil } })
            case .artists:
                artists.append(contentsOf: parsedItems.compactMap { if case .artist(let a) = $0 { return a } else { return nil } })
            case .playlists:
                playlists.append(contentsOf: parsedItems.compactMap { if case .playlist(let p) = $0 { return p } else { return nil } })
            case .stations:
                stations.append(contentsOf: parsedItems.compactMap { if case .station(let s) = $0 { return s } else { return nil } })
            default:
                break
            }
        }

        return MusicSearchResult(
            tracks: tracks,
            albums: albums,
            artists: artists,
            playlists: playlists,
            stations: stations,
            sections: sections
        )
    }

    private func parseLibrarySearchResult(data: Data) -> MusicSearchResult {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = json["results"] as? [String: Any] else {
            return MusicSearchResult()
        }

        let metaOrder = ((json["meta"] as? [String: Any])?["results"] as? [String: Any])?["order"] as? [String] ?? []
        var orderedKeys: [String] = []
        for key in metaOrder where results[key] != nil && !orderedKeys.contains(key) {
            orderedKeys.append(key)
        }
        for key in ["library-songs", "library-albums", "library-artists", "library-playlists"] where results[key] != nil && !orderedKeys.contains(key) {
            orderedKeys.append(key)
        }
        for key in results.keys.sorted() where !orderedKeys.contains(key) {
            orderedKeys.append(key)
        }

        var tracks: [MusicTrack] = []
        var albums: [MusicAlbum] = []
        var artists: [MusicArtist] = []
        var playlists: [MusicPlaylist] = []
        var sections: [SearchSection] = []

        for key in orderedKeys {
            guard let sectionDict = results[key] as? [String: Any],
                  let rawItems = sectionDict["data"] as? [[String: Any]],
                  !rawItems.isEmpty else { continue }

            let kind = SearchCategoryKind(ampKey: key)
            let parsedItems = rawItems.compactMap { parseSearchItem(raw: $0, sectionKey: key) }
            guard !parsedItems.isEmpty else { continue }

            let nextURL = sectionDict["next"] as? String
            sections.append(SearchSection(id: key, kind: kind, title: kind.displayTitle, items: parsedItems, nextURL: nextURL))

            switch kind {
            case .songs:
                tracks.append(contentsOf: parsedItems.compactMap { if case .track(let t) = $0 { return t } else { return nil } })
            case .albums:
                albums.append(contentsOf: parsedItems.compactMap { if case .album(let a) = $0 { return a } else { return nil } })
            case .artists:
                artists.append(contentsOf: parsedItems.compactMap { if case .artist(let a) = $0 { return a } else { return nil } })
            case .playlists:
                playlists.append(contentsOf: parsedItems.compactMap { if case .playlist(let p) = $0 { return p } else { return nil } })
            default:
                break
            }
        }

        return MusicSearchResult(
            tracks: tracks,
            albums: albums,
            artists: artists,
            playlists: playlists,
            stations: [],
            sections: sections
        )
    }

    private func parseSearchItem(raw: [String: Any], sectionKey: String?) -> MusicSearchItem? {
        let itemType = (raw["type"] as? String) ?? sectionKey ?? ""
        switch itemType {
        case "songs", "library-songs":
            return parseTrackItem(raw).map { .track($0) }
        case "albums", "library-albums":
            return parseAlbumItem(raw).map { .album($0) }
        case "artists":
            return parseArtistItem(raw).map { .artist($0) }
        case "library-artists":
            return parseLibraryArtistItem(raw).map { .artist($0) }
        case "playlists", "library-playlists":
            return parsePlaylistItem(raw).map { .playlist($0) }
        case "stations":
            return parseStationItem(raw).map { .station($0) }
        case "music-videos":
            return parseTrackItem(raw).map { .musicVideo($0) }
        case "apple-curators", "curators":
            return parseCuratorItem(raw)
        default:
            return nil
        }
    }

    private func parseCuratorItem(_ item: [String: Any]) -> MusicSearchItem? {
        guard let id = item["id"] as? String else { return nil }
        let attrs = item["attributes"] as? [String: Any] ?? [:]
        let name = attrs["name"] as? String ?? "类别"
        let notes = (attrs["editorialNotes"] as? [String: Any])?["short"] as? String
        let rawArt = (attrs["artwork"] as? [String: Any])?["url"] as? String
        return .curator(id: id, name: name, subtitle: notes ?? "Apple Music 类别", artworkURL: formatArtworkURL(rawArt))
    }

    private func parseStationItem(_ item: [String: Any]) -> MusicStation? {
        guard let id = item["id"] as? String else { return nil }
        let attrs = item["attributes"] as? [String: Any] ?? [:]
        let name = attrs["name"] as? String ?? "未知电台"
        let notes = (attrs["editorialNotes"] as? [String: Any])?["short"] as? String
        let rawArt = (attrs["artwork"] as? [String: Any])?["url"] as? String
        let isLive = attrs["isLive"] as? Bool ?? false
        return MusicStation(
            id: id,
            name: name,
            description: notes ?? "Apple Music 广播",
            artworkURL: formatArtworkURL(rawArt),
            isLive: isLive,
            providerID: "apple_music",
            providerStationID: id
        )
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
        let canEdit = attrs["canEdit"] as? Bool ?? false
        let isCollaborative = attrs["isCollaborative"] as? Bool ?? false
        let playlistType = attrs["playlistType"] as? String ?? ""

        var catalogID: String? = id.hasPrefix("pl.") ? id : nil
        if let rel = item["relationships"] as? [String: Any],
           let catData = (rel["catalog"] as? [String: Any])?["data"] as? [[String: Any]],
           let firstCatID = catData.first?["id"] as? String, !firstCatID.isEmpty {
            catalogID = firstCatID
        }

        let ownership: PlaylistOwnership
        if isCollaborative || playlistType == "collaborative" {
            ownership = .collaborative
        } else if canEdit || id.hasPrefix("p.") {
            ownership = .personal
        } else if id.hasPrefix("pl.") && !canEdit {
            ownership = .platform
        } else {
            ownership = .unknown
        }

        return MusicPlaylist(
            id: id,
            name: name,
            description: desc,
            artworkURL: formatArtworkURL(rawArt),
            trackIDs: [],
            isEditable: canEdit,
            ownerName: attrs["curatorName"] as? String,
            providerID: "apple_music",
            providerPlaylistID: id,
            ownership: ownership,
            catalogID: catalogID
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

        var albumID: String? = nil
        var parsedArtists: [MediaArtistRef] = []
        if let rel = item["relationships"] as? [String: Any] {
            if let albumsData = (rel["albums"] as? [String: Any])?["data"] as? [[String: Any]],
               let firstAlbum = albumsData.first,
               let aid = firstAlbum["id"] as? String {
                albumID = aid
            }
            if let artistsData = (rel["artists"] as? [String: Any])?["data"] as? [[String: Any]] {
                for artistObj in artistsData {
                    if let artistID = artistObj["id"] as? String, !artistID.isEmpty {
                        let artistAttrs = artistObj["attributes"] as? [String: Any]
                        let artistName = (artistAttrs?["name"] as? String) ?? (attrs["artistName"] as? String) ?? "歌手"
                        let isLib = artistID.hasPrefix("r.")
                        parsedArtists.append(MediaArtistRef(id: artistID, name: artistName, isLibrary: isLib))
                    }
                }
            }
        }

        let isLib = id.hasPrefix("i.") || (item["type"] as? String == "library-songs")
        let resolvedCatalogID = catalogID ?? (isLib ? nil : id)
        let resolvedLibraryID = isLib ? id : nil
        let effectiveTrackID = resolvedCatalogID ?? id
        return MusicTrack(
            id: id,
            title: name,
            artistName: artist,
            albumTitle: album,
            durationMs: durationMs,
            artworkURL: formatArtworkURL(rawArt),
            providerID: "apple_music",
            providerTrackID: effectiveTrackID,
            albumID: albumID,
            artists: parsedArtists,
            isLibrary: isLib,
            catalogID: resolvedCatalogID,
            libraryID: resolvedLibraryID
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
