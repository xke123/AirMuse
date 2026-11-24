import AppKit
import Domain
import DesignSystem
import Playback
import Lyrics

// MARK: - LyricsWindow

private final class LyricsHoverTrackerView: NSView {
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

/// Floating AIRPLAY crystal glass window for synced lyrics overlay.
/// Top glass bar hosts the close & mini-lyrics toggle buttons using original `WINDOWBUTTON` sprites.
open class LyricsWindow: NSPanel {

    public let lyricsView = LyricsView()
    private let panel = GlassPanel()
    private let hoverTracker = LyricsHoverTrackerView()
    private let auroraFogView = AuroraGlassFogView()
    private let closeButton = GlassButton(sprite: nil, size: CGSize(width: 13, height: 13), buttonStyle: .glassBar)
    private let miniToggleButton = GlassButton(sprite: nil, size: CGSize(width: 13, height: 13), buttonStyle: .glassBar)

    public private(set) var isMiniLyricsMode: Bool = false
    private var isHovering: Bool = false

    public init(frame: NSRect) {
        super.init(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        isFloatingPanel = true
        level = .floating
        isOpaque = false
        backgroundColor = .clear
        // macOS 26+ Liquid Glass requires the system compositor to participate in
        // window shadow/material blending. Keep shadow on for normal lyrics mode so
        // the GlassPanel's NSGlassEffectView bars render correctly.
        hasShadow = true
        invalidateShadow()
        isMovableByWindowBackground = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        animationBehavior = .none

        setupContent()
    }

    private func setupContent() {
        contentView = panel

        // Always show glass bars in the lyrics panel (normal + mini mode).
        panel.alwaysShowGlassBars = true

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
            self?.orderOut(nil)
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

    private func setHovering(_ hovering: Bool) {
        guard isHovering != hovering else { return }
        isHovering = hovering
        updateButtonVisibility(animated: true)
    }

    private func updateButtonVisibility(animated: Bool) {
        let targetAlpha: CGFloat = isHovering ? 1.0 : 0.0
        if !animated || MotionCoordinator.shared.isReduceMotionEnabled {
            auroraFogView.alphaValue = targetAlpha
        } else {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = MotionTokens.Duration.hoverFade
                auroraFogView.animator().alphaValue = targetAlpha
            }
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
        let capH = (isMiniLyricsMode ? 4.0 : OriginalDesignTokens.BaseMetrics.glassCapHeight) * s
        let btnY = (capH - wb) * 0.5

        auroraFogView.frame = NSRect(x: 0, y: panel.bounds.height - capH, width: panel.bounds.width, height: capH)
        auroraFogView.isFogEnabled = !isMiniLyricsMode
        closeButton.frame = NSRect(x: panel.bounds.width - 16.0 * s - wb, y: btnY, width: wb, height: wb)
        miniToggleButton.frame = NSRect(x: closeButton.frame.minX - 5.0 * s - wb, y: btnY, width: wb, height: wb)

        if !isMiniLyricsMode {
            auroraFogView.setPlume(
                for: [miniToggleButton, closeButton],
                alignment: .right,
                anchorSpread: 10.0 * s,
                tailLength: 64.0 * s,
                peakAlpha: 1.0
            )
        } else {
            auroraFogView.plumes = []
        }
    }

    public func toggleMiniLyricsMode() {
        isMiniLyricsMode.toggle()
        lyricsView.setMiniMode(isMiniLyricsMode)
        // Shadow is always on (Liquid Glass manages it).
        hasShadow = true
        reloadSprites()
        updateButtonVisibility(animated: false)
        let s = GlassInteractionCoordinator.shared.uiScale
        let targetH = (isMiniLyricsMode ? OriginalDesignTokens.BaseMetrics.miniBarStandardHeight : OriginalDesignTokens.BaseMetrics.lyricsWindowHeight) * s
        let f = frame
        let newFrame = NSRect(x: f.minX, y: f.maxY - targetH, width: f.width, height: targetH)
        MotionCoordinator.shared.animate(duration: MotionTokens.Duration.miniToggle) {
            self.setFrame(newFrame, display: true, animate: false)
        }
        invalidateShadow()
    }

    open override func layoutIfNeeded() {
        super.layoutIfNeeded()
        layoutTopBarButtons()
    }

    // MARK: - Key Window

    // Allow this panel to become the key window so that NSGlassEffectView always
    // renders at full "active" intensity regardless of which other window is focused.
    open override var canBecomeKey: Bool { true }
    open override var canBecomeMain: Bool { false }
}
