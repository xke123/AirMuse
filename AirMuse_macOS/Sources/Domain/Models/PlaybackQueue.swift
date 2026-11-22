import Foundation

// MARK: - PlaybackQueue

/// An ordered list of tracks with a cursor pointing to the current item.
public struct PlaybackQueue: Sendable {
    public var tracks: [MusicTrack]
    public var currentIndex: Int?

    public var currentTrack: MusicTrack? {
        guard let idx = currentIndex, tracks.indices.contains(idx) else { return nil }
        return tracks[idx]
    }

    public var nextTrack: MusicTrack? {
        guard let idx = currentIndex, tracks.indices.contains(idx + 1) else { return nil }
        return tracks[idx + 1]
    }

    public var previousTrack: MusicTrack? {
        guard let idx = currentIndex, idx > 0, tracks.indices.contains(idx - 1) else { return nil }
        return tracks[idx - 1]
    }

    public var items: [MusicTrack] {
        get { tracks }
        set { tracks = newValue }
    }

    public init(tracks: [MusicTrack] = [], currentIndex: Int? = nil) {
        self.tracks = tracks
        self.currentIndex = currentIndex
    }

    public init(items: [MusicTrack], currentIndex: Int? = nil) {
        self.tracks = items
        self.currentIndex = currentIndex
    }

    public mutating func advance() {
        guard let idx = currentIndex, idx + 1 < tracks.count else { return }
        currentIndex = idx + 1
    }

    public mutating func retreat() {
        guard let idx = currentIndex, idx > 0 else { return }
        currentIndex = idx - 1
    }

    public mutating func shuffle() {
        guard !tracks.isEmpty else { return }
        let current = currentTrack
        tracks.shuffle()
        if let c = current {
            currentIndex = tracks.firstIndex(where: { $0.id == c.id })
        }
    }
}
