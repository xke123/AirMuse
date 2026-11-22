// Sources/Infrastructure/WebKit/WebViewManager.swift
// AirMuse macOS – Centralised WKWebView lifecycle manager
// Swift 6 strict concurrency – @MainActor throughout

import Foundation
import WebKit

// MARK: - Configuration

public struct WebViewConfiguration: Sendable {
    /// Allowlist of origins that may post bridge messages.
    public var trustedOrigins: Set<String>
    /// Whether to use an ephemeral (non-persistent) data store.
    public var useNonPersistentDataStore: Bool

    public init(trustedOrigins: Set<String> = [], useNonPersistentDataStore: Bool = true) {
        self.trustedOrigins = trustedOrigins
        self.useNonPersistentDataStore = useNonPersistentDataStore
    }
}

// MARK: - Bridge delegate

@MainActor
public protocol WebViewBridgeDelegate: AnyObject {
    /// Called when a validated message arrives from the WebView's JS context.
    func webViewManager(_ manager: WebViewManager,
                        didReceiveMessage envelope: BridgeEnvelope,
                        from key: String)
    /// Called when a page navigation completes.
    func webViewManager(_ manager: WebViewManager,
                        didFinishNavigationFor key: String)
    /// Called when a WebView process terminates unexpectedly.
    func webViewManager(_ manager: WebViewManager,
                        webViewCrashedFor key: String)
}

// MARK: - Manager

/// Manages a pool of WKWebView instances, one per logical key (e.g. "spotify", "qqmusic").
/// All public methods must be called on the main actor.
@MainActor
public final class WebViewManager: NSObject {

    // MARK: Stored state

    private var webViews: [String: WKWebView] = [:]
    /// Keys whose WebViews are currently producing active playback — these must not be torn down.
    private var activePlaybackKeys: Set<String> = []
    private let bridgeHandlerName = "airmuseBridge"

    public weak var delegate: (any WebViewBridgeDelegate)?

    // MARK: - Init

    public override init() { super.init() }

    // MARK: - WebView lifecycle

    /// Returns an existing WebView for `key`, or creates one with `config`.
    public func webView(for key: String, configuration config: WebViewConfiguration) -> WKWebView {
        if let existing = webViews[key] { return existing }
        let wkConfig = makeWKConfiguration(bridgeConfig: config, key: key)
        let webView  = WKWebView(frame: .zero, configuration: wkConfig)
        webView.navigationDelegate = self
        webViews[key] = webView
        return webView
    }

    /// Mark a key as actively playing — prevents its WebView being released.
    public func markActivePlayback(key: String) {
        activePlaybackKeys.insert(key)
    }

    /// Clear the active-playback mark; the WebView may now be released when unused.
    public func clearActivePlayback(key: String) {
        activePlaybackKeys.remove(key)
    }

    /// Tear down a WebView for `key` unless it is actively playing.
    public func releaseWebView(for key: String) {
        guard !activePlaybackKeys.contains(key) else { return }
        webViews.removeValue(forKey: key)
    }

    /// Force tear-down regardless of playback state (e.g. sign-out).
    public func forceReleaseWebView(for key: String) {
        activePlaybackKeys.remove(key)
        webViews.removeValue(forKey: key)
    }

    // MARK: - Navigation

    public func navigate(key: String, to url: URL, config: WebViewConfiguration) {
        let wv = webView(for: key, configuration: config)
        wv.load(URLRequest(url: url))
    }

    // MARK: - Safe JS execution
    // We only execute JSON produced by JSONEncoder — never raw external strings.

    public func send(command: BridgeCommand, to key: String) {
        guard let wv = webViews[key] else { return }
        guard let js = try? command.toJavaScript(handlerName: "window.airmuseBridge") else { return }
        wv.evaluateJavaScript(js, completionHandler: nil)
    }

    // MARK: - Private helpers

    private func makeWKConfiguration(bridgeConfig: WebViewConfiguration, key: String) -> WKWebViewConfiguration {
        let config = WKWebViewConfiguration()

        // Session isolation: use non-persistent store unless caller opts out
        if bridgeConfig.useNonPersistentDataStore {
            config.websiteDataStore = WKWebsiteDataStore.nonPersistent()
        }

        // Bridge handler (message source is validated below)
        let handler = BridgeScriptMessageHandler(manager: self, key: key,
                                                  trustedOrigins: bridgeConfig.trustedOrigins)
        config.userContentController.add(handler, name: bridgeHandlerName)

        return config
    }

    // MARK: - Internal receive (called by BridgeScriptMessageHandler)

    fileprivate func receiveRawMessage(_ body: Any, from key: String) {
        // Serialise back to Data so we can use our safe JSONDecoder path
        guard
            let data = try? JSONSerialization.data(withJSONObject: body),
            let envelope = BridgeEnvelope.decode(from: data)
        else { return }
        delegate?.webViewManager(self, didReceiveMessage: envelope, from: key)
    }
}

// MARK: - WKNavigationDelegate

extension WebViewManager: WKNavigationDelegate {

    public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard let key = key(for: webView) else { return }
        delegate?.webViewManager(self, didFinishNavigationFor: key)
    }

    public func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        guard let key = key(for: webView) else { return }
        // Crash isolation: notify delegate but do NOT crash the host app
        delegate?.webViewManager(self, webViewCrashedFor: key)
        // Remove the crashed instance so it is recreated on next access
        forceReleaseWebView(for: key)
    }

    private func key(for webView: WKWebView) -> String? {
        webViews.first(where: { $0.value === webView })?.key
    }
}

// MARK: - Bridge handler (source validation)

/// A WKScriptMessageHandler that validates message origin before forwarding.
private final class BridgeScriptMessageHandler: NSObject, WKScriptMessageHandler, @unchecked Sendable {
    private weak var manager: WebViewManager?
    private let key: String
    private let trustedOrigins: Set<String>

    init(manager: WebViewManager, key: String, trustedOrigins: Set<String>) {
        self.manager = manager
        self.key = key
        self.trustedOrigins = trustedOrigins
    }

    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        // Validate origin when a trusted-origin set is provided
        if !trustedOrigins.isEmpty {
            let frameInfo = message.frameInfo
            guard
                let origin = frameInfo.securityOrigin.host.nilIfEmpty,
                trustedOrigins.contains(origin)
            else { return }
        }

        Task { @MainActor [weak self] in
            guard let self else { return }
            self.manager?.receiveRawMessage(message.body, from: self.key)
        }
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
