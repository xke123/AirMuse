import Foundation

// MARK: - QueueEntry

/// A single, uniquely identified item in the playback queue.
/// Even if the same `MusicTrack` appears multiple times, each occurrence has its own `UUID`
/// and its own `PlaybackOrigin` captured when added.
public struct QueueEntry: Sendable, Identifiable, Equatable, Hashable, Codable {
    public let id: UUID
    public let track: MusicTrack
    public let origin: PlaybackOrigin
    public let batchID: UUID?
    public let addedAt: Date

    public init(
        id: UUID = UUID(),
        track: MusicTrack,
        origin: PlaybackOrigin = .unknown,
        batchID: UUID? = nil,
        addedAt: Date = Date()
    ) {
        self.id = id
        self.track = track
        self.origin = origin
        self.batchID = batchID
        self.addedAt = addedAt
    }

    public static func == (lhs: QueueEntry, rhs: QueueEntry) -> Bool {
        lhs.id == rhs.id &&
        lhs.track == rhs.track &&
        lhs.origin == rhs.origin &&
        lhs.batchID == rhs.batchID
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

// MARK: - PlaybackQueue

/// An ordered list of queue entries with a cursor pointing to the current item.
/// Preserves compatibility with legacy `tracks` / `items` callers while giving every entry
/// a unique `UUID` and `PlaybackOrigin`.
public struct PlaybackQueue: Sendable, Equatable, Codable {
    public var entries: [QueueEntry]
    public var currentIndex: Int?

    public var tracks: [MusicTrack] {
        get { entries.map(\.track) }
        set {
            entries = newValue.map { QueueEntry(track: $0, origin: .unknown) }
        }
    }

    public var currentEntry: QueueEntry? {
        guard let idx = currentIndex, entries.indices.contains(idx) else { return nil }
        return entries[idx]
    }

    public var currentTrack: MusicTrack? {
        currentEntry?.track
    }

    public var nextTrack: MusicTrack? {
        guard let idx = currentIndex, entries.indices.contains(idx + 1) else { return nil }
        return entries[idx + 1].track
    }

    public var previousTrack: MusicTrack? {
        guard let idx = currentIndex, idx > 0, entries.indices.contains(idx - 1) else { return nil }
        return entries[idx - 1].track
    }

    public var items: [MusicTrack] {
        get { tracks }
        set { tracks = newValue }
    }

    public init(entries: [QueueEntry] = [], currentIndex: Int? = nil) {
        self.entries = entries
        self.currentIndex = currentIndex
    }

    public init(tracks: [MusicTrack], currentIndex: Int? = nil, origin: PlaybackOrigin = .unknown) {
        self.entries = tracks.map { QueueEntry(track: $0, origin: origin) }
        self.currentIndex = currentIndex
    }

    public init(items: [MusicTrack], currentIndex: Int? = nil, origin: PlaybackOrigin = .unknown) {
        self.entries = items.map { QueueEntry(track: $0, origin: origin) }
        self.currentIndex = currentIndex
    }

    public mutating func advance() {
        guard let idx = currentIndex, idx + 1 < entries.count else { return }
        currentIndex = idx + 1
    }

    public mutating func retreat() {
        guard let idx = currentIndex, idx > 0 else { return }
        currentIndex = idx - 1
    }

    public mutating func shuffle() {
        guard !entries.isEmpty else { return }
        let currentID = currentEntry?.id
        entries.shuffle()
        if let cid = currentID {
            currentIndex = entries.firstIndex(where: { $0.id == cid })
        }
    }
}
