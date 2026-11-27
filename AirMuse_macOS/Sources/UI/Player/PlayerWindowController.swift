import AppKit
import Domain
import Playback
import DesignSystem
import Infrastructure

// MARK: - PlayerWindowController

/// Controls Main (`PlayerView`) and Mini (`MiniPlayerView`) player views inside a shared `playerSlotView`
/// hosted by `UnifiedStageController`.
/// Note: `WebRuntime` attaches its keep-alive `WKWebView` directly to `playerSlotView` behind `visualContainer`,
/// so clipping `visualContainer` during M02 morph never disturbs WebKit playback.
@MainActor
open class PlayerWindowController: NSWindowController {

    public private(set) var isMiniMode: Bool = false
    public private(set) var isTopMost: Bool = true

    public let playerSlotView = NSView()
    private let visualContainer = NSView()
    public let playerView = PlayerView()
    public let miniPlayerView = MiniPlayerView()

    public var onToggleLyrics: (() -> Void)?
    public var onToggleLibrary: (() -> Void)?
    public var onToggleFavorite: (() -> Void)?
    public var onToggleLog: (() -> Void)?
    public var onMinimizeRequested: (() -> Void)?
    public var onQuitRequested: (() -> Void)?
    public var onChoreographedMiniToggleRequested: (() -> Void)?
    /// Fired when UnifiedStageController should drive an animated Normal↔Mini morph (M02).
    public var onModeTransitionRequested: ((Bool) -> Void)?
    public var onModeDidTransition: (() -> Void)?
    public var onTopMostDidChange: (() -> Void)?

    private let coordinator: PlaybackCoordinatorV2
    private let store: PlaybackStore
    private var observationTask: Task<Void, Never>?
    private var progressTask: Task<Void, Never>?

    public init(coordinator: PlaybackCoordinatorV2, store: PlaybackStore) {
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

    public func preferredPlayerSize(for scale: CGFloat, mini: Bool? = nil) -> NSSize {
        let useMini = mini ?? isMiniMode
        let w = OriginalDesignTokens.BaseMetrics.mainPlayerWidth * scale
        let h = (useMini
            ? OriginalDesignTokens.BaseMetrics.miniBarStandardHeight
            : OriginalDesignTokens.BaseMetrics.mainPlayerHeight) * scale
        return NSSize(width: w, height: h)
    }

    public func layoutSlot(frame: NSRect) {
        let sizeChanged = playerSlotView.frame.size != frame.size
        playerSlotView.frame = frame
        visualContainer.frame = playerSlotView.bounds
        if !isMiniMode {
            if sizeChanged || playerView.frame != visualContainer.bounds {
                playerView.frame = visualContainer.bounds
                playerView.needsLayout = true
            } else {
                playerView.refreshGlassSurface()
            }
        } else {
            if sizeChanged || miniPlayerView.frame != visualContainer.bounds {
                miniPlayerView.frame = visualContainer.bounds
                miniPlayerView.needsLayout = true
            } else {
                miniPlayerView.refreshAppearance()
            }
        }
    }

    /// Updates visual crossfade & top-pinned bounds during an active M02 Normal↔Mini morph.
    public func applyMorphFrame(slotFrame: NSRect, targetMini: Bool, progress: CGFloat, scale: CGFloat) {
        playerSlotView.frame = slotFrame
        visualContainer.frame = playerSlotView.bounds
        visualContainer.layer?.masksToBounds = true

        playerView.isHidden = false
        miniPlayerView.isHidden = false

        let normalSize = preferredPlayerSize(for: scale, mini: false)
        let miniSize = preferredPlayerSize(for: scale, mini: true)
        let boundsH = visualContainer.bounds.height

        // Pin both subviews to the top edge of visualContainer so controls clip cleanly instead of squishing
        playerView.frame = NSRect(x: 0, y: boundsH - normalSize.height, width: normalSize.width, height: normalSize.height)
        miniPlayerView.frame = NSRect(x: 0, y: boundsH - miniSize.height, width: miniSize.width, height: miniSize.height)

        // Derive crossfade monotonically from live slot height so mid-flight reversals are 100% continuous
        let spanH = max(1.0, normalSize.height - miniSize.height)
        let normalFraction = min(1.0, max(0.0, (slotFrame.height - miniSize.height) / spanH))
        playerView.alphaValue = min(1.0, max(0.0, (normalFraction - 0.35) / 0.65))
        miniPlayerView.alphaValue = min(1.0, max(0.0, (0.40 - normalFraction) / 0.40))
    }

    /// Finalizes visibility, alpha, masks, and bounds after M02 morph settles or cancels.
    public func finalizeMorphState(isMini: Bool, slotFrame: NSRect) {
        visualContainer.layer?.masksToBounds = false
        playerView.alphaValue = 1.0
        miniPlayerView.alphaValue = 1.0
        playerView.isHidden = isMini
        miniPlayerView.isHidden = !isMini
        layoutSlot(frame: slotFrame)
    }

    private func setupSlotViews() {
        playerSlotView.wantsLayer = true
        playerSlotView.layer?.masksToBounds = false

        visualContainer.wantsLayer = true
        visualContainer.layer?.masksToBounds = false
        visualContainer.autoresizingMask = [.width, .height]
        playerSlotView.addSubview(visualContainer)

        playerView.autoresizingMask = []
        visualContainer.addSubview(playerView)

        miniPlayerView.autoresizingMask = []
        miniPlayerView.isHidden = true
        visualContainer.addSubview(miniPlayerView)
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
            if let onChoreographedMiniToggleRequested = self?.onChoreographedMiniToggleRequested {
                onChoreographedMiniToggleRequested()
            } else {
                self?.toggleMiniMode()
            }
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
        playerView.onToggleFavorite = { [weak self] in
            AppLogger.shared.log(category: .userAction, level: .info, message: "用户点击 [收藏当前曲目] 按钮")
            self?.onToggleFavorite?()
        }
        playerView.onMinimize = { [weak self] in
            if let onMinimizeRequested = self?.onMinimizeRequested {
                onMinimizeRequested()
            } else {
                self?.playerView.window?.miniaturize(nil)
            }
        }
        playerView.onQuit = { [weak self] in
            if let onQuitRequested = self?.onQuitRequested {
                onQuitRequested()
            } else {
                NSApp.terminate(nil)
            }
        }
        playerView.onSelectAppleMusic = { [weak self] in
            AppLogger.shared.log(category: .userAction, level: .info, message: "用户点击 [Apple Music] 平台切换")
            self?.playerView.currentPlatform = 0
        }
        playerView.onSelectSpotify = { [weak self] in
            AppLogger.shared.log(category: .userAction, level: .info, message: "用户点击 [Spotify] 平台切换")
            self?.playerView.currentPlatform = 1
        }
        playerView.onSelectQQMusic = { [weak self] in
            AppLogger.shared.log(category: .userAction, level: .info, message: "用户点击 [QQ 音乐] 平台切换")
            self?.playerView.currentPlatform = 2
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
            if let onChoreographedMiniToggleRequested = self?.onChoreographedMiniToggleRequested {
                onChoreographedMiniToggleRequested()
            } else {
                self?.toggleMiniMode()
            }
        }
        miniPlayerView.onToggleLyrics = { [weak self] in
            self?.onToggleLyrics?()
        }
        miniPlayerView.onToggleLibrary = { [weak self] in
            self?.onToggleLibrary?()
        }
        miniPlayerView.onToggleFavorite = { [weak self] in
            self?.onToggleFavorite?()
        }
        miniPlayerView.onToggleSource = { [weak self] in
            self?.onToggleLibrary?()
        }
        miniPlayerView.onQuit = { [weak self] in
            if let onQuitRequested = self?.onQuitRequested {
                onQuitRequested()
            } else {
                NSApp.terminate(nil)
            }
        }
    }

    public func updateFavoriteState(isFavorited: Bool?, isPending: Bool = false, isEnabled: Bool = true) {
        playerView.setFavoriteState(isFavorited: isFavorited, isPending: isPending, isEnabled: isEnabled)
        miniPlayerView.setFavoriteState(isFavorited: isFavorited, isPending: isPending, isEnabled: isEnabled)
    }

    public func toggleTopMost() {
        isTopMost.toggle()
        playerView.isTopMost = isTopMost
        onTopMostDidChange?()
    }

    public func setMiniModeStateForChoreography(_ mini: Bool) {
        isMiniMode = mini
        playerView.cancelScrollIntro()
    }

    public func toggleMiniMode() {
        isMiniMode.toggle()
        playerView.cancelScrollIntro()
        if let onModeTransitionRequested {
            onModeTransitionRequested(isMiniMode)
        } else {
            playerView.isHidden = isMiniMode
            miniPlayerView.isHidden = !isMiniMode
            onModeDidTransition?()
        }
    }

    public func playScrollIntroIfEligible(completion: (@MainActor (Bool) -> Void)? = nil) {
        guard !isMiniMode else {
            completion?(true)
            return
        }
        playerView.playScrollIntro(completion: completion)
    }

    public func playScrollCollapseIfEligible(completion: @escaping @MainActor (Bool) -> Void) {
        guard !isMiniMode else {
            completion(true)
            return
        }
        playerView.playScrollCollapse(completion: completion)
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
