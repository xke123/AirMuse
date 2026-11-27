import Foundation

// MARK: - OriginResourceKind

public enum OriginResourceKind: String, Sendable, Codable, Equatable, Hashable {
    case song
    case album
    case playlist
    case artist
    case station
    case unknown

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = (try? container.decode(String.self)) ?? ""
        self = OriginResourceKind(rawValue: raw) ?? .unknown
    }
}

// MARK: - StationKind

public enum StationKind: String, Sendable, Codable, Equatable, Hashable {
    case live
    case algorithmic
    case unknown

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = (try? container.decode(String.self)) ?? ""
        self = StationKind(rawValue: raw) ?? .unknown
    }
}

// MARK: - OriginNavigationTarget

/// Lightweight, non-recursive typed route for pure internal navigation from a `PlaybackOrigin`.
public enum OriginNavigationTarget: Sendable, Codable, Equatable, Hashable {
    case resource(kind: OriginResourceKind, id: String, isLibrary: Bool, providerID: String)
    case librarySection(id: String, title: String?)
    case search(query: String, scope: String?, sectionID: String?)
    case chart(id: String, title: String?, isLibrary: Bool)
    case browseSection(id: String, title: String?)
    case stationDetail(id: String, title: String?, isLive: Bool?)
    case unknown

    public var isNavigable: Bool {
        switch self {
        case .resource(let kind, let id, _, let providerID):
            return kind != .unknown && !id.isEmpty && !providerID.isEmpty && providerID != ProviderID.unknown.rawValue
        case .librarySection(let id, _):
            return !id.isEmpty
        case .search(let query, _, _):
            return !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .chart(let id, _, _):
            return !id.isEmpty
        case .browseSection(let id, _):
            return !id.isEmpty
        case .stationDetail(let id, _, _):
            return !id.isEmpty
        case .unknown:
            return false
        }
    }

    private enum CodingKeys: String, CodingKey {
        case type, kind, id, isLibrary, providerID, title, query, scope, sectionID, isLive
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let type = (try? c.decode(String.self, forKey: .type)) ?? ""
        switch type {
        case "resource":
            let kind = (try? c.decode(OriginResourceKind.self, forKey: .kind)) ?? .unknown
            let id = (try? c.decode(String.self, forKey: .id)) ?? ""
            let isLibrary = (try? c.decode(Bool.self, forKey: .isLibrary)) ?? false
            let providerID = (try? c.decode(String.self, forKey: .providerID)) ?? ProviderID.unknown.rawValue
            self = (kind == .unknown || id.isEmpty || providerID.isEmpty || providerID == ProviderID.unknown.rawValue)
                ? .unknown
                : .resource(kind: kind, id: id, isLibrary: isLibrary, providerID: providerID)
        case "librarySection":
            let id = (try? c.decode(String.self, forKey: .id)) ?? ""
            let title = try? c.decodeIfPresent(String.self, forKey: .title)
            self = id.isEmpty ? .unknown : .librarySection(id: id, title: title)
        case "search":
            let query = (try? c.decode(String.self, forKey: .query)) ?? ""
            let scope = try? c.decodeIfPresent(String.self, forKey: .scope)
            let sectionID = try? c.decodeIfPresent(String.self, forKey: .sectionID)
            self = query.isEmpty ? .unknown : .search(query: query, scope: scope, sectionID: sectionID)
        case "chart":
            let id = (try? c.decode(String.self, forKey: .id)) ?? ""
            let title = try? c.decodeIfPresent(String.self, forKey: .title)
            let isLibrary = (try? c.decode(Bool.self, forKey: .isLibrary)) ?? false
            self = id.isEmpty ? .unknown : .chart(id: id, title: title, isLibrary: isLibrary)
        case "browseSection":
            let id = (try? c.decode(String.self, forKey: .id)) ?? ""
            let title = try? c.decodeIfPresent(String.self, forKey: .title)
            self = id.isEmpty ? .unknown : .browseSection(id: id, title: title)
        case "stationDetail":
            let id = (try? c.decode(String.self, forKey: .id)) ?? ""
            let title = try? c.decodeIfPresent(String.self, forKey: .title)
            let isLive = try? c.decodeIfPresent(Bool.self, forKey: .isLive)
            self = id.isEmpty ? .unknown : .stationDetail(id: id, title: title, isLive: isLive)
        default:
            self = .unknown
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .resource(let kind, let id, let isLibrary, let providerID):
            try c.encode("resource", forKey: .type)
            try c.encode(kind, forKey: .kind)
            try c.encode(id, forKey: .id)
            try c.encode(isLibrary, forKey: .isLibrary)
            try c.encode(providerID, forKey: .providerID)
        case .librarySection(let id, let title):
            try c.encode("librarySection", forKey: .type)
            try c.encode(id, forKey: .id)
            try c.encodeIfPresent(title, forKey: .title)
        case .search(let query, let scope, let sectionID):
            try c.encode("search", forKey: .type)
            try c.encode(query, forKey: .query)
            try c.encodeIfPresent(scope, forKey: .scope)
            try c.encodeIfPresent(sectionID, forKey: .sectionID)
        case .chart(let id, let title, let isLibrary):
            try c.encode("chart", forKey: .type)
            try c.encode(id, forKey: .id)
            try c.encodeIfPresent(title, forKey: .title)
            try c.encode(isLibrary, forKey: .isLibrary)
        case .browseSection(let id, let title):
            try c.encode("browseSection", forKey: .type)
            try c.encode(id, forKey: .id)
            try c.encodeIfPresent(title, forKey: .title)
        case .stationDetail(let id, let title, let isLive):
            try c.encode("stationDetail", forKey: .type)
            try c.encode(id, forKey: .id)
            try c.encodeIfPresent(title, forKey: .title)
            try c.encodeIfPresent(isLive, forKey: .isLive)
        case .unknown:
            try c.encode("unknown", forKey: .type)
        }
    }
}

// MARK: - StationSeedResource & StationOriginContext

/// Lightweight seed identity for song/artist stations. Contains no `PlaybackOrigin` to avoid recursion.
public struct StationSeedResource: Sendable, Codable, Equatable, Hashable {
    public let kind: OriginResourceKind
    public let id: String
    public let title: String
    public let isLibrary: Bool
    public let providerID: String
    public let albumID: String?
    public let albumTitle: String?

    public init(
        kind: OriginResourceKind,
        id: String,
        title: String,
        isLibrary: Bool = false,
        providerID: String = ProviderID.unknown.rawValue,
        albumID: String? = nil,
        albumTitle: String? = nil
    ) {
        self.kind = kind
        self.id = id
        self.title = title
        self.isLibrary = isLibrary
        self.providerID = providerID
        self.albumID = albumID
        self.albumTitle = albumTitle
    }
}

public struct StationOriginContext: Sendable, Codable, Equatable, Hashable {
    public let stationID: String
    public let stationType: StationKind
    public let seedResource: StationSeedResource?
    public let sourceNavigationTarget: OriginNavigationTarget?

    public init(
        stationID: String,
        stationType: StationKind = .unknown,
        seedResource: StationSeedResource? = nil,
        sourceNavigationTarget: OriginNavigationTarget? = nil
    ) {
        self.stationID = stationID
        self.stationType = stationType
        self.seedResource = seedResource
        self.sourceNavigationTarget = sourceNavigationTarget
    }
}

// MARK: - PlaybackOrigin

/// Captures the true source context where a queue entry was added from.
/// Origin is bound to each `QueueEntry` at insertion time rather than guessed from UI state.
public struct PlaybackOrigin: Sendable, Codable, Equatable, Hashable {

    public enum Kind: String, Sendable, Codable, Equatable, Hashable {
        case song
        case album
        case playlist
        case artist
        case station
        case search
        case library
        case forYou
        case browse
        case chart
        case unknown

        public init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            let raw = (try? container.decode(String.self)) ?? ""
            self = Kind(rawValue: raw) ?? .unknown
        }
    }

    public let kind: Kind
    public let sourceID: String?
    public let sourceTitle: String?
    public let isLibrary: Bool
    public let providerID: String
    public let scope: ResourceScope
    public let artworkURL: URL?
    public let navigationTarget: OriginNavigationTarget?
    public let stationContext: StationOriginContext?

    public static let unknown = PlaybackOrigin(
        kind: .unknown,
        sourceID: nil,
        sourceTitle: nil,
        isLibrary: false,
        providerID: ProviderID.unknown.rawValue,
        scope: .unknown,
        artworkURL: nil
    )

    public init(
        kind: Kind,
        sourceID: String? = nil,
        sourceTitle: String? = nil,
        isLibrary: Bool = false,
        providerID: String = ProviderID.unknown.rawValue,
        scope: ResourceScope = .unknown,
        artworkURL: URL? = nil,
        navigationTarget: OriginNavigationTarget? = nil,
        stationContext: StationOriginContext? = nil
    ) {
        self.kind = kind
        self.sourceID = sourceID
        self.sourceTitle = sourceTitle
        self.isLibrary = isLibrary
        self.providerID = providerID
        self.scope = scope
        self.artworkURL = artworkURL
        self.navigationTarget = navigationTarget
        self.stationContext = stationContext
    }

    private enum CodingKeys: String, CodingKey {
        case kind, sourceID, sourceTitle, isLibrary, providerID, scope, artworkURL, navigationTarget, stationContext
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.kind = (try? c.decode(Kind.self, forKey: .kind)) ?? .unknown
        self.sourceID = try? c.decodeIfPresent(String.self, forKey: .sourceID)
        self.sourceTitle = try? c.decodeIfPresent(String.self, forKey: .sourceTitle)
        self.isLibrary = (try? c.decodeIfPresent(Bool.self, forKey: .isLibrary)) ?? false
        self.providerID = (try? c.decodeIfPresent(String.self, forKey: .providerID)) ?? ProviderID.unknown.rawValue
        self.scope = (try? c.decodeIfPresent(ResourceScope.self, forKey: .scope)) ?? .unknown
        self.artworkURL = try? c.decodeIfPresent(URL.self, forKey: .artworkURL)
        self.navigationTarget = try? c.decodeIfPresent(OriginNavigationTarget.self, forKey: .navigationTarget)
        self.stationContext = try? c.decodeIfPresent(StationOriginContext.self, forKey: .stationContext)
    }

    /// Whether this origin has a verified internal navigation target.
    public var canNavigate: Bool {
        if let navigationTarget, navigationTarget.isNavigable {
            return true
        }
        if let stationNav = stationContext?.sourceNavigationTarget, stationNav.isNavigable {
            return true
        }
        guard let sourceID, !sourceID.isEmpty,
              !providerID.isEmpty, providerID != ProviderID.unknown.rawValue else { return false }
        switch kind {
        case .album, .playlist, .artist:
            return true
        case .song, .station, .search, .library, .forYou, .browse, .chart, .unknown:
            return false
        }
    }

    /// Resolved typed navigation target (preferring explicit `navigationTarget`, falling back to legacy `kind` + `sourceID`).
    public var resolvedNavigationTarget: OriginNavigationTarget? {
        if let navigationTarget, navigationTarget.isNavigable {
            return navigationTarget
        }
        if let stationNav = stationContext?.sourceNavigationTarget, stationNav.isNavigable {
            return stationNav
        }
        guard let sourceID, !sourceID.isEmpty,
              !providerID.isEmpty, providerID != ProviderID.unknown.rawValue else { return nil }
        switch kind {
        case .album:
            return .resource(kind: .album, id: sourceID, isLibrary: isLibrary, providerID: providerID)
        case .playlist:
            return .resource(kind: .playlist, id: sourceID, isLibrary: isLibrary, providerID: providerID)
        case .artist:
            return .resource(kind: .artist, id: sourceID, isLibrary: isLibrary, providerID: providerID)
        default:
            return nil
        }
    }

    /// Human-readable label for UI display and tooltips.
    public var displayTitle: String {
        if let sourceTitle, !sourceTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return sourceTitle
        }
        switch kind {
        case .album: return "专辑"
        case .playlist: return "歌单"
        case .artist: return "艺人"
        case .station: return "电台"
        case .search: return "搜索结果"
        case .library: return "资料库"
        case .forYou: return "为你推荐"
        case .browse: return "浏览"
        case .chart: return "排行榜"
        case .song: return "单曲"
        case .unknown: return "未知来源"
        }
    }
}
