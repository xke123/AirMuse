// Sources/Providers/AppleMusic/Session/AppleMusicSessionModels.swift
// AirMuse macOS – Apple Music Session Models & State Machine
// Swift 6 strict concurrency

import Foundation
import Domain

// MARK: - AppleMusicWebSessionState

/// Represents the lifecycle state of the Apple Music Web Session.
/// Strictly separated from Apple Music API (MusicKit) developer authorization.
public enum AppleMusicWebSessionState: Sendable, Equatable {
    /// No web session is active; user is logged out.
    case loggedOut

    /// Web login flow is open / in progress, waiting for user authentication on official page.
    case loggingIn(progressMessage: String? = nil)

    /// Official authentication signal detected (e.g. cookie / token); actively validating against Apple server.
    case verifying(tokenSnippet: String? = nil)

    /// Authenticated and verified with Apple's backend using legitimate credentials.
    case loggedIn(account: MusicAccount, storefront: String? = nil)

    /// Session was active, but token has expired or Apple server returned 401 / 403.
    case expired(reason: String)

    /// An explicit error occurred during session establishment or verification.
    case error(AppleMusicSessionError)

    /// Session state cannot be determined with verifiable signals (e.g. during offline mode or incomplete data).
    case unknown

    public var isLoggedIn: Bool {
        if case .loggedIn = self { return true }
        return false
    }

    public var displayName: String {
        switch self {
        case .loggedOut:
            return "未登录"
        case .loggingIn:
            return "登录中"
        case .verifying:
            return "验证中"
        case .loggedIn(let account, _):
            return "已登录 (\(account.displayName))"
        case .expired(let reason):
            return "已失效: \(reason)"
        case .error(let err):
            return "错误: \(err.localizedDescription)"
        case .unknown:
            return "未知状态"
        }
    }
}

// MARK: - AppleMusicAPIAuthorizationState

/// Represents the status of official Apple Music API / MusicKit Developer authorization.
/// Under the constraint of NO paid Apple Developer Program membership, this reflects
/// the honest capability boundary without faking or mocking developer credentials.
public enum AppleMusicAPIAuthorizationState: Sendable, Equatable {
    /// Authorization status has not been determined yet.
    case notDetermined

    /// Native MusicKit is authorized with a valid Apple Developer Program entitlement.
    case authorized

    /// User or system denied MusicKit authorization.
    case denied

    /// MusicKit access is restricted (e.g. Parental Controls / MDM profile).
    case restricted

    /// No Apple Developer Program credentials / private key available; operates in official web degraded mode.
    case developerCredentialsMissing(reason: String)

    public var isAuthorized: Bool {
        self == .authorized
    }

    public var displayDescription: String {
        switch self {
        case .notDetermined:
            return "未检测 API 授权"
        case .authorized:
            return "已获得 MusicKit 官方授权"
        case .denied:
            return "MusicKit 授权已被拒绝"
        case .restricted:
            return "MusicKit 授权受限"
        case .developerCredentialsMissing(let reason):
            return "未配置开发者凭据 (\(reason))"
        }
    }
}

// MARK: - AppleMusicSessionError

/// Explicit error cases for Apple Music session management.
public enum AppleMusicSessionError: Error, Sendable, Equatable, LocalizedError {
    case networkUnavailable
    case webViewFailed(String)
    case unsupportedAuthenticationFlow(String)
    case tokenVerificationFailed(statusCode: Int, message: String)
    case sessionExpired
    case userCancelled
    case developerTokenMissing
    case cookieExtractionFailed
    case sessionGenerationMismatch

    public var errorDescription: String? {
        switch self {
        case .networkUnavailable:
            return "网络不可用，无法验证 Apple Music 会话"
        case .webViewFailed(let msg):
            return "WebKit 浏览器加载失败: \(msg)"
        case .unsupportedAuthenticationFlow(let msg):
            return "WebKit 不支持当前的 Apple 登录方式: \(msg)"
        case .tokenVerificationFailed(let code, let msg):
            return "Apple 令牌服务端验证失败 (HTTP \(code)): \(msg)"
        case .sessionExpired:
            return "Apple Music 会话已过期，请重新登录"
        case .userCancelled:
            return "用户取消了 Apple Music 登录"
        case .developerTokenMissing:
            return "缺少 Apple Music Developer Token，无法完成 API 请求"
        case .cookieExtractionFailed:
            return "未从 Apple 登录流程中提取到可信会话 Cookie"
        case .sessionGenerationMismatch:
            return "旧会话请求已被废弃 (跨会话防护)"
        }
    }
}

// MARK: - AppleMusicSessionSnapshot

/// Thread-safe immutable snapshot of the Apple Music session state.
public struct AppleMusicSessionSnapshot: Sendable, Equatable {
    public let generation: Int
    public let webSessionState: AppleMusicWebSessionState
    public let apiAuthorizationState: AppleMusicAPIAuthorizationState
    public let account: MusicAccount?
    public let hasUserToken: Bool
    public let hasDeveloperToken: Bool
    public let storefront: String?

    public init(
        generation: Int,
        webSessionState: AppleMusicWebSessionState,
        apiAuthorizationState: AppleMusicAPIAuthorizationState,
        account: MusicAccount?,
        hasUserToken: Bool,
        hasDeveloperToken: Bool,
        storefront: String? = nil
    ) {
        self.generation = generation
        self.webSessionState = webSessionState
        self.apiAuthorizationState = apiAuthorizationState
        self.account = account
        self.hasUserToken = hasUserToken
        self.hasDeveloperToken = hasDeveloperToken
        self.storefront = storefront
    }
}
