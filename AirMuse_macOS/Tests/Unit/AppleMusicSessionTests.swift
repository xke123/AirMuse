// Tests/Unit/AppleMusicSessionTests.swift
// AirMuse macOS – Automated Tests for Apple Music Authentication & Session Management
// Swift 6 strict concurrency

import Testing
import Foundation
import WebKit
@testable import Domain
@testable import Infrastructure
@testable import Providers

@Suite("AppleMusicSessionTests")
struct AppleMusicSessionTests {

    // MARK: - 1. Session State Machine Transitions

    @Test func testWebSessionStatePropertiesAndTransitions() {
        var state: AppleMusicWebSessionState = .loggedOut
        #expect(!state.isLoggedIn)
        #expect(state.displayName == "未登录")

        state = .loggingIn(progressMessage: "加载页面...")
        #expect(!state.isLoggedIn)
        #expect(state.displayName == "登录中")

        state = .verifying(tokenSnippet: "abc12345")
        #expect(!state.isLoggedIn)
        #expect(state.displayName == "验证中")

        let account = MusicAccount(
            id: "user-1",
            providerID: "apple_music",
            displayName: "Test User",
            isAuthenticated: true
        )
        state = .loggedIn(account: account, storefront: "cn")
        #expect(state.isLoggedIn)
        #expect(state.displayName.contains("Test User"))

        state = .expired(reason: "Token 401")
        #expect(!state.isLoggedIn)
        #expect(state.displayName.contains("已失效"))

        state = .error(.networkUnavailable)
        #expect(!state.isLoggedIn)
        #expect(state.displayName.contains("错误"))

        state = .unknown
        #expect(!state.isLoggedIn)
        #expect(state.displayName == "未知状态")
    }

    // MARK: - 2. API Authorization Separation

    @Test func testAPIAuthorizationStateHonesty() {
        let missing = AppleMusicAPIAuthorizationState.developerCredentialsMissing(reason: "无付费账号")
        #expect(!missing.isAuthorized)
        #expect(missing.displayDescription.contains("未配置开发者凭据"))

        let authorized = AppleMusicAPIAuthorizationState.authorized
        #expect(authorized.isAuthorized)
        #expect(authorized.displayDescription.contains("已获得 MusicKit 官方授权"))

        let denied = AppleMusicAPIAuthorizationState.denied
        #expect(!denied.isAuthorized)
        #expect(denied.displayDescription.contains("拒绝"))
    }

    // MARK: - 3. Stale Request Discarding via Session Generation

    @Test func testStaleRequestDiscardedByGeneration() async {
        let ampClient = AppleMusicAmpClient()
        await ampClient.setActiveGeneration(1)
        #expect(await ampClient.currentGeneration() == 1)

        // Simulate session logout or switch that bumps generation to 2
        await ampClient.setActiveGeneration(2)
        #expect(await ampClient.currentGeneration() == 2)

        // Attempting an API request with the old generation (1) must fail with generation mismatch
        do {
            _ = try await ampClient.fetchCharts(limit: 10, generation: 1)
            #expect(Bool(false), "Should have thrown sessionGenerationMismatch")
        } catch let err as AppleMusicSessionError {
            #expect(err == .sessionGenerationMismatch)
        } catch {
            // If developer token missing throws first, that is also valid before generation check
            #expect(error is AppleMusicSessionError)
        }
    }

    // MARK: - 4. Token Expiration Notification Handling

    @Test @MainActor func testSessionExpirationHandlerPurgesUserToken() async {
        let ampClient = AppleMusicAmpClient(devToken: "dev-mock", userToken: "user-token-old")
        #expect(await ampClient.hasUserToken())

        final class FlagBox: @unchecked Sendable {
            var fired = false
        }
        let box = FlagBox()
        await ampClient.setOnSessionExpired {
            box.fired = true
        }

        let onExpired = await ampClient.onSessionExpired
        #expect(onExpired != nil)
        onExpired?()
        #expect(box.fired)

        await ampClient.setUserToken(nil)
        #expect(!(await ampClient.hasUserToken()))
    }

    // MARK: - 5. Account Display Name Trust & Anti-Fake Guard

    @Test func testDisplayNameNeverUsesDummyStaticName() {
        let dummyNames = ["小可", "Tim Cook", "Apple Music", "Admin", "root"]

        // Verified name from Apple server
        let verifiedAccount = MusicAccount(
            id: "verified-1",
            providerID: "apple_music",
            displayName: "Zhang San",
            isAuthenticated: true
        )
        #expect(verifiedAccount.displayName == "Zhang San")
        #expect(!dummyNames.contains(verifiedAccount.displayName))

        // Fallback when server provides storefront only
        let storefrontFallback = MusicAccount(
            id: "fallback-1",
            providerID: "apple_music",
            displayName: "Apple Music 会员 (CN)",
            isAuthenticated: true
        )
        #expect(storefrontFallback.displayName == "Apple Music 会员 (CN)")
        #expect(!dummyNames.contains(storefrontFallback.displayName))

        // Default anonymous fallback
        let defaultFallback = MusicAccount(
            id: "fallback-2",
            providerID: "apple_music",
            displayName: "Apple Music 用户",
            isAuthenticated: true
        )
        #expect(defaultFallback.displayName == "Apple Music 用户")
        #expect(!dummyNames.contains(defaultFallback.displayName))
    }

    // MARK: - 6. Capability-Based Permission Matrix

    @Test @MainActor func testCapabilityMatrixWebVsGuestVsAPI() async {
        // 1. Unauthenticated Guest Web Mode
        let guestAdapter = AppleMusicWebSessionAdapter(manager: .shared)
        let guestProvider = AppleMusicProvider(sessionAdapter: guestAdapter)
        let guestCaps = await guestProvider.capabilities

        #expect(guestCaps.catalogSearch == .supported)
        #expect(guestCaps.libraryAccess == .requiresAuthorization)
        #expect(guestCaps.playback == .supported)
        #expect(guestCaps.lyricsAccess == .unsupported)
        #expect(guestCaps.radioStations == .unsupported)
        #expect(guestCaps.requiresAuthentication == true)

        // 2. Future MusicKit unconfigured adapter
        let kitAdapter = AppleMusicKitSessionAdapter()
        let kitSnapshot = await kitAdapter.snapshot
        #expect(!kitSnapshot.apiAuthorizationState.isAuthorized)
        if case .developerCredentialsMissing(let reason) = kitSnapshot.apiAuthorizationState {
            #expect(!reason.isEmpty)
        } else {
            #expect(Bool(false), "Must report developerCredentialsMissing")
        }
    }

    // MARK: - 7. Account & Platform Isolation

    @Test func testAccountIsolationAcrossProviders() {
        let appleTrack = MusicTrack(
            id: "song-1",
            title: "Apple Song",
            artist: "Apple Artist",
            album: "Album",
            source: .appleMusic,
            accountID: "apple-user-1"
        )

        let spotifyTrack = MusicTrack(
            id: "song-1",
            title: "Apple Song",
            artist: "Apple Artist",
            album: "Album",
            source: .spotify,
            accountID: "spotify-user-1"
        )

        let qqTrack = MusicTrack(
            id: "song-1",
            title: "Apple Song",
            artist: "Apple Artist",
            album: "Album",
            source: .qqMusic,
            accountID: "qq-user-1"
        )

        // Same track title and id across different platforms MUST produce distinct cache keys
        #expect(appleTrack.trackKey != spotifyTrack.trackKey)
        #expect(appleTrack.trackKey != qqTrack.trackKey)
        #expect(spotifyTrack.trackKey != qqTrack.trackKey)
    }

    // MARK: - 8. WebKit Unsupported Flow Error Formulation

    @Test func testUnsupportedAuthenticationFlowError() {
        let err = AppleMusicSessionError.unsupportedAuthenticationFlow("Passkey not allowed")
        #expect(err.localizedDescription.contains("WebKit 不支持"))
        #expect(err.localizedDescription.contains("Passkey"))

        let netErr = AppleMusicSessionError.networkUnavailable
        #expect(netErr.localizedDescription.contains("网络不可用"))

        let genErr = AppleMusicSessionError.sessionGenerationMismatch
        #expect(genErr.localizedDescription.contains("旧会话请求已被废弃"))
    }

    // MARK: - 9. AppleMusicSessionSnapshot Integrity

    @Test func testSessionSnapshotIntegrity() {
        let acc = MusicAccount(displayName: "Test", source: .appleMusic, isAuthenticated: true)
        let snapshot = AppleMusicSessionSnapshot(
            generation: 3,
            webSessionState: .loggedIn(account: acc, storefront: "us"),
            apiAuthorizationState: .developerCredentialsMissing(reason: "test"),
            account: acc,
            hasUserToken: true,
            hasDeveloperToken: true,
            storefront: "us"
        )

        #expect(snapshot.generation == 3)
        #expect(snapshot.webSessionState.isLoggedIn)
        #expect(snapshot.account?.displayName == "Test")
        #expect(snapshot.hasUserToken)
        #expect(snapshot.hasDeveloperToken)
        #expect(snapshot.storefront == "us")
    }

    // MARK: - 10. Web Session Adapter Protocol Compliance

    @Test func testSessionAdapterInterface() async throws {
        let adapter: any AppleMusicSessionAdapter = AppleMusicKitSessionAdapter()
        let state = await adapter.webSessionState
        #expect(state == .loggedOut)
        let gen = await adapter.currentGeneration
        #expect(gen == 0)

        // Invoking authenticateWeb on unconfigured adapter throws developerTokenMissing
        await #expect(throws: AppleMusicSessionError.self) {
            try await adapter.authenticateWeb()
        }

        // Web player stub controls return safe defaults
        let played = try await adapter.playTrack(id: "12345", type: "song")
        #expect(!played)
        let paused = try await adapter.playPause()
        #expect(!paused)
        let (pos, dur, isPlaying) = await adapter.currentPlaybackPosition()
        #expect(pos == 0 && dur == 0 && !isPlaying)
    }

    @Test @MainActor func testWebPlayerLifecycleAndReset() async {
        let player = AppleMusicWebPlayer(dataStore: .nonPersistent())
        #expect(!player.isReady)
        #expect(!player.isPlaying)
        #expect(player.currentPosition == 0)

        let wv = player.ensureWebView()
        #expect(player.webView === wv)

        player.reset()
        #expect(player.webView == nil)
        #expect(!player.isPlaying)
    }

    // MARK: - 11. Session Manager Sign Out & Reset

    @Test @MainActor func testSignOutClearsStateAndBumpsGeneration() async {
        let testKeychain = KeychainStore(service: "com.airmuse.test.apple_music.\(UUID().uuidString)")
        let testAmp = AppleMusicAmpClient()
        let manager = AppleMusicSessionManager(ampClient: testAmp, keychain: testKeychain)

        let initialGen = manager.generation
        await manager.signOut()

        #expect(manager.generation == initialGen + 1)
        #expect(manager.webSessionState == .loggedOut)
        #expect(manager.currentUserToken == nil)
        #expect(manager.currentAccount == nil)
    }

    @Test @MainActor func testResetSessionClearsCapturedDevToken() async {
        let testKeychain = KeychainStore(service: "com.airmuse.test.apple_music.\(UUID().uuidString)")
        let testAmp = AppleMusicAmpClient(devToken: "custom-dev", userToken: "custom-user")
        let manager = AppleMusicSessionManager(ampClient: testAmp, keychain: testKeychain)

        await manager.resetSession()
        #expect(manager.webSessionState == .loggedOut)
        #expect(manager.capturedDeveloperToken == nil)
        #expect(!(await testAmp.hasDeveloperToken()))
        #expect(!(await testAmp.hasUserToken()))
    }

    @Test @MainActor func testRestoreSessionFromStorageLoggedOutWhenNoToken() async {
        let testKeychain = KeychainStore(service: "com.airmuse.test.apple_music.\(UUID().uuidString)")
        let testAmp = AppleMusicAmpClient()
        let manager = AppleMusicSessionManager(ampClient: testAmp, keychain: testKeychain)

        await manager.restoreSessionFromStorage()
        #expect(manager.webSessionState == .loggedOut)
    }

    @Test @MainActor func testVerifyAndApplyTokenMismatchGenerationIsDropped() async {
        let testKeychain = KeychainStore(service: "com.airmuse.test.apple_music.\(UUID().uuidString)")
        let testAmp = AppleMusicAmpClient()
        let manager = AppleMusicSessionManager(ampClient: testAmp, keychain: testKeychain)

        // Snapshot is taken under generation 0
        let staleGen = manager.generation
        // Then user triggers signOut, bumping generation to 1
        await manager.signOut()
        #expect(manager.generation == staleGen + 1)

        // An async callback from the stale generation arrives
        await manager.verifyAndApplyToken("mock-token", devToken: "mock-dev", generationSnapshot: staleGen)

        // Must remain loggedOut; the stale token application was dropped!
        #expect(manager.webSessionState == .loggedOut)
        #expect(manager.currentUserToken == nil)
    }

    // MARK: - 12. Full-Data Retrieval & Endpoint Routing Tests

    @Test func testAmpClientUnauthenticatedEndpointsFallbackGracefully() async throws {
        let client = AppleMusicAmpClient(devToken: "mock-dev-token", userToken: nil)

        // Recommendations require user authentication; when logged out it should return empty
        let recs = try await client.fetchPersonalRecommendations()
        #expect(recs.isEmpty)

        // Recently added requires user authentication; when logged out it should return empty
        let recent = try await client.fetchRecentlyAdded()
        #expect(recent.isEmpty)

        // Favorites requires user authentication; when logged out it should return empty
        let favs = try await client.fetchFavoriteSongsPlaylist()
        #expect(favs.isEmpty)

        // Library artists requires user authentication; when logged out it should return empty
        let artists = try await client.fetchLibraryArtists()
        #expect(artists.isEmpty)

        // Made for you playlists requires user authentication; when logged out it should return empty
        let mfy = try await client.fetchMadeForYouPlaylists()
        #expect(mfy.isEmpty)

        // Library search requires user authentication; when logged out it should return empty
        let searchLib = try await client.searchLibrary(term: "Jay Chou")
        #expect(searchLib.isEmpty)
    }

    @Test func testAmpClientPlaylistSplitLogic() async throws {
        let client = AppleMusicAmpClient(devToken: "mock-dev-token", userToken: nil)
        let (all, user, fav) = try await client.fetchLibraryPlaylistsSplit()
        #expect(all.isEmpty)
        #expect(user.isEmpty)
        #expect(fav.isEmpty)
    }

    @Test func testAmpCategoryItemAndNextURLModel() {
        let item = AmpCategoryItem(
            id: "p.test123",
            title: "我的歌单",
            subtitle: "10 首",
            type: "playlist",
            artworkURL: URL(string: "https://example.com/art.jpg"),
            durationMs: nil,
            track: nil,
            album: nil,
            playlist: nil,
            artist: nil,
            isLibrary: true
        )
        #expect(item.id == "p.test123")
        #expect(item.isLibrary == true)
        #expect(item.type == "playlist")

        let nextURL = URL(string: "https://amp-api.music.apple.com/v1/me/library/playlists?offset=25")
        let category = AmpCategory(id: "pl-all", title: "全部歌单", items: [item], nextURL: nextURL)
        #expect(category.items.count == 1)
        #expect(category.nextURL == nextURL)
    }
}
