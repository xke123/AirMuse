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
public actor HTTPClient {
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
        var task: Task<HTTPResponse, Error>?
        var waiters: [UUID: CheckedContinuation<HTTPResponse, Error>] = [:]
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

        if !request.policy.deduplicate || request.policy.isSideEffecting {
            return try await executeWithDeadlineAndRetries(request)
        }

        let key = Self.canonicalDeduplicationKey(for: request)
        let waiterID = UUID()

        let entry: InFlightEntry
        let isOwner: Bool
        if let existing = inFlight[key] {
            entry = existing
            isOwner = false
        } else {
            let created = InFlightEntry()
            inFlight[key] = created
            entry = created
            isOwner = true
        }

        if isOwner {
            entry.task = Task { [weak self] in
                guard let self else { throw CoreError.cancelled }
                do {
                    let response = try await self.executeWithDeadlineAndRetries(request)
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

    private func acquireSlot(priority: RequestPriority) async throws {
        try Task.checkCancellation()
        if activeCount < maxConcurrentRequests {
            activeCount += 1
            return
        }

        let waiterID = UUID()
        nextSequence += 1
        let seq = nextSequence

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

    private func executeWithDeadlineAndRetries(_ request: HTTPRequest) async throws -> HTTPResponse {
        let startNs = clock.monotonicNanoseconds
        let totalBudgetNs = UInt64(max(0.1, request.policy.totalDeadlineSeconds) * 1_000_000_000)
        let deadlineNs = startNs &+ totalBudgetNs
        let maxAttempts = request.policy.isSideEffecting ? 1 : max(1, request.policy.maxRetries + 1)

        var lastError: CoreError = .timeout

        for attempt in 0..<maxAttempts {
            if Task.isCancelled { throw CoreError.cancelled }

            let nowNs = clock.monotonicNanoseconds
            if nowNs >= deadlineNs {
                throw CoreError.timeout
            }
            let remainingSeconds = Double(deadlineNs - nowNs) / 1_000_000_000.0
            let attemptTimeout = min(request.policy.attemptTimeoutSeconds, remainingSeconds)

            try await acquireSlot(priority: request.policy.priority)
            let response: HTTPResponse
            do {
                response = try await transport.send(request, timeoutSeconds: attemptTimeout)
                releaseSlot()
            } catch {
                releaseSlot()
                let mapped = Self.mapTransportError(error)
                if mapped == .cancelled { throw CoreError.cancelled }
                lastError = mapped

                let canRetry = !request.policy.isSideEffecting &&
                    attempt + 1 < maxAttempts &&
                    Self.isRetryableError(mapped)
                if canRetry {
                    let delay = min(remainingSeconds, Self.backoffDelay(attempt: attempt))
                    if delay > 0.01 {
                        try await sleepCheckingCancellation(seconds: delay)
                        continue
                    }
                }
                throw mapped
            }

            switch response.statusCode {
            case 200..<300:
                return response
            case 401:
                switch request.policy.authScope {
                case .clientRequired:
                    throw CoreError.clientCredentialInvalid
                default:
                    throw CoreError.userCredentialInvalid
                }
            case 403:
                throw CoreError.forbidden(nil)
            case 404:
                throw CoreError.notFound(nil)
            case 429:
                let retryAfter = Self.parseRetryAfter(response.headerValue(forCaseInsensitiveName: "Retry-After"), now: clock.now)
                lastError = .rateLimited(retryAfterSeconds: retryAfter)
                AppLogger.shared.log(category: .network, level: .warn, correlationID: "http-a\(attempt + 1)", message: "HTTP 429 限流: \(request.url.path) (retryAfter=\(retryAfter.map { String(format: "%.1fs", $0) } ?? "backoff"))")
                let afterNs = clock.monotonicNanoseconds
                let remSec = afterNs < deadlineNs ? Double(deadlineNs - afterNs) / 1_000_000_000.0 : 0
                let waitSec = retryAfter ?? Self.backoffDelay(attempt: attempt)
                if !request.policy.isSideEffecting && attempt + 1 < maxAttempts && waitSec <= remSec && waitSec > 0 {
                    try await sleepCheckingCancellation(seconds: waitSec)
                    continue
                }
                throw lastError
            case 500..<600:
                lastError = .server(statusCode: response.statusCode, message: nil)
                let afterNs = clock.monotonicNanoseconds
                let remSec = afterNs < deadlineNs ? Double(deadlineNs - afterNs) / 1_000_000_000.0 : 0
                if !request.policy.isSideEffecting && attempt + 1 < maxAttempts {
                    let delay = min(remSec, Self.backoffDelay(attempt: attempt))
                    if delay > 0.01 {
                        try await sleepCheckingCancellation(seconds: delay)
                        continue
                    }
                }
                throw lastError
            default:
                throw CoreError.transport(statusCode: response.statusCode, message: "HTTP \(response.statusCode)")
            }
        }

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
