import Foundation

// MARK: - LyricsLine

/// A single timed lyric line, optionally with a translation.
public struct LyricsLine: Sendable, Identifiable, Codable {
    public let id: UUID
    public var timeMs: Int64
    public var text: String
    public var translation: String?

    public var startTime: Double { Double(timeMs) / 1000.0 }

    public init(
        id: UUID = .init(),
        timeMs: Int64,
        text: String,
        translation: String? = nil
    ) {
        self.id = id
        self.timeMs = timeMs
        self.text = text
        self.translation = translation
    }

    public init(startTime: Double, endTime: Double? = nil, text: String, translation: String? = nil) {
        self.id = UUID()
        self.timeMs = Int64(startTime * 1000.0)
        self.text = text
        self.translation = translation
    }
}
