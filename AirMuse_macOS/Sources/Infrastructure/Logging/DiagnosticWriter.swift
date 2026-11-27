import Domain
import Foundation

// MARK: - DiagnosticBudgetPolicy

public struct DiagnosticBudgetPolicy: Sendable, Equatable {
    public let mode: DiagnosticCaptureMode
    public let maxRingEvents: Int
    public let maxRingBytes: Int
    public let maxPendingWriteEvents: Int
    public let maxPendingWriteBytes: Int
    public let maxSegmentBytes: Int
    public let maxSegments: Int
    public let retentionDays: Int
    public let uiBatchIntervalMs: Int
    public let progressAggregateIntervalSeconds: TimeInterval
    public let writerFlushBatchSize: Int
    public let writerFlushIntervalMs: Int

    public init(
        mode: DiagnosticCaptureMode,
        maxRingEvents: Int,
        maxRingBytes: Int,
        maxPendingWriteEvents: Int = 4096,
        maxPendingWriteBytes: Int = 4 * 1024 * 1024,
        maxSegmentBytes: Int,
        maxSegments: Int,
        retentionDays: Int,
        uiBatchIntervalMs: Int,
        progressAggregateIntervalSeconds: TimeInterval,
        writerFlushBatchSize: Int = 64,
        writerFlushIntervalMs: Int = 250
    ) {
        self.mode = mode
        self.maxRingEvents = maxRingEvents
        self.maxRingBytes = maxRingBytes
        self.maxPendingWriteEvents = maxPendingWriteEvents
        self.maxPendingWriteBytes = maxPendingWriteBytes
        self.maxSegmentBytes = maxSegmentBytes
        self.maxSegments = maxSegments
        self.retentionDays = retentionDays
        self.uiBatchIntervalMs = uiBatchIntervalMs
        self.progressAggregateIntervalSeconds = progressAggregateIntervalSeconds
        self.writerFlushBatchSize = writerFlushBatchSize
        self.writerFlushIntervalMs = writerFlushIntervalMs
    }

    public static func forMode(_ mode: DiagnosticCaptureMode) -> DiagnosticBudgetPolicy {
        switch mode {
        case .off:
            return DiagnosticBudgetPolicy(
                mode: .off,
                maxRingEvents: 256,
                maxRingBytes: 512 * 1024,
                maxPendingWriteEvents: 256,
                maxPendingWriteBytes: 512 * 1024,
                maxSegmentBytes: 1024 * 1024,
                maxSegments: 2,
                retentionDays: 1,
                uiBatchIntervalMs: 250,
                progressAggregateIntervalSeconds: 5
            )
        case .normal:
            return DiagnosticBudgetPolicy(
                mode: .normal,
                maxRingEvents: 2000,
                maxRingBytes: 8 * 1024 * 1024,
                maxSegmentBytes: 5 * 1024 * 1024,
                maxSegments: 5,
                retentionDays: 7,
                uiBatchIntervalMs: 250,
                progressAggregateIntervalSeconds: 5
            )
        case .debug:
            return DiagnosticBudgetPolicy(
                mode: .debug,
                maxRingEvents: 5000,
                maxRingBytes: 16 * 1024 * 1024,
                maxSegmentBytes: 10 * 1024 * 1024,
                maxSegments: 5,
                retentionDays: 3,
                uiBatchIntervalMs: 150,
                progressAggregateIntervalSeconds: 2
            )
        case .fullTrace:
            return DiagnosticBudgetPolicy(
                mode: .fullTrace,
                maxRingEvents: 10000,
                maxRingBytes: 32 * 1024 * 1024,
                maxSegmentBytes: 10 * 1024 * 1024,
                maxSegments: 10,
                retentionDays: 3,
                uiBatchIntervalMs: 100,
                progressAggregateIntervalSeconds: 1
            )
        case .performance:
            return DiagnosticBudgetPolicy(
                mode: .performance,
                maxRingEvents: 2000,
                maxRingBytes: 8 * 1024 * 1024,
                maxSegmentBytes: 5 * 1024 * 1024,
                maxSegments: 5,
                retentionDays: 3,
                uiBatchIntervalMs: 250,
                progressAggregateIntervalSeconds: 5
            )
        }
    }
}

// MARK: - SequenceRange & Segment Metadata

public struct SequenceRange: Sendable, Codable, Equatable, Hashable {
    public let runID: UUID
    public let start: UInt64
    public let end: UInt64

    public init(runID: UUID, start: UInt64, end: UInt64) {
        self.runID = runID
        self.start = start
        self.end = end
    }
}

public struct DiagnosticGapRecord: Sendable, Codable, Equatable {
    public let runID: UUID
    public let startSequence: UInt64
    public let endSequence: UInt64
    public let reason: String
    public let recordedAt: Date

    public init(runID: UUID, startSequence: UInt64, endSequence: UInt64, reason: String, recordedAt: Date = Date()) {
        self.runID = runID
        self.startSequence = startSequence
        self.endSequence = endSequence
        self.reason = reason
        self.recordedAt = recordedAt
    }
}

public struct DiagnosticSegmentMetadata: Sendable, Codable, Equatable {
    public let filename: String
    public let runID: UUID
    public let minSequence: UInt64
    public var maxSequence: UInt64
    public var eventCount: Int
    public var byteSize: Int
    public let createdAt: Date
    public var closedAt: Date?
    public var complete: Bool
    public var hasTruncatedTail: Bool

    public init(
        filename: String,
        runID: UUID,
        minSequence: UInt64,
        maxSequence: UInt64,
        eventCount: Int,
        byteSize: Int,
        createdAt: Date = Date(),
        closedAt: Date? = nil,
        complete: Bool = false,
        hasTruncatedTail: Bool = false
    ) {
        self.filename = filename
        self.runID = runID
        self.minSequence = minSequence
        self.maxSequence = maxSequence
        self.eventCount = eventCount
        self.byteSize = byteSize
        self.createdAt = createdAt
        self.closedAt = closedAt
        self.complete = complete
        self.hasTruncatedTail = hasTruncatedTail
    }
}

public struct DiagnosticDiskManifest: Sendable, Codable, Equatable {
    public var schemaVersion: Int
    public var activeRunID: UUID
    public var nextSegmentIndex: Int
    public var segments: [DiagnosticSegmentMetadata]
    public var evictedSegments: [DiagnosticSegmentMetadata]
    public var gaps: [DiagnosticGapRecord]
    public var cleanShutdown: Bool
    public var updatedAt: Date

    public init(
        schemaVersion: Int = DiagnosticSchemaVersion.current,
        activeRunID: UUID,
        nextSegmentIndex: Int = 1,
        segments: [DiagnosticSegmentMetadata] = [],
        evictedSegments: [DiagnosticSegmentMetadata] = [],
        gaps: [DiagnosticGapRecord] = [],
        cleanShutdown: Bool = false,
        updatedAt: Date = Date()
    ) {
        self.schemaVersion = schemaVersion
        self.activeRunID = activeRunID
        self.nextSegmentIndex = nextSegmentIndex
        self.segments = segments
        self.evictedSegments = evictedSegments
        self.gaps = gaps
        self.cleanShutdown = cleanShutdown
        self.updatedAt = updatedAt
    }
}

// MARK: - Writer Stats (Emergency / Non-recursive)

public struct DiagnosticWriterStats: Sendable, Equatable {
    public var writtenCount: UInt64 = 0
    public var writtenBytes: UInt64 = 0
    public var writerFailedCount: UInt64 = 0
    public var rotationCount: UInt64 = 0
    public var evictedSegmentCount: UInt64 = 0
    public var truncatedTailRecoveryCount: UInt64 = 0
    public var lastWrittenSequence: UInt64 = 0
    public var lastErrorSummary: String?
}

// MARK: - DiagnosticWriter

/// Single-writer actor responsible for JSONL encoding, bounded segment rotation,
/// atomic manifest updates, truncation recovery, and safe deletion barriers.
/// Never calls back into `AppLogger` on failure (uses `DiagnosticWriterStats` instead).
public actor DiagnosticWriter {
    private let directoryURL: URL
    private let runID: UUID
    private var policy: DiagnosticBudgetPolicy
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    private var manifest: DiagnosticDiskManifest
    private var stats = DiagnosticWriterStats()
    private var deletionEpoch: UInt64 = 0
    private var pinnedSegmentFilenames: Set<String> = []

    public init(
        directoryURL: URL,
        runID: UUID,
        policy: DiagnosticBudgetPolicy
    ) {
        self.directoryURL = directoryURL
        self.runID = runID
        self.policy = policy
        self.encoder = DiagnosticJSONLCodec.makeEncoder()
        self.decoder = DiagnosticJSONLCodec.makeDecoder()
        self.manifest = DiagnosticDiskManifest(activeRunID: runID)

        Self.ensurePrivateDirectory(directoryURL)
        let recovered = Self.loadAndRecoverManifest(
            directoryURL: directoryURL,
            currentRunID: runID,
            decoder: self.decoder
        )
        self.manifest = recovered.manifest
        self.stats.truncatedTailRecoveryCount = recovered.truncatedTailsFound
        Self.writeManifestAtomically(self.manifest, to: directoryURL)
    }

    public func updatePolicy(_ newPolicy: DiagnosticBudgetPolicy) {
        self.policy = newPolicy
        enforceRetentionBudget()
    }

    public func currentStats() -> DiagnosticWriterStats {
        stats
    }

    public func currentManifest() -> DiagnosticDiskManifest {
        manifest
    }

    public func currentDeletionEpoch() -> UInt64 {
        deletionEpoch
    }

    /// Writes a batch of sanitized events to the active JSONL segment.
    /// If `epoch` is older than `deletionEpoch`, the batch is discarded so deleted history never resurrects.
    public func writeBatch(_ events: [DiagnosticEvent], epoch: UInt64) {
        guard epoch == deletionEpoch, !events.isEmpty else { return }
        Self.ensurePrivateDirectory(directoryURL)

        var encodedLines: [(event: DiagnosticEvent, data: Data)] = []
        encodedLines.reserveCapacity(events.count)

        for event in events {
            do {
                var data = try encoder.encode(event)
                data.append(0x0A) // newline
                encodedLines.append((event, data))
            } catch {
                stats.writerFailedCount &+= 1
                stats.lastErrorSummary = "encode_failed"
            }
        }

        guard !encodedLines.isEmpty else { return }

        for (event, lineData) in encodedLines {
            if shouldRotateBeforeWriting(additionalBytes: lineData.count) {
                rotateActiveSegment()
            }
            let segIndex = ensureActiveSegmentIndex(startingWith: event)
            let filename = manifest.segments[segIndex].filename
            let fileURL = directoryURL.appendingPathComponent(filename)

            do {
                try Self.appendData(lineData, to: fileURL)
                manifest.segments[segIndex].maxSequence = max(manifest.segments[segIndex].maxSequence, event.sequence)
                manifest.segments[segIndex].eventCount += 1
                manifest.segments[segIndex].byteSize += lineData.count
                stats.writtenCount &+= 1
                stats.writtenBytes &+= UInt64(lineData.count)
                stats.lastWrittenSequence = max(stats.lastWrittenSequence, event.sequence)
            } catch {
                stats.writerFailedCount &+= 1
                stats.lastErrorSummary = LogSanitizer.sanitizeSingleLine(error.localizedDescription, maxLength: 128)
                manifest.gaps.append(
                    DiagnosticGapRecord(
                        runID: event.runID,
                        startSequence: event.sequence,
                        endSequence: event.sequence,
                        reason: "writer_io_failed"
                    )
                )
            }
        }

        manifest.updatedAt = Date()
        enforceRetentionBudget()
        Self.writeManifestAtomically(manifest, to: directoryURL)
    }

    public func recordGap(_ gap: DiagnosticGapRecord) {
        manifest.gaps.append(gap)
        if manifest.gaps.count > 512 {
            manifest.gaps.removeFirst(manifest.gaps.count - 512)
        }
        manifest.updatedAt = Date()
        Self.writeManifestAtomically(manifest, to: directoryURL)
    }

    public func markCleanShutdown() {
        if let lastIdx = manifest.segments.indices.last {
            manifest.segments[lastIdx].closedAt = Date()
            manifest.segments[lastIdx].complete = true
        }
        manifest.cleanShutdown = true
        manifest.updatedAt = Date()
        Self.writeManifestAtomically(manifest, to: directoryURL)
    }

    /// Pins currently retained segments during export (bounded by maxSegments + 2) and returns their URLs.
    public func pinRetainedSegmentsForExport() -> (manifest: DiagnosticDiskManifest, segmentURLs: [URL], partialDueToPinBudget: Bool) {
        let maxPin = max(1, policy.maxSegments + 2)
        let selected = Array(manifest.segments.suffix(maxPin))
        let partial = manifest.segments.count > maxPin
        for seg in selected {
            pinnedSegmentFilenames.insert(seg.filename)
        }
        let urls = selected.map { directoryURL.appendingPathComponent($0.filename) }
        return (manifest, urls, partial)
    }

    public func unpinSegments(_ filenames: [String]) {
        for fn in filenames {
            pinnedSegmentFilenames.remove(fn)
        }
        enforceRetentionBudget()
    }

    /// Reads all retained events from disk segments (deduplication is handled by caller/exporter).
    public func readRetainedEvents() -> (events: [DiagnosticEvent], truncatedLinesSkipped: Int) {
        var result: [DiagnosticEvent] = []
        var skipped = 0
        for seg in manifest.segments {
            let url = directoryURL.appendingPathComponent(seg.filename)
            guard let data = try? Data(contentsOf: url) else { continue }
            let lines = data.split(separator: 0x0A, omittingEmptySubsequences: true)
            for lineData in lines {
                if let event = try? decoder.decode(DiagnosticEvent.self, from: Data(lineData)) {
                    result.append(event)
                } else {
                    skipped += 1
                }
            }
        }
        return (result, skipped)
    }

    /// Deletes all persisted log segments and resets manifest under a new deletionEpoch barrier.
    public func deleteAllLogs() -> UInt64 {
        deletionEpoch &+= 1
        let fm = FileManager.default
        if let items = try? fm.contentsOfDirectory(at: directoryURL, includingPropertiesForKeys: nil) {
            for item in items where item.lastPathComponent.hasPrefix("events-") || item.lastPathComponent == "manifest.json" {
                try? fm.removeItem(at: item)
            }
        }
        pinnedSegmentFilenames.removeAll()
        manifest = DiagnosticDiskManifest(activeRunID: runID)
        stats.lastWrittenSequence = 0
        Self.writeManifestAtomically(manifest, to: directoryURL)
        return deletionEpoch
    }

    // MARK: - Rotation & Budget

    private func shouldRotateBeforeWriting(additionalBytes: Int) -> Bool {
        guard let last = manifest.segments.last, last.runID == runID, !last.complete else {
            return false
        }
        return last.byteSize + additionalBytes > policy.maxSegmentBytes
    }

    private func rotateActiveSegment() {
        guard let lastIdx = manifest.segments.indices.last else { return }
        manifest.segments[lastIdx].closedAt = Date()
        manifest.segments[lastIdx].complete = true
        stats.rotationCount &+= 1
    }

    private func ensureActiveSegmentIndex(startingWith event: DiagnosticEvent) -> Int {
        if let lastIdx = manifest.segments.indices.last,
           manifest.segments[lastIdx].runID == runID,
           !manifest.segments[lastIdx].complete {
            return lastIdx
        }
        let idx = manifest.nextSegmentIndex
        manifest.nextSegmentIndex += 1
        let filename = String(format: "events-%04d.jsonl", idx)
        let meta = DiagnosticSegmentMetadata(
            filename: filename,
            runID: runID,
            minSequence: event.sequence,
            maxSequence: event.sequence,
            eventCount: 0,
            byteSize: 0
        )
        manifest.segments.append(meta)
        return manifest.segments.count - 1
    }

    private func enforceRetentionBudget() {
        let fm = FileManager.default
        let cutoff = Date().addingTimeInterval(-Double(policy.retentionDays) * 86400.0)

        // Evict expired segments first (except pinned or active)
        while manifest.segments.count > 1,
              let first = manifest.segments.first,
              first.complete,
              !pinnedSegmentFilenames.contains(first.filename),
              first.createdAt < cutoff {
            let removed = manifest.segments.removeFirst()
            try? fm.removeItem(at: directoryURL.appendingPathComponent(removed.filename))
            recordEvicted(removed)
        }

        // Enforce maxSegments across all runs
        while manifest.segments.count > policy.maxSegments {
            guard let evictIdx = manifest.segments.firstIndex(where: { !pinnedSegmentFilenames.contains($0.filename) && $0.complete })
                    ?? manifest.segments.firstIndex(where: { !pinnedSegmentFilenames.contains($0.filename) }) else {
                break
            }
            // Don't evict the sole active segment if we only have 1
            if manifest.segments.count == 1 { break }
            let removed = manifest.segments.remove(at: evictIdx)
            try? fm.removeItem(at: directoryURL.appendingPathComponent(removed.filename))
            recordEvicted(removed)
        }
    }

    private func recordEvicted(_ seg: DiagnosticSegmentMetadata) {
        stats.evictedSegmentCount &+= 1
        manifest.evictedSegments.append(seg)
        if manifest.evictedSegments.count > 128 {
            manifest.evictedSegments.removeFirst(manifest.evictedSegments.count - 128)
        }
        manifest.gaps.append(
            DiagnosticGapRecord(
                runID: seg.runID,
                startSequence: seg.minSequence,
                endSequence: seg.maxSequence,
                reason: "segment_evicted_budget"
            )
        )
    }

    // MARK: - File Helpers

    private static func ensurePrivateDirectory(_ url: URL) {
        let fm = FileManager.default
        if !fm.fileExists(atPath: url.path) {
            try? fm.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        } else {
            try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        }
    }

    private static func appendData(_ data: Data, to fileURL: URL) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: fileURL.path) {
            let handle = try FileHandle(forWritingTo: fileURL)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
        } else {
            try data.write(to: fileURL, options: .atomic)
            try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        }
    }

    private static func writeManifestAtomically(_ manifest: DiagnosticDiskManifest, to directoryURL: URL) {
        let manifestURL = directoryURL.appendingPathComponent("manifest.json")
        let encoder = DiagnosticJSONLCodec.makeEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(manifest) {
            try? data.write(to: manifestURL, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: manifestURL.path)
        }
    }

    private static func loadAndRecoverManifest(
        directoryURL: URL,
        currentRunID: UUID,
        decoder: JSONDecoder
    ) -> (manifest: DiagnosticDiskManifest, truncatedTailsFound: UInt64) {
        let manifestURL = directoryURL.appendingPathComponent("manifest.json")
        var truncatedCount: UInt64 = 0

        guard let data = try? Data(contentsOf: manifestURL),
              var existing = try? decoder.decode(DiagnosticDiskManifest.self, from: data) else {
            return (DiagnosticDiskManifest(activeRunID: currentRunID), 0)
        }

        if !existing.cleanShutdown {
            // Scan unclosed segments for truncated trailing line
            for idx in existing.segments.indices where !existing.segments[idx].complete {
                let segURL = directoryURL.appendingPathComponent(existing.segments[idx].filename)
                if let segData = try? Data(contentsOf: segURL), !segData.isEmpty {
                    let hasTrailingNewline = segData.last == 0x0A
                    let lines = segData.split(separator: 0x0A, omittingEmptySubsequences: false)
                    var validCount = 0
                    var validBytes = 0
                    var lastValidSeq = existing.segments[idx].minSequence
                    var truncated = false

                    for (lineIdx, slice) in lines.enumerated() {
                        if slice.isEmpty { continue }
                        let lineData = Data(slice)
                        if let ev = try? decoder.decode(DiagnosticEvent.self, from: lineData) {
                            validCount += 1
                            validBytes += lineData.count + 1
                            lastValidSeq = max(lastValidSeq, ev.sequence)
                        } else if lineIdx == lines.count - 1 || (lineIdx == lines.count - 2 && lines.last?.isEmpty == true) || !hasTrailingNewline {
                            truncated = true
                        }
                    }

                    if truncated {
                        truncatedCount &+= 1
                        existing.segments[idx].hasTruncatedTail = true
                        existing.segments[idx].eventCount = validCount
                        existing.segments[idx].maxSequence = lastValidSeq
                        // Rewrite valid prefix so file remains valid JSONL
                        if validBytes > 0 && validBytes <= segData.count {
                            let validPrefix = segData.prefix(validBytes)
                            try? validPrefix.write(to: segURL, options: .atomic)
                        }
                        existing.gaps.append(
                            DiagnosticGapRecord(
                                runID: existing.segments[idx].runID,
                                startSequence: lastValidSeq &+ 1,
                                endSequence: lastValidSeq &+ 1,
                                reason: "crash_truncated_tail"
                            )
                        )
                    }
                }
                existing.segments[idx].complete = true
                existing.segments[idx].closedAt = Date()
            }
        }

        existing.activeRunID = currentRunID
        existing.cleanShutdown = false
        existing.updatedAt = Date()
        return (existing, truncatedCount)
    }
}
