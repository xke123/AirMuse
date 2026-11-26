import Foundation

// MARK: - QueueInsertionIntent

/// Unified four playback/queue insertion intents shared across Library, Context Menus, and future Play Menu.
public enum QueueInsertionIntent: String, Sendable, Equatable, Codable {
    case replaceAndPlay
    case interruptAndPlay
    case prepend
    case append
}

// MARK: - QueuePlaybackPhase

public enum QueuePlaybackPhase: String, Sendable, Equatable, Codable {
    case idle
    case preparing
    case playing
    case paused
    case failed
    case stoppedByUser
    case exhausted
    case waitingForPage
}

// MARK: - QueueCommandResult

public struct QueueCommandResult: Sendable, Equatable {
    public let queueID: UUID
    public let revision: UInt64
    public let destructiveEpoch: UInt64
    public let acceptedCount: Int
    public let message: String?

    public init(
        queueID: UUID,
        revision: UInt64,
        destructiveEpoch: UInt64,
        acceptedCount: Int,
        message: String? = nil
    ) {
        self.queueID = queueID
        self.revision = revision
        self.destructiveEpoch = destructiveEpoch
        self.acceptedCount = acceptedCount
        self.message = message
    }
}

// MARK: - QueueSnapshot

/// Immutable, read-only structural snapshot of the authoritative playback queue.
/// Published atomically alongside `PlaybackState` by `PlaybackCoordinatorV2` through `PlaybackStore`.
public struct QueueSnapshot: Sendable, Equatable {
    public let queueID: UUID
    public let revision: UInt64
    public let destructiveEpoch: UInt64
    public let sessionScope: String
    public let owner: QueueOwner
    public let activeTarget: PlaybackTarget?
    public let confirmedCurrent: QueueEntry?
    public let pendingTarget: QueueEntry?
    public let isPendingTargetFailed: Bool
    public let upcomingEntries: [QueueEntry]
    public let historyCount: Int
    public let canGoPrevious: Bool
    public let canGoNext: Bool
    public let canClearUpcoming: Bool
    public let shuffleEnabled: Bool
    public let requestedShuffle: Bool
    public let effectiveShuffle: Bool
    public let repeatMode: PlaybackState.RepeatMode
    public let capabilities: QueueCapabilities
    public let loadingState: QueueLoadingState
    public let playbackPhase: QueuePlaybackPhase
    public let canUndo: Bool
    public let undoDescription: String?

    public init(
        queueID: UUID = UUID(),
        revision: UInt64 = 0,
        destructiveEpoch: UInt64 = 0,
        sessionScope: String = "",
        owner: QueueOwner = .localCoordinator,
        activeTarget: PlaybackTarget? = nil,
        confirmedCurrent: QueueEntry? = nil,
        pendingTarget: QueueEntry? = nil,
        isPendingTargetFailed: Bool = false,
        upcomingEntries: [QueueEntry] = [],
        historyCount: Int = 0,
        canGoPrevious: Bool = false,
        canGoNext: Bool = false,
        canClearUpcoming: Bool = false,
        shuffleEnabled: Bool = false,
        requestedShuffle: Bool = false,
        effectiveShuffle: Bool = false,
        repeatMode: PlaybackState.RepeatMode = .off,
        capabilities: QueueCapabilities = .fullLocal,
        loadingState: QueueLoadingState = .idle,
        playbackPhase: QueuePlaybackPhase = .idle,
        canUndo: Bool = false,
        undoDescription: String? = nil
    ) {
        self.queueID = queueID
        self.revision = revision
        self.destructiveEpoch = destructiveEpoch
        self.sessionScope = sessionScope
        self.owner = owner
        self.activeTarget = activeTarget
        self.confirmedCurrent = confirmedCurrent
        self.pendingTarget = pendingTarget
        self.isPendingTargetFailed = isPendingTargetFailed
        self.upcomingEntries = upcomingEntries
        self.historyCount = historyCount
        self.canGoPrevious = canGoPrevious
        self.canGoNext = canGoNext
        self.canClearUpcoming = canClearUpcoming
        self.shuffleEnabled = shuffleEnabled
        self.requestedShuffle = requestedShuffle
        self.effectiveShuffle = effectiveShuffle
        self.repeatMode = repeatMode
        self.capabilities = capabilities
        self.loadingState = loadingState
        self.playbackPhase = playbackPhase
        self.canUndo = canUndo
        self.undoDescription = undoDescription
    }

    public static let empty = QueueSnapshot()
}

// MARK: - QueueEditError

public enum QueueEditError: Error, LocalizedError, Sendable, Equatable {
    case queueMismatch(expected: UUID, actual: UUID)
    case sessionMismatch
    case staleEpoch
    case revisionConflict(expected: UInt64, actual: UInt64)
    case entryNotFound(UUID)
    case invalidTarget(UUID)
    case unsupportedCapability(String)
    case remoteQueueRequiresSwitch(stationTitle: String?)
    case remoteStationMixedNotAllowed
    case emptyBatch
    case undoUnavailable(String)

    public var errorDescription: String? {
        switch self {
        case .queueMismatch:
            return "当前播放队列已切换，本次操作已取消。"
        case .sessionMismatch:
            return "播放会话已变更，操作已取消。"
        case .staleEpoch:
            return "队列已被清空或替换，本次添加已取消。"
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
        case .remoteStationMixedNotAllowed:
            return "电台不支持作为普通歌曲混入本地队列。"
        case .emptyBatch:
            return "没有可操作的曲目。"
        case .undoUnavailable(let reason):
            return reason
        }
    }
}
