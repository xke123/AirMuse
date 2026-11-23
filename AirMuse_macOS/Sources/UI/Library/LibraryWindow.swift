import AppKit
import Domain
import DesignSystem

// MARK: - LibraryWindow

/// Floating glass panel for the music library and catalog browser.
open class LibraryWindow: NSPanel {

    public override init(contentRect: NSRect, styleMask style: NSWindow.StyleMask, backing backingStoreType: NSWindow.BackingStoreType, defer flag: Bool) {
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: flag
        )
        isFloatingPanel = true
        level = .floating
        isOpaque = false
        backgroundColor = .clear
        // macOS 26+ Liquid Glass requires window compositor participation.
        if #available(macOS 26.0, *) {
            hasShadow = true
            invalidateShadow()
        } else {
            hasShadow = false
        }
        isMovableByWindowBackground = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    }

    // Allow becoming key so NSGlassEffectView always renders at active intensity.
    public override var canBecomeKey: Bool { true }
    public override var canBecomeMain: Bool { false }
}

