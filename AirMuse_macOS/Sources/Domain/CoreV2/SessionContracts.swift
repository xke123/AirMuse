import Foundation

// MARK: - Independent State Dimensions

public enum SessionState: Sendable, Equatable {
    case restoring
    case signedOut
    case authenticating
    case verifying
    case authenticated
    case offlineUnverified
    case invalidating
    case expired(reason: String)
    case failed(String)

    public var isAuthenticated: Bool {
        if case .authenticated = self { return true }
        return false
    }

    public var allowsCachedPrivateRead: Bool {
        switch self {
        case .authenticated, .offlineUnverified, .verifying:
            return true
        default:
            return false
        }
    }
}

public enum CredentialState: Sendable, Equatable {
    case missing
    case available
    case refreshing
    case invalid
}

public enum SubscriptionState: Sendable, Equatable {
    case unknown
    case active
    case inactive
    case unsupported
}

public enum CatalogAvailabilityState: Sendable, Equatable {
    case idle
    case available
    case degraded
    case unavailable
}

public enum EngineReadinessState: Sendable, Equatable {
    case idle
    case initializing
    case authorizing
    case ready
    case recovering
    case failed(String)
}

// MARK: - SessionContext

/// Immutable context captured at the start of any account-scoped operation.
/// All final writes (cache, credentials, playback, UI) must atomically validate
/// that `sessionID` and `generation` still match the active session.
public struct SessionContext: Sendable, Equatable, Hashable {
    public let providerID: String
    public let accountID: String
    public let storefront: String
    public let sessionID: UUID
    public let generation: UInt64

    public init(
        providerID: String,
        accountID: String,
        storefront: String,
        sessionID: UUID,
        generation: UInt64
    ) {
        self.providerID = providerID
        self.accountID = accountID
        self.storefront = storefront
        self.sessionID = sessionID
        self.generation = generation
    }
}

// MARK: - SessionSnapshot

public struct SessionSnapshot: Sendable, Equatable {
    public let context: SessionContext?
    public let sessionState: SessionState
    public let clientCredentialState: CredentialState
    public let userCredentialState: CredentialState
    public let subscriptionState: SubscriptionState
    public let catalogState: CatalogAvailabilityState
    public let engineState: EngineReadinessState
    public let account: MusicAccount?

    public init(
        context: SessionContext?,
        sessionState: SessionState,
        clientCredentialState: CredentialState,
        userCredentialState: CredentialState,
        subscriptionState: SubscriptionState,
        catalogState: CatalogAvailabilityState,
        engineState: EngineReadinessState,
        account: MusicAccount?
    ) {
        self.context = context
        self.sessionState = sessionState
        self.clientCredentialState = clientCredentialState
        self.userCredentialState = userCredentialState
        self.subscriptionState = subscriptionState
        self.catalogState = catalogState
        self.engineState = engineState
        self.account = account
    }

    public static let initial = SessionSnapshot(
        context: nil,
        sessionState: .signedOut,
        clientCredentialState: .missing,
        userCredentialState: .missing,
        subscriptionState: .unknown,
        catalogState: .idle,
        engineState: .idle,
        account: nil
    )
}

// MARK: - Credential Contracts

public enum CredentialKind: String, Sendable, Codable, Hashable {
    case client
    case user
}

public struct CredentialRecord: Sendable, Equatable, Codable {
    public let kind: CredentialKind
    public let value: String
    public let updatedAt: Date
    public let expiresAt: Date?

    public init(kind: CredentialKind, value: String, updatedAt: Date = Date(), expiresAt: Date? = nil) {
        self.kind = kind
        self.value = value
        self.updatedAt = updatedAt
        self.expiresAt = expiresAt
    }

    public func isExpired(at date: Date) -> Bool {
        if let expiresAt {
            return date >= expiresAt
        }
        return false
    }
}

public protocol CredentialVaultProtocol: Sendable {
    func load(providerID: String, accountID: String?, kind: CredentialKind) async throws -> CredentialRecord?
    func save(_ record: CredentialRecord, providerID: String, accountID: String?) async throws
    func delete(providerID: String, accountID: String?, kind: CredentialKind) async throws
    func clearAccountCredentials(providerID: String, accountID: String) async throws
}

public protocol SessionCoordinatorProtocol: Sendable {
    var snapshot: SessionSnapshot { get async }
    func snapshots() async -> AsyncStream<SessionSnapshot>
    func validate(context: SessionContext) async -> Bool
}
