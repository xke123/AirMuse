import AppKit
import Domain
import DesignSystem
import Playback
import Infrastructure

// MARK: - CapsuleProgressView

/// Custom-drawn AIRPLAY capsule progress bar with hover highlight, drag scrubbing,
/// and localized Liquid Glass hover feedback in Enhanced mode.
@MainActor
final class CapsuleProgressView: NSView {
    var ratio: CGFloat = 0 { didSet { needsDisplay = true } }
    var isHighlighted: Bool = false { didSet { needsDisplay = true; liquidHover.isActive = isHighlighted || isScrubbing } }
    var isScrubbing: Bool = false { didSet { needsDisplay = true; liquidHover.isActive = isHighlighted || isScrubbing } }
    var onSeek: ((CGFloat) -> Void)?
    var onScrubbingChanged: ((Bool, CGFloat) -> Void)?

    private let liquidHover = LiquidGlassControl()
    private var trackingArea: NSTrackingArea?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        liquidHover.cornerRadius = 5.0
        addSubview(liquidHover)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        let barH = max(5.0, bounds.height * 0.45)
        liquidHover.frame = NSRect(x: 0, y: (bounds.height - barH) * 0.5 - 2, width: bounds.width, height: barH + 4)
        liquidHover.cornerRadius = liquidHover.bounds.height * 0.5
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = trackingArea { removeTrackingArea(existing) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        isHighlighted = true
    }

    override func mouseExited(with event: NSEvent) {
        if !isScrubbing { isHighlighted = false }
    }

    override func mouseDown(with event: NSEvent) {
        isScrubbing = true
        let r = ratioFrom(event: event)
        ratio = r
        onScrubbingChanged?(true, r)
    }

    override func mouseDragged(with event: NSEvent) {
        guard isScrubbing else { return }
        let r = ratioFrom(event: event)
        ratio = r
        onScrubbingChanged?(true, r)
    }

    override func mouseUp(with event: NSEvent) {
        guard isScrubbing else { return }
        let r = ratioFrom(event: event)
        ratio = r
        isScrubbing = false
        onScrubbingChanged?(false, r)
        onSeek?(r)
    }

    private func ratioFrom(event: NSEvent) -> CGFloat {
        let pt = convert(event.locationInWindow, from: nil)
        guard bounds.width > 0 else { return 0 }
        return min(max(pt.x / bounds.width, 0), 1)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let barH = max(5.0, bounds.height * 0.43)
        let barRect = CGRect(x: 0, y: (bounds.height - barH) * 0.5, width: bounds.width, height: barH)
        OriginalControlRenderer.drawCapsuleProgress(in: ctx, rect: barRect, ratio: ratio, isHighlighted: isHighlighted, isScrubbing: isScrubbing)
    }
}

// MARK: - VolumeSegmentsView

/// 8-segment vertical volume meter matching AIRPLAY's right-edge volume control.
@MainActor
final class VolumeSegmentsView: NSView {
    var volume: Float = 1.0 { didSet { needsDisplay = true } }
    var onVolumeChanged: ((Float) -> Void)?

    private let liquidHover = LiquidGlassControl()
    private var trackingArea: NSTrackingArea?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        liquidHover.cornerRadius = 4.0
        addSubview(liquidHover)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        liquidHover.frame = bounds
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = trackingArea { removeTrackingArea(existing) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        liquidHover.isActive = true
    }

    override func mouseExited(with event: NSEvent) {
        liquidHover.isActive = false
    }

    override func mouseDown(with event: NSEvent) {
        updateVolume(from: event)
    }

    override func mouseDragged(with event: NSEvent) {
        updateVolume(from: event)
    }

    override func scrollWheel(with event: NSEvent) {
        let delta: Float = event.scrollingDeltaY > 0 ? 0.05 : -0.05
        let next = min(max(volume + delta, 0), 1)
        volume = next
        onVolumeChanged?(next)
    }

    private func updateVolume(from event: NSEvent) {
        let pt = convert(event.locationInWindow, from: nil)
        guard bounds.height > 0 else { return }
        let next = Float(min(max(pt.y / bounds.height, 0), 1))
        volume = next
        onVolumeChanged?(next)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let s = GlassInteractionCoordinator.shared.uiScale
        let origin = CGPoint(x: (bounds.width - 7.0 * s) * 0.5, y: 3.0 * s)
        OriginalControlRenderer.drawVolumeSegments(in: ctx, origin: origin, uiScale: s, volume: volume, alpha: alphaValue)
    }
}

// MARK: - TimeFontDisplayView

/// Renders MM:SS using original `TIMEFONT` bitmap digits (6×7 @ 1×, 7px step).
@MainActor
final class TimeFontDisplayView: NSView {
    var timeString: String = "00:00" {
        didSet {
            if oldValue != timeString { needsDisplay = true }
        }
    }
    var alignment: NSTextAlignment = .left

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let s = GlassInteractionCoordinator.shared.uiScale
        let totalW = CGFloat(timeString.count) * OriginalDesignTokens.BaseMetrics.timeFontCharStep * s
        let startX: CGFloat = alignment == .right ? max(0, bounds.width - totalW) : 0
        let y = (bounds.height - OriginalDesignTokens.BaseMetrics.timeFontCharHeight * s) * 0.5
        PixelFontRenderer.drawTimeFont(in: ctx, text: timeString, origin: CGPoint(x: startX, y: y), uiScale: s, alpha: 0.86)
    }
}

// MARK: - StreamLoadingBarView

/// Animated capsule loading indicator shown in the progress-bar slot while audio stream is loading.
@MainActor
final class StreamLoadingBarView: NSView {
    var statusText: String = "正在加载歌曲…" {
        didSet {
            if oldValue != statusText { needsDisplay = true }
        }
    }
    private var phase: CGFloat = 0
    private var animTask: Task<Void, Never>?
    private var isAnimating: Bool = false

    deinit {
        animTask?.cancel()
    }

    func startAnimating() {
        guard !isAnimating else { return }
        isAnimating = true
        if MotionCoordinator.shared.isReduceMotionEnabled {
            phase = 0.5
            needsDisplay = true
            return
        }
        animTask?.cancel()
        animTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(33))
                guard !Task.isCancelled, let self, self.isAnimating else { break }
                self.phase += 0.032
                if self.phase > 1.35 { self.phase = -0.35 }
                self.needsDisplay = true
            }
        }
    }

    func stopAnimating() {
        isAnimating = false
        animTask?.cancel()
        animTask = nil
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let s = GlassInteractionCoordinator.shared.uiScale
        let w = bounds.width
        let h = bounds.height
        guard w > 12, h > 4 else { return }

        let barH = max(5.0, h * 0.43)
        let barRect = CGRect(x: 0, y: (h - barH) * 0.5, width: w, height: barH)
        let radius = barH * 0.5
        let path = CGPath(roundedRect: barRect, cornerWidth: radius, cornerHeight: radius, transform: nil)

        ctx.saveGState()
        ctx.addPath(path)
        ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.11))
        ctx.fillPath()

        ctx.addPath(path)
        ctx.clip()

        let segW = max(36.0 * s, w * 0.34)
        let centerX = phase * w
        let gradStart = CGPoint(x: centerX - segW * 0.5, y: barRect.midY)
        let gradEnd = CGPoint(x: centerX + segW * 0.5, y: barRect.midY)
        let cs = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let colors = [
            CGColor(srgbRed: 130/255.0, green: 215/255.0, blue: 255/255.0, alpha: 0.0),
            CGColor(srgbRed: 130/255.0, green: 215/255.0, blue: 255/255.0, alpha: 0.55),
            CGColor(srgbRed: 245/255.0, green: 250/255.0, blue: 255/255.0, alpha: 0.85),
            CGColor(srgbRed: 130/255.0, green: 215/255.0, blue: 255/255.0, alpha: 0.55),
            CGColor(srgbRed: 130/255.0, green: 215/255.0, blue: 255/255.0, alpha: 0.0)
        ] as CFArray
        let locs: [CGFloat] = [0.0, 0.25, 0.5, 0.75, 1.0]
        if let grad = CGGradient(colorsSpace: cs, colors: colors, locations: locs) {
            ctx.drawLinearGradient(grad, start: gradStart, end: gradEnd, options: [])
        }
        ctx.restoreGState()

        ctx.saveGState()
        ctx.addPath(path)
        ctx.setStrokeColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.20))
        ctx.setLineWidth(0.6)
        ctx.strokePath()
        ctx.restoreGState()

        let label = statusText
        let font = NSFont.systemFont(ofSize: 9.0 * s, weight: .medium)
        let attr = PixelFontRenderer.makeHaloAttributedString(
            label,
            font: font,
            color: OriginalDesignTokens.Colors.highlightSilver,
            alignment: .center,
            alpha: 0.92
        )
        let strSize = attr.size()
        let textRect = NSRect(x: (w - strSize.width) * 0.5, y: (h - strSize.height) * 0.5, width: strSize.width, height: strSize.height)
        attr.draw(in: textRect)
    }
}

// MARK: - PlayerView

/// 1:1 restoration of the AIRPLAY-zion floating main player (330×106 @ 1×, 495×159 @ 1.5×).
/// Uses authentic 9-slice crystal glass frame, original MAINCONTROL / WINDOWBUTTON sprite atlases,
/// TIMEFONT digital clock, capsule progress bar, 8-segment volume meter, and specular lens-flare sweeps.
open class PlayerView: GlassSurface {

    public var onPlayPause: (() -> Void)?
    public var onStop: (() -> Void)?
    public var onNext: (() -> Void)?
    public var onPrevious: (() -> Void)?
    public var onSeek: ((Int64) -> Void)?
    public var onVolumeChanged: ((Float) -> Void)?
    public var onToggleMiniMode: (() -> Void)?
    public var onToggleTopMost: (() -> Void)?
    public var onToggleLyrics: (() -> Void)?
    public var onToggleLibrary: (() -> Void)?
    public var onMinimize: (() -> Void)?
    public var onQuit: (() -> Void)?
    public var onSelectAppleMusic: (() -> Void)?
    public var onSelectSpotify: (() -> Void)?
    public var onSelectQQMusic: (() -> Void)?

    public var currentPlatform: Int = 0 {
        didSet {
            updatePlatformHighlight()
        }
    }

    public var isTopMost: Bool = true {
        didSet {
            let s = GlassInteractionCoordinator.shared.uiScale
            topMostButton.setSymbol(name: isTopMost ? "pin.fill" : "pin", pointSize: 9.0 * s, weight: .semibold)
        }
    }

    // Left Column (Always-visible Album Artwork)
    private let artworkContainer = NSView()
    private let artworkView = NSImageView()
    private let artworkHoverGlass = LiquidGlassControl()

    // Right Column Upper (Idle): Track info
    private let idleContainer = NSView()
    private let titleLabel = NSTextField(labelWithString: "AirMuse Ready")
    private let artistLabel = NSTextField(labelWithString: "Waiting for playback…")

    // Hover control views
    private let controlsContainer = NSView()
    private let topAuroraFogView = AuroraGlassFogView()
    private let bottomAuroraFogView = AuroraGlassFogView()
    private let stopButton = GlassButton(image: nil, size: CGSize(width: 32, height: 32), enableLiquidGlassHover: true)
    private let prevButton = GlassButton(image: nil, size: CGSize(width: 32, height: 32), enableLiquidGlassHover: true)
    private let playPauseButton = GlassButton(image: nil, size: CGSize(width: 32, height: 32), enableLiquidGlassHover: true)
    private let nextButton = GlassButton(image: nil, size: CGSize(width: 32, height: 32), enableLiquidGlassHover: true)
    private let ejectButton = GlassButton(image: nil, size: CGSize(width: 32, height: 32), enableLiquidGlassHover: true)

    // Window buttons (Top Glass Bar)
    private let glassStyleButton = GlassButton(image: nil, size: CGSize(width: 13, height: 13), buttonStyle: .glassBar)
    private let minimizeButton = GlassButton(image: nil, size: CGSize(width: 13, height: 13), buttonStyle: .glassBar)
    private let miniModeButton = GlassButton(image: nil, size: CGSize(width: 13, height: 13), buttonStyle: .glassBar)
    private let topMostButton = GlassButton(image: nil, size: CGSize(width: 13, height: 13), buttonStyle: .glassBar)
    private let quitButton = GlassButton(image: nil, size: CGSize(width: 13, height: 13), buttonStyle: .glassBar)

    // Panel & Source buttons (Bottom Glass Bar)
    private let appleMusicButton = GlassButton(image: nil, size: CGSize(width: 13, height: 13), buttonStyle: .glassBar)
    private let spotifyButton = GlassButton(image: nil, size: CGSize(width: 13, height: 13), buttonStyle: .glassBar)
    private let qqMusicButton = GlassButton(image: nil, size: CGSize(width: 13, height: 13), buttonStyle: .glassBar)
    private let libraryButton = GlassButton(image: nil, size: CGSize(width: 13, height: 13), buttonStyle: .glassBar)
    private let lyricsButton = GlassButton(image: nil, size: CGSize(width: 13, height: 13), buttonStyle: .glassBar)

    // Always-visible body progress & time (replaced by dynamic loading bar while awaiting audio stream)
    private let streamLoadingView = StreamLoadingBarView()
    private let progressView = CapsuleProgressView()
    private let currentTimeView = TimeFontDisplayView()
    private let durationTimeView = TimeFontDisplayView()
    private let volumeView = VolumeSegmentsView()

    // State
    private var currentDurationMs: Int64 = 0
    private var isScrubbing: Bool = false
    private var isPlayingState: Bool = false
    private var isHoveringPanel: Bool = false
    private var currentArtworkTrackKey: String?
    private var artworkLoadTask: Task<Void, Never>?
    private var trackingArea: NSTrackingArea?

    // Specular sweep tracking
    private var lastMouseY: CGFloat?
    private var lastMouseMoveTime: TimeInterval = 0
    private var lastMidCrossDir: Int = 0
    private var topBoundaryTriggered: Bool = false
    private var botBoundaryTriggered: Bool = false

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupViews()
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupViews()
    }

    private func setupViews() {
        hasMainGloss = true
        cornerRadius = OriginalDesignTokens.BaseMetrics.glassCornerRadius

        // Left Column: Always-visible Album Artwork
        artworkContainer.wantsLayer = true
        artworkContainer.layer?.masksToBounds = false
        addSubview(artworkContainer)

        artworkHoverGlass.cornerRadius = 5.0
        artworkContainer.addSubview(artworkHoverGlass)

        artworkView.wantsLayer = true
        artworkView.layer?.cornerRadius = 5.0
        artworkView.layer?.masksToBounds = true
        artworkView.layer?.backgroundColor = NSColor(white: 1.0, alpha: 0.06).cgColor
        artworkView.layer?.borderWidth = 0.5
        artworkView.layer?.borderColor = NSColor(white: 1.0, alpha: 0.16).cgColor
        artworkView.imageScaling = .scaleProportionallyUpOrDown
        artworkView.image = NSImage(systemSymbolName: "music.note", accessibilityDescription: "Album Art")
        artworkView.contentTintColor = OriginalDesignTokens.Colors.subSilver
        artworkContainer.addSubview(artworkView)

        // Right Column Upper (Idle): Track info
        idleContainer.wantsLayer = true
        idleContainer.alphaValue = 1.0
        addSubview(idleContainer)

        titleLabel.textColor = OriginalDesignTokens.Colors.titleSilver
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.alignment = .center
        idleContainer.addSubview(titleLabel)

        artistLabel.textColor = OriginalDesignTokens.Colors.subSilver
        artistLabel.lineBreakMode = .byTruncatingTail
        artistLabel.alignment = .center
        idleContainer.addSubview(artistLabel)

        // Hover controls container
        controlsContainer.wantsLayer = true
        controlsContainer.alphaValue = 0.0
        addSubview(controlsContainer)

        topAuroraFogView.seamEdge = .bottom
        bottomAuroraFogView.seamEdge = .top
        controlsContainer.addSubview(topAuroraFogView)
        controlsContainer.addSubview(bottomAuroraFogView)

        stopButton.enableDarkHalo = true
        prevButton.enableDarkHalo = true
        playPauseButton.enableDarkHalo = true
        nextButton.enableDarkHalo = true
        ejectButton.enableDarkHalo = true

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

        volumeView.onVolumeChanged = { [weak self] vol in self?.onVolumeChanged?(vol) }
        controlsContainer.addSubview(volumeView)

        // Top glass bar buttons
        glassStyleButton.enableDarkHalo = false
        glassStyleButton.onClick = {
            GlassInteractionCoordinator.shared.useFrostedBarsInNormalMode.toggle()
        }
        controlsContainer.addSubview(glassStyleButton)

        minimizeButton.enableDarkHalo = false
        minimizeButton.toolTip = "最小化"
        minimizeButton.onClick = { [weak self] in
            if let onMinimize = self?.onMinimize { onMinimize() } else { self?.window?.miniaturize(nil) }
        }
        miniModeButton.enableDarkHalo = false
        miniModeButton.toolTip = "切换迷你模式"
        miniModeButton.onClick = { [weak self] in self?.onToggleMiniMode?() }
        topMostButton.enableDarkHalo = false
        topMostButton.toolTip = "总在最前"
        topMostButton.onClick = { [weak self] in self?.onToggleTopMost?() }
        quitButton.enableDarkHalo = false
        quitButton.toolTip = "退出 AirMuse"
        quitButton.onClick = { [weak self] in
            if let onQuit = self?.onQuit { onQuit() } else { NSApp.terminate(nil) }
        }

        controlsContainer.addSubview(minimizeButton)
        controlsContainer.addSubview(miniModeButton)
        controlsContainer.addSubview(topMostButton)
        controlsContainer.addSubview(quitButton)

        // Bottom glass bar buttons
        appleMusicButton.enableDarkHalo = false
        appleMusicButton.toolTip = "Apple Music"
        appleMusicButton.onClick = { [weak self] in
            self?.currentPlatform = 0
            self?.onSelectAppleMusic?()
        }
        controlsContainer.addSubview(appleMusicButton)

        spotifyButton.enableDarkHalo = false
        spotifyButton.toolTip = "Spotify"
        spotifyButton.onClick = { [weak self] in
            self?.currentPlatform = 1
            self?.onSelectSpotify?()
        }
        controlsContainer.addSubview(spotifyButton)

        qqMusicButton.enableDarkHalo = false
        qqMusicButton.toolTip = "QQ 音乐"
        qqMusicButton.onClick = { [weak self] in
            self?.currentPlatform = 2
            self?.onSelectQQMusic?()
        }
        controlsContainer.addSubview(qqMusicButton)

        libraryButton.enableDarkHalo = false
        libraryButton.toolTip = "音乐资料库"
        libraryButton.onClick = { [weak self] in self?.onToggleLibrary?() }
        lyricsButton.enableDarkHalo = false
        lyricsButton.toolTip = "桌面歌词"
        lyricsButton.onClick = { [weak self] in self?.onToggleLyrics?() }
        controlsContainer.addSubview(libraryButton)
        controlsContainer.addSubview(lyricsButton)

        // Progress & Time
        progressView.onScrubbingChanged = { [weak self] scrubbing, ratio in
            guard let self else { return }
            self.isScrubbing = scrubbing
            if self.currentDurationMs > 0 {
                let ms = Int64(Double(ratio) * Double(self.currentDurationMs))
                self.currentTimeView.timeString = self.formatTime(ms: ms)
            }
        }
        progressView.onSeek = { [weak self] ratio in
            guard let self, self.currentDurationMs > 0 else { return }
            let targetMs = Int64(Double(ratio) * Double(self.currentDurationMs))
            self.onSeek?(targetMs)
        }
        streamLoadingView.isHidden = true
        addSubview(streamLoadingView)
        addSubview(progressView)

        currentTimeView.alignment = .right
        durationTimeView.alignment = .left
        addSubview(currentTimeView)
        addSubview(durationTimeView)

        reloadSprites()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(skinSettingsChanged),
            name: GlassInteractionCoordinator.modeDidChangeNotification,
            object: nil
        )
    }

    @objc private func skinSettingsChanged() {
        reloadSprites()
        needsLayout = true
        refreshGlassSurface()
    }

    private func reloadSprites() {
        let s = GlassInteractionCoordinator.shared.uiScale

        stopButton.setSymbol(name: "square.fill", pointSize: 13.0 * s, weight: .bold)
        prevButton.setSymbol(name: "backward.fill", pointSize: 13.5 * s, weight: .bold)
        playPauseButton.setSymbol(name: isPlayingState ? "pause.fill" : "play.fill", pointSize: 16.5 * s, weight: .bold)
        nextButton.setSymbol(name: "forward.fill", pointSize: 13.5 * s, weight: .bold)
        ejectButton.setSymbol(name: "eject.fill", pointSize: 12.0 * s, weight: .bold)

        let frosted = GlassInteractionCoordinator.shared.useFrostedBarsInNormalMode
        let styleSymbol = frosted ? "sparkles.rectangle.stack" : "square.on.square"
        glassStyleButton.setSymbol(name: styleSymbol, pointSize: 9.0 * s, weight: .medium)
        glassStyleButton.toolTip = frosted ? "切换玻璃条样式（当前：磨砂模糊 / 点击切回原版）" : "切换玻璃条样式（当前：原版玻璃 / 点击切为磨砂）"

        minimizeButton.setSymbol(name: "minus", pointSize: 9.0 * s, weight: .bold)
        miniModeButton.setSymbol(name: "rectangle.compress.vertical", pointSize: 8.5 * s, weight: .bold)
        topMostButton.setSymbol(name: isTopMost ? "pin.fill" : "pin", pointSize: 9.0 * s, weight: .semibold)
        quitButton.setSymbol(name: "xmark", pointSize: 8.5 * s, weight: .bold)

        appleMusicButton.setSymbol(name: "apple.logo", pointSize: 10.0 * s, weight: .bold)
        spotifyButton.setSymbol(name: "dot.radiowaves.left.and.right", pointSize: 9.0 * s, weight: .semibold)
        qqMusicButton.setSymbol(name: "waveform", pointSize: 9.0 * s, weight: .semibold)

        libraryButton.setSymbol(name: "books.vertical.fill", pointSize: 9.0 * s, weight: .semibold)
        lyricsButton.setSymbol(name: "text.quote", pointSize: 9.0 * s, weight: .bold)

        updatePlatformHighlight()
    }

    private func updatePlatformHighlight() {
        appleMusicButton.isHighlightedState = (currentPlatform == 0)
        spotifyButton.isHighlightedState = (currentPlatform == 1)
        qqMusicButton.isHighlightedState = (currentPlatform == 2)
    }

    open override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = trackingArea { removeTrackingArea(existing) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    open override func mouseEntered(with event: NSEvent) {
        setHovering(true)
    }

    open override func mouseExited(with event: NSEvent) {
        setHovering(false)
        lastMouseY = nil
        lastMouseMoveTime = 0
        lastMidCrossDir = 0
        topBoundaryTriggered = false
        botBoundaryTriggered = false
    }

    open override func mouseMoved(with event: NSEvent) {
        let pt = convert(event.locationInWindow, from: nil)
        let s = GlassInteractionCoordinator.shared.uiScale
        let h = bounds.height
        let midY = h * 0.5
        let capH = OriginalDesignTokens.BaseMetrics.glassCapHeight * s
        let botGlassBoundary = capH
        let topGlassBoundary = h - capH

        let now = ProcessInfo.processInfo.systemUptime
        let dt = lastMouseMoveTime > 0 ? max(0.001, min(0.1, now - lastMouseMoveTime)) : 0.016
        lastMouseMoveTime = now

        if let prevY = lastMouseY, h > 40 * s {
            let dy = pt.y - prevY
            let speedY = abs(dy) / CGFloat(dt)
            let isFast = speedY > MotionTokens.Thresholds.fastMoveVelocity * s || abs(dy) >= 14.0 * s

            // Midline crossing (note AppKit y increases upward)
            if prevY > midY && pt.y <= midY {
                if lastMidCrossDir != 1 {
                    if !isFast { triggerSpecularSweep(from: 0.5, to: 1.0) }
                    lastMidCrossDir = 1
                }
            } else if prevY < midY && pt.y >= midY {
                if lastMidCrossDir != -1 {
                    if !isFast { triggerSpecularSweep(from: 0.5, to: 0.0) }
                    lastMidCrossDir = -1
                }
            }

            // Glass bar boundary bounce sweeps
            if !botBoundaryTriggered && dy < 0 && pt.y <= botGlassBoundary {
                triggerSpecularSweep(from: 1.0, to: 0.0)
                botBoundaryTriggered = true
            } else if !topBoundaryTriggered && dy > 0 && pt.y >= topGlassBoundary {
                triggerSpecularSweep(from: 0.0, to: 1.0)
                topBoundaryTriggered = true
            }

            if botBoundaryTriggered && pt.y > botGlassBoundary + MotionTokens.Thresholds.boundaryResetMargin * s {
                botBoundaryTriggered = false
            }
            if topBoundaryTriggered && pt.y < topGlassBoundary - MotionTokens.Thresholds.boundaryResetMargin * s {
                topBoundaryTriggered = false
            }
        }
        lastMouseY = pt.y
    }

    private func setHovering(_ hovering: Bool) {
        guard isHoveringPanel != hovering else { return }
        isHoveringPanel = hovering
        let targetIdle: CGFloat = hovering ? 0.0 : 1.0
        let targetCtrl: CGFloat = hovering ? 1.0 : 0.0
        artworkHoverGlass.isActive = hovering

        if MotionCoordinator.shared.isReduceMotionEnabled {
            idleContainer.alphaValue = targetIdle
            controlsContainer.alphaValue = targetCtrl
            artworkView.layer?.borderColor = NSColor(white: 1.0, alpha: hovering ? 0.36 : 0.16).cgColor
        } else {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = MotionTokens.Duration.hoverFade
                idleContainer.animator().alphaValue = targetIdle
                controlsContainer.animator().alphaValue = targetCtrl
            }
            artworkView.layer?.borderColor = NSColor(white: 1.0, alpha: hovering ? 0.36 : 0.16).cgColor
        }
    }

    open override func layout() {
        super.layout()
        let s = GlassInteractionCoordinator.shared.uiScale
        let w = bounds.width
        let h = bounds.height

        idleContainer.frame = bounds
        controlsContainer.frame = bounds

        // Helper converting top-down y (from MainWindow.cpp) to AppKit bottom-up y
        func appKitY(topY: CGFloat, height: CGFloat) -> CGFloat {
            return h - topY - height
        }

        // 1. Left Column: Always-visible Album Artwork (54×54 @ 1x, centered in 66pt middle body)
        let artSize = 54.0 * s
        let artX = 12.0 * s
        let artY = appKitY(topY: 26.0 * s, height: artSize)
        artworkContainer.frame = NSRect(x: artX, y: artY, width: artSize, height: artSize)
        artworkView.frame = artworkContainer.bounds
        artworkView.layer?.cornerRadius = 5.0 * s
        artworkHoverGlass.frame = artworkContainer.bounds.insetBy(dx: -2.0 * s, dy: -2.0 * s)
        artworkHoverGlass.cornerRadius = 6.5 * s

        // 2. Right Column geometry
        let rightColLeft = artX + artSize + 10.0 * s
        let rightColRight = w - 28.0 * s
        let rightColW = max(80.0 * s, rightColRight - rightColLeft)

        // Right Column Upper (Idle): Title & Artist (left-aligned)
        titleLabel.font = NSFont.systemFont(ofSize: 13.0 * s, weight: .bold)
        artistLabel.font = NSFont.systemFont(ofSize: 11.0 * s, weight: .regular)
        titleLabel.frame = NSRect(x: rightColLeft, y: appKitY(topY: 26.0 * s, height: 19.0 * s), width: rightColW, height: 19.0 * s)
        artistLabel.frame = NSRect(x: rightColLeft, y: appKitY(topY: 46.0 * s, height: 16.0 * s), width: rightColW, height: 16.0 * s)

        // Right Column Upper (Hover): 5 playback control buttons (32×32 @ 1x)
        let ctrlSize = 32.0 * s
        let groupW = 164.0 * s
        let startX = rightColLeft + max(0, (rightColW - groupW) * 0.5)
        let ctrlY = appKitY(topY: 26.0 * s, height: ctrlSize)
        stopButton.frame = NSRect(x: startX, y: ctrlY, width: ctrlSize, height: ctrlSize)
        prevButton.frame = NSRect(x: startX + 32.0 * s, y: ctrlY, width: ctrlSize, height: ctrlSize)
        playPauseButton.frame = NSRect(x: startX + 66.0 * s, y: ctrlY, width: ctrlSize, height: ctrlSize)
        nextButton.frame = NSRect(x: startX + 100.0 * s, y: ctrlY, width: ctrlSize, height: ctrlSize)
        ejectButton.frame = NSRect(x: startX + 132.0 * s, y: ctrlY, width: ctrlSize, height: ctrlSize)

        // 3. Top glass bar window buttons (13×13 @ 1x), perfectly aligned horizontally
        let wbSize = 13.0 * s
        let capH = OriginalDesignTokens.BaseMetrics.glassCapHeight * s
        let topBarBtnY = (h - capH) + (capH - wbSize) * 0.5
        let btnSpacing = 5.0 * s

        quitButton.frame = NSRect(x: w - 16.0 * s - wbSize, y: topBarBtnY, width: wbSize, height: wbSize)
        topMostButton.frame = NSRect(x: quitButton.frame.minX - btnSpacing - wbSize, y: topBarBtnY, width: wbSize, height: wbSize)
        miniModeButton.frame = NSRect(x: topMostButton.frame.minX - btnSpacing - wbSize, y: topBarBtnY, width: wbSize, height: wbSize)
        minimizeButton.frame = NSRect(x: miniModeButton.frame.minX - btnSpacing - wbSize, y: topBarBtnY, width: wbSize, height: wbSize)
        glassStyleButton.frame = NSRect(x: minimizeButton.frame.minX - btnSpacing - wbSize, y: topBarBtnY, width: wbSize, height: wbSize)

        // 4. Bottom glass bar panel & source buttons (13×13 @ 1x), perfectly aligned horizontally
        let botBarBtnY = (capH - wbSize) * 0.5
        appleMusicButton.frame = NSRect(x: 20.0 * s, y: botBarBtnY, width: wbSize, height: wbSize)
        spotifyButton.frame = NSRect(x: appleMusicButton.frame.maxX + 6.0 * s, y: botBarBtnY, width: wbSize, height: wbSize)
        qqMusicButton.frame = NSRect(x: spotifyButton.frame.maxX + 6.0 * s, y: botBarBtnY, width: wbSize, height: wbSize)

        lyricsButton.frame = NSRect(x: w - 16.0 * s - wbSize, y: botBarBtnY, width: wbSize, height: wbSize)
        libraryButton.frame = NSRect(x: lyricsButton.frame.minX - 6.0 * s - wbSize, y: botBarBtnY, width: wbSize, height: wbSize)

        // 4b. Normal-mode glass bar laser fog backings
        let isMiniStrip = h <= (OriginalDesignTokens.BaseMetrics.miniBarStandardHeight * s + 2.0)
        topAuroraFogView.frame = NSRect(x: 0, y: h - capH, width: w, height: capH)
        bottomAuroraFogView.frame = NSRect(x: 0, y: 0, width: w, height: capH)
        topAuroraFogView.isFogEnabled = !isMiniStrip
        bottomAuroraFogView.isFogEnabled = !isMiniStrip

        if !isMiniStrip {
            topAuroraFogView.setPlume(
                for: [glassStyleButton, minimizeButton, miniModeButton, topMostButton, quitButton],
                alignment: .right,
                anchorSpread: 10.0 * s,
                tailLength: 68.0 * s,
                peakAlpha: 1.0
            )
            let leftBotPlume = bottomAuroraFogView.makePlume(
                for: [appleMusicButton, spotifyButton, qqMusicButton],
                alignment: .left,
                anchorSpread: 10.0 * s,
                tailLength: 56.0 * s,
                peakAlpha: 1.0
            )
            let rightBotPlume = bottomAuroraFogView.makePlume(
                for: [libraryButton, lyricsButton],
                alignment: .right,
                anchorSpread: 10.0 * s,
                tailLength: 56.0 * s,
                peakAlpha: 1.0
            )
            bottomAuroraFogView.plumes = [leftBotPlume, rightBotPlume].compactMap { $0 }
        } else {
            topAuroraFogView.plumes = []
            bottomAuroraFogView.plumes = []
        }

        // 5. Volume segments (far right of right column)
        volumeView.frame = NSRect(x: w - 23.0 * s, y: appKitY(topY: 32.0 * s, height: 38.0 * s), width: 14.0 * s, height: 38.0 * s)

        // 6. Right Column Lower: Progress bar & TIMEFONT digital clock (or StreamLoadingBarView while loading)
        let progY = appKitY(topY: 64.0 * s, height: 14.0 * s)
        streamLoadingView.frame = NSRect(x: rightColLeft, y: progY, width: rightColW, height: 14.0 * s)
        let timeW = 36.0 * s
        currentTimeView.frame = NSRect(x: rightColLeft, y: progY, width: timeW, height: 14.0 * s)
        durationTimeView.frame = NSRect(x: rightColRight - timeW, y: progY, width: timeW, height: 14.0 * s)
        let sliderX = currentTimeView.frame.maxX + 4.0 * s
        let sliderW = max(20.0 * s, durationTimeView.frame.minX - 4.0 * s - sliderX)
        progressView.frame = NSRect(x: sliderX, y: progY, width: sliderW, height: 14.0 * s)
    }

    public func updateState(_ state: PlaybackState) {
        currentDurationMs = state.durationMs
        isPlayingState = state.isPlaying

        let s = GlassInteractionCoordinator.shared.uiScale
        playPauseButton.setSymbol(name: state.isPlaying ? "pause.fill" : "play.fill", pointSize: 16.5 * s, weight: .bold)

        let titleFont = NSFont.systemFont(ofSize: 13.0 * s, weight: .bold)
        let subFont = NSFont.systemFont(ofSize: 11.0 * s, weight: .regular)

        if let track = state.currentTrack {
            titleLabel.attributedStringValue = PixelFontRenderer.makeHaloAttributedString(
                track.title, font: titleFont, color: OriginalDesignTokens.Colors.titleSilver, alignment: .center
            )
            if state.status == .failed, let err = state.errorMessage, !err.isEmpty {
                artistLabel.attributedStringValue = PixelFontRenderer.makeHaloAttributedString(
                    err, font: subFont, color: .systemRed, alignment: .center
                )
            } else {
                artistLabel.attributedStringValue = PixelFontRenderer.makeHaloAttributedString(
                    track.artistName, font: subFont, color: OriginalDesignTokens.Colors.subSilver, alignment: .center
                )
            }
        } else {
            titleLabel.attributedStringValue = PixelFontRenderer.makeHaloAttributedString(
                "AirMuse Ready", font: titleFont, color: OriginalDesignTokens.Colors.titleSilver, alignment: .center
            )
            artistLabel.attributedStringValue = PixelFontRenderer.makeHaloAttributedString(
                state.sourceName, font: subFont, color: OriginalDesignTokens.Colors.subSilver, alignment: .center
            )
        }

        let isAwaitingStream = (state.status == .loading || state.status == .buffering) && !state.isPlaying
        if isAwaitingStream {
            streamLoadingView.statusText = (state.status == .buffering) ? "正在缓冲音频…" : "正在请求曲目…"
            streamLoadingView.isHidden = false
            streamLoadingView.startAnimating()
            progressView.isHidden = true
            currentTimeView.isHidden = true
            durationTimeView.isHidden = true
        } else {
            streamLoadingView.stopAnimating()
            streamLoadingView.isHidden = true
            progressView.isHidden = false
            currentTimeView.isHidden = false
            durationTimeView.isHidden = false
        }

        if !isScrubbing {
            if state.durationMs > 0 {
                progressView.ratio = CGFloat(min(max(Double(state.estimatedPositionMs) / Double(state.durationMs), 0), 1))
                currentTimeView.timeString = formatTime(ms: state.estimatedPositionMs)
                durationTimeView.timeString = formatTime(ms: state.durationMs)
            } else {
                progressView.ratio = 0
                currentTimeView.timeString = "00:00"
                durationTimeView.timeString = "00:00"
            }
        }

        volumeView.volume = state.volume

        // Artwork with ambient glass diffuse
        let trackKey = state.currentTrack?.trackKey
        if let data = state.artworkData, let img = NSImage(data: data) {
            artworkLoadTask?.cancel()
            currentArtworkTrackKey = trackKey
            applyArtwork(img, key: trackKey ?? "data")
        } else if let track = state.currentTrack, let url = track.artworkURL {
            if currentArtworkTrackKey != track.trackKey {
                currentArtworkTrackKey = track.trackKey
                artworkLoadTask?.cancel()
                applyArtwork(nil, key: "none")
                let expectedKey = track.trackKey
                artworkLoadTask = Task { [weak self] in
                    let img = await ImageCacheV2.shared.image(for: url, targetPixelSize: 222)
                    guard !Task.isCancelled, let self, self.currentArtworkTrackKey == expectedKey else { return }
                    self.applyArtwork(img, key: expectedKey)
                }
            }
        } else {
            artworkLoadTask?.cancel()
            currentArtworkTrackKey = nil
            applyArtwork(nil, key: "none")
        }
    }

    private func applyArtwork(_ img: NSImage?, key: String) {
        if let img {
            artworkView.image = img
            artworkView.imageScaling = .scaleProportionallyUpOrDown
            var rect = NSRect(origin: .zero, size: img.size)
            artworkCacheKey = key
            ambientArtwork = img.cgImage(forProposedRect: &rect, context: nil, hints: nil)
        } else {
            artworkView.image = NSImage(systemSymbolName: "music.note", accessibilityDescription: "Album Art")
            artworkView.imageScaling = .scaleProportionallyDown
            artworkCacheKey = "none"
            ambientArtwork = nil
        }
        needsLayout = true
    }

    private func formatTime(ms: Int64) -> String {
        let totalSec = max(0, ms / 1000)
        let m = totalSec / 60
        let s = totalSec % 60
        return String(format: "%02lld:%02lld", m, s)
    }
}
