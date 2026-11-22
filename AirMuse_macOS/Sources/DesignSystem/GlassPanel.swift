import AppKit

// MARK: - GlassPanel

/// General-purpose AIRPLAY crystal glass panel container for Lyrics, Library, and secondary windows.
/// Uses the exact 5px left/right border and 20px top/bottom glass cap insets (scaled by `uiScale`),
/// and automatically switches to 4px vertical inset in 40pt Mini-Lyrics bar mode.
open class GlassPanel: GlassSurface {

    open class FlippedContainerView: NSView {
        open override var isFlipped: Bool { true }
    }

    public let contentView: NSView = FlippedContainerView()
    public var onLayout: ((NSRect) -> Void)?

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupPanel()
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupPanel()
    }

    private func setupPanel() {
        hasMainGloss = false
        cornerRadius = OriginalDesignTokens.BaseMetrics.glassCornerRadius
        contentView.wantsLayer = true
        addSubview(contentView)
    }

    open override func layout() {
        super.layout()
        let s = GlassInteractionCoordinator.shared.uiScale
        let isMiniStrip = bounds.height <= (OriginalDesignTokens.BaseMetrics.miniBarStandardHeight * s + 2.0)
        let padX = OriginalDesignTokens.BaseMetrics.glassBorderThickness * s
        let padY = (isMiniStrip ? 4.0 : OriginalDesignTokens.BaseMetrics.glassCapHeight) * s
        let w = max(0, bounds.width - padX * 2.0)
        let h = max(0, bounds.height - padY * 2.0)
        contentView.frame = NSRect(x: padX, y: padY, width: w, height: h)
        onLayout?(contentView.bounds)
    }
}
