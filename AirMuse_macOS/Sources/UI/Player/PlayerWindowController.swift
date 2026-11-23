import AppKit
import Domain
import Playback
import DesignSystem
import Infrastructure

// MARK: - PlayerWindowController

/// Controls Main (`PlayerView`) and Mini (`MiniPlayerView`) player views inside a shared `playerSlotView`
/// hosted by `UnifiedStageController`.
@MainActor
open class PlayerWindowController: NSWindowController {

    public private(set) var isMiniMode: Bool = false
    public private(set) var isTopMost: Bool = true

    public let playerSlotView = NSView()
    private let playerView = PlayerView()
    private let miniPlayerView = MiniPlayerView()

    public var onToggleLyrics: (() -> Void)?
    public var onToggleLibrary: (() -> Void)?
    public var onToggleLog: (() -> Void)?
    public var onModeDidTransition: (() -> Void)?
    public var onTopMostDidChange: (() -> Void)?

    private let coordinator: PlaybackCoordinator
    private let store: PlaybackStore
    private var observationTask: Task<Void, Never>?
    private var progressTask: Task<Void, Never>?

    public init(coordinator: PlaybackCoordinator, store: PlaybackStore) {
        self.coordinator = coordinator
        self.store = store
        super.init(window: nil)

        setupSlotViews()
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

    public func preferredPlayerSize(for scale: CGFloat) -> NSSize {
        let w = OriginalDesignTokens.BaseMetrics.mainPlayerWidth * scale
        let h = (isMiniMode
            ? OriginalDesignTokens.BaseMetrics.miniBarStandardHeight
            : OriginalDesignTokens.BaseMetrics.mainPlayerHeight) * scale
        return NSSize(width: w, height: h)
    }

    public func layoutSlot(frame: NSRect) {
        playerSlotView.frame = frame
        playerView.frame = playerSlotView.bounds
        miniPlayerView.frame = playerSlotView.bounds
        playerView.needsLayout = true
        miniPlayerView.needsLayout = true
        if !isMiniMode {
            playerView.refreshGlassSurface()
        }
    }

    private func setupSlotViews() {
        playerSlotView.wantsLayer = true
        playerSlotView.layer?.masksToBounds = false

        playerView.autoresizingMask = [.width, .height]
        playerSlotView.addSubview(playerView)

        miniPlayerView.autoresizingMask = [.width, .height]
        miniPlayerView.isHidden = true
        playerSlotView.addSubview(miniPlayerView)
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
            AppLogger.shared.log(category: .userAction, level: .info, message: "用户点击切换 [迷你播放器] 模式")
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
        playerView.isTopMost = isTopMost
        onTopMostDidChange?()
    }

    public func toggleMiniMode() {
        isMiniMode.toggle()
        playerView.isHidden = isMiniMode
        miniPlayerView.isHidden = !isMiniMode
        onModeDidTransition?()
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
