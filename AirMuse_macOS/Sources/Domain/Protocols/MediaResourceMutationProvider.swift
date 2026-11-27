import Foundation

// MARK: - MediaActionError

public enum MediaActionError: LocalizedError, Sendable, Equatable {
    case notAuthenticated
    case forbidden
    case readOnlyPlaylist
    case unsupportedCapability(String)
    case accountMismatch
    case staleOperation
    case networkTimeout
    case serverError(String)

    public var errorDescription: String? {
        switch self {
        case .notAuthenticated:
            return "请先登录当前平台账号"
        case .forbidden:
            return "当前账号无权执行此操作"
        case .readOnlyPlaylist:
            return "个人自建或协作歌单为只读容器，不支持修改"
        case .unsupportedCapability(let detail):
            return "当前音源暂不支持该操作：\(detail)"
        case .accountMismatch:
            return "账号已切换，已取消旧账号操作"
        case .staleOperation:
            return "操作已过期"
        case .networkTimeout:
            return "请求超时，正在核对最新状态"
        case .serverError(let msg):
            return msg
        }
    }
}

// MARK: - MediaMutationReceipt

public struct MediaMutationReceipt: Sendable, Equatable {
    public let state: MediaResourceState
    public let message: String?

    public init(state: MediaResourceState, message: String? = nil) {
        self.state = state
        self.message = message
    }
}

// MARK: - MediaResourceMutationProvider

public protocol MediaResourceMutationProvider: Sendable {
    func mediaActionCapabilities(for resource: MediaResourceReference) async -> MediaActionCapabilities
    func fetchResourceState(_ resource: MediaResourceReference) async throws -> MediaResourceState
    func fetchResourceStates(for resources: [MediaResourceReference]) async throws -> [String: MediaResourceState]
    func addToLibrary(_ resource: MediaResourceReference) async throws -> MediaMutationReceipt
    func removeFromLibrary(_ resource: MediaResourceReference) async throws -> MediaMutationReceipt
    func setFavorite(_ resource: MediaResourceReference, enabled: Bool) async throws -> MediaMutationReceipt
}

public extension MediaResourceMutationProvider {
    func fetchResourceStates(for resources: [MediaResourceReference]) async throws -> [String: MediaResourceState] {
        var result: [String: MediaResourceState] = [:]
        for resource in resources {
            if let state = try? await fetchResourceState(resource) {
                result[resource.normalizedKey] = state
            }
        }
        return result
    }
}
