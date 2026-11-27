import Domain
import Foundation
import os

// MARK: - LogLevel (Legacy Compatible)

public enum LogLevel: String, Sendable, CaseIterable {
    case info  = "INFO"
    case debug = "DEBUG"
    case warn  = "WARN"
    case error = "ERROR"

    public var diagnosticLevel: DiagnosticLevel {
        switch self {
        case .info:  return .info
        case .debug: return .debug
        case .warn:  return .warn
        case .error: return .error
        }
    }

    public init(from diagnosticLevel: DiagnosticLevel) {
        switch diagnosticLevel {
        case .trace, .debug: self = .debug
        case .info, .notice: self = .info
        case .warn:          self = .warn
        case .error, .fault: self = .error
        }
    }
}

// MARK: - LogCategory (Legacy Compatible)

public enum LogCategory: String, Sendable, CaseIterable {
    case lifecycle  = "LIFECYCLE"
    case userAction = "USER_ACTION"
    case session    = "SESSION"
    case auth       = "AUTH"
    case engine     = "ENGINE"
    case injection  = "INJECTION"
    case ampAPI     = "AMP_API"
    case musicKit   = "MUSICKIT"
    case render     = "RENDER"
    case playback   = "PLAYBACK"
    case queue      = "QUEUE"
    case lyrics     = "LYRICS"
    case cache      = "CACHE"
    case database   = "DATABASE"
    case network    = "NETWORK"
    case error      = "ERROR"
}

// MARK: - LogEntry (Legacy Compatible)

public struct LogEntry: Identifiable, Sendable {
    public let id: UUID
    public let timestamp: Date
    public let level: LogLevel
    public let category: LogCategory
    public let correlationID: String?
    public let message: String
    public let details: String?

    public init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        level: LogLevel = .info,
        category: LogCategory,
        correlationID: String? = nil,
        message: String,
        details: String? = nil
    ) {
        self.id = id
        self.timestamp = timestamp
        self.level = level
        self.category = category
        self.correlationID = correlationID.map { LogSanitizer.sanitizeSingleLine($0, maxLength: 128) }
        self.message = LogSanitizer.redact(message)
        self.details = details.map { LogSanitizer.redact($0) }
    }

    public init(from event: DiagnosticEvent) {
        self.id = event.eventID
        self.timestamp = event.timestamp
        self.level = LogLevel(from: event.level)
        self.category = LogCategory(rawValue: event.category) ?? .lifecycle
        if case .string(let corr) = event.fields["correlationID"] {
            self.correlationID = corr
        } else {
            self.correlationID = String(event.traceID.uuidString.prefix(8))
        }
        self.message = event.message
        if case .string(let det) = event.fields["details"] {
            self.details = det
        } else if let err = event.error {
            self.details = "\(err.domain):\(err.code) \(err.safeSummary)"
        } else {
            self.details = nil
        }
    }

    public var formattedTime: String {
        Self.formatTimestamp(timestamp)
    }

    public var formattedLine: String {
        let corr = correlationID.map { " [\($0)]" } ?? ""
        var line = "[\(formattedTime)] [\(level.rawValue)] [\(category.rawValue)]\(corr) \(message)"
        if let details = details, !details.isEmpty {
            line += "\n  ↳ \(details)"
        }
        return line
    }

    private static let timeLock = OSAllocatedUnfairLock<DateFormatter>(initialState: {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }())

    private static func formatTimestamp(_ date: Date) -> String {
        timeLock.withLock { $0.string(from: date) }
    }
}

// MARK: - Payload, Span Token, Metrics, Subscription

public struct DiagnosticEventPayload: Sendable {
    public var context: DiagnosticContext
    public var fields: [String: DiagnosticFieldValue]
    public var error: DiagnosticErrorInfo?
    public var links: [DiagnosticLink]
    public var message: String

    public init(
        context: DiagnosticContext = .empty,
        fields: [String: DiagnosticFieldValue] = [:],
        error: DiagnosticErrorInfo? = nil,
        links: [DiagnosticLink] = [],
        message: String
    ) {
        self.context = context
        self.fields = fields
        self.error = error
        self.links = links
        self.message = message
    }
}

public struct DiagnosticSpanToken: Sendable {
    public let eventName: String
    public let category: String
    public let level: DiagnosticLevel
    public let traceContext: DiagnosticTraceContext
    public let startMonotonicNs: UInt64
    public let source: DiagnosticSourceLocation
    public let signpostName: StaticString?
    public let signpostState: AppSignpost.IntervalHandle?
}

public struct DiagnosticSubscriberBatch: Sendable {
    public let events: [DiagnosticEvent]
    public let nextCursor: UInt64
    public let gapDetected: Bool
    public let resetRequired: Bool
}

public struct DiagnosticLoggerMetrics: Sendable, Codable, Equatable {
    public let runID: UUID
    public let mode: DiagnosticCaptureMode
    public let totalEmitted: UInt64
    public let filteredOutCount: UInt64
    public let sampledOutCount: UInt64
    public let ringRetainedCount: Int
    public let ringRetainedBytes: Int
    public let ringEvictedCount: UInt64
    public let ringCriticalLossCount: UInt64
    public let writerDroppedCount: UInt64
    public let writerCriticalLossCount: UInt64
    public let writerWrittenCount: UInt64
    public let writerFailedCount: UInt64
    public let rotationCount: UInt64
    public let evictedSegmentCount: UInt64
    public let truncatedTailRecoveryCount: UInt64
    public let minRetainedSequence: UInt64
    public let maxSequence: UInt64
    public let subscriberCount: Int
    public let evictedByLevel: [String: UInt64]
    public let droppedByLevel: [String: UInt64]
    public let writerLastError: String?
}

public struct DiagnosticRetainedExport: Sendable {
    public let runID: UUID
    public let highWatermark: UInt64
    public let events: [DiagnosticEvent]
    public let manifest: DiagnosticDiskManifest
    public let metrics: DiagnosticLoggerMetrics
    public let isPartial: Bool
    public let truncatedLinesSkipped: Int
}

// MARK: - AppLogger

/// Centralized, bounded, pre-sanitized, single-writer diagnostic logger for AirMuse macOS.
public final class AppLogger: Sendable {

    public static let shared = AppLogger()

    private struct RingItem: Sendable {
        let event: DiagnosticEvent
        let estimatedBytes: Int
    }

    private struct PendingWriteItem: Sendable {
        let event: DiagnosticEvent
        let estimatedBytes: Int
        let epoch: UInt64
    }

    private struct Subscriber: Sendable {
        let id: UUID
        var lastDeliveredSequence: UInt64
        let continuation: AsyncStream<DiagnosticSubscriberBatch>.Continuation
    }

    private struct State: Sendable {
        var mode: DiagnosticCaptureMode
        var policy: DiagnosticBudgetPolicy
        var sequence: UInt64 = 0
        var viewClearSequence: UInt64 = 0
        var deletionEpoch: UInt64 = 0

        var ring: [RingItem] = []
        var ringBytes: Int = 0

        var pendingWrites: [PendingWriteItem] = []
        var pendingWriteBytes: Int = 0

        var totalEmitted: UInt64 = 0
        var filteredOutCount: UInt64 = 0
        var sampledOutCount: UInt64 = 0
        var ringEvictedCount: UInt64 = 0
        var ringCriticalLossCount: UInt64 = 0
        var writerDroppedCount: UInt64 = 0
        var writerCriticalLossCount: UInt64 = 0
        var evictedByLevel: [String: UInt64] = [:]
        var droppedByLevel: [String: UInt64] = [:]

        var subscribers: [UUID: Subscriber] = [:]
        var legacyOnNewEntry: (@MainActor @Sendable (LogEntry) -> Void)?
        var pendingUIBatch: [DiagnosticEvent] = []
        var uiGapDetected: Bool = false

        var consoleEchoEnabled: Bool
        var writerSignalContinuation: AsyncStream<Void>.Continuation?
    }

    public let runID: UUID
    public let environment: AppEnvironmentInfo
    public let logDirectoryURL: URL
    public let clock: any ClockProtocol
    public let hasher: DiagnosticReferenceHasher
    private let startMonotonicNs: UInt64

    private let state: OSAllocatedUnfairLock<State>
    private let writer: DiagnosticWriter
    private let workerTaskLock = OSAllocatedUnfairLock<Task<Void, Never>?>(initialState: nil)

    public init(
        logDirectoryURL: URL? = nil,
        mode: DiagnosticCaptureMode? = nil,
        policy: DiagnosticBudgetPolicy? = nil,
        clock: any ClockProtocol = SystemClock(),
        consoleEchoEnabled: Bool = true
    ) {
        let resolvedMode: DiagnosticCaptureMode = mode ?? {
            #if DEBUG
            return .fullTrace
            #else
            return .normal
            #endif
        }()
        let resolvedPolicy = policy ?? DiagnosticBudgetPolicy.forMode(resolvedMode)
        let resolvedDir: URL
        if let customDir = logDirectoryURL {
            resolvedDir = customDir
        } else {
            let logsBase = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first
                ?? URL(fileURLWithPath: NSTemporaryDirectory())
            resolvedDir = logsBase.appendingPathComponent("Logs/AirMuse", isDirectory: true)
        }

        self.runID = UUID()
        self.environment = AppEnvironmentInfo.current()
        self.logDirectoryURL = resolvedDir
        self.clock = clock
        self.hasher = DiagnosticReferenceHasher()
        self.startMonotonicNs = clock.monotonicNanoseconds
        self.writer = DiagnosticWriter(directoryURL: resolvedDir, runID: self.runID, policy: resolvedPolicy)

        let initialState = State(
            mode: resolvedMode,
            policy: resolvedPolicy,
            consoleEchoEnabled: consoleEchoEnabled
        )
        self.state = OSAllocatedUnfairLock(initialState: initialState)

        startBackgroundConsumer()

        emit(
            eventName: "diagnostic.capture.started",
            category: "DIAGNOSTICS",
            level: .info,
            source: DiagnosticSourceLocation(module: "Infrastructure", component: "AppLogger", function: "init"),
            payload: {
                DiagnosticEventPayload(
                    fields: [
                        "mode": .string(resolvedMode.rawValue),
                        "policyVersion": .int(DiagnosticSchemaVersion.current),
                        "arch": .string(self.environment.arch),
                        "os": .string(self.environment.osVersion),
                        "build": .string(self.environment.buildNumber),
                        "commit": .string(self.environment.commit)
                    ],
                    message: "AppLogger initialized (mode=\(resolvedMode.rawValue), arch=\(self.environment.arch))"
                )
            }
        )
    }

    public convenience init(
        logDirectoryURL: URL? = nil,
        maxFileBytes: Int,
        maxRotatedFiles: Int
    ) {
        let base = DiagnosticBudgetPolicy.forMode(.normal)
        let customPolicy = DiagnosticBudgetPolicy(
            mode: .normal,
            maxRingEvents: base.maxRingEvents,
            maxRingBytes: base.maxRingBytes,
            maxPendingWriteEvents: base.maxPendingWriteEvents,
            maxPendingWriteBytes: base.maxPendingWriteBytes,
            maxSegmentBytes: max(256, maxFileBytes),
            maxSegments: max(1, maxRotatedFiles),
            retentionDays: base.retentionDays,
            uiBatchIntervalMs: base.uiBatchIntervalMs,
            progressAggregateIntervalSeconds: base.progressAggregateIntervalSeconds
        )
        self.init(logDirectoryURL: logDirectoryURL, mode: .normal, policy: customPolicy)
    }

    public var activeLogFileURL: URL {
        logDirectoryURL.appendingPathComponent("events-0001.jsonl")
    }

    public var captureMode: DiagnosticCaptureMode {
        state.withLock { $0.mode }
    }

    public func setCaptureMode(_ mode: DiagnosticCaptureMode, policy customPolicy: DiagnosticBudgetPolicy? = nil) {
        let newPolicy = customPolicy ?? DiagnosticBudgetPolicy.forMode(mode)
        state.withLock { s in
            s.mode = mode
            s.policy = newPolicy
        }
        Task { [writer] in
            await writer.updatePolicy(newPolicy)
        }
    }

    public func isEnabled(level: DiagnosticLevel) -> Bool {
        state.withLock { s in
            if s.mode == .off { return false }
            return level >= s.mode.minimumLevel
        }
    }

    public func recordSampledOut() {
        state.withLock { $0.sampledOutCount &+= 1 }
    }

    // MARK: - Legacy Compatible Entry Points

    public var onNewEntry: (@MainActor @Sendable (LogEntry) -> Void)? {
        get { state.withLock { $0.legacyOnNewEntry } }
        set { state.withLock { $0.legacyOnNewEntry = newValue } }
    }

    public func log(
        category: LogCategory,
        level: LogLevel = .info,
        correlationID: String? = nil,
        message: String,
        details: String? = nil,
        fileID: String = #fileID,
        function: String = #function,
        line: Int = #line
    ) {
        let diagLevel = level.diagnosticLevel
        guard isEnabled(level: diagLevel) else {
            state.withLock { $0.filteredOutCount &+= 1 }
            return
        }
        var fields: [String: DiagnosticFieldValue] = [:]
        if let correlationID, !correlationID.isEmpty {
            fields["correlationID"] = .string(LogSanitizer.sanitizeSingleLine(correlationID, maxLength: 128))
        }
        if let details, !details.isEmpty {
            fields["details"] = .string(details)
        }
        emit(
            eventName: "legacy.event",
            category: category.rawValue,
            level: diagLevel,
            phase: .instant,
            source: DiagnosticSourceLocation(
                module: "App",
                component: category.rawValue,
                function: function,
                fileID: fileID,
                line: line
            ),
            payload: {
                DiagnosticEventPayload(fields: fields, message: message)
            }
        )
    }

    // MARK: - Typed Structured Emit (Zero I/O, Lazy Payload)

    public func emit(
        eventName: String,
        category: String,
        level: DiagnosticLevel = .info,
        phase: DiagnosticPhase = .instant,
        outcome: DiagnosticOutcome? = nil,
        durationMs: Double? = nil,
        traceContext: DiagnosticTraceContext? = nil,
        source: DiagnosticSourceLocation,
        payload: () -> DiagnosticEventPayload
    ) {
        let enabled = state.withLock { s -> Bool in
            if s.mode == .off || level < s.mode.minimumLevel {
                s.filteredOutCount &+= 1
                return false
            }
            return true
        }
        guard enabled else { return }

        let evaluated = payload()
        let activeTrace = traceContext ?? DiagnosticTrace.currentOrRoot()
        let mergedContext = activeTrace.context.merging(evaluated.context)
        let mergedLinks = activeTrace.links + evaluated.links

        let now = clock.now
        let monoNow = clock.monotonicNanoseconds
        let monotonicOffset = monoNow >= startMonotonicNs ? (monoNow - startMonotonicNs) : 0

        let rawEvent = DiagnosticEvent(
            runID: runID,
            sequence: 0, // assigned atomically under lock
            timestamp: now,
            monotonicTimeNs: monotonicOffset,
            eventName: eventName,
            category: category,
            level: level,
            traceID: activeTrace.traceID,
            spanID: activeTrace.spanID,
            parentSpanID: activeTrace.parentSpanID,
            links: mergedLinks,
            phase: phase,
            outcome: outcome,
            durationMs: durationMs,
            context: mergedContext,
            fields: evaluated.fields,
            error: evaluated.error,
            source: source,
            message: evaluated.message
        )

        let sanitizedWithoutSeq = LogSanitizer.sanitizeEvent(rawEvent, hasher: hasher)
        let estBytes = max(256, sanitizedWithoutSeq.message.utf8.count + sanitizedWithoutSeq.fields.count * 64 + 256)

        let (committedEvent, shouldWakeWriter, legacyCallback, echoLine) = state.withLock { s -> (DiagnosticEvent, Bool, (@MainActor @Sendable (LogEntry) -> Void)?, String?) in
            s.sequence &+= 1
            let seq = s.sequence
            s.totalEmitted &+= 1

            let event = DiagnosticEvent(
                schemaVersion: sanitizedWithoutSeq.schemaVersion,
                eventID: sanitizedWithoutSeq.eventID,
                runID: sanitizedWithoutSeq.runID,
                sequence: seq,
                timestamp: sanitizedWithoutSeq.timestamp,
                monotonicTimeNs: sanitizedWithoutSeq.monotonicTimeNs,
                eventName: sanitizedWithoutSeq.eventName,
                category: sanitizedWithoutSeq.category,
                level: sanitizedWithoutSeq.level,
                traceID: sanitizedWithoutSeq.traceID,
                spanID: sanitizedWithoutSeq.spanID,
                parentSpanID: sanitizedWithoutSeq.parentSpanID,
                links: sanitizedWithoutSeq.links,
                phase: sanitizedWithoutSeq.phase,
                outcome: sanitizedWithoutSeq.outcome,
                durationMs: sanitizedWithoutSeq.durationMs,
                context: sanitizedWithoutSeq.context,
                fields: sanitizedWithoutSeq.fields,
                error: sanitizedWithoutSeq.error,
                source: sanitizedWithoutSeq.source,
                message: sanitizedWithoutSeq.message
            )

            // 1. Bounded Ring Buffer with Critical Priority Reservation (25%)
            s.ring.append(RingItem(event: event, estimatedBytes: estBytes))
            s.ringBytes += estBytes
            Self.enforceRingBudget(&s)

            // 2. Bounded Pending Write Queue with Critical Priority Reservation (25%)
            s.pendingWrites.append(PendingWriteItem(event: event, estimatedBytes: estBytes, epoch: s.deletionEpoch))
            s.pendingWriteBytes += estBytes
            Self.enforcePendingWriteBudget(&s)

            let wake = s.pendingWrites.count >= s.policy.writerFlushBatchSize || event.level >= .warn

            // 3. UI Batch Queue
            if !s.subscribers.isEmpty {
                s.pendingUIBatch.append(event)
                if s.pendingUIBatch.count > s.policy.maxRingEvents {
                    s.pendingUIBatch.removeFirst(s.pendingUIBatch.count - s.policy.maxRingEvents)
                    s.uiGapDetected = true
                }
            }
            let cb = s.legacyOnNewEntry
            let echo = (s.consoleEchoEnabled && event.level >= .info) ? LogEntry(from: event).formattedLine : nil
            return (event, wake, cb, echo)
        }

        if let echoLine {
            print(echoLine)
        }
        if shouldWakeWriter {
            _ = state.withLock { $0.writerSignalContinuation?.yield(()) }
        }
        if let legacyCallback {
            let legacyEntry = LogEntry(from: committedEvent)
            Task { @MainActor in
                legacyCallback(legacyEntry)
            }
        }
    }

    // MARK: - Span Helpers (Monotonic Duration + Signpost)

    public func beginSpan(
        eventName: String,
        category: String,
        level: DiagnosticLevel = .info,
        context: DiagnosticContext = .empty,
        fields: [String: DiagnosticFieldValue] = [:],
        signpostName: StaticString? = nil,
        source: DiagnosticSourceLocation,
        message: String
    ) -> DiagnosticSpanToken {
        let childTrace = DiagnosticTrace.currentOrRoot(context: context).childSpan(context: context)
        let startNs = clock.monotonicNanoseconds
        let signpostState = signpostName.map { AppSignpost.shared.beginInterval($0) }

        emit(
            eventName: eventName,
            category: category,
            level: level,
            phase: .begin,
            traceContext: childTrace,
            source: source,
            payload: {
                DiagnosticEventPayload(context: context, fields: fields, message: message)
            }
        )

        return DiagnosticSpanToken(
            eventName: eventName,
            category: category,
            level: level,
            traceContext: childTrace,
            startMonotonicNs: startNs,
            source: source,
            signpostName: signpostName,
            signpostState: signpostState
        )
    }

    public func endSpan(
        _ token: DiagnosticSpanToken,
        endEventName: String? = nil,
        outcome: DiagnosticOutcome,
        fields: [String: DiagnosticFieldValue] = [:],
        error: DiagnosticErrorInfo? = nil,
        message: String
    ) {
        let endNs = clock.monotonicNanoseconds
        let elapsedNs = endNs >= token.startMonotonicNs ? (endNs - token.startMonotonicNs) : 0
        let durationMs = Double(elapsedNs) / 1_000_000.0

        if let spName = token.signpostName, let spState = token.signpostState {
            AppSignpost.shared.endInterval(spName, spState)
        }

        let resolvedLevel: DiagnosticLevel = (outcome == .failed && token.level < .error) ? .error : token.level

        emit(
            eventName: endEventName ?? token.eventName,
            category: token.category,
            level: resolvedLevel,
            phase: .end,
            outcome: outcome,
            durationMs: durationMs,
            traceContext: token.traceContext,
            source: token.source,
            payload: {
                DiagnosticEventPayload(fields: fields, error: error, message: message)
            }
        )
    }

    // MARK: - Queries, Subscriptions, Clear & Delete

    public func getEntries() -> [LogEntry] {
        state.withLock { s in
            s.ring
                .filter { $0.event.sequence > s.viewClearSequence }
                .map { LogEntry(from: $0.event) }
        }
    }

    public func getEvents(afterSequence: UInt64 = 0) -> [DiagnosticEvent] {
        state.withLock { s in
            s.ring
                .filter { $0.event.sequence > max(afterSequence, s.viewClearSequence) }
                .map(\.event)
        }
    }

    /// Clears only the UI view without deleting persisted disk logs.
    public func clear() {
        state.withLock { s in
            s.viewClearSequence = s.sequence
            s.pendingUIBatch.removeAll()
        }
    }

    /// Deletes all persisted logs and clears in-memory ring under a writer barrier.
    public func deleteAllLogs() async {
        let newEpoch = await writer.deleteAllLogs()
        state.withLock { s in
            s.deletionEpoch = newEpoch
            s.ring.removeAll()
            s.ringBytes = 0
            s.pendingWrites.removeAll()
            s.pendingWriteBytes = 0
            s.pendingUIBatch.removeAll()
            s.viewClearSequence = s.sequence
            for id in s.subscribers.keys {
                s.subscribers[id]?.lastDeliveredSequence = s.sequence
                s.subscribers[id]?.continuation.yield(
                    DiagnosticSubscriberBatch(events: [], nextCursor: s.sequence, gapDetected: false, resetRequired: true)
                )
            }
        }
    }

    public func subscribe(
        fromCursor cursor: UInt64? = nil
    ) -> (snapshot: [DiagnosticEvent], nextCursor: UInt64, gapDetected: Bool, stream: AsyncStream<DiagnosticSubscriberBatch>) {
        let subID = UUID()
        let (stream, continuation) = AsyncStream.makeStream(
            of: DiagnosticSubscriberBatch.self,
            bufferingPolicy: .bufferingNewest(64)
        )

        let (snapshot, nextCursor, gapDetected) = state.withLock { s -> ([DiagnosticEvent], UInt64, Bool) in
            let minSeq = s.ring.first?.event.sequence ?? (s.sequence &+ 1)
            let effectiveCursor = max(cursor ?? 0, s.viewClearSequence)
            let gap = (cursor ?? 0) > 0 && (cursor ?? 0) + 1 < minSeq && !s.ring.isEmpty
            let snap = s.ring
                .filter { $0.event.sequence > effectiveCursor }
                .map(\.event)
            let next = snap.last?.sequence ?? max(effectiveCursor, s.sequence)
            s.subscribers[subID] = Subscriber(
                id: subID,
                lastDeliveredSequence: next,
                continuation: continuation
            )
            return (snap, next, gap)
        }

        continuation.onTermination = { [weak self] _ in
            self?.removeSubscriber(id: subID)
        }

        return (snapshot, nextCursor, gapDetected, stream)
    }

    private func removeSubscriber(id: UUID) {
        _ = state.withLock { s in
            s.subscribers.removeValue(forKey: id)
        }
    }

    // MARK: - Flush, Export & Metrics

    public func flush(timeoutSeconds: TimeInterval = 2.0) async -> Bool {
        let highWatermark = state.withLock { $0.sequence }
        let deadline = Date().addingTimeInterval(max(0.05, timeoutSeconds))

        while Date() < deadline {
            let drained = await drainPendingWritesOnce()
            let writerStats = await writer.currentStats()
            let pendingEmpty = state.withLock { $0.pendingWrites.isEmpty }
            if pendingEmpty && (writerStats.lastWrittenSequence >= highWatermark || highWatermark == 0 || !drained) {
                return true
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return state.withLock { $0.pendingWrites.isEmpty }
    }

    public func exportRetained(timeoutSeconds: TimeInterval = 2.0) async -> DiagnosticRetainedExport {
        let highWatermark = state.withLock { $0.sequence }
        let flushed = await flush(timeoutSeconds: timeoutSeconds)

        let pinned = await writer.pinRetainedSegmentsForExport()
        let diskRead = await writer.readRetainedEvents()
        let pinnedFilenames = pinned.segmentURLs.map(\.lastPathComponent)
        await writer.unpinSegments(pinnedFilenames)

        let tailEvents = state.withLock { s in
            s.ring.filter { $0.event.sequence <= highWatermark }.map(\.event)
        }

        var byID: [UUID: DiagnosticEvent] = [:]
        for ev in diskRead.events where ev.runID != runID || ev.sequence <= highWatermark {
            byID[ev.eventID] = ev
        }
        for ev in tailEvents {
            byID[ev.eventID] = ev
        }

        let merged = byID.values.sorted {
            if $0.timestamp != $1.timestamp { return $0.timestamp < $1.timestamp }
            if $0.runID == $1.runID { return $0.sequence < $1.sequence }
            return $0.eventID.uuidString < $1.eventID.uuidString
        }

        let metrics = await metricsSnapshot()
        let isPartial = !flushed || pinned.partialDueToPinBudget || diskRead.truncatedLinesSkipped > 0

        return DiagnosticRetainedExport(
            runID: runID,
            highWatermark: highWatermark,
            events: merged,
            manifest: pinned.manifest,
            metrics: metrics,
            isPartial: isPartial,
            truncatedLinesSkipped: diskRead.truncatedLinesSkipped
        )
    }

    public func exportMarkdown() -> String {
        let copy = getEntries()
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let nowStr = df.string(from: Date())

        var md = """
        ======================================================================
        AirMuse macOS 诊断日志 (Diagnostics Report)
        生成时间: \(nowStr)
        版本/提交: \(environment.appVersion) (\(environment.buildNumber)) / \(environment.commit)
        运行环境: \(environment.osVersion) (\(environment.arch))
        Run ID: \(runID.uuidString)
        日志总数: \(copy.count) 条
        ======================================================================

        """
        for entry in copy {
            md += "\(entry.formattedLine)\n"
        }
        md += "\n======================== 日志输出结束 (EOF) ========================\n"
        return md
    }

    public func metricsSnapshot() async -> DiagnosticLoggerMetrics {
        let wStats = await writer.currentStats()
        return state.withLock { s in
            DiagnosticLoggerMetrics(
                runID: runID,
                mode: s.mode,
                totalEmitted: s.totalEmitted,
                filteredOutCount: s.filteredOutCount,
                sampledOutCount: s.sampledOutCount,
                ringRetainedCount: s.ring.count,
                ringRetainedBytes: s.ringBytes,
                ringEvictedCount: s.ringEvictedCount,
                ringCriticalLossCount: s.ringCriticalLossCount,
                writerDroppedCount: s.writerDroppedCount,
                writerCriticalLossCount: s.writerCriticalLossCount,
                writerWrittenCount: wStats.writtenCount,
                writerFailedCount: wStats.writerFailedCount,
                rotationCount: wStats.rotationCount,
                evictedSegmentCount: wStats.evictedSegmentCount,
                truncatedTailRecoveryCount: wStats.truncatedTailRecoveryCount,
                minRetainedSequence: s.ring.first?.event.sequence ?? 0,
                maxSequence: s.sequence,
                subscriberCount: s.subscribers.count,
                evictedByLevel: s.evictedByLevel,
                droppedByLevel: s.droppedByLevel,
                writerLastError: wStats.lastErrorSummary
            )
        }
    }

    public func shutdown(timeoutSeconds: TimeInterval = 1.5) async {
        let flushed = await flush(timeoutSeconds: timeoutSeconds)
        if flushed {
            await writer.markCleanShutdown()
        } else {
            await writer.recordGap(
                DiagnosticGapRecord(
                    runID: runID,
                    startSequence: state.withLock { $0.sequence },
                    endSequence: state.withLock { $0.sequence },
                    reason: "shutdown_flush_timeout"
                )
            )
        }
    }

    // MARK: - Background Consumer

    private func startBackgroundConsumer() {
        let signalStream = AsyncStream<Void>(bufferingPolicy: .bufferingNewest(1)) { continuation in
            state.withLock { $0.writerSignalContinuation = continuation }
        }

        let task = Task(priority: .utility) { [weak self] in
            guard let self else { return }
            await withTaskGroup(of: Void.self) { group in
                group.addTask { [weak self] in
                    for await _ in signalStream {
                        guard let self, !Task.isCancelled else { break }
                        _ = await self.drainPendingWritesOnce()
                    }
                }
                group.addTask { [weak self] in
                    while !Task.isCancelled {
                        let intervalMs = self?.state.withLock { $0.policy.uiBatchIntervalMs } ?? 250
                        try? await Task.sleep(for: .milliseconds(intervalMs))
                        guard let self, !Task.isCancelled else { break }
                        _ = await self.drainPendingWritesOnce()
                        self.flushUIBatches()
                    }
                }
            }
        }
        workerTaskLock.withLock { $0 = task }
    }

    private func drainPendingWritesOnce() async -> Bool {
        let batch = state.withLock { s -> [PendingWriteItem] in
            guard !s.pendingWrites.isEmpty else { return [] }
            let count = min(s.pendingWrites.count, s.policy.writerFlushBatchSize)
            let slice = Array(s.pendingWrites.prefix(count))
            s.pendingWrites.removeFirst(count)
            for item in slice {
                s.pendingWriteBytes = max(0, s.pendingWriteBytes - item.estimatedBytes)
            }
            return slice
        }
        guard !batch.isEmpty else { return false }

        var byEpoch: [UInt64: [DiagnosticEvent]] = [:]
        for item in batch {
            byEpoch[item.epoch, default: []].append(item.event)
        }
        for (epoch, events) in byEpoch {
            await writer.writeBatch(events, epoch: epoch)
        }
        return true
    }

    private func flushUIBatches() {
        let deliveries: [(AsyncStream<DiagnosticSubscriberBatch>.Continuation, DiagnosticSubscriberBatch)] = state.withLock { s in
            guard !s.pendingUIBatch.isEmpty, !s.subscribers.isEmpty else {
                s.pendingUIBatch.removeAll()
                s.uiGapDetected = false
                return []
            }
            let batchEvents = s.pendingUIBatch
            let gap = s.uiGapDetected
            s.pendingUIBatch.removeAll()
            s.uiGapDetected = false

            var out: [(AsyncStream<DiagnosticSubscriberBatch>.Continuation, DiagnosticSubscriberBatch)] = []
            for subID in s.subscribers.keys {
                guard var sub = s.subscribers[subID] else { continue }
                let filtered = batchEvents.filter { $0.sequence > sub.lastDeliveredSequence }
                if let lastSeq = filtered.last?.sequence {
                    sub.lastDeliveredSequence = lastSeq
                    s.subscribers[subID] = sub
                    out.append((
                        sub.continuation,
                        DiagnosticSubscriberBatch(
                            events: filtered,
                            nextCursor: lastSeq,
                            gapDetected: gap,
                            resetRequired: false
                        )
                    ))
                }
            }
            return out
        }
        for (continuation, batch) in deliveries {
            continuation.yield(batch)
        }
    }

    // MARK: - Priority Eviction Helpers

    private static func enforceRingBudget(_ s: inout State) {
        let maxCount = max(16, s.policy.maxRingEvents)
        let maxBytes = max(4096, s.policy.maxRingBytes)
        let criticalReserveCount = max(4, maxCount / 4)

        while s.ring.count > maxCount || s.ringBytes > maxBytes {
            if s.ring.count <= 1 { break }
            // Prefer evicting low-priority (< .notice) items first
            let nonCriticalIdx = s.ring.firstIndex { $0.event.level < .notice }
            let evictIdx: Int
            if let idx = nonCriticalIdx, s.ring.count > criticalReserveCount || s.ring.count > maxCount {
                evictIdx = idx
            } else {
                evictIdx = 0
            }
            let removed = s.ring.remove(at: evictIdx)
            s.ringBytes = max(0, s.ringBytes - removed.estimatedBytes)
            s.ringEvictedCount &+= 1
            s.evictedByLevel[removed.event.level.rawValue, default: 0] &+= 1
            if removed.event.level >= .notice {
                s.ringCriticalLossCount &+= 1
            }
        }
    }

    private static func enforcePendingWriteBudget(_ s: inout State) {
        let maxCount = max(16, s.policy.maxPendingWriteEvents)
        let maxBytes = max(4096, s.policy.maxPendingWriteBytes)
        let criticalReserveCount = max(4, maxCount / 4)

        while s.pendingWrites.count > maxCount || s.pendingWriteBytes > maxBytes {
            if s.pendingWrites.count <= 1 { break }
            let nonCriticalIdx = s.pendingWrites.firstIndex { $0.event.level < .notice }
            let evictIdx: Int
            if let idx = nonCriticalIdx, s.pendingWrites.count > criticalReserveCount || s.pendingWrites.count > maxCount {
                evictIdx = idx
            } else {
                evictIdx = 0
            }
            let removed = s.pendingWrites.remove(at: evictIdx)
            s.pendingWriteBytes = max(0, s.pendingWriteBytes - removed.estimatedBytes)
            s.writerDroppedCount &+= 1
            s.droppedByLevel[removed.event.level.rawValue, default: 0] &+= 1
            if removed.event.level >= .notice {
                s.writerCriticalLossCount &+= 1
            }
        }
    }
}
