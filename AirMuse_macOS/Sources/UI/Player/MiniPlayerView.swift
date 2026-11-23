import AppKit
import Domain
import DesignSystem

// MARK: - CarouselHaloTextView

/// Renders Windows-style soft Gaussian glyph halo text (`DrawGlyphHaloText`)
/// with 10-second vertical-slide carousel cycling across [Title, Artist, Album]
/// and smooth marquee scrolling if a line exceeds the visible width.
@MainActor
public final class CarouselHaloTextView: NSView {

    private var items: [String] = ["AirMuse Ready"]
    private var currentIndex: Int = 0
    private var currentLine: String = "AirMuse Ready"
    private var previousLine: String?
    private var slideProgress: CGFloat = 1.0
    private var cycleTask: Task<Void, Never>?
    private var slideTask: Task<Void, Never>?

    public var cycleIntervalSeconds: UInt64 = 10

    deinit {
        cycleTask?.cancel()
        slideTask?.cancel()
    }

    public func setItems(_ newItems: [String]) {
        let cleaned = newItems.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        let normalized = cleaned.isEmpty ? ["AirMuse Ready"] : cleaned
        guard normalized != items else { return }

        items = normalized
        currentIndex = 0
        transition(to: normalized[0])
        restartCycleTimer()
    }

    public func setSingleLine(_ line: String) {
        let text = line.trimmingCharacters(in: .whitespacesAndNewlines)
        let target = text.isEmpty ? " " : text
        cycleTask?.cancel()
        cycleTask = nil
        guard target != currentLine else { return }
        items = [target]
        currentIndex = 0
        transition(to: target)
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        restartCycleTimer()
    }

    public override func viewDidHide() {
        super.viewDidHide()
        cycleTask?.cancel()
        cycleTask = nil
    }

    public override func viewDidUnhide() {
        super.viewDidUnhide()
        restartCycleTimer()
    }

    private func restartCycleTimer() {
        cycleTask?.cancel()
        cycleTask = nil
        guard window != nil, !isHidden, items.count > 1 else { return }

        cycleTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(self?.cycleIntervalSeconds ?? 10))
                guard !Task.isCancelled, let self, self.window != nil, !self.isHidden, self.items.count > 1 else { break }
                self.currentIndex = (self.currentIndex + 1) % self.items.count
                self.transition(to: self.items[self.currentIndex])
            }
        }
    }

    private func transition(to nextLine: String) {
        previousLine = currentLine
        currentLine = nextLine

        if MotionCoordinator.shared.isReduceMotionEnabled {
            slideProgress = 1.0
            previousLine = nil
            needsDisplay = true
            return
        }

        slideProgress = 0.0
        slideTask?.cancel()
        slideTask = Task { @MainActor [weak self] in
            let steps = 18
            for step in 1...steps {
                try? await Task.sleep(for: .milliseconds(16))
                guard !Task.isCancelled, let self else { break }
                let t = CGFloat(step) / CGFloat(steps)
                // Smooth ease-out cubic
                self.slideProgress = 1.0 - pow(1.0 - t, 3.0)
                self.needsDisplay = true
            }
            if let self {
                self.slideProgress = 1.0
                self.previousLine = nil
                self.needsDisplay = true
            }
        }
    }

    public override func draw(_ dirtyRect: NSRect) {
        guard bounds.width > 4, bounds.height > 4 else { return }
        let s = GlassInteractionCoordinator.shared.uiScale
        let font = NSFont.systemFont(ofSize: 12.5 * s, weight: .regular)
        let textH = ceil(font.ascender - font.descender + 4.0)
        let baseY = (bounds.height - textH) * 0.5
        let slideDist = 14.0 * s
        let p = slideProgress

        if p < 0.99, let prev = previousLine, !prev.isEmpty {
            let prevRect = CGRect(x: 0, y: baseY + p * slideDist, width: bounds.width, height: textH)
            PixelFontRenderer.drawSoftGlyphHaloText(
                prev,
                in: prevRect,
                font: font,
                textColor: OriginalDesignTokens.Colors.highlightSilver,
                alignment: .center,
                alpha: 1.0 - p
            )
        }

        if p > 0.01, !currentLine.isEmpty {
            let curRect = CGRect(x: 0, y: baseY - (1.0 - p) * slideDist, width: bounds.width, height: textH)
            PixelFontRenderer.drawSoftGlyphHaloText(
                currentLine,
                in: curRect,
                font: font,
                textColor: OriginalDesignTokens.Colors.highlightSilver,
                alignment: .center,
                alpha: p
            )
        }
    }
}

// MARK: - MiniPlayerView

/// 1:1 restoration of the AIRPLAY-zion / AirMuse_Remastered Mini Bar (330×40 @ 1×, 495×60 @ 1.5×).
/// - Idle: 10-second vertical-slide carousel across [Title, Artist, Album] with Windows-style soft Gaussian glyph halo
/// - Hover: `MINICONTROL` 16×16 playback buttons + `WINDOWBUTTON` controls
open class MiniPlayerView: GlassMiniPlayer {

    public var onPlayPause: (() -> Void)?
    public var onStop: (() -> Void)?
    public var onNext: (() -> Void)?
    public var onPrevious: (() -> Void)?
    public var onExpand: (() -> Void)?
    public var onToggleLyrics: (() -> Void)?
    public var onToggleLibrary: (() -> Void)?
    public var onQuit: (() -> Void)?

    // Idle state views
    private let idleContainer = NSView()
    private let carouselView = CarouselHaloTextView()
    private let timeView = TimeFontDisplayView()

    // Hover state views
    private let controlsContainer = NSView()
    private let stopButton = GlassButton(sprite: nil, size: CGSize(width: 16, height: 16), enableLiquidGlassHover: true)
    private let prevButton = GlassButton(sprite: nil, size: CGSize(width: 16, height: 16), enableLiquidGlassHover: true)
    private let playPauseButton = GlassButton(sprite: nil, size: CGSize(width: 16, height: 16), enableLiquidGlassHover: true)
    private let nextButton = GlassButton(sprite: nil, size: CGSize(width: 16, height: 16), enableLiquidGlassHover: true)
    private let ejectButton = GlassButton(sprite: nil, size: CGSize(width: 16, height: 16), enableLiquidGlassHover: true)

    private let libraryButton = GlassButton(sprite: nil, size: CGSize(width: 13, height: 13))
    private let lyricsButton = GlassButton(sprite: nil, size: CGSize(width: 13, height: 13))
    private let expandButton = GlassButton(sprite: nil, size: CGSize(width: 13, height: 13))
    private let quitButton = GlassButton(sprite: nil, size: CGSize(width: 13, height: 13))

    private var isPlayingState: Bool = false
    private var showRemainingTime: Bool = false
    private var lastPositionMs: Int64 = 0
    private var lastDurationMs: Int64 = 0
    private var isHovering: Bool = false
    private var trackingArea: NSTrackingArea?

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupMiniViews()
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupMiniViews()
    }

    private func setupMiniViews() {
        idleContainer.wantsLayer = true
        idleContainer.alphaValue = 1.0
        addSubview(idleContainer)

        carouselView.cycleIntervalSeconds = 10
        idleContainer.addSubview(carouselView)

        timeView.alignment = .right
        let click = NSClickGestureRecognizer(target: self, action: #selector(toggleTimeMode))
        timeView.addGestureRecognizer(click)
        idleContainer.addSubview(timeView)

        controlsContainer.wantsLayer = true
        controlsContainer.alphaValue = 0.0
        addSubview(controlsContainer)

        stopButton.onClick = { [weak self] in self?.onStop?() }
        prevButton.onClick = { [weak self] in self?.onPrevious?() }
        playPauseButton.onClick = { [weak self] in self?.onPlayPause?() }
        nextButton.onClick = { [weak self] in self?.onNext?() }
        ejectButton.onClick = { [weak self] in self?.onToggleLibrary?() }

        controlsContainer.addSubview(stopButton)
        controlsContainer.addSubview(prevButton)
        controlsContainer.addSubview(playPauseButton)
        controlsContainer.addSubview(nextButton)
        controlsContainer.addSubview(ejectButton)

        libraryButton.toolTip = "显示/隐藏音乐来源面板"
        libraryButton.onClick = { [weak self] in self?.onToggleLibrary?() }
        controlsContainer.addSubview(libraryButton)

        lyricsButton.toolTip = "桌面歌词"
        lyricsButton.onClick = { [weak self] in self?.onToggleLyrics?() }
        expandButton.toolTip = "展开主界面"
        expandButton.onClick = { [weak self] in self?.onExpand?() }
        quitButton.toolTip = "退出 AirMuse"
        quitButton.onClick = { [weak self] in
            if let onQuit = self?.onQuit { onQuit() } else { NSApp.terminate(nil) }
        }

        controlsContainer.addSubview(lyricsButton)
        controlsContainer.addSubview(expandButton)
        controlsContainer.addSubview(quitButton)

        reloadSprites()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(skinSettingsChanged),
            name: GlassInteractionCoordinator.modeDidChangeNotification,
            object: nil
        )
    }

    @objc private func toggleTimeMode() {
        showRemainingTime.toggle()
        refreshTimeDisplay()
    }

    @objc private func skinSettingsChanged() {
        reloadSprites()
        needsLayout = true
    }

    private func reloadSprites() {
        let res = GlassInteractionCoordinator.shared.resolutionMode
        let atlas = SkinAtlas.shared
        stopButton.spriteImage = atlas.miniControl(.stop, resolution: res)
        prevButton.spriteImage = atlas.miniControl(.previous, resolution: res)
        playPauseButton.spriteImage = atlas.miniControl(isPlayingState ? .pause : .play, resolution: res)
        nextButton.spriteImage = atlas.miniControl(.next, resolution: res)
        ejectButton.spriteImage = atlas.miniControl(.eject, resolution: res)

        libraryButton.spriteImage = atlas.windowButton(.maximize, resolution: res)
        lyricsButton.spriteImage = atlas.windowButton(.lyricsNote, resolution: res)
        expandButton.spriteImage = atlas.windowButton(.expandDown, resolution: res)
        quitButton.spriteImage = atlas.windowButton(.close, resolution: res)
    }

    open override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = trackingArea { removeTrackingArea(existing) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    open override func mouseEntered(with event: NSEvent) {
        setHovering(true)
    }

    open override func mouseExited(with event: NSEvent) {
        setHovering(false)
    }

    private func setHovering(_ hovering: Bool) {
        guard isHovering != hovering else { return }
        isHovering = hovering
        let targetIdle: CGFloat = hovering ? 0.0 : 1.0
        let targetCtrl: CGFloat = hovering ? 1.0 : 0.0

        if MotionCoordinator.shared.isReduceMotionEnabled {
            idleContainer.alphaValue = targetIdle
            controlsContainer.alphaValue = targetCtrl
        } else {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = MotionTokens.Duration.hoverFade
                idleContainer.animator().alphaValue = targetIdle
                controlsContainer.animator().alphaValue = targetCtrl
            }
        }
    }

    open override func layout() {
        super.layout()
        let s = GlassInteractionCoordinator.shared.uiScale
        let w = bounds.width
        let h = bounds.height

        idleContainer.frame = bounds
        controlsContainer.frame = bounds

        // Idle: centered 10s carousel [Title, Artist, Album] across full bar without time display
        timeView.isHidden = true
        let textLeft = 14.0 * s
        carouselView.frame = NSRect(x: textLeft, y: 0, width: max(20, w - textLeft * 2.0), height: h)

        // Hover: centered 5 MINICONTROL buttons (16×16 @ 1x) + right window buttons (13×13 @ 1x)
        let btnSize = 16.0 * s
        let btnY = (h - btnSize) * 0.5
        let startX = (w - 92.0 * s) * 0.5
        stopButton.frame = NSRect(x: startX, y: btnY, width: btnSize, height: btnSize)
        prevButton.frame = NSRect(x: startX + 18.0 * s, y: btnY, width: btnSize, height: btnSize)
        playPauseButton.frame = NSRect(x: startX + 37.0 * s, y: btnY, width: btnSize, height: btnSize)
        nextButton.frame = NSRect(x: startX + 56.0 * s, y: btnY, width: btnSize, height: btnSize)
        ejectButton.frame = NSRect(x: startX + 74.0 * s, y: btnY, width: btnSize, height: btnSize)

        let wbSize = 13.0 * s
        let wbY = (h - wbSize) * 0.5
        libraryButton.frame = NSRect(x: w - 93.0 * s, y: wbY, width: wbSize, height: wbSize)
        expandButton.frame = NSRect(x: w - 77.0 * s, y: wbY, width: wbSize, height: wbSize)
        lyricsButton.frame = NSRect(x: w - 61.0 * s, y: wbY, width: wbSize, height: wbSize)
        quitButton.frame = NSRect(x: w - 45.0 * s, y: wbY, width: wbSize, height: wbSize)
    }

    public func updateState(_ state: PlaybackState) {
        isPlayingState = state.isPlaying
        lastPositionMs = state.estimatedPositionMs
        lastDurationMs = state.durationMs

        let res = GlassInteractionCoordinator.shared.resolutionMode
        playPauseButton.spriteImage = SkinAtlas.shared.miniControl(state.isPlaying ? .pause : .play, resolution: res)

        if let track = state.currentTrack {
            carouselView.setItems([track.title, track.artistName, track.albumTitle])
        } else {
            carouselView.setItems(["AirMuse Ready"])
        }

        refreshTimeDisplay()
    }

    private func refreshTimeDisplay() {
        if showRemainingTime && lastDurationMs > 0 {
            let rem = max(0, lastDurationMs - lastPositionMs)
            timeView.timeString = "-" + formatTime(ms: rem)
        } else {
            timeView.timeString = formatTime(ms: lastPositionMs)
        }
    }

    private func formatTime(ms: Int64) -> String {
        let totalSec = max(0, ms / 1000)
        let m = totalSec / 60
        let s = totalSec % 60
        return String(format: "%02lld:%02lld", m, s)
    }
}
