import AppKit
import QuartzCore

// MARK: - LiquidGlassOverlay

/// Container using `NSGlassEffectContainerView` (macOS 26+) for localized interactive
/// floating overlays (volume HUD, hover control pills, context popovers) in Enhanced mode.
/// Never replaces the primary AIRPLAY crystal border.
@MainActor
open class LiquidGlassOverlay: NSView {

    private var containerView: NSGlassEffectContainerView?
    private var pillGlassView: NSGlassEffectView?

    public var pillCornerRadius: CGFloat = 10.0 {
        didSet { updateCorner() }
    }

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        wantsLayer = true

        let container = NSGlassEffectContainerView(frame: bounds)
        container.autoresizingMask = [.width, .height]
        container.spacing = 6.0

        let glass = NSGlassEffectView(frame: bounds)
        glass.autoresizingMask = [.width, .height]
        glass.style = .regular
        glass.cornerRadius = pillCornerRadius
        container.contentView = glass

        addSubview(container)
        self.containerView = container
        self.pillGlassView = glass

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(modeChanged),
            name: GlassInteractionCoordinator.modeDidChangeNotification,
            object: nil
        )
        modeChanged()
    }

    open override func layout() {
        super.layout()
        containerView?.frame = bounds
        pillGlassView?.frame = bounds
    }

    private func updateCorner() {
        pillGlassView?.cornerRadius = pillCornerRadius
    }

    @objc private func modeChanged() {
        let enhanced = GlassInteractionCoordinator.shared.isEnhancedMode
        containerView?.isHidden = !enhanced
    }
}
