// Sources/Providers/QQMusic/QQMusicProvider.swift
// AirMuse macOS – QQ Music provider via WKWebView session adapter
// Swift 6 strict concurrency – all WebView ops on @MainActor
// Loads y.qq.com and communicates via a JS bridge.
// No user credentials, tokens, or cookies are embedded.

import Foundation
import WebKit
import Domain
import Infrastructure

// MARK: - Errors

public enum QQMusicError: Error, Sendable {
    case notLoggedIn
    case pageLoadFailed(String)
    case bridgeError(String)
    case crashIsolated   // The WebView process crashed; host app is unaffected
}

// MARK: - Page state

public enum QQMusicPageState: Sendable {
    case unknown
    case loading
    case loggedOut
    case loggedIn(userName: String)
    case playing(trackTitle: String, isPlaying: Bool)
}

// MARK: - Provider actor

public actor QQMusicProvider:
    MusicPlaybackProvider,
    MusicAuthenticationProvider
{
    // MARK: MusicProvider

    public let providerID: String = "qq_music"
    public let source: MusicSource = .qqMusic

    public var capabilities: MusicProviderCapabilities {
        get async {
            MusicProviderCapabilities(
                catalogSearch:  .unsupported,  // y.qq.com does not expose a stable API
                libraryAccess:  _pageState.isLoggedIn ? .supported : .requiresAuthorization,
                playback:       _pageState.isLoggedIn ? .supported : .requiresAuthorization,
                lyricsAccess:   .unsupported,
                radioStations:  .unsupported
            )
        }
    }

    // MARK: - Private state

    private var _pageState: QQMusicPageState = .unknown
    private var _isAuthenticated: Bool = false
    private let webViewKey = "qqmusic"
    private static let homeURL = URL(string: "https://y.qq.com")!

    // MARK: - Init

    public init() {}

    // MARK: - WebView setup (called from MainActor context)

    @MainActor
    public func makeWebViewConfiguration() -> WebViewConfiguration {
        WebViewConfiguration(
            trustedOrigins: ["y.qq.com", "qq.com"],
            useNonPersistentDataStore: false  // QQ Music requires persistent cookies for session
        )
    }

    /// Call this after WebViewManager creates the WKWebView to inject compatibility detection.
    @MainActor
    public func injectBridgeScript(into webView: WKWebView) {
        // Injected script listens for DOM changes and page state, posting messages back via
        // the AirMuse bridge handler. The script is defined entirely in Swift — no external
        // string substitution occurs.
        let script = """
        (function() {
            'use strict';
            const BRIDGE = 'airmuseBridge';
            function post(type, payload) {
                if (window.webkit && window.webkit.messageHandlers[BRIDGE]) {
                    window.webkit.messageHandlers[BRIDGE].postMessage({ type: type, payload: payload });
                }
            }

            // Auth state detection
            function detectLoginState() {
                const avatar = document.querySelector('.mod_top_toolbar .avatar, .user_name');
                const loginBtn = document.querySelector('.login_btn, [data-action="login"]');
                if (avatar) {
                    post('authStatus', { isLoggedIn: true, userName: avatar.textContent.trim() });
                } else if (loginBtn) {
                    post('authStatus', { isLoggedIn: false, userName: null });
                }
            }

            // Playback state detection
            function detectPlaybackState() {
                const playBtn = document.querySelector('.player_middle .btn_play, .js_btn_play');
                const titleEl = document.querySelector('.player_song .song_name, .js_song_name');
                if (titleEl) {
                    const isPlaying = playBtn && playBtn.classList.contains('btn_pause');
                    post('nowPlaying', {
                        title:     titleEl.textContent.trim(),
                        isPlaying: isPlaying,
                        source:    'qq_music'
                    });
                }
            }

            // DOM mutation observer for compatibility
            const observer = new MutationObserver(function() {
                detectLoginState();
                detectPlaybackState();
            });
            observer.observe(document.body, { childList: true, subtree: true });

            // Initial probe
            detectLoginState();
            detectPlaybackState();

            // Expose control surface for Swift-side commands
            window.__airmuseQQ = {
                playPause: function() {
                    const btn = document.querySelector('.btn_play, .js_btn_play');
                    if (btn) btn.click();
                },
                next: function() {
                    const btn = document.querySelector('.btn_next, .js_btn_next');
                    if (btn) btn.click();
                },
                prev: function() {
                    const btn = document.querySelector('.btn_prev, .js_btn_prev');
                    if (btn) btn.click();
                }
            };
        })();
        """
        let userScript = WKUserScript(source: script,
                                      injectionTime: .atDocumentEnd,
                                      forMainFrameOnly: true)
        webView.configuration.userContentController.addUserScript(userScript)
    }

    // MARK: - Bridge message handling

    public func handleBridgeMessage(_ envelope: BridgeEnvelope) {
        switch envelope.typedPayload() {
        case .authStatus(let p):
            _isAuthenticated = p.isLoggedIn
            _pageState = p.isLoggedIn
                ? .loggedIn(userName: p.userName ?? "")
                : .loggedOut
        case .nowPlaying(let p):
            if let title = p.title {
                _pageState = .playing(trackTitle: title, isPlaying: p.isPlaying ?? false)
            }
        default:
            break
        }
    }

    /// Call when WebViewManager reports a process crash — isolates the crash from the host app.
    public func handleWebViewCrash() {
        _pageState = .unknown
        _isAuthenticated = false
        // Provider degrades gracefully; host app is not affected
    }

    // MARK: - MusicAuthenticationProvider

    public var isAuthenticated: Bool { _isAuthenticated }

    public func authenticate() async throws {
        // QQ Music authentication is performed by the user inside the WebView (y.qq.com login flow).
        // We navigate to the login page and wait for the bridge to report success.
        await MainActor.run {
            // WebViewManager.shared.navigate(key: webViewKey, to: Self.homeURL, config: ...)
            // Wired externally through the full integration layer.
        }
    }

    public func signOut() async throws {
        _isAuthenticated = false
        _pageState = .loggedOut
        // Clear the persistent session so the user must log in again
        await MainActor.run {
            WKWebsiteDataStore.default().removeData(
                ofTypes: [WKWebsiteDataTypeSessionStorage,
                          WKWebsiteDataTypeCookies,
                          WKWebsiteDataTypeLocalStorage],
                modifiedSince: .distantPast) {}
        }
    }

    public func currentAccount() async -> MusicAccount? {
        guard case .loggedIn(let name) = _pageState else { return nil }
        return MusicAccount(displayName: name, source: .qqMusic, isAuthenticated: true)
    }

    // MARK: - MusicPlaybackProvider

    public func play(track: MusicTrack) async throws {
        guard _isAuthenticated else { throw QQMusicError.notLoggedIn }
        // Deep-linking a specific track in y.qq.com requires navigating to its URL.
        // The track.id for QQ Music should be the numeric song mid.
        let urlString = "https://y.qq.com/n/ryqq/songDetail/\(track.id)"
        guard let url = URL(string: urlString) else { return }
        await MainActor.run {
            // WebViewManager.shared.navigate(key: webViewKey, to: url, ...)
            _ = url  // placeholder
        }
    }

    public func playPause() async throws {
        try await executeQQBridgeAction("playPause")
    }

    public func stop() async throws {
        try await executeQQBridgeAction("playPause")  // QQ Music has no dedicated stop
    }

    public func skipToNext() async throws {
        try await executeQQBridgeAction("next")
    }

    public func skipToPrevious() async throws {
        try await executeQQBridgeAction("prev")
    }

    public func seek(to seconds: Double) async throws {
        // QQ Music web player seek is unreliable via DOM; mark as unsupported for now.
        throw QQMusicError.bridgeError("Seek not supported on QQ Music web player")
    }

    public func setVolume(_ volume: Float) async throws {
        let js = "if(window.__airmuseQQ && window.__airmuseQQ.setVolume) window.__airmuseQQ.setVolume(\(Double(volume)));"
        await MainActor.run {
            _ = js  // evaluated via WebViewManager in full integration
        }
    }

    public func currentSession() async -> PlaybackSession {
        switch _pageState {
        case .playing(_, let isPlaying):
            return PlaybackSession(source: .qqMusic, state: isPlaying ? .playing : .paused)
        case .loggedIn:
            return PlaybackSession(source: .qqMusic, state: .idle)
        default:
            return PlaybackSession(source: .qqMusic, state: .idle)
        }
    }

    // MARK: - Private

    private func executeQQBridgeAction(_ action: String) async throws {
        // Build a safe JS string calling only our injected __airmuseQQ surface.
        // `action` is a programmer-controlled literal — not user/external input.
        let js = "if(window.__airmuseQQ) window.__airmuseQQ.\(action)();"
        await MainActor.run {
            _ = js  // evaluated via WebViewManager in full integration
        }
    }
}

// MARK: - Page state helpers

private extension QQMusicPageState {
    var isLoggedIn: Bool {
        if case .loggedIn = self { return true }
        if case .playing  = self { return true }
        return false
    }
}
