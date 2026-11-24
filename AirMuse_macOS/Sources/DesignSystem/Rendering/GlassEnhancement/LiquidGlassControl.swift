import AppKit
import QuartzCore

// MARK: - LiquidGlassControl

/// Local macOS 26+ `NSGlassEffectView` enhancement wrapper for interactive capsules,
/// search fields, popovers, and hover pills.
/// - In `.original` mode: completely transparent/inactive so the original AIRPLAY skin is 100% pure.
/// - In `.enhanced` mode: activates a localized `NSGlassEffectView` (macOS 26+) inside the control's
///   exact silhouette without altering the outer AIRPLAY crystal frame.
/// - In Reduce Transparency mode: automatically hides translucent glass and reveals a high-contrast opaque fallback rim.
@MainActor
open class LiquidGlassControl: NSView {

    private let controlOwnerID = "LiquidGlassControl-\(UUID().uuidString)"
    private var glassEffectView: NSGlassEffectView?
    public let contentHostView = NSView()
    private let reduceTransparencyFallbackLayer = CALayer()
    private var cornerRadiusValue: CGFloat = 8.0
    private var isEnhancementActive: Bool = false

    public var isGlassEffectVisible: Bool {
        guard let glassEffectView else { return false }
        return !glassEffectView.isHidden && glassEffectView.alphaValue > 0.01
    }

    /// True whenever the native `NSGlassEffectView` is enabled and should host `contentHostView`.
    public var isGlassEffectActiveForContent: Bool {
        GlassInteractionCoordinator.shared.isEnhancedMode
            && isEnhancementActive
            && !MotionCoordinator.shared.isReduceTransparencyEnabled
    }

    public var cornerRadius: CGFloat {
        get { cornerRadiusValue }
        set {
            cornerRadiusValue = newValue
            updateGlassAppearance()
        }
    }

    public var isActive: Bool {
        get { isEnhancementActive }
        set {
            guard isEnhancementActive != newValue else { return }
            isEnhancementActive = newValue
            updateGlassAppearance()
        }
    }

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    isolated deinit {
        NotificationCenter.default.removeObserver(self)
        MotionCoordinator.shared.cancelAll(owner: controlOwnerID)
    }

    private func setup() {
        wantsLayer = true
        layer?.masksToBounds = true

        reduceTransparencyFallbackLayer.backgroundColor = NSColor(srgbRed: 26/255.0, green: 28/255.0, blue: 32/255.0, alpha: 0.94).cgColor
        reduceTransparencyFallbackLayer.borderColor = NSColor(white: 1.0, alpha: 0.34).cgColor
        reduceTransparencyFallbackLayer.borderWidth = 1.0
        reduceTransparencyFallbackLayer.opacity = 0.0
        layer?.addSublayer(reduceTransparencyFallbackLayer)

        let effect = NSGlassEffectView(frame: bounds)
        effect.autoresizingMask = [.width, .height]
        effect.style = .clear
        effect.cornerRadius = cornerRadiusValue
        effect.alphaValue = 0.0
        effect.isHidden = true
        if #available(macOS 27.0, *) {
            effect.effectIsInteractive = true
        }
        contentHostView.wantsLayer = true
        contentHostView.frame = effect.bounds
        contentHostView.autoresizingMask = [.width, .height]
        effect.contentView = contentHostView
        addSubview(effect)
        self.glassEffectView = effect

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(renderModeChanged),
            name: GlassInteractionCoordinator.modeDidChangeNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(renderModeChanged),
            name: MotionAccessibility.preferencesDidChangeNotification,
            object: nil
        )
        updateGlassAppearance()
    }

    open override func layout() {
        super.layout()
        glassEffectView?.frame = bounds
        contentHostView.frame = glassEffectView?.bounds ?? bounds
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        reduceTransparencyFallbackLayer.frame = bounds
        reduceTransparencyFallbackLayer.cornerRadius = cornerRadiusValue
        CATransaction.commit()
    }

    @objc private func renderModeChanged() {
        updateGlassAppearance()
    }

    private func updateGlassAppearance() {
        let enhanced = GlassInteractionCoordinator.shared.isEnhancedMode
        let reduceTransparency = MotionCoordinator.shared.isReduceTransparencyEnabled
        let shouldShow = enhanced && isEnhancementActive && !reduceTransparency

        glassEffectView?.cornerRadius = cornerRadiusValue
        glassEffectView?.isHidden = !shouldShow

        let targetGlassAlpha: CGFloat = shouldShow ? 1.0 : 0.0
        let targetFallbackOpacity: Float = (enhanced && isEnhancementActive && reduceTransparency) ? 1.0 : 0.0

        let key = TransitionKey(owner: controlOwnerID, channel: "alpha")
        let fallbackKey = TransitionKey(owner: controlOwnerID, channel: "fallbackOpacity")
        let ticket = MotionCoordinator.shared.beginTransition(for: key, category: .controlInteraction)

        if MotionCoordinator.shared.isReduceMotionEnabled {
            MotionCoordinator.shared.cancel(key: fallbackKey)
            glassEffectView?.alphaValue = targetGlassAlpha
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            reduceTransparencyFallbackLayer.opacity = targetFallbackOpacity
            CATransaction.commit()
            _ = MotionCoordinator.shared.complete(ticket)
        } else {
            MotionCoordinator.shared.animate(
                duration: MotionTokens.Duration.buttonState,
                timingFunction: .easeOut,
                ticket: ticket,
                action: {
                    self.glassEffectView?.animator().alphaValue = targetGlassAlpha
                }
            )
            let fallbackTicket = MotionCoordinator.shared.beginTransition(for: fallbackKey, category: .controlInteraction)
            MotionCoordinator.shared.animateLayerFloat(
                reduceTransparencyFallbackLayer,
                keyPath: "opacity",
                animationKey: "fallbackOpacity",
                to: CGFloat(targetFallbackOpacity),
                duration: MotionTokens.Duration.buttonState,
                timingFunction: .easeOut,
                ticket: fallbackTicket,
                setModel: { $0.opacity = Float($1) }
            )
        }
    }
}
