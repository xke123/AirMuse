import AppKit
import MediaPlayer
import Domain
import Playback
import PlatformRuntime
import Application
import Lyrics
import Providers
import DesignSystem
import UI
import AppleMusicIntegrationUI
import Infrastructure

// MARK: - AppLifecycleCoordinator

/// Centralized Core V2 application lifecycle orchestrator for AirMuse macOS.
/// - Stage 0 (0ms): Builds UI controllers from CompositionRoot and presents the interactive stage immediately
///   without blocking on network, full cache reads, WebKit readiness, or a forced 2-second splash delay.
/// - Stage 1 (Parallel Warmup): Off-MainActor skin pre-decoding, SessionCoordinator restore + WebRuntime attach,
///   core service activation, MPRemoteCommandCenter, and Lyrics/NowPlaying observers.
/// - Stage 2 (Shutdown): Cancels tasks, removes observers, clears remote commands, closes DBs, and isolates WebEngine.
@MainActor
public final class AppLifecycleCoordinator {

    private let root: CompositionRoot
    private var store: PlaybackStore { root.playbackStore }
    private var coordinator: PlaybackCoordinatorV2 { root.playbackCoordinatorV2 }
    private var sessionCoordinator: SessionCoordinator { root.sessionCoordinator }
    private var lyricsRepository: LyricsRepositoryV2 { root.lyricsRepository }
    private var appleMusicProvider: AppleMusicProvider { root.appleMusicProvider }

    // UI Controllers
    private var playerWindowController: PlayerWindowController?
    private var libraryWindowController: LibraryWindowController?
    private var lyricsModuleView: LyricsModuleView?
    private var stageController: UnifiedStageController?
    private var logWindowController: LogWindowController?
    private var appleMusicAuthWindowController: AppleMusicAuthWindowController?

    // Tasks & Observers
    private var launchSequenceTask: Task<Void, Never>?
    private var sessionRestoreTask: Task<Void, Never>?
    private var sessionSyncTask: Task<Void, Never>?
    private var lyricsStreamTask: Task<Void, Never>?
    private var lyricsSyncTask: Task<Void, Never>?
    private var nowPlayingSyncTask: Task<Void, Never>?
    private var remoteCommandTargets: [Any] = []
    private var authObserverToken: NSObjectProtocol?

    public init(root: CompositionRoot = CompositionRoot()) {
        self.root = root
    }

    // MARK: - Launch

    public func launch() {
        let launchT0 = ProcessInfo.processInfo.systemUptime
        let startupInterval = AppSignpost.shared.beginInterval("StartupToInteractive")
        AppLogger.shared.log(
            category: .lifecycle,
            level: .info,
            message: "[启动计时 +0ms] AirMuse Core V2 启动中（渐进式无阻塞调度）...",
            details: "Bundle: \(Bundle.main.bundlePath)"
        )

        // Build UI controllers & present native stage immediately (0ms interactive)
        let playerCtrl = PlayerWindowController(coordinator: coordinator, store: store)
        let libCtrl = LibraryWindowController(
            coordinator: coordinator,
            registry: root.providerRegistry
        )
        let logCtrl = LogWindowController(
            diagnosticFetch: { [provider = self.appleMusicProvider] in
                try await provider.fetchTopCharts()
            },
            diagnosticsProvider: { [root = self.root] in
                let sessSnap = await root.sessionCoordinator.snapshot
                let pbState = await root.playbackStore.state
                let cacheBytes = (try? await root.sqlCacheStore.totalCachedBytes()) ?? 0
                let imgBytes = await root.imageCache.diskUsageBytes()
                let (engineID, isReady, isAuth) = await MainActor.run {
                    (root.webRuntime.engineInstanceID, root.webRuntime.isReady, root.webRuntime.isAuthorized)
                }
                return """
                Session: state=\(sessSnap.sessionState) | gen=\(sessSnap.context?.generation ?? 0) | storefront=\(sessSnap.context?.storefront ?? "nil") | account=\(sessSnap.account?.displayName ?? "nil")
                WebEngine: id=\(engineID.uuidString.prefix(8)) | ready=\(isReady) | authorized=\(isAuth)
                Playback: status=\(pbState.status) | track=\(pbState.currentTrack?.title ?? "none") | posMs=\(pbState.estimatedPositionMs)
                Cache: sqlBytes=\(cacheBytes) | imageDiskBytes=\(imgBytes) | logFile=\(AppLogger.shared.activeLogFileURL.lastPathComponent)
                """
            }
        )
        let authCtrl = AppleMusicAuthWindowController(
            sessionCoordinator: sessionCoordinator,
            webLoginController: root.webLoginController
        )
        let lyricsView = LyricsModuleView(frame: .zero)
        let stage = UnifiedStageController(playerCtrl: playerCtrl, lyricsView: lyricsView, libraryCtrl: libCtrl)

        self.playerWindowController = playerCtrl
        self.libraryWindowController = libCtrl
        self.lyricsModuleView = lyricsView
        self.stageController = stage
        self.logWindowController = logCtrl
        self.appleMusicAuthWindowController = authCtrl

        wireCallbacks(
            playerCtrl: playerCtrl,
            libCtrl: libCtrl,
            lyricsView: lyricsView,
            stage: stage,
            logCtrl: logCtrl,
            authCtrl: authCtrl
        )

        // Show main interactive stage immediately without a blocking 2-second splash
        stage.showAndFocus()
        stage.playLaunchIntroIfNeeded()
        AppSignpost.shared.endInterval("StartupToInteractive", startupInterval)
        AppLogger.shared.log(
            category: .lifecycle,
            level: .info,
            message: "[启动计时 +\(Int((ProcessInfo.processInfo.systemUptime - launchT0) * 1000))ms] 主界面已可交互"
        )

        // Attach WebKit keep-alive view without blocking main UI
        root.webRuntime.attach(to: playerCtrl.playerSlotView)

        // Parallel background warmup: skin decoding (off-MainActor), session restore, core services
        sessionRestoreTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let sp = AppSignpost.shared.beginInterval("SessionRestore")
            await self.sessionCoordinator.restoreFromStorage()
            AppSignpost.shared.endInterval("SessionRestore", sp)
        }

        launchSequenceTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let skinTask = Task.detached(priority: .userInitiated) {
                await MainActor.run {
                    SkinAssetLoader.shared.preloadCoreAssets(resolution: .retina4x)
                }
            }
            self.setupRemoteCommandCenter()
            self.startSessionSyncObserver()
            self.startLyricsAndNowPlayingObservers(lyricsView: lyricsView)
            await self.initializeCoreServices(launchT0: launchT0)
            await skinTask.value
        }
    }

    /// Restores the single main stage window without reviving auxiliary windows or resetting playback/modes.
    public func restoreStage() {
        NSApp.activate(ignoringOtherApps: true)
        stageController?.showAndFocus()
    }

    // MARK: - Shutdown

    public func shutdown() {
        launchSequenceTask?.cancel()
        sessionRestoreTask?.cancel()
        sessionSyncTask?.cancel()
        lyricsStreamTask?.cancel()
        lyricsSyncTask?.cancel()
        nowPlayingSyncTask?.cancel()

        if let token = authObserverToken {
            NotificationCenter.default.removeObserver(token)
            authObserverToken = nil
        }
        teardownRemoteCommandCenter()

        let coord = coordinator
        let engine = root.webEngine
        let cacheStore = root.sqlCacheStore
        let lyricsRepo = lyricsRepository
        Task {
            await coord.shutdown()
            await engine.isolateAndReset()
            await cacheStore.close()
            await lyricsRepo.close()
        }
        AppLogger.shared.log(category: .lifecycle, level: .info, message: "AirMuse macOS Core V2 生命周期已收口退出")
    }

    // MARK: - Private Setup

    private func initializeCoreServices(launchT0: TimeInterval) async {
        let sp = AppSignpost.shared.beginInterval("CoreServicesInit")
        try? await root.sqlCacheStore.open()
        try? await lyricsRepository.open()
        await lyricsRepository.register(provider: appleMusicProvider)
        await coordinator.start(session: await sessionCoordinator.snapshot.context)
        AppSignpost.shared.endInterval("CoreServicesInit", sp)
        let now = ProcessInfo.processInfo.systemUptime
        AppLogger.shared.log(
            category: .lifecycle,
            level: .info,
            message: "[启动计时 +\(Int((now - launchT0) * 1000))ms] Core V2 服务初始化就绪"
        )
    }

    private func startSessionSyncObserver() {
        sessionSyncTask = Task { [weak self] in
            guard let self else { return }
            if !(await AppleMusicAmpClient.shared.hasDeveloperToken()),
               let clientRec = try? await self.root.credentialVault.load(providerID: "apple_music", accountID: nil, kind: .client) {
                await AppleMusicAmpClient.shared.setDeveloperToken(clientRec.value)
            }
            let stream = await self.sessionCoordinator.snapshots()
            for await snap in stream {
                guard !Task.isCancelled else { break }
                if snap.clientCredentialState == .available,
                   !(await AppleMusicAmpClient.shared.hasDeveloperToken()),
                   let clientRec = try? await self.root.credentialVault.load(providerID: "apple_music", accountID: nil, kind: .client) {
                    await AppleMusicAmpClient.shared.setDeveloperToken(clientRec.value)
                }
                await self.coordinator.updateSession(snap.context)
                await self.root.providerRegistry.publishSessionSnapshot(snap, for: .appleMusic)
                if let ctx = snap.context {
                    await AppleMusicAmpClient.shared.setStorefront(ctx.storefront)
                    await AppleMusicAmpClient.shared.setActiveGeneration(Int(ctx.generation))
                    if let rec = try? await self.root.credentialVault.load(providerID: ctx.providerID, accountID: ctx.accountID, kind: .user) {
                        await AppleMusicAmpClient.shared.setUserToken(rec.value)
                    }
                    if snap.sessionState == .authenticated {
                        await self.coordinator.restoreSnapshotIfNeeded(providerID: ctx.providerID, accountID: ctx.accountID)
                        try? await self.root.engineRouter.prepare(sessionContext: ctx, deadlineSeconds: 12.0)
                    }
                } else {
                    await AppleMusicAmpClient.shared.setUserToken(nil)
                }
            }
        }
    }

    private func wireCallbacks(
        playerCtrl: PlayerWindowController,
        libCtrl: LibraryWindowController,
        lyricsView: LyricsModuleView,
        stage: UnifiedStageController,
        logCtrl: LogWindowController,
        authCtrl: AppleMusicAuthWindowController
    ) {
        authObserverToken = NotificationCenter.default.addObserver(
            forName: .appleMusicRequiresAuthentication,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let auth = self.appleMusicAuthWindowController else { return }
                if auth.window?.isVisible != true {
                    auth.showAuthWindow()
                }
            }
        }

        lyricsView.lyricsView.onAdjustOffset = { [weak lyrics = self.lyricsRepository, weak store = self.store] delta in
            Task {
                guard let lyrics, let store else { return }
                let state = await store.state
                if let key = state.currentTrack?.trackKey {
                    await lyrics.adjustOffset(trackKey: key, deltaMs: delta)
                }
            }
        }

        playerCtrl.onToggleLyrics = { [weak stage] in
            stage?.toggleLyrics()
        }
        playerCtrl.onToggleLibrary = { [weak stage] in
            stage?.toggleLibrary()
        }
        playerCtrl.onToggleFavorite = { [weak libCtrl, weak store = self.store] in
            Task { @MainActor in
                guard let libCtrl, let store else { return }
                let state = await store.state
                if let track = state.currentTrack {
                    libCtrl.toggleFavoriteForTrack(track)
                }
            }
        }
        libCtrl.onObservedResourceStateChanged = { [weak playerCtrl, weak store = self.store] normalizedKey, resState in
            Task { @MainActor in
                guard let playerCtrl, let store else { return }
                let pbState = await store.state
                guard let track = pbState.currentTrack else { return }
                let ref = MediaResourceReference.from(track: track)
                if ref.normalizedKey == normalizedKey {
                    playerCtrl.updateFavoriteState(
                        isFavorited: resState.favorite.confirmedBool,
                        isPending: resState.favorite.isPending,
                        isEnabled: true
                    )
                }
            }
        }
        playerCtrl.onToggleLog = { [weak logCtrl] in
            guard let wnd = logCtrl?.window else { return }
            if wnd.isVisible {
                wnd.orderOut(nil)
            } else {
                wnd.makeKeyAndOrderFront(nil)
            }
        }
        libCtrl.onToggleLog = { [weak logCtrl] in
            guard let wnd = logCtrl?.window else { return }
            if wnd.isVisible {
                wnd.orderOut(nil)
            } else {
                wnd.makeKeyAndOrderFront(nil)
            }
        }
        libCtrl.onToggleAccount = { [weak authCtrl] in
            guard let authCtrl else { return }
            if authCtrl.window?.isVisible == true {
                authCtrl.window?.orderOut(nil)
            } else {
                authCtrl.showAuthWindow()
            }
        }
    }

    private func startLyricsAndNowPlayingObservers(lyricsView: LyricsModuleView) {
        lyricsStreamTask = Task { [weak lyricsView, weak store = self.store] in
            guard let store else { return }
            let stream = await store.lyricsStream()
            for await doc in stream {
                guard !Task.isCancelled else { break }
                await MainActor.run {
                    lyricsView?.lyricsView.updateLyrics(doc)
                }
            }
        }

        lyricsSyncTask = Task { [weak lyricsView, weak store = self.store] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
                guard let lyricsView, let store else { break }
                let state = await store.state
                if state.isPlaying || state.estimatedPositionMs > 0 {
                    let est = state.estimatedPositionMs
                    await MainActor.run {
                        lyricsView.lyricsView.updatePlaybackPosition(ms: est)
                    }
                }
            }
        }

        nowPlayingSyncTask = Task { [weak store = self.store, weak lyrics = self.lyricsRepository, weak playerCtrl = self.playerWindowController, weak libCtrl = self.libraryWindowController] in
            guard let store else { return }
            var lastTrackKey: String?
            let stream = await store.playbackStream()
            for await state in stream {
                guard !Task.isCancelled else { break }
                if let track = state.currentTrack, track.trackKey != lastTrackKey {
                    lastTrackKey = track.trackKey
                    if let lyrics {
                        Task { await lyrics.requestLyrics(for: track) }
                    }
                    await MainActor.run {
                        if let libCtrl, let playerCtrl {
                            let status = libCtrl.currentFavoriteStatus(for: track)
                            playerCtrl.updateFavoriteState(
                                isFavorited: status.isFavorited,
                                isPending: status.isPending,
                                isEnabled: status.isEnabled
                            )
                        }
                    }
                } else if state.currentTrack == nil {
                    lastTrackKey = nil
                    await MainActor.run {
                        playerCtrl?.updateFavoriteState(isFavorited: nil, isPending: false, isEnabled: false)
                    }
                }
                await MainActor.run {
                    Self.updateNowPlayingInfo(state)
                }
            }
        }
    }

    // MARK: - macOS MPRemoteCommandCenter & MPNowPlayingInfoCenter

    private func setupRemoteCommandCenter() {
        let center = MPRemoteCommandCenter.shared()
        let coord = coordinator

        let playTarget = center.playCommand.addTarget { _ in
            Task { try? await coord.play() }
            return .success
        }
        let pauseTarget = center.pauseCommand.addTarget { _ in
            Task { try? await coord.pause() }
            return .success
        }
        let toggleTarget = center.togglePlayPauseCommand.addTarget { _ in
            Task { try? await coord.playPause() }
            return .success
        }
        let nextTarget = center.nextTrackCommand.addTarget { _ in
            Task { try? await coord.skipToNext() }
            return .success
        }
        let prevTarget = center.previousTrackCommand.addTarget { _ in
            Task { try? await coord.skipToPrevious() }
            return .success
        }
        let seekTarget = center.changePlaybackPositionCommand.addTarget { event in
            guard let posEvent = event as? MPChangePlaybackPositionCommandEvent else {
                return .commandFailed
            }
            let ms = Int64(posEvent.positionTime * 1000.0)
            Task { try? await coord.seek(toMs: ms) }
            return .success
        }

        remoteCommandTargets = [playTarget, pauseTarget, toggleTarget, nextTarget, prevTarget, seekTarget]
    }

    private func teardownRemoteCommandCenter() {
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.removeTarget(nil)
        center.pauseCommand.removeTarget(nil)
        center.togglePlayPauseCommand.removeTarget(nil)
        center.nextTrackCommand.removeTarget(nil)
        center.previousTrackCommand.removeTarget(nil)
        center.changePlaybackPositionCommand.removeTarget(nil)
        remoteCommandTargets.removeAll()
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }

    private static func updateNowPlayingInfo(_ state: PlaybackState) {
        let infoCenter = MPNowPlayingInfoCenter.default()
        guard let track = state.currentTrack else {
            infoCenter.nowPlayingInfo = nil
            infoCenter.playbackState = .stopped
            return
        }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: track.title,
            MPMediaItemPropertyArtist: track.artistName,
            MPMediaItemPropertyAlbumTitle: track.albumTitle,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: Double(state.estimatedPositionMs) / 1000.0,
            MPNowPlayingInfoPropertyPlaybackRate: state.isPlaying ? 1.0 : 0.0
        ]
        if state.durationMs > 0 {
            info[MPMediaItemPropertyPlaybackDuration] = Double(state.durationMs) / 1000.0
        }
        infoCenter.nowPlayingInfo = info
        infoCenter.playbackState = state.isPlaying ? .playing : .paused
    }
}
