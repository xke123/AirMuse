import Foundation
import Domain

// MARK: - PlaybackSnapshot

public struct PlaybackSnapshot: Codable, Sendable, Equatable {
    public let schemaVersion: Int
    public let providerID: String
    public let accountID: String?
    public let queueTracks: [MusicTrack]
    public let currentIndex: Int
    public let positionMs: Int64
    public let volume: Float
    public let repeatMode: PlaybackState.RepeatMode
    public let shuffleEnabled: Bool
    public let savedAt: Date

    public init(
        schemaVersion: Int = 1,
        providerID: String,
        accountID: String?,
        queueTracks: [MusicTrack],
        currentIndex: Int,
        positionMs: Int64,
        volume: Float,
        repeatMode: PlaybackState.RepeatMode,
        shuffleEnabled: Bool,
        savedAt: Date = Date()
    ) {
        self.schemaVersion = schemaVersion
        self.providerID = providerID
        self.accountID = accountID
        self.queueTracks = queueTracks
        self.currentIndex = currentIndex
        self.positionMs = positionMs
        self.volume = volume
        self.repeatMode = repeatMode
        self.shuffleEnabled = shuffleEnabled
        self.savedAt = savedAt
    }
}

// MARK: - PlaybackSnapshotStore

/// Persists playback queue, position, volume, and repeat/shuffle state atomically.
/// Private snapshots are isolated by `accountID` so unknown or mismatched accounts
/// never mount another user's queue.
public actor PlaybackSnapshotStore {
    private let fileURL: URL
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init(fileURL: URL? = nil) {
        if let fileURL {
            self.fileURL = fileURL
        } else {
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? URL(fileURLWithPath: NSTemporaryDirectory())
            self.fileURL = appSupport.appendingPathComponent("AirMuse/playback_snapshot_v2.json")
        }
    }

    public func save(_ snapshot: PlaybackSnapshot) throws {
        let dir = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let data = try encoder.encode(snapshot)
        try data.write(to: fileURL, options: .atomic)
    }

    /// Loads snapshot only if schema matches and (if private `accountID` is present)
    /// it strictly matches `expectedAccountID`. Always restores in paused state by caller.
    public func load(expectedAccountID: String?) -> PlaybackSnapshot? {
        guard FileManager.default.fileExists(atPath: fileURL.path),
              let data = try? Data(contentsOf: fileURL),
              let snap = try? decoder.decode(PlaybackSnapshot.self, from: data),
              snap.schemaVersion == 1 else {
            return nil
        }
        if let snapAccount = snap.accountID {
            guard let expectedAccountID, snapAccount == expectedAccountID else {
                return nil
            }
        }
        return snap
    }

    public func clear() {
        try? FileManager.default.removeItem(at: fileURL)
    }
}
