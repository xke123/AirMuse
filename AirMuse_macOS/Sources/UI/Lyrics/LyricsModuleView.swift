import AppKit
import Domain
import DesignSystem
import Playback
import Lyrics

// MARK: - LyricsModuleView

private final class LyricsModuleHoverTrackerView: NSView {
    var onHoverChanged: ((Bool) -> Void)?
    private var trackingArea: NSTrackingArea?

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = trackingArea { removeTrackingArea(existing) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        onHoverChanged?(true)
    }

    override func mouseExited(with event: NSEvent) {
        onHoverChanged?(false)
    }
}

/// Pure NSView module for synced lyrics inside the unified host window.
/// Preserves AIRPLAY crystal glass bars, hover controls, and normal/mini lyrics mode switching.
@MainActor
open class LyricsModuleView: NSView {

    public let lyricsView = LyricsView()
    private let panel = GlassPanel()
    private let hoverTracker = LyricsModuleHoverTrackerView()
    private let auroraFogView = AuroraGlassFogView()
    private let closeButton = GlassButton(sprite: nil, size: CGSize(width: 13, height: 13), buttonStyle: .glassBar)
    private let miniToggleButton = GlassButton(sprite: nil, size: CGSize(width: 13, height: 13), buttonStyle: .glassBar)

    public private(set) var isMiniLyricsMode: Bool = false
    private var isHovering: Bool = false

    public var onClose: (() -> Void)?
    public var onMiniModeDidChange: (() -> Void)?
    public var onMiniModeTransitionRequested: ((Bool) -> Void)?

    public var contentContainerView: NSView { panel.contentView }

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupContent()
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupContent()
    }

    public func preferredSize(for scale: CGFloat) -> NSSize {
        let w = OriginalDesignTokens.BaseMetrics.lyricsWindowWidth * scale
        let h = (isMiniLyricsMode
            ? OriginalDesignTokens.BaseMetrics.miniBarStandardHeight
            : OriginalDesignTokens.BaseMetrics.lyricsWindowHeight) * scale
        return NSSize(width: w, height: h)
    }

    private func setupContent() {
        wantsLayer = true
        layer?.masksToBounds = false

        panel.alwaysShowGlassBars = true
        panel.frame = bounds
        panel.autoresizingMask = [.width, .height]
        addSubview(panel)

        lyricsView.autoresizingMask = [.width, .height]
        panel.contentView.addSubview(lyricsView)

        hoverTracker.autoresizingMask = [.width, .height]
        hoverTracker.onHoverChanged = { [weak self] hovering in
            self?.setHovering(hovering)
        }
        panel.addSubview(hoverTracker)

        auroraFogView.seamEdge = .bottom
        auroraFogView.alphaValue = 0.0
        panel.addSubview(auroraFogView)

        closeButton.enableDarkHalo = false
        closeButton.toolTip = "关闭歌词"
        closeButton.onClick = { [weak self] in
            self?.onClose?()
        }
        auroraFogView.addSubview(closeButton)

        miniToggleButton.enableDarkHalo = false
        miniToggleButton.toolTip = "切换迷你歌词条"
        miniToggleButton.onClick = { [weak self] in
            self?.toggleMiniLyricsMode()
        }
        auroraFogView.addSubview(miniToggleButton)

        panel.onLayout = { [weak self] bounds in
            guard let self else { return }
            self.lyricsView.frame = bounds
            self.hoverTracker.frame = self.panel.bounds
            self.layoutTopBarButtons()
        }

        reloadSprites()
        updateButtonVisibility(animated: false)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleSkinChange),
            name: GlassInteractionCoordinator.modeDidChangeNotification,
            object: nil
        )
    }

    open override func layout() {
        super.layout()
        panel.frame = bounds
        layoutTopBarButtons()
    }

    open override func viewDidHide() {
        super.viewDidHide()
        isHovering = false
        MotionCoordinator.shared.cancel(key: TransitionKey(owner: "LyricsModule-\(ObjectIdentifier(self).hashValue)", channel: "hover"))
        auroraFogView.alphaValue = 0.0
    }

    public func setHovering(_ hovering: Bool, immediate: Bool = false) {
        guard isHovering != hovering else { return }
        isHovering = hovering
        updateButtonVisibility(animated: !immediate)
    }

    private func updateButtonVisibility(animated: Bool) {
        let targetAlpha: CGFloat = isHovering ? 1.0 : 0.0
        let key = TransitionKey(owner: "LyricsModule-\(ObjectIdentifier(self).hashValue)", channel: "hover")
        let ticket = MotionCoordinator.shared.beginTransition(for: key, category: .controlInteraction)
        if !animated || MotionCoordinator.shared.isReduceMotionEnabled {
            auroraFogView.alphaValue = targetAlpha
            _ = MotionCoordinator.shared.complete(ticket)
        } else {
            MotionCoordinator.shared.animate(
                duration: MotionTokens.Duration.hoverFade,
                timingFunction: .easeInEaseOut,
                ticket: ticket,
                action: {
                    self.auroraFogView.animator().alphaValue = targetAlpha
                }
            )
        }
    }

    @objc private func handleSkinChange() {
        reloadSprites()
        layoutTopBarButtons()
        panel.refreshGlassSurface()
    }

    private func reloadSprites() {
        let s = GlassInteractionCoordinator.shared.uiScale
        closeButton.setSymbol(name: "xmark", pointSize: 8.5 * s, weight: .bold)
        let toggleIcon = isMiniLyricsMode ? "rectangle.expand.vertical" : "rectangle.compress.vertical"
        miniToggleButton.setSymbol(name: toggleIcon, pointSize: 8.5 * s, weight: .bold)
    }

    private func layoutTopBarButtons() {
        let s = GlassInteractionCoordinator.shared.uiScale
        let wb = 13.0 * s

        if isMiniLyricsMode {
            // In Mini-Lyrics bar mode (height = 30 * s), center controls vertically inside the bar
            let barH = max(wb, panel.bounds.height)
            let btnY = (barH - wb) * 0.5
            auroraFogView.frame = panel.bounds
            auroraFogView.isFogEnabled = false
            auroraFogView.plumes = []
            closeButton.frame = NSRect(x: panel.bounds.width - 12.0 * s - wb, y: btnY, width: wb, height: wb)
            miniToggleButton.frame = NSRect(x: closeButton.frame.minX - 5.0 * s - wb, y: btnY, width: wb, height: wb)
        } else {
            let capH = OriginalDesignTokens.BaseMetrics.glassCapHeight * s
            let btnY = (capH - wb) * 0.5
            auroraFogView.frame = NSRect(x: 0, y: panel.bounds.height - capH, width: panel.bounds.width, height: capH)
            auroraFogView.isFogEnabled = true
            closeButton.frame = NSRect(x: panel.bounds.width - 16.0 * s - wb, y: btnY, width: wb, height: wb)
            miniToggleButton.frame = NSRect(x: closeButton.frame.minX - 5.0 * s - wb, y: btnY, width: wb, height: wb)
            auroraFogView.setPlume(
                for: [miniToggleButton, closeButton],
                alignment: .right,
                anchorSpread: 10.0 * s,
                tailLength: 64.0 * s,
                peakAlpha: 1.0
            )
        }
    }

    public func setMiniLyricsModeState(_ mini: Bool) {
        guard isMiniLyricsMode != mini else { return }
        isMiniLyricsMode = mini
        lyricsView.setMiniMode(mini)
        reloadSprites()
        layoutTopBarButtons()
        updateButtonVisibility(animated: false)
    }

    public func toggleMiniLyricsMode() {
        isMiniLyricsMode.toggle()
        lyricsView.setMiniMode(isMiniLyricsMode)
        reloadSprites()
        layoutTopBarButtons()
        updateButtonVisibility(animated: false)
        if let onMiniModeTransitionRequested {
            onMiniModeTransitionRequested(isMiniLyricsMode)
        } else {
            onMiniModeDidChange?()
        }
    }

    public var isScrollPresentationActive: Bool {
        panel.isScrollPresentationActive
    }

    public func refreshGlass() {
        panel.refreshGlassSurface()
    }

    public func applyScrollPresentation(
        topBarFrame: NSRect,
        bottomBarFrame: NSRect,
        barAlpha: CGFloat = 1.0,
        outerClipRect: NSRect? = nil
    ) {
        panel.applyScrollPresentation(
            topBarFrame: topBarFrame,
            bottomBarFrame: bottomBarFrame,
            barAlpha: barAlpha,
            outerClipRect: outerClipRect
        )
    }

    public func clearScrollPresentation() {
        panel.clearScrollPresentation()
    }
}
