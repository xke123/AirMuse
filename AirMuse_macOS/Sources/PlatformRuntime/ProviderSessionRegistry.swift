import Foundation
import Domain
import Infrastructure

// MARK: - ProviderSessionRecord

public struct ProviderSessionRecord: Sendable, Equatable {
    public let descriptor: PlatformDescriptor
    public let sessionContext: SessionContext?
    public let sessionState: SessionState
    public let isActivated: Bool

    public init(
        descriptor: PlatformDescriptor,
        sessionContext: SessionContext?,
        sessionState: SessionState,
        isActivated: Bool
    ) {
        self.descriptor = descriptor
        self.sessionContext = sessionContext
        self.sessionState = sessionState
        self.isActivated = isActivated
    }
}

// MARK: - ProviderSessionRegistry

/// Generic platform registry, lazy activation coordinator, and per-provider session isolation owner.
/// Never imports concrete adapters; stores descriptors + lazy factories only.
public actor ProviderSessionRegistry {
    private var factories: [ProviderID: any PlatformAdapterFactory] = [:]
    private var descriptorOrder: [ProviderID] = []
    private var adapters: [ProviderID: any PlatformAdapter] = [:]
    private var sessions: [ProviderID: SessionContext] = [:]
    private var sessionStates: [ProviderID: SessionState] = [:]
    private var fullSnapshots: [ProviderID: SessionSnapshot] = [:]
    private var snapshotContinuations: [UUID: AsyncStream<(ProviderID, SessionSnapshot)>.Continuation] = [:]
    private var generations: [ProviderID: UInt64] = [:]

    public private(set) var browsingProviderID: ProviderID?
    private var isShutDown: Bool = false

    public init(initialFactories: [any PlatformAdapterFactory] = []) {
        for factory in initialFactories {
            let id = factory.descriptor.providerID
            if factories[id] == nil {
                descriptorOrder.append(id)
            }
            factories[id] = factory
            sessionStates[id] = .signedOut
            generations[id] = 0
            if browsingProviderID == nil && factory.descriptor.isAvailableInProduction {
                browsingProviderID = id
            }
        }
    }

    // MARK: - Registration (Zero side effects)

    public func register(factory: any PlatformAdapterFactory) {
        let id = factory.descriptor.providerID
        if factories[id] == nil {
            descriptorOrder.append(id)
        }
        factories[id] = factory
        if sessionStates[id] == nil {
            sessionStates[id] = .signedOut
        }
        if generations[id] == nil {
            generations[id] = 0
        }
        if browsingProviderID == nil && factory.descriptor.isAvailableInProduction {
            browsingProviderID = id
        }
    }

    public func registeredDescriptors(includeNonProduction: Bool = false) -> [PlatformDescriptor] {
        descriptorOrder.compactMap { id in
            guard let desc = factories[id]?.descriptor else { return nil }
            if !includeNonProduction && !desc.isAvailableInProduction {
                return nil
            }
            return desc
        }
    }

    public func descriptor(for providerID: ProviderID) -> PlatformDescriptor? {
        factories[providerID]?.descriptor
    }

    public func isActivated(_ providerID: ProviderID) -> Bool {
        adapters[providerID] != nil
    }

    // MARK: - Browsing Context (Independent of Playback)

    public func setBrowsingProvider(_ providerID: ProviderID?) {
        guard let providerID else {
            browsingProviderID = nil
            return
        }
        guard factories[providerID] != nil else { return }
        browsingProviderID = providerID
    }

    // MARK: - Lazy Activation & Session Management

    public func activate(providerID: ProviderID) async throws -> any PlatformAdapter {
        guard !isShutDown else {
            throw CoreError.engineUnavailable("Platform registry is shut down")
        }
        if let existing = adapters[providerID] {
            return existing
        }
        guard let factory = factories[providerID] else {
            throw CoreError.unsupported("Provider \(providerID.rawValue) is not registered")
        }
        let adapter = await factory.makeAdapter()
        adapters[providerID] = adapter
        return adapter
    }

    public func adapterIfActivated(for providerID: ProviderID) -> (any PlatformAdapter)? {
        adapters[providerID]
    }

    public func updateSession(
        for providerID: ProviderID,
        accountID: String,
        storefront: String,
        state: SessionState
    ) -> SessionContext {
        let nextGen = (generations[providerID] ?? 0) &+ 1
        generations[providerID] = nextGen
        let ctx = SessionContext(
            providerID: providerID.rawValue,
            accountID: accountID,
            storefront: storefront,
            sessionID: UUID(),
            generation: nextGen
        )
        sessions[providerID] = ctx
        sessionStates[providerID] = state
        return ctx
    }

    public func sessionContext(for providerID: ProviderID) -> SessionContext? {
        sessions[providerID]
    }

    public func sessionGeneration(for providerID: ProviderID) -> UInt64 {
        generations[providerID] ?? 0
    }

    public func publishSessionSnapshot(_ snapshot: SessionSnapshot, for providerID: ProviderID) {
        if let ctx = snapshot.context {
            sessions[providerID] = ctx
            generations[providerID] = ctx.generation
        } else {
            sessions.removeValue(forKey: providerID)
        }
        sessionStates[providerID] = snapshot.sessionState
        fullSnapshots[providerID] = snapshot
        for c in snapshotContinuations.values {
            c.yield((providerID, snapshot))
        }
    }

    public func sessionSnapshots() -> AsyncStream<(ProviderID, SessionSnapshot)> {
        AsyncStream(bufferingPolicy: .bufferingNewest(16)) { continuation in
            let id = UUID()
            snapshotContinuations[id] = continuation
            for (pid, snap) in fullSnapshots {
                continuation.yield((pid, snap))
            }
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeSnapshotContinuation(id: id) }
            }
        }
    }

    private func removeSnapshotContinuation(id: UUID) {
        snapshotContinuations.removeValue(forKey: id)
    }

    public func sessionRecord(for providerID: ProviderID) -> ProviderSessionRecord? {
        guard let desc = factories[providerID]?.descriptor else { return nil }
        return ProviderSessionRecord(
            descriptor: desc,
            sessionContext: sessions[providerID],
            sessionState: sessionStates[providerID] ?? .signedOut,
            isActivated: adapters[providerID] != nil
        )
    }

    public func signOut(providerID: ProviderID) async {
        let nextGen = (generations[providerID] ?? 0) &+ 1
        generations[providerID] = nextGen
        sessions.removeValue(forKey: providerID)
        sessionStates[providerID] = .signedOut
        if let adapter = adapters[providerID] {
            try? await adapter.authProvider?.signOut()
        }
    }

    public func shutdownAll() async {
        guard !isShutDown else { return }
        isShutDown = true
        for id in adapters.keys {
            let nextGen = (generations[id] ?? 0) &+ 1
            generations[id] = nextGen
        }
        adapters.removeAll()
        sessions.removeAll()
    }
}
