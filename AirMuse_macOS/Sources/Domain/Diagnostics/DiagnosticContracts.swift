import Foundation

// MARK: - Schema Version

public enum DiagnosticSchemaVersion {
    public static let current: Int = 1
}

// MARK: - DiagnosticLevel & DiagnosticCaptureMode

public enum DiagnosticLevel: String, Sendable, Codable, CaseIterable, Comparable, Hashable {
    case trace  = "TRACE"
    case debug  = "DEBUG"
    case info   = "INFO"
    case notice = "NOTICE"
    case warn   = "WARN"
    case error  = "ERROR"
    case fault  = "FAULT"

    private var severityOrder: Int {
        switch self {
        case .trace:  return 0
        case .debug:  return 1
        case .info:   return 2
        case .notice: return 3
        case .warn:   return 4
        case .error:  return 5
        case .fault:  return 6
        }
    }

    public static func < (lhs: DiagnosticLevel, rhs: DiagnosticLevel) -> Bool {
        lhs.severityOrder < rhs.severityOrder
    }
}

public enum DiagnosticCaptureMode: String, Sendable, Codable, CaseIterable, Equatable, Hashable {
    case off
    case normal
    case debug
    case fullTrace
    case performance

    public var minimumLevel: DiagnosticLevel {
        switch self {
        case .off:         return .fault // off disables normal emission
        case .normal:      return .info
        case .debug:       return .debug
        case .fullTrace:   return .trace
        case .performance: return .notice
        }
    }
}

// MARK: - Phase & Outcome

public enum DiagnosticPhase: String, Sendable, Codable, Equatable, Hashable {
    case begin
    case end
    case instant
}

public enum DiagnosticOutcome: String, Sendable, Codable, Equatable, Hashable {
    case accepted
    case confirmed
    case succeeded
    case failed
    case rejected
    case cancelled
    case superseded
    case discarded
    case unknown
    case unsupported
    case partial
}

// MARK: - Links & Error & Source

public struct DiagnosticLink: Sendable, Codable, Equatable, Hashable {
    public let traceID: UUID
    public let spanID: UUID?
    public let eventID: UUID?
    public let relation: String

    public init(traceID: UUID, spanID: UUID? = nil, eventID: UUID? = nil, relation: String) {
        self.traceID = traceID
        self.spanID = spanID
        self.eventID = eventID
        self.relation = relation
    }
}

public struct DiagnosticErrorInfo: Sendable, Codable, Equatable, Hashable {
    public let domain: String
    public let code: String
    public let stage: String?
    public let retryable: Bool
    public let underlyingCode: String?
    public let safeSummary: String

    public init(
        domain: String,
        code: String,
        stage: String? = nil,
        retryable: Bool = false,
        underlyingCode: String? = nil,
        safeSummary: String
    ) {
        self.domain = domain
        self.code = code
        self.stage = stage
        self.retryable = retryable
        self.underlyingCode = underlyingCode
        self.safeSummary = safeSummary
    }
}

public struct DiagnosticSourceLocation: Sendable, Codable, Equatable, Hashable {
    public let module: String
    public let component: String
    public let function: String
    public let fileID: String?
    public let line: Int?

    public init(
        module: String,
        component: String,
        function: String,
        fileID: String? = nil,
        line: Int? = nil
    ) {
        self.module = module
        self.component = component
        self.function = function
        self.fileID = fileID
        self.line = line
    }
}

// MARK: - Typed Field Value (No [String: Any])

public enum DiagnosticFieldValue: Sendable, Codable, Equatable, Hashable {
    case string(String)
    case int(Int)
    case int64(Int64)
    case uint64(UInt64)
    case double(Double)
    case bool(Bool)
    case strings([String])
    case absent

    private enum CodingKeys: String, CodingKey {
        case type, value
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        switch type {
        case "string":
            self = .string(try container.decode(String.self, forKey: .value))
        case "int":
            self = .int(try container.decode(Int.self, forKey: .value))
        case "int64":
            self = .int64(try container.decode(Int64.self, forKey: .value))
        case "uint64":
            self = .uint64(try container.decode(UInt64.self, forKey: .value))
        case "double":
            self = .double(try container.decode(Double.self, forKey: .value))
        case "bool":
            self = .bool(try container.decode(Bool.self, forKey: .value))
        case "strings":
            self = .strings(try container.decode([String].self, forKey: .value))
        case "absent":
            self = .absent
        default:
            self = .string("<unsupported_field_type:\(type)>")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .string(let v):
            try container.encode("string", forKey: .type)
            try container.encode(v, forKey: .value)
        case .int(let v):
            try container.encode("int", forKey: .type)
            try container.encode(v, forKey: .value)
        case .int64(let v):
            try container.encode("int64", forKey: .type)
            try container.encode(v, forKey: .value)
        case .uint64(let v):
            try container.encode("uint64", forKey: .type)
            try container.encode(v, forKey: .value)
        case .double(let v):
            try container.encode("double", forKey: .type)
            try container.encode(v, forKey: .value)
        case .bool(let v):
            try container.encode("bool", forKey: .type)
            try container.encode(v, forKey: .value)
        case .strings(let v):
            try container.encode("strings", forKey: .type)
            try container.encode(v, forKey: .value)
        case .absent:
            try container.encode("absent", forKey: .type)
        }
    }

    public var displayString: String {
        switch self {
        case .string(let s): return s
        case .int(let i): return String(i)
        case .int64(let i): return String(i)
        case .uint64(let u): return String(u)
        case .double(let d): return String(format: "%.3f", d)
        case .bool(let b): return b ? "true" : "false"
        case .strings(let arr): return "[\(arr.joined(separator: ", "))]"
        case .absent: return "absent"
        }
    }
}

// MARK: - Typed Allowlist Context

public struct DiagnosticContext: Sendable, Codable, Equatable, Hashable {
    public var providerID: String?
    public var browsingProviderID: String?
    public var playingProviderID: String?
    public var operationProviderID: String?

    public var accountRef: String?
    public var storefront: String?
    public var sessionID: UUID?
    public var sessionGeneration: UInt64?

    public var engineInstanceID: UUID?
    public var candidateEngineID: UUID?
    public var routingGeneration: UInt64?
    public var leaseRef: String?
    public var switchRef: String?

    public var playbackGeneration: UInt64?
    public var transportRevision: UInt64?
    public var operationID: UInt64?
    public var intentID: UUID?

    public var queueID: UUID?
    public var queueRevision: UInt64?
    public var destructiveEpoch: UInt64?
    public var entryID: UUID?
    public var batchID: UUID?

    public var stationRef: String?
    public var seedRef: String?
    public var currentItemRef: String?
    public var itemSequence: UInt64?

    public var resourceRef: String?
    public var resourceKind: String?
    public var scopeRef: String?

    public var navigationGeneration: UInt64?
    public var browseGeneration: UInt64?
    public var mutationID: UUID?
    public var fieldRevision: UInt64?

    public var requestID: UUID?
    public var attempt: Int?
    public var animationID: UUID?
    public var windowRef: String?
    public var routeRef: String?
    public var runtimeRef: String?

    public static let empty = DiagnosticContext()

    public init(
        providerID: String? = nil,
        browsingProviderID: String? = nil,
        playingProviderID: String? = nil,
        operationProviderID: String? = nil,
        accountRef: String? = nil,
        storefront: String? = nil,
        sessionID: UUID? = nil,
        sessionGeneration: UInt64? = nil,
        engineInstanceID: UUID? = nil,
        candidateEngineID: UUID? = nil,
        routingGeneration: UInt64? = nil,
        leaseRef: String? = nil,
        switchRef: String? = nil,
        playbackGeneration: UInt64? = nil,
        transportRevision: UInt64? = nil,
        operationID: UInt64? = nil,
        intentID: UUID? = nil,
        queueID: UUID? = nil,
        queueRevision: UInt64? = nil,
        destructiveEpoch: UInt64? = nil,
        entryID: UUID? = nil,
        batchID: UUID? = nil,
        stationRef: String? = nil,
        seedRef: String? = nil,
        currentItemRef: String? = nil,
        itemSequence: UInt64? = nil,
        resourceRef: String? = nil,
        resourceKind: String? = nil,
        scopeRef: String? = nil,
        navigationGeneration: UInt64? = nil,
        browseGeneration: UInt64? = nil,
        mutationID: UUID? = nil,
        fieldRevision: UInt64? = nil,
        requestID: UUID? = nil,
        attempt: Int? = nil,
        animationID: UUID? = nil,
        windowRef: String? = nil,
        routeRef: String? = nil,
        runtimeRef: String? = nil
    ) {
        self.providerID = providerID
        self.browsingProviderID = browsingProviderID
        self.playingProviderID = playingProviderID
        self.operationProviderID = operationProviderID
        self.accountRef = accountRef
        self.storefront = storefront
        self.sessionID = sessionID
        self.sessionGeneration = sessionGeneration
        self.engineInstanceID = engineInstanceID
        self.candidateEngineID = candidateEngineID
        self.routingGeneration = routingGeneration
        self.leaseRef = leaseRef
        self.switchRef = switchRef
        self.playbackGeneration = playbackGeneration
        self.transportRevision = transportRevision
        self.operationID = operationID
        self.intentID = intentID
        self.queueID = queueID
        self.queueRevision = queueRevision
        self.destructiveEpoch = destructiveEpoch
        self.entryID = entryID
        self.batchID = batchID
        self.stationRef = stationRef
        self.seedRef = seedRef
        self.currentItemRef = currentItemRef
        self.itemSequence = itemSequence
        self.resourceRef = resourceRef
        self.resourceKind = resourceKind
        self.scopeRef = scopeRef
        self.navigationGeneration = navigationGeneration
        self.browseGeneration = browseGeneration
        self.mutationID = mutationID
        self.fieldRevision = fieldRevision
        self.requestID = requestID
        self.attempt = attempt
        self.animationID = animationID
        self.windowRef = windowRef
        self.routeRef = routeRef
        self.runtimeRef = runtimeRef
    }

    public func merging(_ overlay: DiagnosticContext) -> DiagnosticContext {
        DiagnosticContext(
            providerID: overlay.providerID ?? providerID,
            browsingProviderID: overlay.browsingProviderID ?? browsingProviderID,
            playingProviderID: overlay.playingProviderID ?? playingProviderID,
            operationProviderID: overlay.operationProviderID ?? operationProviderID,
            accountRef: overlay.accountRef ?? accountRef,
            storefront: overlay.storefront ?? storefront,
            sessionID: overlay.sessionID ?? sessionID,
            sessionGeneration: overlay.sessionGeneration ?? sessionGeneration,
            engineInstanceID: overlay.engineInstanceID ?? engineInstanceID,
            candidateEngineID: overlay.candidateEngineID ?? candidateEngineID,
            routingGeneration: overlay.routingGeneration ?? routingGeneration,
            leaseRef: overlay.leaseRef ?? leaseRef,
            switchRef: overlay.switchRef ?? switchRef,
            playbackGeneration: overlay.playbackGeneration ?? playbackGeneration,
            transportRevision: overlay.transportRevision ?? transportRevision,
            operationID: overlay.operationID ?? operationID,
            intentID: overlay.intentID ?? intentID,
            queueID: overlay.queueID ?? queueID,
            queueRevision: overlay.queueRevision ?? queueRevision,
            destructiveEpoch: overlay.destructiveEpoch ?? destructiveEpoch,
            entryID: overlay.entryID ?? entryID,
            batchID: overlay.batchID ?? batchID,
            stationRef: overlay.stationRef ?? stationRef,
            seedRef: overlay.seedRef ?? seedRef,
            currentItemRef: overlay.currentItemRef ?? currentItemRef,
            itemSequence: overlay.itemSequence ?? itemSequence,
            resourceRef: overlay.resourceRef ?? resourceRef,
            resourceKind: overlay.resourceKind ?? resourceKind,
            scopeRef: overlay.scopeRef ?? scopeRef,
            navigationGeneration: overlay.navigationGeneration ?? navigationGeneration,
            browseGeneration: overlay.browseGeneration ?? browseGeneration,
            mutationID: overlay.mutationID ?? mutationID,
            fieldRevision: overlay.fieldRevision ?? fieldRevision,
            requestID: overlay.requestID ?? requestID,
            attempt: overlay.attempt ?? attempt,
            animationID: overlay.animationID ?? animationID,
            windowRef: overlay.windowRef ?? windowRef,
            routeRef: overlay.routeRef ?? routeRef,
            runtimeRef: overlay.runtimeRef ?? runtimeRef
        )
    }
}

// MARK: - Trace Context Propagation

public struct DiagnosticTraceContext: Sendable, Codable, Equatable, Hashable {
    public let traceID: UUID
    public let spanID: UUID
    public let parentSpanID: UUID?
    public let links: [DiagnosticLink]
    public let context: DiagnosticContext

    public init(
        traceID: UUID,
        spanID: UUID,
        parentSpanID: UUID? = nil,
        links: [DiagnosticLink] = [],
        context: DiagnosticContext = .empty
    ) {
        self.traceID = traceID
        self.spanID = spanID
        self.parentSpanID = parentSpanID
        self.links = links
        self.context = context
    }

    public func childSpan(
        links extraLinks: [DiagnosticLink] = [],
        context overlay: DiagnosticContext? = nil
    ) -> DiagnosticTraceContext {
        DiagnosticTraceContext(
            traceID: traceID,
            spanID: UUID(),
            parentSpanID: spanID,
            links: links + extraLinks,
            context: overlay.map { context.merging($0) } ?? context
        )
    }

    public func withContext(_ overlay: DiagnosticContext) -> DiagnosticTraceContext {
        DiagnosticTraceContext(
            traceID: traceID,
            spanID: spanID,
            parentSpanID: parentSpanID,
            links: links,
            context: context.merging(overlay)
        )
    }
}

public enum DiagnosticTrace {
    @TaskLocal public static var current: DiagnosticTraceContext?

    public static func makeRoot(
        links: [DiagnosticLink] = [],
        context: DiagnosticContext = .empty
    ) -> DiagnosticTraceContext {
        DiagnosticTraceContext(
            traceID: UUID(),
            spanID: UUID(),
            parentSpanID: nil,
            links: links,
            context: context
        )
    }

    public static func currentOrRoot(
        links: [DiagnosticLink] = [],
        context: DiagnosticContext = .empty
    ) -> DiagnosticTraceContext {
        if let active = current {
            if links.isEmpty && context == .empty {
                return active
            }
            return DiagnosticTraceContext(
                traceID: active.traceID,
                spanID: active.spanID,
                parentSpanID: active.parentSpanID,
                links: active.links + links,
                context: active.context.merging(context)
            )
        }
        return makeRoot(links: links, context: context)
    }

    public static func withContext<T>(
        _ traceContext: DiagnosticTraceContext,
        isolation: isolated (any Actor)? = #isolation,
        operation: () async throws -> T
    ) async rethrows -> T {
        try await $current.withValue(traceContext) {
            try await operation()
        }
    }

    public static func withContextSync<T>(
        _ traceContext: DiagnosticTraceContext,
        operation: () throws -> T
    ) rethrows -> T {
        try $current.withValue(traceContext) {
            try operation()
        }
    }

    public static func withRoot<T>(
        links: [DiagnosticLink] = [],
        context: DiagnosticContext = .empty,
        isolation: isolated (any Actor)? = #isolation,
        operation: (DiagnosticTraceContext) async throws -> T
    ) async rethrows -> T {
        let root = makeRoot(links: links, context: context)
        return try await $current.withValue(root) {
            try await operation(root)
        }
    }

    public static func withChildSpan<T>(
        links: [DiagnosticLink] = [],
        context: DiagnosticContext? = nil,
        isolation: isolated (any Actor)? = #isolation,
        operation: (DiagnosticTraceContext) async throws -> T
    ) async rethrows -> T {
        let child = (current ?? makeRoot()).childSpan(links: links, context: context)
        return try await $current.withValue(child) {
            try await operation(child)
        }
    }
}

// MARK: - DiagnosticEvent (Schema v1)

public enum DiagnosticEventDecodingError: Error, Sendable, Equatable {
    case unsupportedSchemaVersion(Int)
}

public struct DiagnosticEvent: Sendable, Codable, Identifiable, Equatable {
    public let schemaVersion: Int
    public let eventID: UUID
    public let runID: UUID
    public let sequence: UInt64
    public let timestamp: Date
    public let monotonicTimeNs: UInt64
    public let eventName: String
    public let category: String
    public let level: DiagnosticLevel
    public let traceID: UUID
    public let spanID: UUID
    public let parentSpanID: UUID?
    public let links: [DiagnosticLink]
    public let phase: DiagnosticPhase
    public let outcome: DiagnosticOutcome?
    public let durationMs: Double?
    public let context: DiagnosticContext
    public let fields: [String: DiagnosticFieldValue]
    public let error: DiagnosticErrorInfo?
    public let source: DiagnosticSourceLocation
    public let message: String

    public var id: UUID { eventID }

    public init(
        schemaVersion: Int = DiagnosticSchemaVersion.current,
        eventID: UUID = UUID(),
        runID: UUID,
        sequence: UInt64,
        timestamp: Date,
        monotonicTimeNs: UInt64,
        eventName: String,
        category: String,
        level: DiagnosticLevel,
        traceID: UUID,
        spanID: UUID,
        parentSpanID: UUID? = nil,
        links: [DiagnosticLink] = [],
        phase: DiagnosticPhase = .instant,
        outcome: DiagnosticOutcome? = nil,
        durationMs: Double? = nil,
        context: DiagnosticContext = .empty,
        fields: [String: DiagnosticFieldValue] = [:],
        error: DiagnosticErrorInfo? = nil,
        source: DiagnosticSourceLocation,
        message: String
    ) {
        self.schemaVersion = schemaVersion
        self.eventID = eventID
        self.runID = runID
        self.sequence = sequence
        self.timestamp = timestamp
        self.monotonicTimeNs = monotonicTimeNs
        self.eventName = eventName
        self.category = category
        self.level = level
        self.traceID = traceID
        self.spanID = spanID
        self.parentSpanID = parentSpanID
        self.links = links
        self.phase = phase
        self.outcome = outcome
        self.durationMs = durationMs
        self.context = context
        self.fields = fields
        self.error = error
        self.source = source
        self.message = message
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, eventID, runID, sequence, timestamp, monotonicTimeNs
        case eventName, category, level, traceID, spanID, parentSpanID, links
        case phase, outcome, durationMs, context, fields, error, source, message
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let version = try c.decode(Int.self, forKey: .schemaVersion)
        guard version == DiagnosticSchemaVersion.current else {
            throw DiagnosticEventDecodingError.unsupportedSchemaVersion(version)
        }
        self.schemaVersion = version
        self.eventID = try c.decode(UUID.self, forKey: .eventID)
        self.runID = try c.decode(UUID.self, forKey: .runID)
        self.sequence = try c.decode(UInt64.self, forKey: .sequence)
        self.timestamp = try c.decode(Date.self, forKey: .timestamp)
        self.monotonicTimeNs = try c.decode(UInt64.self, forKey: .monotonicTimeNs)
        self.eventName = try c.decode(String.self, forKey: .eventName)
        self.category = try c.decode(String.self, forKey: .category)
        self.level = try c.decode(DiagnosticLevel.self, forKey: .level)
        self.traceID = try c.decode(UUID.self, forKey: .traceID)
        self.spanID = try c.decode(UUID.self, forKey: .spanID)
        self.parentSpanID = try c.decodeIfPresent(UUID.self, forKey: .parentSpanID)
        self.links = try c.decodeIfPresent([DiagnosticLink].self, forKey: .links) ?? []
        self.phase = try c.decode(DiagnosticPhase.self, forKey: .phase)
        self.outcome = try c.decodeIfPresent(DiagnosticOutcome.self, forKey: .outcome)
        self.durationMs = try c.decodeIfPresent(Double.self, forKey: .durationMs)
        self.context = try c.decodeIfPresent(DiagnosticContext.self, forKey: .context) ?? .empty
        self.fields = try c.decodeIfPresent([String: DiagnosticFieldValue].self, forKey: .fields) ?? [:]
        self.error = try c.decodeIfPresent(DiagnosticErrorInfo.self, forKey: .error)
        self.source = try c.decode(DiagnosticSourceLocation.self, forKey: .source)
        self.message = try c.decode(String.self, forKey: .message)
    }
}

// MARK: - JSONL Codec

public enum DiagnosticJSONLCodec {
    public static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            let formatted = ISO8601DateFormatter.airmuseDiagnosticString(from: date)
            try container.encode(formatted)
        }
        return encoder
    }

    public static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let str = try container.decode(String.self)
            if let date = ISO8601DateFormatter.airmuseDiagnosticDate(from: str) {
                return date
            }
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid ISO8601 date: \(str)")
        }
        return decoder
    }
}

private extension ISO8601DateFormatter {
    static func airmuseDiagnosticString(from date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.string(from: date)
    }

    static func airmuseDiagnosticDate(from string: String) -> Date? {
        let withFrac = ISO8601DateFormatter()
        withFrac.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = withFrac.date(from: string) { return d }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: string)
    }
}

// MARK: - Read-Only Snapshot & Invariant Contracts

public enum DiagnosticSnapshotAvailability: String, Sendable, Codable, Equatable {
    case available
    case unavailable
    case timeout
    case partial
}

public struct DiagnosticComponentSnapshot: Sendable, Codable, Equatable {
    public let component: String
    public let capturedAt: Date
    public let monotonicTimeNs: UInt64
    public let ownerRevision: UInt64?
    public let scopeRef: String?
    public let availability: DiagnosticSnapshotAvailability
    public let data: [String: DiagnosticFieldValue]
    public let error: DiagnosticErrorInfo?

    public init(
        component: String,
        capturedAt: Date = Date(),
        monotonicTimeNs: UInt64 = DispatchTime.now().uptimeNanoseconds,
        ownerRevision: UInt64? = nil,
        scopeRef: String? = nil,
        availability: DiagnosticSnapshotAvailability,
        data: [String: DiagnosticFieldValue] = [:],
        error: DiagnosticErrorInfo? = nil
    ) {
        self.component = component
        self.capturedAt = capturedAt
        self.monotonicTimeNs = monotonicTimeNs
        self.ownerRevision = ownerRevision
        self.scopeRef = scopeRef
        self.availability = availability
        self.data = data
        self.error = error
    }
}

public protocol DiagnosticSnapshotProvider: Sendable {
    var componentName: String { get }
    func captureDiagnosticSnapshot() async -> DiagnosticComponentSnapshot
}

public struct InvariantViolationRecord: Sendable, Codable, Equatable, Identifiable {
    public let id: UUID
    public let invariantID: String
    public let timestamp: Date
    public let monotonicTimeNs: UInt64
    public let traceID: UUID?
    public let summary: String
    public let evidence: [String: DiagnosticFieldValue]
    public let snapshotRef: String?

    public init(
        id: UUID = UUID(),
        invariantID: String,
        timestamp: Date = Date(),
        monotonicTimeNs: UInt64 = DispatchTime.now().uptimeNanoseconds,
        traceID: UUID? = nil,
        summary: String,
        evidence: [String: DiagnosticFieldValue] = [:],
        snapshotRef: String? = nil
    ) {
        self.id = id
        self.invariantID = invariantID
        self.timestamp = timestamp
        self.monotonicTimeNs = monotonicTimeNs
        self.traceID = traceID
        self.summary = summary
        self.evidence = evidence
        self.snapshotRef = snapshotRef
    }
}
