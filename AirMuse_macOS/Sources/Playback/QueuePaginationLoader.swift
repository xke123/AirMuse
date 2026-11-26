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

/// Bounded, session- and queue-scoped background pagination loader.
/// Guarantees:
/// - Preserves duplicate tracks (never deduplicates by `track.id`).
/// - Detects circular `nextURL` cursors and stops with a bounded failure state.
/// - Commits pages to `PlaybackCoordinatorV2` anchored by `batchID`, `expectedQueueID`, and `expectedSessionScope`.
public final class QueuePaginationLoader: @unchecked Sendable {

    private let maxPages: Int
    private var activeTask: Task<Void, Never>?

    public init(maxPages: Int = 100) {
        self.maxPages = max(1, maxPages)
    }

    public func cancel() {
        activeTask?.cancel()
        activeTask = nil
    }

    public func startBackgroundPagination(
        coordinator: PlaybackCoordinatorV2,
        batchID: UUID,
        expectedQueueID: UUID,
        expectedSessionScope: String,
        origin: PlaybackOrigin,
        initialLoadedCount: Int,
        initialNextURL: URL?,
        totalCount: Int?,
        fetchNextPage: @escaping @Sendable (URL) async throws -> QueuePageFetchResult
    ) {
        activeTask?.cancel()
        guard let firstNextURL = initialNextURL else {
            return
        }

        activeTask = Task { [maxPages] in
            var nextURL: URL? = firstNextURL
            var visitedURLs: Set<String> = []
            var loadedCount = initialLoadedCount
            var knownTotal = totalCount
            var pageCount = 1

            AppLogger.shared.log(
                category: .queue,
                level: .info,
                correlationID: "batch-\(batchID.uuidString.prefix(6))",
                message: "启动队列后台分页加载 (已加载 \(initialLoadedCount) 首, 来源=\(origin.displayTitle))"
            )

            while let url = nextURL, !Task.isCancelled {
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
                        expectedSessionScope: expectedSessionScope
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
                        expectedSessionScope: expectedSessionScope
                    )
                    return
                }
                visitedURLs.insert(key)
                pageCount += 1

                do {
                    let page = try await fetchNextPage(url)
                    if Task.isCancelled { return }
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
                    if Task.isCancelled { return }
                    AppLogger.shared.log(
                        category: .queue,
                        level: .error,
                        correlationID: "batch-\(batchID.uuidString.prefix(6))",
                        message: "队列分页加载失败 (已加载 \(loadedCount) 首): \(error.localizedDescription)"
                    )
                    await coordinator.updateQueueLoadingState(
                        .failed(loadedCount: loadedCount, totalCount: knownTotal, message: error.localizedDescription, isRetryable: true),
                        expectedQueueID: expectedQueueID,
                        expectedSessionScope: expectedSessionScope
                    )
                    return
                }
            }
        }
    }
}
