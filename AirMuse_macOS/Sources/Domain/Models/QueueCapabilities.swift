import Foundation

// MARK: - QueueCapabilities

/// Describes what queue operations are supported in the current playback mode/owner.
/// Remote radio/station queues default to restricted/unknown until verified.
public struct QueueCapabilities: Sendable, Codable, Equatable {
    public var canRead: Bool
    public var canInsertNext: Bool
    public var canAppend: Bool
    public var canRemove: Bool
    public var canReorder: Bool
    public var canClear: Bool
    public var canToggleShuffle: Bool
    public var canRepeatOne: Bool
    public var canRepeatAll: Bool
    public var canSkipNext: Bool
    public var canSkipPrevious: Bool

    public init(
        canRead: Bool = false,
        canInsertNext: Bool = false,
        canAppend: Bool = false,
        canRemove: Bool = false,
        canReorder: Bool = false,
        canClear: Bool = false,
        canToggleShuffle: Bool = false,
        canRepeatOne: Bool = false,
        canRepeatAll: Bool = false,
        canSkipNext: Bool = false,
        canSkipPrevious: Bool = false
    ) {
        self.canRead = canRead
        self.canInsertNext = canInsertNext
        self.canAppend = canAppend
        self.canRemove = canRemove
        self.canReorder = canReorder
        self.canClear = canClear
        self.canToggleShuffle = canToggleShuffle
        self.canRepeatOne = canRepeatOne
        self.canRepeatAll = canRepeatAll
        self.canSkipNext = canSkipNext
        self.canSkipPrevious = canSkipPrevious
    }

    /// Full local coordinator queue capabilities.
    public static let fullLocal = QueueCapabilities(
        canRead: true,
        canInsertNext: true,
        canAppend: true,
        canRemove: true,
        canReorder: true,
        canClear: true,
        canToggleShuffle: true,
        canRepeatOne: true,
        canRepeatAll: true,
        canSkipNext: true,
        canSkipPrevious: true
    )

    /// Default remote station/radio capabilities before runtime verification:
    /// no local queue editing, shuffle/repeat disabled, next skip allowed by MusicKit.
    public static let remoteStationDefault = QueueCapabilities(
        canRead: false,
        canInsertNext: false,
        canAppend: false,
        canRemove: false,
        canReorder: false,
        canClear: false,
        canToggleShuffle: false,
        canRepeatOne: false,
        canRepeatAll: false,
        canSkipNext: true,
        canSkipPrevious: false
    )
}

// MARK: - QueueLoadingState

/// Represents background pagination / collection loading status for the active queue.
public enum QueueLoadingState: Sendable, Codable, Equatable {
    case idle
    case loading(loadedCount: Int, totalCount: Int?)
    case partial(loadedCount: Int, totalCount: Int?)
    case complete(totalCount: Int)
    case failed(loadedCount: Int, totalCount: Int?, message: String, isRetryable: Bool)

    public var isLoading: Bool {
        if case .loading = self { return true }
        return false
    }

    public var loadedCount: Int {
        switch self {
        case .idle: return 0
        case .loading(let count, _), .partial(let count, _), .failed(let count, _, _, _): return count
        case .complete(let total): return total
        }
    }

    public var totalCount: Int? {
        switch self {
        case .idle: return nil
        case .loading(_, let total), .partial(_, let total), .failed(_, let total, _, _): return total
        case .complete(let total): return total
        }
    }
}
