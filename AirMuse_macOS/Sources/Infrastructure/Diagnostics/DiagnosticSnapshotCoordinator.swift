import Domain
import Foundation

// MARK: - InvariantCheckResult

public enum InvariantEvaluationStatus: String, Sendable, Codable, Equatable {
    case satisfied
    case violated
    case unknown
}

public struct InvariantCheckReport: Sendable, Codable, Equatable {
    public let invariantID: String
    public let status: InvariantEvaluationStatus
    public let summary: String
    public let evidence: [String: DiagnosticFieldValue]

    public init(
        invariantID: String,
        status: InvariantEvaluationStatus,
        summary: String,
        evidence: [String: DiagnosticFieldValue] = [:]
    ) {
        self.invariantID = invariantID
        self.status = status
        self.summary = summary
        self.evidence = evidence
    }
}

// MARK: - DiagnosticSnapshotBundle

public struct DiagnosticSnapshotBundle: Sendable, Codable, Equatable {
    public let snapshotRef: UUID
    public let capturedAt: Date
    public let components: [DiagnosticComponentSnapshot]
    public let invariants: [InvariantCheckReport]
    public let violations: [InvariantViolationRecord]
}

// MARK: - DiagnosticSnapshotCoordinator

/// Bounded, strictly read-only snapshot collector and invariant evaluator.
/// Never activates dormant platforms, never initiates network/audio writes, and never mutates business state.
public actor DiagnosticSnapshotCoordinator {

    public static let shared = DiagnosticSnapshotCoordinator()

    private var providers: [String: any DiagnosticSnapshotProvider] = [:]
    private var recentViolations: [InvariantViolationRecord] = []
    private var lastViolationByInvariant: [String: Date] = [:]

    public init() {}

    public func register(_ provider: any DiagnosticSnapshotProvider) {
        providers[provider.componentName] = provider
    }

    public func unregister(componentName: String) {
        providers.removeValue(forKey: componentName)
    }

    public func registeredComponents() -> [String] {
        Array(providers.keys).sorted()
    }

    public func recordedViolations() -> [InvariantViolationRecord] {
        recentViolations
    }

    public func captureAll(
        perComponentTimeoutSeconds: TimeInterval = 0.4,
        totalTimeoutSeconds: TimeInterval = 1.5,
        logger: AppLogger = .shared
    ) async -> DiagnosticSnapshotBundle {
        let snapshotRef = UUID()
        let capturedAt = Date()
        let currentProviders = providers

        var collected: [DiagnosticComponentSnapshot] = []
        let loggerSnap = await captureLoggerSnapshot(logger: logger)
        collected.append(loggerSnap)

        let timeoutNs = UInt64(max(0.05, perComponentTimeoutSeconds) * 1_000_000_000)
        let overallDeadline = Date().addingTimeInterval(max(0.1, totalTimeoutSeconds))

        await withTaskGroup(of: DiagnosticComponentSnapshot.self) { group in
            for (name, provider) in currentProviders.sorted(by: { $0.key < $1.key }) {
                group.addTask {
                    await Self.captureWithTimeout(name: name, provider: provider, timeoutNs: timeoutNs)
                }
            }
            for await snap in group {
                collected.append(snap)
                if Date() >= overallDeadline {
                    group.cancelAll()
                }
            }
        }

        // Fill any missing providers as timeout/partial if overall deadline cancelled them
        let capturedNames = Set(collected.map(\.component))
        for name in currentProviders.keys.sorted() where !capturedNames.contains(name) {
            collected.append(
                DiagnosticComponentSnapshot(
                    component: name,
                    capturedAt: capturedAt,
                    availability: .timeout,
                    data: ["reason": .string("total_timeout_exceeded")]
                )
            )
        }

        collected.sort { $0.component < $1.component }

        let invariants = evaluateInvariants(from: collected, events: logger.getEvents())
        var newViolations: [InvariantViolationRecord] = []
        for report in invariants where report.status == .violated {
            let now = Date()
            if let last = lastViolationByInvariant[report.invariantID], now.timeIntervalSince(last) < 5.0 {
                continue // Deduplicate repeated FAULTs within 5s
            }
            lastViolationByInvariant[report.invariantID] = now
            let violation = InvariantViolationRecord(
                invariantID: report.invariantID,
                timestamp: now,
                traceID: DiagnosticTrace.current?.traceID,
                summary: report.summary,
                evidence: report.evidence,
                snapshotRef: snapshotRef.uuidString
            )
            newViolations.append(violation)
            recentViolations.append(violation)
            if recentViolations.count > 128 {
                recentViolations.removeFirst(recentViolations.count - 128)
            }
            logger.emit(
                eventName: "invariant.violation",
                category: "DIAGNOSTICS",
                level: .fault,
                outcome: .failed,
                source: DiagnosticSourceLocation(module: "Infrastructure", component: "DiagnosticSnapshotCoordinator", function: "captureAll"),
                payload: {
                    DiagnosticEventPayload(
                        fields: report.evidence.merging([
                            "invariantID": .string(report.invariantID),
                            "snapshotRef": .string(snapshotRef.uuidString)
                        ]) { a, _ in a },
                        message: "Invariant \(report.invariantID) violated: \(report.summary)"
                    )
                }
            )
        }

        let statusSummary = collected.map { "\($0.component):\($0.availability.rawValue)" }
        logger.emit(
            eventName: "diagnostic.snapshot.completed",
            category: "DIAGNOSTICS",
            level: .info,
            outcome: collected.allSatisfy({ $0.availability == .available }) ? .succeeded : .partial,
            source: DiagnosticSourceLocation(module: "Infrastructure", component: "DiagnosticSnapshotCoordinator", function: "captureAll"),
            payload: {
                DiagnosticEventPayload(
                    fields: [
                        "snapshotRef": .string(snapshotRef.uuidString),
                        "componentStatuses": .strings(statusSummary)
                    ],
                    message: "Captured \(collected.count) read-only component snapshots"
                )
            }
        )

        return DiagnosticSnapshotBundle(
            snapshotRef: snapshotRef,
            capturedAt: capturedAt,
            components: collected,
            invariants: invariants,
            violations: recentViolations
        )
    }

    private func captureLoggerSnapshot(logger: AppLogger) async -> DiagnosticComponentSnapshot {
        let m = await logger.metricsSnapshot()
        return DiagnosticComponentSnapshot(
            component: "Logger",
            availability: .available,
            data: [
                "mode": .string(m.mode.rawValue),
                "totalEmitted": .uint64(m.totalEmitted),
                "ringRetainedCount": .int(m.ringRetainedCount),
                "ringRetainedBytes": .int(m.ringRetainedBytes),
                "ringEvictedCount": .uint64(m.ringEvictedCount),
                "writerDroppedCount": .uint64(m.writerDroppedCount),
                "writerWrittenCount": .uint64(m.writerWrittenCount),
                "writerFailedCount": .uint64(m.writerFailedCount),
                "rotationCount": .uint64(m.rotationCount),
                "minRetainedSequence": .uint64(m.minRetainedSequence),
                "maxSequence": .uint64(m.maxSequence)
            ]
        )
    }

    private static func captureWithTimeout(
        name: String,
        provider: any DiagnosticSnapshotProvider,
        timeoutNs: UInt64
    ) async -> DiagnosticComponentSnapshot {
        await withTaskGroup(of: DiagnosticComponentSnapshot.self) { group in
            group.addTask {
                await provider.captureDiagnosticSnapshot()
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: timeoutNs)
                return DiagnosticComponentSnapshot(
                    component: name,
                    availability: .timeout,
                    data: ["reason": .string("component_timeout")]
                )
            }
            let first = await group.next() ?? DiagnosticComponentSnapshot(component: name, availability: .unavailable)
            group.cancelAll()
            return first
        }
    }

    // MARK: - Read-Only Invariants (INV01-INV15)

    private func evaluateInvariants(
        from snapshots: [DiagnosticComponentSnapshot],
        events: [DiagnosticEvent]
    ) -> [InvariantCheckReport] {
        let byName = Dictionary(uniqueKeysWithValues: snapshots.map { ($0.component, $0) })
        var reports: [InvariantCheckReport] = []

        // INV01: Single audio lease
        if let router = byName["EngineRouter"], router.availability == .available {
            if case .int(let activeCount) = router.data["activeAudioCount"], activeCount > 1 {
                reports.append(InvariantCheckReport(
                    invariantID: "INV01",
                    status: .violated,
                    summary: "Multiple active audio engines detected (\(activeCount))",
                    evidence: ["activeAudioCount": .int(activeCount)]
                ))
            } else {
                reports.append(InvariantCheckReport(invariantID: "INV01", status: .satisfied, summary: "Single audio lease maintained"))
            }
        } else {
            reports.append(InvariantCheckReport(invariantID: "INV01", status: .unknown, summary: "EngineRouter snapshot unavailable"))
        }

        // INV07: Queue entry UUID uniqueness
        if let queue = byName["QueueManager"] ?? byName["PlaybackCoordinatorV2"], queue.availability == .available {
            if case .bool(let unique) = queue.data["entryUUIDsUnique"], !unique {
                reports.append(InvariantCheckReport(invariantID: "INV07", status: .violated, summary: "Duplicate QueueEntry UUIDs detected"))
            } else {
                reports.append(InvariantCheckReport(invariantID: "INV07", status: .satisfied, summary: "QueueEntry UUIDs unique"))
            }
        } else {
            reports.append(InvariantCheckReport(invariantID: "INV07", status: .unknown, summary: "QueueManager snapshot unavailable"))
        }

        // INV12: Origin navigation never mutates playback
        let navMutated = events.contains {
            $0.eventName == "navigation.completed" && $0.fields["causedPlaybackMutation"] == .bool(true)
        }
        reports.append(InvariantCheckReport(
            invariantID: "INV12",
            status: navMutated ? .violated : .satisfied,
            summary: navMutated ? "Origin navigation caused playback mutation" : "Origin navigation remained playback-free"
        ))

        // INV15: Non-active engine resources bounded
        if let router = byName["EngineRouter"], router.availability == .available {
            if case .int(let candidates) = router.data["candidateCount"], candidates > 4 {
                reports.append(InvariantCheckReport(
                    invariantID: "INV15",
                    status: .violated,
                    summary: "Unbounded candidate engines (\(candidates))",
                    evidence: ["candidateCount": .int(candidates)]
                ))
            } else {
                reports.append(InvariantCheckReport(invariantID: "INV15", status: .satisfied, summary: "Candidate engines bounded"))
            }
        } else {
            reports.append(InvariantCheckReport(invariantID: "INV15", status: .unknown, summary: "EngineRouter snapshot unavailable"))
        }

        return reports
    }
}
