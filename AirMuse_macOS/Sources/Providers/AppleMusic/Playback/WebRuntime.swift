import AppKit
import Foundation
import WebKit
import Domain
import Infrastructure

// MARK: - WebRuntime

/// @MainActor owner of the single active WKWebView instance for Apple Music playback.
/// Handles mounting/keep-alive, strict origin/navigation checks, script message origin validation,
/// and crash/termination isolation without mutating session state.
@MainActor
public final class WebRuntime: NSObject {
    public let dataStore: WKWebsiteDataStore
    public private(set) var engineInstanceID: UUID = UUID()
    public private(set) var webView: WKWebView?
    public private(set) var isReady: Bool = false
    public private(set) var isAuthorized: Bool = false
    public private(set) var isNavigating: Bool = false

    private weak var hostContainerView: NSView?
    private var readyWaiters: [CheckedContinuation<Void, Error>] = []

    public var onEvent: ((WebBridgeInboundEvent) -> Void)?
    public var onProcessTerminated: ((UUID) -> Void)?

    public init(dataStore: WKWebsiteDataStore = .default()) {
        self.dataStore = dataStore
        super.init()
    }

    public func attach(to parentView: NSView) {
        self.hostContainerView = parentView
        let wv = ensureWebView()
        if wv.superview !== parentView {
            wv.removeFromSuperview()
            wv.frame = NSRect(x: 0, y: 0, width: 100, height: 100)
            wv.alphaValue = 0.01
            parentView.addSubview(wv, positioned: .below, relativeTo: nil)
        }
    }

    @discardableResult
    public func ensureWebView() -> WKWebView {
        if let existing = webView {
            return existing
        }

        let instanceID = engineInstanceID
        let config = WKWebViewConfiguration()
        config.websiteDataStore = dataStore
        config.mediaTypesRequiringUserActionForPlayback = []
        config.defaultWebpagePreferences.allowsContentJavaScript = true

        let bridgeJS = Self.buildBridgeScript(engineInstanceID: instanceID)
        let userScript = WKUserScript(source: bridgeJS, injectionTime: .atDocumentEnd, forMainFrameOnly: false)
        config.userContentController.addUserScript(userScript)
        config.userContentController.add(self, name: WebBridgeParser.messageHandlerName)

        let wv = WKWebView(frame: NSRect(x: 0, y: 0, width: 100, height: 100), configuration: config)
        wv.navigationDelegate = self
        self.webView = wv

        if let host = hostContainerView {
            wv.alphaValue = 0.01
            host.addSubview(wv, positioned: .below, relativeTo: nil)
        }
        return wv
    }

    public func loadIfNeeded(storefront: String) {
        let wv = ensureWebView()
        guard !isNavigating, wv.url == nil else { return }
        isNavigating = true
        let sf = storefront.isEmpty ? "cn" : storefront
        let targetURL = URL(string: "https://music.apple.com/\(sf)/browse") ?? URL(string: "https://music.apple.com")!
        wv.load(URLRequest(url: targetURL))
    }

    public func waitUntilReady(deadlineSeconds: TimeInterval) async throws {
        if isReady { return }
        let timeoutTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(max(0.2, deadlineSeconds)))
            self?.failReadyWaiters(with: CoreError.timeout)
        }
        defer { timeoutTask.cancel() }

        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            if isReady {
                cont.resume()
            } else {
                readyWaiters.append(cont)
            }
        }
    }

    public struct BridgeJSResult: Sendable, Equatable {
        public let ok: Bool
        public let cancelled: Bool
        public let error: String?
        public let boolValue: Bool

        public init(ok: Bool = false, cancelled: Bool = false, error: String? = nil, boolValue: Bool = false) {
            self.ok = ok
            self.cancelled = cancelled
            self.error = error
            self.boolValue = boolValue
        }
    }

    public func callBridgeScript(
        _ script: String,
        stringArgs: [String: String] = [:],
        numberArgs: [String: Double] = [:]
    ) async throws -> BridgeJSResult {
        let wv = ensureWebView()
        var args: [String: Any] = [:]
        for (k, v) in stringArgs { args[k] = v }
        for (k, v) in numberArgs { args[k] = v }
        let raw = try await wv.callAsyncJavaScript(script, arguments: args, in: nil, contentWorld: .page)
        if let b = raw as? Bool {
            return BridgeJSResult(ok: b, boolValue: b)
        }
        if let dict = raw as? [String: Any] {
            return BridgeJSResult(
                ok: dict["ok"] as? Bool ?? false,
                cancelled: dict["cancelled"] as? Bool ?? false,
                error: dict["error"] as? String,
                boolValue: dict["ok"] as? Bool ?? false
            )
        }
        return BridgeJSResult()
    }

    /// Immediately isolates the current engine instance so no further events or JS callbacks
    /// from the old WebView can affect the new instance.
    public func isolateAndReset() {
        failReadyWaiters(with: CoreError.cancelled)
        if let wv = webView {
            wv.stopLoading()
            wv.configuration.userContentController.removeScriptMessageHandler(forName: WebBridgeParser.messageHandlerName)
            wv.navigationDelegate = nil
            wv.removeFromSuperview()
        }
        webView = nil
        engineInstanceID = UUID()
        isReady = false
        isAuthorized = false
        isNavigating = false
    }

    private func succeedReadyWaiters() {
        let waiters = readyWaiters
        readyWaiters.removeAll()
        for w in waiters { w.resume() }
    }

    private func failReadyWaiters(with error: Error) {
        let waiters = readyWaiters
        readyWaiters.removeAll()
        for w in waiters { w.resume(throwing: error) }
    }

    private static func buildBridgeScript(engineInstanceID: UUID) -> String {
        """
        (function() {
            'use strict';
            var BRIDGE = '\(WebBridgeParser.messageHandlerName)';
            var ENGINE_ID = '\(engineInstanceID.uuidString)';
            function post(event, payload) {
                if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers[BRIDGE]) {
                    window.webkit.messageHandlers[BRIDGE].postMessage(
                        Object.assign({ event: event, engineInstanceID: ENGINE_ID, operationID: window.__airmuseOpId || 0 }, payload || {})
                    );
                }
            }
            function emitNowPlaying(mk) {
                var item = mk.nowPlayingItem;
                if (!item) return;
                var attrs = item.attributes || {};
                var title = item.title || attrs.name || item.name || '';
                var artist = item.artistName || attrs.artistName || '';
                var album = item.albumName || attrs.albumName || '';
                var artUrl = '';
                if (item.artworkURL) {
                    artUrl = String(item.artworkURL).replace('{w}', '240').replace('{h}', '240').replace('{c}', 'bb').replace('{f}', 'webp');
                } else if (attrs.artwork && attrs.artwork.url) {
                    artUrl = String(attrs.artwork.url).replace('{w}x{h}', '240x240').replace('{w}', '240').replace('{h}', '240').replace('{c}', 'bb').replace('{f}', 'webp');
                }
                var metaDur = attrs.durationInMillis ? (attrs.durationInMillis / 1000.0) : 0;
                post('nowPlayingItemDidChange', {
                    title: title,
                    artistName: artist,
                    albumName: album,
                    artworkURL: artUrl,
                    id: item.id || '',
                    isAuthorized: !!mk.isAuthorized,
                    playbackDuration: mk.currentPlaybackDuration || 0,
                    metaDuration: metaDur
                });
            }
            function hookMusicKit() {
                try {
                    var mk = window.MusicKit && window.MusicKit.getInstance ? window.MusicKit.getInstance() : null;
                    if (!mk) return false;
                    mk.addEventListener('playbackStateDidChange', function() {
                        var s = mk.playbackState;
                        var cur = mk.currentPlaybackTime || 0;
                        var dur = mk.currentPlaybackDuration || 0;
                        post('playbackStateDidChange', {
                            playbackState: s,
                            isPlaying: s === 2,
                            isBuffering: (s === 1 || s === 7 || s === 8),
                            isPaused: (s === 3 || s === 4 || s === 0)
                        });
                        if (s === 2) {
                            emitNowPlaying(mk);
                        }
                        var isEndedState = (s === 5 || s === 9 || s === 10);
                        var isAtEOF = (!window.__airmuseTransitioning && dur > 5 && cur >= dur - 1.2 && (s === 3 || s === 4 || s === 0));
                        if (isEndedState || isAtEOF) {
                            post('playbackEnded', {
                                currentPlaybackTime: cur,
                                currentPlaybackDuration: dur
                            });
                        }
                    });
                    mk.addEventListener('playbackTimeDidChange', function() {
                        if (window.__airmuseTransitioning) return;
                        post('playbackTimeDidChange', {
                            currentPlaybackTime: mk.currentPlaybackTime || 0,
                            currentPlaybackDuration: mk.currentPlaybackDuration || 0
                        });
                    });
                    mk.addEventListener('nowPlayingItemDidChange', function() {
                        emitNowPlaying(mk);
                    });
                    mk.addEventListener('mediaItemMetadataDidChange', function() {
                        emitNowPlaying(mk);
                    });
                    post('ready', { isAuthorized: !!mk.isAuthorized });
                    return true;
                } catch (e) { return false; }
            }
            if (!hookMusicKit()) {
                var timer = setInterval(function() {
                    if (hookMusicKit()) clearInterval(timer);
                }, 150);
            }
        })();
        """
    }
}

// MARK: - WKNavigationDelegate

extension WebRuntime: WKNavigationDelegate {
    public func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
        guard webView === self.webView else { return .cancel }
        if OriginValidator.isAllowedNavigationURL(navigationAction.request.url) {
            return .allow
        }
        return .cancel
    }

    public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard webView === self.webView else { return }
        isNavigating = false
        isReady = true
        succeedReadyWaiters()
    }

    public func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        guard webView === self.webView else { return }
        isNavigating = false
        failReadyWaiters(with: CoreError.transport(statusCode: nil, message: error.localizedDescription))
    }

    public func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        guard webView === self.webView else { return }
        let crashedID = engineInstanceID
        isolateAndReset()
        onProcessTerminated?(crashedID)
    }
}

// MARK: - WKScriptMessageHandler

extension WebRuntime: WKScriptMessageHandler {
    public func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == WebBridgeParser.messageHandlerName,
              message.webView === self.webView else { return }

        let origin = message.frameInfo.securityOrigin
        guard OriginValidator.isAllowedScriptOrigin(
            protocol: origin.protocol,
            host: origin.host,
            isMainFrame: message.frameInfo.isMainFrame,
            allowSubframe: true
        ) else { return }

        guard let parsed = WebBridgeParser.parse(body: message.body, expectedEngineID: engineInstanceID) else {
            return
        }

        if case .ready(_, let isAuth) = parsed {
            self.isReady = true
            self.isAuthorized = isAuth
            succeedReadyWaiters()
        }
        onEvent?(parsed)
    }
}
