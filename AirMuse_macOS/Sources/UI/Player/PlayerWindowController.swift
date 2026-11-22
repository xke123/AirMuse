import AppKit
import Domain
import DesignSystem
import Playback
import Infrastructure

// MARK: - PlayerWindowController

/// Controls independent Main and Mini `PlayerWindow` instances,
/// matching original AIRPLAY's two-window hide/show switching model.
@MainActor
open class PlayerWindowController: NSWindowController {

    public private(set) var isMiniMode: Bool = false
    public private(set) var isTopMost: Bool = true

    public let mainWindow: PlayerWindow
    public let miniWindow: PlayerWindow

    public var activeWindow: PlayerWindow {
        isMiniMode ? miniWindow : mainWindow
    }

    public var onToggleLyrics: (() -> Void)?
    public var onToggleLibrary: (() -> Void)?
    public var onToggleLog: (() -> Void)?
    public var onModeDidTransition: (() -> Void)?

    private let coordinator: PlaybackCoordinator
    private let store: PlaybackStore

    private let playerView = PlayerView()
    private let miniPlayerView = MiniPlayerView()
    private var observationTask: Task<Void, Never>?
    private var progressTask: Task<Void, Never>?
    private var isTransitioning: Bool = false

    private enum Keys {
        static let originX = "airmuse.window.main.x"
        static let originY = "airmuse.window.main.y"
        static let hasOrigin = "airmuse.window.main.hasOrigin"
    }

    public init(coordinator: PlaybackCoordinator, store: PlaybackStore) {
        self.coordinator = coordinator
        self.store = store

        let s = GlassInteractionCoordinator.shared.uiScale
        let mainW = OriginalDesignTokens.BaseMetrics.mainPlayerWidth * s
        let mainH = OriginalDesignTokens.BaseMetrics.mainPlayerHeight * s
        let miniH = OriginalDesignTokens.BaseMetrics.miniBarStandardHeight * s

        var initialX: CGFloat = 200
        var initialY: CGFloat = (NSScreen.main?.visibleFrame.maxY ?? 800) - mainH - 50
        if UserDefaults.standard.bool(forKey: Keys.hasOrigin) {
            initialX = CGFloat(UserDefaults.standard.double(forKey: Keys.originX))
            initialY = CGFloat(UserDefaults.standard.double(forKey: Keys.originY))
        }

        let clampedOrigin = Self.clampOriginToScreens(NSPoint(x: initialX, y: initialY), size: NSSize(width: mainW, height: mainH))
        let mainRect = NSRect(origin: clampedOrigin, size: NSSize(width: mainW, height: mainH))
        let miniRect = NSRect(x: mainRect.minX, y: mainRect.maxY - miniH, width: mainW, height: miniH)

        self.mainWindow = PlayerWindow(contentRect: mainRect)
        self.miniWindow = PlayerWindow(contentRect: miniRect)

        super.init(window: mainWindow)

        setupWindows()
        wireActions()
        startObservingStore()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleScaleOrModeChange),
            name: GlassInteractionCoordinator.modeDidChangeNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowDidMove(_:)),
            name: NSWindow.didMoveNotification,
            object: mainWindow
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowDidMove(_:)),
            name: NSWindow.didMoveNotification,
            object: miniWindow
        )
    }

    public required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        observationTask?.cancel()
        progressTask?.cancel()
    }

    private func setupWindows() {
        mainWindow.onDoubleClicked = { [weak self] in self?.toggleMiniMode() }
        mainWindow.onToggleLog = { [weak self] in self?.onToggleLog?() }
        mainWindow.onToggleTopMost = { [weak self] in self?.toggleTopMost() }

        let mainContainer = NSView(frame: mainWindow.contentView?.bounds ?? .zero)
        mainContainer.wantsLayer = true
        mainWindow.contentView = mainContainer
        playerView.frame = mainContainer.bounds
        playerView.autoresizingMask = [.width, .height]
        mainContainer.addSubview(playerView)

        miniWindow.onDoubleClicked = { [weak self] in self?.toggleMiniMode() }
        miniWindow.onToggleLog = { [weak self] in self?.onToggleLog?() }
        miniWindow.onToggleTopMost = { [weak self] in self?.toggleTopMost() }

        let miniContainer = NSView(frame: miniWindow.contentView?.bounds ?? .zero)
        miniContainer.wantsLayer = true
        miniWindow.contentView = miniContainer
        miniPlayerView.frame = miniContainer.bounds
        miniPlayerView.autoresizingMask = [.width, .height]
        miniContainer.addSubview(miniPlayerView)
        miniWindow.orderOut(nil)
    }

    private func wireActions() {
        playerView.onPlayPause = { [weak self] in
            AppLogger.shared.log(category: .userAction, level: .info, message: "用户点击主界面 [播放/暂停] 按钮")
            self?.executeCommand { try await self?.coordinator.playPause() }
        }
        playerView.onStop = { [weak self] in
            AppLogger.shared.log(category: .userAction, level: .info, message: "用户点击主界面 [停止] 按钮")
            self?.executeCommand { try await self?.coordinator.pause() }
        }
        playerView.onNext = { [weak self] in
            AppLogger.shared.log(category: .userAction, level: .info, message: "用户点击主界面 [下一首] 按钮")
            self?.executeCommand { try await self?.coordinator.skipToNext() }
        }
        playerView.onPrevious = { [weak self] in
            AppLogger.shared.log(category: .userAction, level: .info, message: "用户点击主界面 [上一首] 按钮")
            self?.executeCommand { try await self?.coordinator.skipToPrevious() }
        }
        playerView.onSeek = { [weak self] targetMs in
            let sec = String(format: "%.1f", Double(targetMs) / 1000.0)
            AppLogger.shared.log(category: .userAction, level: .info, message: "用户拖动进度条跳转至: \(sec)s (\(targetMs)ms)")
            self?.executeCommand { try await self?.coordinator.seek(toMs: targetMs) }
        }
        playerView.onVolumeChanged = { [weak self] vol in
            self?.executeCommand { try await self?.coordinator.setVolume(vol) }
        }
        playerView.onToggleMiniMode = { [weak self] in
            AppLogger.shared.log(category: .userAction, level: .info, message: "用户点击切换 [迷你播放器] 独立窗口")
            self?.toggleMiniMode()
        }
        playerView.onToggleTopMost = { [weak self] in
            self?.toggleTopMost()
        }
        playerView.onToggleLyrics = { [weak self] in
            AppLogger.shared.log(category: .userAction, level: .info, message: "用户点击 [歌词面板] 按钮")
            self?.onToggleLyrics?()
        }
        playerView.onToggleLibrary = { [weak self] in
            AppLogger.shared.log(category: .userAction, level: .info, message: "用户点击 [音乐资料库] 按钮")
            self?.onToggleLibrary?()
        }

        miniPlayerView.onPlayPause = { [weak self] in
            AppLogger.shared.log(category: .userAction, level: .info, message: "用户点击迷你栏 [播放/暂停] 按钮")
            self?.executeCommand { try await self?.coordinator.playPause() }
        }
        miniPlayerView.onStop = { [weak self] in
            AppLogger.shared.log(category: .userAction, level: .info, message: "用户点击迷你栏 [停止] 按钮")
            self?.executeCommand { try await self?.coordinator.pause() }
        }
        miniPlayerView.onNext = { [weak self] in
            AppLogger.shared.log(category: .userAction, level: .info, message: "用户点击迷你栏 [下一首] 按钮")
            self?.executeCommand { try await self?.coordinator.skipToNext() }
        }
        miniPlayerView.onPrevious = { [weak self] in
            AppLogger.shared.log(category: .userAction, level: .info, message: "用户点击迷你栏 [上一首] 按钮")
            self?.executeCommand { try await self?.coordinator.skipToPrevious() }
        }
        miniPlayerView.onExpand = { [weak self] in
            AppLogger.shared.log(category: .userAction, level: .info, message: "用户点击迷你栏 [还原展开] 按钮")
            self?.toggleMiniMode()
        }
        miniPlayerView.onToggleLyrics = { [weak self] in
            self?.onToggleLyrics?()
        }
        miniPlayerView.onToggleLibrary = { [weak self] in
            self?.onToggleLibrary?()
        }
    }

    public func toggleTopMost() {
        isTopMost.toggle()
        let level: NSWindow.Level = isTopMost ? .floating : .normal
        mainWindow.level = level
        miniWindow.level = level
        playerView.isTopMost = isTopMost
        mainWindow.refreshMenuStates()
        miniWindow.refreshMenuStates()
    }

    public func toggleMiniMode() {
        let outgoing = activeWindow
        isMiniMode.toggle()
        let incoming = activeWindow

        let s = GlassInteractionCoordinator.shared.uiScale
        let targetW = OriginalDesignTokens.BaseMetrics.mainPlayerWidth * s
        let targetH = (isMiniMode ? OriginalDesignTokens.BaseMetrics.miniBarStandardHeight : OriginalDesignTokens.BaseMetrics.mainPlayerHeight) * s

        let anchor = outgoing.frame
        let targetFrame = NSRect(x: anchor.minX, y: anchor.maxY - targetH, width: targetW, height: targetH)

        incoming.setFrame(targetFrame, display: true, animate: false)
        incoming.level = isTopMost ? .floating : .normal
        incoming.alphaValue = 0.0
        incoming.makeKeyAndOrderFront(nil)
        onModeDidTransition?()

        if MotionCoordinator.shared.isReduceMotionEnabled {
            incoming.alphaValue = 1.0
            outgoing.orderOut(nil)
            outgoing.alphaValue = 1.0
            return
        }

        isTransitioning = true
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.18
            ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            incoming.animator().alphaValue = 1.0
            outgoing.animator().alphaValue = 0.0
        }, completionHandler: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.isTransitioning = false
                if outgoing !== self.activeWindow {
                    outgoing.orderOut(nil)
                }
                outgoing.alphaValue = 1.0
                self.onModeDidTransition?()
            }
        })
    }

    @objc private func handleScaleOrModeChange() {
        let s = GlassInteractionCoordinator.shared.uiScale
        let mainW = OriginalDesignTokens.BaseMetrics.mainPlayerWidth * s
        let mainH = OriginalDesignTokens.BaseMetrics.mainPlayerHeight * s
        let miniH = OriginalDesignTokens.BaseMetrics.miniBarStandardHeight * s

        let cur = activeWindow.frame
        mainWindow.setFrame(NSRect(x: cur.minX, y: cur.maxY - mainH, width: mainW, height: mainH), display: true, animate: false)
        miniWindow.setFrame(NSRect(x: cur.minX, y: cur.maxY - miniH, width: mainW, height: miniH), display: true, animate: false)

        mainWindow.refreshMenuStates()
        miniWindow.refreshMenuStates()
        onModeDidTransition?()
    }

    @objc private func windowDidMove(_ notification: Notification) {
        guard let moved = notification.object as? NSWindow, moved === activeWindow else { return }
        let f = moved.frame
        UserDefaults.standard.set(true, forKey: Keys.hasOrigin)
        UserDefaults.standard.set(Double(f.origin.x), forKey: Keys.originX)
        UserDefaults.standard.set(Double(f.origin.y), forKey: Keys.originY)
    }

    private static func clampOriginToScreens(_ origin: NSPoint, size: NSSize) -> NSPoint {
        for screen in NSScreen.screens {
            let vf = screen.visibleFrame
            if vf.intersects(NSRect(origin: origin, size: size)) {
                let x = min(max(origin.x, vf.minX), vf.maxX - size.width)
                let y = min(max(origin.y, vf.minY), vf.maxY - size.height)
                return NSPoint(x: x, y: y)
            }
        }
        if let mainVF = NSScreen.main?.visibleFrame {
            let x = min(max(origin.x, mainVF.minX), mainVF.maxX - size.width)
            let y = min(max(origin.y, mainVF.minY), mainVF.maxY - size.height)
            return NSPoint(x: x, y: y)
        }
        return origin
    }

    private func executeCommand(_ block: @escaping () async throws -> Void) {
        Task {
            do {
                try await block()
            } catch {
                AppLogger.shared.log(category: .playback, level: .warn, message: "播放控制指令失败: \(error.localizedDescription)")
            }
        }
    }

    private func startObservingStore() {
        observationTask = Task { [weak self] in
            guard let self else { return }
            let stream = await self.store.playbackStream()
            for await state in stream {
                guard !Task.isCancelled else { break }
                self.updateUI(with: state)
            }
        }

        progressTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                guard !Task.isCancelled, let self else { break }
                let state = await self.store.state
                if state.isPlaying {
                    self.updateUI(with: state)
                }
            }
        }
    }

    private func updateUI(with state: PlaybackState) {
        playerView.updateState(state)
        miniPlayerView.updateState(state)
    }
}
