import Foundation
import Domain
import Infrastructure

// MARK: - QueuePageFetchResult

public struct QueuePageFetchResult: Sendable {
    public let tracks: [MusicTrack]
    public let nextURL: URL?
    public let totalCount: Int?

    public init(tracks: [MusicTrack], nextURL: URL? = nil, totalCount: Int? = nil) {
        self.tracks = tracks
        self.nextURL = nextURL
        self.totalCount = totalCount
    }
}

// MARK: - QueuePaginationLoader

/// Actor-isolated, bounded, session- and queue-scoped background pagination loader with retry support (P0-06, P1-03).
/// Guarantees:
/// - Preserves duplicate tracks (never deduplicates by `track.id`).
/// - Detects circular `nextURL` cursors and stops with a non-retryable bounded failure.
/// - Retries from the exact failed `nextURL` without replaying/seeking current audio or duplicating prior pages.
/// - Discards stale callbacks if `queueID`, `sessionScope`, or `destructiveEpoch` changed.
public actor QueuePaginationLoader {

    private struct RetryContext {
        let coordinator: PlaybackCoordinatorV2
        let batchID: UUID
        let expectedQueueID: UUID
        let expectedSessionScope: String
        let expectedDestructiveEpoch: UInt64
        let origin: PlaybackOrigin
        var loadedCount: Int
        var totalCount: Int?
        var failedNextURL: URL
        var visitedURLs: Set<String>
        var pageCount: Int
        let fetchNextPage: @Sendable (URL) async throws -> QueuePageFetchResult
    }

    private let maxPages: Int
    private var activeTask: Task<Void, Never>?
    private var activeRunID: UUID?
    private var retryContext: RetryContext?

    public init(maxPages: Int = 100) {
        self.maxPages = max(1, maxPages)
    }

    public func cancel() {
        activeRunID = nil
        activeTask?.cancel()
        activeTask = nil
        retryContext = nil
    }

    public func startBackgroundPagination(
        coordinator: PlaybackCoordinatorV2,
        batchID: UUID,
        expectedQueueID: UUID,
        expectedSessionScope: String,
        expectedDestructiveEpoch: UInt64,
        origin: PlaybackOrigin,
        initialLoadedCount: Int,
        initialNextURL: URL?,
        totalCount: Int?,
        fetchNextPage: @escaping @Sendable (URL) async throws -> QueuePageFetchResult
    ) {
        cancel()
        guard let firstNextURL = initialNextURL else {
            return
        }

        let runID = UUID()
        activeRunID = runID
        activeTask = Task {
            await self.runLoop(
                runID: runID,
                coordinator: coordinator,
                batchID: batchID,
                expectedQueueID: expectedQueueID,
                expectedSessionScope: expectedSessionScope,
                expectedDestructiveEpoch: expectedDestructiveEpoch,
                origin: origin,
                initialLoadedCount: initialLoadedCount,
                startURL: firstNextURL,
                initialVisited: [],
                initialPageCount: 1,
                totalCount: totalCount,
                fetchNextPage: fetchNextPage
            )
        }
    }

    /// P0-06: Resumes pagination from the exact failed `nextURL` without touching current audio or duplicating committed pages.
    @discardableResult
    public func retryFailedPagination() async -> Bool {
        guard let ctx = retryContext else { return false }
        let snap = await ctx.coordinator.currentStructuredQueueSnapshot()
        guard snap.queueID == ctx.expectedQueueID,
              snap.sessionScope == ctx.expectedSessionScope,
              snap.destructiveEpoch == ctx.expectedDestructiveEpoch else {
            retryContext = nil
            return false
        }

        retryContext = nil
        let runID = UUID()
        activeRunID = runID
        await ctx.coordinator.updateQueueLoadingState(
            .loading(loadedCount: ctx.loadedCount, totalCount: ctx.totalCount),
            expectedQueueID: ctx.expectedQueueID,
            expectedSessionScope: ctx.expectedSessionScope,
            expectedDestructiveEpoch: ctx.expectedDestructiveEpoch,
            batchID: ctx.batchID
        )

        activeTask = Task {
            await self.runLoop(
                runID: runID,
                coordinator: ctx.coordinator,
                batchID: ctx.batchID,
                expectedQueueID: ctx.expectedQueueID,
                expectedSessionScope: ctx.expectedSessionScope,
                expectedDestructiveEpoch: ctx.expectedDestructiveEpoch,
                origin: ctx.origin,
                initialLoadedCount: ctx.loadedCount,
                startURL: ctx.failedNextURL,
                initialVisited: ctx.visitedURLs,
                initialPageCount: ctx.pageCount,
                totalCount: ctx.totalCount,
                fetchNextPage: ctx.fetchNextPage
            )
        }
        return true
    }

    private func runLoop(
        runID: UUID,
        coordinator: PlaybackCoordinatorV2,
        batchID: UUID,
        expectedQueueID: UUID,
        expectedSessionScope: String,
        expectedDestructiveEpoch: UInt64,
        origin: PlaybackOrigin,
        initialLoadedCount: Int,
        startURL: URL,
        initialVisited: Set<String>,
        initialPageCount: Int,
        totalCount: Int?,
        fetchNextPage: @escaping @Sendable (URL) async throws -> QueuePageFetchResult
    ) async {
        var nextURL: URL? = startURL
        var visitedURLs = initialVisited
        var loadedCount = initialLoadedCount
        var knownTotal = totalCount
        var pageCount = initialPageCount

        AppLogger.shared.log(
            category: .queue,
            level: .info,
            correlationID: "batch-\(batchID.uuidString.prefix(6))",
            message: "启动队列后台分页加载 (已加载 \(initialLoadedCount) 首, 来源=\(origin.displayTitle))"
        )

        while let url = nextURL, !Task.isCancelled, activeRunID == runID {
            let key = url.absoluteString
            if visitedURLs.contains(key) {
                AppLogger.shared.log(
                    category: .queue,
                    level: .warn,
                    correlationID: "batch-\(batchID.uuidString.prefix(6))",
                    message: "检测到重复分页游标，已终止分页 (已加载 \(loadedCount) 首)"
                )
                await coordinator.updateQueueLoadingState(
                    .failed(loadedCount: loadedCount, totalCount: knownTotal, message: "检测到重复分页游标，已停止加载。", isRetryable: false),
                    expectedQueueID: expectedQueueID,
                    expectedSessionScope: expectedSessionScope,
                    expectedDestructiveEpoch: expectedDestructiveEpoch,
                    batchID: batchID
                )
                return
            }
            if pageCount >= maxPages {
                AppLogger.shared.log(
                    category: .queue,
                    level: .warn,
                    correlationID: "batch-\(batchID.uuidString.prefix(6))",
                    message: "达到队列分页上限 (\(maxPages) 页)，保持部分加载状态 (已加载 \(loadedCount) 首)"
                )
                await coordinator.updateQueueLoadingState(
                    .partial(loadedCount: loadedCount, totalCount: knownTotal),
                    expectedQueueID: expectedQueueID,
                    expectedSessionScope: expectedSessionScope,
                    expectedDestructiveEpoch: expectedDestructiveEpoch,
                    batchID: batchID
                )
                return
            }
            visitedURLs.insert(key)
            pageCount += 1

            do {
                let page = try await fetchNextPage(url)
                if Task.isCancelled || activeRunID != runID { return }
                if let t = page.totalCount { knownTotal = t }
                loadedCount += page.tracks.count
                nextURL = page.nextURL

                let entries = page.tracks.map {
                    QueueEntry(track: $0, origin: origin, batchID: batchID)
                }
                let state: QueueLoadingState = (nextURL == nil)
                    ? .complete(totalCount: loadedCount)
                    : .loading(loadedCount: loadedCount, totalCount: knownTotal)

                let committed = await coordinator.commitPaginatedBatch(
                    entries,
                    batchID: batchID,
                    expectedQueueID: expectedQueueID,
                    expectedSessionScope: expectedSessionScope,
                    expectedDestructiveEpoch: expectedDestructiveEpoch,
                    loadingState: state
                )
                if !committed {
                    AppLogger.shared.log(
                        category: .queue,
                        level: .debug,
                        correlationID: "batch-\(batchID.uuidString.prefix(6))",
                        message: "分页批次已失效（队列已清空或切换），放弃提交第 \(pageCount) 页"
                    )
                    return
                }
                AppLogger.shared.log(
                    category: .queue,
                    level: .info,
                    correlationID: "batch-\(batchID.uuidString.prefix(6))",
                    message: "提交队列第 \(pageCount) 页: +\(page.tracks.count) 首 (累计 \(loadedCount)\(nextURL == nil ? ", 已全部完成" : ""))"
                )
            } catch {
                if Task.isCancelled || activeRunID != runID { return }
                // Remove failed URL from visited so retry can request it again
                visitedURLs.remove(key)
                retryContext = RetryContext(
                    coordinator: coordinator,
                    batchID: batchID,
                    expectedQueueID: expectedQueueID,
                    expectedSessionScope: expectedSessionScope,
                    expectedDestructiveEpoch: expectedDestructiveEpoch,
                    origin: origin,
                    loadedCount: loadedCount,
                    totalCount: knownTotal,
                    failedNextURL: url,
                    visitedURLs: visitedURLs,
                    pageCount: pageCount - 1,
                    fetchNextPage: fetchNextPage
                )
                AppLogger.shared.log(
                    category: .queue,
                    level: .error,
                    correlationID: "batch-\(batchID.uuidString.prefix(6))",
                    message: "队列分页加载失败 (已加载 \(loadedCount) 首): \(error.localizedDescription)"
                )
                await coordinator.updateQueueLoadingState(
                    .failed(loadedCount: loadedCount, totalCount: knownTotal, message: error.localizedDescription, isRetryable: true),
                    expectedQueueID: expectedQueueID,
                    expectedSessionScope: expectedSessionScope,
                    expectedDestructiveEpoch: expectedDestructiveEpoch,
                    batchID: batchID
                )
                return
            }
        }
    }
}
