import AppKit

// MARK: - GlassMiniPlayer

/// Widget-style Liquid Glass Mini Player bar (`NSGlassEffectView` on macOS 26+,
/// falling back to `NSVisualEffectView` on earlier macOS versions).
open class GlassMiniPlayer: NSView {

    private var glassShellView: NSView!

    public var isFocusedSurface: Bool = true {
        didSet {
            guard oldValue != isFocusedSurface else { return }
            updateBorder()
        }
    }

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

        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView(frame: bounds)
            glass.style = .clear
            glass.cornerRadius = 8.0
            self.glassShellView = glass
        } else {
            let blur = NSVisualEffectView(frame: bounds)
            blur.blendingMode = .behindWindow
            blur.material = .hudWindow
            blur.state = .active
            blur.wantsLayer = true
            blur.layer?.masksToBounds = true
            blur.layer?.cornerRadius = 8.0
            blur.layer?.borderWidth = 1.0
            self.glassShellView = blur
        }

        addSubview(glassShellView, positioned: .below, relativeTo: nil)
        updateBorder()
    }

    open override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        NotificationCenter.default.removeObserver(self, name: NSWindow.didBecomeKeyNotification, object: nil)
        NotificationCenter.default.removeObserver(self, name: NSWindow.didResignKeyNotification, object: nil)
        if let win = window {
            win.hasShadow = true
            win.invalidateShadow()
            NotificationCenter.default.addObserver(self, selector: #selector(windowFocusChanged), name: NSWindow.didBecomeKeyNotification, object: win)
            NotificationCenter.default.addObserver(self, selector: #selector(windowFocusChanged), name: NSWindow.didResignKeyNotification, object: win)
            isFocusedSurface = win.isKeyWindow
        }
    }

    open override func layout() {
        super.layout()
        glassShellView.frame = bounds
        window?.invalidateShadow()
    }

    @objc private func windowFocusChanged() {
        if let win = window {
            isFocusedSurface = win.isKeyWindow
        }
    }

    private func updateBorder() {
        // macOS 26+: NSGlassEffectView tracks the window's key state automatically.
        // We do NOT manually dim the glass on focus loss — the user wants Liquid Glass
        // to remain at full intensity at all times.
        if #available(macOS 26.0, *) { return }
        // Fallback: adjust NSVisualEffectView border brightness.
        glassShellView.layer?.borderColor = NSColor(white: 1.0, alpha: isFocusedSurface ? 0.55 : 0.32).cgColor
    }
}
