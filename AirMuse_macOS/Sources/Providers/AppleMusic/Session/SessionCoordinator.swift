import Foundation
import Domain
import Infrastructure

// MARK: - SessionVerificationResult

public struct SessionVerificationResult: Sendable, Equatable {
    public let isValid: Bool
    public let storefront: String?
    public let accountName: String?
    public let serverAccountID: String?
    public let subscriptionState: SubscriptionState

    public init(
        isValid: Bool,
        storefront: String?,
        accountName: String? = nil,
        serverAccountID: String? = nil,
        subscriptionState: SubscriptionState = .unknown
    ) {
        self.isValid = isValid
        self.storefront = storefront
        self.accountName = accountName
        self.serverAccountID = serverAccountID
        self.subscriptionState = subscriptionState
    }
}

// MARK: - SessionInvalidationReason

public enum SessionInvalidationReason: Sendable, Equatable {
    case userSignOut
    case accountSwitch
    case userCredentialExpired(String)
    case clientCredentialInvalid
    case networkOffline
}

// MARK: - SessionAuthBackendProtocol

/// Testable abstraction for verifying user tokens and refreshing client credentials.
public protocol SessionAuthBackendProtocol: Sendable {
    func verifyUserToken(_ userToken: String, clientToken: String) async throws -> SessionVerificationResult
    func refreshClientCredential() async throws -> CredentialRecord
}

// MARK: - SessionCoordinator

/// Single authoritative owner of account session state, SessionContext,
/// login attempt lifecycle, single-flight credential refresh, and atomic invalidation transactions.
public actor SessionCoordinator: SessionCoordinatorProtocol {
    private let providerID: String
    private let vault: any CredentialVaultProtocol
    private let backend: any SessionAuthBackendProtocol
    private let clock: any ClockProtocol
    private let onEngineIsolate: @Sendable () async -> Void
    private let onClearWebSessionData: @Sendable () async -> Void

    private var _snapshot: SessionSnapshot = .initial
    private var generation: UInt64 = 0
    private var activeLoginAttemptID: UUID?
    private var activeVerifyTask: Task<Void, Never>?
    private var continuations: [UUID: AsyncStream<SessionSnapshot>.Continuation] = [:]

    // Single-flight credential refresh keyed by (sessionID, CredentialKind)
    private struct RefreshKey: Hashable {
        let sessionID: UUID?
        let kind: CredentialKind
    }

    private final class RefreshEntry {
        var task: Task<CredentialRecord, Error>?
        var waiters: [UUID: CheckedContinuation<CredentialRecord, Error>] = [:]
    }

    private var refreshEntries: [RefreshKey: RefreshEntry] = [:]

    public init(
        providerID: String = "apple_music",
        vault: any CredentialVaultProtocol,
        backend: any SessionAuthBackendProtocol,
        clock: any ClockProtocol = SystemClock(),
        onEngineIsolate: @escaping @Sendable () async -> Void = {},
        onClearWebSessionData: @escaping @Sendable () async -> Void = {}
    ) {
        self.providerID = providerID
        self.vault = vault
        self.backend = backend
        self.clock = clock
        self.onEngineIsolate = onEngineIsolate
        self.onClearWebSessionData = onClearWebSessionData
    }

    // MARK: - SessionCoordinatorProtocol

    public var snapshot: SessionSnapshot { _snapshot }

    public func snapshots() async -> AsyncStream<SessionSnapshot> {
        AsyncStream(bufferingPolicy: .bufferingNewest(16)) { continuation in
            let id = UUID()
            continuations[id] = continuation
            continuation.yield(_snapshot)
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeContinuation(id: id) }
            }
        }
    }

    private func removeContinuation(id: UUID) {
        continuations.removeValue(forKey: id)
    }

    public func validate(context: SessionContext) async -> Bool {
        guard let active = _snapshot.context else { return false }
        guard active.sessionID == context.sessionID && active.generation == context.generation else {
            return false
        }
        switch _snapshot.sessionState {
        case .invalidating, .signedOut, .expired, .failed:
            return false
        default:
            return true
        }
    }

    // MARK: - Login Attempt Lifecycle

    /// Starts a new login attempt, invalidating any prior uncompleted attempt.
    @discardableResult
    public func beginLoginAttempt() -> UUID {
        let attemptID = UUID()
        activeLoginAttemptID = attemptID
        publish(SessionSnapshot(
            context: _snapshot.context,
            sessionState: .authenticating,
            clientCredentialState: _snapshot.clientCredentialState,
            userCredentialState: _snapshot.userCredentialState,
            subscriptionState: .unknown,
            catalogState: _snapshot.catalogState,
            engineState: _snapshot.engineState,
            account: _snapshot.account
        ))
        return attemptID
    }

    public func cancelLoginAttempt(_ attemptID: UUID) {
        guard activeLoginAttemptID == attemptID else { return }
        activeLoginAttemptID = nil
        if _snapshot.sessionState == .authenticating {
            publish(SessionSnapshot(
                context: _snapshot.context,
                sessionState: _snapshot.context == nil ? .signedOut : .authenticated,
                clientCredentialState: _snapshot.clientCredentialState,
                userCredentialState: _snapshot.userCredentialState,
                subscriptionState: _snapshot.subscriptionState,
                catalogState: _snapshot.catalogState,
                engineState: _snapshot.engineState,
                account: _snapshot.account
            ))
        }
    }

    /// Completes a login attempt with a captured user token.
    /// Rejects stale/cancelled attempts before touching vault or active session state.
    public func completeLoginAttempt(
        _ attemptID: UUID,
        userToken: String,
        clientToken: String? = nil,
        storefrontHint: String = "cn"
    ) async throws -> SessionContext {
        guard activeLoginAttemptID == attemptID else {
            throw CoreError.staleSession
        }
        let genAtStart = generation
        let resolvedClient: String
        if let clientToken, !clientToken.isEmpty {
            resolvedClient = clientToken
            try? await vault.save(CredentialRecord(kind: .client, value: clientToken, updatedAt: clock.now), providerID: providerID, accountID: nil)
        } else {
            let rec = try await refreshCredentialSingleFlight(kind: .client)
            resolvedClient = rec.value
        }

        guard activeLoginAttemptID == attemptID, generation == genAtStart else {
            throw CoreError.staleSession
        }

        publish(SessionSnapshot(
            context: _snapshot.context,
            sessionState: .verifying,
            clientCredentialState: .available,
            userCredentialState: .available,
            subscriptionState: .unknown,
            catalogState: _snapshot.catalogState,
            engineState: _snapshot.engineState,
            account: _snapshot.account
        ))

        let verification = try await backend.verifyUserToken(userToken, clientToken: resolvedClient)

        // Atomic commit boundary after await
        guard activeLoginAttemptID == attemptID, generation == genAtStart else {
            throw CoreError.staleSession
        }
        guard verification.isValid else {
            throw CoreError.userCredentialInvalid
        }

        activeLoginAttemptID = nil
        generation += 1
        let newGen = generation
        let sf = (verification.storefront?.isEmpty == false) ? verification.storefront! : storefrontHint
        let accountID = AccountNamespaceResolver.stableAccountID(
            providerID: providerID,
            serverAccountID: verification.serverAccountID,
            token: userToken
        )
        let ctx = SessionContext(
            providerID: providerID,
            accountID: accountID,
            storefront: sf,
            sessionID: UUID(),
            generation: newGen
        )

        let displayName = Self.truthfulDisplayName(
            accountName: verification.accountName,
            storefront: sf
        )
        let account = MusicAccount(
            id: accountID,
            providerID: providerID,
            displayName: displayName,
            email: nil,
            avatarURL: nil,
            isAuthenticated: true,
            subscriptionTier: .unknown
        )

        try await vault.save(
            CredentialRecord(kind: .user, value: userToken, updatedAt: clock.now),
            providerID: providerID,
            accountID: accountID
        )
        // Also persist last active accountID under global metadata key for restore
        try? await vault.save(
            CredentialRecord(kind: .user, value: accountID, updatedAt: clock.now),
            providerID: providerID,
            accountID: "_last_active_"
        )

        publish(SessionSnapshot(
            context: ctx,
            sessionState: .authenticated,
            clientCredentialState: .available,
            userCredentialState: .available,
            subscriptionState: verification.subscriptionState,
            catalogState: .available,
            engineState: _snapshot.engineState,
            account: account
        ))
        return ctx
    }

    // MARK: - Restore From Storage

    /// Restores local credentials without blocking on network, then verifies asynchronously.
    /// Offline network never deletes user credentials and enters `.offlineUnverified` (not `.authenticated`).
    public func restoreFromStorage(defaultStorefront: String = "cn") async {
        let genAtStart = generation
        publish(SessionSnapshot(
            context: nil,
            sessionState: .restoring,
            clientCredentialState: .missing,
            userCredentialState: .missing,
            subscriptionState: .unknown,
            catalogState: .idle,
            engineState: .idle,
            account: nil
        ))

        let clientRec = try? await vault.load(providerID: providerID, accountID: nil, kind: .client)
        let lastAccountRec = try? await vault.load(providerID: providerID, accountID: "_last_active_", kind: .user)
        let accountID = lastAccountRec?.value
        let userRec: CredentialRecord? = if let accountID {
            try? await vault.load(providerID: providerID, accountID: accountID, kind: .user)
        } else {
            nil
        }

        guard generation == genAtStart else { return }

        guard let userRec, !userRec.value.isEmpty, let accountID else {
            publish(SessionSnapshot(
                context: nil,
                sessionState: .signedOut,
                clientCredentialState: clientRec == nil ? .missing : .available,
                userCredentialState: .missing,
                subscriptionState: .unknown,
                catalogState: .idle,
                engineState: .idle,
                account: nil
            ))
            return
        }

        generation += 1
        let restoreGen = generation
        let ctx = SessionContext(
            providerID: providerID,
            accountID: accountID,
            storefront: defaultStorefront,
            sessionID: UUID(),
            generation: restoreGen
        )

        let unverifiedAccount = MusicAccount(
            id: accountID,
            providerID: providerID,
            displayName: Self.truthfulDisplayName(accountName: nil, storefront: defaultStorefront),
            isAuthenticated: false,
            subscriptionTier: .unknown
        )

        publish(SessionSnapshot(
            context: ctx,
            sessionState: .verifying,
            clientCredentialState: clientRec == nil ? .missing : .available,
            userCredentialState: .available,
            subscriptionState: .unknown,
            catalogState: .idle,
            engineState: .idle,
            account: unverifiedAccount
        ))

        activeVerifyTask?.cancel()
        activeVerifyTask = Task { [weak self] in
            await self?.verifyRestoredSession(context: ctx, userToken: userRec.value, clientToken: clientRec?.value)
        }
    }

    private func verifyRestoredSession(context: SessionContext, userToken: String, clientToken: String?) async {
        do {
            let resolvedClient: String
            if let clientToken, !clientToken.isEmpty {
                resolvedClient = clientToken
            } else {
                let rec = try await refreshCredentialSingleFlight(kind: .client)
                resolvedClient = rec.value
            }

            guard await validate(context: context) else { return }
            let result = try await backend.verifyUserToken(userToken, clientToken: resolvedClient)
            guard await validate(context: context) else { return }

            if result.isValid {
                let sf = (result.storefront?.isEmpty == false) ? result.storefront! : context.storefront
                let updatedCtx = SessionContext(
                    providerID: context.providerID,
                    accountID: context.accountID,
                    storefront: sf,
                    sessionID: context.sessionID,
                    generation: context.generation
                )
                let verifiedAccount = MusicAccount(
                    id: context.accountID,
                    providerID: providerID,
                    displayName: Self.truthfulDisplayName(accountName: result.accountName, storefront: sf),
                    isAuthenticated: true,
                    subscriptionTier: .unknown
                )
                publish(SessionSnapshot(
                    context: updatedCtx,
                    sessionState: .authenticated,
                    clientCredentialState: .available,
                    userCredentialState: .available,
                    subscriptionState: result.subscriptionState,
                    catalogState: .available,
                    engineState: _snapshot.engineState,
                    account: verifiedAccount
                ))
            } else {
                await invalidate(reason: .userCredentialExpired("服务端拒绝了用户凭据"))
            }
        } catch let err as CoreError {
            guard await validate(context: context) else { return }
            switch err {
            case .offline, .timeout:
                // Offline does NOT equal signedOut and NEVER deletes user credentials!
                publish(SessionSnapshot(
                    context: context,
                    sessionState: .offlineUnverified,
                    clientCredentialState: _snapshot.clientCredentialState,
                    userCredentialState: .available,
                    subscriptionState: .unknown,
                    catalogState: .degraded,
                    engineState: _snapshot.engineState,
                    account: _snapshot.account
                ))
            case .clientCredentialInvalid:
                // Client credential failure does NOT delete user credentials!
                publish(SessionSnapshot(
                    context: context,
                    sessionState: .offlineUnverified,
                    clientCredentialState: .invalid,
                    userCredentialState: .available,
                    subscriptionState: .unknown,
                    catalogState: .unavailable,
                    engineState: _snapshot.engineState,
                    account: _snapshot.account
                ))
            case .userCredentialInvalid:
                await invalidate(reason: .userCredentialExpired(err.localizedDescription))
            case .forbidden:
                // 403 does NOT blindly log the user out
                publish(SessionSnapshot(
                    context: context,
                    sessionState: .authenticated,
                    clientCredentialState: _snapshot.clientCredentialState,
                    userCredentialState: .available,
                    subscriptionState: .unknown,
                    catalogState: .degraded,
                    engineState: _snapshot.engineState,
                    account: _snapshot.account
                ))
            default:
                publish(SessionSnapshot(
                    context: context,
                    sessionState: .offlineUnverified,
                    clientCredentialState: _snapshot.clientCredentialState,
                    userCredentialState: .available,
                    subscriptionState: .unknown,
                    catalogState: .degraded,
                    engineState: _snapshot.engineState,
                    account: _snapshot.account
                ))
            }
        } catch {
            guard await validate(context: context) else { return }
            publish(SessionSnapshot(
                context: context,
                sessionState: .offlineUnverified,
                clientCredentialState: _snapshot.clientCredentialState,
                userCredentialState: .available,
                subscriptionState: .unknown,
                catalogState: .degraded,
                engineState: _snapshot.engineState,
                account: _snapshot.account
            ))
        }
    }

    // MARK: - Single-Flight Credential Refresh

    public func refreshCredentialSingleFlight(kind: CredentialKind) async throws -> CredentialRecord {
        let sessionID = _snapshot.context?.sessionID
        let genAtStart = generation
        let key = RefreshKey(sessionID: sessionID, kind: kind)
        let waiterID = UUID()

        let entry: RefreshEntry
        let isOwner: Bool
        if let existing = refreshEntries[key] {
            entry = existing
            isOwner = false
        } else {
            let created = RefreshEntry()
            refreshEntries[key] = created
            entry = created
            isOwner = true
        }

        if isOwner {
            updateCredentialState(kind: kind, state: .refreshing)
            entry.task = Task { [weak self] in
                guard let self else { throw CoreError.cancelled }
                do {
                    let record = try await self.performCredentialRefresh(kind: kind, expectedGeneration: genAtStart)
                    await self.finishRefresh(key: key, result: .success(record))
                    return record
                } catch {
                    await self.finishRefresh(key: key, result: .failure(error))
                    throw error
                }
            }
        }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { cont in
                if Task.isCancelled {
                    cont.resume(throwing: CoreError.cancelled)
                    return
                }
                if let current = refreshEntries[key], current === entry {
                    entry.waiters[waiterID] = cont
                } else {
                    cont.resume(throwing: CoreError.cancelled)
                }
            }
        } onCancel: {
            Task {
                await self.cancelRefreshWaiter(key: key, waiterID: waiterID)
            }
        }
    }

    private func performCredentialRefresh(kind: CredentialKind, expectedGeneration: UInt64) async throws -> CredentialRecord {
        switch kind {
        case .client:
            let record = try await backend.refreshClientCredential()
            guard generation == expectedGeneration else {
                throw CoreError.staleSession
            }
            try await vault.save(record, providerID: providerID, accountID: nil)
            updateCredentialState(kind: .client, state: .available)
            return record
        case .user:
            // User token cannot be silently fabricated; requires interactive login if invalid
            throw CoreError.userCredentialInvalid
        }
    }

    private func finishRefresh(key: RefreshKey, result: Result<CredentialRecord, Error>) {
        guard let entry = refreshEntries.removeValue(forKey: key) else { return }
        let waiters = entry.waiters
        entry.waiters.removeAll()
        for (_, cont) in waiters {
            cont.resume(with: result)
        }
    }

    private func cancelRefreshWaiter(key: RefreshKey, waiterID: UUID) {
        guard let entry = refreshEntries[key] else { return }
        if let cont = entry.waiters.removeValue(forKey: waiterID) {
            cont.resume(throwing: CoreError.cancelled)
        }
        if entry.waiters.isEmpty {
            refreshEntries.removeValue(forKey: key)
            entry.task?.cancel()
        }
    }

    // MARK: - Unified Invalidation Transaction

    public func invalidate(reason: SessionInvalidationReason) async {
        // 1. Synchronous actor segment: bump generation, close entry, cancel in-flight tasks
        generation += 1
        activeLoginAttemptID = nil
        activeVerifyTask?.cancel()
        activeVerifyTask = nil

        for (key, entry) in refreshEntries {
            entry.task?.cancel()
            for (_, cont) in entry.waiters {
                cont.resume(throwing: CoreError.staleSession)
            }
            refreshEntries.removeValue(forKey: key)
        }

        let oldContext = _snapshot.context

        switch reason {
        case .networkOffline:
            publish(SessionSnapshot(
                context: oldContext,
                sessionState: .offlineUnverified,
                clientCredentialState: _snapshot.clientCredentialState,
                userCredentialState: _snapshot.userCredentialState,
                subscriptionState: .unknown,
                catalogState: .degraded,
                engineState: _snapshot.engineState,
                account: _snapshot.account
            ))
            return

        case .clientCredentialInvalid:
            publish(SessionSnapshot(
                context: oldContext,
                sessionState: oldContext == nil ? .signedOut : .offlineUnverified,
                clientCredentialState: .invalid,
                userCredentialState: _snapshot.userCredentialState,
                subscriptionState: _snapshot.subscriptionState,
                catalogState: .unavailable,
                engineState: _snapshot.engineState,
                account: _snapshot.account
            ))
            return

        case .userSignOut, .accountSwitch, .userCredentialExpired:
            publish(SessionSnapshot(
                context: nil,
                sessionState: .invalidating,
                clientCredentialState: _snapshot.clientCredentialState,
                userCredentialState: .missing,
                subscriptionState: .unknown,
                catalogState: .idle,
                engineState: .idle,
                account: nil
            ))

            if let accountID = oldContext?.accountID {
                try? await vault.clearAccountCredentials(providerID: providerID, accountID: accountID)
            }
            try? await vault.delete(providerID: providerID, accountID: "_last_active_", kind: .user)

            await onEngineIsolate()
            await onClearWebSessionData()

            let finalState: SessionState = switch reason {
            case .userCredentialExpired(let msg): .expired(reason: msg)
            default: .signedOut
            }
            publish(SessionSnapshot(
                context: nil,
                sessionState: finalState,
                clientCredentialState: _snapshot.clientCredentialState,
                userCredentialState: .missing,
                subscriptionState: .unknown,
                catalogState: .idle,
                engineState: .idle,
                account: nil
            ))
        }
    }

    // MARK: - Helpers

    private func updateCredentialState(kind: CredentialKind, state: CredentialState) {
        let cur = _snapshot
        publish(SessionSnapshot(
            context: cur.context,
            sessionState: cur.sessionState,
            clientCredentialState: kind == .client ? state : cur.clientCredentialState,
            userCredentialState: kind == .user ? state : cur.userCredentialState,
            subscriptionState: cur.subscriptionState,
            catalogState: cur.catalogState,
            engineState: cur.engineState,
            account: cur.account
        ))
    }

    private func publish(_ newSnapshot: SessionSnapshot) {
        _snapshot = newSnapshot
        for cont in continuations.values {
            cont.yield(newSnapshot)
        }
    }

    private static func truthfulDisplayName(accountName: String?, storefront: String?) -> String {
        if let name = accountName?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
            return name
        }
        if let sf = storefront?.trimmingCharacters(in: .whitespacesAndNewlines), !sf.isEmpty {
            return "Apple Music (\(sf.uppercased()))"
        }
        return "Apple Music 用户"
    }
}
