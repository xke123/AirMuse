import Foundation

// MARK: - QueueCapabilities

/// Describes what queue operations are supported in the current playback mode/owner.
/// Remote radio/station queues default to restricted/unknown until verified.
public struct QueueCapabilities: Sendable, Codable, Equatable {
    public var canRead: Bool
    public var canPlayEntry: Bool
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
    public var canSeek: Bool
    public var canPause: Bool

    public init(
        canRead: Bool = false,
        canPlayEntry: Bool = false,
        canInsertNext: Bool = false,
        canAppend: Bool = false,
        canRemove: Bool = false,
        canReorder: Bool = false,
        canClear: Bool = false,
        canToggleShuffle: Bool = false,
        canRepeatOne: Bool = false,
        canRepeatAll: Bool = false,
        canSkipNext: Bool = false,
        canSkipPrevious: Bool = false,
        canSeek: Bool = true,
        canPause: Bool = true
    ) {
        self.canRead = canRead
        self.canPlayEntry = canPlayEntry
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
        self.canSeek = canSeek
        self.canPause = canPause
    }

    /// Full local coordinator queue capabilities.
    public static let fullLocal = QueueCapabilities(
        canRead: true,
        canPlayEntry: true,
        canInsertNext: true,
        canAppend: true,
        canRemove: true,
        canReorder: true,
        canClear: true,
        canToggleShuffle: true,
        canRepeatOne: true,
        canRepeatAll: true,
        canSkipNext: true,
        canSkipPrevious: true,
        canSeek: true,
        canPause: true
    )

    /// Conservative capabilities for unknown/unverified remote stations.
    public static let remoteStationUnknown = QueueCapabilities(
        canRead: false,
        canPlayEntry: false,
        canInsertNext: false,
        canAppend: false,
        canRemove: false,
        canReorder: false,
        canClear: false,
        canToggleShuffle: false,
        canRepeatOne: false,
        canRepeatAll: false,
        canSkipNext: false,
        canSkipPrevious: false,
        canSeek: false,
        canPause: true
    )

    /// Conservative capabilities for live broadcast stations (no skip/seek).
    public static let remoteStationLive = QueueCapabilities(
        canRead: false,
        canPlayEntry: false,
        canInsertNext: false,
        canAppend: false,
        canRemove: false,
        canReorder: false,
        canClear: false,
        canToggleShuffle: false,
        canRepeatOne: false,
        canRepeatAll: false,
        canSkipNext: false,
        canSkipPrevious: false,
        canSeek: false,
        canPause: true
    )

    /// Capabilities for verified algorithmic stations.
    public static let remoteStationAlgorithmic = QueueCapabilities(
        canRead: false,
        canPlayEntry: false,
        canInsertNext: false,
        canAppend: false,
        canRemove: false,
        canReorder: false,
        canClear: false,
        canToggleShuffle: false,
        canRepeatOne: false,
        canRepeatAll: false,
        canSkipNext: true,
        canSkipPrevious: false,
        canSeek: true,
        canPause: true
    )

    /// Default remote station/radio capabilities before runtime verification:
    /// conservative unknown capabilities until verified.
    public static let remoteStationDefault = remoteStationUnknown

    /// Conservative capability synthesis from owner, station kind, and verified runtime engine evidence.
    /// Never infers seek/skip/pause from station kind alone when engine evidence is missing.
    public static func resolve(
        owner: QueueOwner,
        stationKind: StationKind,
        evidence: EngineCapabilityEvidence?
    ) -> QueueCapabilities {
        switch owner {
        case .localCoordinator:
            return .fullLocal
        case .remoteEngine:
            guard let evidence else {
                return QueueCapabilities(
                    canRead: false,
                    canPlayEntry: false,
                    canInsertNext: false,
                    canAppend: false,
                    canRemove: false,
                    canReorder: false,
                    canClear: false,
                    canToggleShuffle: false,
                    canRepeatOne: false,
                    canRepeatAll: false,
                    canSkipNext: false,
                    canSkipPrevious: false,
                    canSeek: false,
                    canPause: false
                )
            }
            switch stationKind {
            case .live:
                return QueueCapabilities(
                    canRead: false,
                    canPlayEntry: false,
                    canInsertNext: false,
                    canAppend: false,
                    canRemove: false,
                    canReorder: false,
                    canClear: false,
                    canToggleShuffle: false,
                    canRepeatOne: false,
                    canRepeatAll: false,
                    canSkipNext: false,
                    canSkipPrevious: false,
                    canSeek: false,
                    canPause: evidence.canPause
                )
            case .algorithmic, .unknown:
                return QueueCapabilities(
                    canRead: false,
                    canPlayEntry: false,
                    canInsertNext: false,
                    canAppend: false,
                    canRemove: false,
                    canReorder: false,
                    canClear: false,
                    canToggleShuffle: false,
                    canRepeatOne: false,
                    canRepeatAll: false,
                    canSkipNext: evidence.canSkipNext,
                    canSkipPrevious: evidence.canSkipPrevious,
                    canSeek: evidence.canSeek,
                    canPause: evidence.canPause
                )
            }
        }
    }
}

public struct EngineCapabilityEvidence: Sendable, Equatable, Codable {
    public let canPause: Bool
    public let canSeek: Bool
    public let canSkipNext: Bool
    public let canSkipPrevious: Bool

    public init(
        canPause: Bool,
        canSeek: Bool,
        canSkipNext: Bool,
        canSkipPrevious: Bool
    ) {
        self.canPause = canPause
        self.canSeek = canSeek
        self.canSkipNext = canSkipNext
        self.canSkipPrevious = canSkipPrevious
    }
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
