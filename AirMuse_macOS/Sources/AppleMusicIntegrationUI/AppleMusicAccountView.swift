// Sources/UI/Auth/AppleMusicAccountView.swift
// AirMuse macOS – Native Liquid Glass Apple Music Account & Session View
// Swift 6 strict concurrency – @MainActor

import AppKit
import WebKit
import Domain
import DesignSystem
import Providers
import Infrastructure

/// Native Liquid Glass view showing real-time Apple Music session state,
/// separation of Web login vs Developer API authorization, and account controls.
@MainActor
open class AppleMusicAccountView: GlassSurface {

    public var onLoginClicked: (() -> Void)?
    public var onSignOutClicked: (() -> Void)?
    public var onSwitchAccountClicked: (() -> Void)?
    public var onReverifyClicked: (() -> Void)?
    public var onResetSessionClicked: (() -> Void)?
    public var onCloseClicked: (() -> Void)?
    public var onCancelWebLogin: (() -> Void)?

    // MARK: - Subviews: Status & Cards

    private let headerIcon = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "Apple Music 会话与认证")
    private let subtitleLabel = NSTextField(labelWithString: "基于官方 Web 会话的独立管理引擎 · 严格隔离与安全鉴权")
    private let closeButton = GlassButton(image: NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close"), size: CGSize(width: 14, height: 14))

    // Card 1: Web Session Card
    private let webCard = GlassPanel()
    private let webCardTitle = NSTextField(labelWithString: "官方网页会话 (Web Session)")
    private let webStatusBadge = NSTextField(labelWithString: "未登录")
    private let accountNameTitle = NSTextField(labelWithString: "账户身份:")
    private let accountNameLabel = NSTextField(labelWithString: "尚未登录")
    private let storefrontTitle = NSTextField(labelWithString: "服务区域:")
    private let storefrontLabel = NSTextField(labelWithString: "未知 (Unknown)")

    // Card 2: API Authorization Card
    private let apiCard = GlassPanel()
    private let apiCardTitle = NSTextField(labelWithString: "MusicKit API 授权状态")
    private let apiStatusBadge = NSTextField(labelWithString: "官方 Web 会话模式")
    private let apiDescLabel = NSTextField(wrappingLabelWithString: "当前运行在官方 Web 会话模式下。\n• 全球公共曲库检索: 完全可用\n• 广播电台与精选专区: 完全可用\n• 完整曲库与自建歌单高保真播放: 登录官方账号即可畅享")

    // Notice Box
    private let noticeBox = NSView()
    private let noticeLabel = NSTextField(wrappingLabelWithString: "🔒 官方安全承诺: 登录过程直接在 Apple 官方页面执行，AirMuse 不采集、不中继、不存储您的密码与双重验证码。退出登录时将立即清除所有本地凭据与会话 Cookie。")

    // Buttons Container
    private let buttonStack = NSStackView()
    private let loginButton = NSButton()
    private let signOutButton = NSButton()
    private let switchAccountButton = NSButton()
    private let reverifyButton = NSButton()
    private let resetButton = NSButton()

    // MARK: - Subviews: Embedded Web Login Sheet
    private let webLoginContainer = NSView()
    private let webLoginTopBar = NSView()
    private let webLoginTitle = NSTextField(labelWithString: "Apple 官方安全登录通道")
    private let webLoginCancelButton = NSButton()
    private let webWarningLabel = NSTextField(wrappingLabelWithString: "")
    private var embeddedWebView: WKWebView?

    private var currentWebState: AppleMusicWebSessionState = .loggedOut
    private var isWebLoginPresented: Bool = false

    // MARK: - Init

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupUI()
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupUI()
    }

    // MARK: - Setup UI

    private func setupUI() {
        cornerRadius = DesignTokens.CornerRadius.window

        // Header
        let config = NSImage.SymbolConfiguration(pointSize: 18, weight: .semibold)
        headerIcon.image = NSImage(systemSymbolName: "apple.logo", accessibilityDescription: "Apple")?.withSymbolConfiguration(config)
        headerIcon.contentTintColor = NSColor(white: 0.95, alpha: 1.0)
        addSubview(headerIcon)

        titleLabel.font = NSFont.systemFont(ofSize: 13, weight: .bold)
        titleLabel.textColor = NSColor(white: 0.98, alpha: 1.0)
        addSubview(titleLabel)

        subtitleLabel.font = NSFont.systemFont(ofSize: 9.5, weight: .regular)
        subtitleLabel.textColor = NSColor(white: 0.55, alpha: 1.0)
        addSubview(subtitleLabel)

        closeButton.onClick = { [weak self] in self?.onCloseClicked?() }
        addSubview(closeButton)

        // Web Card
        setupWebCard()

        // API Card
        setupAPICard()

        // Notice Box
        setupNoticeBox()

        // Action Buttons
        setupButtons()

        // Web Login Container (Initially Hidden)
        setupWebLoginContainer()
    }

    private func setupWebCard() {
        addSubview(webCard)
        let c = webCard.contentView

        webCardTitle.font = NSFont.systemFont(ofSize: 11, weight: .semibold)
        webCardTitle.textColor = NSColor(white: 0.92, alpha: 1.0)
        c.addSubview(webCardTitle)

        configureBadge(webStatusBadge, text: "未登录", color: .systemGray)
        c.addSubview(webStatusBadge)

        accountNameTitle.font = NSFont.systemFont(ofSize: 10, weight: .medium)
        accountNameTitle.textColor = NSColor(white: 0.60, alpha: 1.0)
        c.addSubview(accountNameTitle)

        accountNameLabel.font = NSFont.systemFont(ofSize: 10, weight: .semibold)
        accountNameLabel.textColor = NSColor(white: 0.95, alpha: 1.0)
        c.addSubview(accountNameLabel)

        storefrontTitle.font = NSFont.systemFont(ofSize: 10, weight: .medium)
        storefrontTitle.textColor = NSColor(white: 0.60, alpha: 1.0)
        c.addSubview(storefrontTitle)

        storefrontLabel.font = NSFont.systemFont(ofSize: 10, weight: .regular)
        storefrontLabel.textColor = NSColor(white: 0.85, alpha: 1.0)
        c.addSubview(storefrontLabel)
    }

    private func setupAPICard() {
        addSubview(apiCard)
        let c = apiCard.contentView

        apiCardTitle.font = NSFont.systemFont(ofSize: 11, weight: .semibold)
        apiCardTitle.textColor = NSColor(white: 0.92, alpha: 1.0)
        c.addSubview(apiCardTitle)

        configureBadge(apiStatusBadge, text: "Web 官方会话模式", color: .systemBlue)
        c.addSubview(apiStatusBadge)

        apiDescLabel.font = NSFont.systemFont(ofSize: 9.5, weight: .regular)
        apiDescLabel.textColor = NSColor(white: 0.65, alpha: 1.0)
        c.addSubview(apiDescLabel)
    }

    private func setupNoticeBox() {
        noticeBox.wantsLayer = true
        noticeBox.layer?.cornerRadius = 6
        noticeBox.layer?.backgroundColor = NSColor(white: 1.0, alpha: 0.04).cgColor
        noticeBox.layer?.borderWidth = 0.5
        noticeBox.layer?.borderColor = NSColor(white: 1.0, alpha: 0.08).cgColor
        addSubview(noticeBox)

        noticeLabel.font = NSFont.systemFont(ofSize: 9.0, weight: .regular)
        noticeLabel.textColor = NSColor(white: 0.60, alpha: 1.0)
        noticeBox.addSubview(noticeLabel)
    }

    private func setupButtons() {
        buttonStack.orientation = .horizontal
        buttonStack.spacing = 8
        buttonStack.distribution = .fillEqually
        addSubview(buttonStack)

        // Login Button
        configureStyledButton(loginButton, title: "登录 Apple 官方网页", isPrimary: true, action: #selector(loginClicked))

        // Sign Out Button
        configureStyledButton(signOutButton, title: "退出登录", isPrimary: false, action: #selector(signOutClicked))

        // Switch Account Button
        configureStyledButton(switchAccountButton, title: "切换账号", isPrimary: false, action: #selector(switchAccountClicked))

        // Reverify Button
        configureStyledButton(reverifyButton, title: "刷新验证", isPrimary: false, action: #selector(reverifyClicked))

        // Reset Button
        configureStyledButton(resetButton, title: "重置会话", isPrimary: false, action: #selector(resetClicked))

        updateButtonVisibility()
    }

    private func setupWebLoginContainer() {
        webLoginContainer.wantsLayer = true
        webLoginContainer.layer?.cornerRadius = DesignTokens.CornerRadius.window
        webLoginContainer.layer?.masksToBounds = true
        webLoginContainer.layer?.backgroundColor = NSColor(calibratedRed: 0.12, green: 0.12, blue: 0.14, alpha: 0.98).cgColor
        webLoginContainer.layer?.borderWidth = 0.5
        webLoginContainer.layer?.borderColor = NSColor(white: 1.0, alpha: 0.15).cgColor
        webLoginContainer.isHidden = true
        addSubview(webLoginContainer)

        webLoginTopBar.wantsLayer = true
        webLoginTopBar.layer?.backgroundColor = NSColor(white: 0.15, alpha: 1.0).cgColor
        webLoginContainer.addSubview(webLoginTopBar)

        webLoginTitle.font = NSFont.systemFont(ofSize: 11, weight: .bold)
        webLoginTitle.textColor = NSColor.white
        webLoginTopBar.addSubview(webLoginTitle)

        webLoginCancelButton.title = "关闭并返回"
        webLoginCancelButton.bezelStyle = .roundRect
        webLoginCancelButton.font = NSFont.systemFont(ofSize: 10, weight: .medium)
        webLoginCancelButton.target = self
        webLoginCancelButton.action = #selector(cancelWebLoginClicked)
        webLoginTopBar.addSubview(webLoginCancelButton)

        webWarningLabel.font = NSFont.systemFont(ofSize: 9.5, weight: .regular)
        webWarningLabel.textColor = NSColor.systemYellow
        webWarningLabel.isHidden = true
        webLoginContainer.addSubview(webWarningLabel)
    }

    private func configureBadge(_ label: NSTextField, text: String, color: NSColor) {
        label.stringValue = " \(text) "
        label.font = NSFont.systemFont(ofSize: 9, weight: .semibold)
        label.textColor = color
        label.wantsLayer = true
        label.layer?.cornerRadius = 3
        label.layer?.masksToBounds = true
        label.layer?.backgroundColor = color.withAlphaComponent(0.15).cgColor
        label.layer?.borderWidth = 0.5
        label.layer?.borderColor = color.withAlphaComponent(0.35).cgColor
    }

    private func configureStyledButton(_ btn: NSButton, title: String, isPrimary: Bool, action: Selector) {
        btn.title = title
        btn.font = NSFont.systemFont(ofSize: 10.5, weight: isPrimary ? .semibold : .medium)
        btn.bezelStyle = .regularSquare
        btn.isBordered = false
        btn.wantsLayer = true
        btn.layer?.cornerRadius = 5
        btn.layer?.masksToBounds = true
        btn.target = self
        btn.action = action

        if isPrimary {
            btn.layer?.backgroundColor = NSColor(calibratedRed: 0.88, green: 0.88, blue: 0.90, alpha: 1.0).cgColor
            btn.contentTintColor = NSColor(calibratedRed: 0.12, green: 0.12, blue: 0.12, alpha: 1.0)
        } else {
            btn.layer?.backgroundColor = NSColor(white: 1.0, alpha: 0.10).cgColor
            btn.layer?.borderWidth = 0.5
            btn.layer?.borderColor = NSColor(white: 1.0, alpha: 0.15).cgColor
            btn.contentTintColor = NSColor(white: 0.90, alpha: 1.0)
        }
    }

    // MARK: - Layout

    open override func layout() {
        super.layout()
        let w = bounds.width
        let pad: CGFloat = 16

        // Top Header
        headerIcon.frame = NSRect(x: pad, y: pad, width: 22, height: 22)
        titleLabel.frame = NSRect(x: pad + 30, y: pad, width: w - 100, height: 18)
        subtitleLabel.frame = NSRect(x: pad + 30, y: pad + 20, width: w - 100, height: 14)
        closeButton.frame = NSRect(x: w - pad - 14, y: pad + 2, width: 14, height: 14)

        var curY: CGFloat = pad + 44

        // Web Card
        let cardH1: CGFloat = 90
        webCard.frame = NSRect(x: pad, y: curY, width: w - pad * 2, height: cardH1)
        layoutWebCard(w: w - pad * 2)
        curY += (cardH1 + 10)

        // API Card
        let cardH2: CGFloat = 110
        apiCard.frame = NSRect(x: pad, y: curY, width: w - pad * 2, height: cardH2)
        layoutAPICard(w: w - pad * 2)
        curY += (cardH2 + 10)

        // Notice Box
        let noticeH: CGFloat = 62
        noticeBox.frame = NSRect(x: pad, y: curY, width: w - pad * 2, height: noticeH)
        noticeLabel.frame = NSRect(x: 8, y: 6, width: w - pad * 2 - 16, height: noticeH - 12)
        curY += (noticeH + 14)

        // Button Stack
        let btnH: CGFloat = 30
        buttonStack.frame = NSRect(x: pad, y: curY, width: w - pad * 2, height: btnH)

        // Web Login Container (Full Overlay)
        webLoginContainer.frame = bounds.insetBy(dx: 4, dy: 4)
        webLoginTopBar.frame = NSRect(x: 0, y: 0, width: webLoginContainer.bounds.width, height: 34)
        webLoginTitle.frame = NSRect(x: 12, y: 8, width: 250, height: 18)
        webLoginCancelButton.frame = NSRect(x: webLoginContainer.bounds.width - 96, y: 4, width: 88, height: 26)

        let webY: CGFloat = 34
        var webH = webLoginContainer.bounds.height - webY
        if !webWarningLabel.isHidden {
            webWarningLabel.frame = NSRect(x: 10, y: webY + 4, width: webLoginContainer.bounds.width - 20, height: 32)
            webH -= 38
            embeddedWebView?.frame = NSRect(x: 0, y: webY + 38, width: webLoginContainer.bounds.width, height: webH)
        } else {
            embeddedWebView?.frame = NSRect(x: 0, y: webY, width: webLoginContainer.bounds.width, height: webH)
        }
    }

    private func layoutWebCard(w: CGFloat) {
        webCardTitle.frame = NSRect(x: 10, y: 10, width: 200, height: 16)
        webStatusBadge.frame = NSRect(x: w - 120, y: 10, width: 110, height: 18)

        accountNameTitle.frame = NSRect(x: 10, y: 36, width: 64, height: 16)
        accountNameLabel.frame = NSRect(x: 76, y: 36, width: w - 86, height: 16)

        storefrontTitle.frame = NSRect(x: 10, y: 60, width: 64, height: 16)
        storefrontLabel.frame = NSRect(x: 76, y: 60, width: w - 86, height: 16)
    }

    private func layoutAPICard(w: CGFloat) {
        apiCardTitle.frame = NSRect(x: 10, y: 10, width: 160, height: 16)
        apiStatusBadge.frame = NSRect(x: w - 180, y: 10, width: 170, height: 18)
        apiDescLabel.frame = NSRect(x: 10, y: 36, width: w - 20, height: 64)
    }

    // MARK: - Public State Updates

    public func updateState(
        webState: AppleMusicWebSessionState,
        apiState: AppleMusicAPIAuthorizationState,
        account: MusicAccount?,
        storefront: String?
    ) {
        self.currentWebState = webState

        // Update Web Card
        switch webState {
        case .loggedOut:
            configureBadge(webStatusBadge, text: "未登录", color: .systemGray)
            accountNameLabel.stringValue = "尚未登录"
            storefrontLabel.stringValue = "—"
        case .loggingIn(let progress):
            configureBadge(webStatusBadge, text: progress ?? "正在登录", color: .systemYellow)
            accountNameLabel.stringValue = "等待官方登录完成..."
            storefrontLabel.stringValue = "—"
        case .verifying:
            configureBadge(webStatusBadge, text: "验证中...", color: .systemTeal)
            accountNameLabel.stringValue = "正在核对 Apple 官方令牌..."
            storefrontLabel.stringValue = storefront ?? "—"
        case .loggedIn(let acc, let sf):
            configureBadge(webStatusBadge, text: "已验证登录", color: .systemGreen)
            accountNameLabel.stringValue = acc.displayName
            storefrontLabel.stringValue = (sf != nil) ? "\(sf!.uppercased()) (官方已连接)" : "已连接"
        case .expired(let reason):
            configureBadge(webStatusBadge, text: "会话失效", color: .systemRed)
            accountNameLabel.stringValue = "令牌已过期 (\(reason))"
            storefrontLabel.stringValue = "请重新登录"
        case .error(let err):
            configureBadge(webStatusBadge, text: "会话异常", color: .systemRed)
            accountNameLabel.stringValue = err.localizedDescription
            storefrontLabel.stringValue = "—"
        case .unknown:
            configureBadge(webStatusBadge, text: "未定状态", color: .systemOrange)
            accountNameLabel.stringValue = "待网络可用时自动重验"
            storefrontLabel.stringValue = "—"
        }

        // Update API Card
        switch apiState {
        case .authorized:
            configureBadge(apiStatusBadge, text: "MusicKit 已授权", color: .systemGreen)
        case .denied:
            configureBadge(apiStatusBadge, text: "MusicKit 已拒绝", color: .systemRed)
        case .restricted:
            configureBadge(apiStatusBadge, text: "MusicKit 受限", color: .systemRed)
        case .developerCredentialsMissing:
            configureBadge(apiStatusBadge, text: "Web 官方会话模式", color: .systemBlue)
        case .notDetermined:
            configureBadge(apiStatusBadge, text: "未检测", color: .systemGray)
        }

        updateButtonVisibility()
    }

    public func presentWebLogin(with webView: WKWebView, warning: String? = nil) {
        self.embeddedWebView = webView
        webView.removeFromSuperview()
        webLoginContainer.addSubview(webView)

        if let warning, !warning.isEmpty {
            webWarningLabel.stringValue = "⚠️ \(warning)"
            webWarningLabel.isHidden = false
        } else {
            webWarningLabel.isHidden = true
        }

        webLoginContainer.isHidden = false
        isWebLoginPresented = true
        needsLayout = true
    }

    public func dismissWebLogin() {
        embeddedWebView?.removeFromSuperview()
        embeddedWebView = nil
        webLoginContainer.isHidden = true
        isWebLoginPresented = false
    }

    private func updateButtonVisibility() {
        buttonStack.arrangedSubviews.forEach { buttonStack.removeArrangedSubview($0); $0.removeFromSuperview() }

        switch currentWebState {
        case .loggedOut:
            buttonStack.addArrangedSubview(loginButton)
            buttonStack.addArrangedSubview(resetButton)
        case .loggingIn:
            buttonStack.addArrangedSubview(loginButton)
            buttonStack.addArrangedSubview(resetButton)
        case .verifying:
            buttonStack.addArrangedSubview(reverifyButton)
            buttonStack.addArrangedSubview(signOutButton)
        case .loggedIn:
            buttonStack.addArrangedSubview(signOutButton)
            buttonStack.addArrangedSubview(switchAccountButton)
            buttonStack.addArrangedSubview(reverifyButton)
        case .expired, .error, .unknown:
            buttonStack.addArrangedSubview(loginButton)
            buttonStack.addArrangedSubview(reverifyButton)
            buttonStack.addArrangedSubview(resetButton)
        }
    }

    // MARK: - Action Handlers

    @objc private func loginClicked() {
        AppLogger.shared.log(category: .userAction, level: .info, message: "用户点击 [登录 Apple 官方账号] 按钮")
        onLoginClicked?()
    }
    @objc private func signOutClicked() {
        AppLogger.shared.log(category: .userAction, level: .info, message: "用户点击 [退出登录] 按钮")
        onSignOutClicked?()
    }
    @objc private func switchAccountClicked() {
        AppLogger.shared.log(category: .userAction, level: .info, message: "用户点击 [切换账号] 按钮")
        onSwitchAccountClicked?()
    }
    @objc private func reverifyClicked() {
        AppLogger.shared.log(category: .userAction, level: .info, message: "用户点击 [刷新验证] 按钮")
        onReverifyClicked?()
    }
    @objc private func resetClicked() {
        AppLogger.shared.log(category: .userAction, level: .info, message: "用户点击 [重置会话] 按钮")
        onResetSessionClicked?()
    }
    @objc private func cancelWebLoginClicked() {
        AppLogger.shared.log(category: .userAction, level: .info, message: "用户取消网页登录流程")
        dismissWebLogin()
        onCancelWebLogin?()
    }
}
