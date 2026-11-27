import Domain
import Foundation
import Infrastructure
import os
import Testing

// MARK: - Deterministic Test Clock

private final class MutableTestClock: ClockProtocol, @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock<(now: Date, mono: UInt64)>(
        initialState: (Date(timeIntervalSince1970: 1_700_000_000), 1_000_000_000)
    )

    var now: Date {
        lock.withLock { $0.now }
    }

    var monotonicNanoseconds: UInt64 {
        lock.withLock { $0.mono }
    }

    func advance(wallSeconds: TimeInterval, monoMs: UInt64) {
        lock.withLock { state in
            state.now = state.now.addingTimeInterval(wallSeconds)
            state.mono &+= monoMs * 1_000_000
        }
    }

    func sleep(for duration: Duration) async throws {
        try await Task.sleep(for: duration)
    }
}

@Suite("LOG01 & LOG02: Observability Schema, Trace, Sanitizer & Pipeline Tests")
struct ObservabilityPipelineTests {

    private func makeTempDir(_ name: String = "obs_test") -> URL {
        URL(fileURLWithPath: "/tmp/\(name)_\(UUID().uuidString)", isDirectory: true)
    }

    @Test("T01: Schema v1 JSONL roundtrip and unknown version handling")
    func t01SchemaRoundtripAndUnknownVersion() throws {
        let runID = UUID()
        let traceID = UUID()
        let spanID = UUID()
        let event = DiagnosticEvent(
            runID: runID,
            sequence: 42,
            timestamp: Date(timeIntervalSince1970: 1_700_000_123.456),
            monotonicTimeNs: 987_654_321,
            eventName: "playback.intent.created",
            category: "PLAYBACK",
            level: .info,
            traceID: traceID,
            spanID: spanID,
            parentSpanID: nil,
            links: [DiagnosticLink(traceID: UUID(), relation: "triggeredBy")],
            phase: .instant,
            outcome: .accepted,
            durationMs: 12.5,
            context: DiagnosticContext(providerID: "apple_music", operationID: 7),
            fields: [
                "entryCount": .int(3),
                "missingOptional": .absent,
                "tags": .strings(["a", "b"])
            ],
            error: nil,
            source: DiagnosticSourceLocation(module: "Playback", component: "Coordinator", function: "submit"),
            message: "Intent created"
        )

        let encoder = DiagnosticJSONLCodec.makeEncoder()
        let decoder = DiagnosticJSONLCodec.makeDecoder()
        let data = try encoder.encode(event)
        let decoded = try decoder.decode(DiagnosticEvent.self, from: data)

        #expect(decoded.schemaVersion == 1)
        #expect(decoded.runID == runID)
        #expect(decoded.sequence == 42)
        #expect(decoded.eventName == "playback.intent.created")
        #expect(decoded.outcome == .accepted)
        #expect(decoded.fields["missingOptional"] == .absent)

        // Unknown future version fails cleanly with typed error
        let jsonStr = String(data: data, encoding: .utf8)!.replacingOccurrences(of: "\"schemaVersion\":1", with: "\"schemaVersion\":99")
        do {
            _ = try decoder.decode(DiagnosticEvent.self, from: Data(jsonStr.utf8))
            Issue.record("Expected unsupportedSchemaVersion error")
        } catch DiagnosticEventDecodingError.unsupportedSchemaVersion(let ver) {
            #expect(ver == 99)
        }
    }

    @Test("T02 & T14: Concurrent emission assigns unique monotonic sequence without deadlock")
    func t02AndT14ConcurrentSequenceMonotonic() async throws {
        let dir = makeTempDir("t02")
        defer { try? FileManager.default.removeItem(at: dir) }

        let logger = AppLogger(logDirectoryURL: dir, mode: .fullTrace, consoleEchoEnabled: false)
        await withTaskGroup(of: Void.self) { group in
            for worker in 0..<8 {
                group.addTask {
                    for i in 0..<50 {
                        logger.emit(
                            eventName: "test.concurrent.emit",
                            category: "DIAGNOSTICS",
                            level: .debug,
                            source: DiagnosticSourceLocation(module: "Tests", component: "Concurrent", function: "run"),
                            payload: {
                                DiagnosticEventPayload(
                                    fields: ["worker": .int(worker), "iter": .int(i)],
                                    message: "w\(worker)-\(i)"
                                )
                            }
                        )
                    }
                }
            }
        }

        let events = logger.getEvents()
        #expect(events.count >= 400)
        var prev: UInt64 = 0
        for ev in events {
            #expect(ev.sequence > prev)
            #expect(ev.runID == logger.runID)
            prev = ev.sequence
        }
        await logger.shutdown(timeoutSeconds: 1.0)
    }

    @Test("T03: Wall clock backward jump does not affect monotonic durationMs")
    func t03WallClockBackwardDoesNotAffectDuration() {
        let dir = makeTempDir("t03")
        defer { try? FileManager.default.removeItem(at: dir) }

        let clock = MutableTestClock()
        let logger = AppLogger(logDirectoryURL: dir, mode: .fullTrace, clock: clock, consoleEchoEnabled: false)

        let token = logger.beginSpan(
            eventName: "playback.prepare",
            category: "PLAYBACK",
            source: DiagnosticSourceLocation(module: "Tests", component: "Clock", function: "t03"),
            message: "prepare begin"
        )
        // Wall clock jumps backward by 1 hour; monotonic advances by 42 ms
        clock.advance(wallSeconds: -3600, monoMs: 42)
        logger.endSpan(token, outcome: .succeeded, message: "prepare end")

        let endEvent = logger.getEvents().last
        #expect(endEvent?.phase == .end)
        #expect(endEvent?.outcome == .succeeded)
        #expect(endEvent?.durationMs == 42.0)
    }

    @Test("T04: Disabled level does not evaluate payload closure")
    func t04DisabledLevelSkipsPayloadEvaluation() {
        let dir = makeTempDir("t04")
        defer { try? FileManager.default.removeItem(at: dir) }

        let logger = AppLogger(logDirectoryURL: dir, mode: .normal, consoleEchoEnabled: false)
        let evaluated = OSAllocatedUnfairLock<Int>(initialState: 0)

        logger.emit(
            eventName: "test.trace.skipped",
            category: "DIAGNOSTICS",
            level: .trace,
            source: DiagnosticSourceLocation(module: "Tests", component: "Gate", function: "t04"),
            payload: {
                evaluated.withLock { $0 += 1 }
                return DiagnosticEventPayload(message: "expensive")
            }
        )

        #expect(evaluated.withLock { $0 } == 0)
        logger.setCaptureMode(.off)
        logger.emit(
            eventName: "test.off.skipped",
            category: "DIAGNOSTICS",
            level: .error,
            source: DiagnosticSourceLocation(module: "Tests", component: "Gate", function: "t04"),
            payload: {
                evaluated.withLock { $0 += 1 }
                return DiagnosticEventPayload(message: "off")
            }
        )
        #expect(evaluated.withLock { $0 } == 0)
    }

    @Test("T06 & T08: Trace propagation across Task/Actor/callback and span terminal outcomes")
    func t06AndT08TracePropagationAndSpanOutcomes() async {
        let dir = makeTempDir("t06")
        defer { try? FileManager.default.removeItem(at: dir) }

        let logger = AppLogger(logDirectoryURL: dir, mode: .fullTrace, consoleEchoEnabled: false)
        let rootCtx = DiagnosticTrace.makeRoot(context: DiagnosticContext(providerID: "apple_music"))

        await DiagnosticTrace.withContext(rootCtx) {
            let captured = DiagnosticTrace.currentOrRoot()
            let token = logger.beginSpan(
                eventName: "engine.prepare",
                category: "ENGINE",
                source: DiagnosticSourceLocation(module: "Tests", component: "Trace", function: "t06"),
                message: "begin"
            )
            await Task.detached {
                DiagnosticTrace.withContextSync(captured) {
                    logger.emit(
                        eventName: "bridge.callback",
                        category: "BRIDGE",
                        level: .info,
                        source: DiagnosticSourceLocation(module: "Tests", component: "Callback", function: "detached"),
                        payload: { DiagnosticEventPayload(message: "callback") }
                    )
                }
            }.value
            logger.endSpan(token, outcome: .cancelled, message: "cancelled")
        }

        let events = logger.getEvents().filter { $0.eventName != "diagnostic.capture.started" }
        #expect(events.count == 3)
        #expect(events.allSatisfy { $0.traceID == rootCtx.traceID })
        #expect(events.last?.phase == .end)
        #expect(events.last?.outcome == .cancelled)
    }

    @Test("T10, T11, T12: Sanitizer redacts nested JSON, URL-encoded OAuth, JWT, paths, and newline injection")
    func t10T11T12SanitizerCanaryCoverage() async throws {
        let dir = makeTempDir("t10")
        defer { try? FileManager.default.removeItem(at: dir) }

        let logger = AppLogger(logDirectoryURL: dir, mode: .fullTrace, consoleEchoEnabled: false)
        let canaries = [
            "CANARY_BEARER_SECRET_XYZ",
            "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiJDQU5BUllfSldUIn0.SIGNATURE_CANARY",
            "CANARY_MEDIA_USER_TOKEN_999",
            "CANARY_OAUTH_CODE_888",
            "CANARY_PASSWORD_777"
        ]

        logger.log(
            category: .auth,
            level: .error,
            correlationID: "corr\nFAKE_LOG_LINE\rINJECTED",
            message: "Auth failed Bearer \(canaries[0]) jwt=\(canaries[1]) path=/Users/alice/Library/Keychain",
            details: "{\"password\":\"\(canaries[4])\",\"nested\":{\"media_user_token\":\"\(canaries[2])\"}} https://example.com/cb?code=\(canaries[3])&state=abc%26token%3D\(canaries[0])"
        )

        let nsErr = NSError(
            domain: "TestDomain",
            code: 401,
            userInfo: [
                NSLocalizedDescriptionKey: "Failed with Bearer \(canaries[0])",
                "rawSecret": canaries[4]
            ]
        )
        let safeErr = LogSanitizer.sanitizeError(nsErr, stage: "auth")
        #expect(!safeErr.safeSummary.contains(canaries[0]))
        #expect(safeErr.domain == "TestDomain")
        #expect(safeErr.code == "401")

        let exported = await logger.exportRetained(timeoutSeconds: 1.0)
        let encoder = DiagnosticJSONLCodec.makeEncoder()
        for ev in exported.events {
            let line = String(data: try encoder.encode(ev), encoding: .utf8)!
            #expect(!line.contains("\n"))
            #expect(!line.contains("\r"))
            #expect(!line.contains("/Users/alice"))
            for canary in canaries {
                #expect(!line.contains(canary))
            }
        }
        await logger.shutdown(timeoutSeconds: 1.0)
    }

    @Test("T15 & T16: Priority eviction preserves critical events and counts critical loss when exceeded")
    func t15T16PriorityEvictionAndCriticalLoss() async {
        let dir = makeTempDir("t15")
        defer { try? FileManager.default.removeItem(at: dir) }

        let policy = DiagnosticBudgetPolicy(
            mode: .fullTrace,
            maxRingEvents: 20,
            maxRingBytes: 1024 * 1024,
            maxPendingWriteEvents: 20,
            maxPendingWriteBytes: 1024 * 1024,
            maxSegmentBytes: 64 * 1024,
            maxSegments: 3,
            retentionDays: 3,
            uiBatchIntervalMs: 100,
            progressAggregateIntervalSeconds: 1
        )
        let logger = AppLogger(logDirectoryURL: dir, mode: .fullTrace, policy: policy, consoleEchoEnabled: false)

        logger.emit(
            eventName: "critical.state",
            category: "PLAYBACK",
            level: .error,
            source: DiagnosticSourceLocation(module: "Tests", component: "Evict", function: "t15"),
            payload: { DiagnosticEventPayload(message: "important error") }
        )
        for i in 0..<30 {
            logger.emit(
                eventName: "noise.trace",
                category: "UI",
                level: .trace,
                source: DiagnosticSourceLocation(module: "Tests", component: "Evict", function: "t15"),
                payload: { DiagnosticEventPayload(message: "trace-\(i)") }
            )
        }

        let retained = logger.getEvents()
        #expect(retained.contains(where: { $0.eventName == "critical.state" }))
        let metrics = await logger.metricsSnapshot()
        #expect(metrics.ringEvictedCount > 0)

        // Now flood with critical events to verify criticalLossCount
        for i in 0..<25 {
            logger.emit(
                eventName: "critical.flood",
                category: "ERROR",
                level: .fault,
                source: DiagnosticSourceLocation(module: "Tests", component: "Evict", function: "t16"),
                payload: { DiagnosticEventPayload(message: "fault-\(i)") }
            )
        }
        let metrics2 = await logger.metricsSnapshot()
        #expect(metrics2.ringCriticalLossCount > 0)
    }

    @Test("T17 & T57: Writer I/O failure records failure count without recursion or crash")
    func t17AndT57WriterFailureNonRecursive() async {
        // Point logDirectoryURL at an existing regular file so directory/file writes fail
        let blockerFile = URL(fileURLWithPath: "/tmp/obs_blocker_\(UUID().uuidString)")
        FileManager.default.createFile(atPath: blockerFile.path, contents: Data("block".utf8))
        defer { try? FileManager.default.removeItem(at: blockerFile) }

        let logger = AppLogger(logDirectoryURL: blockerFile, mode: .normal, consoleEchoEnabled: false)
        for i in 0..<10 {
            logger.log(category: .playback, level: .error, message: "event \(i)")
        }
        _ = await logger.flush(timeoutSeconds: 0.5)
        let metrics = await logger.metricsSnapshot()
        #expect(metrics.writerFailedCount > 0)
        #expect(metrics.totalEmitted >= 10)
    }

    @Test("T18, T19, T20, T22, T23: Rotation, truncation recovery, export H, delete barrier, and subscriber cursor")
    func t18ThroughT23PipelineLifecycle() async throws {
        let dir = makeTempDir("t18")
        defer { try? FileManager.default.removeItem(at: dir) }

        let policy = DiagnosticBudgetPolicy(
            mode: .fullTrace,
            maxRingEvents: 500,
            maxRingBytes: 1024 * 1024,
            maxPendingWriteEvents: 500,
            maxPendingWriteBytes: 1024 * 1024,
            maxSegmentBytes: 1024,
            maxSegments: 3,
            retentionDays: 3,
            uiBatchIntervalMs: 50,
            progressAggregateIntervalSeconds: 1,
            writerFlushBatchSize: 8
        )

        let logger = AppLogger(logDirectoryURL: dir, mode: .fullTrace, policy: policy, consoleEchoEnabled: false)
        let sub = logger.subscribe(fromCursor: nil)
        #expect(sub.snapshot.count >= 1)

        for i in 0..<30 {
            logger.emit(
                eventName: "test.rotation.item",
                category: "QUEUE",
                level: .info,
                source: DiagnosticSourceLocation(module: "Tests", component: "Pipeline", function: "t18"),
                payload: { DiagnosticEventPayload(fields: ["idx": .int(i)], message: String(repeating: "a", count: 80)) }
            )
        }

        let exported = await logger.exportRetained(timeoutSeconds: 2.0)
        #expect(exported.events.count >= 31)
        #expect(exported.metrics.rotationCount > 0)
        #expect(exported.manifest.segments.count <= 3)

        // Verify deleteAllLogs barrier prevents resurrection
        await logger.deleteAllLogs()
        let afterDelete = await logger.exportRetained(timeoutSeconds: 1.0)
        #expect(afterDelete.events.isEmpty)

        // T19: Simulate crash-truncated segment and verify recovery records gap
        let segURL = dir.appendingPathComponent("events-0099.jsonl")
        let validEv = DiagnosticEvent(
            runID: logger.runID,
            sequence: 100,
            timestamp: Date(),
            monotonicTimeNs: 1000,
            eventName: "test.valid",
            category: "DIAGNOSTICS",
            level: .info,
            traceID: UUID(),
            spanID: UUID(),
            source: DiagnosticSourceLocation(module: "Tests", component: "Crash", function: "t19"),
            message: "valid"
        )
        let validData = try DiagnosticJSONLCodec.makeEncoder().encode(validEv)
        var corrupted = validData
        corrupted.append(0x0A)
        corrupted.append(contentsOf: "{\"schemaVersion\":1,\"truncated".utf8)
        try corrupted.write(to: segURL)

        let badManifest = DiagnosticDiskManifest(
            activeRunID: logger.runID,
            nextSegmentIndex: 100,
            segments: [
                DiagnosticSegmentMetadata(
                    filename: "events-0099.jsonl",
                    runID: logger.runID,
                    minSequence: 100,
                    maxSequence: 101,
                    eventCount: 2,
                    byteSize: corrupted.count,
                    complete: false
                )
            ],
            cleanShutdown: false
        )
        let mData = try DiagnosticJSONLCodec.makeEncoder().encode(badManifest)
        try mData.write(to: dir.appendingPathComponent("manifest.json"))

        let recoveredLogger = AppLogger(logDirectoryURL: dir, mode: .fullTrace, policy: policy, consoleEchoEnabled: false)
        let recMetrics = await recoveredLogger.metricsSnapshot()
        #expect(recMetrics.truncatedTailRecoveryCount == 1)
        let recExport = await recoveredLogger.exportRetained(timeoutSeconds: 1.0)
        #expect(recExport.manifest.gaps.contains(where: { $0.reason == "crash_truncated_tail" }))
        await recoveredLogger.shutdown(timeoutSeconds: 1.0)
    }
}
