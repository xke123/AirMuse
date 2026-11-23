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
    private let closeButton = GlassButton(sprite: nil, size: CGSize(width: 13, height: 13))
    private let miniToggleButton = GlassButton(sprite: nil, size: CGSize(width: 13, height: 13))

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

        closeButton.toolTip = "关闭歌词"
        closeButton.onClick = { [weak self] in
            self?.orderOut(nil)
        }
        panel.addSubview(closeButton)

        miniToggleButton.toolTip = "切换迷你歌词条"
        miniToggleButton.onClick = { [weak self] in
            self?.toggleMiniLyricsMode()
        }
        panel.addSubview(miniToggleButton)

        panel.onLayout = { [weak self] bounds in
            guard let self else { return }
            self.lyricsView.frame = bounds
            self.hoverTracker.frame = bounds
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
        let targetAlpha: CGFloat = (!isMiniLyricsMode || isHovering) ? 1.0 : 0.0
        if !animated || MotionCoordinator.shared.isReduceMotionEnabled {
            closeButton.alphaValue = targetAlpha
            miniToggleButton.alphaValue = targetAlpha
        } else {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = MotionTokens.Duration.hoverFade
                closeButton.animator().alphaValue = targetAlpha
                miniToggleButton.animator().alphaValue = targetAlpha
            }
        }
    }

    @objc private func handleSkinChange() {
        reloadSprites()
        layoutTopBarButtons()
        panel.refreshGlassSurface()
    }

    private func reloadSprites() {
        let res = GlassInteractionCoordinator.shared.resolutionMode
        closeButton.spriteImage = SkinAtlas.shared.windowButton(.close, resolution: res)
        miniToggleButton.spriteImage = SkinAtlas.shared.windowButton(.miniToggle, resolution: res)
    }

    private func layoutTopBarButtons() {
        let s = GlassInteractionCoordinator.shared.uiScale
        let wb = 13.0 * s
        let topY = isMiniLyricsMode ? (panel.bounds.height - wb) * 0.5 : (panel.bounds.height - 4.0 * s - wb)
        closeButton.frame = NSRect(x: panel.bounds.width - 45.0 * s, y: topY, width: wb, height: wb)
        miniToggleButton.frame = NSRect(x: panel.bounds.width - 63.0 * s, y: topY, width: wb, height: wb)
    }

    public func toggleMiniLyricsMode() {
        isMiniLyricsMode.toggle()
        lyricsView.setMiniMode(isMiniLyricsMode)
        // Shadow is always on (Liquid Glass manages it).
        hasShadow = true
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
