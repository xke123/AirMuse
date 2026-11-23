import AppKit

// MARK: - GlassMiniPlayer

/// Widget-style Liquid Glass Mini Player bar (`NSGlassEffectView`).
open class GlassMiniPlayer: NSView {

    private var glassShellView: NSGlassEffectView!

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupMini()
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupMini()
    }

    private func setupMini() {
        wantsLayer = true
        layer?.masksToBounds = false

        let glass = NSGlassEffectView(frame: bounds)
        glass.style = .clear
        glass.cornerRadius = 8.0
        self.glassShellView = glass

        addSubview(glassShellView, positioned: .below, relativeTo: nil)
    }

    open override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let win = window {
            win.hasShadow = true
            win.invalidateShadow()
        }
    }

    open override func layout() {
        super.layout()
        glassShellView.frame = bounds
        window?.invalidateShadow()
    }
}
