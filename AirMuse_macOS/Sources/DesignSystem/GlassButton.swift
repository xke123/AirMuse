import AppKit
import QuartzCore

// MARK: - GlassButtonStyle

public enum GlassButtonStyle: Sendable {
    /// Standard panel control button (e.g. main playback controls).
    case standard
    /// Window / chrome button mounted on top or bottom glass bars.
    case glassBar
}

// MARK: - GlassButton

/// Interactive AIRPLAY button supporting original sprite sheets (`MAINCONTROL`, `MINICONTROL`,
/// `WINDOWBUTTON`, `ICONBUTTON`) as well as fallback SF Symbols, with M05 elastic press/hover physics,
/// M06 symbol transitions, keyboard accessibility, and localized `LiquidGlassControl` in Enhanced mode.
open class GlassButton: NSControl {

    public var onClick: (() -> Void)?

    public var buttonStyle: GlassButtonStyle = .standard {
        didSet {
            guard oldValue != buttonStyle else { return }
            updateImageShadow()
            updateVisualState(animated: false)
        }
    }

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
            guard oldValue != isHighlightedState else { return }
            updateVisualState(animated: true)
        }
    }

    public var enableLiquidGlassHover: Bool = false {
        didSet {
            liquidOverlay.isHidden = !(enableLiquidGlassHover || enablePersistentLiquidGlass)
            updateVisualState(animated: false)
        }
    }

    /// Draws the button's own circular/capsule shape directly with `NSGlassEffectView` in Enhanced mode
    /// (with the icon placed inside `NSGlassEffectView.contentView` so it stays crisp and unoccluded).
    public var enablePersistentLiquidGlass: Bool = false {
        didSet {
            liquidOverlay.isHidden = !(enableLiquidGlassHover || enablePersistentLiquidGlass)
            updateVisualState(animated: false)
        }
    }

    public var enableDarkHalo: Bool = false {
        didSet {
            haloLayer.isHidden = !enableDarkHalo
            updateVisualState(animated: false)
        }
    }

    open override var isEnabled: Bool {
        didSet {
            if !isEnabled {
                isHovered = false
                isPressed = false
                isTrackingPress = false
            }
            updateVisualState(animated: true)
        }
    }

    private let buttonOwnerID = "GlassButton-\(UUID().uuidString)"
    private let haloLayer = CALayer()
    private let hoverBackdropLayer = CALayer()
    private let liquidOverlay = LiquidGlassControl()
    private let imageView = NSImageView()
    private var trackingArea: NSTrackingArea?
    private var isHovered: Bool = false
    private var isPressed: Bool = false
    private var isTrackingPress: Bool = false
    private var isKeyboardFocused: Bool = false
    private var cachedHaloSize: CGSize = .zero
    private var currentSymbolName: String?
    private var storedTooltip: String?

    open override var toolTip: String? {
        get { storedTooltip }
        set {
            storedTooltip = newValue
            syncNativeToolTip()
            setAccessibilityLabel(newValue)
        }
    }

    private func syncNativeToolTip() {
        if !GlassInteractionCoordinator.shared.isEnhancedMode || MotionCoordinator.shared.isReduceTransparencyEnabled {
            super.toolTip = storedTooltip
        } else {
            super.toolTip = nil
        }
    }

    open override var mouseDownCanMoveWindow: Bool { false }
    open override var acceptsFirstResponder: Bool { isEnabled }

    open override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden, isEnabled, alphaValue > 0.01 else { return nil }
        let localPt = convert(point, from: superview)
        return bounds.contains(localPt) ? self : nil
    }

    public var currentControlState: ControlState {
        if !isEnabled { return .disabled }
        if isPressed { return .pressed }
        if isHovered || isHighlightedState || isKeyboardFocused { return .hover }
        return .normal
    }

    public init(
        image: NSImage? = nil,
        size: CGSize = CGSize(width: 24, height: 24),
        buttonStyle: GlassButtonStyle = .standard,
        enableLiquidGlassHover: Bool = false,
        enableDarkHalo: Bool = false,
        target: AnyObject? = nil,
        action: Selector? = nil
    ) {
        self.buttonStyle = buttonStyle
        super.init(frame: NSRect(origin: .zero, size: size))
        self.image = image
        self.enableLiquidGlassHover = enableLiquidGlassHover
        self.enableDarkHalo = enableDarkHalo
        self.target = target
        self.action = action
        setupButton()
    }

    public init(
        sprite: CGImage?,
        size: CGSize,
        buttonStyle: GlassButtonStyle = .standard,
        enableLiquidGlassHover: Bool = false
    ) {
        self.buttonStyle = buttonStyle
        super.init(frame: NSRect(origin: .zero, size: size))
        self.spriteImage = sprite
        self.enableLiquidGlassHover = enableLiquidGlassHover
        setupButton()
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupButton()
    }

    isolated deinit {
        NotificationCenter.default.removeObserver(self)
        MotionCoordinator.shared.cancelAll(owner: buttonOwnerID)
    }

    public func setSymbol(name: String, pointSize: CGFloat, weight: NSFont.Weight = .medium) {
        currentSymbolName = name
        let cfg = NSImage.SymbolConfiguration(pointSize: pointSize, weight: weight)
        self.spriteImage = nil
        imageView.imageScaling = .scaleProportionallyDown
        self.image = NSImage(systemSymbolName: name, accessibilityDescription: toolTip)?.withSymbolConfiguration(cfg)
        imageView.image = self.image
        updateVisualState(animated: false)
    }

    /// M06: Transitions to a new SF Symbol cleanly when playback state genuinely changes.
    public func transitionToSymbol(name: String, pointSize: CGFloat, weight: NSFont.Weight = .medium) {
        guard currentSymbolName != name else { return }
        currentSymbolName = name
        let cfg = NSImage.SymbolConfiguration(pointSize: pointSize, weight: weight)
        let nextImg = NSImage(systemSymbolName: name, accessibilityDescription: toolTip)?.withSymbolConfiguration(cfg)
        self.spriteImage = nil
        imageView.imageScaling = .scaleProportionallyDown
        self.image = nextImg

        let key = TransitionKey(owner: buttonOwnerID, channel: "icon")
        let ticket = MotionCoordinator.shared.beginTransition(for: key, category: .controlInteraction)

        if MotionCoordinator.shared.isReduceMotionEnabled {
            imageView.image = nextImg
            imageView.alphaValue = currentTargetAlpha()
            _ = MotionCoordinator.shared.complete(ticket)
            return
        }

        imageView.image = nextImg
        if let imgLayer = imageView.layer {
            CATransaction.begin()
            let scaleAnim = CABasicAnimation(keyPath: "transform.scale")
            scaleAnim.fromValue = 0.84
            scaleAnim.toValue = currentTargetScale()
            scaleAnim.duration = MotionTokens.Duration.playPauseMorph
            scaleAnim.timingFunction = CAMediaTimingFunction(name: .easeOut)
            scaleAnim.isRemovedOnCompletion = true

            let opAnim = CABasicAnimation(keyPath: "opacity")
            opAnim.fromValue = 0.35
            opAnim.toValue = Float(currentTargetAlpha())
            opAnim.duration = MotionTokens.Duration.playPauseMorph
            opAnim.timingFunction = CAMediaTimingFunction(name: .easeOut)
            opAnim.isRemovedOnCompletion = true

            CATransaction.setCompletionBlock {
                Task { @MainActor in
                    _ = MotionCoordinator.shared.complete(ticket)
                }
            }
            imgLayer.add(scaleAnim, forKey: "symbolScale")
            imgLayer.add(opAnim, forKey: "symbolOpacity")
            CATransaction.commit()
        } else {
            _ = MotionCoordinator.shared.complete(ticket)
        }
        updateVisualState(animated: false)
    }

    private func setupButton() {
        wantsLayer = true
        layer?.masksToBounds = false
        setAccessibilityRole(.button)

        haloLayer.masksToBounds = false
        haloLayer.opacity = 0.0
        haloLayer.isHidden = !enableDarkHalo
        layer?.insertSublayer(haloLayer, at: 0)

        hoverBackdropLayer.opacity = 0.0
        hoverBackdropLayer.borderWidth = 0.5
        layer?.addSublayer(hoverBackdropLayer)

        liquidOverlay.cornerRadius = min(bounds.width, bounds.height) * 0.5
        liquidOverlay.isHidden = !(enableLiquidGlassHover || enablePersistentLiquidGlass)
        addSubview(liquidOverlay)

        imageView.wantsLayer = true
        imageView.imageScaling = spriteImage != nil ? .scaleProportionallyUpOrDown : .scaleProportionallyDown
        imageView.frame = bounds
        if let imgLayer = imageView.layer {
            imgLayer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
            imgLayer.position = CGPoint(x: bounds.midX, y: bounds.midY)
        }
        if let cg = spriteImage {
            imageView.image = NSImage(cgImage: cg, size: bounds.size)
        } else {
            imageView.image = image
            imageView.contentTintColor = buttonStyle == .glassBar
                ? OriginalDesignTokens.Colors.glassBarForeground
                : OriginalDesignTokens.Colors.subSilver
        }
        addSubview(imageView)

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleEnvironmentDidChange),
            name: GlassInteractionCoordinator.modeDidChangeNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleEnvironmentDidChange),
            name: MotionAccessibility.preferencesDidChangeNotification,
            object: nil
        )

        updateImageShadow()
        updateVisualState(animated: false)
    }

    @objc private func handleEnvironmentDidChange() {
        syncNativeToolTip()
        updateVisualState(animated: false)
    }

    private func syncImageViewParent() {
        let useGlassHost = (enablePersistentLiquidGlass || enableLiquidGlassHover) && liquidOverlay.isGlassEffectActiveForContent
        let desiredParent: NSView = useGlassHost ? liquidOverlay.contentHostView : self
        if imageView.superview !== desiredParent {
            imageView.removeFromSuperview()
            desiredParent.addSubview(imageView)
            needsLayout = true
        }
    }

    private func updateImageShadow() {
        guard let imgLayer = imageView.layer else { return }
        if buttonStyle == .glassBar {
            imgLayer.shadowColor = NSColor(srgbRed: 12/255.0, green: 14/255.0, blue: 18/255.0, alpha: 1.0).cgColor
            imgLayer.shadowOpacity = 0.55
            imgLayer.shadowRadius = 1.2
            imgLayer.shadowOffset = CGSize(width: 0, height: -0.5)
        } else {
            imgLayer.shadowOpacity = 0.0
        }
    }

    open override func layout() {
        super.layout()
        liquidOverlay.frame = bounds
        liquidOverlay.cornerRadius = min(liquidOverlay.bounds.width, liquidOverlay.bounds.height) * 0.5

        let backdropInset: CGFloat = buttonStyle == .glassBar ? -2.5 : -2.0
        let backdropRect = bounds.insetBy(dx: backdropInset, dy: backdropInset)
        hoverBackdropLayer.frame = backdropRect
        hoverBackdropLayer.cornerRadius = min(backdropRect.width, backdropRect.height) * 0.5

        let targetBounds = imageView.superview?.bounds ?? bounds
        if let imgLayer = imageView.layer {
            let savedTransform = imgLayer.transform
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            imgLayer.transform = CATransform3DIdentity
            imageView.frame = targetBounds
            imgLayer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
            imgLayer.position = CGPoint(x: targetBounds.midX, y: targetBounds.midY)
            imgLayer.transform = savedTransform
            CATransaction.commit()
        } else {
            imageView.frame = targetBounds
        }

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
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        self.trackingArea = area
    }

    open override func resetCursorRects() {
        if isEnabled {
            addCursorRect(bounds, cursor: .pointingHand)
        }
    }

    open override func viewDidHide() {
        super.viewDidHide()
        resetTransientStates()
    }

    open override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            resetTransientStates()
        }
    }

    open override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        if ok {
            isKeyboardFocused = true
            updateVisualState(animated: true)
        }
        return ok
    }

    open override func resignFirstResponder() -> Bool {
        let ok = super.resignFirstResponder()
        if ok {
            isKeyboardFocused = false
            isPressed = false
            isTrackingPress = false
            updateVisualState(animated: true)
        }
        return ok
    }

    open override func keyDown(with event: NSEvent) {
        guard isEnabled, !event.isARepeat else {
            if !event.isARepeat { super.keyDown(with: event) }
            return
        }
        // Space (49) or Return (36) / Enter (76)
        if event.keyCode == 49 || event.keyCode == 36 || event.keyCode == 76 {
            triggerKeyboardActivate()
        } else {
            super.keyDown(with: event)
        }
    }

    /// Triggers an atomic keyboard press+release click sequence (M05 keyboard parity).
    public func triggerKeyboardActivate() {
        guard isEnabled else { return }
        isPressed = true
        updateVisualState(animated: true)
        fireClickAction()
        isPressed = false
        updateVisualState(animated: true)
    }

    open override func mouseEntered(with event: NSEvent) {
        guard isEnabled else { return }
        isHovered = true
        if isTrackingPress {
            isPressed = true
        } else if let tip = storedTooltip, !tip.isEmpty,
                  GlassInteractionCoordinator.shared.isEnhancedMode,
                  !MotionCoordinator.shared.isReduceTransparencyEnabled {
            GlassTooltipManager.shared.scheduleTooltip(text: tip, for: self)
        }
        updateVisualState(animated: true)
    }

    open override func mouseExited(with event: NSEvent) {
        isHovered = false
        isPressed = false
        GlassTooltipManager.shared.hideImmediately()
        updateVisualState(animated: true)
    }

    open override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        GlassTooltipManager.shared.hideImmediately()
        isTrackingPress = true
        isPressed = true
        updateVisualState(animated: true)
    }

    open override func mouseDragged(with event: NSEvent) {
        guard isEnabled, isTrackingPress else { return }
        let inside = bounds.contains(convert(event.locationInWindow, from: nil))
        if isPressed != inside || isHovered != inside {
            isPressed = inside
            isHovered = inside
            updateVisualState(animated: true)
        }
    }

    open override func mouseUp(with event: NSEvent) {
        guard isEnabled else {
            isTrackingPress = false
            isPressed = false
            return
        }
        let inside = isTrackingPress && bounds.contains(convert(event.locationInWindow, from: nil))
        isTrackingPress = false
        isPressed = false
        isHovered = inside
        updateVisualState(animated: true)

        if inside {
            fireClickAction()
        }
    }

    private func fireClickAction() {
        if let act = action, let tgt = target {
            NSApp.sendAction(act, to: tgt, from: self)
        }
        onClick?()
    }

    private func resetTransientStates() {
        isHovered = false
        isPressed = false
        isTrackingPress = false
        isKeyboardFocused = false
        GlassTooltipManager.shared.hideImmediately()
        MotionCoordinator.shared.cancelAll(owner: buttonOwnerID)
        updateVisualState(animated: false)
    }

    private func currentTargetAlpha() -> CGFloat {
        if buttonStyle == .glassBar {
            if !isEnabled { return 0.40 }
            if isPressed { return 0.92 }
            return 1.0
        }
        return currentControlState.alpha
    }

    private func currentTargetScale() -> CGFloat {
        guard isEnabled else { return 1.0 }
        if isPressed {
            return MotionTokens.Geometry.buttonPressScale
        }
        if isHovered || isKeyboardFocused {
            return MotionTokens.Geometry.buttonHoverScale
        }
        return 1.0
    }

    private func updateVisualState(animated: Bool) {
        needsLayout = true
        let targetAlpha = currentTargetAlpha()
        let targetScale = currentTargetScale()
        let duration: TimeInterval = isPressed
            ? MotionTokens.Duration.buttonPress
            : (isHovered ? MotionTokens.Duration.buttonHover : MotionTokens.Duration.buttonRelease)

        let shouldActivateGlass = (enablePersistentLiquidGlass && isEnabled)
            || (enableLiquidGlassHover && isEnabled && (isHovered || isPressed || isKeyboardFocused))
        liquidOverlay.isActive = shouldActivateGlass
        syncImageViewParent()

        if spriteImage == nil {
            if buttonStyle == .glassBar {
                if !isEnabled {
                    imageView.contentTintColor = OriginalDesignTokens.Colors.glassBarForegroundDisabled
                } else if isPressed {
                    imageView.contentTintColor = OriginalDesignTokens.Colors.glassBarForegroundPressed
                } else if isHovered || isHighlightedState || isKeyboardFocused {
                    imageView.contentTintColor = OriginalDesignTokens.Colors.glassBarForegroundHover
                } else {
                    imageView.contentTintColor = OriginalDesignTokens.Colors.glassBarForeground
                }
            } else {
                if !isEnabled {
                    imageView.contentTintColor = NSColor(white: 0.40, alpha: 1.0)
                } else if isPressed {
                    imageView.contentTintColor = .white
                } else if isHovered || isHighlightedState || isKeyboardFocused {
                    imageView.contentTintColor = OriginalDesignTokens.Colors.titleSilver
                } else {
                    imageView.contentTintColor = OriginalDesignTokens.Colors.subSilver
                }
            }
        }

        let glassActive = liquidOverlay.isGlassEffectActiveForContent
        let showBackdrop = (buttonStyle == .glassBar || !glassActive)
            && isEnabled
            && (isPressed || isHovered || isHighlightedState || isKeyboardFocused)
        let targetBackdropOpacity: Float = showBackdrop ? 1.0 : 0.0
        if isPressed {
            hoverBackdropLayer.backgroundColor = NSColor(white: 1.0, alpha: 0.26).cgColor
            hoverBackdropLayer.borderColor = NSColor(white: 1.0, alpha: 0.34).cgColor
        } else if isHovered || isKeyboardFocused {
            hoverBackdropLayer.backgroundColor = NSColor(white: 1.0, alpha: 0.17).cgColor
            hoverBackdropLayer.borderColor = NSColor(white: 1.0, alpha: 0.26).cgColor
        } else if isHighlightedState {
            hoverBackdropLayer.backgroundColor = NSColor(white: 1.0, alpha: 0.11).cgColor
            hoverBackdropLayer.borderColor = NSColor(white: 1.0, alpha: 0.18).cgColor
        } else {
            hoverBackdropLayer.backgroundColor = NSColor.clear.cgColor
            hoverBackdropLayer.borderColor = NSColor.clear.cgColor
        }

        let targetHaloOpacity: Float = enableDarkHalo && isEnabled && (isHovered || isPressed || isKeyboardFocused) ? 0.90 : 0.0
        let sinkPt = OriginalDesignTokens.Scale.original1x * MotionTokens.Geometry.buttonPressSinkPt
        let offset: CGFloat = isPressed ? (isFlipped ? sinkPt : -sinkPt) : 0.0
        let scaleTransform = CATransform3DScale(
            CATransform3DMakeTranslation(0, offset, 0),
            targetScale,
            targetScale,
            1.0
        )

        let key = TransitionKey(owner: buttonOwnerID, channel: "state")
        let ticket = MotionCoordinator.shared.beginTransition(for: key, category: .controlInteraction)
        let alphaKey = TransitionKey(owner: buttonOwnerID, channel: "alpha")

        if !animated || MotionCoordinator.shared.isReduceMotionEnabled {
            MotionCoordinator.shared.cancel(key: alphaKey)
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            imageView.alphaValue = targetAlpha
            imageView.layer?.removeAnimation(forKey: "btnScale")
            imageView.layer?.transform = scaleTransform
            haloLayer.opacity = targetHaloOpacity
            hoverBackdropLayer.opacity = targetBackdropOpacity
            CATransaction.commit()
            _ = MotionCoordinator.shared.complete(ticket)
            return
        }

        if let imgLayer = imageView.layer {
            let startScale = (imgLayer.presentation()?.value(forKeyPath: "transform.scale.x") as? NSNumber).map { CGFloat($0.doubleValue) } ?? 1.0
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            imgLayer.removeAnimation(forKey: "btnScale")
            imgLayer.transform = scaleTransform
            haloLayer.opacity = targetHaloOpacity
            hoverBackdropLayer.opacity = targetBackdropOpacity
            CATransaction.commit()

            let scaleAnim = MotionCoordinator.shared.makeSpringAnimation(
                keyPath: "transform.scale",
                from: startScale,
                to: targetScale,
                preset: MotionTokens.Springs.buttonPress
            )
            scaleAnim.duration = min(scaleAnim.settlingDuration, max(duration, 0.14))
            CATransaction.begin()
            CATransaction.setCompletionBlock {
                Task { @MainActor in
                    _ = MotionCoordinator.shared.complete(ticket)
                }
            }
            imgLayer.add(scaleAnim, forKey: "btnScale")
            CATransaction.commit()
        } else {
            _ = MotionCoordinator.shared.complete(ticket)
        }

        let alphaTicket = MotionCoordinator.shared.beginTransition(for: alphaKey, category: .controlInteraction)
        MotionCoordinator.shared.animate(
            duration: duration,
            timingFunction: .easeOut,
            ticket: alphaTicket
        ) {
            self.imageView.animator().alphaValue = targetAlpha
        }
    }
}
