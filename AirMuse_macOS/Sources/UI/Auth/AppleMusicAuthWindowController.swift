// Sources/UI/Auth/AppleMusicAuthWindowController.swift
// AirMuse macOS – Native Liquid Glass Apple Music Auth Window Controller
// Swift 6 strict concurrency – @MainActor

import AppKit
import WebKit
import Domain
import DesignSystem
import Providers
import Infrastructure

// MARK: - AppleMusicAuthWindow

open class AppleMusicAuthWindow: NSPanel {
    public init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless, .resizable, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        level = .floating
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isMovableByWindowBackground = true
        minSize = NSSize(width: 480, height: 460)
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    }

    open override var canBecomeKey: Bool { true }
    open override var canBecomeMain: Bool { true }
}

// MARK: - AppleMusicAuthWindowController

@MainActor
open class AppleMusicAuthWindowController: NSWindowController {

    private let accountView = AppleMusicAccountView()
    private let sessionCoordinator: SessionCoordinator
    private let webLoginController: WebLoginController
    private var snapshotTask: Task<Void, Never>?
    private var currentSnapshot: SessionSnapshot = .initial

    public init(sessionCoordinator: SessionCoordinator, webLoginController: WebLoginController) {
        self.sessionCoordinator = sessionCoordinator
        self.webLoginController = webLoginController

        let screenFrame = NSScreen.main?.visibleFrame ?? NSRect(x: 100, y: 100, width: 1200, height: 800)
        let rect = NSRect(
            x: screenFrame.midX - 250,
            y: screenFrame.midY - 260,
            width: 500,
            height: 520
        )
        let window = AppleMusicAuthWindow(contentRect: rect)
        super.init(window: window)

        window.contentView = accountView
        wireCallbacks()
        listenToSessionChanges()
        refreshView()
    }

    public required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        snapshotTask?.cancel()
    }

    private func wireCallbacks() {
        accountView.onCloseClicked = { [weak self] in
            self?.window?.orderOut(nil)
        }

        accountView.onLoginClicked = { [weak self] in
            self?.handleStartLogin()
        }

        accountView.onSignOutClicked = { [weak self] in
            guard let self else { return }
            Task {
                await self.sessionCoordinator.invalidate(reason: .userSignOut)
                self.refreshView()
            }
        }

        accountView.onSwitchAccountClicked = { [weak self] in
            guard let self else { return }
            Task {
                await self.sessionCoordinator.invalidate(reason: .accountSwitch)
                self.handleStartLogin()
            }
        }

        accountView.onReverifyClicked = { [weak self] in
            guard let self else { return }
            Task {
                await self.sessionCoordinator.restoreFromStorage()
                self.refreshView()
            }
        }

        accountView.onResetSessionClicked = { [weak self] in
            guard let self else { return }
            Task {
                await self.sessionCoordinator.invalidate(reason: .userSignOut)
                await self.webLoginController.clearAllWebData()
                self.refreshView()
            }
        }

        accountView.onCancelWebLogin = { [weak self] in
            self?.webLoginController.cancelLogin()
            self?.accountView.dismissWebLogin()
        }
    }

    private func handleStartLogin() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            let wv = await self.webLoginController.startLogin()
            self.accountView.presentWebLogin(with: wv)
        }
    }

    private func listenToSessionChanges() {
        snapshotTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let stream = await self.sessionCoordinator.snapshots()
            for await snap in stream {
                guard !Task.isCancelled else { break }
                self.currentSnapshot = snap
                self.refreshView()

                if snap.sessionState == .authenticated {
                    Task { @MainActor [weak self] in
                        try? await Task.sleep(for: .seconds(1.5))
                        self?.accountView.dismissWebLogin()
                    }
                }
            }
        }
    }

    public func refreshView() {
        let webState: AppleMusicWebSessionState = switch currentSnapshot.sessionState {
        case .signedOut, .invalidating:
            .loggedOut
        case .restoring, .verifying:
            .verifying(tokenSnippet: nil)
        case .authenticating:
            .loggingIn(progressMessage: "请在官方页面完成登录")
        case .authenticated:
            if let acc = currentSnapshot.account {
                .loggedIn(account: acc, storefront: currentSnapshot.context?.storefront)
            } else {
                .verifying(tokenSnippet: nil)
            }
        case .offlineUnverified:
            .unknown
        case .expired(let reason):
            .expired(reason: reason)
        case .failed(let msg):
            .error(.tokenVerificationFailed(statusCode: 0, message: msg))
        }

        accountView.updateState(
            webState: webState,
            apiState: .developerCredentialsMissing(reason: "Web 官方会话模式"),
            account: currentSnapshot.account,
            storefront: currentSnapshot.context?.storefront
        )
    }

    public func showAuthWindow() {
        refreshView()
        window?.makeKeyAndOrderFront(nil)
    }
}
