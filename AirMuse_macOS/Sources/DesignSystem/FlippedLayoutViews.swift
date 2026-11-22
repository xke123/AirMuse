import AppKit

// MARK: - FlippedClipView

/// An NSClipView subclass that ensures content origin is anchored at the top (isFlipped = true),
/// avoiding AppKit's default behavior where flipped subviews get pushed to the bottom.
open class FlippedClipView: NSClipView {
    open override var isFlipped: Bool { true }
}

// MARK: - FlippedStackView

/// An NSStackView subclass that computes top-down layouts in macOS coordinates.
open class FlippedStackView: NSStackView {
    open override var isFlipped: Bool { true }
}
