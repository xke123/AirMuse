import Foundation
import Domain

// MARK: - PlaybackSnapshot

public struct PlaybackSnapshot: Codable, Sendable, Equatable {
    public static let currentSchemaVersion = 2

    public let schemaVersion: Int
    public let providerID: String
    public let accountID: String?
    public let storefront: String?
    public let queueTracks: [MusicTrack]
    public let currentIndex: Int
    public let queuePayload: QueuePersistencePayload?
    public let positionMs: Int64
    public let volume: Float
    public let repeatMode: PlaybackState.RepeatMode
    public let shuffleEnabled: Bool
    public let savedAt: Date

    public init(
        schemaVersion: Int = PlaybackSnapshot.currentSchemaVersion,
        providerID: String,
        accountID: String?,
        storefront: String? = nil,
        queueTracks: [MusicTrack] = [],
        currentIndex: Int = 0,
        queuePayload: QueuePersistencePayload? = nil,
        positionMs: Int64,
        volume: Float,
        repeatMode: PlaybackState.RepeatMode,
        shuffleEnabled: Bool,
        savedAt: Date = Date()
    ) {
        self.schemaVersion = schemaVersion
        self.providerID = providerID
        self.accountID = accountID
        self.storefront = storefront
        self.queueTracks = queueTracks
        self.currentIndex = currentIndex
        self.queuePayload = queuePayload
        self.positionMs = positionMs
        self.volume = volume
        self.repeatMode = repeatMode
        self.shuffleEnabled = shuffleEnabled
        self.savedAt = savedAt
    }

    /// Migrates a v1 snapshot (or validates a v2 snapshot) into a `QueuePersistencePayload`.
    /// Unknown or corrupted indices are safely clamped or dropped.
    public func resolvedQueuePayload() -> QueuePersistencePayload? {
        if schemaVersion >= 2, let payload = queuePayload {
            // Validate referential integrity
            let validIDs = Set(payload.entries.map(\.id))
            let cleanBaseline = payload.baselineOrder.filter { validIDs.contains($0) }
            let cleanUpcoming = payload.upcomingOrder.filter { validIDs.contains($0) }
            let cleanCurrent = payload.currentEntryID.flatMap { validIDs.contains($0) ? $0 : nil }
            // Remote station: only restore if current entry is valid and has a real station target/ID; do not fabricate upcoming tracks
            if payload.owner == .remoteEngine {
                let validStationID = payload.activeTarget?.providerResourceID
                guard let cleanCurrent,
                      let currentEntry = payload.entries.first(where: { $0.id == cleanCurrent }),
                      let stationID = validStationID ?? (currentEntry.origin.kind == .station ? currentEntry.origin.sourceID : nil),
                      !stationID.isEmpty else {
                    return nil
                }
                let safeTarget = PlaybackTarget(
                    kind: .station,
                    providerResourceID: stationID,
                    title: payload.activeTarget?.title ?? currentEntry.origin.sourceTitle ?? currentEntry.track.title,
                    storefront: payload.activeTarget?.storefront
                )
                return QueuePersistencePayload(
                    queueID: payload.queueID,
                    entries: [currentEntry],
                    baselineOrder: [currentEntry.id],
                    upcomingOrder: [],
                    history: [],
                    currentEntryID: currentEntry.id,
                    activeTarget: safeTarget,
                    shuffleEnabled: false,
                    repeatMode: .off,
                    owner: .remoteEngine
                )
            }
            return QueuePersistencePayload(
                queueID: payload.queueID,
                entries: payload.entries,
                baselineOrder: cleanBaseline,
                upcomingOrder: cleanUpcoming,
                history: payload.history,
                currentEntryID: cleanCurrent,
                activeTarget: payload.activeTarget,
                shuffleEnabled: payload.shuffleEnabled,
                repeatMode: payload.repeatMode,
                owner: payload.owner
            )
        }

        // Schema v1 migration: convert tracks + currentIndex to independent QueueEntry IDs with .unknown origin
        guard schemaVersion == 1, !queueTracks.isEmpty else {
            return nil
        }
        let entries = queueTracks.map { QueueEntry(track: $0, origin: .unknown) }
        let validIndex = (0..<entries.count).contains(currentIndex) ? currentIndex : 0
        let currentID = entries[validIndex].id
        let upcomingIDs = Array(entries[(validIndex + 1)...].map(\.id))
        return QueuePersistencePayload(
            queueID: UUID(),
            entries: entries,
            baselineOrder: entries.map(\.id),
            upcomingOrder: upcomingIDs,
            history: [],
            currentEntryID: currentID,
            shuffleEnabled: shuffleEnabled,
            repeatMode: repeatMode,
            owner: .localCoordinator
        )
    }
}

// MARK: - PlaybackSnapshotStore

/// Persists playback queue, position, volume, and repeat/shuffle state atomically.
/// Private snapshots are isolated by `accountID` and `providerID` so unknown or mismatched accounts
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

    /// Loads snapshot only if schema is supported (v1 or v2) and account/provider match.
    /// Unknown provider snapshots are never defaulted to Apple Music.
    public func load(expectedProviderID: String, expectedAccountID: String?) -> PlaybackSnapshot? {
        guard !expectedProviderID.isEmpty,
              expectedProviderID != ProviderID.unknown.rawValue,
              FileManager.default.fileExists(atPath: fileURL.path),
              let data = try? Data(contentsOf: fileURL),
              let snap = try? decoder.decode(PlaybackSnapshot.self, from: data),
              (snap.schemaVersion == 1 || snap.schemaVersion == PlaybackSnapshot.currentSchemaVersion),
              !snap.providerID.isEmpty,
              snap.providerID != ProviderID.unknown.rawValue,
              snap.providerID == expectedProviderID else {
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
