import Foundation

// MARK: - MusicSource

/// Identifies the music service / platform.
public enum MusicSource: String, Sendable, Hashable, Codable, CaseIterable {
    case appleMusic = "apple_music"
    case spotify    = "spotify"
    case qqMusic    = "qq_music"
    case local      = "local"
    case unknown    = "unknown"

    public var displayName: String {
        switch self {
        case .appleMusic: "Apple Music"
        case .spotify:    "Spotify"
        case .qqMusic:    "QQ 音乐"
        case .local:      "本地音乐"
        case .unknown:    "Ready"
        }
    }
}
