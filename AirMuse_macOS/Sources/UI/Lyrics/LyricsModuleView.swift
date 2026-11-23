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
    private let closeButton = GlassButton(sprite: nil, size: CGSize(width: 13, height: 13))
    private let miniToggleButton = GlassButton(sprite: nil, size: CGSize(width: 13, height: 13))

    public private(set) var isMiniLyricsMode: Bool = false
    private var isHovering: Bool = false

    public var onClose: (() -> Void)?
    public var onMiniModeDidChange: (() -> Void)?

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

        closeButton.toolTip = "关闭歌词"
        closeButton.onClick = { [weak self] in
            self?.onClose?()
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

    open override func layout() {
        super.layout()
        panel.frame = bounds
        layoutTopBarButtons()
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
        updateButtonVisibility(animated: false)
        onMiniModeDidChange?()
    }

    public func refreshGlass() {
        panel.refreshGlassSurface()
    }
}
