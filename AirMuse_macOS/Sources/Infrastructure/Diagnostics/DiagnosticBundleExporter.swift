import CryptoKit
import Domain
import Foundation

// MARK: - Export Outcome & Manifest

public enum DiagnosticExportOutcome: String, Sendable, Codable, Equatable {
    case completeWithinRetention
    case partial
    case failed
}

public struct DiagnosticExportFileEntry: Sendable, Codable, Equatable {
    public let relativePath: String
    public let bytes: Int
    public let sha256: String
}

public struct DiagnosticExportManifest: Sendable, Codable, Equatable {
    public let schemaVersion: Int
    public let exportID: UUID
    public let createdAt: Date
    public let environment: AppEnvironmentInfo
    public let captureMode: DiagnosticCaptureMode
    public let runIDs: [UUID]
    public let highWatermark: UInt64
    public let exportedEventCount: Int
    public let minSequence: UInt64
    public let maxSequence: UInt64
    public let gaps: [DiagnosticGapRecord]
    public let evictedSegmentsCount: Int
    public let componentStatuses: [String: String]
    public let sanitizerRuleVersion: Int
    public let includesLocalDisplayNames: Bool
    public let exportOutcome: DiagnosticExportOutcome
    public let files: [DiagnosticExportFileEntry]
}

public struct DiagnosticExportResult: Sendable {
    public let directoryURL: URL
    public let zipURL: URL?
    public let manifest: DiagnosticExportManifest
    public let summaryMarkdown: String
}

// MARK: - DiagnosticBundleExporter

public enum DiagnosticBundleExporter {

    public static func exportBundle(
        to destinationZipURL: URL,
        logger: AppLogger = .shared,
        snapshotCoordinator: DiagnosticSnapshotCoordinator = .shared,
        performanceAggregator: DiagnosticPerformanceAggregator = .shared,
        createZip: Bool = true
    ) async throws -> DiagnosticExportResult {
        let exportRef = "\(logger.runID.uuidString.prefix(8))-\(Int(Date().timeIntervalSince1970))"
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("AirMuse_Diagnostics_\(exportRef)_\(UUID().uuidString.prefix(6))", isDirectory: true)
        let bundleDir = tempRoot.appendingPathComponent("AirMuse_Diagnostics_\(exportRef)", isDirectory: true)

        defer {
            if createZip {
                try? FileManager.default.removeItem(at: tempRoot)
            }
        }

        let fm = FileManager.default
        try fm.createDirectory(at: bundleDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try fm.createDirectory(at: bundleDir.appendingPathComponent("events"), withIntermediateDirectories: true)
        try fm.createDirectory(at: bundleDir.appendingPathComponent("snapshots"), withIntermediateDirectories: true)
        try fm.createDirectory(at: bundleDir.appendingPathComponent("traces"), withIntermediateDirectories: true)
        try fm.createDirectory(at: bundleDir.appendingPathComponent("performance"), withIntermediateDirectories: true)
        try fm.createDirectory(at: bundleDir.appendingPathComponent("faults"), withIntermediateDirectories: true)

        let retained = await logger.exportRetained(timeoutSeconds: 2.0)
        let snapshots = await snapshotCoordinator.captureAll(logger: logger)
        let perfSummaries = performanceAggregator.allSummaries()

        let encoder = DiagnosticJSONLCodec.makeEncoder()
        let prettyEncoder = DiagnosticJSONLCodec.makeEncoder()
        prettyEncoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        var files: [DiagnosticExportFileEntry] = []

        func writeFile(_ data: Data, relativePath: String) throws {
            let url = bundleDir.appendingPathComponent(relativePath)
            try data.write(to: url, options: .atomic)
            try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            files.append(DiagnosticExportFileEntry(relativePath: relativePath, bytes: data.count, sha256: digest))
        }

        // 1. environment.json
        try writeFile(try prettyEncoder.encode(logger.environment), relativePath: "environment.json")

        // 2. events/events-0001.jsonl
        var eventsData = Data()
        for ev in retained.events {
            if let line = try? encoder.encode(ev) {
                eventsData.append(line)
                eventsData.append(0x0A)
            }
        }
        try writeFile(eventsData, relativePath: "events/events-0001.jsonl")

        // 3. snapshots/<component>.json
        var componentStatuses: [String: String] = [:]
        for snap in snapshots.components {
            componentStatuses[snap.component] = snap.availability.rawValue
            let safeName = snap.component.replacingOccurrences(of: "[^A-Za-z0-9._-]", with: "_", options: .regularExpression)
            try writeFile(try prettyEncoder.encode(snap), relativePath: "snapshots/\(safeName).json")
        }

        // 4. traces/trace-index.json
        let traceGroups = Dictionary(grouping: retained.events, by: \.traceID)
        let traceIndex = traceGroups.map { traceID, evs in
            [
                "traceID": traceID.uuidString,
                "eventCount": String(evs.count),
                "firstEvent": evs.first?.eventName ?? "",
                "lastEvent": evs.last?.eventName ?? "",
                "hasError": evs.contains(where: { $0.level >= .error }) ? "true" : "false"
            ]
        }.sorted { ($0["traceID"] ?? "") < ($1["traceID"] ?? "") }
        try writeFile(try prettyEncoder.encode(traceIndex), relativePath: "traces/trace-index.json")

        // 5. performance/metrics.json
        try writeFile(try prettyEncoder.encode(perfSummaries), relativePath: "performance/metrics.json")

        // 6. faults/invariant-violations.jsonl
        var faultsData = Data()
        for v in snapshots.violations {
            if let line = try? encoder.encode(v) {
                faultsData.append(line)
                faultsData.append(0x0A)
            }
        }
        try writeFile(faultsData, relativePath: "faults/invariant-violations.jsonl")

        // 7. summary.md (AI-first-read summary without guessed root cause)
        let summaryMd = buildSummaryMarkdown(retained: retained, snapshots: snapshots, perf: perfSummaries, environment: logger.environment)
        try writeFile(Data(summaryMd.utf8), relativePath: "summary.md")

        // 8. manifest.json
        let runIDs = Array(Set(retained.events.map(\.runID)))
        let outcome: DiagnosticExportOutcome = retained.isPartial ? .partial : .completeWithinRetention
        let manifest = DiagnosticExportManifest(
            schemaVersion: DiagnosticSchemaVersion.current,
            exportID: UUID(),
            createdAt: Date(),
            environment: logger.environment,
            captureMode: retained.metrics.mode,
            runIDs: runIDs.isEmpty ? [logger.runID] : runIDs,
            highWatermark: retained.highWatermark,
            exportedEventCount: retained.events.count,
            minSequence: retained.events.first?.sequence ?? 0,
            maxSequence: retained.events.last?.sequence ?? 0,
            gaps: retained.manifest.gaps,
            evictedSegmentsCount: retained.manifest.evictedSegments.count,
            componentStatuses: componentStatuses,
            sanitizerRuleVersion: 1,
            includesLocalDisplayNames: false,
            exportOutcome: outcome,
            files: files
        )
        try writeFile(try prettyEncoder.encode(manifest), relativePath: "manifest.json")

        var finalZipURL: URL? = nil
        if createZip {
            try fm.createDirectory(at: destinationZipURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            if fm.fileExists(atPath: destinationZipURL.path) {
                try fm.removeItem(at: destinationZipURL)
            }
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            proc.arguments = ["-c", "-k", "--sequesterRsrc", "--keepParent", bundleDir.path, destinationZipURL.path]
            try proc.run()
            proc.waitUntilExit()
            guard proc.terminationStatus == 0 else {
                throw CoreError.storage("ZIP packaging failed with exit code \(proc.terminationStatus)")
            }
            try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destinationZipURL.path)
            finalZipURL = destinationZipURL
        }

        logger.emit(
            eventName: "diagnostic.export.completed",
            category: "DIAGNOSTICS",
            level: .info,
            outcome: outcome == .completeWithinRetention ? .succeeded : .partial,
            source: DiagnosticSourceLocation(module: "Infrastructure", component: "DiagnosticBundleExporter", function: "exportBundle"),
            payload: {
                DiagnosticEventPayload(
                    fields: [
                        "exportRef": .string(exportRef),
                        "coverage": .string(outcome.rawValue),
                        "gapCount": .int(retained.manifest.gaps.count),
                        "eventCount": .int(retained.events.count)
                    ],
                    message: "Exported diagnostic bundle (\(retained.events.count) events, outcome=\(outcome.rawValue))"
                )
            }
        )

        return DiagnosticExportResult(
            directoryURL: bundleDir,
            zipURL: finalZipURL,
            manifest: manifest,
            summaryMarkdown: summaryMd
        )
    }

    public static func buildSummaryMarkdown(
        retained: DiagnosticRetainedExport,
        snapshots: DiagnosticSnapshotBundle,
        perf: [DiagnosticMetricSummary],
        environment: AppEnvironmentInfo
    ) -> String {
        let errorEvents = retained.events.filter { $0.level >= .error }.suffix(10)
        var lines: [String] = [
            "# AirMuse Diagnostics Summary",
            "- Version/Commit: \(environment.appVersion) (\(environment.buildNumber)) / \(environment.commit)",
            "- OS/Arch: \(environment.osVersion) (\(environment.arch))",
            "- Capture Mode: \(retained.metrics.mode.rawValue)",
            "- Retained Sequence Range: \(retained.metrics.minRetainedSequence)...\(retained.metrics.maxSequence) (total=\(retained.events.count), gaps=\(retained.manifest.gaps.count), ringEvicted=\(retained.metrics.ringEvictedCount), writerDropped=\(retained.metrics.writerDroppedCount))",
            "",
            "## Component Snapshots"
        ]
        for snap in snapshots.components {
            lines.append("- \(snap.component): \(snap.availability.rawValue)")
        }
        lines.append("")
        lines.append("## Invariants")
        for inv in snapshots.invariants {
            lines.append("- \(inv.invariantID): \(inv.status.rawValue) — \(inv.summary)")
        }
        lines.append("")
        lines.append("## Recent Errors & Faults (\(errorEvents.count))")
        for ev in errorEvents {
            lines.append("- [seq \(ev.sequence)] [\(ev.level.rawValue)] \(ev.eventName) trace=\(ev.traceID.uuidString.prefix(8)): \(ev.message)")
        }
        if !perf.isEmpty {
            lines.append("")
            lines.append("## Performance Metrics")
            for p in perf {
                let p50 = p.p50Ms.map { String(format: "%.2fms", $0) } ?? "unavailable"
                let p95 = p.p95Ms.map { String(format: "%.2fms", $0) } ?? "unavailable"
                lines.append("- \(p.metricName) (\(p.source)): n=\(p.sampleCount), p50=\(p50), p95=\(p95)")
            }
        }
        return lines.joined(separator: "\n")
    }
}
