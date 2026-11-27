import AppKit
import QuartzCore
import Domain
import DesignSystem

// MARK: - CarouselHaloTextView

/// Renders Windows-style soft Gaussian glyph halo text (`DrawGlyphHaloText`)
/// with 10-second vertical-slide carousel cycling across [Title, Artist, Album],
/// M15 horizontal marquee scrolling when text overflows (CJK/RTL/emoji safe),
/// and automatic clock shutdown when hidden, off-window, hovered, or Reduce Motion.
@MainActor
public final class CarouselHaloTextView: NSView {

    private let ownerID = "CarouselHaloText-\(UUID().uuidString)"
    private var items: [String] = ["AirMuse Ready"]
    private var currentIndex: Int = 0
    private var currentLine: String = "AirMuse Ready"
    private var previousLine: String?
    private var slideProgress: CGFloat = 1.0
    private var marqueeOffset: CGFloat = 0.0
    private var marqueePaused: Bool = false

    private var cycleTask: Task<Void, Never>?
    private var slideDriverID: UUID?
    private var slideTicket: MotionTicket?
    private var marqueeDriverID: UUID?
    private var marqueeDelayRemaining: TimeInterval = 1.0

    public var cycleIntervalSeconds: UInt64 = 10
    public var isMarqueeActive: Bool { marqueeDriverID != nil }
    public var currentMarqueeOffset: CGFloat { marqueeOffset }

    isolated deinit {
        stopAllClocks()
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

    public func setPaused(_ paused: Bool) {
        guard marqueePaused != paused else { return }
        marqueePaused = paused
        if paused {
            stopMarqueeDriver()
            cycleTask?.cancel()
            cycleTask = nil
        } else {
            restartCycleTimer()
            restartMarqueeIfNeeded()
        }
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            stopAllClocks()
        } else if !isHiddenOrHasHiddenAncestor && !marqueePaused {
            restartCycleTimer()
            restartMarqueeIfNeeded()
        }
    }

    public override func viewDidHide() {
        super.viewDidHide()
        stopAllClocks()
    }

    public override func viewDidUnhide() {
        super.viewDidUnhide()
        if !marqueePaused {
            restartCycleTimer()
            restartMarqueeIfNeeded()
        }
    }

    public override func layout() {
        super.layout()
        restartMarqueeIfNeeded()
    }

    private func stopAllClocks() {
        cycleTask?.cancel()
        cycleTask = nil
        stopSlideDriver()
        stopMarqueeDriver()
        MotionCoordinator.shared.cancelAll(owner: ownerID)
    }

    private func stopSlideDriver() {
        if let id = slideDriverID {
            MotionCoordinator.shared.displayDriver.stop(id: id)
            slideDriverID = nil
        }
        slideTicket = nil
    }

    private func stopMarqueeDriver() {
        if let id = marqueeDriverID {
            MotionCoordinator.shared.displayDriver.stop(id: id)
            marqueeDriverID = nil
        }
    }

    private func restartCycleTimer() {
        cycleTask?.cancel()
        cycleTask = nil
        guard window != nil, !isHiddenOrHasHiddenAncestor, !marqueePaused, items.count > 1 else { return }

        cycleTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(self?.cycleIntervalSeconds ?? 10))
                guard !Task.isCancelled, let self, self.window != nil, !self.isHiddenOrHasHiddenAncestor, !self.marqueePaused, self.items.count > 1 else { break }
                self.currentIndex = (self.currentIndex + 1) % self.items.count
                self.transition(to: self.items[self.currentIndex])
            }
        }
    }

    private func transition(to nextLine: String) {
        previousLine = currentLine
        currentLine = nextLine
        marqueeOffset = 0
        stopMarqueeDriver()

        let key = TransitionKey(owner: ownerID, channel: "slide")
        stopSlideDriver()
        let ticket = MotionCoordinator.shared.beginTransition(for: key, category: .content) { [weak self] in
            self?.stopSlideDriver()
        }
        slideTicket = ticket

        if MotionCoordinator.shared.isReduceMotionEnabled {
            slideProgress = 1.0
            previousLine = nil
            _ = MotionCoordinator.shared.complete(ticket)
            slideTicket = nil
            needsDisplay = true
            return
        }

        slideProgress = 0.0
        var elapsed: TimeInterval = 0
        let total = MotionTokens.Duration.miniTextSlide
        slideDriverID = MotionCoordinator.shared.displayDriver.start { [weak self] dt, _ in
            guard let self, MotionCoordinator.shared.isCurrent(ticket) else { return false }
            elapsed += dt
            let raw = min(1.0, elapsed / max(0.01, total))
            self.slideProgress = CGFloat(1.0 - pow(1.0 - raw, 3.0))
            self.needsDisplay = true
            if raw >= 1.0 {
                if MotionCoordinator.shared.complete(ticket) {
                    self.slideProgress = 1.0
                    self.previousLine = nil
                    self.slideDriverID = nil
                    self.slideTicket = nil
                    self.restartMarqueeIfNeeded()
                    self.needsDisplay = true
                }
                return false
            }
            return true
        }
    }

    /// Computes exact natural single-line width using CoreText (handles CJK, RTL, and emoji clusters accurately).
    public func measureTextWidth(_ text: String, font: NSFont) -> CGFloat {
        guard !text.isEmpty else { return 0 }
        let attr = NSAttributedString(string: text, attributes: [.font: font as CTFont])
        let line = CTLineCreateWithAttributedString(attr)
        var ascent: CGFloat = 0
        var descent: CGFloat = 0
        var leading: CGFloat = 0
        return ceil(CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, &leading)))
    }

    private func restartMarqueeIfNeeded() {
        stopMarqueeDriver()
        guard !MotionCoordinator.shared.isReduceMotionEnabled,
              !marqueePaused,
              window != nil,
              !isHiddenOrHasHiddenAncestor,
              bounds.width > 12 else {
            marqueeOffset = 0
            return
        }

        let s = GlassInteractionCoordinator.shared.uiScale
        let font = NSFont.systemFont(ofSize: 12.5 * s, weight: .regular)
        let textW = measureTextWidth(currentLine, font: font)
        guard textW > bounds.width + 2.0 else {
            marqueeOffset = 0
            return
        }

        let gap = MotionTokens.Thresholds.marqueeGapPt * s
        let cycleSpan = textW + gap
        let speed = MotionTokens.Thresholds.marqueeSpeedPtPerSec * s
        marqueeDelayRemaining = 1.2

        marqueeDriverID = MotionCoordinator.shared.displayDriver.start { [weak self] dt, _ in
            guard let self,
                  !MotionCoordinator.shared.isReduceMotionEnabled,
                  !self.marqueePaused,
                  self.window != nil,
                  !self.isHiddenOrHasHiddenAncestor else {
                self?.marqueeOffset = 0
                self?.marqueeDriverID = nil
                return false
            }
            if self.marqueeDelayRemaining > 0 {
                self.marqueeDelayRemaining -= dt
                return true
            }
            self.marqueeOffset += speed * CGFloat(dt)
            if self.marqueeOffset >= cycleSpan {
                self.marqueeOffset -= cycleSpan
                self.marqueeDelayRemaining = 1.2
            }
            self.needsDisplay = true
            return true
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
            let textW = measureTextWidth(currentLine, font: font)
            if textW > bounds.width + 2.0 && marqueeOffset > 0.1 && !MotionCoordinator.shared.isReduceMotionEnabled {
                let gap = MotionTokens.Thresholds.marqueeGapPt * s
                let span = textW + gap
                let y = baseY - (1.0 - p) * slideDist
                let x1 = -marqueeOffset
                let x2 = x1 + span
                NSGraphicsContext.saveGraphicsState()
                NSBezierPath(rect: bounds).addClip()
                PixelFontRenderer.drawSoftGlyphHaloText(
                    currentLine,
                    in: CGRect(x: x1, y: y, width: textW + 4, height: textH),
                    font: font,
                    textColor: OriginalDesignTokens.Colors.highlightSilver,
                    alignment: .left,
                    alpha: p
                )
                if x2 < bounds.width {
                    PixelFontRenderer.drawSoftGlyphHaloText(
                        currentLine,
                        in: CGRect(x: x2, y: y, width: textW + 4, height: textH),
                        font: font,
                        textColor: OriginalDesignTokens.Colors.highlightSilver,
                        alignment: .left,
                        alpha: p
                    )
                }
                NSGraphicsContext.restoreGraphicsState()
            } else {
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
}

// MARK: - MiniHoverControlsContainer

@MainActor
private final class MiniHoverControlsContainer: NSView {
    var allowsHitTesting: Bool = false

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard allowsHitTesting, !isHidden, alphaValue > 0.05 else { return nil }
        let localPt = convert(point, from: superview)
        guard bounds.contains(localPt) else { return nil }
        for sub in subviews.reversed() where !sub.isHidden {
            if let hit = sub.hitTest(localPt) {
                return hit
            }
        }
        return nil
    }
}

// MARK: - MiniPlayerView

/// 1:1 restoration of the AIRPLAY-zion / AirMuse_Remastered Mini Bar (330×30 @ 1×, 495×45 @ 1.5×).
/// Supports M04 hover capsule transition (preserving time display, zero resize), M05 button physics,
/// M06 real playback-state icon transition, M15 marquee/carousel, and keyboard accessibility.
open class MiniPlayerView: GlassMiniPlayer {

    public var onPlayPause: (() -> Void)?
    public var onStop: (() -> Void)?
    public var onNext: (() -> Void)?
    public var onPrevious: (() -> Void)?
    public var onExpand: (() -> Void)?
    public var onToggleLyrics: (() -> Void)?
    public var onToggleLibrary: (() -> Void)?
    public var onToggleFavorite: (() -> Void)?
    public var onToggleSource: (() -> Void)?
    public var onQuit: (() -> Void)?

    private let miniMotionID = "MiniPlayerView-\(UUID().uuidString)"

    // Idle state views + persistent time readout
    private let idleContainer = NSView()
    private let carouselView = CarouselHaloTextView()
    private let timeView = TimeFontDisplayView()

    // Hover state views
    private let haloHostLayer = CALayer()
    private let controlsContainer = MiniHoverControlsContainer()
    private let stopButton = GlassButton(image: nil, size: CGSize(width: 16, height: 16), enableLiquidGlassHover: false)
    private let prevButton = GlassButton(image: nil, size: CGSize(width: 16, height: 16), enableLiquidGlassHover: false)
    private let playPauseButton = GlassButton(image: nil, size: CGSize(width: 16, height: 16), enableLiquidGlassHover: false)
    private let nextButton = GlassButton(image: nil, size: CGSize(width: 16, height: 16), enableLiquidGlassHover: false)
    private let ejectButton = GlassButton(image: nil, size: CGSize(width: 16, height: 16), enableLiquidGlassHover: false)

    private let miniSourceButton = GlassButton(image: nil, size: CGSize(width: 13, height: 13), buttonStyle: .glassBar)
    private let libraryButton = GlassButton(image: nil, size: CGSize(width: 13, height: 13), buttonStyle: .glassBar)
    private var currentFavoriteState: Bool?
    private let lyricsButton = GlassButton(image: nil, size: CGSize(width: 13, height: 13), buttonStyle: .glassBar)
    private let expandButton = GlassButton(image: nil, size: CGSize(width: 13, height: 13), buttonStyle: .glassBar)
    private let quitButton = GlassButton(image: nil, size: CGSize(width: 13, height: 13), buttonStyle: .glassBar)

    private var isPlayingState: Bool = false
    private var showRemainingTime: Bool = false
    private var lastPositionMs: Int64 = 0
    private var lastDurationMs: Int64 = 0
    private var isHovering: Bool = false
    private var isKeyboardControlsActive: Bool = false
    private var trackingArea: NSTrackingArea?
    private var cachedHaloSize: CGSize = .zero

    public var isHoverControlsInteractive: Bool {
        controlsContainer.allowsHitTesting
    }

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupMiniViews()
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupMiniViews()
    }

    isolated deinit {
        if let obs = resignKeyObserver {
            NotificationCenter.default.removeObserver(obs)
            resignKeyObserver = nil
        }
        MotionCoordinator.shared.cancelAll(owner: miniMotionID)
        NotificationCenter.default.removeObserver(self)
    }

    private func setupMiniViews() {
        idleContainer.wantsLayer = true
        idleContainer.alphaValue = 1.0
        addSubview(idleContainer)

        carouselView.cycleIntervalSeconds = 10
        idleContainer.addSubview(carouselView)

        // M04: Keep time visible in its own non-overlapping left slot and clickable to toggle remaining time
        haloHostLayer.masksToBounds = false
        haloHostLayer.opacity = 0.0
        layer?.insertSublayer(haloHostLayer, at: 0)

        controlsContainer.wantsLayer = true
        controlsContainer.alphaValue = 0.0
        controlsContainer.allowsHitTesting = false
        addSubview(controlsContainer)

        timeView.alignment = .left
        let click = NSClickGestureRecognizer(target: self, action: #selector(toggleTimeMode))
        timeView.addGestureRecognizer(click)
        addSubview(timeView)

        stopButton.toolTip = "停止"
        prevButton.toolTip = "上一首"
        playPauseButton.toolTip = "播放 / 暂停"
        nextButton.toolTip = "下一首"
        ejectButton.toolTip = "收藏当前曲目"

        stopButton.onClick = { [weak self] in self?.onStop?() }
        prevButton.onClick = { [weak self] in self?.onPrevious?() }
        playPauseButton.onClick = { [weak self] in self?.onPlayPause?() }
        nextButton.onClick = { [weak self] in self?.onNext?() }
        ejectButton.onClick = { [weak self] in self?.onToggleFavorite?() }

        controlsContainer.addSubview(stopButton)
        controlsContainer.addSubview(prevButton)
        controlsContainer.addSubview(playPauseButton)
        controlsContainer.addSubview(nextButton)
        controlsContainer.addSubview(ejectButton)

        miniSourceButton.toolTip = "当前播放源 (点击切换或查看资料库)"
        miniSourceButton.onClick = { [weak self] in
            if let onToggleSource = self?.onToggleSource {
                onToggleSource()
            } else {
                self?.onToggleLibrary?()
            }
        }
        controlsContainer.addSubview(miniSourceButton)

        libraryButton.toolTip = "显示/隐藏资料库"
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
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(skinSettingsChanged),
            name: MotionAccessibility.preferencesDidChangeNotification,
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
        let s = GlassInteractionCoordinator.shared.uiScale

        stopButton.setSymbol(name: "square.fill", pointSize: 8.5 * s, weight: .bold)
        prevButton.setSymbol(name: "backward.fill", pointSize: 9.0 * s, weight: .bold)
        playPauseButton.setSymbol(name: isPlayingState ? "pause.fill" : "play.fill", pointSize: 10.5 * s, weight: .bold)
        nextButton.setSymbol(name: "forward.fill", pointSize: 9.0 * s, weight: .bold)
        applyFavoriteSymbol(scale: s)

        miniSourceButton.setSymbol(name: "apple.logo", pointSize: 9.5 * s, weight: .bold)
        libraryButton.setSymbol(name: "books.vertical.fill", pointSize: 8.5 * s, weight: .semibold)
        lyricsButton.setSymbol(name: "text.quote", pointSize: 8.5 * s, weight: .bold)
        expandButton.setSymbol(name: "rectangle.expand.vertical", pointSize: 8.0 * s, weight: .bold)
        quitButton.setSymbol(name: "xmark", pointSize: 8.0 * s, weight: .bold)
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

    private var resignKeyObserver: NSObjectProtocol?

    open override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let obs = resignKeyObserver {
            NotificationCenter.default.removeObserver(obs)
            resignKeyObserver = nil
        }
        if let win = window {
            resignKeyObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didResignKeyNotification,
                object: win,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.setKeyboardControlsFocused(false)
                }
            }
        }
    }

    open override func viewDidHide() {
        super.viewDidHide()
        setHovering(false, immediate: true)
        setKeyboardControlsFocused(false)
    }

    /// M04: Keyboard focus lock allows full Mini bar navigation via keyboard without hovering.
    public func setKeyboardControlsFocused(_ focused: Bool) {
        guard isKeyboardControlsActive != focused else { return }
        isKeyboardControlsActive = focused
        refreshHoverPresentation(immediate: false)
    }

    open override var acceptsFirstResponder: Bool { true }

    open override func keyDown(with event: NSEvent) {
        guard !event.isARepeat else { return }
        switch event.keyCode {
        case 48, 125, 126: // Tab / Down / Up -> enter keyboard control focus
            setKeyboardControlsFocused(true)
            window?.makeFirstResponder(playPauseButton)
        case 49: // Space
            onPlayPause?()
        case 53: // Esc
            setKeyboardControlsFocused(false)
        case 123: // Left arrow
            onPrevious?()
        case 124: // Right arrow
            onNext?()
        default:
            super.keyDown(with: event)
        }
    }

    public func setHovering(_ hovering: Bool, immediate: Bool = false) {
        guard isHovering != hovering else { return }
        isHovering = hovering
        refreshHoverPresentation(immediate: immediate)
    }

    private func refreshHoverPresentation(immediate: Bool) {
        let active = isHovering || isKeyboardControlsActive
        let targetIdle: CGFloat = active ? 0.0 : 1.0
        let targetCtrl: CGFloat = active ? 1.0 : 0.0
        let targetHalo: Float = active ? 1.0 : 0.0

        carouselView.setPaused(active)
        controlsContainer.allowsHitTesting = active

        let key = TransitionKey(owner: miniMotionID, channel: "hover")
        let haloKey = TransitionKey(owner: miniMotionID, channel: "haloOpacity")
        let ticket = MotionCoordinator.shared.beginTransition(for: key, category: .controlInteraction)

        if immediate || MotionCoordinator.shared.isReduceMotionEnabled {
            MotionCoordinator.shared.cancel(key: haloKey)
            idleContainer.alphaValue = targetIdle
            controlsContainer.alphaValue = targetCtrl
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            haloHostLayer.opacity = targetHalo
            CATransaction.commit()
            _ = MotionCoordinator.shared.complete(ticket)
            return
        }

        MotionCoordinator.shared.animate(
            duration: MotionTokens.Duration.hoverFade,
            timingFunction: .easeInEaseOut,
            ticket: ticket,
            action: {
                self.idleContainer.animator().alphaValue = targetIdle
                self.controlsContainer.animator().alphaValue = targetCtrl
            }
        )
        let haloTicket = MotionCoordinator.shared.beginTransition(for: haloKey, category: .controlInteraction)
        MotionCoordinator.shared.animateLayerFloat(
            haloHostLayer,
            keyPath: "opacity",
            animationKey: "haloOpacity",
            to: CGFloat(targetHalo),
            duration: MotionTokens.Duration.hoverFade,
            timingFunction: .easeInEaseOut,
            ticket: haloTicket,
            setModel: { $0.opacity = Float($1) }
        )
    }

    open override func layout() {
        super.layout()
        let s = GlassInteractionCoordinator.shared.uiScale
        let w = bounds.width
        let h = bounds.height

        idleContainer.frame = bounds
        controlsContainer.frame = bounds
        haloHostLayer.frame = bounds

        if cachedHaloSize != bounds.size {
            cachedHaloSize = bounds.size
            updateHaloLayer(w: w, h: h, s: s)
        }

        // M04: Non-overlapping left time slot + centered carousel
        let timeW = 35.0 * s
        let timeH = 11.0 * s
        timeView.isHidden = false
        timeView.frame = NSRect(x: 8.0 * s, y: (h - timeH) * 0.5, width: timeW, height: timeH)

        let textLeft = 46.0 * s
        carouselView.frame = NSRect(x: textLeft, y: 0, width: max(20, w - textLeft * 2.0), height: h)

        // Hover: centered 5 buttons (16×16 @ 1x) inside compact glass capsule + left source button + right window buttons
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
        miniSourceButton.frame = NSRect(x: 45.0 * s, y: wbY, width: wbSize, height: wbSize)

        libraryButton.frame = NSRect(x: w - 93.0 * s, y: wbY, width: wbSize, height: wbSize)
        lyricsButton.frame = NSRect(x: w - 77.0 * s, y: wbY, width: wbSize, height: wbSize)
        expandButton.frame = NSRect(x: w - 61.0 * s, y: wbY, width: wbSize, height: wbSize)
        quitButton.frame = NSRect(x: w - 45.0 * s, y: wbY, width: wbSize, height: wbSize)
    }

    public func setFavoriteState(isFavorited: Bool?, isPending: Bool = false, isEnabled: Bool = true) {
        currentFavoriteState = isFavorited
        ejectButton.isEnabled = isEnabled && !isPending
        ejectButton.alphaValue = isEnabled ? (isPending ? 0.65 : 1.0) : 0.45
        ejectButton.toolTip = isPending ? "正在同步收藏状态…" : (isFavorited == true ? "已收藏当前曲目（点击取消）" : "收藏当前曲目")
        applyFavoriteSymbol(scale: GlassInteractionCoordinator.shared.uiScale)
    }

    private func applyFavoriteSymbol(scale s: CGFloat) {
        let symbolName = (currentFavoriteState == true) ? "star.fill" : "star"
        ejectButton.setSymbol(name: symbolName, pointSize: 9.0 * s, weight: .bold)
        ejectButton.isHighlightedState = (currentFavoriteState == true)
    }

    private func updateHaloLayer(w: CGFloat, h: CGFloat, s: CGFloat) {
        guard w > 20, h > 10 else { return }
        let scale = window?.backingScaleFactor ?? 2.0
        let pxW = max(1, Int(round(w * scale)))
        let pxH = max(1, Int(round(h * scale)))
        let cs = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil,
            width: pxW,
            height: pxH,
            bitsPerComponent: 8,
            bytesPerRow: pxW * 4,
            space: cs,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return }

        ctx.scaleBy(x: scale, y: scale)
        ctx.clear(CGRect(x: 0, y: 0, width: w, height: h))

        OriginalGlassRenderer.drawTextHalo(
            in: ctx,
            center: CGPoint(x: w * 0.5, y: h * 0.5),
            rx: 68.0 * s,
            ry: 14.0 * s,
            centerAlpha: 135.0 / 255.0
        )
        OriginalGlassRenderer.drawTextHalo(
            in: ctx,
            center: CGPoint(x: w - 61.0 * s, y: h * 0.5),
            rx: 38.0 * s,
            ry: 14.0 * s,
            centerAlpha: 135.0 / 255.0
        )
        OriginalGlassRenderer.drawTextHalo(
            in: ctx,
            center: CGPoint(x: 51.5 * s, y: h * 0.5),
            rx: 20.0 * s,
            ry: 14.0 * s,
            centerAlpha: 135.0 / 255.0
        )

        if let haloImg = ctx.makeImage() {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            haloHostLayer.contents = haloImg
            CATransaction.commit()
        }
    }

    public func updateState(_ state: PlaybackState) {
        let effectivePlaying = (state.status == .playing)
        let playChanged = (isPlayingState != effectivePlaying)
        isPlayingState = effectivePlaying
        lastPositionMs = state.estimatedPositionMs
        lastDurationMs = state.durationMs

        let s = GlassInteractionCoordinator.shared.uiScale
        if playChanged {
            playPauseButton.transitionToSymbol(
                name: effectivePlaying ? "pause.fill" : "play.fill",
                pointSize: 10.5 * s,
                weight: .bold
            )
        }

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
