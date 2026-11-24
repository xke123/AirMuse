// Sources/Providers/AppleMusic/Session/AppleMusicSessionAdapter.swift
// AirMuse macOS – Apple Music Session Adapter (Web vs MusicKit abstraction)
// Swift 6 strict concurrency

import Foundation
import Domain
import Infrastructure

// MARK: - AppleMusicSessionAdapter Protocol

/// Decouples the UI and higher-level providers from specific session implementations.
/// Allows clean switching between official Web Session and future MusicKit Developer API authorization.
public protocol AppleMusicSessionAdapter: Sendable {
    var snapshot: AppleMusicSessionSnapshot { get async }
    var webSessionState: AppleMusicWebSessionState { get async }
    var apiAuthorizationState: AppleMusicAPIAuthorizationState { get async }
    var currentAccount: MusicAccount? { get async }
    var currentGeneration: Int { get async }

    func authenticateWeb() async throws
    func signOut() async throws
    func switchAccount() async throws
    func resetSession() async throws
    func reauthenticate() async throws

    // Web Player Playback
    func beginTrackTransition() async
    func playTrack(id: String, type: String) async throws -> Bool
    func play() async throws -> Bool
    func pause() async throws -> Bool
    func playPause() async throws -> Bool
    func stop() async throws
    func seek(to seconds: Double) async throws
    func skipToNext() async throws
    func skipToPrevious() async throws
    func setVolume(_ volume: Float) async throws
    func currentPlaybackPosition() async -> (position: Double, duration: Double, isPlaying: Bool)
    func currentPlaybackSnapshot() async -> (position: Double, duration: Double, isPlaying: Bool, isBuffering: Bool, hasStartedAudio: Bool, volume: Float)
}

// MARK: - AppleMusicWebSessionAdapter

/// The primary adapter when operating without paid Apple Developer Program credentials.
/// Delegates all session lifecycle, cookie monitoring, and verification to `AppleMusicSessionManager`.
public final class AppleMusicWebSessionAdapter: AppleMusicSessionAdapter, @unchecked Sendable {
    private let manager: AppleMusicSessionManager

    public init(manager: AppleMusicSessionManager) {
        self.manager = manager
    }

    public var snapshot: AppleMusicSessionSnapshot {
        get async {
            await manager.currentSnapshot
        }
    }

    public var webSessionState: AppleMusicWebSessionState {
        get async {
            await manager.webSessionState
        }
    }

    public var apiAuthorizationState: AppleMusicAPIAuthorizationState {
        get async {
            await manager.apiAuthorizationState
        }
    }

    public var currentAccount: MusicAccount? {
        get async {
            await manager.currentAccount
        }
    }

    public var currentGeneration: Int {
        get async {
            await manager.generation
        }
    }

    public func authenticateWeb() async throws {
        await manager.startLogin()
    }

    public func signOut() async throws {
        await manager.signOut()
    }

    public func switchAccount() async throws {
        await manager.switchAccount()
    }

    public func resetSession() async throws {
        await manager.resetSession()
    }

    public func reauthenticate() async throws {
        await manager.reauthenticate()
    }

    public func beginTrackTransition() async {
        await manager.webPlayer.beginTrackTransition()
    }

    public func playTrack(id: String, type: String) async throws -> Bool {
        switch type {
        case "station":
            return try await manager.webPlayer.playStation(id: id)
        case "playlist":
            return try await manager.webPlayer.playPlaylist(id: id)
        case "album":
            return try await manager.webPlayer.playAlbum(id: id)
        default:
            return try await manager.webPlayer.playSong(id: id)
        }
    }

    public func play() async throws -> Bool {
        try await manager.webPlayer.play()
    }

    public func pause() async throws -> Bool {
        try await manager.webPlayer.pause()
    }

    public func playPause() async throws -> Bool {
        try await manager.webPlayer.playPause()
    }

    public func stop() async throws {
        try await manager.webPlayer.stop()
    }

    public func seek(to seconds: Double) async throws {
        try await manager.webPlayer.seek(to: seconds)
    }

    public func skipToNext() async throws {
        try await manager.webPlayer.skipToNext()
    }

    public func skipToPrevious() async throws {
        try await manager.webPlayer.skipToPrevious()
    }

    public func setVolume(_ volume: Float) async throws {
        try await manager.webPlayer.setVolume(volume)
    }

    public func currentPlaybackPosition() async -> (position: Double, duration: Double, isPlaying: Bool) {
        await (manager.webPlayer.currentPosition, manager.webPlayer.currentDuration, manager.webPlayer.isPlaying)
    }

    public func currentPlaybackSnapshot() async -> (position: Double, duration: Double, isPlaying: Bool, isBuffering: Bool, hasStartedAudio: Bool, volume: Float) {
        await (manager.webPlayer.currentPosition, manager.webPlayer.currentDuration, manager.webPlayer.isPlaying, manager.webPlayer.isBuffering, manager.webPlayer.hasStartedAudio, manager.webPlayer.currentVolume)
    }
}

// MARK: - AppleMusicKitSessionAdapter

/// Reserved adapter for future MusicKit Developer authorization when valid developer credentials exist.
/// Strictly reports developer credentials missing when running in standard environment.
public final class AppleMusicKitSessionAdapter: AppleMusicSessionAdapter, Sendable {

    public init() {}

    public var snapshot: AppleMusicSessionSnapshot {
        get async {
            AppleMusicSessionSnapshot(
                generation: 0,
                webSessionState: .loggedOut,
                apiAuthorizationState: .developerCredentialsMissing(reason: "未配置 Apple Developer Program 私钥与证书"),
                account: nil,
                hasUserToken: false,
                hasDeveloperToken: false,
                storefront: nil
            )
        }
    }

    public var webSessionState: AppleMusicWebSessionState {
        get async { .loggedOut }
    }

    public var apiAuthorizationState: AppleMusicAPIAuthorizationState {
        get async {
            .developerCredentialsMissing(reason: "未配置 Apple Developer Program 私钥与证书")
        }
    }

    public var currentAccount: MusicAccount? {
        get async { nil }
    }

    public var currentGeneration: Int {
        get async { 0 }
    }

    public func authenticateWeb() async throws {
        throw AppleMusicSessionError.developerTokenMissing
    }

    public func signOut() async throws {
        // No-op for unconfigured MusicKit adapter
    }

    public func switchAccount() async throws {
        throw AppleMusicSessionError.developerTokenMissing
    }

    public func resetSession() async throws {
        // No-op
    }

    public func reauthenticate() async throws {
        throw AppleMusicSessionError.developerTokenMissing
    }

    public func beginTrackTransition() async {}
    public func playTrack(id: String, type: String) async throws -> Bool { false }
    public func play() async throws -> Bool { false }
    public func pause() async throws -> Bool { false }
    public func playPause() async throws -> Bool { false }
    public func stop() async throws {}
    public func seek(to seconds: Double) async throws {}
    public func skipToNext() async throws {}
    public func skipToPrevious() async throws {}
    public func setVolume(_ volume: Float) async throws {}
    public func currentPlaybackPosition() async -> (position: Double, duration: Double, isPlaying: Bool) {
        (0, 0, false)
    }

    public func currentPlaybackSnapshot() async -> (position: Double, duration: Double, isPlaying: Bool, isBuffering: Bool, hasStartedAudio: Bool, volume: Float) {
        (0, 0, false, false, false, 1.0)
    }
}
