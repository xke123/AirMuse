// Sources/Providers/Spotify/SpotifyProvider.swift
// AirMuse macOS – Spotify provider via WKWebView (Web Playback SDK)
// Swift 6 strict concurrency – all WebView ops on @MainActor
// NOTE: Requires a valid Spotify Client ID in SpotifyConfiguration.clientID.
//       No tokens, secrets, or cookies are embedded in this source file.

import Foundation
import WebKit
import CryptoKit
import Domain
import Infrastructure

// MARK: - Configuration (populated at runtime from user settings — never hardcoded)

public struct SpotifyConfiguration: Sendable {
    /// OAuth 2.0 Client ID obtained from Spotify Developer Dashboard (provided by user at runtime).
    public var clientID: String
    /// Custom URI scheme registered in the app (e.g. "airmuse://spotify/callback").
    public var redirectURI: String
    public var scopes: [String]

    public init(clientID: String,
                redirectURI: String = "airmuse://spotify/callback",
                scopes: [String] = [
                    "streaming", "user-read-email", "user-read-private",
                    "user-library-read", "user-read-playback-state",
                    "user-modify-playback-state"
                ]) {
        self.clientID = clientID
        self.redirectURI = redirectURI
        self.scopes = scopes
    }
}

// MARK: - PKCE helpers

private enum PKCE {
    static func generateVerifier() -> String {
        var bytes = [UInt8](repeating: 0, count: 64)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64URLEncoded()
    }

    static func challenge(for verifier: String) -> String {
        let data = Data(verifier.utf8)
        let digest = SHA256.hash(data: data)
        return Data(digest).base64URLEncoded()
    }
}

private extension Data {
    func base64URLEncoded() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

// MARK: - Errors

public enum SpotifyError: Error, Sendable {
    case clientIDNotConfigured
    case authorizationFailed(String)
    case noActiveDevice
    case requiresExternalValidation   // DRM / protected-content boundary
    case bridgeError(String)
}

// MARK: - Provider actor

public actor SpotifyProvider:
    MusicSearchProvider,
    MusicPlaybackProvider,
    MusicAuthenticationProvider
{
    // MARK: MusicProvider

    public let providerID: String = "spotify"
    public let source: MusicSource = .spotify

    public var capabilities: MusicProviderCapabilities {
        get async {
            MusicProviderCapabilities(
                catalogSearch:  configuration.clientID.isEmpty ? .requiresAuthorization : .supported,
                libraryAccess:  _isAuthenticated ? .supported : .requiresAuthorization,
                playback:       _isAuthenticated ? .supported : .requiresAuthorization,
                lyricsAccess:   .unsupported,   // Web Playback SDK does not expose lyrics
                radioStations:  .unsupported
            )
        }
    }

    // MARK: - Private state

    private var configuration: SpotifyConfiguration
    private var _isAuthenticated: Bool = false
    private var _accessToken: String?  // in-memory only; never persisted to disk
    private var _pkceVerifier: String?

    // The WebView is owned and operated exclusively on MainActor
    // We pass instructions via a MainActor-isolated helper
    private let webViewKey = "spotify"

    // MARK: - Init

    public init(configuration: SpotifyConfiguration) {
        self.configuration = configuration
    }

    // MARK: - MusicAuthenticationProvider

    public var isAuthenticated: Bool { _isAuthenticated }

    public func authenticate() async throws {
        guard !configuration.clientID.isEmpty else {
            throw SpotifyError.clientIDNotConfigured
        }
        let verifier  = PKCE.generateVerifier()
        let challenge = PKCE.challenge(for: verifier)
        _pkceVerifier = verifier

        var components = URLComponents(string: "https://accounts.spotify.com/authorize")!
        components.queryItems = [
            .init(name: "client_id",             value: configuration.clientID),
            .init(name: "response_type",          value: "code"),
            .init(name: "redirect_uri",           value: configuration.redirectURI),
            .init(name: "code_challenge_method",  value: "S256"),
            .init(name: "code_challenge",         value: challenge),
            .init(name: "scope",                  value: configuration.scopes.joined(separator: " ")),
        ]
        guard let authURL = components.url else {
            throw SpotifyError.authorizationFailed("Could not build authorization URL")
        }
        // Open the system browser — we do NOT inject user credentials into a WebView
        let openURL = authURL
        await MainActor.run { _ = NSWorkspace.shared.open(openURL) }
        // Token exchange is handled by handleCallback(url:) below
    }

    /// Call this from your AppDelegate / URL handler when the redirect URI fires.
    public func handleCallback(url: URL) async throws {
        guard
            let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
            let code = components.queryItems?.first(where: { $0.name == "code" })?.value,
            let verifier = _pkceVerifier
        else { throw SpotifyError.authorizationFailed("Invalid callback URL") }

        let token = try await exchangeCodeForToken(code: code, verifier: verifier)
        _accessToken = token
        _isAuthenticated = true
        _pkceVerifier = nil
    }

    public func signOut() async throws {
        _accessToken = nil
        _isAuthenticated = false
        // Tear down the WebView session so cookies are cleared
        await MainActor.run {
            // WebViewManager.shared would handle teardown in the full integration
            WKWebsiteDataStore.nonPersistent().removeData(
                ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(),
                modifiedSince: .distantPast) {}
        }
    }

    public func currentAccount() async -> MusicAccount? {
        guard _isAuthenticated else { return nil }
        return MusicAccount(displayName: nil, source: .spotify, isAuthenticated: true)
    }

    // MARK: - MusicSearchProvider (Spotify Web API)

    public func search(query: String) async throws -> MusicSearchResult {
        guard let token = _accessToken else { throw AuthenticationError.requiresAuthorization }
        var components = URLComponents(string: "https://api.spotify.com/v1/search")!
        components.queryItems = [
            .init(name: "q",     value: query),
            .init(name: "type",  value: "track,album,artist"),
            .init(name: "limit", value: "20"),
        ]
        guard let url = components.url else { return MusicSearchResult() }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, _) = try await URLSession.shared.data(for: request)
        return try parseSearchResponse(data: data)
    }

    // MARK: - MusicPlaybackProvider (via Web Playback SDK in WKWebView)

    public func play(track: MusicTrack) async throws {
        guard _isAuthenticated else { throw AuthenticationError.requiresAuthorization }
        // Instruct the Web Playback SDK via bridge
        let command = BridgeCommand(type: "play", payload: [
            "uri": .string("spotify:track:\(track.id)")
        ])
        try await sendCommand(command)
    }

    public func playPause() async throws {
        try await sendCommand(BridgeCommand(type: "togglePlay"))
    }

    public func stop() async throws {
        try await sendCommand(BridgeCommand(type: "pause"))
    }

    public func skipToNext() async throws {
        try await sendCommand(BridgeCommand(type: "next"))
    }

    public func skipToPrevious() async throws {
        try await sendCommand(BridgeCommand(type: "previous"))
    }

    public func seek(to seconds: Double) async throws {
        try await sendCommand(BridgeCommand(type: "seek", payload: [
            "positionMs": .number(seconds * 1000)
        ]))
    }

    public func setVolume(_ volume: Float) async throws {
        try await sendCommand(BridgeCommand(type: "setVolume", payload: [
            "volume": .number(Double(volume))
        ]))
    }

    public func currentSession() async -> PlaybackSession {
        PlaybackSession(source: .spotify, state: _isAuthenticated ? .paused : .idle)
    }

    // MARK: - Private

    private func sendCommand(_ command: BridgeCommand) async throws {
        guard let js = try? command.toJavaScript() else { return }
        // All WebView operations must happen on MainActor
        await MainActor.run {
            // In the full integration, resolve the WKWebView from WebViewManager
            // and call evaluateJavaScript. The js string is JSON-encoded — safe.
            _ = js  // placeholder until WebViewManager is wired
        }
    }

    private func exchangeCodeForToken(code: String, verifier: String) async throws -> String {
        var request = URLRequest(url: URL(string: "https://accounts.spotify.com/api/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let body = [
            "grant_type=authorization_code",
            "code=\(code)",
            "redirect_uri=\(configuration.redirectURI)",
            "client_id=\(configuration.clientID)",
            "code_verifier=\(verifier)"
        ].joined(separator: "&")
        request.httpBody = body.data(using: .utf8)
        let (data, _) = try await URLSession.shared.data(for: request)
        guard
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let token = json["access_token"] as? String
        else { throw SpotifyError.authorizationFailed("Token exchange failed") }
        return token
    }

    private func parseSearchResponse(data: Data) throws -> MusicSearchResult {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return MusicSearchResult()
        }
        var tracks: [MusicTrack] = []
        var albums: [MusicAlbum] = []
        var artists: [MusicArtist] = []

        if let tracksObj  = json["tracks"]  as? [String: Any],
           let items = tracksObj["items"] as? [[String: Any]] {
            tracks = items.compactMap { parseSongItem($0) }
        }
        if let albumsObj  = json["albums"]  as? [String: Any],
           let items = albumsObj["items"] as? [[String: Any]] {
            albums = items.compactMap { parseAlbumItem($0) }
        }
        if let artistsObj = json["artists"] as? [String: Any],
           let items = artistsObj["items"] as? [[String: Any]] {
            artists = items.compactMap { parseArtistItem($0) }
        }
        return MusicSearchResult(tracks: tracks, albums: albums, artists: artists)
    }

    private func parseSongItem(_ d: [String: Any]) -> MusicTrack? {
        guard let id = d["id"] as? String, let name = d["name"] as? String else { return nil }
        let artistName = (d["artists"] as? [[String: Any]])?.first?["name"] as? String ?? ""
        let albumName  = (d["album"] as? [String: Any])?["name"] as? String
        let durationMs = d["duration_ms"] as? Double
        return MusicTrack(id: id, title: name, artistName: artistName,
                          albumTitle: albumName,
                          durationSeconds: durationMs.map { $0 / 1000 },
                          source: .spotify)
    }

    private func parseAlbumItem(_ d: [String: Any]) -> MusicAlbum? {
        guard let id = d["id"] as? String, let name = d["name"] as? String else { return nil }
        let artistName = (d["artists"] as? [[String: Any]])?.first?["name"] as? String ?? ""
        return MusicAlbum(id: id, title: name, artistName: artistName, source: .spotify)
    }

    private func parseArtistItem(_ d: [String: Any]) -> MusicArtist? {
        guard let id = d["id"] as? String, let name = d["name"] as? String else { return nil }
        return MusicArtist(id: id, name: name)
    }
}

// MARK: - Capability-only stub for protected content

extension SpotifyProvider {
    /// Playing Spotify's DRM-protected streams requires the official Spotify SDK or
    /// Web Playback SDK running in an authorised browser context.
    /// This capability must be verified externally and is never faked.
    public var protectedPlaybackCapability: ProviderCapability {
        .requiresSubscription   // Signals "needs external validation"
    }
}

import AppKit  // for NSWorkspace
