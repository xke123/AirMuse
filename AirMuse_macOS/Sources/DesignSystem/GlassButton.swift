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

    public var enableDarkHalo: Bool = false {
        didSet {
            haloLayer.isHidden = !enableDarkHalo
        }
    }

    private let haloLayer = CALayer()
    private let liquidOverlay = LiquidGlassControl()
    private let imageView = NSImageView()
    private var trackingArea: NSTrackingArea?
    private var isHovered: Bool = false
    private var isPressed: Bool = false
    private var cachedHaloSize: CGSize = .zero

    public var currentControlState: ControlState {
        if !isEnabled { return .disabled }
        if isPressed { return .pressed }
        if isHovered || isHighlightedState { return .hover }
        return .normal
    }

    public init(
        image: NSImage? = nil,
        size: CGSize = CGSize(width: 24, height: 24),
        enableLiquidGlassHover: Bool = false,
        enableDarkHalo: Bool = false,
        target: AnyObject? = nil,
        action: Selector? = nil
    ) {
        super.init(frame: NSRect(origin: .zero, size: size))
        self.image = image
        self.enableLiquidGlassHover = enableLiquidGlassHover
        self.enableDarkHalo = enableDarkHalo
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

    public func setSymbol(name: String, pointSize: CGFloat, weight: NSFont.Weight = .medium) {
        let cfg = NSImage.SymbolConfiguration(pointSize: pointSize, weight: weight)
        self.spriteImage = nil
        self.image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(cfg)
        imageView.image = self.image
        updateVisualState()
    }

    private func setupButton() {
        wantsLayer = true
        layer?.masksToBounds = false

        haloLayer.masksToBounds = false
        haloLayer.opacity = 0.0
        haloLayer.isHidden = !enableDarkHalo
        layer?.insertSublayer(haloLayer, at: 0)

        liquidOverlay.cornerRadius = min(bounds.width, bounds.height) * 0.5
        liquidOverlay.isHidden = !enableLiquidGlassHover
        addSubview(liquidOverlay)

        imageView.imageScaling = .scaleProportionallyUpOrDown
        if let cg = spriteImage {
            imageView.image = NSImage(cgImage: cg, size: bounds.size)
        } else {
            imageView.image = image
            imageView.contentTintColor = OriginalDesignTokens.Colors.subSilver
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

        let haloInset = max(6.0, min(bounds.width, bounds.height) * 0.35)
        let haloFrame = bounds.insetBy(dx: -haloInset, dy: -haloInset)
        haloLayer.frame = haloFrame
        if cachedHaloSize != haloFrame.size {
            cachedHaloSize = haloFrame.size
            updateHaloImage(size: haloFrame.size)
        }
    }

    private func updateHaloImage(size: CGSize) {
        guard size.width > 2, size.height > 2 else { return }
        let scale = window?.backingScaleFactor ?? 2.0
        let pxW = max(1, Int(round(size.width * scale)))
        let pxH = max(1, Int(round(size.height * scale)))
        let cs = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil,
            width: pxW,
            height: pxH,
            bitsPerComponent: 8,
            bytesPerRow: pxW * 4,
            space: cs,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return }

        ctx.scaleBy(x: scale, y: scale)
        let center = CGPoint(x: size.width * 0.5, y: size.height * 0.5)
        let radius = min(size.width, size.height) * 0.5
        let centerColor = CGColor(srgbRed: 12/255.0, green: 14/255.0, blue: 18/255.0, alpha: 0.85)
        let edgeColor = CGColor(srgbRed: 12/255.0, green: 14/255.0, blue: 18/255.0, alpha: 0.0)

        if let grad = CGGradient(colorsSpace: cs, colors: [centerColor, edgeColor] as CFArray, locations: [0.0, 1.0]) {
            ctx.drawRadialGradient(grad, startCenter: center, startRadius: 0, endCenter: center, endRadius: radius, options: [])
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            haloLayer.contents = ctx.makeImage()
            CATransaction.commit()
        }
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

        // Tint color for SF Symbols
        if spriteImage == nil {
            if !isEnabled {
                imageView.contentTintColor = NSColor(white: 0.40, alpha: 1.0)
            } else if isPressed {
                imageView.contentTintColor = .white
            } else if isHovered || isHighlightedState {
                imageView.contentTintColor = OriginalDesignTokens.Colors.titleSilver
            } else {
                imageView.contentTintColor = OriginalDesignTokens.Colors.subSilver
            }
        }

        let targetHaloOpacity: Float = enableDarkHalo && (isHovered || isPressed) ? 0.90 : 0.0

        if MotionCoordinator.shared.isReduceMotionEnabled {
            imageView.alphaValue = targetAlpha
            haloLayer.opacity = targetHaloOpacity
        } else {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = MotionTokens.Duration.buttonState
                self.imageView.animator().alphaValue = targetAlpha
            }
            CATransaction.begin()
            CATransaction.setAnimationDuration(MotionTokens.Duration.buttonState)
            haloLayer.opacity = targetHaloOpacity
            CATransaction.commit()
        }
    }
}
