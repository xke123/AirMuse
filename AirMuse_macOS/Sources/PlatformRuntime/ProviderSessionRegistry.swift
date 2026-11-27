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
public actor ProviderSessionRegistry: DiagnosticSnapshotProvider {
    public nonisolated var componentName: String { "ProviderSessionRegistry" }

    public func captureDiagnosticSnapshot() async -> DiagnosticComponentSnapshot {
        DiagnosticComponentSnapshot(
            component: componentName,
            scopeRef: browsingProviderID?.rawValue,
            availability: .available,
            data: [
                "registeredCount": .int(descriptorOrder.count),
                "activatedCount": .int(adapters.count),
                "browsingProviderID": browsingProviderID.map { .string($0.rawValue) } ?? .absent,
                "subscriberCount": .int(snapshotContinuations.count),
                "isShutDown": .bool(isShutDown)
            ]
        )
    }
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
        if factories[id] != nil {
            AppLogger.shared.emit(
                eventName: "platform.registration.rejected",
                category: "PLATFORM",
                level: .warn,
                outcome: .rejected,
                source: DiagnosticSourceLocation(module: "PlatformRuntime", component: "ProviderSessionRegistry", function: "register"),
                payload: {
                    DiagnosticEventPayload(
                        context: DiagnosticContext(providerID: id.rawValue),
                        fields: ["reasonCode": .string("duplicate_provider")],
                        message: "Rejected duplicate provider registration: \(id.rawValue)"
                    )
                }
            )
            return
        }
        descriptorOrder.append(id)
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
        AppLogger.shared.emit(
            eventName: "platform.registered",
            category: "PLATFORM",
            level: .info,
            outcome: .succeeded,
            source: DiagnosticSourceLocation(module: "PlatformRuntime", component: "ProviderSessionRegistry", function: "register"),
            payload: {
                DiagnosticEventPayload(
                    context: DiagnosticContext(providerID: id.rawValue),
                    fields: [
                        "descriptorRef": .string(id.rawValue),
                        "isProduction": .bool(factory.descriptor.isAvailableInProduction)
                    ],
                    message: "Registered platform \(id.rawValue)"
                )
            }
        )
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
        let previous = browsingProviderID
        guard let providerID else {
            browsingProviderID = nil
            return
        }
        guard factories[providerID] != nil else { return }
        browsingProviderID = providerID
        if previous != providerID {
            AppLogger.shared.emit(
                eventName: "platform.browse.changed",
                category: "PLATFORM",
                level: .info,
                outcome: .confirmed,
                source: DiagnosticSourceLocation(module: "PlatformRuntime", component: "ProviderSessionRegistry", function: "setBrowsingProvider"),
                payload: {
                    DiagnosticEventPayload(
                        context: DiagnosticContext(browsingProviderID: providerID.rawValue),
                        fields: [
                            "previousProvider": .string(previous?.rawValue ?? "absent"),
                            "nextProvider": .string(providerID.rawValue)
                        ],
                        message: "Browsing provider changed: \(previous?.rawValue ?? "none") -> \(providerID.rawValue)"
                    )
                }
            )
        }
    }

    // MARK: - Lazy Activation & Session Management

    public func activate(providerID: ProviderID) async throws -> any PlatformAdapter {
        let activationRef = UUID().uuidString
        let gen = generations[providerID] ?? 0
        let span = AppLogger.shared.beginSpan(
            eventName: "platform.activation.requested",
            category: "PLATFORM",
            level: .info,
            context: DiagnosticContext(providerID: providerID.rawValue, sessionGeneration: gen),
            fields: ["activationRef": .string(activationRef), "reason": .string("on_demand")],
            source: DiagnosticSourceLocation(module: "PlatformRuntime", component: "ProviderSessionRegistry", function: "activate"),
            message: "Activation requested for \(providerID.rawValue)"
        )
        guard !isShutDown else {
            let err = CoreError.engineUnavailable("Platform registry is shut down")
            AppLogger.shared.endSpan(span, endEventName: "platform.activation.failed", outcome: .failed, error: LogSanitizer.sanitizeError(err, stage: "activate"), message: "Registry is shut down")
            throw err
        }
        if let existing = adapters[providerID] {
            AppLogger.shared.endSpan(span, endEventName: "platform.activation.reused", outcome: .succeeded, fields: ["activationRef": .string(activationRef), "adapterRef": .string(providerID.rawValue)], message: "Reused activated adapter for \(providerID.rawValue)")
            return existing
        }
        guard let factory = factories[providerID] else {
            let err = CoreError.unsupported("Provider \(providerID.rawValue) is not registered")
            AppLogger.shared.endSpan(span, endEventName: "platform.activation.failed", outcome: .unsupported, error: LogSanitizer.sanitizeError(err, stage: "activate"), message: "Provider not registered")
            throw err
        }
        let adapter = await factory.makeAdapter()
        adapters[providerID] = adapter
        AppLogger.shared.endSpan(span, endEventName: "platform.activation.completed", outcome: .succeeded, fields: ["activationRef": .string(activationRef), "adapterRef": .string(providerID.rawValue)], message: "Activated adapter for \(providerID.rawValue)")
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
        let prevGen = generations[providerID] ?? 0
        let prevState = sessionStates[providerID] ?? .signedOut
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
        let newGen = generations[providerID] ?? prevGen
        if newGen != prevGen {
            AppLogger.shared.emit(
                eventName: "session.generation.changed",
                category: "SESSION",
                level: .info,
                source: DiagnosticSourceLocation(module: "PlatformRuntime", component: "ProviderSessionRegistry", function: "publishSessionSnapshot"),
                payload: {
                    DiagnosticEventPayload(
                        context: DiagnosticContext(providerID: providerID.rawValue, sessionID: snapshot.context?.sessionID, sessionGeneration: newGen),
                        fields: ["previousGeneration": .uint64(prevGen), "nextGeneration": .uint64(newGen)],
                        message: "Session generation \(prevGen) -> \(newGen)"
                    )
                }
            )
        }
        if prevState != snapshot.sessionState {
            AppLogger.shared.emit(
                eventName: "session.state.changed",
                category: "SESSION",
                level: .info,
                source: DiagnosticSourceLocation(module: "PlatformRuntime", component: "ProviderSessionRegistry", function: "publishSessionSnapshot"),
                payload: {
                    DiagnosticEventPayload(
                        context: DiagnosticContext(providerID: providerID.rawValue, sessionID: snapshot.context?.sessionID, sessionGeneration: newGen),
                        fields: ["before": .string(String(describing: prevState)), "after": .string(String(describing: snapshot.sessionState)), "reasonCode": .string("snapshot_published")],
                        message: "Session state changed for \(providerID.rawValue)"
                    )
                }
            )
        }
        AppLogger.shared.emit(
            eventName: "session.snapshot.published",
            category: "SESSION",
            level: .debug,
            source: DiagnosticSourceLocation(module: "PlatformRuntime", component: "ProviderSessionRegistry", function: "publishSessionSnapshot"),
            payload: {
                DiagnosticEventPayload(
                    context: DiagnosticContext(providerID: providerID.rawValue, sessionID: snapshot.context?.sessionID, sessionGeneration: newGen),
                    fields: ["subscriberCount": .int(snapshotContinuations.count)],
                    message: "Published session snapshot to \(snapshotContinuations.count) subscribers"
                )
            }
        )
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
        let count = adapters.count
        for id in adapters.keys {
            let nextGen = (generations[id] ?? 0) &+ 1
            generations[id] = nextGen
            AppLogger.shared.emit(
                eventName: "platform.deactivated",
                category: "PLATFORM",
                level: .notice,
                outcome: .succeeded,
                source: DiagnosticSourceLocation(module: "PlatformRuntime", component: "ProviderSessionRegistry", function: "shutdownAll"),
                payload: {
                    DiagnosticEventPayload(
                        context: DiagnosticContext(providerID: id.rawValue, sessionGeneration: nextGen),
                        fields: ["reason": .string("shutdown"), "adapterRef": .string(id.rawValue)],
                        message: "Deactivated platform \(id.rawValue)"
                    )
                }
            )
        }
        adapters.removeAll()
        sessions.removeAll()
        AppLogger.shared.emit(
            eventName: "session.shutdown.completed",
            category: "SESSION",
            level: .notice,
            outcome: .succeeded,
            source: DiagnosticSourceLocation(module: "PlatformRuntime", component: "ProviderSessionRegistry", function: "shutdownAll"),
            payload: {
                DiagnosticEventPayload(
                    fields: ["releasedCount": .int(count)],
                    message: "ProviderSessionRegistry shutdown completed (released=\(count))"
                )
            }
        )
    }
}
