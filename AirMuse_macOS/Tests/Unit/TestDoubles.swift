import Foundation
import Domain
import Infrastructure

// MARK: - TestClock

public final class TestClock: ClockProtocol, @unchecked Sendable {
    private let lock = NSLock()
    private var _now: Date
    private var _monoNs: UInt64
    private var sleepers: [(id: UUID, wakeNs: UInt64, cont: CheckedContinuation<Void, Error>)] = []

    public init(now: Date = Date(timeIntervalSince1970: 1_700_000_000), monotonicNanoseconds: UInt64 = 1_000_000_000) {
        self._now = now
        self._monoNs = monotonicNanoseconds
    }

    public var now: Date {
        lock.lock()
        defer { lock.unlock() }
        return _now
    }

    public var monotonicNanoseconds: UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return _monoNs
    }

    public func advance(seconds: TimeInterval) {
        let deltaNs = UInt64(max(0, seconds) * 1_000_000_000)
        var toWake: [CheckedContinuation<Void, Error>] = []

        lock.lock()
        _now = _now.addingTimeInterval(seconds)
        _monoNs &+= deltaNs
        let current = _monoNs
        var remaining: [(id: UUID, wakeNs: UInt64, cont: CheckedContinuation<Void, Error>)] = []
        for s in sleepers {
            if s.wakeNs <= current {
                toWake.append(s.cont)
            } else {
                remaining.append(s)
            }
        }
        sleepers = remaining
        lock.unlock()

        for cont in toWake {
            cont.resume()
        }
    }

    public func sleep(for duration: Duration) async throws {
        try Task.checkCancellation()
        let comps = duration.components
        let ns = UInt64(max(0, comps.seconds)) * 1_000_000_000 &+ UInt64(max(0, comps.attoseconds) / 1_000_000_000)
        if ns == 0 { return }

        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                lock.lock()
                if Task.isCancelled {
                    lock.unlock()
                    cont.resume(throwing: CancellationError())
                    return
                }
                let wake = _monoNs &+ ns
                sleepers.append((id: id, wakeNs: wake, cont: cont))
                lock.unlock()
            }
        } onCancel: {
            lock.lock()
            var cancelled: CheckedContinuation<Void, Error>?
            if let idx = sleepers.firstIndex(where: { $0.id == id }) {
                cancelled = sleepers.remove(at: idx).cont
            }
            lock.unlock()
            cancelled?.resume(throwing: CancellationError())
        }
    }
}

// MARK: - MockHTTPTransport

public actor MockHTTPTransport: HTTPTransportProtocol {
    public typealias Handler = @Sendable (HTTPRequest, TimeInterval, Int) async throws -> HTTPResponse

    public private(set) var recordedRequests: [HTTPRequest] = []
    public private(set) var callCount: Int = 0
    private var handler: Handler

    public init(handler: @escaping Handler) {
        self.handler = handler
    }

    public func setHandler(_ newHandler: @escaping Handler) {
        self.handler = newHandler
    }

    public func send(_ request: HTTPRequest, timeoutSeconds: TimeInterval) async throws -> HTTPResponse {
        callCount += 1
        let index = callCount
        recordedRequests.append(request)
        return try await handler(request, timeoutSeconds, index)
    }
}

// MARK: - FailingSecureStore

public final class FailingSecureStore: SecureKeyValueStore, @unchecked Sendable {
    public var storage: [String: String] = [:]
    public var failOnLoad: Error?
    public var failOnSave: Error?
    public var failOnDelete: Error?
    private let lock = NSLock()

    public init() {}

    public func save(_ value: String, forKey key: String) throws {
        lock.lock()
        defer { lock.unlock() }
        if let err = failOnSave { throw err }
        storage[key] = value
    }

    public func load(key: String) throws -> String {
        lock.lock()
        defer { lock.unlock() }
        if let err = failOnLoad { throw err }
        guard let val = storage[key] else { throw KeychainError.itemNotFound }
        return val
    }

    public func delete(key: String) throws {
        lock.lock()
        defer { lock.unlock() }
        if let err = failOnDelete { throw err }
        storage.removeValue(forKey: key)
    }

    public func exists(key: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return storage[key] != nil
    }
}

// MARK: - InMemoryCredentialVault

public actor InMemoryCredentialVault: CredentialVaultProtocol {
    private var records: [String: CredentialRecord] = [:]

    public init() {}

    public func load(providerID: String, accountID: String?, kind: CredentialKind) async throws -> CredentialRecord? {
        records[CredentialVault.storageKey(providerID: providerID, accountID: accountID, kind: kind)]
    }

    public func save(_ record: CredentialRecord, providerID: String, accountID: String?) async throws {
        records[CredentialVault.storageKey(providerID: providerID, accountID: accountID, kind: record.kind)] = record
    }

    public func delete(providerID: String, accountID: String?, kind: CredentialKind) async throws {
        records.removeValue(forKey: CredentialVault.storageKey(providerID: providerID, accountID: accountID, kind: kind))
    }

    public func clearAccountCredentials(providerID: String, accountID: String) async throws {
        try await delete(providerID: providerID, accountID: accountID, kind: .user)
    }
}

// MARK: - MockPlaybackEngine

public actor MockPlaybackEngine: PlaybackEngineProtocol {
    public private(set) var currentEngineInstanceID = UUID()
    public private(set) var executedCommands: [(EngineCommand, PlaybackOperationContext)] = []
    private var continuations: [UUID: AsyncStream<EngineEvent>.Continuation] = [:]

    public init() {}

    public var engineInstanceID: UUID { currentEngineInstanceID }

    public func events() async -> AsyncStream<EngineEvent> {
        AsyncStream { cont in
            let id = UUID()
            continuations[id] = cont
            cont.onTermination = { [weak self] _ in
                Task { await self?.removeCont(id) }
            }
        }
    }

    private func removeCont(_ id: UUID) {
        continuations.removeValue(forKey: id)
    }

    public func emit(_ event: EngineEvent) {
        for cont in continuations.values {
            cont.yield(event)
        }
    }

    public func prepare(sessionContext: SessionContext, deadlineSeconds: TimeInterval) async throws {
        emit(.readinessChanged(engineInstanceID: currentEngineInstanceID, isReady: true, isAuthorized: true))
    }

    public func execute(_ command: EngineCommand, context: PlaybackOperationContext) async throws {
        executedCommands.append((command, context))
    }

    public func isolateAndReset() async {
        currentEngineInstanceID = UUID()
    }
}
