import AppKit
import MediaPlayer
import Domain
import Playback
import Lyrics
import Providers
import DesignSystem
import UI
import Infrastructure

// MARK: - AppLifecycleCoordinator

/// Centralized application lifecycle orchestrator for AirMuse macOS.
/// - Stage 0 (0ms): Shows the 2-second Liquid Glass logo splash and constructs core services & UI controllers.
/// - Stage 1 (0 ~ 2.0s): Runs background warm-up tasks in parallel (skin assets, session restore, WebKit preload,
///   library cache/first-screen, LyricsEngine, and macOS MPRemoteCommandCenter).
/// - Stage 2 (2.0s): Dismisses splash and presents the ready unified stage window (without blocking on slow network calls).
/// - Stage 3 (Shutdown): Cancels background tasks, clears remote commands, and shuts down playback.
@MainActor
public final class AppLifecycleCoordinator {

    private let splashDurationSeconds: Double = 2.0

    // Core services
    private let store = PlaybackStore()
    private lazy var coordinator = PlaybackCoordinator(store: store)
    private lazy var lyricsEngine = LyricsEngine(store: store)
    private let appleMusicProvider = AppleMusicProvider()

    // UI Controllers
    private var splashWindow: LaunchSplashWindow?
    private var playerWindowController: PlayerWindowController?
    private var libraryWindowController: LibraryWindowController?
    private var lyricsModuleView: LyricsModuleView?
    private var stageController: UnifiedStageController?
    private var logWindowController: LogWindowController?
    private var appleMusicAuthWindowController: AppleMusicAuthWindowController?

    // Tasks
    private var launchSequenceTask: Task<Void, Never>?
    private var sessionRestoreTask: Task<Void, Never>?
    private var lyricsStreamTask: Task<Void, Never>?
    private var lyricsSyncTask: Task<Void, Never>?
    private var nowPlayingSyncTask: Task<Void, Never>?
    private var remoteCommandTargets: [Any] = []

    public init() {}

    // MARK: - Launch

    public func launch() {
        let launchT0 = ProcessInfo.processInfo.systemUptime
        AppLogger.shared.log(
            category: .lifecycle,
            level: .info,
            message: "[启动计时 +0ms] AirMuse macOS 启动中（2 秒 Logo 预热调度）...",
            details: "Bundle: \(Bundle.main.bundlePath)"
        )

        // Stage 0: Immediately show 2-second Logo splash
        let splash = LaunchSplashWindow()
        self.splashWindow = splash
        splash.present()
        AppLogger.shared.log(
            category: .lifecycle,
            level: .info,
            message: "[启动计时 +\(Int((ProcessInfo.processInfo.systemUptime - launchT0) * 1000))ms] Logo 悬浮窗已展示"
        )

        // Build UI controllers & attach WebKit keep-alive view while splash is visible
        let playerCtrl = PlayerWindowController(coordinator: coordinator, store: store)
        let libCtrl = LibraryWindowController(coordinator: coordinator, appleMusicProvider: appleMusicProvider)
        let logCtrl = LogWindowController(appleMusicProvider: appleMusicProvider)
        let authCtrl = AppleMusicAuthWindowController(sessionManager: .shared)
        let lyricsView = LyricsModuleView(frame: .zero)
        let stage = UnifiedStageController(playerCtrl: playerCtrl, lyricsView: lyricsView, libraryCtrl: libCtrl)

        self.playerWindowController = playerCtrl
        self.libraryWindowController = libCtrl
        self.lyricsModuleView = lyricsView
        self.stageController = stage
        self.logWindowController = logCtrl
        self.appleMusicAuthWindowController = authCtrl

        AppLogger.shared.log(
            category: .lifecycle,
            level: .info,
            message: "[启动计时 +\(Int((ProcessInfo.processInfo.systemUptime - launchT0) * 1000))ms] UI 控制器与统一舞台构建完成"
        )

        // Attach WebKit player immediately so it stays alive in the window hierarchy
        AppleMusicSessionManager.shared.webPlayer.attach(to: playerCtrl.playerSlotView, preloadImmediately: false)

        wireCallbacks(
            playerCtrl: playerCtrl,
            libCtrl: libCtrl,
            lyricsView: lyricsView,
            stage: stage,
            logCtrl: logCtrl,
            authCtrl: authCtrl
        )

        // Run session restore + WebPlayer preload independently so slow network never stalls the 2s splash
        sessionRestoreTask = Task { @MainActor in
            let tStart = ProcessInfo.processInfo.systemUptime
            AppLogger.shared.log(
                category: .lifecycle,
                level: .info,
                message: "[启动计时 +\(Int((tStart - launchT0) * 1000))ms] 开始后台会话恢复与 WebPlayer 预加载"
            )
            await AppleMusicSessionManager.shared.restoreSessionFromStorage()
            let tEnd = ProcessInfo.processInfo.systemUptime
            AppLogger.shared.log(
                category: .lifecycle,
                level: .info,
                message: "[启动计时 +\(Int((tEnd - launchT0) * 1000))ms] 会话恢复流程完成（自身耗时 \(Int((tEnd - tStart) * 1000))ms）"
            )
        }

        // Stage 1: Parallel local/core warm-up during the 2.0s splash window
        launchSequenceTask = Task { @MainActor [weak self] in
            guard let self else { return }

            let tAssetsStart = ProcessInfo.processInfo.systemUptime
            SkinAssetLoader.shared.preloadCoreAssets(resolution: .retina4x)
            let tAssetsEnd = ProcessInfo.processInfo.systemUptime
            AppLogger.shared.log(
                category: .lifecycle,
                level: .info,
                message: "[启动计时 +\(Int((tAssetsEnd - launchT0) * 1000))ms] 皮肤资源预解码完成（耗时 \(Int((tAssetsEnd - tAssetsStart) * 1000))ms）"
            )

            self.setupRemoteCommandCenter()
            self.startLyricsAndNowPlayingObservers(lyricsView: lyricsView)
            AppLogger.shared.log(
                category: .lifecycle,
                level: .info,
                message: "[启动计时 +\(Int((ProcessInfo.processInfo.systemUptime - launchT0) * 1000))ms] MPRemoteCommandCenter 与歌词/状态监听已就绪"
            )

            async let coreInit: Void = self.initializeCoreServices(launchT0: launchT0)
            let alreadyElapsed = ProcessInfo.processInfo.systemUptime - launchT0
            let remaining = max(0.0, self.splashDurationSeconds - alreadyElapsed)
            if remaining > 0 {
                try? await Task.sleep(for: .seconds(remaining))
            }
            await coreInit

            let elapsed = ProcessInfo.processInfo.systemUptime - launchT0
            AppLogger.shared.log(
                category: .lifecycle,
                level: .info,
                message: "[启动计时 +\(Int(elapsed * 1000))ms] 2 秒 Logo 展示结束，准备淡出并展示主界面"
            )

            guard !Task.isCancelled else { return }
            self.splashWindow?.updateStatus("所有组件已就绪")
            self.splashWindow?.dismiss { [weak self] in
                guard let self else { return }
                self.splashWindow = nil
                self.stageController?.showAndFocus()
                let tShown = ProcessInfo.processInfo.systemUptime - launchT0
                AppLogger.shared.log(
                    category: .lifecycle,
                    level: .info,
                    message: "[启动计时 +\(Int(tShown * 1000))ms] 主界面已展示"
                )
            }
        }
    }

    // MARK: - Shutdown

    public func shutdown() {
        launchSequenceTask?.cancel()
        sessionRestoreTask?.cancel()
        lyricsStreamTask?.cancel()
        lyricsSyncTask?.cancel()
        nowPlayingSyncTask?.cancel()
        teardownRemoteCommandCenter()

        let coord = coordinator
        Task {
            await coord.shutdown()
        }
        AppLogger.shared.log(category: .lifecycle, level: .info, message: "AirMuse macOS 生命周期已收口退出")
    }

    // MARK: - Private Setup

    private func initializeCoreServices(launchT0: TimeInterval) async {
        let t0 = ProcessInfo.processInfo.systemUptime
        await coordinator.register(provider: appleMusicProvider)
        try? await coordinator.activate(providerID: "apple_music")
        await coordinator.start()
        await lyricsEngine.register(provider: appleMusicProvider)
        await lyricsEngine.startObserving()
        let now = ProcessInfo.processInfo.systemUptime
        AppLogger.shared.log(
            category: .lifecycle,
            level: .info,
            message: "[启动计时 +\(Int((now - launchT0) * 1000))ms] PlaybackCoordinator 与 LyricsEngine 就绪（自身耗时 \(Int((now - t0) * 1000))ms）"
        )
    }

    private func wireCallbacks(
        playerCtrl: PlayerWindowController,
        libCtrl: LibraryWindowController,
        lyricsView: LyricsModuleView,
        stage: UnifiedStageController,
        logCtrl: LogWindowController,
        authCtrl: AppleMusicAuthWindowController
    ) {
        let advanceAction: @Sendable () -> Void = { [weak coordinator = self.coordinator] in
            Task {
                AppLogger.shared.log(category: .playback, level: .info, message: "Apple Music 曲目播放完毕，自动切播下一首")
                try? await coordinator?.skipToNext()
            }
        }
        AppleMusicSessionManager.shared.webPlayer.onPlaybackEnded = advanceAction
        Task {
            await appleMusicProvider.setOnPlaybackEnded(advanceAction)
        }

        NotificationCenter.default.addObserver(
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

        lyricsView.lyricsView.onAdjustOffset = { [weak lyrics = self.lyricsEngine, weak store = self.store] delta in
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

        nowPlayingSyncTask = Task { [weak store = self.store] in
            guard let store else { return }
            let stream = await store.playbackStream()
            for await state in stream {
                guard !Task.isCancelled else { break }
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
