import Foundation

// MARK: - PlaylistOwnership

/// Ownership classification for playlist resources.
/// Personal, collaborative, and unknown playlists are strictly read-only containers.
public enum PlaylistOwnership: String, Sendable, Equatable, Hashable, Codable {
    case platform
    case personal
    case collaborative
    case unknown

    public var isContainerWritable: Bool {
        self == .platform
    }
}

// MARK: - MediaResourceKind

public enum MediaResourceKind: Sendable, Equatable, Hashable, Codable {
    case song
    case album
    case playlist(PlaylistOwnership)
    case artist
    case station
    case queueEntry

    public var isPlaylist: Bool {
        if case .playlist = self { return true }
        return false
    }
}

// MARK: - MediaArtistRef

public struct MediaArtistRef: Sendable, Equatable, Hashable, Codable {
    public let id: String
    public let name: String
    public let isLibrary: Bool

    public init(id: String, name: String, isLibrary: Bool = false) {
        self.id = id
        self.name = name
        self.isLibrary = isLibrary
    }
}

// MARK: - MediaResourceReference

/// Immutable typed identity for any media resource targeted by an action.
public struct MediaResourceReference: Sendable, Equatable, Hashable, Codable {
    public let kind: MediaResourceKind
    public let providerID: String
    public let canonicalID: String
    public let catalogID: String?
    public let libraryID: String?
    public let title: String
    public let subtitle: String?
    public let artworkURL: URL?
    public let isLibrary: Bool
    public let albumID: String?
    public let albumTitle: String?
    public let artists: [MediaArtistRef]
    public let stationID: String?
    public let hasStationDetail: Bool
    public let queueEntryID: UUID?
    public let origin: PlaybackOrigin?

    public init(
        kind: MediaResourceKind,
        providerID: String = "apple_music",
        canonicalID: String,
        catalogID: String? = nil,
        libraryID: String? = nil,
        title: String,
        subtitle: String? = nil,
        artworkURL: URL? = nil,
        isLibrary: Bool = false,
        albumID: String? = nil,
        albumTitle: String? = nil,
        artists: [MediaArtistRef] = [],
        stationID: String? = nil,
        hasStationDetail: Bool = false,
        queueEntryID: UUID? = nil,
        origin: PlaybackOrigin? = nil
    ) {
        self.kind = kind
        self.providerID = providerID
        self.canonicalID = canonicalID
        self.catalogID = catalogID
        self.libraryID = libraryID
        self.title = title
        self.subtitle = subtitle
        self.artworkURL = artworkURL
        self.isLibrary = isLibrary
        self.albumID = albumID
        self.albumTitle = albumTitle
        self.artists = artists
        self.stationID = stationID
        self.hasStationDetail = hasStationDetail
        self.queueEntryID = queueEntryID
        self.origin = origin
    }

    /// Normalized identity key for state caching and deduplication.
    public var normalizedKey: String {
        let kindTag: String
        switch kind {
        case .song, .queueEntry: kindTag = "song"
        case .album: kindTag = "album"
        case .playlist: kindTag = "playlist"
        case .artist: kindTag = "artist"
        case .station: kindTag = "station"
        }
        let effectiveID = (catalogID?.isEmpty == false ? catalogID! : canonicalID)
        return "\(providerID)|\(kindTag)|\(effectiveID)"
    }

    /// Whether this reference has a verified library identity safe for library deletion.
    public var hasTrustedLibraryDeleteIdentity: Bool {
        switch kind {
        case .artist, .station:
            return false
        case .playlist(let ownership):
            guard ownership.isContainerWritable else { return false }
            return (libraryID?.isEmpty == false) || (catalogID?.hasPrefix("pl.") == true)
        case .song, .queueEntry, .album:
            return (libraryID?.isEmpty == false) || (catalogID?.isEmpty == false && !isLibrary)
        }
    }

    /// Constructs a typed reference from a `MusicTrack` without conflating catalog and library IDs.
    public static func from(
        track: MusicTrack,
        origin: PlaybackOrigin? = nil,
        queueEntryID: UUID? = nil,
        fallbackAlbumID: String? = nil
    ) -> MediaResourceReference {
        let isLib = track.isLibrary || track.id.hasPrefix("i.")
        let resolvedCatalogID = track.catalogID ?? ((!isLib && !track.providerTrackID.isEmpty && !track.providerTrackID.hasPrefix("i.")) ? track.providerTrackID : nil)
        let resolvedLibraryID = track.libraryID ?? (isLib ? track.id : nil)
        let canonical = resolvedCatalogID ?? resolvedLibraryID ?? track.id
        return MediaResourceReference(
            kind: queueEntryID != nil ? .queueEntry : .song,
            providerID: track.providerID,
            canonicalID: canonical,
            catalogID: resolvedCatalogID,
            libraryID: resolvedLibraryID,
            title: track.title,
            subtitle: track.artistName,
            artworkURL: track.artworkURL,
            isLibrary: isLib,
            albumID: track.albumID ?? fallbackAlbumID,
            albumTitle: track.albumTitle.isEmpty ? nil : track.albumTitle,
            artists: track.artists,
            queueEntryID: queueEntryID,
            origin: origin
        )
    }
}

// MARK: - MediaToggleState

/// Authoritative state for library membership or favorite status.
/// Unknown is explicitly distinct from `known(false)`.
public enum MediaToggleState: Sendable, Equatable {
    case unknown
    case known(Bool)
    case pending(target: Bool, previous: Bool?, operationID: UUID)
    case failed(lastKnown: Bool?, errorMessage: String)

    public var effectiveBool: Bool? {
        switch self {
        case .unknown:
            return nil
        case .known(let value):
            return value
        case .pending(let target, _, _):
            return target
        case .failed(let lastKnown, _):
            return lastKnown
        }
    }

    /// Authoritative confirmed boolean value (never returns an unconfirmed pending target).
    public var confirmedBool: Bool? {
        switch self {
        case .unknown:
            return nil
        case .known(let value):
            return value
        case .pending(_, let previous, _):
            return previous
        case .failed(let lastKnown, _):
            return lastKnown
        }
    }

    public var isPending: Bool {
        if case .pending = self { return true }
        return false
    }
}

// MARK: - MediaMutationOutcome

public enum MediaMutationOutcome: Sendable, Equatable {
    case confirmed(MediaResourceState, message: String?)
    case reconciledDifferent(MediaResourceState, actual: Bool)
    case unknownOutcome(MediaResourceState, message: String)
    case superseded(MediaResourceState)

    public var state: MediaResourceState {
        switch self {
        case .confirmed(let s, _),
             .reconciledDifferent(let s, _),
             .unknownOutcome(let s, _),
             .superseded(let s):
            return s
        }
    }
}

// MARK: - MediaResourceState

public struct MediaResourceState: Sendable, Equatable {
    public var libraryMembership: MediaToggleState
    public var favorite: MediaToggleState

    public static let unknown = MediaResourceState(
        libraryMembership: .unknown,
        favorite: .unknown
    )

    public init(
        libraryMembership: MediaToggleState = .unknown,
        favorite: MediaToggleState = .unknown
    ) {
        self.libraryMembership = libraryMembership
        self.favorite = favorite
    }
}

// MARK: - MediaDetailIdentity

/// Identity of the currently visible detail page, used to deduplicate redundant navigation.
public enum MediaDetailIdentity: Sendable, Equatable, Hashable {
    case album(id: String)
    case playlist(id: String)
    case artist(id: String)
    case station(id: String)
}

// MARK: - MediaActionLocation

public enum MediaActionLocation: Sendable, Equatable {
    case pageHeader
    case card
    case trackRow
    case searchResult
    case artistHeader
    case queueRow
}

// MARK: - MediaActionCapabilities

/// Verified runtime capabilities for the current provider/account/session.
public struct MediaActionCapabilities: Sendable, Equatable {
    public var isAuthenticated: Bool
    public var canPlay: Bool
    public var canReadLibraryMembership: Bool
    public var canAddToLibrary: Bool
    public var canRemoveFromLibrary: Bool
    public var canReadFavorite: Bool
    public var canSetFavorite: Bool
    public var canStartSongStation: Bool
    public var canStartArtistStation: Bool
    public var canReorderQueue: Bool
    public var canRemoveFromQueue: Bool

    public static let playbackOnly = MediaActionCapabilities(
        isAuthenticated: false,
        canPlay: true,
        canReadLibraryMembership: false,
        canAddToLibrary: false,
        canRemoveFromLibrary: false,
        canReadFavorite: false,
        canSetFavorite: false,
        canStartSongStation: false,
        canStartArtistStation: false,
        canReorderQueue: true,
        canRemoveFromQueue: true
    )

    public init(
        isAuthenticated: Bool = false,
        canPlay: Bool = true,
        canReadLibraryMembership: Bool = false,
        canAddToLibrary: Bool = false,
        canRemoveFromLibrary: Bool = false,
        canReadFavorite: Bool = false,
        canSetFavorite: Bool = false,
        canStartSongStation: Bool = false,
        canStartArtistStation: Bool = false,
        canReorderQueue: Bool = true,
        canRemoveFromQueue: Bool = true
    ) {
        self.isAuthenticated = isAuthenticated
        self.canPlay = canPlay
        self.canReadLibraryMembership = canReadLibraryMembership
        self.canAddToLibrary = canAddToLibrary
        self.canRemoveFromLibrary = canRemoveFromLibrary
        self.canReadFavorite = canReadFavorite
        self.canSetFavorite = canSetFavorite
        self.canStartSongStation = canStartSongStation
        self.canStartArtistStation = canStartArtistStation
        self.canReorderQueue = canReorderQueue
        self.canRemoveFromQueue = canRemoveFromQueue
    }
}

// MARK: - MediaPlayIntent

/// Five product playback intents mapped onto `PlaybackCoordinatorV2`.
public enum MediaPlayIntent: String, Sendable, Equatable, Hashable, Codable {
    case replaceAndPlay
    case shuffleAndPlay
    case interruptAndPlay
    case prepend
    case append

    public var queueInsertionIntent: QueueInsertionIntent {
        switch self {
        case .replaceAndPlay: return .replaceAndPlay
        case .shuffleAndPlay: return .shuffleAndPlay
        case .interruptAndPlay: return .interruptAndPlay
        case .prepend: return .prepend
        case .append: return .append
        }
    }
}

// MARK: - MediaAction

public enum MediaAction: Sendable, Equatable {
    case play(intent: MediaPlayIntent, title: String, symbolName: String, isCollectionDefault: Bool)
    case playQueueEntry(entryID: UUID)
    case moveQueueEntryToNext(entryIDs: [UUID])
    case moveQueueEntryToEnd(entryIDs: [UUID])
    case removeQueueEntries(entryIDs: [UUID])

    case addToLibrary(MediaResourceReference)
    case removeFromLibrary(MediaResourceReference)
    case libraryStatusPlaceholder(title: String)

    case favorite(MediaResourceReference)
    case unfavorite(MediaResourceReference)
    case favoriteStatusPlaceholder(title: String)

    case startSongStation(MediaResourceReference)
    case startArtistStation(MediaArtistRef)

    case navigateToAlbum(id: String, title: String, isLibrary: Bool)
    case navigateToArtist(MediaArtistRef)
    case navigateToArtistsSubmenu([MediaArtistRef])
    case navigateToPlaylist(id: String, title: String, isLibrary: Bool)
    case navigateToStationDetail(id: String, title: String)
    case navigateToOrigin(PlaybackOrigin)

    public var title: String {
        switch self {
        case .play(_, let title, _, _): return title
        case .playQueueEntry: return "立即播放"
        case .moveQueueEntryToNext: return "移到下一首"
        case .moveQueueEntryToEnd: return "移到末尾"
        case .removeQueueEntries(let ids): return ids.count > 1 ? "移除所选 (\(ids.count))" : "移除"
        case .addToLibrary: return "添加到资料库"
        case .removeFromLibrary: return "从资料库移除"
        case .libraryStatusPlaceholder(let title): return title
        case .favorite: return "收藏"
        case .unfavorite: return "取消收藏"
        case .favoriteStatusPlaceholder(let title): return title
        case .startSongStation: return "歌曲电台"
        case .startArtistStation: return "艺人电台"
        case .navigateToAlbum: return "查看专辑"
        case .navigateToArtist: return "查看歌手"
        case .navigateToArtistsSubmenu: return "查看歌手"
        case .navigateToPlaylist: return "查看歌单"
        case .navigateToStationDetail: return "查看电台信息"
        case .navigateToOrigin(let origin): return "前往来源（\(origin.displayTitle)）"
        }
    }

    public var symbolName: String {
        switch self {
        case .play(_, _, let symbol, _): return symbol
        case .playQueueEntry: return "play.fill"
        case .moveQueueEntryToNext: return "text.line.first.and.arrowtriangle.forward"
        case .moveQueueEntryToEnd: return "text.append"
        case .removeQueueEntries: return "trash"
        case .addToLibrary: return "plus.circle"
        case .removeFromLibrary: return "checkmark.circle.fill"
        case .libraryStatusPlaceholder: return "ellipsis.circle"
        case .favorite: return "star"
        case .unfavorite: return "star.fill"
        case .favoriteStatusPlaceholder: return "ellipsis.circle"
        case .startSongStation: return "dot.radiowaves.left.and.right"
        case .startArtistStation: return "dot.radiowaves.left.and.right"
        case .navigateToAlbum: return "square.stack"
        case .navigateToArtist: return "music.mic"
        case .navigateToArtistsSubmenu: return "music.mic"
        case .navigateToPlaylist: return "music.note.list"
        case .navigateToStationDetail: return "info.circle"
        case .navigateToOrigin: return "arrow.up.forward.app"
        }
    }

    public var isEnabled: Bool {
        switch self {
        case .libraryStatusPlaceholder, .favoriteStatusPlaceholder:
            return false
        default:
            return true
        }
    }
}

// MARK: - MediaActionMenuSection

public struct MediaActionMenuSection: Sendable, Equatable {
    public let actions: [MediaAction]

    public init(actions: [MediaAction]) {
        self.actions = actions
    }
}

// MARK: - MediaActionMenuDescriptor

public struct MediaActionMenuDescriptor: Sendable, Equatable {
    public let sections: [MediaActionMenuSection]

    public var isEmpty: Bool {
        sections.allSatisfy(\.actions.isEmpty)
    }

    public var allActions: [MediaAction] {
        sections.flatMap(\.actions)
    }

    public init(sections: [MediaActionMenuSection]) {
        self.sections = sections.filter { !$0.actions.isEmpty }
    }
}

// MARK: - MediaActionContext

public struct MediaActionContext: Sendable, Equatable {
    public let resource: MediaResourceReference
    public let location: MediaActionLocation
    public let state: MediaResourceState
    public let capabilities: MediaActionCapabilities
    public let currentDetail: MediaDetailIdentity?
    public let selectedCount: Int
    public let selectedQueueEntryIDs: [UUID]

    public init(
        resource: MediaResourceReference,
        location: MediaActionLocation,
        state: MediaResourceState = .unknown,
        capabilities: MediaActionCapabilities = .playbackOnly,
        currentDetail: MediaDetailIdentity? = nil,
        selectedCount: Int = 1,
        selectedQueueEntryIDs: [UUID] = []
    ) {
        self.resource = resource
        self.location = location
        self.state = state
        self.capabilities = capabilities
        self.currentDetail = currentDetail
        self.selectedCount = max(1, selectedCount)
        self.selectedQueueEntryIDs = selectedQueueEntryIDs
    }
}
