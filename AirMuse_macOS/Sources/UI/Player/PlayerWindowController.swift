import AppKit
import Domain
import DesignSystem
import Playback
import Infrastructure

// MARK: - PlayerWindowController

/// Controls the primary AirMuse window and transitions between Main and Mini modes.
@MainActor
open class PlayerWindowController: NSWindowController {

    public private(set) var isMiniMode: Bool = false

    public var onToggleLyrics: (() -> Void)?
    public var onToggleLibrary: (() -> Void)?
    public var onToggleLog: (() -> Void)?

    private let coordinator: PlaybackCoordinator
    private let store: PlaybackStore

    private let playerView = PlayerView()
    private let miniPlayerView = MiniPlayerView()
    private var observationTask: Task<Void, Never>?
    private var progressTask: Task<Void, Never>?

    public init(coordinator: PlaybackCoordinator, store: PlaybackStore) {
        self.coordinator = coordinator
        self.store = store

        let initialRect = NSRect(
            x: 200,
            y: (NSScreen.main?.visibleFrame.maxY ?? 800) - DesignTokens.Metrics.mainPlayerHeight - 50,
            width: DesignTokens.Metrics.mainPlayerWidth,
            height: DesignTokens.Metrics.mainPlayerHeight
        )
        let window = PlayerWindow(contentRect: initialRect)
        super.init(window: window)

        setupWindow(window)
        wireActions()
        startObservingStore()
    }

    public required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        observationTask?.cancel()
        progressTask?.cancel()
    }

    private func setupWindow(_ window: PlayerWindow) {
        window.onDoubleClicked = { [weak self] in
            self?.toggleMiniMode()
        }
        window.onToggleLog = { [weak self] in
            self?.onToggleLog?()
        }

        let container = NSView(frame: window.contentView?.bounds ?? .zero)
        container.wantsLayer = true
        window.contentView = container

        playerView.frame = container.bounds
        playerView.autoresizingMask = [.width, .height]
        container.addSubview(playerView)

        miniPlayerView.frame = container.bounds
        miniPlayerView.autoresizingMask = [.width, .height]
        miniPlayerView.alphaValue = 0.0
        miniPlayerView.isHidden = true
        container.addSubview(miniPlayerView)
    }

    private func wireActions() {
        // PlayerView Actions
        playerView.onPlayPause = { [weak self] in
            AppLogger.shared.log(category: .userAction, level: .info, message: "用户点击主界面 [播放/暂停] 按钮")
            self?.executeCommand { try await self?.coordinator.playPause() }
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
        playerView.onToggleMiniMode = { [weak self] in
            AppLogger.shared.log(category: .userAction, level: .info, message: "用户点击切换 [迷你播放器] 模式")
            self?.toggleMiniMode()
        }
        playerView.onToggleLyrics = { [weak self] in
            AppLogger.shared.log(category: .userAction, level: .info, message: "用户点击 [歌词面板] 按钮")
            self?.onToggleLyrics?()
        }
        playerView.onToggleLibrary = { [weak self] in
            AppLogger.shared.log(category: .userAction, level: .info, message: "用户点击 [音乐资料库] 按钮")
            self?.onToggleLibrary?()
        }

        // MiniPlayerView Actions
        miniPlayerView.onPlayPause = { [weak self] in
            AppLogger.shared.log(category: .userAction, level: .info, message: "用户点击迷你栏 [播放/暂停] 按钮")
            self?.executeCommand { try await self?.coordinator.playPause() }
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
    }

    public func toggleMiniMode() {
        guard let window = window else { return }
        isMiniMode.toggle()

        let currentFrame = window.frame
        let targetHeight: CGFloat = isMiniMode ? DesignTokens.Metrics.miniPlayerHeight : DesignTokens.Metrics.mainPlayerHeight
        let newY = currentFrame.maxY - targetHeight
        let targetFrame = NSRect(x: currentFrame.minX, y: newY, width: currentFrame.width, height: targetHeight)

        let isMini = self.isMiniMode
        miniPlayerView.isHidden = false
        playerView.isHidden = false

        MotionCoordinator.shared.animate(duration: 0.28) {
            window.setFrame(targetFrame, display: true, animate: false)
            self.playerView.animator().alphaValue = isMini ? 0.0 : 1.0
            self.miniPlayerView.animator().alphaValue = isMini ? 1.0 : 0.0
        }
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

        // Periodic async task to update progress estimation only when playing
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
