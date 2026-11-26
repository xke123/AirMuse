import Foundation

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
    }

    public let kind: Kind
    public let sourceID: String?
    public let sourceTitle: String?
    public let isLibrary: Bool
    public let providerID: String
    public let artworkURL: URL?

    public static let unknown = PlaybackOrigin(
        kind: .unknown,
        sourceID: nil,
        sourceTitle: nil,
        isLibrary: false,
        providerID: "apple_music",
        artworkURL: nil
    )

    public init(
        kind: Kind,
        sourceID: String? = nil,
        sourceTitle: String? = nil,
        isLibrary: Bool = false,
        providerID: String = "apple_music",
        artworkURL: URL? = nil
    ) {
        self.kind = kind
        self.sourceID = sourceID
        self.sourceTitle = sourceTitle
        self.isLibrary = isLibrary
        self.providerID = providerID
        self.artworkURL = artworkURL
    }

    /// Whether this origin can be navigated to in the Library window (e.g. album, playlist, artist).
    public var canNavigate: Bool {
        guard let sourceID, !sourceID.isEmpty else { return false }
        switch kind {
        case .album, .playlist, .artist:
            return true
        case .song, .station, .search, .library, .forYou, .browse, .chart, .unknown:
            return false
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
