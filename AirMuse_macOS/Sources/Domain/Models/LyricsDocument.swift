import Foundation

// MARK: - LyricsDocument

/// A complete lyrics document for one track (may contain translations).
public struct LyricsDocument: Sendable, Codable {
    public var trackKey: String
    public var lines: [LyricsLine]
    public var offsetMs: Int64           // user-adjusted timing offset
    public var isLoading: Bool
    public var statusText: String
    public var errorMessage: String?

    public var offsetSeconds: Double {
        get { Double(offsetMs) / 1000.0 }
        set { offsetMs = Int64(newValue * 1000.0) }
    }

    public init(
        trackKey: String = "",
        lines: [LyricsLine] = [],
        offsetMs: Int64 = 0,
        isLoading: Bool = false,
        statusText: String = "暂无歌词",
        errorMessage: String? = nil
    ) {
        self.trackKey = trackKey
        self.lines = lines
        self.offsetMs = offsetMs
        self.isLoading = isLoading
        self.statusText = statusText
        self.errorMessage = errorMessage
    }

    public static let empty = LyricsDocument(trackKey: "", statusText: "暂无歌词")

    /// Returns the active line for the given playback position.
    public func activeLine(atMs position: Int64) -> LyricsLine? {
        let adjusted = position - offsetMs
        return lines.last(where: { $0.timeMs <= adjusted })
    }

    public func activeLine(atSeconds seconds: Double) -> LyricsLine? {
        activeLine(atMs: Int64(seconds * 1000))
    }

    /// Returns the index of the active line for the given playback position (ms).
    /// Returns nil if position is before the first line.
    public func activeLine(at positionMs: Int64) -> Int? {
        guard !lines.isEmpty else { return nil }
        let adjusted = positionMs - offsetMs
        guard adjusted >= 0, let first = lines.first, adjusted >= first.timeMs else { return nil }
        var idx = 0
        for (i, line) in lines.enumerated() {
            if line.timeMs <= adjusted { idx = i } else { break }
        }
        return idx
    }
}
