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
        closeButton.frame = NSRect(x: panel.bounds.width - 16.0 * s - wb, y: btnY, width: wb, height: wb)
        miniToggleButton.frame = NSRect(x: closeButton.frame.minX - 5.0 * s - wb, y: btnY, width: wb, height: wb)

        auroraFogView.plumes = [
            AuroraGlassFogView.PlumeItem(
                xMin: miniToggleButton.frame.minX,
                xMax: closeButton.frame.maxX,
                spreadLeft: 28.0 * s,
                spreadRight: 14.0 * s,
                peakAlpha: 1.0
            )
        ]
    }

    public func toggleMiniLyricsMode() {
        isMiniLyricsMode.toggle()
        lyricsView.setMiniMode(isMiniLyricsMode)
        reloadSprites()
        updateButtonVisibility(animated: false)
        onMiniModeDidChange?()
    }

    public func refreshGlass() {
        panel.refreshGlassSurface()
    }
}
