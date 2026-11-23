import AppKit
import QuartzCore

// MARK: - GlassSurface

/// Authentic AIRPLAY-zion crystal glass window surface.
/// Renders the 9-slice `WINDOWGLASS` / `WINDOWGLASSFOCUS` border, middle body gradient,
/// physical groove seams, and optional Gaussian specular sweep via `PlayerLayerComposer`.
///
/// Liquid Glass strategy (macOS 26+):
/// - **Normal mode + frostedBars / alwaysShowGlassBars**: Two independent `NSGlassEffectView`
///   strips covering only the top cap (20 pt) and bottom cap (20 pt) — the middle body
///   rendered by the compositor remains fully opaque, so glass shows strictly in the bars.
/// - **Mini-strip mode** (height ≤ miniBarStandardHeight): A single full-coverage glass
///   view because the entire view IS the bar.
/// - **Original mode**: No glass shell; the classic AIRPLAY 9-slice bitmap is used as-is.
open class GlassSurface: NSView {

    public let composer = PlayerLayerComposer()

    // Two narrow glass strips for the top/bottom cap bars (normal mode).
    private var topBarGlass: NSView!
    private var bottomBarGlass: NSView!
    // Full-coverage glass for mini-strip mode (the whole view is a bar).
    private var fullStripGlass: NSView!

    private let composerHostView = NSView()

    /// Set `true` on secondary windows (Lyrics, Library) to always show the glass bars
    /// regardless of the global `useFrostedBarsInNormalMode` preference.
    public var alwaysShowGlassBars: Bool = false {
        didSet { needsLayout = true }
    }

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

    // MARK: - Glass Setup

    /// Creates a single `NSGlassEffectView` for a glass bar or full-strip surface.
    private func makeGlassView() -> NSGlassEffectView {
        let v = NSGlassEffectView(frame: .zero)
        v.style = .clear
        v.cornerRadius = OriginalDesignTokens.BaseMetrics.glassCornerRadius
        return v
    }

    private func setupGlass() {
        wantsLayer = true
        layer?.masksToBounds = false

        // Top cap glass strip.
        topBarGlass = makeGlassView()
        topBarGlass.isHidden = true
        addSubview(topBarGlass)

        // Bottom cap glass strip.
        bottomBarGlass = makeGlassView()
        bottomBarGlass.isHidden = true
        addSubview(bottomBarGlass)

        // Full-coverage glass for mini-strip mode (the whole view is a single bar).
        fullStripGlass = makeGlassView()
        fullStripGlass.isHidden = true
        addSubview(fullStripGlass)

        composerHostView.wantsLayer = true
        composerHostView.layer?.masksToBounds = false
        addSubview(composerHostView)

        if let hostLayer = composerHostView.layer {
            composer.attach(to: hostLayer)
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
        let coord = GlassInteractionCoordinator.shared
        let s = coord.uiScale
        let capH = OriginalDesignTokens.BaseMetrics.glassCapHeight * s
        let isMiniStrip = bounds.height <= (OriginalDesignTokens.BaseMetrics.miniBarStandardHeight * s + 2.0)

        // Whether to show glass at all: frosted-bars preference, explicit flag, or mini-strip.
        let wantGlass = coord.useFrostedBarsInNormalMode || alwaysShowGlassBars

        // Mini-strip: entire view is one glass bar → use fullStripGlass only.
        // Normal:     top + bottom cap bars → topBarGlass + bottomBarGlass.
        let showFull = isMiniStrip
        let showBars = wantGlass && !isMiniStrip

        topBarGlass.isHidden = !showBars
        bottomBarGlass.isHidden = !showBars
        fullStripGlass.isHidden = !showFull

        if showBars {
            topBarGlass.frame = NSRect(x: 0, y: bounds.height - capH, width: bounds.width, height: capH)
            bottomBarGlass.frame = NSRect(x: 0, y: 0, width: bounds.width, height: capH)
        }
        if showFull {
            fullStripGlass.frame = bounds
        }

        composerHostView.frame = bounds
        composerHostView.isHidden = isMiniStrip
        composer.backgroundLayer.isHidden = isMiniStrip
        composer.sweepLayer.isHidden = isMiniStrip
        composer.fogLayer.isHidden = isMiniStrip

        refreshGlassSurface()
    }

    public func triggerSpecularSweep(from startRatio: CGFloat, to endRatio: CGFloat) {
        let uiScale = GlassInteractionCoordinator.shared.uiScale
        let backingScale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2.0
        composer.triggerSweep(from: startRatio, to: endRatio, size: bounds.size, uiScale: uiScale, backingScale: backingScale)
    }

    @objc private func handleConfigChange() {
        needsLayout = true
        refreshGlassSurface()
    }

    @objc private func windowFocusChanged() {
        if let win = window {
            isFocusedSurface = win.isKeyWindow
        }
    }

    public func refreshGlassSurface() {
        guard let hostLayer = composerHostView.layer else { return }
        let coord = GlassInteractionCoordinator.shared
        let s = coord.uiScale
        let isMiniStrip = bounds.height <= (OriginalDesignTokens.BaseMetrics.miniBarStandardHeight * s + 2.0)

        if isMiniStrip { return }

        composer.attach(to: hostLayer)

        let backingScale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2.0
        composer.layout(bounds: bounds, backingScale: backingScale)

        let usesGlassBars = coord.useFrostedBarsInNormalMode || alwaysShowGlassBars
        composer.updateBackground(
            size: bounds.size,
            uiScale: coord.uiScale,
            backingScale: backingScale,
            resolution: coord.resolutionMode,
            focusRatio: usesGlassBars ? 1.0 : (isFocusedSurface ? 1.0 : 0.0),
            hasMainGloss: hasMainGloss,
            frostedBars: usesGlassBars,
            artworkKey: artworkCacheKey,
            artworkImage: ambientArtwork
        )
    }
}
