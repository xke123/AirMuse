import AppKit
import Foundation
import WebKit
import Domain
import Infrastructure

// MARK: - AmpSessionAuthBackend

/// Bridges `SessionAuthBackendProtocol` to `AppleMusicAmpClient` so `SessionCoordinator`
/// verifies user tokens and refreshes client developer tokens against Apple's official endpoints.
public struct AmpSessionAuthBackend: SessionAuthBackendProtocol, Sendable {
    private let ampClient: AppleMusicAmpClient

    public init(ampClient: AppleMusicAmpClient = .shared) {
        self.ampClient = ampClient
    }

    public func verifyUserToken(_ userToken: String, clientToken: String) async throws -> SessionVerificationResult {
        do {
            let res = try await ampClient.verifyUserToken(userToken: userToken, devToken: clientToken)
            return SessionVerificationResult(
                isValid: res.isValid,
                storefront: res.storefront,
                accountName: res.accountName,
                serverAccountID: nil,
                subscriptionState: res.isValid ? .active : .unknown
            )
        } catch let err as AppleMusicSessionError {
            switch err {
            case .networkUnavailable:
                throw CoreError.offline
            case .developerTokenMissing:
                throw CoreError.clientCredentialInvalid
            case .tokenVerificationFailed(let code, let msg):
                if code == 401 { throw CoreError.userCredentialInvalid }
                if code == 403 { throw CoreError.forbidden(msg) }
                throw CoreError.server(statusCode: code, message: msg)
            default:
                throw CoreError.transport(statusCode: nil, message: err.localizedDescription)
            }
        } catch let err as URLError {
            if err.code == .notConnectedToInternet { throw CoreError.offline }
            if err.code == .timedOut { throw CoreError.timeout }
            throw CoreError.transport(statusCode: nil, message: err.localizedDescription)
        }
    }

    public func refreshClientCredential() async throws -> CredentialRecord {
        let token = try await ampClient.ensureDeveloperToken()
        return CredentialRecord(kind: .client, value: token, updatedAt: Date())
    }
}

// MARK: - CoreV2SessionAdapter

/// Bridges `SessionCoordinator` (Core V2) to `AppleMusicSessionAdapter` so `AppleMusicProvider`
/// always observes the authoritative `sessionState` and `generation` without using legacy singletons.
public final class CoreV2SessionAdapter: AppleMusicSessionAdapter, Sendable {
    private let sessionCoordinator: SessionCoordinator

    public init(sessionCoordinator: SessionCoordinator) {
        self.sessionCoordinator = sessionCoordinator
    }

    public var snapshot: AppleMusicSessionSnapshot {
        get async {
            let snap = await sessionCoordinator.snapshot
            return AppleMusicSessionSnapshot(
                generation: Int(snap.context?.generation ?? 0),
                webSessionState: await webSessionState,
                apiAuthorizationState: .developerCredentialsMissing(reason: "Web 官方会话模式"),
                account: snap.account,
                hasUserToken: snap.userCredentialState == .available,
                hasDeveloperToken: snap.clientCredentialState == .available,
                storefront: snap.context?.storefront
            )
        }
    }

    public var webSessionState: AppleMusicWebSessionState {
        get async {
            let snap = await sessionCoordinator.snapshot
            switch snap.sessionState {
            case .authenticated:
                let acc = snap.account ?? MusicAccount(
                    id: snap.context?.accountID ?? "apple_music",
                    providerID: "apple_music",
                    displayName: "Apple Music 用户",
                    isAuthenticated: true
                )
                return .loggedIn(account: acc, storefront: snap.context?.storefront)
            case .authenticating:
                return .loggingIn(progressMessage: "正在登录")
            case .restoring, .verifying:
                return .verifying(tokenSnippet: nil)
            case .offlineUnverified:
                return .unknown
            case .expired(let reason):
                return .expired(reason: reason)
            case .failed(let msg):
                return .error(.tokenVerificationFailed(statusCode: 0, message: msg))
            case .signedOut, .invalidating:
                return .loggedOut
            }
        }
    }

    public var apiAuthorizationState: AppleMusicAPIAuthorizationState {
        get async { .developerCredentialsMissing(reason: "Web 官方会话模式") }
    }

    public var currentAccount: MusicAccount? {
        get async { await sessionCoordinator.snapshot.account }
    }

    public var currentGeneration: Int {
        get async { Int(await sessionCoordinator.snapshot.context?.generation ?? 0) }
    }

    public func authenticateWeb() async throws {}
    public func signOut() async throws {
        await sessionCoordinator.invalidate(reason: .userSignOut)
    }
    public func switchAccount() async throws {
        await sessionCoordinator.invalidate(reason: .accountSwitch)
    }
    public func resetSession() async throws {
        await sessionCoordinator.invalidate(reason: .userSignOut)
    }
    public func reauthenticate() async throws {
        await sessionCoordinator.restoreFromStorage()
    }

    public func beginTrackTransition() async {}
    public func playTrack(id: String, type: String) async throws -> Bool { false }
    public func play() async throws -> Bool { false }
    public func pause() async throws -> Bool { false }
    public func playPause() async throws -> Bool { false }
    public func stop() async throws {}
    public func seek(to seconds: Double) async throws {}
    public func skipToNext() async throws {}
    public func skipToPrevious() async throws {}
    public func setVolume(_ volume: Float) async throws {}
    public func currentPlaybackPosition() async -> (position: Double, duration: Double, isPlaying: Bool) { (0, 0, false) }
    public func currentPlaybackSnapshot() async -> (position: Double, duration: Double, isPlaying: Bool, isBuffering: Bool, hasStartedAudio: Bool, volume: Float) {
        (0, 0, false, false, false, 1.0)
    }
}

// MARK: - WebLoginController

/// `@MainActor` WebAuthorization component (`P3-01`) for interactive Apple ID login.
/// Enforces `OriginValidator` boundaries, monitors cookies/storage for `media-user-token`,
/// and completes the active `SessionCoordinator` login attempt without mutating session state directly.
@MainActor
public final class WebLoginController: NSObject {
    private let dataStore: WKWebsiteDataStore
    private let sessionCoordinator: SessionCoordinator
    private var activeAttemptID: UUID?
    private var loginWebView: WKWebView?
    private var cookieObserverInstalled = false
    private let handlerName = "airmuseAuthBridge"

    public var onUnsupportedFlow: ((String) -> Void)?

    public init(dataStore: WKWebsiteDataStore = .default(), sessionCoordinator: SessionCoordinator) {
        self.dataStore = dataStore
        self.sessionCoordinator = sessionCoordinator
        super.init()
    }

    public func startLogin() async -> WKWebView {
        let attemptID = await sessionCoordinator.beginLoginAttempt()
        self.activeAttemptID = attemptID

        if !cookieObserverInstalled {
            dataStore.httpCookieStore.add(self)
            cookieObserverInstalled = true
        }

        let config = WKWebViewConfiguration()
        config.websiteDataStore = dataStore
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        config.userContentController.add(self, name: handlerName)

        let probeJS = """
        (function() {
            function check() {
                try {
                    var tok = localStorage.getItem('media-user-token') || localStorage.getItem('music.userToken');
                    if (tok && window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers['\(handlerName)']) {
                        window.webkit.messageHandlers['\(handlerName)'].postMessage({ event: 'token', value: tok });
                    }
                } catch(e) {}
            }
            setInterval(check, 800);
        })();
        """
        config.userContentController.addUserScript(WKUserScript(source: probeJS, injectionTime: .atDocumentEnd, forMainFrameOnly: false))

        let wv = WKWebView(frame: NSRect(x: 0, y: 0, width: 500, height: 460), configuration: config)
        wv.navigationDelegate = self
        self.loginWebView = wv

        if let url = URL(string: "https://music.apple.com/cn/login") {
            wv.load(URLRequest(url: url))
        }
        return wv
    }

    public func cancelLogin() {
        let attempt = activeAttemptID
        activeAttemptID = nil
        tearDownWebView()
        if let attempt {
            Task { await sessionCoordinator.cancelLoginAttempt(attempt) }
        }
    }

    public func clearAllWebData() async {
        tearDownWebView()
        let types = WKWebsiteDataStore.allWebsiteDataTypes()
        let records = await dataStore.dataRecords(ofTypes: types)
        await dataStore.removeData(ofTypes: types, for: records)
    }

    private func tearDownWebView() {
        if let wv = loginWebView {
            wv.stopLoading()
            wv.configuration.userContentController.removeScriptMessageHandler(forName: handlerName)
            wv.navigationDelegate = nil
            wv.removeFromSuperview()
        }
        loginWebView = nil
    }

    private func handleCapturedToken(_ token: String) {
        guard let attempt = activeAttemptID, !token.isEmpty else { return }
        activeAttemptID = nil
        Task {
            do {
                _ = try await sessionCoordinator.completeLoginAttempt(attempt, userToken: token)
                await MainActor.run { self.tearDownWebView() }
            } catch {
                AppLogger.shared.log(category: .auth, level: .warn, message: "登录令牌校验未通过: \(error.localizedDescription)")
            }
        }
    }
}

extension WebLoginController: WKHTTPCookieStoreObserver {
    public func cookiesDidChange(in cookieStore: WKHTTPCookieStore) {
        guard activeAttemptID != nil else { return }
        cookieStore.getAllCookies { [weak self] cookies in
            for cookie in cookies {
                if cookie.name == "media-user-token",
                   OriginValidator.isAllowedCookieDomain(cookie.domain),
                   !cookie.value.isEmpty {
                    Task { @MainActor [weak self] in
                        self?.handleCapturedToken(cookie.value)
                    }
                    break
                }
            }
        }
    }
}

extension WebLoginController: WKScriptMessageHandler {
    public func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == handlerName, message.webView === loginWebView else { return }
        let origin = message.frameInfo.securityOrigin
        guard OriginValidator.isAllowedScriptOrigin(protocol: origin.protocol, host: origin.host, isMainFrame: message.frameInfo.isMainFrame, allowSubframe: true) else {
            return
        }
        if let dict = message.body as? [String: Any],
           dict["event"] as? String == "token",
           let value = dict["value"] as? String {
            handleCapturedToken(value)
        }
    }
}

extension WebLoginController: WKNavigationDelegate {
    public func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
        guard webView === loginWebView else { return .cancel }
        if OriginValidator.isAllowedNavigationURL(navigationAction.request.url) {
            return .allow
        }
        return .cancel
    }
}
