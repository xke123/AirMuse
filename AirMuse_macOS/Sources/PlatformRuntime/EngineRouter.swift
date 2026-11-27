import Foundation
import Domain
import Infrastructure

// MARK: - EngineRouter

/// Single-audio-ownership router coordinating `PlaybackEngineProtocol` instances across platforms.
/// Guarantees at most one active audio engine at any moment, silent candidate preparation,
/// explicit stop/isolation barriers before lease transfer, and generation-isolated event forwarding.
public actor EngineRouter: PlaybackEngineRouterProtocol, DiagnosticSnapshotProvider {
    public nonisolated var componentName: String { "EngineRouter" }

    public func captureDiagnosticSnapshot() async -> DiagnosticComponentSnapshot {
        DiagnosticComponentSnapshot(
            component: componentName,
            ownerRevision: routingGeneration,
            scopeRef: activeProviderID?.rawValue,
            availability: .available,
            data: [
                "activeAudioCount": .int(activeEngine != nil ? 1 : 0),
                "activeEngineID": activeEngineID.map { .string($0.uuidString) } ?? .absent,
                "activeProviderID": activeProviderID.map { .string($0.rawValue) } ?? .absent,
                "candidateCount": .int(candidateEngines.count),
                "handoffState": .string(String(describing: handoffState)),
                "routingGeneration": .uint64(routingGeneration)
            ]
        )
    }
    public enum HandoffState: Sendable, Equatable {
        case idle
        case preparingCandidate(UUID)
        case quiescingOld(UUID)
        case transferringLease(UUID)
        case active(UUID)
        case failed(String)
    }

    private let registry: ProviderSessionRegistry
    private var activeProviderID: ProviderID?
    private var activeEngine: (any PlaybackEngineProtocol)?
    private var activeEngineID: UUID?
    private var routingGeneration: UInt64 = 0
    private var candidateEngines: [UUID: (providerID: ProviderID, engine: any PlaybackEngineProtocol)] = [:]
    private var activeEventTask: Task<Void, Never>?
    private var continuations: [UUID: AsyncStream<EngineEvent>.Continuation] = [:]
    public private(set) var handoffState: HandoffState = .idle

    private let fallbackEngineID = UUID()

    public init(registry: ProviderSessionRegistry) {
        self.registry = registry
    }

    public var engineInstanceID: UUID {
        get async {
            activeEngineID ?? fallbackEngineID
        }
    }

    public var currentRoutingGeneration: UInt64 {
        routingGeneration
    }

    public func events() async -> AsyncStream<EngineEvent> {
        AsyncStream(bufferingPolicy: .bufferingNewest(64)) { continuation in
            let id = UUID()
            continuations[id] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeContinuation(id: id) }
            }
        }
    }

    private func removeContinuation(id: UUID) {
        continuations.removeValue(forKey: id)
    }

    private func broadcast(_ event: EngineEvent) {
        for continuation in continuations.values {
            continuation.yield(event)
        }
    }

    // MARK: - Candidate Preparation & Atomic Lease Handoff

    public func prepareCandidate(
        target: PlaybackTarget,
        sessionContext: SessionContext,
        deadlineSeconds: TimeInterval
    ) async throws -> UUID {
        let targetProvider = target.providerID.isUnknown
            ? ProviderID(rawValue: sessionContext.providerID)
            : target.providerID
        let switchRef = UUID().uuidString
        let fromProvider = activeProviderID?.rawValue ?? "absent"
        guard !targetProvider.isUnknown else {
            throw CoreError.unsupported("Cannot prepare engine for unknown provider")
        }

        let adapter = try await registry.activate(providerID: targetProvider)
        guard let candidateEngine = await adapter.makePlaybackEngine() else {
            throw CoreError.engineUnavailable("Provider \(targetProvider.rawValue) has no playback engine")
        }

        let candidateID = await candidateEngine.engineInstanceID
        candidateEngines[candidateID] = (providerID: targetProvider, engine: candidateEngine)
        handoffState = .preparingCandidate(candidateID)

        AppLogger.shared.emit(
            eventName: "engine.switch.requested",
            category: "ENGINE_ROUTER",
            level: .info,
            phase: .begin,
            source: DiagnosticSourceLocation(module: "PlatformRuntime", component: "EngineRouter", function: "prepareCandidate"),
            payload: {
                DiagnosticEventPayload(
                    context: DiagnosticContext(providerID: targetProvider.rawValue, candidateEngineID: candidateID, routingGeneration: routingGeneration, switchRef: switchRef),
                    fields: ["fromProvider": .string(fromProvider), "toProvider": .string(targetProvider.rawValue)],
                    message: "Engine switch requested (\(fromProvider) -> \(targetProvider.rawValue))"
                )
            }
        )
        AppLogger.shared.emit(
            eventName: "engine.switch.preparing",
            category: "ENGINE_ROUTER",
            level: .debug,
            source: DiagnosticSourceLocation(module: "PlatformRuntime", component: "EngineRouter", function: "prepareCandidate"),
            payload: {
                DiagnosticEventPayload(
                    context: DiagnosticContext(candidateEngineID: candidateID, routingGeneration: routingGeneration, switchRef: switchRef),
                    fields: ["deadlineMs": .double(deadlineSeconds * 1000.0)],
                    message: "Preparing silent candidate engine"
                )
            }
        )

        do {
            try await candidateEngine.prepare(sessionContext: sessionContext, deadlineSeconds: deadlineSeconds)
            AppLogger.shared.emit(
                eventName: "engine.candidate.prepared",
                category: "ENGINE_ROUTER",
                level: .info,
                outcome: .confirmed,
                source: DiagnosticSourceLocation(module: "PlatformRuntime", component: "EngineRouter", function: "prepareCandidate"),
                payload: {
                    DiagnosticEventPayload(
                        context: DiagnosticContext(providerID: targetProvider.rawValue, candidateEngineID: candidateID, routingGeneration: routingGeneration, switchRef: switchRef),
                        fields: ["evidence": .string("prepare_returned")],
                        message: "Candidate engine prepared"
                    )
                }
            )
            return candidateID
        } catch {
            candidateEngines.removeValue(forKey: candidateID)
            await candidateEngine.isolateAndReset()
            if activeEngineID != nil {
                handoffState = .active(activeEngineID!)
            } else {
                handoffState = .idle
            }
            AppLogger.shared.emit(
                eventName: "engine.switch.prepare_failed",
                category: "ENGINE_ROUTER",
                level: .error,
                outcome: .failed,
                source: DiagnosticSourceLocation(module: "PlatformRuntime", component: "EngineRouter", function: "prepareCandidate"),
                payload: {
                    DiagnosticEventPayload(
                        context: DiagnosticContext(providerID: targetProvider.rawValue, candidateEngineID: candidateID, routingGeneration: routingGeneration, switchRef: switchRef),
                        fields: ["oldEngineState": .string(String(describing: handoffState))],
                        error: LogSanitizer.sanitizeError(error, stage: "prepareCandidate"),
                        message: "Candidate engine prepare failed; old engine preserved"
                    )
                }
            )
            throw error
        }
    }

    public func activateCandidate(
        candidateEngineID: UUID,
        quiesceTimeoutSeconds: TimeInterval = 5.0
    ) async throws {
        guard candidateEngines[candidateEngineID] != nil else {
            AppLogger.shared.emit(
                eventName: "engine.switch.cancelled",
                category: "ENGINE_ROUTER",
                level: .info,
                outcome: .superseded,
                source: DiagnosticSourceLocation(module: "PlatformRuntime", component: "EngineRouter", function: "activateCandidate"),
                payload: {
                    DiagnosticEventPayload(
                        context: DiagnosticContext(candidateEngineID: candidateEngineID, routingGeneration: routingGeneration),
                        fields: ["reasonCode": .string("candidate_missing_or_superseded")],
                        message: "Engine switch cancelled: candidate missing"
                    )
                }
            )
            throw CoreError.superseded
        }

        if let currentID = activeEngineID, currentID != candidateEngineID {
            try await quiesceActiveEngine(timeoutSeconds: quiesceTimeoutSeconds)
        }

        // Re-verify candidate was not superseded while quiescing old engine.
        guard let verifiedCandidate = candidateEngines.removeValue(forKey: candidateEngineID) else {
            AppLogger.shared.emit(
                eventName: "engine.switch.cancelled",
                category: "ENGINE_ROUTER",
                level: .info,
                outcome: .superseded,
                source: DiagnosticSourceLocation(module: "PlatformRuntime", component: "EngineRouter", function: "activateCandidate"),
                payload: {
                    DiagnosticEventPayload(
                        context: DiagnosticContext(candidateEngineID: candidateEngineID, routingGeneration: routingGeneration),
                        fields: ["reasonCode": .string("superseded_during_quiesce")],
                        message: "Engine switch cancelled during quiesce"
                    )
                }
            )
            throw CoreError.superseded
        }

        handoffState = .transferringLease(candidateEngineID)
        routingGeneration &+= 1
        let expectedGen = routingGeneration
        let leaseRef = "lease-\(expectedGen)-\(candidateEngineID.uuidString.prefix(8))"

        activeEventTask?.cancel()
        activeEngine = verifiedCandidate.engine
        activeEngineID = candidateEngineID
        activeProviderID = verifiedCandidate.providerID
        handoffState = .active(candidateEngineID)

        AppLogger.shared.emit(
            eventName: "audio.ownership.acquired",
            category: "ENGINE_ROUTER",
            level: .notice,
            outcome: .confirmed,
            source: DiagnosticSourceLocation(module: "PlatformRuntime", component: "EngineRouter", function: "activateCandidate"),
            payload: {
                DiagnosticEventPayload(
                    context: DiagnosticContext(providerID: verifiedCandidate.providerID.rawValue, engineInstanceID: candidateEngineID, routingGeneration: expectedGen, leaseRef: leaseRef),
                    fields: ["newEngineID": .string(candidateEngineID.uuidString)],
                    message: "Audio ownership acquired by \(verifiedCandidate.providerID.rawValue)"
                )
            }
        )
        AppLogger.shared.emit(
            eventName: "engine.switch.completed",
            category: "ENGINE_ROUTER",
            level: .info,
            phase: .end,
            outcome: .succeeded,
            source: DiagnosticSourceLocation(module: "PlatformRuntime", component: "EngineRouter", function: "activateCandidate"),
            payload: {
                DiagnosticEventPayload(
                    context: DiagnosticContext(providerID: verifiedCandidate.providerID.rawValue, engineInstanceID: candidateEngineID, routingGeneration: expectedGen, leaseRef: leaseRef),
                    fields: ["newEngineID": .string(candidateEngineID.uuidString)],
                    message: "Engine switch completed (gen=\(expectedGen))"
                )
            }
        )

        let stream = await verifiedCandidate.engine.events()
        activeEventTask = Task { [weak self] in
            for await event in stream {
                guard let self, !Task.isCancelled else { break }
                await self.forwardIfActive(event, fromEngineID: candidateEngineID, expectedGen: expectedGen)
            }
        }
    }

    private func forwardIfActive(_ event: EngineEvent, fromEngineID: UUID, expectedGen: UInt64) {
        guard activeEngineID == fromEngineID, routingGeneration == expectedGen else {
            AppLogger.shared.emit(
                eventName: "engine.route.event_discarded",
                category: "ENGINE_ROUTER",
                level: .debug,
                outcome: .discarded,
                source: DiagnosticSourceLocation(module: "PlatformRuntime", component: "EngineRouter", function: "forwardIfActive"),
                payload: {
                    DiagnosticEventPayload(
                        context: DiagnosticContext(engineInstanceID: activeEngineID, routingGeneration: routingGeneration),
                        fields: [
                            "receivedGeneration": .uint64(expectedGen),
                            "expectedGeneration": .uint64(routingGeneration),
                            "receivedEngineID": .string(fromEngineID.uuidString),
                            "reasonCode": .string("stale_engine_or_generation")
                        ],
                        message: "Discarded stale engine event (gen \(expectedGen) != \(routingGeneration))"
                    )
                }
            )
            return
        }
        broadcast(event)
    }

    public func quiesceActiveEngine(timeoutSeconds: TimeInterval = 5.0) async throws {
        guard let oldEngine = activeEngine, let oldID = activeEngineID else {
            return
        }
        handoffState = .quiescingOld(oldID)
        activeEventTask?.cancel()
        activeEventTask = nil
        routingGeneration &+= 1

        AppLogger.shared.emit(
            eventName: "audio.ownership.release_requested",
            category: "ENGINE_ROUTER",
            level: .info,
            source: DiagnosticSourceLocation(module: "PlatformRuntime", component: "EngineRouter", function: "quiesceActiveEngine"),
            payload: {
                DiagnosticEventPayload(
                    context: DiagnosticContext(engineInstanceID: oldID, routingGeneration: routingGeneration),
                    fields: ["oldEngineID": .string(oldID.uuidString)],
                    message: "Requested audio ownership release from \(oldID.uuidString.prefix(8))"
                )
            }
        )

        let stopContext = PlaybackOperationContext(
            sessionID: UUID(),
            engineInstanceID: oldID,
            operationID: routingGeneration,
            trackID: ""
        )
        do {
            try await oldEngine.execute(.stop, context: stopContext)
            await oldEngine.isolateAndReset()
            activeEngine = nil
            activeEngineID = nil
            activeProviderID = nil
            handoffState = .idle
            AppLogger.shared.emit(
                eventName: "audio.ownership.release_confirmed",
                category: "ENGINE_ROUTER",
                level: .notice,
                outcome: .confirmed,
                source: DiagnosticSourceLocation(module: "PlatformRuntime", component: "EngineRouter", function: "quiesceActiveEngine"),
                payload: {
                    DiagnosticEventPayload(
                        context: DiagnosticContext(engineInstanceID: oldID, routingGeneration: routingGeneration),
                        fields: [
                            "oldEngineID": .string(oldID.uuidString),
                            "evidence": .string("stop_and_isolate_completed"),
                            "confirmationLevel": .string("engine_confirmed")
                        ],
                        message: "Audio ownership release confirmed (not claiming physical silence)"
                    )
                }
            )
        } catch {
            handoffState = .failed("无法确认旧音频已停止: \(error.localizedDescription)")
            AppLogger.shared.emit(
                eventName: "audio.ownership.release_failed",
                category: "ENGINE_ROUTER",
                level: .error,
                outcome: .failed,
                source: DiagnosticSourceLocation(module: "PlatformRuntime", component: "EngineRouter", function: "quiesceActiveEngine"),
                payload: {
                    DiagnosticEventPayload(
                        context: DiagnosticContext(engineInstanceID: oldID, routingGeneration: routingGeneration),
                        fields: ["oldEngineID": .string(oldID.uuidString)],
                        error: LogSanitizer.sanitizeError(error, stage: "quiesceActiveEngine"),
                        message: "Audio ownership release failed; blocking new engine activation"
                    )
                }
            )
            throw CoreError.handoffFailed("无法确认旧音频已停止: \(error.localizedDescription)")
        }
    }

    /// Cancels and releases a prepared candidate that is no longer needed (e.g. superseded by a newer intent).
    public func discardCandidate(candidateEngineID: UUID) async {
        if let entry = candidateEngines.removeValue(forKey: candidateEngineID) {
            await entry.engine.isolateAndReset()
            AppLogger.shared.emit(
                eventName: "engine.candidate.discarded",
                category: "ENGINE_ROUTER",
                level: .info,
                outcome: .discarded,
                source: DiagnosticSourceLocation(module: "PlatformRuntime", component: "EngineRouter", function: "discardCandidate"),
                payload: {
                    DiagnosticEventPayload(
                        context: DiagnosticContext(providerID: entry.providerID.rawValue, candidateEngineID: candidateEngineID, routingGeneration: routingGeneration),
                        fields: ["reasonCode": .string("superseded_candidate")],
                        message: "Discarded and isolated candidate engine"
                    )
                }
            )
        }
    }

    // MARK: - PlaybackEngineProtocol

    public func prepare(sessionContext: SessionContext, deadlineSeconds: TimeInterval) async throws {
        let targetProvider = ProviderID(rawValue: sessionContext.providerID)
        let target = PlaybackTarget(
            kind: .song,
            providerResourceID: "",
            providerID: targetProvider,
            scope: .catalog(region: sessionContext.storefront),
            storefront: sessionContext.storefront
        )
        if let currentID = activeEngineID,
           let currentProvider = activeProviderID,
           currentProvider == targetProvider,
           let engine = activeEngine {
            try await engine.prepare(sessionContext: sessionContext, deadlineSeconds: deadlineSeconds)
            _ = currentID
            return
        }
        let candidateID = try await prepareCandidate(target: target, sessionContext: sessionContext, deadlineSeconds: deadlineSeconds)
        try await activateCandidate(candidateEngineID: candidateID)
    }

    public func execute(_ command: EngineCommand, context: PlaybackOperationContext) async throws {
        guard let engine = activeEngine else {
            throw CoreError.engineUnavailable("没有活动的播放引擎")
        }
        let targetID = await engine.engineInstanceID
        let forwardContext = PlaybackOperationContext(
            sessionID: context.sessionID,
            engineInstanceID: targetID,
            operationID: context.operationID,
            trackID: context.trackID
        )
        try await engine.execute(command, context: forwardContext)
    }

    public func isolateAndReset() async {
        activeEventTask?.cancel()
        activeEventTask = nil
        routingGeneration &+= 1
        if let engine = activeEngine {
            await engine.isolateAndReset()
        }
        for (_, entry) in candidateEngines {
            await entry.engine.isolateAndReset()
        }
        candidateEngines.removeAll()
        activeEngine = nil
        activeEngineID = nil
        activeProviderID = nil
        handoffState = .idle
    }
}
