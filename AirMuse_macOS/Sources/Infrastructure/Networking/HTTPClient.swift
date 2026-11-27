import Foundation
import Domain

// MARK: - URLSessionHTTPTransport

public final class URLSessionHTTPTransport: HTTPTransportProtocol, Sendable {
    private let session: URLSession

    public init(configuration: URLSessionConfiguration = .ephemeral) {
        let cfg = configuration
        cfg.waitsForConnectivity = false
        cfg.httpCookieStorage = nil
        cfg.urlCache = nil
        self.session = URLSession(configuration: cfg)
    }

    public func send(_ request: HTTPRequest, timeoutSeconds: TimeInterval) async throws -> HTTPResponse {
        var urlRequest = URLRequest(url: request.url)
        urlRequest.httpMethod = request.method.rawValue
        urlRequest.timeoutInterval = max(0.5, timeoutSeconds)
        urlRequest.httpBody = request.body
        for (k, v) in request.headers {
            urlRequest.setValue(v, forHTTPHeaderField: k)
        }

        let (data, urlResponse) = try await session.data(for: urlRequest)
        guard let http = urlResponse as? HTTPURLResponse else {
            throw CoreError.transport(statusCode: nil, message: "Invalid HTTP response")
        }
        var headerMap: [String: String] = [:]
        for (k, v) in http.allHeaderFields {
            headerMap[String(describing: k)] = String(describing: v)
        }
        return HTTPResponse(
            statusCode: http.statusCode,
            headers: headerMap,
            data: data,
            url: http.url ?? request.url
        )
    }
}

// MARK: - HTTPClient

/// Actor-isolated HTTP client with single-flight request deduplication,
/// priority-aware bounded concurrency, total deadline enforcement, and typed error mapping.
public actor HTTPClient: DiagnosticSnapshotProvider {
    public nonisolated var componentName: String { "HTTPClient" }

    public func captureDiagnosticSnapshot() async -> DiagnosticComponentSnapshot {
        DiagnosticComponentSnapshot(
            component: componentName,
            availability: .available,
            data: [
                "activeCount": .int(activeCount),
                "maxConcurrentRequests": .int(maxConcurrentRequests),
                "queuedWaiters": .int(slotWaiters.count),
                "inFlightCoalescedKeys": .int(inFlight.count)
            ]
        )
    }
    private let transport: any HTTPTransportProtocol
    private let clock: any ClockProtocol
    private let maxConcurrentRequests: Int

    private var activeCount: Int = 0
    private var slotWaiters: [SlotWaiter] = []
    private var nextSequence: UInt64 = 0
    private var inFlight: [String: InFlightEntry] = [:]

    private struct SlotWaiter {
        let id: UUID
        let priority: RequestPriority
        let sequence: UInt64
        let continuation: CheckedContinuation<Void, Error>
    }

    private final class InFlightEntry {
        let ownerRequestID: UUID
        let ownerTrace: DiagnosticTraceContext
        var task: Task<HTTPResponse, Error>?
        var waiters: [UUID: CheckedContinuation<HTTPResponse, Error>] = [:]
        var consumerCount: Int = 1

        init(ownerRequestID: UUID, ownerTrace: DiagnosticTraceContext) {
            self.ownerRequestID = ownerRequestID
            self.ownerTrace = ownerTrace
        }
    }

    public init(
        transport: any HTTPTransportProtocol = URLSessionHTTPTransport(),
        clock: any ClockProtocol = SystemClock(),
        maxConcurrentRequests: Int = 6
    ) {
        self.transport = transport
        self.clock = clock
        self.maxConcurrentRequests = max(1, maxConcurrentRequests)
    }

    // MARK: - Public API

    public func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        try Task.checkCancellation()

        let requestID = UUID()
        let parentTrace = DiagnosticTrace.currentOrRoot()
        let reqTrace = parentTrace.childSpan(context: DiagnosticContext(requestID: requestID))
        let sanitizedURL = LogSanitizer.sanitizeURL(request.url)

        AppLogger.shared.emit(
            eventName: "http.request.created",
            category: "HTTP",
            level: .debug,
            phase: .begin,
            traceContext: reqTrace,
            source: DiagnosticSourceLocation(module: "Infrastructure", component: "HTTPClient", function: "send"),
            payload: {
                DiagnosticEventPayload(
                    context: DiagnosticContext(requestID: requestID),
                    fields: [
                        "method": .string(request.method.rawValue),
                        "hostClass": .string(sanitizedURL.hostClass),
                        "endpointTemplate": .string(sanitizedURL.endpointTemplate),
                        "timeoutMs": .double(request.policy.totalDeadlineSeconds * 1000.0)
                    ],
                    message: "HTTP \(request.method.rawValue) \(sanitizedURL.endpointTemplate)"
                )
            }
        )

        if !request.policy.deduplicate || request.policy.isSideEffecting {
            return try await executeWithDeadlineAndRetries(request, requestID: requestID, traceContext: reqTrace)
        }

        let key = Self.canonicalDeduplicationKey(for: request)
        let waiterID = UUID()

        let entry: InFlightEntry
        let isOwner: Bool
        if let existing = inFlight[key] {
            entry = existing
            entry.consumerCount += 1
            isOwner = false
            AppLogger.shared.emit(
                eventName: "http.request.coalesced",
                category: "HTTP",
                level: .debug,
                phase: .instant,
                traceContext: reqTrace,
                source: DiagnosticSourceLocation(module: "Infrastructure", component: "HTTPClient", function: "send"),
                payload: {
                    DiagnosticEventPayload(
                        context: DiagnosticContext(requestID: entry.ownerRequestID),
                        fields: [
                            "ownerRequestID": .string(entry.ownerRequestID.uuidString),
                            "consumerCount": .int(entry.consumerCount)
                        ],
                        links: [DiagnosticLink(traceID: entry.ownerTrace.traceID, spanID: entry.ownerTrace.spanID, relation: "coalescedFrom")],
                        message: "Coalesced into owner request \(entry.ownerRequestID.uuidString.prefix(8))"
                    )
                }
            )
        } else {
            let created = InFlightEntry(ownerRequestID: requestID, ownerTrace: reqTrace)
            inFlight[key] = created
            entry = created
            isOwner = true
        }

        if isOwner {
            entry.task = Task { [weak self] in
                guard let self else { throw CoreError.cancelled }
                do {
                    let response = try await self.executeWithDeadlineAndRetries(request, requestID: requestID, traceContext: reqTrace)
                    await self.finishInFlight(key: key, result: .success(response))
                    return response
                } catch {
                    await self.finishInFlight(key: key, result: .failure(error))
                    throw error
                }
            }
        }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if Task.isCancelled {
                    continuation.resume(throwing: CoreError.cancelled)
                    return
                }
                if let current = inFlight[key], current === entry {
                    entry.waiters[waiterID] = continuation
                } else {
                    continuation.resume(throwing: CoreError.cancelled)
                }
            }
        } onCancel: {
            Task {
                await self.cancelWaiter(key: key, waiterID: waiterID)
            }
        }
    }

    public func decode<T: Decodable>(_ type: T.Type, from request: HTTPRequest, decoder: JSONDecoder = JSONDecoder()) async throws -> T {
        let response = try await send(request)
        do {
            return try decoder.decode(T.self, from: response.data)
        } catch {
            throw CoreError.decode(error.localizedDescription)
        }
    }

    // MARK: - Deduplication Management

    private func finishInFlight(key: String, result: Result<HTTPResponse, Error>) {
        guard let entry = inFlight.removeValue(forKey: key) else { return }
        let waiters = entry.waiters
        entry.waiters.removeAll()
        for (_, cont) in waiters {
            cont.resume(with: result)
        }
    }

    private func cancelWaiter(key: String, waiterID: UUID) {
        guard let entry = inFlight[key] else { return }
        if let cont = entry.waiters.removeValue(forKey: waiterID) {
            cont.resume(throwing: CoreError.cancelled)
        }
        if entry.waiters.isEmpty {
            inFlight.removeValue(forKey: key)
            entry.task?.cancel()
        }
    }

    // MARK: - Bounded Concurrency & Priority Queue

    private func acquireSlot(priority: RequestPriority, requestID: UUID, traceContext: DiagnosticTraceContext) async throws {
        try Task.checkCancellation()
        if activeCount < maxConcurrentRequests {
            activeCount += 1
            return
        }

        let waiterID = UUID()
        nextSequence += 1
        let seq = nextSequence

        AppLogger.shared.emit(
            eventName: "http.request.queued",
            category: "HTTP",
            level: .debug,
            phase: .instant,
            traceContext: traceContext,
            source: DiagnosticSourceLocation(module: "Infrastructure", component: "HTTPClient", function: "acquireSlot"),
            payload: {
                DiagnosticEventPayload(
                    context: DiagnosticContext(requestID: requestID),
                    fields: ["pool": .string("http_default"), "queueDepth": .int(slotWaiters.count + 1)],
                    message: "HTTP request queued (depth=\(slotWaiters.count + 1))"
                )
            }
        )

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                if Task.isCancelled {
                    cont.resume(throwing: CoreError.cancelled)
                    return
                }
                slotWaiters.append(SlotWaiter(id: waiterID, priority: priority, sequence: seq, continuation: cont))
            }
        } onCancel: {
            Task {
                await self.cancelSlotWaiter(id: waiterID)
            }
        }
    }

    private func cancelSlotWaiter(id: UUID) {
        if let idx = slotWaiters.firstIndex(where: { $0.id == id }) {
            let waiter = slotWaiters.remove(at: idx)
            waiter.continuation.resume(throwing: CoreError.cancelled)
        }
    }

    private func releaseSlot() {
        if !slotWaiters.isEmpty {
            var bestIndex = 0
            for i in 1..<slotWaiters.count {
                let candidate = slotWaiters[i]
                let currentBest = slotWaiters[bestIndex]
                if candidate.priority > currentBest.priority ||
                    (candidate.priority == currentBest.priority && candidate.sequence < currentBest.sequence) {
                    bestIndex = i
                }
            }
            let next = slotWaiters.remove(at: bestIndex)
            next.continuation.resume()
        } else {
            activeCount = max(0, activeCount - 1)
        }
    }

    // MARK: - Deadline, Retry & Error Mapping

    private func executeWithDeadlineAndRetries(
        _ request: HTTPRequest,
        requestID: UUID,
        traceContext: DiagnosticTraceContext
    ) async throws -> HTTPResponse {
        let startNs = clock.monotonicNanoseconds
        let totalBudgetNs = UInt64(max(0.1, request.policy.totalDeadlineSeconds) * 1_000_000_000)
        let deadlineNs = startNs &+ totalBudgetNs
        let maxAttempts = request.policy.isSideEffecting ? 1 : max(1, request.policy.maxRetries + 1)
        let sanitizedURL = LogSanitizer.sanitizeURL(request.url)

        var lastError: CoreError = .timeout
        var attemptsUsed = 0

        func emitCompleted(outcome: DiagnosticOutcome, error: CoreError? = nil) {
            let endNs = clock.monotonicNanoseconds
            let durationMs = Double(endNs >= startNs ? endNs - startNs : 0) / 1_000_000.0
            AppLogger.shared.emit(
                eventName: "http.request.completed",
                category: "HTTP",
                level: outcome == .failed ? .error : .debug,
                phase: .end,
                outcome: outcome,
                durationMs: durationMs,
                traceContext: traceContext,
                source: DiagnosticSourceLocation(module: "Infrastructure", component: "HTTPClient", function: "executeWithDeadlineAndRetries"),
                payload: {
                    DiagnosticEventPayload(
                        context: DiagnosticContext(requestID: requestID, attempt: attemptsUsed),
                        fields: [
                            "attemptCount": .int(attemptsUsed),
                            "endpointTemplate": .string(sanitizedURL.endpointTemplate)
                        ],
                        error: error.map { LogSanitizer.sanitizeError($0, stage: "http") },
                        message: "HTTP \(request.method.rawValue) \(sanitizedURL.endpointTemplate) \(outcome.rawValue)"
                    )
                }
            )
        }

        for attempt in 0..<maxAttempts {
            attemptsUsed = attempt + 1
            if Task.isCancelled {
                AppLogger.shared.emit(
                    eventName: "http.request.cancelled",
                    category: "HTTP",
                    level: .info,
                    outcome: .cancelled,
                    traceContext: traceContext,
                    source: DiagnosticSourceLocation(module: "Infrastructure", component: "HTTPClient", function: "executeWithDeadlineAndRetries"),
                    payload: {
                        DiagnosticEventPayload(
                            context: DiagnosticContext(requestID: requestID, attempt: attemptsUsed),
                            fields: ["reasonCode": .string("task_cancelled"), "initiator": .string("caller")],
                            message: "HTTP request cancelled"
                        )
                    }
                )
                emitCompleted(outcome: .cancelled, error: .cancelled)
                throw CoreError.cancelled
            }

            let nowNs = clock.monotonicNanoseconds
            if nowNs >= deadlineNs {
                AppLogger.shared.emit(
                    eventName: "http.request.timeout",
                    category: "HTTP",
                    level: .warn,
                    outcome: .failed,
                    traceContext: traceContext,
                    source: DiagnosticSourceLocation(module: "Infrastructure", component: "HTTPClient", function: "executeWithDeadlineAndRetries"),
                    payload: {
                        DiagnosticEventPayload(
                            context: DiagnosticContext(requestID: requestID, attempt: attemptsUsed),
                            fields: ["stage": .string("total_deadline"), "deadlineMs": .double(request.policy.totalDeadlineSeconds * 1000.0)],
                            message: "HTTP request deadline exceeded"
                        )
                    }
                )
                emitCompleted(outcome: .failed, error: .timeout)
                throw CoreError.timeout
            }
            let remainingSeconds = Double(deadlineNs - nowNs) / 1_000_000_000.0
            let attemptTimeout = min(request.policy.attemptTimeoutSeconds, remainingSeconds)

            let slotStartNs = clock.monotonicNanoseconds
            do {
                try await acquireSlot(priority: request.policy.priority, requestID: requestID, traceContext: traceContext)
            } catch {
                emitCompleted(outcome: .cancelled, error: .cancelled)
                throw error
            }
            let attemptStartNs = clock.monotonicNanoseconds
            let queueWaitMs = Double(attemptStartNs >= slotStartNs ? attemptStartNs - slotStartNs : 0) / 1_000_000.0
            AppLogger.shared.emit(
                eventName: "http.request.started",
                category: "HTTP",
                level: .trace,
                traceContext: traceContext,
                source: DiagnosticSourceLocation(module: "Infrastructure", component: "HTTPClient", function: "executeWithDeadlineAndRetries"),
                payload: {
                    DiagnosticEventPayload(
                        context: DiagnosticContext(requestID: requestID, attempt: attemptsUsed),
                        fields: ["queueWaitMs": .double(queueWaitMs), "deadlineMs": .double(attemptTimeout * 1000.0)],
                        message: "HTTP attempt \(attemptsUsed) started"
                    )
                }
            )

            let response: HTTPResponse
            do {
                response = try await transport.send(request, timeoutSeconds: attemptTimeout)
                releaseSlot()
            } catch {
                releaseSlot()
                let mapped = Self.mapTransportError(error)
                if mapped == .cancelled {
                    AppLogger.shared.emit(
                        eventName: "http.request.cancelled",
                        category: "HTTP",
                        level: .info,
                        outcome: .cancelled,
                        traceContext: traceContext,
                        source: DiagnosticSourceLocation(module: "Infrastructure", component: "HTTPClient", function: "executeWithDeadlineAndRetries"),
                        payload: {
                            DiagnosticEventPayload(
                                context: DiagnosticContext(requestID: requestID, attempt: attemptsUsed),
                                fields: ["reasonCode": .string("transport_cancelled"), "initiator": .string("caller")],
                                message: "HTTP transport cancelled"
                            )
                        }
                    )
                    emitCompleted(outcome: .cancelled, error: .cancelled)
                    throw CoreError.cancelled
                }
                lastError = mapped

                let canRetry = !request.policy.isSideEffecting &&
                    attempt + 1 < maxAttempts &&
                    Self.isRetryableError(mapped)
                AppLogger.shared.emit(
                    eventName: "http.request.failed",
                    category: "HTTP",
                    level: canRetry ? .warn : .error,
                    outcome: .failed,
                    traceContext: traceContext,
                    source: DiagnosticSourceLocation(module: "Infrastructure", component: "HTTPClient", function: "executeWithDeadlineAndRetries"),
                    payload: {
                        DiagnosticEventPayload(
                            context: DiagnosticContext(requestID: requestID, attempt: attemptsUsed),
                            fields: ["retryable": .bool(canRetry)],
                            error: LogSanitizer.sanitizeError(mapped, stage: "transport"),
                            message: "HTTP transport failed (retryable=\(canRetry))"
                        )
                    }
                )
                if canRetry {
                    let delay = min(remainingSeconds, Self.backoffDelay(attempt: attempt))
                    if delay > 0.01 {
                        AppLogger.shared.emit(
                            eventName: "http.request.retry_scheduled",
                            category: "HTTP",
                            level: .info,
                            traceContext: traceContext,
                            source: DiagnosticSourceLocation(module: "Infrastructure", component: "HTTPClient", function: "executeWithDeadlineAndRetries"),
                            payload: {
                                DiagnosticEventPayload(
                                    context: DiagnosticContext(requestID: requestID, attempt: attemptsUsed),
                                    fields: [
                                        "reasonCode": .string("transport_error"),
                                        "backoffMs": .double(delay * 1000.0),
                                        "nextAttempt": .int(attemptsUsed + 1)
                                    ],
                                    message: "Scheduling retry attempt \(attemptsUsed + 1)"
                                )
                            }
                        )
                        try await sleepCheckingCancellation(seconds: delay)
                        continue
                    }
                }
                emitCompleted(outcome: .failed, error: mapped)
                throw mapped
            }

            let respNs = clock.monotonicNanoseconds
            let attemptMs = Double(respNs >= attemptStartNs ? respNs - attemptStartNs : 0) / 1_000_000.0
            AppLogger.shared.emit(
                eventName: "http.response.received",
                category: "HTTP",
                level: response.statusCode >= 400 ? .warn : .debug,
                durationMs: attemptMs,
                traceContext: traceContext,
                source: DiagnosticSourceLocation(module: "Infrastructure", component: "HTTPClient", function: "executeWithDeadlineAndRetries"),
                payload: {
                    DiagnosticEventPayload(
                        context: DiagnosticContext(requestID: requestID, attempt: attemptsUsed),
                        fields: [
                            "statusCode": .int(response.statusCode),
                            "responseBytes": .int(response.data.count)
                        ],
                        message: "HTTP \(response.statusCode) (\(response.data.count)B)"
                    )
                }
            )

            switch response.statusCode {
            case 200..<300:
                emitCompleted(outcome: .succeeded)
                return response
            case 401:
                let authErr: CoreError
                switch request.policy.authScope {
                case .clientRequired: authErr = .clientCredentialInvalid
                default: authErr = .userCredentialInvalid
                }
                AppLogger.shared.emit(
                    eventName: "api.authorization_failed",
                    category: "HTTP",
                    level: .error,
                    outcome: .failed,
                    traceContext: traceContext,
                    source: DiagnosticSourceLocation(module: "Infrastructure", component: "HTTPClient", function: "executeWithDeadlineAndRetries"),
                    payload: {
                        DiagnosticEventPayload(
                            context: DiagnosticContext(requestID: requestID, attempt: attemptsUsed),
                            fields: ["statusCode": .int(401), "classification": .string("unauthorized")],
                            error: LogSanitizer.sanitizeError(authErr, stage: "auth"),
                            message: "HTTP 401 unauthorized"
                        )
                    }
                )
                emitCompleted(outcome: .failed, error: authErr)
                throw authErr
            case 403:
                AppLogger.shared.emit(
                    eventName: "api.authorization_failed",
                    category: "HTTP",
                    level: .error,
                    outcome: .failed,
                    traceContext: traceContext,
                    source: DiagnosticSourceLocation(module: "Infrastructure", component: "HTTPClient", function: "executeWithDeadlineAndRetries"),
                    payload: {
                        DiagnosticEventPayload(
                            context: DiagnosticContext(requestID: requestID, attempt: attemptsUsed),
                            fields: ["statusCode": .int(403), "classification": .string("forbidden")],
                            error: LogSanitizer.sanitizeError(CoreError.forbidden(nil), stage: "auth"),
                            message: "HTTP 403 forbidden"
                        )
                    }
                )
                emitCompleted(outcome: .failed, error: .forbidden(nil))
                throw CoreError.forbidden(nil)
            case 404:
                emitCompleted(outcome: .failed, error: .notFound(nil))
                throw CoreError.notFound(nil)
            case 429:
                let retryAfter = Self.parseRetryAfter(response.headerValue(forCaseInsensitiveName: "Retry-After"), now: clock.now)
                lastError = .rateLimited(retryAfterSeconds: retryAfter)
                AppLogger.shared.emit(
                    eventName: "api.rate_limited",
                    category: "HTTP",
                    level: .warn,
                    traceContext: traceContext,
                    source: DiagnosticSourceLocation(module: "Infrastructure", component: "HTTPClient", function: "executeWithDeadlineAndRetries"),
                    payload: {
                        DiagnosticEventPayload(
                            context: DiagnosticContext(requestID: requestID, attempt: attemptsUsed),
                            fields: [
                                "endpointTemplate": .string(sanitizedURL.endpointTemplate),
                                "retryAfterMs": retryAfter.map { .double($0 * 1000.0) } ?? .absent
                            ],
                            message: "HTTP 429 rate limited"
                        )
                    }
                )
                let afterNs = clock.monotonicNanoseconds
                let remSec = afterNs < deadlineNs ? Double(deadlineNs - afterNs) / 1_000_000_000.0 : 0
                let waitSec = retryAfter ?? Self.backoffDelay(attempt: attempt)
                if !request.policy.isSideEffecting && attempt + 1 < maxAttempts && waitSec <= remSec && waitSec > 0 {
                    try await sleepCheckingCancellation(seconds: waitSec)
                    continue
                }
                emitCompleted(outcome: .failed, error: lastError)
                throw lastError
            case 500..<600:
                lastError = .server(statusCode: response.statusCode, message: nil)
                let afterNs = clock.monotonicNanoseconds
                let remSec = afterNs < deadlineNs ? Double(deadlineNs - afterNs) / 1_000_000_000.0 : 0
                if !request.policy.isSideEffecting && attempt + 1 < maxAttempts {
                    let delay = min(remSec, Self.backoffDelay(attempt: attempt))
                    if delay > 0.01 {
                        AppLogger.shared.emit(
                            eventName: "http.request.retry_scheduled",
                            category: "HTTP",
                            level: .info,
                            traceContext: traceContext,
                            source: DiagnosticSourceLocation(module: "Infrastructure", component: "HTTPClient", function: "executeWithDeadlineAndRetries"),
                            payload: {
                                DiagnosticEventPayload(
                                    context: DiagnosticContext(requestID: requestID, attempt: attemptsUsed),
                                    fields: [
                                        "reasonCode": .string("server_\(response.statusCode)"),
                                        "backoffMs": .double(delay * 1000.0),
                                        "nextAttempt": .int(attemptsUsed + 1)
                                    ],
                                    message: "Scheduling retry after HTTP \(response.statusCode)"
                                )
                            }
                        )
                        try await sleepCheckingCancellation(seconds: delay)
                        continue
                    }
                }
                emitCompleted(outcome: .failed, error: lastError)
                throw lastError
            default:
                let err = CoreError.transport(statusCode: response.statusCode, message: "HTTP \(response.statusCode)")
                emitCompleted(outcome: .failed, error: err)
                throw err
            }
        }

        emitCompleted(outcome: .failed, error: lastError)
        throw lastError
    }

    private func sleepCheckingCancellation(seconds: TimeInterval) async throws {
        do {
            try await clock.sleep(for: .milliseconds(Int64(seconds * 1000)))
        } catch is CancellationError {
            throw CoreError.cancelled
        }
    }

    // MARK: - Helpers

    public static func canonicalDeduplicationKey(for request: HTTPRequest) -> String {
        var components = URLComponents(url: request.url, resolvingAgainstBaseURL: false)
        if let items = components?.queryItems, !items.isEmpty {
            components?.queryItems = items.sorted {
                if $0.name == $1.name {
                    return ($0.value ?? "") < ($1.value ?? "")
                }
                return $0.name < $1.name
            }
        }
        let canonicalURL = components?.url?.absoluteString ?? request.url.absoluteString
        let bodyCount = request.body?.count ?? 0
        return "\(request.method.rawValue)|\(canonicalURL)|\(request.policy.authScope.cacheScopeKey)|b:\(bodyCount)"
    }

    private static func mapTransportError(_ error: Error) -> CoreError {
        if let core = error as? CoreError { return core }
        if error is CancellationError { return .cancelled }
        let nsErr = error as NSError
        if nsErr.domain == NSURLErrorDomain {
            switch nsErr.code {
            case NSURLErrorCancelled:
                return .cancelled
            case NSURLErrorTimedOut:
                return .timeout
            case NSURLErrorNotConnectedToInternet, NSURLErrorDataNotAllowed, NSURLErrorNetworkConnectionLost:
                return .offline
            default:
                return .transport(statusCode: nil, message: nsErr.localizedDescription)
            }
        }
        return .transport(statusCode: nil, message: error.localizedDescription)
    }

    private static func isRetryableError(_ error: CoreError) -> Bool {
        switch error {
        case .timeout, .server, .rateLimited:
            return true
        case .transport(let code, _):
            return code == nil || (code ?? 0) >= 500
        default:
            return false
        }
    }

    private static func backoffDelay(attempt: Int) -> TimeInterval {
        let base = 0.25 * pow(2.0, Double(attempt))
        return min(base, 4.0)
    }

    public static func parseRetryAfter(_ raw: String?, now: Date) -> TimeInterval? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        if let seconds = TimeInterval(trimmed) {
            return max(0, seconds)
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        if let date = formatter.date(from: trimmed) {
            return max(0, date.timeIntervalSince(now))
        }
        return nil
    }
}
