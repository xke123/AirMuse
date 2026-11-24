import Foundation

// MARK: - RequestPriority

public enum RequestPriority: Int, Sendable, Comparable, Hashable {
    case background = 0
    case normal = 1
    case high = 2
    case critical = 3

    public static func < (lhs: RequestPriority, rhs: RequestPriority) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

// MARK: - AuthScope

public enum AuthScope: Sendable, Equatable, Hashable {
    case publicCatalog(providerID: String, storefront: String)
    case clientRequired(providerID: String, storefront: String)
    case userRequired(SessionContext)

    public var cacheScopeKey: String {
        switch self {
        case .publicCatalog(let providerID, let storefront):
            return "pub|\(providerID)|\(storefront)"
        case .clientRequired(let providerID, let storefront):
            return "cli|\(providerID)|\(storefront)"
        case .userRequired(let ctx):
            return "usr|\(ctx.providerID)|\(ctx.accountID)|\(ctx.storefront)|\(ctx.sessionID.uuidString)"
        }
    }
}

// MARK: - CachePolicy

public enum CachePolicy: Sendable, Equatable, Hashable {
    case networkOnly
    case returnCacheElseLoad
    case staleWhileRevalidate
}

// MARK: - RequestPolicy

public struct RequestPolicy: Sendable, Equatable {
    public let totalDeadlineSeconds: TimeInterval
    public let attemptTimeoutSeconds: TimeInterval
    public let maxRetries: Int
    public let priority: RequestPriority
    public let authScope: AuthScope
    public let cachePolicy: CachePolicy
    public let deduplicate: Bool
    public let isSideEffecting: Bool

    public init(
        totalDeadlineSeconds: TimeInterval = 20.0,
        attemptTimeoutSeconds: TimeInterval = 8.0,
        maxRetries: Int = 2,
        priority: RequestPriority = .normal,
        authScope: AuthScope,
        cachePolicy: CachePolicy = .networkOnly,
        deduplicate: Bool = true,
        isSideEffecting: Bool = false
    ) {
        self.totalDeadlineSeconds = totalDeadlineSeconds
        self.attemptTimeoutSeconds = attemptTimeoutSeconds
        self.maxRetries = maxRetries
        self.priority = priority
        self.authScope = authScope
        self.cachePolicy = cachePolicy
        self.deduplicate = deduplicate
        self.isSideEffecting = isSideEffecting
    }
}

// MARK: - HTTP Types

public enum HTTPMethod: String, Sendable, Hashable {
    case get = "GET"
    case post = "POST"
    case put = "PUT"
    case delete = "DELETE"
    case head = "HEAD"
}

public struct HTTPRequest: Sendable, Equatable {
    public let method: HTTPMethod
    public let url: URL
    public let headers: [String: String]
    public let body: Data?
    public let policy: RequestPolicy

    public init(
        method: HTTPMethod = .get,
        url: URL,
        headers: [String: String] = [:],
        body: Data? = nil,
        policy: RequestPolicy
    ) {
        self.method = method
        self.url = url
        self.headers = headers
        self.body = body
        self.policy = policy
    }
}

public struct HTTPResponse: Sendable, Equatable {
    public let statusCode: Int
    public let headers: [String: String]
    public let data: Data
    public let url: URL

    public init(statusCode: Int, headers: [String: String] = [:], data: Data, url: URL) {
        self.statusCode = statusCode
        self.headers = headers
        self.data = data
        self.url = url
    }

    public func headerValue(forCaseInsensitiveName name: String) -> String? {
        let target = name.lowercased()
        for (k, v) in headers where k.lowercased() == target {
            return v
        }
        return nil
    }
}

public protocol HTTPTransportProtocol: Sendable {
    func send(_ request: HTTPRequest, timeoutSeconds: TimeInterval) async throws -> HTTPResponse
}

// MARK: - ClockProtocol

public protocol ClockProtocol: Sendable {
    var now: Date { get }
    var monotonicNanoseconds: UInt64 { get }
    func sleep(for duration: Duration) async throws
}

public struct SystemClock: ClockProtocol, Sendable {
    public init() {}

    public var now: Date { Date() }

    public var monotonicNanoseconds: UInt64 {
        DispatchTime.now().uptimeNanoseconds
    }

    public func sleep(for duration: Duration) async throws {
        try await Task.sleep(for: duration)
    }
}
