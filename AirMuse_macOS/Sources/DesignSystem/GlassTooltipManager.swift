import AppKit
import QuartzCore

// MARK: - GlassTooltipManager (M20)

/// Localized non-occluding glass tooltip with 400ms hover dwell delay, 120ms enter fade,
/// instant dismissal on exit/target switch, and HINTGLASS / high-contrast opaque fallbacks.
@MainActor
public final class GlassTooltipManager {

    public static let shared = GlassTooltipManager()

    private let ownerID = "GlassTooltip"
    private var panel: NSPanel?
    private var label = NSTextField(labelWithString: "")
    private var glassView = NSGlassEffectView(frame: .zero)
    private var fallbackLayer = CALayer()
    private var dwellTask: Task<Void, Never>?
    private weak var currentTarget: NSView?

    public var isTooltipVisible: Bool { panel?.isVisible == true && (panel?.alphaValue ?? 0) > 0.01 }
    public var currentTooltipText: String? { isTooltipVisible ? label.stringValue : nil }

    public init() {}

    isolated deinit {
        hideImmediately()
    }

    /// Schedules tooltip display after `MotionTokens.Duration.tooltipDelay` (400ms).
    /// Cancels any previous target's pending or visible tooltip immediately.
    public func scheduleTooltip(text: String, for target: NSView, delay: TimeInterval = MotionTokens.Duration.tooltipDelay) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            hideImmediately()
            return
        }
        if currentTarget !== target {
            hideImmediately()
        }
        currentTarget = target
        dwellTask?.cancel()
        dwellTask = Task { @MainActor [weak self, weak target] in
            if delay > 0.001 {
                try? await Task.sleep(for: .milliseconds(Int(delay * 1000)))
            }
            guard !Task.isCancelled, let self, let target, target.window != nil, !target.isHiddenOrHasHiddenAncestor else { return }
            self.present(text: trimmed, above: target)
        }
    }

    public func hideImmediately() {
        dwellTask?.cancel()
        dwellTask = nil
        currentTarget = nil
        MotionCoordinator.shared.cancel(key: TransitionKey(owner: ownerID, channel: "present"))
        panel?.orderOut(nil)
    }

    private func ensurePanel() -> NSPanel {
        if let p = panel { return p }
        let p = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 120, height: 24),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        p.isFloatingPanel = true
        p.level = .popUpMenu
        p.isOpaque = false
        p.backgroundColor = .clear
        p.ignoresMouseEvents = true
        p.hasShadow = true

        let content = NSView(frame: NSRect(x: 0, y: 0, width: 120, height: 24))
        content.wantsLayer = true

        fallbackLayer.backgroundColor = NSColor(srgbRed: 22/255.0, green: 24/255.0, blue: 28/255.0, alpha: 0.94).cgColor
        fallbackLayer.borderColor = NSColor(white: 1.0, alpha: 0.28).cgColor
        fallbackLayer.borderWidth = 0.8
        fallbackLayer.cornerRadius = 6
        content.layer?.addSublayer(fallbackLayer)

        glassView.style = .clear
        glassView.cornerRadius = 6
        glassView.autoresizingMask = [.width, .height]
        content.addSubview(glassView)

        label.font = NSFont.systemFont(ofSize: 11.0, weight: .medium)
        label.textColor = OriginalDesignTokens.Colors.titleSilver
        label.alignment = .center
        content.addSubview(label)

        p.contentView = content
        self.panel = p
        return p
    }

    private func present(text: String, above target: NSView) {
        guard let win = target.window else { return }
        let p = ensurePanel()
        label.stringValue = text
        let textSize = label.attributedStringValue.size()
        let w = ceil(textSize.width) + 16
        let h: CGFloat = 22

        let targetInWin = target.convert(target.bounds, to: nil)
        let targetInScreen = win.convertToScreen(targetInWin)

        // Position strictly outside control bounds (above, or below if near top screen edge)
        let vf = win.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        var y = targetInScreen.maxY + 6
        if y + h > vf.maxY - 4 {
            y = targetInScreen.minY - h - 6
        }
        let x = min(max(targetInScreen.midX - w * 0.5, vf.minX + 6), vf.maxX - w - 6)

        p.setFrame(NSRect(x: x, y: y, width: w, height: h), display: true)
        p.contentView?.frame = NSRect(x: 0, y: 0, width: w, height: h)
        glassView.frame = NSRect(x: 0, y: 0, width: w, height: h)
        label.frame = NSRect(x: 6, y: 3, width: w - 12, height: 16)

        let useGlass = GlassInteractionCoordinator.shared.isEnhancedMode && !MotionCoordinator.shared.isReduceTransparencyEnabled
        glassView.isHidden = !useGlass
        fallbackLayer.isHidden = useGlass
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        fallbackLayer.frame = NSRect(x: 0, y: 0, width: w, height: h)
        CATransaction.commit()

        let ticket = MotionCoordinator.shared.beginTransition(for: TransitionKey(owner: ownerID, channel: "present"), category: .decorative) { [weak p] in
            p?.orderOut(nil)
        }

        if MotionCoordinator.shared.isReduceMotionEnabled {
            p.alphaValue = 1.0
            p.orderFront(nil)
            _ = MotionCoordinator.shared.complete(ticket)
        } else {
            p.alphaValue = 0.0
            p.orderFront(nil)
            MotionCoordinator.shared.animate(
                duration: MotionTokens.Duration.tooltipIn,
                timingFunction: .easeOut,
                ticket: ticket,
                action: {
                    p.animator().alphaValue = 1.0
                }
            )
        }
    }
}
