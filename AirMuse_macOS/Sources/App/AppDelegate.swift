import AppKit
import Domain
import Playback
import Lyrics
import Providers
import DesignSystem
import UI
import Infrastructure

/// Root application delegate for AirMuse macOS.
/// Boots the Liquid Glass floating player, docked lyrics, and native library browser.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    private var playbackCoordinator: PlaybackCoordinator?
    private var playbackStore: PlaybackStore?
    private var lyricsEngine: LyricsEngine?
    private var playerWindowController: PlayerWindowController?
    private var lyricsModuleView: LyricsModuleView?
    private var libraryWindowController: LibraryWindowController?
    private var logWindowController: LogWindowController?
    private var appleMusicAuthWindowController: AppleMusicAuthWindowController?
    private var stageController: UnifiedStageController?

    private var appleMusicProvider: AppleMusicProvider?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        AppLogger.shared.log(
            category: .lifecycle,
            level: .info,
            message: "AirMuse macOS 应用程序启动中...",
            details: "Bundle: \(Bundle.main.bundlePath)"
        )

        // Wire core domain services
        let store = PlaybackStore()
        let coordinator = PlaybackCoordinator(store: store)
        let lyrics = LyricsEngine(store: store)
        let appleMusic = AppleMusicProvider()

        self.playbackStore = store
        self.playbackCoordinator = coordinator
        self.lyricsEngine = lyrics
        self.appleMusicProvider = appleMusic

        Task {
            await coordinator.register(provider: appleMusic)
            try? await coordinator.activate(providerID: "apple_music")
            await coordinator.start()
            await lyrics.register(provider: appleMusic)
            await lyrics.startObserving()
            AppLogger.shared.log(category: .lifecycle, level: .info, message: "PlaybackCoordinator 已激活 AppleMusicProvider，LyricsEngine 已启动监听同步歌词")
            // Restore saved Apple Music session from secure storage
            await AppleMusicSessionManager.shared.restoreSessionFromStorage()
        }

        // Initialize UI Controllers
        let playerCtrl = PlayerWindowController(coordinator: coordinator, store: store)
        let libCtrl = LibraryWindowController(coordinator: coordinator, appleMusicProvider: appleMusic)
        let logCtrl = LogWindowController(appleMusicProvider: appleMusic)
        let authCtrl = AppleMusicAuthWindowController(sessionManager: .shared)

        let lyricsView = LyricsModuleView(frame: .zero)
        let stage = UnifiedStageController(playerCtrl: playerCtrl, lyricsView: lyricsView, libraryCtrl: libCtrl)

        // Attach Web Player to player slot view for keep-alive inside player bounds
        AppleMusicSessionManager.shared.webPlayer.attach(to: playerCtrl.playerSlotView, preloadImmediately: false)

        // Automatically advance queue when track ends in WebKit Player
        let advanceAction: @Sendable () -> Void = { [weak coordinator] in
            Task {
                AppLogger.shared.log(category: .playback, level: .info, message: "Apple Music 曲目播放完毕，自动切播下一首")
                try? await coordinator?.skipToNext()
            }
        }
        AppleMusicSessionManager.shared.webPlayer.onPlaybackEnded = advanceAction
        Task {
            await appleMusic.setOnPlaybackEnded(advanceAction)
        }

        // Observe authentication requirement notifications and guide user to log in
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

        // Wire lyrics offset adjust
        lyricsView.lyricsView.onAdjustOffset = { [weak lyrics, weak store] delta in
            Task {
                guard let lyrics, let store else { return }
                let state = await store.state
                if let key = state.currentTrack?.trackKey {
                    await lyrics.adjustOffset(trackKey: key, deltaMs: delta)
                }
            }
        }

        self.playerWindowController = playerCtrl
        self.libraryWindowController = libCtrl
        self.lyricsModuleView = lyricsView
        self.stageController = stage
        self.logWindowController = logCtrl
        self.appleMusicAuthWindowController = authCtrl

        // Module toggles inside UnifiedStageController
        playerCtrl.onToggleLyrics = { [weak self] in
            self?.stageController?.toggleLyrics()
        }

        playerCtrl.onToggleLibrary = { [weak self] in
            self?.stageController?.toggleLibrary()
        }

        playerCtrl.onToggleLog = { [weak self] in
            guard let self, let wnd = self.logWindowController?.window else { return }
            if wnd.isVisible {
                wnd.orderOut(nil)
            } else {
                wnd.makeKeyAndOrderFront(nil)
            }
        }

        libCtrl.onToggleLog = { [weak self] in
            guard let self, let wnd = self.logWindowController?.window else { return }
            if wnd.isVisible {
                wnd.orderOut(nil)
            } else {
                wnd.makeKeyAndOrderFront(nil)
            }
        }

        libCtrl.onToggleAccount = { [weak self] in
            guard let self, let auth = self.appleMusicAuthWindowController else { return }
            if auth.window?.isVisible == true {
                auth.window?.orderOut(nil)
            } else {
                auth.showAuthWindow()
            }
        }

        // Show unified single host window
        stage.showAndFocus()

        // Connect Lyrics stream to LyricsModuleView
        Task { [weak lyricsView] in
            let stream = await store.lyricsStream()
            for await doc in stream {
                guard !Task.isCancelled else { break }
                await MainActor.run {
                    lyricsView?.lyricsView.updateLyrics(doc)
                }
            }
        }

        // High-frequency smooth position synchronization for synced lyrics
        Task { [weak lyricsView, weak store] in
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
    }

    func applicationWillTerminate(_ notification: Notification) {
        Task {
            await playbackCoordinator?.shutdown()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }
}
