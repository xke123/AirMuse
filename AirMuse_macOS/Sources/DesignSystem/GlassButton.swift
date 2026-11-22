import AppKit
import QuartzCore

// MARK: - GlassButton

/// Interactive AIRPLAY button supporting original sprite sheets (`MAINCONTROL`, `MINICONTROL`,
/// `WINDOWBUTTON`, `ICONBUTTON`) as well as fallback SF Symbols, with exact Normal/Hover/Pressed/Disabled
/// state physics and optional localized `LiquidGlassControl` enhancement in Enhanced mode.
open class GlassButton: NSControl {

    public var onClick: (() -> Void)?

    public var image: NSImage? {
        didSet {
            spriteImage = nil
            imageView.image = image
            needsDisplay = true
        }
    }

    public var spriteImage: CGImage? {
        didSet {
            if let cg = spriteImage {
                imageView.image = NSImage(cgImage: cg, size: bounds.size)
            }
            needsDisplay = true
        }
    }

    public var isHighlightedState: Bool = false {
        didSet {
            updateVisualState()
        }
    }

    public var enableLiquidGlassHover: Bool = false {
        didSet {
            liquidOverlay.isHidden = !enableLiquidGlassHover
        }
    }

    private let liquidOverlay = LiquidGlassControl()
    private let imageView = NSImageView()
    private var trackingArea: NSTrackingArea?
    private var isHovered: Bool = false
    private var isPressed: Bool = false

    public var currentControlState: ControlState {
        if !isEnabled { return .disabled }
        if isPressed { return .pressed }
        if isHovered || isHighlightedState { return .hover }
        return .normal
    }

    public init(image: NSImage? = nil, size: CGSize = CGSize(width: 24, height: 24), target: AnyObject? = nil, action: Selector? = nil) {
        super.init(frame: NSRect(origin: .zero, size: size))
        self.image = image
        self.target = target
        self.action = action
        setupButton()
    }

    public init(sprite: CGImage?, size: CGSize, enableLiquidGlassHover: Bool = false) {
        super.init(frame: NSRect(origin: .zero, size: size))
        self.spriteImage = sprite
        self.enableLiquidGlassHover = enableLiquidGlassHover
        setupButton()
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupButton()
    }

    private func setupButton() {
        wantsLayer = true
        layer?.masksToBounds = false

        liquidOverlay.cornerRadius = min(bounds.width, bounds.height) * 0.5
        liquidOverlay.isHidden = !enableLiquidGlassHover
        addSubview(liquidOverlay)

        imageView.imageScaling = .scaleProportionallyUpOrDown
        if let cg = spriteImage {
            imageView.image = NSImage(cgImage: cg, size: bounds.size)
        } else {
            imageView.image = image
            imageView.contentTintColor = DesignTokens.Colors.primaryText
        }
        addSubview(imageView)

        updateVisualState()
    }

    open override func layout() {
        super.layout()
        liquidOverlay.frame = bounds.insetBy(dx: -2, dy: -2)
        liquidOverlay.cornerRadius = min(liquidOverlay.bounds.width, liquidOverlay.bounds.height) * 0.5
        let offset: CGFloat = isPressed ? -1.0 : 0.0
        imageView.frame = NSRect(x: 0, y: offset, width: bounds.width, height: bounds.height)
    }

    open override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = trackingArea {
            removeTrackingArea(existing)
        }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .assumeInside], owner: self, userInfo: nil)
        addTrackingArea(area)
        self.trackingArea = area
    }

    open override func mouseEntered(with event: NSEvent) {
        isHovered = true
        updateVisualState()
    }

    open override func mouseExited(with event: NSEvent) {
        isHovered = false
        isPressed = false
        updateVisualState()
    }

    open override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        isPressed = true
        updateVisualState()
    }

    open override func mouseUp(with event: NSEvent) {
        guard isEnabled else { return }
        let inside = bounds.contains(convert(event.locationInWindow, from: nil))
        isPressed = false
        updateVisualState()

        if inside {
            if let act = action, let tgt = target {
                NSApp.sendAction(act, to: tgt, from: self)
            }
            onClick?()
        }
    }

    private func updateVisualState() {
        needsLayout = true
        let state = currentControlState
        let targetAlpha = state.alpha
        liquidOverlay.isActive = enableLiquidGlassHover && (isHovered || isPressed)

        if MotionCoordinator.shared.isReduceMotionEnabled {
            alphaValue = targetAlpha
        } else {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = MotionTokens.Duration.buttonState
                self.animator().alphaValue = targetAlpha
            }
        }
    }
}
