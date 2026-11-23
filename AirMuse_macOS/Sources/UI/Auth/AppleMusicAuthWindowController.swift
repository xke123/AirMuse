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
    private let sessionManager: AppleMusicSessionManager

    public init(sessionManager: AppleMusicSessionManager = .shared) {
        self.sessionManager = sessionManager

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
                await self.sessionManager.signOut()
                self.refreshView()
            }
        }

        accountView.onSwitchAccountClicked = { [weak self] in
            guard let self else { return }
            Task {
                await self.sessionManager.signOut()
                self.handleStartLogin()
            }
        }

        accountView.onReverifyClicked = { [weak self] in
            guard let self else { return }
            Task {
                await self.sessionManager.restoreSessionFromStorage()
                self.refreshView()
            }
        }

        accountView.onResetSessionClicked = { [weak self] in
            guard let self else { return }
            Task {
                await self.sessionManager.resetSession()
                self.refreshView()
            }
        }

        accountView.onCancelWebLogin = { [weak self] in
            self?.accountView.dismissWebLogin()
        }
    }

    private func handleStartLogin() {
        sessionManager.startLogin()
        let wv = sessionManager.createLoginWebView()
        accountView.presentWebLogin(with: wv)
    }

    private func listenToSessionChanges() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleSessionStateNotification(_:)),
            name: AppleMusicSessionManager.sessionStateDidChangeNotification,
            object: nil
        )

        sessionManager.onAPIAuthorizationChanged = { [weak self] _ in
            self?.refreshView()
        }
    }

    @objc private func handleSessionStateNotification(_ notif: Notification) {
        guard let newState = notif.userInfo?["state"] as? AppleMusicWebSessionState else { return }
        self.refreshView()

        // If login completed successfully, wait briefly for music.apple.com to finish persisting localStorage before dismissing
        if newState.isLoggedIn {
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(1.5))
                self?.accountView.dismissWebLogin()
            }
        }

        // If unsupported flow occurred, surface warning in web view
        if case .error(let err) = newState,
           case .unsupportedAuthenticationFlow(let msg) = err {
            let wv = self.sessionManager.createLoginWebView()
            self.accountView.presentWebLogin(with: wv, warning: msg)
        }
    }

    public func refreshView() {
        accountView.updateState(
            webState: sessionManager.webSessionState,
            apiState: sessionManager.apiAuthorizationState,
            account: sessionManager.currentAccount,
            storefront: sessionManager.currentStorefront
        )
    }

    public func showAuthWindow() {
        refreshView()
        window?.makeKeyAndOrderFront(nil)
    }
}
