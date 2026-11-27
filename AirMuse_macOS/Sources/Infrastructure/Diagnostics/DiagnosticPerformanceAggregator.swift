import Domain
import Foundation
import os

// MARK: - DiagnosticMetricSummary

public struct DiagnosticMetricSummary: Sendable, Codable, Equatable, Identifiable {
    public let id: String
    public let metricName: String
    public let source: String
    public let sampleCount: Int
    public let p50Ms: Double?
    public let p95Ms: Double?
    public let maxMs: Double?
    public let budgetMs: Double?
    public let slowCount: Int
    public let availability: DiagnosticSnapshotAvailability
    public let windowStart: Date
    public let windowEnd: Date

    public init(
        metricName: String,
        source: String,
        sampleCount: Int,
        p50Ms: Double?,
        p95Ms: Double?,
        maxMs: Double?,
        budgetMs: Double?,
        slowCount: Int,
        availability: DiagnosticSnapshotAvailability,
        windowStart: Date,
        windowEnd: Date
    ) {
        self.id = metricName
        self.metricName = metricName
        self.source = source
        self.sampleCount = sampleCount
        self.p50Ms = p50Ms
        self.p95Ms = p95Ms
        self.maxMs = maxMs
        self.budgetMs = budgetMs
        self.slowCount = slowCount
        self.availability = availability
        self.windowStart = windowStart
        self.windowEnd = windowEnd
    }
}

// MARK: - DiagnosticPerformanceAggregator

/// Bounded, real-sample performance aggregator.
/// Never fabricates metrics: metrics with zero recorded samples report `.unavailable`.
public final class DiagnosticPerformanceAggregator: Sendable {

    public static let shared = DiagnosticPerformanceAggregator()

    private struct Bucket: Sendable {
        var samplesMs: [Double] = []
        var source: String
        var budgetMs: Double?
        var slowCount: Int = 0
        var windowStart: Date
        var windowEnd: Date
    }

    private let maxSamplesPerBucket = 512
    private let state = OSAllocatedUnfairLock<[String: Bucket]>(initialState: [:])

    public init() {}

    public func recordSample(
        metric: String,
        durationMs: Double,
        source: String,
        budgetMs: Double? = nil,
        at date: Date = Date()
    ) {
        guard durationMs.isFinite, durationMs >= 0 else { return }
        state.withLock { buckets in
            var bucket = buckets[metric] ?? Bucket(
                samplesMs: [],
                source: source,
                budgetMs: budgetMs,
                slowCount: 0,
                windowStart: date,
                windowEnd: date
            )
            bucket.source = source
            if let budgetMs {
                bucket.budgetMs = budgetMs
                if durationMs > budgetMs {
                    bucket.slowCount += 1
                }
            }
            bucket.samplesMs.append(durationMs)
            if bucket.samplesMs.count > maxSamplesPerBucket {
                bucket.samplesMs.removeFirst(bucket.samplesMs.count - maxSamplesPerBucket)
            }
            bucket.windowEnd = date
            buckets[metric] = bucket
        }
    }

    public func summary(for metric: String, defaultSource: String = "unavailable", budgetMs: Double? = nil) -> DiagnosticMetricSummary {
        state.withLock { buckets in
            guard let bucket = buckets[metric], !bucket.samplesMs.isEmpty else {
                let now = Date()
                return DiagnosticMetricSummary(
                    metricName: metric,
                    source: defaultSource,
                    sampleCount: 0,
                    p50Ms: nil,
                    p95Ms: nil,
                    maxMs: nil,
                    budgetMs: budgetMs,
                    slowCount: 0,
                    availability: .unavailable,
                    windowStart: now,
                    windowEnd: now
                )
            }
            let sorted = bucket.samplesMs.sorted()
            let p50 = sorted[sorted.count / 2]
            let p95Idx = min(sorted.count - 1, Int(Double(sorted.count) * 0.95))
            let p95 = sorted[p95Idx]
            let maxVal = sorted.last
            return DiagnosticMetricSummary(
                metricName: metric,
                source: bucket.source,
                sampleCount: sorted.count,
                p50Ms: p50,
                p95Ms: p95,
                maxMs: maxVal,
                budgetMs: bucket.budgetMs ?? budgetMs,
                slowCount: bucket.slowCount,
                availability: .available,
                windowStart: bucket.windowStart,
                windowEnd: bucket.windowEnd
            )
        }
    }

    public func allSummaries() -> [DiagnosticMetricSummary] {
        let keys = state.withLock { Array($0.keys).sorted() }
        return keys.map { summary(for: $0) }
    }

    public func reset() {
        state.withLock { $0.removeAll() }
    }
}
