import Foundation
import Domain
import Infrastructure

// MARK: - EngineRouter

/// Single-audio-ownership router coordinating `PlaybackEngineProtocol` instances across platforms.
/// Guarantees at most one active audio engine at any moment, silent candidate preparation,
/// explicit stop/isolation barriers before lease transfer, and generation-isolated event forwarding.
public actor EngineRouter: PlaybackEngineRouterProtocol {
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

        do {
            try await candidateEngine.prepare(sessionContext: sessionContext, deadlineSeconds: deadlineSeconds)
            return candidateID
        } catch {
            candidateEngines.removeValue(forKey: candidateID)
            await candidateEngine.isolateAndReset()
            if activeEngineID != nil {
                handoffState = .active(activeEngineID!)
            } else {
                handoffState = .idle
            }
            throw error
        }
    }

    public func activateCandidate(
        candidateEngineID: UUID,
        quiesceTimeoutSeconds: TimeInterval = 5.0
    ) async throws {
        guard candidateEngines[candidateEngineID] != nil else {
            throw CoreError.superseded
        }

        if let currentID = activeEngineID, currentID != candidateEngineID {
            try await quiesceActiveEngine(timeoutSeconds: quiesceTimeoutSeconds)
        }

        // Re-verify candidate was not superseded while quiescing old engine.
        guard let verifiedCandidate = candidateEngines.removeValue(forKey: candidateEngineID) else {
            throw CoreError.superseded
        }

        handoffState = .transferringLease(candidateEngineID)
        routingGeneration &+= 1
        let expectedGen = routingGeneration

        activeEventTask?.cancel()
        activeEngine = verifiedCandidate.engine
        activeEngineID = candidateEngineID
        activeProviderID = verifiedCandidate.providerID
        handoffState = .active(candidateEngineID)

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
        } catch {
            handoffState = .failed("无法确认旧音频已停止: \(error.localizedDescription)")
            throw CoreError.handoffFailed("无法确认旧音频已停止: \(error.localizedDescription)")
        }
    }

    /// Cancels and releases a prepared candidate that is no longer needed (e.g. superseded by a newer intent).
    public func discardCandidate(candidateEngineID: UUID) async {
        if let entry = candidateEngines.removeValue(forKey: candidateEngineID) {
            await entry.engine.isolateAndReset()
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
