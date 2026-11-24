import Foundation

// MARK: - CoreError

/// Unified, typed domain error hierarchy for AirMuse Core V2.
/// Replaces ad-hoc string errors and prevents conflating offline, 403 forbidden,
/// client credential failure, and user credential expiration.
public enum CoreError: Error, Sendable, Equatable, LocalizedError {
    case offline
    case timeout
    case transport(statusCode: Int?, message: String)
    case clientCredentialInvalid
    case userCredentialInvalid
    case forbidden(String?)
    case subscriptionRequired
    case rateLimited(retryAfterSeconds: TimeInterval?)
    case server(statusCode: Int, message: String?)
    case decode(String)
    case notFound(String?)
    case cancelled
    case staleSession
    case unsupported(String)
    case storage(String)

    public var errorDescription: String? {
        switch self {
        case .offline:
            return "网络不可用，请检查网络连接"
        case .timeout:
            return "请求超时，请稍后重试"
        case .transport(let code, let msg):
            if let code { return "网络传输错误 (HTTP \(code)): \(msg)" }
            return "网络传输错误: \(msg)"
        case .clientCredentialInvalid:
            return "客户端服务凭据已失效"
        case .userCredentialInvalid:
            return "用户登录凭据已失效，请重新登录"
        case .forbidden(let detail):
            return detail ?? "当前请求被服务端拒绝 (403)"
        case .subscriptionRequired:
            return "需要有效订阅权限才能执行此操作"
        case .rateLimited(let retryAfter):
            if let retryAfter {
                return "请求过于频繁，请在 \(Int(ceil(retryAfter))) 秒后重试"
            }
            return "请求过于频繁，请稍后重试"
        case .server(let code, let msg):
            return "服务端异常 (HTTP \(code))" + (msg.map { ": \($0)" } ?? "")
        case .decode(let detail):
            return "数据解析失败: \(detail)"
        case .notFound(let detail):
            return detail ?? "请求的资源不存在"
        case .cancelled:
            return "操作已取消"
        case .staleSession:
            return "会话已切换或失效，旧操作已作废"
        case .unsupported(let detail):
            return "当前平台或会话不支持该操作: \(detail)"
        case .storage(let detail):
            return "本地存储错误: \(detail)"
        }
    }
}
