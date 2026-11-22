// Sources/Providers/AppleMusic/Session/AppleMusicWebPlayer.swift
// AirMuse macOS – Apple Music Official WebKit Player Engine
// Swift 6 strict concurrency – @MainActor throughout WebKit operations
// Drives window.MusicKit.getInstance() inside WKWebView with authorized dataStore
// Streams full tracks from 0:00, radio stations, playlists, and albums without paid Apple Developer keys.

import Foundation
import WebKit
import Domain
import Infrastructure

@MainActor
public final class AppleMusicWebPlayer: NSObject, WKNavigationDelegate, WKScriptMessageHandler {

    public let dataStore: WKWebsiteDataStore
    public private(set) var webView: WKWebView?

    public private(set) var isReady: Bool = false
    public private(set) var isPlaying: Bool = false
    public private(set) var currentPosition: Double = 0
    public private(set) var currentDuration: Double = 0
    public private(set) var currentTrackTitle: String = ""
    public private(set) var currentArtistName: String = ""
    public private(set) var isSeeking: Bool = false
    public private(set) var userToken: String?

    private static func jsStringLiteral(_ value: String) -> String {
        if let data = try? JSONEncoder().encode(value),
           let json = String(data: data, encoding: .utf8) {
            return json
        }
        return "\"\""
    }

    public func setUserToken(_ token: String) {
        self.userToken = token
        if let wv = webView {
            let tokenLiteral = Self.jsStringLiteral(token)
            let js = """
            (function() {
                try {
                    var t = \(tokenLiteral);
                    var mk = window.MusicKit && window.MusicKit.getInstance ? window.MusicKit.getInstance() : null;
                    if (mk) {
                        mk.musicUserToken = t;
                        return !!mk.isAuthorized;
                    }
                } catch(e) {}
                return false;
            })();
            """
            wv.evaluateJavaScript(js) { [weak self, weak wv] res, _ in
                guard let self, let wv, !self.isPlaying, !self.isNavigating, !self.didReloadForAuth else { return }
                let authorized = (res as? Bool) ?? false
                if !authorized && wv.url != nil {
                    self.didReloadForAuth = true
                    self.isReady = false
                    self.isNavigating = true
                    wv.reload()
                }
            }
        }
    }

    private var tokenInjectionJS: String {
        guard let token = userToken, !token.isEmpty else { return "" }
        let tokenLiteral = Self.jsStringLiteral(token)
        return """
        var uToken = \(tokenLiteral);
        if (uToken && !document.cookie.includes('media-user-token')) {
            document.cookie = 'media-user-token=' + encodeURIComponent(uToken) + '; domain=.music.apple.com; path=/; max-age=31536000; SameSite=Lax';
        }
        if (uToken && !mk.musicUserToken) {
            mk.musicUserToken = uToken;
        }
        """
    }

    public var onPlaybackStateChanged: ((Bool) -> Void)?
    public var onTimeChanged: ((Double, Double) -> Void)?
    public var onTrackChanged: ((String, String) -> Void)?
    public var onPlaybackEnded: (() -> Void)?
    public var onStateChanged: (() -> Void)?

    private var isNavigating: Bool = false
    private var didReloadForAuth: Bool = false
    private var playCommandGeneration: Int = 0
    private var lastNotifiedPosition: Double = -1
    private var trackPlaybackStartTime: Date?
    private var lastPlaybackEndedTime: Date?
    private static let officialWebURL = URL(string: "https://music.apple.com")!
    private let messageHandlerName = "airmusePlayerBridge"

    // MARK: - Init

    public init(dataStore: WKWebsiteDataStore = .default()) {
        self.dataStore = dataStore
        super.init()
    }

    // MARK: - Setup & Preload

    /// Creates or returns the player WKWebView, pre-loading https://music.apple.com with the authorized data store.
    @discardableResult
    public func ensureWebView() -> WKWebView {
        if let existing = webView {
            return existing
        }

        let config = WKWebViewConfiguration()
        config.websiteDataStore = self.dataStore
        // Allow autonomous background audio playback without requiring user gesture
        config.mediaTypesRequiringUserActionForPlayback = []
        config.defaultWebpagePreferences.allowsContentJavaScript = true

        let bridgeScriptSource = """
        (function() {
            'use strict';
            var BRIDGE = 'airmusePlayerBridge';
            function post(event, payload) {
                if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers[BRIDGE]) {
                    window.webkit.messageHandlers[BRIDGE].postMessage(Object.assign({ event: event }, payload || {}));
                }
            }

            function notifyTime() {
                var mk = window.MusicKit && window.MusicKit.getInstance ? window.MusicKit.getInstance() : null;
                var item = mk ? mk.nowPlayingItem : null;
                var cur = 0;
                var dur = 0;
                var isPlaying = false;

                if (mk) {
                    cur = mk.currentPlaybackTime || 0;
                    dur = mk.currentPlaybackDuration || 0;
                    isPlaying = !!mk.isPlaying;
                    if (item && item.attributes && item.attributes.durationInMillis) {
                        dur = item.attributes.durationInMillis / 1000.0;
                    }
                }

                var audios = document.querySelectorAll('audio, video');
                for (var i = 0; i < audios.length; i++) {
                    var a = audios[i];
                    if (isFinite(a.currentTime) && a.currentTime > cur) {
                        cur = a.currentTime;
                    }
                    if (isFinite(a.duration) && a.duration > 0 && dur === 0) {
                        dur = a.duration;
                    }
                    if (!a.paused && isFinite(a.currentTime) && a.currentTime > 0) {
                        isPlaying = true;
                    }
                }

                post('playbackTimeDidChange', {
                    currentPlaybackTime: cur,
                    currentPlaybackDuration: dur,
                    isPlaying: isPlaying
                });
            }

            function checkTrackEnded(source) {
                var mk = window.MusicKit && window.MusicKit.getInstance ? window.MusicKit.getInstance() : null;
                var cur = 0;
                var dur = 0;
                if (mk) {
                    cur = mk.currentPlaybackTime || 0;
                    dur = mk.currentPlaybackDuration || 0;
                }
                var audios = document.querySelectorAll('audio, video');
                for (var i = 0; i < audios.length; i++) {
                    var a = audios[i];
                    if (isFinite(a.currentTime) && a.currentTime > cur) {
                        cur = a.currentTime;
                        if (isFinite(a.duration) && a.duration > 0) dur = a.duration;
                    }
                }
                // Strict completion rule:
                // 1. Duration must be at least 15s (guards against uninitialized audio or empty items)
                // 2. Played at least 10s into the track
                // 3. Current time is within 3.5s of track duration
                if (dur > 15 && cur >= (dur - 3.5) && cur > 10) {
                    post('playbackEnded', {
                        currentPlaybackTime: cur,
                        currentPlaybackDuration: dur,
                        source: source
                    });
                }
            }

            function hookAudio() {
                var audios = document.querySelectorAll('audio, video');
                for (var i = 0; i < audios.length; i++) {
                    var a = audios[i];
                    if (a.__airmuseHooked) continue;
                    a.__airmuseHooked = true;
                    a.preload = 'auto';
                    a.addEventListener('play', function() {
                        post('playbackStateDidChange', { isPlaying: true, playbackState: 2 });
                        notifyTime();
                    });
                    a.addEventListener('playing', function() {
                        var mk = window.MusicKit && window.MusicKit.getInstance ? window.MusicKit.getInstance() : null;
                        post('playbackStarted', {
                            currentPlaybackTime: a.currentTime || 0,
                            currentPlaybackDuration: isFinite(a.duration) ? a.duration : 0,
                            isAuthorized: mk ? !!mk.isAuthorized : false
                        });
                        notifyTime();
                    });
                    a.addEventListener('pause', function() {
                        post('playbackStateDidChange', { isPlaying: false, playbackState: 3 });
                        notifyTime();
                    });
                    a.addEventListener('ended', function() {
                        checkTrackEnded('audio_tag');
                    });
                    a.addEventListener('timeupdate', notifyTime);
                    a.addEventListener('seeked', notifyTime);
                }
            }

            function hookMusicKit() {
                try {
                    var mk = window.MusicKit && window.MusicKit.getInstance ? window.MusicKit.getInstance() : null;
                    if (!mk) return false;

                    mk.addEventListener('playbackStateDidChange', function() {
                        var isPlaying = !!mk.isPlaying;
                        post('playbackStateDidChange', {
                            isPlaying: isPlaying,
                            playbackState: mk.playbackState
                        });
                        notifyTime();
                        // Only ended (5) or completed (9) can signify track ending.
                        // Stalled (8), stopped (4), loading (1), waiting (7) are NEVER ended!
                        if (mk.playbackState === 5 || mk.playbackState === 9) {
                            checkTrackEnded('musickit_state');
                        }
                    });

                    mk.addEventListener('playbackTimeDidChange', notifyTime);

                    mk.addEventListener('nowPlayingItemDidChange', function() {
                        var item = mk.nowPlayingItem;
                        post('nowPlayingItemDidChange', {
                            title: item ? (item.title || item.name || '') : '',
                            artistName: item ? (item.artistName || '') : '',
                            id: item ? (item.id || '') : ''
                        });
                    });

                    post('ready', { isAuthorized: mk.isAuthorized || false });
                    return true;
                } catch(e) {
                    return false;
                }
            }

            hookAudio();
            setInterval(hookAudio, 1000);
            setInterval(notifyTime, 250);

            if (!hookMusicKit()) {
                var timer = setInterval(function() {
                    if (hookMusicKit()) clearInterval(timer);
                }, 300);
            }
        })();
        """

        let script = WKUserScript(source: bridgeScriptSource, injectionTime: .atDocumentEnd, forMainFrameOnly: false)
        config.userContentController.addUserScript(script)
        config.userContentController.add(self, name: messageHandlerName)

        let wv = WKWebView(frame: NSRect(x: 0, y: 0, width: 100, height: 100), configuration: config)
        wv.navigationDelegate = self
        self.webView = wv

        AppLogger.shared.log(category: .playback, level: .info, message: "Apple Music 官方 Web 播放器初始化完成 (DataStore 隔离就绪)")
        return wv
    }

    /// Pre-warms official web page in the background
    public func preload() {
        guard !isNavigating else { return }
        let wv = ensureWebView()
        if wv.url == nil {
            isNavigating = true
            let storefront = AppleMusicSessionManager.shared.currentStorefront ?? "cn"
            let targetURL = URL(string: "https://music.apple.com/\(storefront)/browse") ?? Self.officialWebURL
            AppLogger.shared.log(category: .playback, level: .info, message: "Apple Music Web 播放器后台预加载: \(targetURL.absoluteString)")
            wv.load(URLRequest(url: targetURL))
        }
    }

    /// Attaches the invisible player view to an active AppKit window container to guarantee WebKit audio engine stays active
    public func attach(to parentView: NSView, preloadImmediately: Bool = true) {
        let wv = ensureWebView()
        if wv.superview !== parentView {
            wv.removeFromSuperview()
            wv.frame = NSRect(x: 0, y: 0, width: 100, height: 100)
            wv.alphaValue = 0.01
            parentView.addSubview(wv, positioned: .below, relativeTo: nil)
            AppLogger.shared.log(category: .playback, level: .info, message: "Apple Music Web 播放器已接入活动视窗层级 (免休眠保活)")
        }
        if preloadImmediately {
            preload()
        }
    }

    // MARK: - Playback Commands

    /// Plays a catalog or library song by ID from 0:00 with full audio quality
    public func playSong(id: String) async throws -> Bool {
        preload()
        let js = """
        try {
            var mk = window.MusicKit && window.MusicKit.getInstance ? window.MusicKit.getInstance() : null;
            if (!mk) return { ok: false, error: "MusicKit not loaded" };
            if (uToken && !mk.musicUserToken) {
                mk.musicUserToken = uToken;
            }
            if (!mk.isAuthorized) {
                return { ok: false, error: "WEB_NOT_AUTHORIZED" };
            }
            var rawId = String(trackId);
            var cleanId = rawId.replace(/^[ilpa]\\./, '');
            try {
                await mk.setQueue({ song: cleanId });
            } catch(e1) {
                try {
                    await mk.setQueue({ song: rawId });
                } catch(e2) {
                    await mk.setQueue({ songs: [cleanId] });
                }
            }
            await mk.play();
            return { ok: true };
        } catch(e) {
            return { ok: false, error: String(e && e.message ? e.message : e) };
        }
        """
        return try await executePlayScript(js, arguments: ["trackId": id, "uToken": userToken ?? ""], description: "单曲 [\(id)]")
    }

    /// Plays a radio station by ID
    public func playStation(id: String) async throws -> Bool {
        preload()
        let js = """
        try {
            var mk = window.MusicKit && window.MusicKit.getInstance ? window.MusicKit.getInstance() : null;
            if (!mk) return { ok: false, error: "MusicKit not loaded" };
            if (uToken && !mk.musicUserToken) {
                mk.musicUserToken = uToken;
            }
            if (!mk.isAuthorized) {
                return { ok: false, error: "WEB_NOT_AUTHORIZED" };
            }
            await mk.setQueue({ station: String(trackId) });
            await mk.play();
            return { ok: true };
        } catch(e) {
            return { ok: false, error: String(e && e.message ? e.message : e) };
        }
        """
        return try await executePlayScript(js, arguments: ["trackId": id, "uToken": userToken ?? ""], description: "广播电台 [\(id)]")
    }

    /// Plays a playlist starting at index
    public func playPlaylist(id: String, startIndex: Int = 0) async throws -> Bool {
        preload()
        let js = """
        try {
            var mk = window.MusicKit && window.MusicKit.getInstance ? window.MusicKit.getInstance() : null;
            if (!mk) return { ok: false, error: "MusicKit not loaded" };
            if (uToken && !mk.musicUserToken) {
                mk.musicUserToken = uToken;
            }
            if (!mk.isAuthorized) {
                return { ok: false, error: "WEB_NOT_AUTHORIZED" };
            }
            var rawId = String(trackId);
            var cleanId = rawId.replace(/^[ilp]\\./, '');
            try {
                await mk.setQueue({ playlist: cleanId, startWith: startIndex });
            } catch(e1) {
                await mk.setQueue({ playlist: rawId, startWith: startIndex });
            }
            await mk.play();
            return { ok: true };
        } catch(e) {
            return { ok: false, error: String(e && e.message ? e.message : e) };
        }
        """
        return try await executePlayScript(js, arguments: ["trackId": id, "startIndex": startIndex, "uToken": userToken ?? ""], description: "歌单 [\(id)]")
    }

    /// Plays an album starting at index
    public func playAlbum(id: String, startIndex: Int = 0) async throws -> Bool {
        preload()
        let js = """
        try {
            var mk = window.MusicKit && window.MusicKit.getInstance ? window.MusicKit.getInstance() : null;
            if (!mk) return { ok: false, error: "MusicKit not loaded" };
            if (uToken && !mk.musicUserToken) {
                mk.musicUserToken = uToken;
            }
            if (!mk.isAuthorized) {
                return { ok: false, error: "WEB_NOT_AUTHORIZED" };
            }
            var rawId = String(trackId);
            var cleanId = rawId.replace(/^[ilp]\\./, '');
            try {
                await mk.setQueue({ album: cleanId, startWith: startIndex });
            } catch(e1) {
                await mk.setQueue({ album: rawId, startWith: startIndex });
            }
            await mk.play();
            return { ok: true };
        } catch(e) {
            return { ok: false, error: String(e && e.message ? e.message : e) };
        }
        """
        return try await executePlayScript(js, arguments: ["trackId": id, "startIndex": startIndex, "uToken": userToken ?? ""], description: "专辑 [\(id)]")
    }

    /// Explicitly pauses playback
    public func pause() async throws -> Bool {
        guard let wv = webView else { return false }
        let js = """
        (function() {
            try {
                var mk = window.MusicKit && window.MusicKit.getInstance ? window.MusicKit.getInstance() : null;
                if (mk) {
                    mk.pause();
                    return true;
                }
            } catch(e) {}
            return false;
        })();
        """
        let res = try? await wv.evaluateJavaScript(js)
        let paused = (res as? Bool) ?? false
        if paused {
            self.isPlaying = false
            onPlaybackStateChanged?(false)
        }
        return paused
    }

    /// Explicitly resumes playback
    public func play() async throws -> Bool {
        guard let wv = webView else { return false }
        let js = """
        (function() {
            try {
                var mk = window.MusicKit && window.MusicKit.getInstance ? window.MusicKit.getInstance() : null;
                if (mk) {
                    mk.play();
                    return true;
                }
            } catch(e) {}
            return false;
        })();
        """
        let res = try? await wv.evaluateJavaScript(js)
        let started = (res as? Bool) ?? false
        if started {
            self.isPlaying = true
            onPlaybackStateChanged?(true)
        }
        return started
    }

    /// Toggles play / pause state
    public func playPause() async throws -> Bool {
        guard let wv = webView else { return false }
        let js = """
        (function() {
            try {
                var mk = window.MusicKit && window.MusicKit.getInstance ? window.MusicKit.getInstance() : null;
                if (mk) {
                    if (mk.isPlaying) { mk.pause(); } else { mk.play(); }
                    return true;
                }
            } catch(e) {}
            return false;
        })();
        """
        let res = try? await wv.evaluateJavaScript(js)
        return (res as? Bool) ?? false
    }

    /// Stops playback
    public func stop() async throws {
        guard let wv = webView else { return }
        let js = """
        (function() {
            try {
                var mk = window.MusicKit && window.MusicKit.getInstance ? window.MusicKit.getInstance() : null;
                if (mk) mk.stop();
            } catch(e) {}
        })();
        """
        _ = try? await wv.evaluateJavaScript(js)
        self.isPlaying = false
    }

    /// Seeks to target seconds
    public func seek(to seconds: Double) async throws {
        self.isSeeking = true
        self.currentPosition = seconds
        defer {
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: 800_000_000)
                self?.isSeeking = false
            }
        }
        guard let wv = webView else { return }
        let js = """
        (function() {
            try {
                var mk = window.MusicKit && window.MusicKit.getInstance ? window.MusicKit.getInstance() : null;
                if (mk) {
                    mk.seekToTime(\(seconds));
                }
                var audios = document.querySelectorAll('audio, video');
                for (var i = 0; i < audios.length; i++) {
                    if (isFinite(audios[i].duration)) {
                        audios[i].currentTime = \(seconds);
                    }
                }
            } catch(e) {}
        })();
        """
        _ = try? await wv.evaluateJavaScript(js)
    }

    /// Skips to next item
    public func skipToNext() async throws {
        guard let wv = webView else { return }
        let js = """
        (function() {
            try {
                var mk = window.MusicKit && window.MusicKit.getInstance ? window.MusicKit.getInstance() : null;
                if (mk) mk.skipToNextItem();
            } catch(e) {}
        })();
        """
        _ = try? await wv.evaluateJavaScript(js)
    }

    /// Skips to previous item
    public func skipToPrevious() async throws {
        guard let wv = webView else { return }
        let js = """
        (function() {
            try {
                var mk = window.MusicKit && window.MusicKit.getInstance ? window.MusicKit.getInstance() : null;
                if (mk) mk.skipToPreviousItem();
            } catch(e) {}
        })();
        """
        _ = try? await wv.evaluateJavaScript(js)
    }

    /// Sets playback volume (0.0 ... 1.0)
    public func setVolume(_ volume: Float) async throws {
        guard let wv = webView else { return }
        let clamped = max(0.0, min(1.0, Double(volume)))
        let js = """
        (function() {
            try {
                var mk = window.MusicKit && window.MusicKit.getInstance ? window.MusicKit.getInstance() : null;
                if (mk) mk.volume = \(clamped);
            } catch(e) {}
        })();
        """
        _ = try? await wv.evaluateJavaScript(js)
    }

    /// Clean reset of player on sign-out
    public func reset() {
        Task { try? await stop() }
        webView?.stopLoading()
        webView?.removeFromSuperview()
        webView = nil
        isReady = false
        isPlaying = false
        currentPosition = 0
        currentDuration = 0
        currentTrackTitle = ""
        currentArtistName = ""
        isNavigating = false
        didReloadForAuth = false
        playCommandGeneration += 1
        trackPlaybackStartTime = nil
        lastPlaybackEndedTime = nil
        AppLogger.shared.log(category: .playback, level: .info, message: "Apple Music Web 播放器已重置释放")
    }

    // MARK: - Private Execution Helper

    private func executePlayScript(_ script: String, arguments: [String: Any], description: String) async throws -> Bool {
        let wv = ensureWebView()
        playCommandGeneration += 1
        let myGen = playCommandGeneration

        // Wait up to 8.0s for web page & MusicKit JS to be responsive, using callAsyncJavaScript so Promises are awaited
        var retries = 0
        while retries < 16 {
            try Task.checkCancellation()
            guard myGen == playCommandGeneration else { return false }
            do {
                let res = try await wv.callAsyncJavaScript(script, arguments: arguments, in: nil, contentWorld: .page)
                guard myGen == playCommandGeneration else { return false }
                if let dict = res as? [String: Any], let ok = dict["ok"] as? Bool, ok {
                    self.isPlaying = true
                    self.currentPosition = 0
                    self.trackPlaybackStartTime = Date()
                    onPlaybackStateChanged?(true)
                    AppLogger.shared.log(category: .playback, level: .info, message: "Web 播放器指令执行成功: \(description)")
                    return true
                } else if let dict = res as? [String: Any], let err = dict["error"] as? String {
                    if err == "WEB_NOT_AUTHORIZED" {
                        AppLogger.shared.log(category: .playback, level: .error, message: "Web 端 MusicKit 未处于授权状态 (isAuthorized=false)，已中止试听播放，请在账号窗口退出并重新登录以同步完整 Web 会话")
                        return false
                    }
                    AppLogger.shared.log(category: .playback, level: .warn, message: "Web 播放器暂未就绪 (\(err))，正在重试... [\(retries + 1)/16]")
                }
            } catch {
                guard myGen == playCommandGeneration else { return false }
                AppLogger.shared.log(category: .playback, level: .warn, message: "Web 播放器异步调用异常: \(error.localizedDescription)，重试中...")
            }
            try? await Task.sleep(nanoseconds: 500_000_000)
            retries += 1
        }
        return false
    }

    // MARK: - WKNavigationDelegate

    public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        isNavigating = false
        isReady = true
        AppLogger.shared.log(category: .playback, level: .info, message: "Apple Music 官方 Web 播放器核心页面加载完成")
    }

    public func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        isNavigating = false
        AppLogger.shared.log(category: .playback, level: .warn, message: "Apple Music Web 播放器页面加载失败: \(error.localizedDescription)")
    }

    public func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        isNavigating = false
        AppLogger.shared.log(category: .playback, level: .warn, message: "Apple Music Web 播放器预备导航失败: \(error.localizedDescription)")
    }

    // MARK: - WKScriptMessageHandler

    public func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == messageHandlerName, let body = message.body as? [String: Any] else { return }
        let event = body["event"] as? String ?? ""

        switch event {
        case "ready":
            self.isReady = true
            let isAuth = body["isAuthorized"] as? Bool ?? false
            AppLogger.shared.log(category: .playback, level: .info, message: "Apple Music Web 端 MusicKit 引擎就绪信号已捕获 (isAuthorized: \(isAuth))")

        case "playbackStarted":
            let cur = body["currentPlaybackTime"] as? Double ?? 0
            let dur = body["currentPlaybackDuration"] as? Double ?? 0
            let isAuth = body["isAuthorized"] as? Bool ?? false
            self.isPlaying = true
            self.currentPosition = cur
            if dur > 0 { self.currentDuration = dur }
            AppLogger.shared.log(category: .playback, level: .info, message: "Apple Music 声音正式开始输出 (pos: \(String(format: "%.2f", cur))s, audioDur: \(String(format: "%.1f", dur))s, isAuthorized: \(isAuth))")
            if !isAuth && dur > 0 && dur <= 95 {
                AppLogger.shared.log(category: .playback, level: .warn, message: "检测到 Web 端 MusicKit 未授权 (isAuthorized=false)，当前仅播放 \(Int(dur))s 试听片段；请在账号窗口重新登录以同步完整 Web 会话")
            }
            lastNotifiedPosition = cur
            onPlaybackStateChanged?(true)
            onTimeChanged?(cur, dur)
            onStateChanged?()

        case "playbackStateDidChange":
            let playing = body["isPlaying"] as? Bool ?? false
            self.isPlaying = playing
            onPlaybackStateChanged?(playing)
            onStateChanged?()

        case "playbackTimeDidChange":
            let cur = body["currentPlaybackTime"] as? Double ?? 0
            let dur = body["currentPlaybackDuration"] as? Double ?? 0
            let playing = body["isPlaying"] as? Bool ?? self.isPlaying

            // Monotonic guard: never accept a sudden drop back to < 1.0s while mid-track unless seeking
            if cur < 1.0 && self.currentPosition > 2.0 && !self.isSeeking {
                return
            }

            let stateFlipped = (self.isPlaying != playing)
            self.currentPosition = cur
            if dur > 0 { self.currentDuration = dur }
            self.isPlaying = playing
            onTimeChanged?(cur, dur)
            if stateFlipped || abs(cur - lastNotifiedPosition) >= 0.45 {
                lastNotifiedPosition = cur
                onStateChanged?()
            }

        case "nowPlayingItemDidChange":
            let title = body["title"] as? String ?? ""
            let artist = body["artistName"] as? String ?? ""
            self.currentTrackTitle = title
            self.currentArtistName = artist
            onTrackChanged?(title, artist)

        case "playbackEnded":
            let cur = body["currentPlaybackTime"] as? Double ?? self.currentPosition
            let dur = body["currentPlaybackDuration"] as? Double ?? self.currentDuration
            let now = Date()

            // 1. Minimum playtime guard: song must have started at least 8 seconds ago
            if let startTime = self.trackPlaybackStartTime {
                let elapsed = now.timeIntervalSince(startTime)
                if elapsed < 8.0 {
                    AppLogger.shared.log(category: .playback, level: .warn, message: "已拦截虚假完播信号: 歌曲仅启动了 \(String(format: "%.1f", elapsed)) 秒")
                    return
                }
            }

            // 2. Debounce: minimum 8 seconds between successive ended events
            if let lastEnded = self.lastPlaybackEndedTime {
                let diff = now.timeIntervalSince(lastEnded)
                if diff < 8.0 {
                    AppLogger.shared.log(category: .playback, level: .warn, message: "已拦截高频重复完播信号 (距上次切歌不足 8 秒)")
                    return
                }
            }

            // 3. Proximity check: must have actually reached near completion
            if dur > 15.0 {
                guard cur >= (dur - 5.0) || (dur > 0 && (cur / dur) > 0.88) else {
                    AppLogger.shared.log(category: .playback, level: .warn, message: "已拦截未完播信号: 进度 \(Int(cur))s / \(Int(dur))s")
                    return
                }
            } else if cur < 15.0 {
                return
            }

            self.lastPlaybackEndedTime = now
            AppLogger.shared.log(category: .playback, level: .info, message: "Apple Music 曲目自然完播 (有效时长: \(Int(cur))s)，触发自动连播下一首")
            self.isPlaying = false
            self.currentPosition = 0
            onPlaybackStateChanged?(false)
            onPlaybackEnded?()

        default:
            break
        }
    }
}
