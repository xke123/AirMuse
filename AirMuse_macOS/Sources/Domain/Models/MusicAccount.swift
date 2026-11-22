import Foundation

// MARK: - MusicAccount

/// Authentication / account state for a music provider.
public struct MusicAccount: Sendable, Identifiable, Codable, Equatable {
    public let id: String
    public var providerID: String
    public var displayName: String
    public var email: String?
    public var avatarURL: URL?
    public var isAuthenticated: Bool
    public var subscriptionTier: SubscriptionTier

    public enum SubscriptionTier: String, Sendable, Codable {
        case free
        case individual
        case family
        case student
        case trial
        case unknown
    }

    public init(
        id: String,
        providerID: String,
        displayName: String,
        email: String? = nil,
        avatarURL: URL? = nil,
        isAuthenticated: Bool = false,
        subscriptionTier: SubscriptionTier = .unknown
    ) {
        self.id = id
        self.providerID = providerID
        self.displayName = displayName
        self.email = email
        self.avatarURL = avatarURL
        self.isAuthenticated = isAuthenticated
        self.subscriptionTier = subscriptionTier
    }

    public init(displayName: String? = nil, source: MusicSource = .unknown, isAuthenticated: Bool = false) {
        self.id = UUID().uuidString
        self.providerID = source.rawValue
        self.displayName = displayName ?? source.displayName
        self.email = nil
        self.avatarURL = nil
        self.isAuthenticated = isAuthenticated
        self.subscriptionTier = .unknown
    }
}

// MARK: - Errors

public enum AuthenticationError: Error, Sendable {
    case userDenied
    case tokenExpired
    case networkError(String)
    case invalidCredentials
    case notConfigured
    case requiresAuthorization
}

public enum MusicProviderError: Error, Sendable {
    case unsupported
    case notAuthorized
    case notFound
    case playbackFailed(String)
}

public enum LyricsError: Error, Sendable {
    case notSupported
    case notFound
    case parseFailed
    case networkError(String)
}
