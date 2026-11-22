import AppKit
import QuartzCore

// MARK: - GlassSurface

/// Authentic AIRPLAY-zion crystal glass window surface.
/// Renders the 9-slice `WINDOWGLASS` / `WINDOWGLASSFOCUS` border, middle body gradient,
/// physical groove seams, and optional Gaussian specular sweep via `PlayerLayerComposer`.
/// Does NOT use full-window `NSVisualEffectView` frosted blur.
open class GlassSurface: NSView {

    public let composer = PlayerLayerComposer()

    public var hasMainGloss: Bool = false {
        didSet {
            guard oldValue != hasMainGloss else { return }
            refreshGlassSurface()
        }
    }

    public var cornerRadius: CGFloat = OriginalDesignTokens.BaseMetrics.glassCornerRadius {
        didSet {
            layer?.cornerRadius = cornerRadius
        }
    }

    public var isFocusedSurface: Bool = true {
        didSet {
            guard oldValue != isFocusedSurface else { return }
            refreshGlassSurface()
        }
    }

    public var ambientArtwork: CGImage? {
        didSet {
            refreshGlassSurface()
        }
    }

    public var artworkCacheKey: String = "none"

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupGlass()
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupGlass()
    }

    private func setupGlass() {
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
        refreshGlassSurface()
    }

    open override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        refreshGlassSurface()
    }

    open override func layout() {
        super.layout()
        refreshGlassSurface()
    }

    public func triggerSpecularSweep(from startRatio: CGFloat, to endRatio: CGFloat) {
        let uiScale = GlassInteractionCoordinator.shared.uiScale
        let backingScale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2.0
        composer.triggerSweep(from: startRatio, to: endRatio, size: bounds.size, uiScale: uiScale, backingScale: backingScale)
    }

    @objc private func handleConfigChange() {
        refreshGlassSurface()
    }

    @objc private func windowFocusChanged() {
        if let win = window {
            isFocusedSurface = win.isKeyWindow
        }
    }

    public func refreshGlassSurface() {
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
            focusRatio: isFocusedSurface ? 1.0 : 0.0,
            hasMainGloss: hasMainGloss,
            artworkKey: artworkCacheKey,
            artworkImage: ambientArtwork
        )
    }
}
