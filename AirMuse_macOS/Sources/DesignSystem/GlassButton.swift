import AppKit
import QuartzCore

// MARK: - GlassButton

/// An interactive glass button with Normal, Hover, and Pressed states.
/// Replicates the AirPlay Zion specification:
/// - Normal: 70% opacity (metal silver-gray)
/// - Hover: 100% opacity (pure silver-white highlight)
/// - Pressed: 90% opacity, vertical offset +1pt down for tactile feedback!
open class GlassButton: NSControl {

    public var onClick: (() -> Void)?

    public var image: NSImage? {
        didSet {
            imageView.image = image
            needsDisplay = true
        }
    }

    public var isHighlightedState: Bool = false {
        didSet {
            updateVisualState()
        }
    }

    private let imageView = NSImageView()
    private var trackingArea: NSTrackingArea?
    private var isHovered: Bool = false
    private var isPressed: Bool = false

    public init(image: NSImage? = nil, size: CGSize = CGSize(width: 24, height: 24), target: AnyObject? = nil, action: Selector? = nil) {
        super.init(frame: NSRect(origin: .zero, size: size))
        self.image = image
        self.target = target
        self.action = action
        setupButton()
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupButton()
    }

    private func setupButton() {
        wantsLayer = true
        layer?.masksToBounds = false

        imageView.imageScaling = .scaleProportionallyDown
        imageView.image = image
        imageView.contentTintColor = DesignTokens.Colors.primaryText
        addSubview(imageView)

        updateVisualState()
    }

    open override func layout() {
        super.layout()
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
        isPressed = true
        updateVisualState()
    }

    open override func mouseUp(with event: NSEvent) {
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
        let targetAlpha: CGFloat
        if isPressed {
            targetAlpha = 0.90
        } else if isHovered || isHighlightedState {
            targetAlpha = 1.00
        } else {
            targetAlpha = 0.70
        }

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            self.animator().alphaValue = targetAlpha
        }
    }
}

