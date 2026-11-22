import AppKit

// MARK: - GlassPanel

/// General-purpose glass panel container for popovers, drawers, and secondary panels.
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
        cornerRadius = DesignTokens.CornerRadius.panel
        contentView.wantsLayer = true
        addSubview(contentView)
    }

    open override func layout() {
        super.layout()
        contentView.frame = bounds.insetBy(dx: DesignTokens.Spacing.sm, dy: DesignTokens.Spacing.sm)
        onLayout?(contentView.bounds)
    }
}

