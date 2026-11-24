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

    public private(set) var isReady: Bool = false {
        didSet {
            if isReady {
                resumeReadyWaiters()
            }
        }
    }
    public private(set) var isPlaying: Bool = false
    public private(set) var isBuffering: Bool = false
    public private(set) var hasStartedAudio: Bool = false
    public private(set) var currentVolume: Float = 1.0
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
                    try {
                        localStorage.setItem('media-user-token', t);
                        localStorage.setItem('music.userToken', t);
                        if (!document.cookie.includes('media-user-token=')) {
                            document.cookie = 'media-user-token=' + t + '; domain=.music.apple.com; path=/; max-age=31536000; Secure; SameSite=Lax';
                            document.cookie = 'media-user-token=' + t + '; domain=.apple.com; path=/; max-age=31536000; Secure; SameSite=Lax';
                        }
                    } catch(e) {}
                    var mk = window.MusicKit && window.MusicKit.getInstance ? window.MusicKit.getInstance() : null;
                    if (mk) {
                        var wasAuthorized = !!mk.isAuthorized;
                        if (!mk.musicUserToken) {
                            mk.musicUserToken = t;
                        }
                        return wasAuthorized;
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

    public var onPlaybackStateChanged: ((Bool) -> Void)?
    public var onTimeChanged: ((Double, Double) -> Void)?
    public var onTrackChanged: ((String, String) -> Void)?
    public var onPlaybackEnded: (() -> Void)?
    public var onStateChanged: (() -> Void)?

    private var isNavigating: Bool = false
    private var didReloadForAuth: Bool = false
    private var isExecutingPlayScript: Bool = false
    private var playCommandGeneration: Int = 0
    private var lastNotifiedPosition: Double = -1
    private var trackPlaybackStartTime: Date?
    private var lastPlaybackEndedTime: Date?
    private var readyWaiters: [CheckedContinuation<Void, Never>] = []
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
                if (window.__airmuseTransitioning) return;
                var mk = window.MusicKit && window.MusicKit.getInstance ? window.MusicKit.getInstance() : null;
                var item = mk ? mk.nowPlayingItem : null;
                var cur = 0;
                var dur = 0;

                if (mk) {
                    cur = mk.currentPlaybackTime || 0;
                    dur = mk.currentPlaybackDuration || 0;
                    if (item && item.attributes && item.attributes.durationInMillis) {
                        dur = item.attributes.durationInMillis / 1000.0;
                    }
                }

                post('playbackTimeDidChange', {
                    currentPlaybackTime: cur,
                    currentPlaybackDuration: dur
                });
            }

            function checkTrackEnded(source) {
                var mk = window.MusicKit && window.MusicKit.getInstance ? window.MusicKit.getInstance() : null;
                var item = mk ? mk.nowPlayingItem : null;
                var cur = mk ? (mk.currentPlaybackTime || 0) : 0;
                var dur = mk ? (mk.currentPlaybackDuration || 0) : 0;
                if (item && item.attributes && item.attributes.durationInMillis) {
                    dur = item.attributes.durationInMillis / 1000.0;
                }
                if (dur > 3.0 && cur >= (dur - 2.5) && cur > 2.0) {
                    post('playbackEnded', {
                        currentPlaybackTime: cur,
                        currentPlaybackDuration: dur,
                        source: source
                    });
                }
            }

            function hookMusicKit() {
                try {
                    var mk = window.MusicKit && window.MusicKit.getInstance ? window.MusicKit.getInstance() : null;
                    if (!mk) return false;

                    mk.addEventListener('playbackStateDidChange', function() {
                        var rawState = mk.playbackState;
                        // MusicKit PlaybackStates:
                        // 0: none, 1: loading, 2: playing, 3: paused, 4: stopped, 5: ended, 6: seeking, 7: waiting, 8: stalled, 9: completed
                        var isPlaying = (rawState === 2);
                        var isBuffering = (rawState === 1 || rawState === 7 || rawState === 8);
                        var isPaused = (rawState === 3 || rawState === 4 || rawState === 0);
                        post('playbackStateDidChange', {
                            isPlaying: isPlaying,
                            isBuffering: isBuffering,
                            isPaused: isPaused,
                            playbackState: rawState
                        });
                        notifyTime();
                        if (rawState === 5 || rawState === 9) {
                            checkTrackEnded('musickit_state');
                        }
                    });

                    mk.addEventListener('playbackTimeDidChange', notifyTime);

                    mk.addEventListener('nowPlayingItemDidChange', function() {
                        var item = mk.nowPlayingItem;
                        var metaDur = (item && item.attributes && item.attributes.durationInMillis) ? (item.attributes.durationInMillis / 1000.0) : 0;
                        post('nowPlayingItemDidChange', {
                            title: item ? (item.title || item.name || '') : '',
                            artistName: item ? (item.artistName || '') : '',
                            id: item ? (item.id || '') : '',
                            isAuthorized: !!mk.isAuthorized,
                            playbackDuration: mk.currentPlaybackDuration || 0,
                            metaDuration: metaDur
                        });
                        notifyTime();
                    });

                    post('ready', { isAuthorized: mk.isAuthorized || false });
                    return true;
                } catch(e) {
                    return false;
                }
            }

            setInterval(notifyTime, 250);

            if (!hookMusicKit()) {
                var timer = setInterval(function() {
                    if (hookMusicKit()) clearInterval(timer);
                }, 150);
            }
        })();
        """

        // Pre-inject media-user-token into localStorage and cookies before any scripts run
        var startScriptSource = """
        (function() {
            try {
                var cookieMatch = document.cookie.match(/media-user-token=([^;]+)/);
                if (cookieMatch && cookieMatch[1]) {
                    var cVal = decodeURIComponent(cookieMatch[1]);
                    try { localStorage.setItem('media-user-token', cVal); } catch(e) {}
                    try { localStorage.setItem('music.userToken', cVal); } catch(e) {}
                }
            } catch(e) {}
        })();
        """
        if let token = self.userToken, !token.isEmpty {
            let lit = Self.jsStringLiteral(token)
            startScriptSource = """
            (function() {
                try {
                    var t = \(lit);
                    if (t) {
                        try { localStorage.setItem('media-user-token', t); } catch(e) {}
                        try { localStorage.setItem('music.userToken', t); } catch(e) {}
                        try {
                            if (!document.cookie.includes('media-user-token=')) {
                                document.cookie = 'media-user-token=' + t + '; domain=.music.apple.com; path=/; max-age=31536000; Secure; SameSite=Lax';
                                document.cookie = 'media-user-token=' + t + '; domain=.apple.com; path=/; max-age=31536000; Secure; SameSite=Lax';
                            }
                        } catch(e) {}
                    }
                } catch(e) {}
                try {
                    var cookieMatch = document.cookie.match(/media-user-token=([^;]+)/);
                    if (cookieMatch && cookieMatch[1]) {
                        var cVal = cookieMatch[1].includes('%') ? decodeURIComponent(cookieMatch[1]) : cookieMatch[1];
                        try { localStorage.setItem('media-user-token', cVal); } catch(e) {}
                        try { localStorage.setItem('music.userToken', cVal); } catch(e) {}
                    }
                } catch(e) {}
            })();
            """
        }
        let startScript = WKUserScript(source: startScriptSource, injectionTime: .atDocumentStart, forMainFrameOnly: false)
        config.userContentController.addUserScript(startScript)

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
            // Ensure document-start token script is present even if attach() created WKWebView before restoreSessionFromStorage()
            if let token = self.userToken, !token.isEmpty {
                let lit = Self.jsStringLiteral(token)
                let tokenStartJS = """
                (function() {
                    try {
                        var t = \(lit);
                        if (t) {
                            try { localStorage.setItem('media-user-token', t); } catch(e) {}
                            try { localStorage.setItem('music.userToken', t); } catch(e) {}
                            try {
                                if (!document.cookie.includes('media-user-token=')) {
                                    document.cookie = 'media-user-token=' + t + '; domain=.music.apple.com; path=/; max-age=31536000; Secure; SameSite=Lax';
                                    document.cookie = 'media-user-token=' + t + '; domain=.apple.com; path=/; max-age=31536000; Secure; SameSite=Lax';
                                }
                            } catch(e) {}
                        }
                    } catch(e) {}
                })();
                """
                let extraScript = WKUserScript(source: tokenStartJS, injectionTime: .atDocumentStart, forMainFrameOnly: false)
                wv.configuration.userContentController.addUserScript(extraScript)
            }
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

    /// Immediately resets playback state before switching to a new track so stale events from the previous song cannot leak through.
    public func beginTrackTransition() {
        playCommandGeneration += 1
        isExecutingPlayScript = true
        isBuffering = true
        isPlaying = false
        hasStartedAudio = false
        currentPosition = 0
        currentDuration = 0
        lastNotifiedPosition = -1
        trackPlaybackStartTime = nil
        onStateChanged?()
    }

    /// Plays a catalog or library song by ID from 0:00 with full audio quality
    public func playSong(id: String) async throws -> Bool {
        preload()
        let js = """
        try {
            window.__airmusePlayCmdId = cmdId;
            window.__airmuseTransitioning = true;
            var mk = window.MusicKit && window.MusicKit.getInstance ? window.MusicKit.getInstance() : null;
            if (!mk) { window.__airmuseTransitioning = false; return { ok: false, error: "MusicKit not loaded" }; }
            if (uToken && !mk.musicUserToken) {
                mk.musicUserToken = uToken;
            }
            if (!mk.isAuthorized) {
                window.__airmuseTransitioning = false;
                return { ok: false, error: "WEB_NOT_AUTHORIZED" };
            }
            mk.volume = targetVol;
            if (mk.isPlaying) {
                try { mk.stop(); } catch(e) {}
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
            if (window.__airmusePlayCmdId !== cmdId) {
                return { ok: false, cancelled: true };
            }
            window.__airmuseTransitioning = false;
            await Promise.race([
                Promise.resolve(mk.play()),
                new Promise(function(resolve) { setTimeout(resolve, 1500); })
            ]);
            var a = document.querySelector('audio, video');
            return {
                ok: true,
                isAuth: !!mk.isAuthorized,
                hasToken: !!mk.musicUserToken,
                hasCookie: document.cookie.includes('media-user-token='),
                storefront: String(mk.storefrontId || ''),
                mkDur: Number(mk.currentPlaybackDuration || 0),
                audioDur: a && isFinite(a.duration) ? Number(a.duration) : 0,
                audioSrc: a && a.src ? String(a.src).slice(0, 90) : ''
            };
        } catch(e) {
            return { ok: false, error: String(e && e.message ? e.message : e) };
        }
        """
        return try await executePlayScript(js, arguments: ["trackId": id, "uToken": userToken ?? "", "targetVol": Double(currentVolume)], description: "单曲 [\(id)]")
    }

    /// Plays a radio station by ID
    public func playStation(id: String) async throws -> Bool {
        preload()
        let js = """
        try {
            window.__airmusePlayCmdId = cmdId;
            var mk = window.MusicKit && window.MusicKit.getInstance ? window.MusicKit.getInstance() : null;
            if (!mk) return { ok: false, error: "MusicKit not loaded" };
            if (uToken && !mk.musicUserToken) {
                mk.musicUserToken = uToken;
            }
            if (!mk.isAuthorized) {
                return { ok: false, error: "WEB_NOT_AUTHORIZED" };
            }
            mk.volume = targetVol;
            if (mk.isPlaying) {
                try { mk.stop(); } catch(e) {}
            }
            await mk.setQueue({ station: String(trackId) });
            if (window.__airmusePlayCmdId !== cmdId) {
                return { ok: false, cancelled: true };
            }
            await Promise.race([
                Promise.resolve(mk.play()),
                new Promise(function(resolve) { setTimeout(resolve, 1500); })
            ]);
            return { ok: true };
        } catch(e) {
            return { ok: false, error: String(e && e.message ? e.message : e) };
        }
        """
        return try await executePlayScript(js, arguments: ["trackId": id, "uToken": userToken ?? "", "targetVol": Double(currentVolume)], description: "广播电台 [\(id)]")
    }

    /// Plays a playlist starting at index
    public func playPlaylist(id: String, startIndex: Int = 0) async throws -> Bool {
        preload()
        let js = """
        try {
            window.__airmusePlayCmdId = cmdId;
            var mk = window.MusicKit && window.MusicKit.getInstance ? window.MusicKit.getInstance() : null;
            if (!mk) return { ok: false, error: "MusicKit not loaded" };
            if (uToken && !mk.musicUserToken) {
                mk.musicUserToken = uToken;
            }
            if (!mk.isAuthorized) {
                return { ok: false, error: "WEB_NOT_AUTHORIZED" };
            }
            mk.volume = targetVol;
            if (mk.isPlaying) {
                try { mk.stop(); } catch(e) {}
            }
            var rawId = String(trackId);
            var cleanId = rawId.replace(/^[ilp]\\./, '');
            try {
                await mk.setQueue({ playlist: cleanId, startWith: startIndex });
            } catch(e1) {
                await mk.setQueue({ playlist: rawId, startWith: startIndex });
            }
            if (window.__airmusePlayCmdId !== cmdId) {
                return { ok: false, cancelled: true };
            }
            await Promise.race([
                Promise.resolve(mk.play()),
                new Promise(function(resolve) { setTimeout(resolve, 1500); })
            ]);
            return { ok: true };
        } catch(e) {
            return { ok: false, error: String(e && e.message ? e.message : e) };
        }
        """
        return try await executePlayScript(js, arguments: ["trackId": id, "startIndex": startIndex, "uToken": userToken ?? "", "targetVol": Double(currentVolume)], description: "歌单 [\(id)]")
    }

    /// Plays an album starting at index
    public func playAlbum(id: String, startIndex: Int = 0) async throws -> Bool {
        preload()
        let js = """
        try {
            window.__airmusePlayCmdId = cmdId;
            var mk = window.MusicKit && window.MusicKit.getInstance ? window.MusicKit.getInstance() : null;
            if (!mk) return { ok: false, error: "MusicKit not loaded" };
            if (uToken && !mk.musicUserToken) {
                mk.musicUserToken = uToken;
            }
            if (!mk.isAuthorized) {
                return { ok: false, error: "WEB_NOT_AUTHORIZED" };
            }
            mk.volume = targetVol;
            if (mk.isPlaying) {
                try { mk.stop(); } catch(e) {}
            }
            var rawId = String(trackId);
            var cleanId = rawId.replace(/^[ilp]\\./, '');
            try {
                await mk.setQueue({ album: cleanId, startWith: startIndex });
            } catch(e1) {
                await mk.setQueue({ album: rawId, startWith: startIndex });
            }
            if (window.__airmusePlayCmdId !== cmdId) {
                return { ok: false, cancelled: true };
            }
            await Promise.race([
                Promise.resolve(mk.play()),
                new Promise(function(resolve) { setTimeout(resolve, 1500); })
            ]);
            return { ok: true };
        } catch(e) {
            return { ok: false, error: String(e && e.message ? e.message : e) };
        }
        """
        return try await executePlayScript(js, arguments: ["trackId": id, "startIndex": startIndex, "uToken": userToken ?? "", "targetVol": Double(currentVolume)], description: "专辑 [\(id)]")
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
            self.trackPlaybackStartTime = nil
            self.isPlaying = false
            self.isBuffering = false
            onPlaybackStateChanged?(false)
            onStateChanged?()
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
            self.trackPlaybackStartTime = Date()
            self.isPlaying = true
            self.isBuffering = false
            onPlaybackStateChanged?(true)
            onStateChanged?()
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
        self.trackPlaybackStartTime = nil
        self.isPlaying = false
        self.isBuffering = false
        self.hasStartedAudio = false
        onPlaybackStateChanged?(false)
        onStateChanged?()
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
        let clamped = min(max(volume, 0.0), 1.0)
        self.currentVolume = clamped
        guard let wv = webView else { return }
        let js = """
        (function() {
            try {
                var mk = window.MusicKit && window.MusicKit.getInstance ? window.MusicKit.getInstance() : null;
                if (mk) mk.volume = \(Double(clamped));
            } catch(e) {}
        })();
        """
        _ = try? await wv.evaluateJavaScript(js)
        onStateChanged?()
    }

    /// Clean reset of player on sign-out
    public func reset() {
        Task { try? await stop() }
        webView?.stopLoading()
        webView?.removeFromSuperview()
        webView = nil
        isReady = false
        isPlaying = false
        isBuffering = false
        hasStartedAudio = false
        currentPosition = 0
        currentDuration = 0
        currentTrackTitle = ""
        currentArtistName = ""
        isNavigating = false
        didReloadForAuth = false
        isExecutingPlayScript = false
        playCommandGeneration += 1
        trackPlaybackStartTime = nil
        lastPlaybackEndedTime = nil
        resumeReadyWaiters()
        AppLogger.shared.log(category: .playback, level: .info, message: "Apple Music Web 播放器已重置释放")
    }

    // MARK: - Ready Waiter & Private Execution Helper

    private func resumeReadyWaiters() {
        let waiters = readyWaiters
        readyWaiters.removeAll()
        for cont in waiters {
            cont.resume()
        }
    }

    private func waitUntilReady(timeoutSeconds: Double) async {
        if isReady { return }
        let timeoutTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(timeoutSeconds))
            self?.resumeReadyWaiters()
        }
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            if self.isReady {
                cont.resume()
            } else {
                self.readyWaiters.append(cont)
            }
        }
        timeoutTask.cancel()
    }

    private func executePlayScript(_ script: String, arguments: [String: Any], description: String) async throws -> Bool {
        let wv = ensureWebView()
        playCommandGeneration += 1
        let myGen = playCommandGeneration

        // Establish loading/buffering state until audio actually starts playing
        self.isBuffering = true
        self.isPlaying = false
        self.hasStartedAudio = false
        self.currentPosition = 0
        self.trackPlaybackStartTime = Date()
        self.isExecutingPlayScript = true
        defer {
            if myGen == playCommandGeneration {
                self.isExecutingPlayScript = false
            }
        }
        onStateChanged?()

        if !isReady {
            await waitUntilReady(timeoutSeconds: 4.0)
            guard myGen == playCommandGeneration else { return false }
        }

        var argsWithGen = arguments
        argsWithGen["cmdId"] = myGen

        // Poll up to ~4.8s (24 × 200ms) for MusicKit JS instance if page just finished loading
        var retries = 0
        while retries < 24 {
            try Task.checkCancellation()
            guard myGen == playCommandGeneration else { return false }
            do {
                let res = try await wv.callAsyncJavaScript(script, arguments: argsWithGen, in: nil, contentWorld: .page)
                guard myGen == playCommandGeneration else { return false }
                if let dict = res as? [String: Any], let ok = dict["ok"] as? Bool, ok {
                    self.trackPlaybackStartTime = Date()
                    let isAuth = dict["isAuth"] as? Bool ?? false
                    let hasCookie = dict["hasCookie"] as? Bool ?? false
                    let sf = dict["storefront"] as? String ?? ""
                    let mkDur = dict["mkDur"] as? Double ?? 0
                    let audioDur = dict["audioDur"] as? Double ?? 0
                    let audioSrc = dict["audioSrc"] as? String ?? ""
                    let diag = "isAuth=\(isAuth), hasCookie=\(hasCookie), sf=\(sf), mkDur=\(Int(mkDur))s, audioDur=\(Int(audioDur))s" + (audioSrc.isEmpty ? "" : ", src=\(audioSrc)")
                    AppLogger.shared.log(category: .playback, level: .info, message: "Web 播放器指令执行成功: \(description)", details: diag)
                    onStateChanged?()
                    return true
                } else if let dict = res as? [String: Any], let cancelled = dict["cancelled"] as? Bool, cancelled {
                    return false
                } else if let dict = res as? [String: Any], let err = dict["error"] as? String {
                    if err == "WEB_NOT_AUTHORIZED" {
                        AppLogger.shared.log(category: .playback, level: .error, message: "Web 端 MusicKit 未处于授权状态 (isAuthorized=false)，已中止播放")
                        self.isPlaying = false
                        self.isBuffering = false
                        self.trackPlaybackStartTime = nil
                        onPlaybackStateChanged?(false)
                        onStateChanged?()
                        if !AppleMusicSessionManager.shared.webSessionState.isLoggedIn {
                            NotificationCenter.default.post(name: .appleMusicRequiresAuthentication, object: nil)
                        }
                        return false
                    }
                    AppLogger.shared.log(category: .playback, level: .warn, message: "Web 播放器暂未就绪 (\(err))，正在重试... [\(retries + 1)/24]")
                }
            } catch {
                guard myGen == playCommandGeneration else { return false }
                AppLogger.shared.log(category: .playback, level: .warn, message: "Web 播放器异步调用异常: \(error.localizedDescription)，重试中...")
            }
            try? await Task.sleep(for: .milliseconds(200))
            retries += 1
        }
        self.isPlaying = false
        self.isBuffering = false
        self.trackPlaybackStartTime = nil
        onPlaybackStateChanged?(false)
        onStateChanged?()
        return false
    }

    // MARK: - WKNavigationDelegate

    public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        isNavigating = false
        isReady = true
        AppLogger.shared.log(category: .playback, level: .info, message: "Apple Music 官方 Web 播放器核心页面加载完成")
        if let token = userToken, !token.isEmpty {
            setUserToken(token)
        }
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

        case "playbackStateDidChange":
            let rawState = body["playbackState"] as? Int ?? -1
            let buffering = body["isBuffering"] as? Bool ?? (rawState == 1 || rawState == 7 || rawState == 8)
            let paused = body["isPaused"] as? Bool ?? (rawState == 3 || rawState == 4 || rawState == 0)
            let playing = body["isPlaying"] as? Bool ?? (rawState == 2)

            let previousPlaying = self.isPlaying
            let previousBuffering = self.isBuffering

            if playing {
                self.isPlaying = true
                self.isBuffering = false
                self.hasStartedAudio = true
            } else if buffering {
                self.isBuffering = true
                if !self.hasStartedAudio {
                    self.isPlaying = false
                }
            } else if paused {
                // Ignore transient stopped/none events emitted by mk.stop()/setQueue while a new track script is executing
                if self.isExecutingPlayScript && (rawState == 0 || rawState == 4) {
                    return
                }
                self.isPlaying = false
                self.isBuffering = false
            }

            if self.isPlaying != previousPlaying || self.isBuffering != previousBuffering {
                if self.isPlaying != previousPlaying {
                    AppLogger.shared.log(category: .playback, level: .info, message: "Apple Music 播放状态切换: \(previousPlaying ? "播放中" : "未播放") -> \(self.isPlaying ? "播放中" : "未播放") (MusicKit 状态码: \(rawState))")
                    onPlaybackStateChanged?(self.isPlaying)
                }
                onStateChanged?()
            }

        case "playbackTimeDidChange":
            if self.isExecutingPlayScript {
                return
            }
            let cur = body["currentPlaybackTime"] as? Double ?? 0
            let dur = body["currentPlaybackDuration"] as? Double ?? 0

            // Monotonic guard: never accept a sudden drop back to < 1.0s while mid-track unless seeking
            if cur < 1.0 && self.currentPosition > 2.0 && !self.isSeeking {
                return
            }

            self.currentPosition = cur
            if dur > 0 { self.currentDuration = dur }
            let justStartedAudio = !self.hasStartedAudio && cur > 0.01 && self.isPlaying
            if cur > 0.01 && self.isPlaying {
                self.hasStartedAudio = true
                self.isBuffering = false
            }
            onTimeChanged?(cur, dur)
            if justStartedAudio || abs(cur - lastNotifiedPosition) >= 0.45 {
                lastNotifiedPosition = cur
                onStateChanged?()
            }

        case "nowPlayingItemDidChange":
            let title = body["title"] as? String ?? ""
            let artist = body["artistName"] as? String ?? ""
            let isAuth = body["isAuthorized"] as? Bool ?? false
            let pbDur = body["playbackDuration"] as? Double ?? 0
            let metaDur = body["metaDuration"] as? Double ?? 0
            if !title.isEmpty {
                AppLogger.shared.log(
                    category: .playback,
                    level: (pbDur > 0 && pbDur <= 31 && metaDur > 45) ? .warn : .info,
                    message: "MusicKit 曲目变更: \(title) - \(artist)",
                    details: "isAuthorized=\(isAuth), 流时长=\(Int(pbDur))s, 元数据时长=\(Int(metaDur))s"
                )
            }
            self.currentTrackTitle = title
            self.currentArtistName = artist
            onTrackChanged?(title, artist)

        case "playbackEnded":
            let cur = body["currentPlaybackTime"] as? Double ?? self.currentPosition
            let dur = body["currentPlaybackDuration"] as? Double ?? self.currentDuration
            let now = Date()

            // 1. Minimum playtime guard: song must have started at least 3 seconds ago
            if let startTime = self.trackPlaybackStartTime {
                let elapsed = now.timeIntervalSince(startTime)
                if elapsed < 3.0 {
                    AppLogger.shared.log(category: .playback, level: .warn, message: "已拦截虚假完播信号: 歌曲仅启动了 \(String(format: "%.1f", elapsed)) 秒")
                    return
                }
            }

            // 2. Debounce: minimum 5 seconds between successive ended events
            if let lastEnded = self.lastPlaybackEndedTime {
                let diff = now.timeIntervalSince(lastEnded)
                if diff < 5.0 {
                    AppLogger.shared.log(category: .playback, level: .warn, message: "已拦截高频重复完播信号 (距上次切歌不足 5 秒)")
                    return
                }
            }

            // 3. Proximity check: must have actually reached near completion
            if dur > 3.0 {
                guard cur >= (dur - 2.5) || (dur > 0 && (cur / dur) > 0.88) else {
                    AppLogger.shared.log(category: .playback, level: .warn, message: "已拦截未完播信号: 进度 \(Int(cur))s / \(Int(dur))s")
                    return
                }
            } else if cur < 2.0 {
                return
            }

            self.lastPlaybackEndedTime = now
            AppLogger.shared.log(category: .playback, level: .info, message: "Apple Music 曲目自然完播 (有效时长: \(Int(cur))s)，触发自动连播下一首")
            self.isPlaying = false
            self.isBuffering = false
            self.currentPosition = 0
            onPlaybackStateChanged?(false)
            onPlaybackEnded?()

        default:
            break
        }
    }
}
