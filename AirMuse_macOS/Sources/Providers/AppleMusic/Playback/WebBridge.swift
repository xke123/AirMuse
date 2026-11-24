import Foundation
import WebKit
import Domain

// MARK: - WebBridgeInboundEvent

public enum WebBridgeInboundEvent: Sendable, Equatable {
    case ready(engineInstanceID: UUID, isAuthorized: Bool)
    case playbackStateDidChange(
        engineInstanceID: UUID,
        operationID: UInt64,
        rawState: Int,
        isPlaying: Bool,
        isBuffering: Bool,
        isPaused: Bool
    )
    case playbackTimeDidChange(
        engineInstanceID: UUID,
        operationID: UInt64,
        positionSeconds: Double,
        durationSeconds: Double
    )
    case nowPlayingItemDidChange(
        engineInstanceID: UUID,
        operationID: UInt64,
        title: String,
        artistName: String,
        albumTitle: String,
        artworkURL: String,
        trackID: String,
        isAuthorized: Bool,
        playbackDuration: Double,
        metaDuration: Double
    )
    case playbackEnded(
        engineInstanceID: UUID,
        operationID: UInt64,
        positionSeconds: Double,
        durationSeconds: Double
    )
}

// MARK: - WebBridgeParser

public enum WebBridgeParser: Sendable {
    public static let messageHandlerName = "airmusePlayerBridge"

    /// Parses and validates an inbound script message against the active `engineInstanceID`.
    /// Rejects malformed payloads or messages belonging to a stale engine instance.
    public static func parse(
        body: Any,
        expectedEngineID: UUID
    ) -> WebBridgeInboundEvent? {
        guard let dict = body as? [String: Any],
              let event = dict["event"] as? String else {
            return nil
        }

        if let rawEngineID = dict["engineInstanceID"] as? String,
           let parsedID = UUID(uuidString: rawEngineID),
           parsedID != expectedEngineID {
            return nil
        }

        let opID: UInt64
        if let num = dict["operationID"] as? NSNumber {
            opID = num.uint64Value
        } else {
            opID = 0
        }

        switch event {
        case "ready":
            let isAuth = dict["isAuthorized"] as? Bool ?? false
            return .ready(engineInstanceID: expectedEngineID, isAuthorized: isAuth)

        case "playbackStateDidChange":
            let rawState = dict["playbackState"] as? Int ?? -1
            let isPlaying = dict["isPlaying"] as? Bool ?? (rawState == 2)
            let isBuffering = dict["isBuffering"] as? Bool ?? (rawState == 1 || rawState == 7 || rawState == 8)
            let isPaused = dict["isPaused"] as? Bool ?? (rawState == 3 || rawState == 4 || rawState == 0)
            return .playbackStateDidChange(
                engineInstanceID: expectedEngineID,
                operationID: opID,
                rawState: rawState,
                isPlaying: isPlaying,
                isBuffering: isBuffering,
                isPaused: isPaused
            )

        case "playbackTimeDidChange":
            let cur = dict["currentPlaybackTime"] as? Double ?? 0
            let dur = dict["currentPlaybackDuration"] as? Double ?? 0
            return .playbackTimeDidChange(
                engineInstanceID: expectedEngineID,
                operationID: opID,
                positionSeconds: cur,
                durationSeconds: dur
            )

        case "nowPlayingItemDidChange":
            let title = dict["title"] as? String ?? ""
            let artist = dict["artistName"] as? String ?? ""
            let album = dict["albumName"] as? String ?? ""
            let artURL = dict["artworkURL"] as? String ?? ""
            let trackID = dict["id"] as? String ?? ""
            let isAuth = dict["isAuthorized"] as? Bool ?? false
            let pbDur = dict["playbackDuration"] as? Double ?? 0
            let metaDur = dict["metaDuration"] as? Double ?? 0
            return .nowPlayingItemDidChange(
                engineInstanceID: expectedEngineID,
                operationID: opID,
                title: title,
                artistName: artist,
                albumTitle: album,
                artworkURL: artURL,
                trackID: trackID,
                isAuthorized: isAuth,
                playbackDuration: pbDur,
                metaDuration: metaDur
            )

        case "playbackEnded":
            let cur = dict["currentPlaybackTime"] as? Double ?? 0
            let dur = dict["currentPlaybackDuration"] as? Double ?? 0
            return .playbackEnded(
                engineInstanceID: expectedEngineID,
                operationID: opID,
                positionSeconds: cur,
                durationSeconds: dur
            )

        default:
            return nil
        }
    }
}
