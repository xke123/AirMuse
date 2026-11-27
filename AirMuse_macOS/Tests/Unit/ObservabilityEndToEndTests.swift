import Application
import Domain
import Foundation
import Infrastructure
import PlatformRuntime
import Playback
import Testing

private struct SlowSnapshotProvider: DiagnosticSnapshotProvider {
    let componentName: String = "SlowComponent"
    func captureDiagnosticSnapshot() async -> DiagnosticComponentSnapshot {
        try? await Task.sleep(for: .milliseconds(600))
        return DiagnosticComponentSnapshot(component: componentName, availability: .available)
    }
}

private struct MockFixtureTransport: HTTPTransportProtocol {
    func send(_ request: HTTPRequest, timeoutSeconds: TimeInterval) async throws -> HTTPResponse {
        HTTPResponse(statusCode: 200, data: Data("{\"ok\":true}".utf8), url: request.url)
    }
}

@Suite("LOG07, LOG08 & LOG09: Snapshot, Invariants, Export ZIP & Performance Benchmark Tests")
struct ObservabilityEndToEndTests {

    @Test("T53 & T54: Snapshot collector isolates slow component timeout and evaluates invariants without false positives")
    func t53AndT54SnapshotTimeoutAndInvariants() async {
        let coordinator = DiagnosticSnapshotCoordinator()
        let registry = ProviderSessionRegistry()
        let store = PlaybackStore()
        let engine = NoOpTestEngine()
        let pbCoordinator = PlaybackCoordinatorV2(store: store, engine: engine)

        await coordinator.register(registry)
        await coordinator.register(pbCoordinator)
        await coordinator.register(SlowSnapshotProvider())

        let bundle = await coordinator.captureAll(perComponentTimeoutSeconds: 0.1, totalTimeoutSeconds: 0.8)
        let slow = bundle.components.first(where: { $0.component == "SlowComponent" })
        #expect(slow?.availability == .timeout)
        #expect(bundle.components.contains(where: { $0.component == "ProviderSessionRegistry" && $0.availability == .available }))
        #expect(bundle.components.contains(where: { $0.component == "PlaybackCoordinatorV2" && $0.availability == .available }))

        // EngineRouter was not registered -> INV01 must be .unknown, not .violated
        let inv01 = bundle.invariants.first(where: { $0.invariantID == "INV01" })
        #expect(inv01?.status == .unknown)
        let inv07 = bundle.invariants.first(where: { $0.invariantID == "INV07" })
        #expect(inv07?.status == .satisfied)
    }

    @Test("T05 & T56: Full-chain trace + ZIP export + offline manifest/trace/privacy verification")
    func t05AndT56FullChainAndZipExport() async throws {
        let dir = URL(fileURLWithPath: "/tmp/obs_e2e_\(UUID().uuidString)", isDirectory: true)
        let zipURL = dir.appendingPathComponent("diag_bundle.zip")
        defer { try? FileManager.default.removeItem(at: dir) }

        let logger = AppLogger(logDirectoryURL: dir.appendingPathComponent("logs"), mode: .fullTrace, consoleEchoEnabled: false)
        let snapCoord = DiagnosticSnapshotCoordinator()
        let perfAgg = DiagnosticPerformanceAggregator()

        let registry = ProviderSessionRegistry()
        let router = EngineRouter(registry: registry)
        let http = HTTPClient(transport: MockFixtureTransport())
        await snapCoord.register(registry)
        await snapCoord.register(router)
        await snapCoord.register(http)

        let rootTrace = DiagnosticTrace.makeRoot(context: DiagnosticContext(providerID: "fixture_a"))
        try await DiagnosticTrace.withContext(rootTrace) {
            let req = HTTPRequest(
                url: URL(string: "https://api.example.com/v1/tracks?token=CANARY_SECRET_QUERY")!,
                policy: RequestPolicy(authScope: .publicCatalog(providerID: "fixture_a", storefront: "cn"))
            )
            _ = try await http.send(req)
        }

        perfAgg.recordSample(metric: "ui.frame", durationMs: 0.42, source: "test_benchmark", budgetMs: 16.67)

        let result = try await DiagnosticBundleExporter.exportBundle(
            to: zipURL,
            logger: logger,
            snapshotCoordinator: snapCoord,
            performanceAggregator: perfAgg,
            createZip: true
        )

        #expect(FileManager.default.fileExists(atPath: zipURL.path))
        #expect(result.manifest.exportedEventCount >= 1)
        #expect(!result.manifest.files.isEmpty)
        #expect(result.summaryMarkdown.contains("# AirMuse Diagnostics Summary"))

        // Unzip and verify canary absence & JSONL integrity
        let unzipDir = dir.appendingPathComponent("unzipped", isDirectory: true)
        try FileManager.default.createDirectory(at: unzipDir, withIntermediateDirectories: true)
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        proc.arguments = ["-x", "-k", zipURL.path, unzipDir.path]
        try proc.run()
        proc.waitUntilExit()
        #expect(proc.terminationStatus == 0)

        let bundleFolderName = result.directoryURL.lastPathComponent
        let eventsFile = unzipDir.appendingPathComponent(bundleFolderName).appendingPathComponent("events/events-0001.jsonl")
        let eventsText = try String(contentsOf: eventsFile, encoding: .utf8)
        #expect(!eventsText.contains("CANARY_SECRET_QUERY"))
        let lines = eventsText.split(separator: "\n")
        #expect(lines.count == result.manifest.exportedEventCount)

        await logger.shutdown(timeoutSeconds: 1.0)
    }

    @Test("T58: Off / Normal / FullTrace emission latency benchmark")
    func t58ModeOverheadBenchmark() async {
        let dir = URL(fileURLWithPath: "/tmp/obs_bench_\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let modes: [DiagnosticCaptureMode] = [.off, .normal, .fullTrace]
        let iterations = 500
        let clock = SystemClock()
        let agg = DiagnosticPerformanceAggregator()

        for mode in modes {
            let logger = AppLogger(
                logDirectoryURL: dir.appendingPathComponent(mode.rawValue),
                mode: mode,
                consoleEchoEnabled: false
            )
            // Warmup
            for i in 0..<20 {
                logger.emit(
                    eventName: "bench.warmup",
                    category: "DIAGNOSTICS",
                    level: .info,
                    source: DiagnosticSourceLocation(module: "Tests", component: "Bench", function: "t58"),
                    payload: { DiagnosticEventPayload(fields: ["i": .int(i)], message: "warmup") }
                )
            }
            for i in 0..<iterations {
                let t0 = clock.monotonicNanoseconds
                logger.emit(
                    eventName: "bench.sample",
                    category: "PLAYBACK",
                    level: .info,
                    source: DiagnosticSourceLocation(module: "Tests", component: "Bench", function: "t58"),
                    payload: { DiagnosticEventPayload(fields: ["i": .int(i)], message: "bench item \(i)") }
                )
                let t1 = clock.monotonicNanoseconds
                let ms = Double(t1 >= t0 ? t1 - t0 : 0) / 1_000_000.0
                agg.recordSample(metric: "emit.\(mode.rawValue)", durationMs: ms, source: "t58_benchmark", budgetMs: mode == .normal ? 0.2 : 0.5)
            }
            await logger.shutdown(timeoutSeconds: 1.0)
        }

        let offSummary = agg.summary(for: "emit.off")
        let normalSummary = agg.summary(for: "emit.normal")
        let fullSummary = agg.summary(for: "emit.fullTrace")
        #expect(offSummary.sampleCount == iterations)
        #expect(normalSummary.sampleCount == iterations)
        #expect(fullSummary.sampleCount == iterations)
        print("[T58_BENCHMARK] off_p50=\(String(format: "%.4f", offSummary.p50Ms ?? -1))ms normal_p50=\(String(format: "%.4f", normalSummary.p50Ms ?? -1))ms normal_p95=\(String(format: "%.4f", normalSummary.p95Ms ?? -1))ms full_p50=\(String(format: "%.4f", fullSummary.p50Ms ?? -1))ms full_p95=\(String(format: "%.4f", fullSummary.p95Ms ?? -1))ms")
    }
}

private actor NoOpTestEngine: PlaybackEngineProtocol {
    let engineInstanceID = UUID()
    func events() async -> AsyncStream<EngineEvent> { AsyncStream { _ in } }
    func prepare(sessionContext: SessionContext, deadlineSeconds: TimeInterval) async throws {}
    func execute(_ command: EngineCommand, context: PlaybackOperationContext) async throws {}
    func isolateAndReset() async {}
}
