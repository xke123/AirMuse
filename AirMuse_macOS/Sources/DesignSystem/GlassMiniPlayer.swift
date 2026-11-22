import AppKit

// MARK: - GlassMiniPlayer

/// The 40pt (1×) / 60pt (1.5×) height AIRPLAY Mini Player crystal bar container.
/// Uses `MiniPlayerLayerComposer` with pure transparent 9-slice glass caps and
/// zero opaque dark background fill.
open class GlassMiniPlayer: NSView {

    public let composer = MiniPlayerLayerComposer()

    public var isFocusedSurface: Bool = true {
        didSet {
            guard oldValue != isFocusedSurface else { return }
            refreshMiniGlass()
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
        if let rootLayer = layer {
            composer.attach(to: rootLayer)
        }

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleConfigChange),
            name: GlassInteractionCoordinator.modeDidChangeNotification,
            object: nil
        )
    }

    open override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        NotificationCenter.default.removeObserver(self, name: NSWindow.didBecomeKeyNotification, object: nil)
        NotificationCenter.default.removeObserver(self, name: NSWindow.didResignKeyNotification, object: nil)
        if let win = window {
            NotificationCenter.default.addObserver(self, selector: #selector(windowFocusChanged), name: NSWindow.didBecomeKeyNotification, object: win)
            NotificationCenter.default.addObserver(self, selector: #selector(windowFocusChanged), name: NSWindow.didResignKeyNotification, object: win)
            isFocusedSurface = win.isKeyWindow
        }
        refreshMiniGlass()
    }

    open override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        refreshMiniGlass()
    }

    open override func layout() {
        super.layout()
        refreshMiniGlass()
    }

    @objc private func handleConfigChange() {
        refreshMiniGlass()
    }

    @objc private func windowFocusChanged() {
        if let win = window {
            isFocusedSurface = win.isKeyWindow
        }
    }

    public func refreshMiniGlass() {
        guard let rootLayer = layer else { return }
        composer.attach(to: rootLayer)
        let backingScale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2.0
        composer.layout(bounds: bounds, backingScale: backingScale)

        let coord = GlassInteractionCoordinator.shared
        composer.updateBackground(
            size: bounds.size,
            uiScale: coord.uiScale,
            backingScale: backingScale,
            resolution: coord.resolutionMode,
            focusRatio: isFocusedSurface ? 1.0 : 0.0
        )
    }
}
