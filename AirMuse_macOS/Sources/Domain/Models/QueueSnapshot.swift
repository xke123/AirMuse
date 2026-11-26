import Foundation

// MARK: - QueueSnapshot

/// Immutable, read-only structural snapshot of the authoritative playback queue.
/// Published by `PlaybackCoordinatorV2` through `PlaybackStore` only on structural or state changes
/// (never on high-frequency progress/lyrics/volume updates).
public struct QueueSnapshot: Sendable, Equatable {
    public let queueID: UUID
    public let revision: UInt64
    public let sessionScope: String
    public let owner: QueueOwner
    public let confirmedCurrent: QueueEntry?
    public let pendingTarget: QueueEntry?
    public let upcomingEntries: [QueueEntry]
    public let historyCount: Int
    public let canGoPrevious: Bool
    public let canGoNext: Bool
    public let shuffleEnabled: Bool
    public let repeatMode: PlaybackState.RepeatMode
    public let capabilities: QueueCapabilities
    public let loadingState: QueueLoadingState
    public let canUndo: Bool
    public let undoDescription: String?

    public init(
        queueID: UUID = UUID(),
        revision: UInt64 = 0,
        sessionScope: String = "",
        owner: QueueOwner = .localCoordinator,
        confirmedCurrent: QueueEntry? = nil,
        pendingTarget: QueueEntry? = nil,
        upcomingEntries: [QueueEntry] = [],
        historyCount: Int = 0,
        canGoPrevious: Bool = false,
        canGoNext: Bool = false,
        shuffleEnabled: Bool = false,
        repeatMode: PlaybackState.RepeatMode = .off,
        capabilities: QueueCapabilities = .fullLocal,
        loadingState: QueueLoadingState = .idle,
        canUndo: Bool = false,
        undoDescription: String? = nil
    ) {
        self.queueID = queueID
        self.revision = revision
        self.sessionScope = sessionScope
        self.owner = owner
        self.confirmedCurrent = confirmedCurrent
        self.pendingTarget = pendingTarget
        self.upcomingEntries = upcomingEntries
        self.historyCount = historyCount
        self.canGoPrevious = canGoPrevious
        self.canGoNext = canGoNext
        self.shuffleEnabled = shuffleEnabled
        self.repeatMode = repeatMode
        self.capabilities = capabilities
        self.loadingState = loadingState
        self.canUndo = canUndo
        self.undoDescription = undoDescription
    }

    public static let empty = QueueSnapshot()
}

// MARK: - QueueEditError

public enum QueueEditError: Error, LocalizedError, Sendable, Equatable {
    case queueMismatch(expected: UUID, actual: UUID)
    case sessionMismatch
    case revisionConflict(expected: UInt64, actual: UInt64)
    case entryNotFound(UUID)
    case invalidTarget(UUID)
    case unsupportedCapability(String)
    case remoteQueueRequiresSwitch(stationTitle: String?)
    case emptyBatch
    case undoUnavailable(String)

    public var errorDescription: String? {
        switch self {
        case .queueMismatch:
            return "当前播放队列已切换，请刷新后重试。"
        case .sessionMismatch:
            return "播放会话已变更，操作已取消。"
        case .revisionConflict:
            return "队列内容已更新，请重试。"
        case .entryNotFound:
            return "目标曲目已不在待播队列中。"
        case .invalidTarget:
            return "无法移动到无效的目标位置。"
        case .unsupportedCapability(let reason):
            return reason
        case .remoteQueueRequiresSwitch(let title):
            if let title, !title.isEmpty {
                return "当前正在收听电台「\(title)」，不支持直接加入队列。"
            }
            return "当前正在收听电台，不支持直接加入队列。"
        case .emptyBatch:
            return "没有可操作的曲目。"
        case .undoUnavailable(let reason):
            return reason
        }
    }
}
