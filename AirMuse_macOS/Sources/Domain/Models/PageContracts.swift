import Foundation

// MARK: - PageCursor

/// Opaque pagination cursor owned and interpreted exclusively by the originating adapter.
/// Bound to provider, scope, and route fingerprint to prevent cross-platform/account/query reuse.
public struct PageCursor: Sendable, Hashable, Codable {
    public let opaqueToken: String
    public let providerID: ProviderID
    public let scope: ResourceScope
    public let routeFingerprint: String

    public init(
        opaqueToken: String,
        providerID: ProviderID,
        scope: ResourceScope,
        routeFingerprint: String
    ) {
        self.opaqueToken = opaqueToken
        self.providerID = providerID
        self.scope = scope
        self.routeFingerprint = routeFingerprint
    }

    public func matches(
        providerID: ProviderID,
        scope: ResourceScope,
        routeFingerprint: String
    ) -> Bool {
        self.providerID == providerID &&
        self.scope == scope &&
        self.routeFingerprint == routeFingerprint &&
        !opaqueToken.isEmpty
    }
}

// MARK: - Page

public struct Page<Element: Sendable>: Sendable {
    public let items: [Element]
    public let next: PageCursor?
    public let totalCount: Int?

    public init(items: [Element], next: PageCursor? = nil, totalCount: Int? = nil) {
        self.items = items
        self.next = next
        self.totalCount = totalCount
    }
}

// MARK: - CollectionTrackPage

public struct CollectionTrackPage: Sendable {
    public let tracks: [MusicTrack]
    public let nextCursor: PageCursor?
    public let totalCount: Int?

    public init(tracks: [MusicTrack], nextCursor: PageCursor? = nil, totalCount: Int? = nil) {
        self.tracks = tracks
        self.nextCursor = nextCursor
        self.totalCount = totalCount
    }
}

// MARK: - BrowseRoute & Generic Presentation Models

public struct BrowseTabDescriptor: Sendable, Hashable, Codable, Identifiable {
    public let id: String
    public let title: String
    public let symbolName: String

    public init(id: String, title: String, symbolName: String) {
        self.id = id
        self.title = title
        self.symbolName = symbolName
    }
}

public struct BrowseRoute: Sendable, Hashable, Codable {
    public enum Kind: Sendable, Hashable, Codable {
        case tab(id: String)
        case section(id: String, title: String?)
        case search(query: String, scope: String?)
        case detail(ResourceIdentity)
    }

    public let providerID: ProviderID
    public let scope: ResourceScope
    public let kind: Kind

    public init(providerID: ProviderID, scope: ResourceScope, kind: Kind) {
        self.providerID = providerID
        self.scope = scope
        self.kind = kind
    }
}

public struct MediaCardModel: Sendable, Hashable, Identifiable {
    public let id: String
    public let identity: ResourceIdentity
    public let title: String
    public let subtitle: String
    public let artworkURL: URL?
    public let isExplicit: Bool
    public let track: MusicTrack?
    public let stationKind: StationKind?

    public init(
        identity: ResourceIdentity,
        title: String,
        subtitle: String,
        artworkURL: URL? = nil,
        isExplicit: Bool = false,
        track: MusicTrack? = nil,
        stationKind: StationKind? = nil
    ) {
        self.id = identity.scopedKey
        self.identity = identity
        self.title = title
        self.subtitle = subtitle
        self.artworkURL = artworkURL
        self.isExplicit = isExplicit
        self.track = track
        self.stationKind = stationKind
    }
}

public struct BrowseSectionModel: Sendable, Identifiable {
    public let id: String
    public let title: String
    public let items: [MediaCardModel]
    public let nextCursor: PageCursor?

    public init(id: String, title: String, items: [MediaCardModel], nextCursor: PageCursor? = nil) {
        self.id = id
        self.title = title
        self.items = items
        self.nextCursor = nextCursor
    }
}

public struct BrowsePageModel: Sendable {
    public let route: BrowseRoute
    public let title: String
    public let sections: [BrowseSectionModel]

    public init(route: BrowseRoute, title: String, sections: [BrowseSectionModel]) {
        self.route = route
        self.title = title
        self.sections = sections
    }
}
