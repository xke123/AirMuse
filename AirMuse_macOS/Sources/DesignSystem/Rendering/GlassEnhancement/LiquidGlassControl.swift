import AppKit
import QuartzCore

// MARK: - LiquidGlassControl

/// Local macOS 26+ `NSGlassEffectView` enhancement wrapper for interactive capsules,
/// search fields, popovers, and hover pills.
/// - In `.original` mode: completely transparent/inactive so the original AIRPLAY skin is 100% pure.
/// - In `.enhanced` mode: activates a localized `NSGlassEffectView` (macOS 26+) inside the control's
///   exact silhouette without altering the outer AIRPLAY crystal frame.
@MainActor
open class LiquidGlassControl: NSView {

    private var glassEffectView: NSView?
    private var cornerRadiusValue: CGFloat = 8.0
    private var isEnhancementActive: Bool = false

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

    private func setup() {
        wantsLayer = true
        layer?.masksToBounds = true

        if #available(macOS 26.0, *) {
            let effect = NSGlassEffectView(frame: bounds)
            effect.autoresizingMask = [.width, .height]
            effect.style = .clear
            effect.cornerRadius = cornerRadiusValue
            effect.alphaValue = 0.0
            addSubview(effect)
            self.glassEffectView = effect
        }

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(renderModeChanged),
            name: GlassInteractionCoordinator.modeDidChangeNotification,
            object: nil
        )
        updateGlassAppearance()
    }

    open override func layout() {
        super.layout()
        glassEffectView?.frame = bounds
    }

    @objc private func renderModeChanged() {
        updateGlassAppearance()
    }

    private func updateGlassAppearance() {
        let enhanced = GlassInteractionCoordinator.shared.isEnhancedMode
        let targetAlpha: CGFloat = (enhanced && isEnhancementActive) ? 1.0 : 0.0

        if #available(macOS 26.0, *), let effect = glassEffectView as? NSGlassEffectView {
            effect.cornerRadius = cornerRadiusValue
        } else {
            layer?.cornerRadius = cornerRadiusValue
        }

        if MotionCoordinator.shared.isReduceMotionEnabled {
            glassEffectView?.alphaValue = targetAlpha
        } else {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = MotionTokens.Duration.buttonState
                glassEffectView?.animator().alphaValue = targetAlpha
            }
        }
    }
}
