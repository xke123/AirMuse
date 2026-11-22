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
    private var lyricsWindow: LyricsWindow?
    private var libraryWindowController: LibraryWindowController?
    private var logWindowController: LogWindowController?
    private var appleMusicAuthWindowController: AppleMusicAuthWindowController?
    private let dockManager = DockManager()

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

        // Attach Web Player to active Player Window content view for keep-alive without preloading before auth barrier
        if let contentView = playerCtrl.window?.contentView {
            AppleMusicSessionManager.shared.webPlayer.attach(to: contentView, preloadImmediately: false)
        }

        let lyricsFrame = NSRect(
            x: playerCtrl.window?.frame.minX ?? 200,
            y: (playerCtrl.window?.frame.minY ?? 500) - DesignTokens.Metrics.lyricsWindowHeight,
            width: DesignTokens.Metrics.lyricsWindowWidth,
            height: DesignTokens.Metrics.lyricsWindowHeight
        )
        let lyricsWnd = LyricsWindow(frame: lyricsFrame)

        // Automatically advance queue when track ends in WebKit Player or AVPlayer
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

        // Wire lyrics offset adjust
        lyricsWnd.lyricsView.onAdjustOffset = { [weak lyrics, weak store] delta in
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
        self.lyricsWindow = lyricsWnd
        self.logWindowController = logCtrl
        self.appleMusicAuthWindowController = authCtrl

        // Window toggles
        playerCtrl.onToggleLyrics = { [weak self] in
            guard let self, let wnd = self.lyricsWindow else { return }
            if wnd.isVisible {
                wnd.orderOut(nil)
            } else {
                wnd.makeKeyAndOrderFront(nil)
                self.dockManager.syncAllDocked()
            }
        }

        playerCtrl.onToggleLibrary = { [weak self] in
            guard let self, let wnd = self.libraryWindowController?.window else { return }
            if wnd.isVisible {
                wnd.orderOut(nil)
            } else {
                wnd.makeKeyAndOrderFront(nil)
                self.dockManager.syncAllDocked()
            }
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

        // Attach to DockManager
        if let mainWnd = playerCtrl.window {
            dockManager.attachWindows(main: mainWnd, lyrics: lyricsWnd, library: libCtrl.window)
            mainWnd.makeKeyAndOrderFront(nil)
            lyricsWnd.makeKeyAndOrderFront(nil)   // show lyrics on launch
            libCtrl.window?.makeKeyAndOrderFront(nil)  // show library on launch
        }

        // Connect Lyrics stream to LyricsWindow
        Task { [weak lyricsWnd] in
            let stream = await store.lyricsStream()
            for await doc in stream {
                guard !Task.isCancelled else { break }
                await MainActor.run {
                    lyricsWnd?.lyricsView.updateLyrics(doc)
                }
            }
        }

        // High-frequency smooth position synchronization for synced lyrics
        Task { [weak lyricsWnd, weak store] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
                guard let lyricsWnd, let store else { break }
                let state = await store.state
                if state.isPlaying || state.estimatedPositionMs > 0 {
                    let est = state.estimatedPositionMs
                    await MainActor.run {
                        lyricsWnd.lyricsView.updatePlaybackPosition(ms: est)
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
