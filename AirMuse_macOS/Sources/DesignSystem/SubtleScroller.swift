import AppKit

// MARK: - SubtleOverlayScroller

/// Unified, ultra-thin (6pt) translucent overlay scroller with zero opaque track background.
/// Ensures all scrollviews across Lyrics, Library Sidebar, and Library Content share the exact
/// same discreet visual weight regardless of system scrollbar preferences.
public final class SubtleOverlayScroller: NSScroller {

    public override class var isCompatibleWithOverlayScrollers: Bool { true }

    public override class func scrollerWidth(for controlSize: NSControl.ControlSize, scrollerStyle: NSScroller.Style) -> CGFloat {
        return 6.0
    }

    public override func draw(_ dirtyRect: NSRect) {
        // Intentionally omit track background; draw only the thin translucent silver knob.
        drawKnob()
    }

    public override func drawKnob() {
        let knobRect = rect(for: .knob)
        guard knobRect.height > 4, knobRect.width > 1 else { return }
        let inset = knobRect.insetBy(dx: 1.5, dy: 2.0)
        guard inset.width > 0.5, inset.height > 2.0 else { return }
        let r = inset.width * 0.5
        let path = NSBezierPath(roundedRect: inset, xRadius: r, yRadius: r)
        NSColor(srgbRed: 201/255.0, green: 201/255.0, blue: 201/255.0, alpha: 0.28).setFill()
        path.fill()
    }
}

public extension NSScrollView {
    /// Applies AirMuse's unified 6pt subtle overlay scrollbar styling.
    @MainActor
    func applySubtleOverlayScrollbar() {
        scrollerStyle = .overlay
        scrollerKnobStyle = .light
        autohidesScrollers = true
        hasVerticalScroller = true
        hasHorizontalScroller = false
        verticalScroller = SubtleOverlayScroller()
    }
}
