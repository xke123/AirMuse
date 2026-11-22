// Sources/Providers/AppleMusic/Session/AppleMusicSessionManager.swift
// AirMuse macOS – Dedicated Apple Music Session & Lifecycle Manager
// Swift 6 strict concurrency – @MainActor throughout WebKit operations

import Foundation
import WebKit
import Domain
import Infrastructure

/// Manages the official Apple Music Web authentication lifecycle, cookies, session persistence,
/// expiration detection, and account switching without requiring paid Apple Developer Program credentials.
@MainActor
public final class AppleMusicSessionManager: NSObject {

    public static let shared = AppleMusicSessionManager()

    // MARK: - State

    public private(set) var webSessionState: AppleMusicWebSessionState = .loggedOut {
        didSet {
            guard webSessionState != oldValue else { return }
            AppLogger.shared.log(
                category: .auth,
                level: .info,
                message: "Apple Music Web 会话状态流转: \(oldValue.displayName) -> \(webSessionState.displayName)"
            )
            onStateChanged?(webSessionState)
        }
    }

    public private(set) var apiAuthorizationState: AppleMusicAPIAuthorizationState = .developerCredentialsMissing(reason: "未配置 Apple Developer Program 开发者私钥") {
        didSet {
            guard apiAuthorizationState != oldValue else { return }
            onAPIAuthorizationChanged?(apiAuthorizationState)
        }
    }

    public private(set) var generation: Int = 0
    public private(set) var currentAccount: MusicAccount?
    public private(set) var currentStorefront: String?
    public private(set) var capturedDeveloperToken: String?
    public private(set) var currentUserToken: String?

    // MARK: - Callbacks

    public var onStateChanged: ((AppleMusicWebSessionState) -> Void)?
    public var onAPIAuthorizationChanged: ((AppleMusicAPIAuthorizationState) -> Void)?

    // MARK: - WebKit & Infrastructure

    public let dataStore: WKWebsiteDataStore
    public let webPlayer: AppleMusicWebPlayer
    private var loginWebView: WKWebView?
    private let keychain: KeychainStore
    private let ampClient: AppleMusicAmpClient

    private var cookieObserverAttached: Bool = false
    private var isVerifyingToken: Bool = false
    private var inFlightVerifyTask: Task<Void, Never>?

    private static let userDefaultsTokenKey = "com.airmuse.apple_music.user_token"
    private static let userDefaultsStorefrontKey = "com.airmuse.apple_music.storefront"
    private static let keychainTokenKey = "media_user_token"
    private static let keychainStorefrontKey = "storefront_id"
    private static let officialAppleMusicURL = URL(string: "https://music.apple.com")!
    private static let officialLoginURL = URL(string: "https://music.apple.com/login")!

    // MARK: - Init

    public init(
        ampClient: AppleMusicAmpClient = .shared,
        keychain: KeychainStore = KeychainStore(service: "com.airmuse.apple_music"),
        dataStore: WKWebsiteDataStore = .default()
    ) {
        self.ampClient = ampClient
        self.keychain = keychain
        self.dataStore = dataStore
        self.webPlayer = AppleMusicWebPlayer(dataStore: dataStore)
        super.init()

        setupCookieObserver()
        wireClientExpirationListener()
    }

    public var currentSnapshot: AppleMusicSessionSnapshot {
        AppleMusicSessionSnapshot(
            generation: generation,
            webSessionState: webSessionState,
            apiAuthorizationState: apiAuthorizationState,
            account: currentAccount,
            hasUserToken: currentUserToken != nil,
            hasDeveloperToken: capturedDeveloperToken != nil,
            storefront: currentStorefront
        )
    }

    // MARK: - Session Bootstrap / Restore

    /// Restores previously saved session from Keychain and verifies it against Apple's live endpoint.
    public func restoreSessionFromStorage() async {
        // Scrub any legacy plaintext token from UserDefaults and keep token strictly in Keychain
        var savedToken = try? keychain.load(key: Self.keychainTokenKey)
        let savedStorefront = (try? keychain.load(key: Self.keychainStorefrontKey))
            ?? UserDefaults.standard.string(forKey: Self.userDefaultsStorefrontKey)

        if (savedToken == nil || savedToken!.isEmpty),
           let legacyToken = UserDefaults.standard.string(forKey: Self.userDefaultsTokenKey),
           !legacyToken.isEmpty {
            try? keychain.save(legacyToken, forKey: Self.keychainTokenKey)
            savedToken = legacyToken
        }
        UserDefaults.standard.removeObject(forKey: Self.userDefaultsTokenKey)

        guard let token = savedToken, !token.trimmingCharacters(in: .whitespaces).isEmpty else {
            self.webSessionState = .loggedOut
            return
        }
        if let sf = savedStorefront, !sf.isEmpty {
            await ampClient.setStorefront(sf)
        }

        self.currentUserToken = token
        self.currentStorefront = savedStorefront
        self.webSessionState = .verifying(tokenSnippet: String(token.prefix(8)))
        await syncTokenToCookieStore(token: token)

        AppLogger.shared.log(
            category: .auth,
            level: .info,
            message: "从安全存储中发现已存 Apple Music 令牌，正在向 Apple 官方验证有效性..."
        )

        // If developer token is already known, verify immediately; otherwise await page probe
        if let devToken = capturedDeveloperToken {
            await verifyAndApplyToken(token, devToken: devToken, generationSnapshot: generation)
        } else {
            // First try silent direct token resolution via AmpClient
            if let clientDevToken = try? await ampClient.ensureDeveloperToken() {
                self.capturedDeveloperToken = clientDevToken
                await verifyAndApplyToken(token, devToken: clientDevToken, generationSnapshot: generation)
            } else {
                // Fallback to WKWebView silent probe on official page
                probeDeveloperTokenFromOfficialPage { [weak self] capturedDevToken in
                    guard let self else { return }
                    Task { @MainActor in
                        if let capturedDevToken {
                            self.capturedDeveloperToken = capturedDevToken
                            await self.ampClient.setDeveloperToken(capturedDevToken)
                            await self.verifyAndApplyToken(token, devToken: capturedDevToken, generationSnapshot: self.generation)
                        } else {
                            // Inconclusive: cannot verify without developer token
                            self.webSessionState = .unknown
                        }
                    }
                }
            }
        }
    }

    // MARK: - Web Login Flow

    /// Creates or returns the official Apple Music WKWebView for user sign-in.
    /// Strictly uses Apple's official web page; credentials are never intercepted or captured by AirMuse.
    public func createLoginWebView() -> WKWebView {
        if let existing = loginWebView {
            return existing
        }

        let config = WKWebViewConfiguration()
        config.websiteDataStore = self.dataStore

        // Script to observe public window.MusicKit developerToken on official site
        let scriptSource = """
        (function() {
            function checkDevToken() {
                try {
                    var mk = window.MusicKit && window.MusicKit.getInstance ? window.MusicKit.getInstance() : null;
                    if (mk && mk.developerToken) {
                        window.webkit.messageHandlers.appleMusicDevToken.postMessage(mk.developerToken);
                        return true;
                    }
                    var match = document.documentElement.innerHTML.match(/eyJ0eXAiOiJKV1Qi[a-zA-Z0-9_-]+\\.[a-zA-Z0-9_-]+\\.[a-zA-Z0-9_-]+/);
                    if (match && match[0]) {
                        window.webkit.messageHandlers.appleMusicDevToken.postMessage(match[0]);
                        return true;
                    }
                } catch(e) {}
                return false;
            }
            if (!checkDevToken()) {
                var timer = setInterval(function() {
                    if (checkDevToken()) clearInterval(timer);
                }, 800);
            }
        })();
        """

        let script = WKUserScript(source: scriptSource, injectionTime: .atDocumentEnd, forMainFrameOnly: false)
        config.userContentController.addUserScript(script)
        config.userContentController.add(self, name: "appleMusicDevToken")

        let wv = WKWebView(frame: .zero, configuration: config)
        wv.navigationDelegate = self
        self.loginWebView = wv
        return wv
    }

    /// Initiates user login by loading official Apple Music sign-in URL.
    public func startLogin() {
        self.webSessionState = .loggingIn(progressMessage: "正在连接 Apple 官方登录服务…")
        let wv = createLoginWebView()
        wv.load(URLRequest(url: Self.officialLoginURL))
    }

    /// Re-authenticates if session has expired or failed.
    public func reauthenticate() {
        startLogin()
    }

    // MARK: - Sign Out & Reset

    /// Performs clean logout:
    /// 1. Increments session generation (canceling in-flight requests from the old session).
    /// 2. Clears tokens and in-memory caches.
    /// 3. Deletes Apple Music token from Keychain.
    /// 4. Removes Apple Music cookies & website data without touching other platforms.
    /// 5. Transitions state to `.loggedOut`.
    public func signOut() async {
        generation += 1
        await ampClient.setActiveGeneration(generation)
        inFlightVerifyTask?.cancel()

        currentUserToken = nil
        currentAccount = nil
        currentStorefront = nil

        UserDefaults.standard.removeObject(forKey: Self.userDefaultsTokenKey)
        UserDefaults.standard.removeObject(forKey: Self.userDefaultsStorefrontKey)
        try? keychain.delete(key: Self.keychainTokenKey)
        try? keychain.delete(key: Self.keychainStorefrontKey)

        await ampClient.setUserToken(nil)

        // Reset web player
        webPlayer.reset()

        // Isolated data store purge: only delete cookies for apple.com / music.apple.com
        await clearAppleWebsiteDataOnly()

        self.webSessionState = .loggedOut
        AppLogger.shared.log(category: .auth, level: .info, message: "Apple Music 会话已完全登出并清除本地凭据 (世代: \(generation))")
    }

    /// Switches account by cleanly signing out the old session and opening the login flow.
    public func switchAccount() async {
        await signOut()
        startLogin()
    }

    /// Full local session reset.
    public func resetSession() async {
        await signOut()
        capturedDeveloperToken = nil
        await ampClient.setDeveloperToken(nil)
        loginWebView?.stopLoading()
        loginWebView = nil
        self.webSessionState = .loggedOut
    }

    // MARK: - Token Verification & Application

    /// Verifies candidate token with Apple server.
    /// Only confirms login state based on verified server responses.
    public func verifyAndApplyToken(_ token: String, devToken: String, generationSnapshot: Int) async {
        guard generation == generationSnapshot else {
            AppLogger.shared.log(category: .auth, level: .warn, message: "校验请求已作废 (世代不匹配: \(generationSnapshot) vs \(self.generation))")
            return
        }
        guard !isVerifyingToken else { return }
        isVerifyingToken = true
        defer { isVerifyingToken = false }

        self.webSessionState = .verifying(tokenSnippet: String(token.prefix(8)))

        do {
            let (isValid, storefront, accountName) = try await ampClient.verifyUserToken(userToken: token, devToken: devToken)

            // Cross-session check: if session generation changed while verifying, discard results
            guard generation == generationSnapshot else {
                AppLogger.shared.log(category: .auth, level: .warn, message: "校验结果已作废 (世代不匹配: \(generationSnapshot) vs \(self.generation))")
                return
            }

            if isValid {
                self.currentUserToken = token
                self.currentStorefront = storefront

                // Persist token strictly in Keychain (never plaintext UserDefaults)
                UserDefaults.standard.removeObject(forKey: Self.userDefaultsTokenKey)
                if let sf = storefront {
                    UserDefaults.standard.set(sf, forKey: Self.userDefaultsStorefrontKey)
                }
                try? keychain.save(token, forKey: Self.keychainTokenKey)
                if let sf = storefront {
                    try? keychain.save(sf, forKey: Self.keychainStorefrontKey)
                }

                // Account Name rule: MUST come from trusted server data or truthful description.
                // NEVER invent a fake dummy username like '小可' or 'Tim Cook'!
                let resolvedDisplayName: String = {
                    if let name = accountName, !name.trimmingCharacters(in: .whitespaces).isEmpty {
                        return name
                    }
                    if let sf = storefront {
                        return "Apple Music 会员 (\(sf.uppercased()))"
                    }
                    return "Apple Music 用户"
                }()

                let account = MusicAccount(
                    id: UUID().uuidString,
                    providerID: "apple_music",
                    displayName: resolvedDisplayName,
                    email: nil,
                    avatarURL: nil,
                    isAuthenticated: true,
                    subscriptionTier: .individual
                )
                self.currentAccount = account

                await ampClient.setUserToken(token)
                await ampClient.setDeveloperToken(devToken)
                await ampClient.setStorefront(storefront)
                await syncTokenToCookieStore(token: token)
                self.webPlayer.setUserToken(token)

                self.webSessionState = .loggedIn(account: account, storefront: storefront)
                self.webPlayer.preload()
                AppLogger.shared.log(
                    category: .auth,
                    level: .info,
                    message: "Apple Music 官方会话校验成功",
                    details: "用户: \(resolvedDisplayName), Storefront: \(storefront ?? "未知")"
                )
            } else {
                handleTokenExpiration(reason: "服务端拒绝了该用户令牌")
            }
        } catch let err as AppleMusicSessionError {
            guard generation == generationSnapshot else { return }
            switch err {
            case .networkUnavailable:
                self.webSessionState = .error(.networkUnavailable)
            case .tokenVerificationFailed(let code, let msg):
                if code == 401 || code == 403 {
                    handleTokenExpiration(reason: "Apple 服务端返回鉴权失效 (HTTP \(code)): \(msg)")
                } else {
                    self.webSessionState = .error(err)
                }
            default:
                self.webSessionState = .error(err)
            }
        } catch {
            guard generation == generationSnapshot else { return }
            self.webSessionState = .error(.webViewFailed(error.localizedDescription))
        }
    }

    private func handleTokenExpiration(reason: String) {
        currentUserToken = nil
        currentAccount = nil
        UserDefaults.standard.removeObject(forKey: Self.userDefaultsTokenKey)
        UserDefaults.standard.removeObject(forKey: Self.userDefaultsStorefrontKey)
        try? keychain.delete(key: Self.keychainTokenKey)
        try? keychain.delete(key: Self.keychainStorefrontKey)
        Task {
            await ampClient.setUserToken(nil)
        }
        self.webSessionState = .expired(reason: reason)
    }

    // MARK: - Isolated Data Store Cleanup

    /// Synchronizes the user token into WebKit HTTPCookieStore so that official music.apple.com web session recognizes subscription status
    private func syncTokenToCookieStore(token: String) async {
        let cookieStore = dataStore.httpCookieStore
        let existing = await cookieStore.allCookies()
        var hasExactMatch = false
        for c in existing where c.name == "media-user-token" && c.domain.contains("apple.com") {
            if c.value == token {
                hasExactMatch = true
            } else if c.value.contains("%") {
                await cookieStore.deleteCookie(c)
            }
        }
        guard !hasExactMatch else { return }
        guard let cookie = HTTPCookie(properties: [
            .domain: ".music.apple.com",
            .path: "/",
            .name: "media-user-token",
            .value: token,
            .secure: "TRUE",
            .expires: Date().addingTimeInterval(31536000)
        ]) else { return }
        await cookieStore.setCookie(cookie)
        AppLogger.shared.log(category: .auth, level: .info, message: "已将用户 media-user-token 同步至 WebKit Cookie 存储")
    }

    /// Cleans ONLY Apple Music domain cookies and website data, leaving Spotify and QQ Music untouched.
    private func clearAppleWebsiteDataOnly() async {
        let cookieStore = dataStore.httpCookieStore
        let cookies = await cookieStore.allCookies()
        for c in cookies {
            if c.domain.localizedCaseInsensitiveContains("apple.com") {
                await cookieStore.deleteCookie(c)
            }
        }

        let records = await dataStore.dataRecords(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes())
        let appleRecords = records.filter { $0.displayName.localizedCaseInsensitiveContains("apple") }
        if !appleRecords.isEmpty {
            await dataStore.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), for: appleRecords)
        }
    }

    // MARK: - Cookie Store Observer

    private func setupCookieObserver() {
        guard !cookieObserverAttached else { return }
        dataStore.httpCookieStore.add(self)
        cookieObserverAttached = true
    }

    private func inspectCookiesForUserToken() {
        guard !isVerifyingToken else { return }
        dataStore.httpCookieStore.getAllCookies { [weak self] cookies in
            guard let self else { return }
            Task { @MainActor in
                guard !self.isVerifyingToken else { return }
                for c in cookies {
                    if c.name == "media-user-token" && c.domain.contains("apple.com") {
                        let token = c.value
                        // Ignore percent-encoded duplicates written by JS or already-active tokens
                        if token.isEmpty || token.contains("%") || token == self.currentUserToken {
                            continue
                        }
                        AppLogger.shared.log(category: .auth, level: .info, message: "捕获到新的 media-user-token Cookie，准备验证")
                        if let devToken = self.capturedDeveloperToken {
                            await self.verifyAndApplyToken(token, devToken: devToken, generationSnapshot: self.generation)
                        } else {
                            self.currentUserToken = token
                        }
                        break
                    }
                }
            }
        }
    }

    // MARK: - Silent Developer Token Probe

    private func probeDeveloperTokenFromOfficialPage(completion: @escaping (String?) -> Void) {
        let wv = createLoginWebView()
        wv.load(URLRequest(url: Self.officialAppleMusicURL))
        DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) { [weak self] in
            completion(self?.capturedDeveloperToken)
        }
    }

    private func wireClientExpirationListener() {
        Task { [weak self] in
            guard let self else { return }
            await self.ampClient.setOnSessionExpired { [weak self] in
                Task { @MainActor [weak self] in
                    self?.handleTokenExpiration(reason: "Amp-API 收到 401/403 鉴权失效响应")
                }
            }
        }
    }
}

// MARK: - WKHTTPCookieStoreObserver

extension AppleMusicSessionManager: WKHTTPCookieStoreObserver {
    public func cookiesDidChange(in cookieStore: WKHTTPCookieStore) {
        inspectCookiesForUserToken()
    }
}

// MARK: - WKScriptMessageHandler

extension AppleMusicSessionManager: WKScriptMessageHandler {
    public func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        if message.name == "appleMusicDevToken", let token = message.body as? String, !token.isEmpty {
            if self.capturedDeveloperToken != token {
                self.capturedDeveloperToken = token
                AppLogger.shared.log(category: .auth, level: .info, message: "成功从 Apple 官方页面捕获 Developer Token (\(token.count) 字符)")
                Task {
                    await ampClient.setDeveloperToken(token)
                    if let userToken = self.currentUserToken, !self.webSessionState.isLoggedIn {
                        await self.verifyAndApplyToken(userToken, devToken: token, generationSnapshot: self.generation)
                    }
                }
            }
        }
    }
}

// MARK: - WKNavigationDelegate

extension AppleMusicSessionManager: WKNavigationDelegate {

    public func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
        guard let url = navigationAction.request.url else {
            return .allow
        }

        // WebKit unsupported authentication flow detection (Passkeys / Apple ID special schemes)
        if url.scheme == "appleid" || url.scheme == "itms" {
            AppLogger.shared.log(category: .auth, level: .warn, message: "拦截到 WebKit 不支持的专有 scheme: \(url.absoluteString)")
            self.webSessionState = .error(.unsupportedAuthenticationFlow("检测到 \(url.scheme ?? ""):// 专有协议。当前嵌入式 WebKit 无法调起系统凭据管理器，请在登录页面使用常规密码或双重验证码。"))
            return .cancel
        }

        return .allow
    }

    public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        inspectCookiesForUserToken()
    }

    public func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        let nsErr = error as NSError
        if nsErr.domain == NSURLErrorDomain && nsErr.code == NSURLErrorNotConnectedToInternet {
            self.webSessionState = .error(.networkUnavailable)
        } else if nsErr.code != NSURLErrorCancelled {
            self.webSessionState = .error(.webViewFailed(error.localizedDescription))
        }
    }

    public func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        let nsErr = error as NSError
        if nsErr.domain == NSURLErrorDomain && nsErr.code == NSURLErrorNotConnectedToInternet {
            self.webSessionState = .error(.networkUnavailable)
        } else if nsErr.code != NSURLErrorCancelled {
            self.webSessionState = .error(.webViewFailed(error.localizedDescription))
        }
    }
}
