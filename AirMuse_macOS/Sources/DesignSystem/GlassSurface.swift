import AppKit
import QuartzCore

@MainActor
private final class ScrollCapOverlayView: NSView {
    private let glassView = NSGlassEffectView(frame: .zero)
    private let spriteLayer = CALayer()
    private let borderLayer = CALayer()
    private let isTop: Bool

    init(isTop: Bool) {
        self.isTop = isTop
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = true

        glassView.style = .clear
        glassView.autoresizingMask = [.width, .height]
        addSubview(glassView)

        spriteLayer.contentsGravity = .resize
        layer?.addSublayer(spriteLayer)

        borderLayer.borderWidth = 0.75
        borderLayer.borderColor = NSColor(white: 1.0, alpha: 0.28).cgColor
        layer?.addSublayer(borderLayer)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func configure(
        frame: NSRect,
        alpha: CGFloat,
        useNativeGlass: Bool,
        spriteImage: CGImage?,
        fullHeight: CGFloat,
        capHeight: CGFloat,
        cornerRadius: CGFloat,
        backingScale: CGFloat
    ) {
        self.isHidden = false
        self.alphaValue = alpha
        self.frame = frame

        let r = min(cornerRadius, min(frame.width, frame.height) * 0.5)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer?.cornerRadius = r
        if useNativeGlass {
            glassView.isHidden = false
            glassView.frame = bounds
            glassView.cornerRadius = r
            spriteLayer.isHidden = true
            borderLayer.isHidden = false
            borderLayer.frame = bounds
            borderLayer.cornerRadius = r
        } else {
            glassView.isHidden = true
            borderLayer.isHidden = true
            spriteLayer.isHidden = false
            spriteLayer.frame = bounds
            spriteLayer.contents = spriteImage
            spriteLayer.contentsScale = backingScale
            if fullHeight > capHeight, capHeight > 1 {
                let normH = min(1.0, max(0.01, capHeight / fullHeight))
                spriteLayer.contentsRect = isTop
                    ? CGRect(x: 0, y: 1.0 - normH, width: 1.0, height: normH)
                    : CGRect(x: 0, y: 0, width: 1.0, height: normH)
            } else {
                spriteLayer.contentsRect = CGRect(x: 0, y: 0, width: 1, height: 1)
            }
        }
        CATransaction.commit()
    }
}

// MARK: - GlassSurface

/// Authentic AIRPLAY-zion crystal glass window surface.
/// Renders the 9-slice `WINDOWGLASS` / `WINDOWGLASSFOCUS` border, middle body gradient,
/// physical groove seams, M07 focus crossfade, and M08 Gaussian specular sweep via `PlayerLayerComposer`.
///
/// Liquid Glass strategy (macOS 26+):
/// - **Original mode** (or Reduce Transparency enabled): No glass shell; classic AIRPLAY 9-slice bitmap.
/// - **Enhanced mode + frostedBars / alwaysShowGlassBars**: Two independent `NSGlassEffectView`
///   strips covering only the top cap and bottom cap — middle body stays opaque.
/// - **Mini-strip mode** (height ≤ miniBarStandardHeight): Full-coverage glass in Enhanced mode, or 9-slice mini crystal in Original mode.
open class GlassSurface: NSView {

    public let composer = PlayerLayerComposer()

    private var topBarGlass: NSGlassEffectView!
    private var bottomBarGlass: NSGlassEffectView!
    private var fullStripGlass: NSGlassEffectView!

    private let composerHostView = NSView()
    private let scrollTopCap = ScrollCapOverlayView(isTop: true)
    private let scrollBottomCap = ScrollCapOverlayView(isTop: false)
    private let scrollBodyMaskLayer = CAShapeLayer()
    private let scrollOuterMaskLayer = CAShapeLayer()
    public private(set) var isScrollPresentationActive: Bool = false

    /// Set `true` on secondary windows (Lyrics, Library) to always show the glass bars
    /// regardless of the global `useFrostedBarsInNormalMode` preference (except in Original or Reduce Transparency).
    public var alwaysShowGlassBars: Bool = false {
        didSet { needsLayout = true }
    }

    public var hasMainGloss: Bool = false {
        didSet {
            guard oldValue != hasMainGloss else { return }
            refreshGlassSurface(animateFocus: false)
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
            refreshGlassSurface(animateFocus: true)
        }
    }

    public var ambientArtwork: CGImage? {
        didSet {
            refreshGlassSurface(animateFocus: false)
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

    isolated deinit {
        NotificationCenter.default.removeObserver(self)
        composer.cancelAll()
    }

    private func makeGlassView() -> NSGlassEffectView {
        let v = NSGlassEffectView(frame: .zero)
        v.style = .clear
        v.cornerRadius = OriginalDesignTokens.BaseMetrics.glassCornerRadius
        return v
    }

    private func setupGlass() {
        wantsLayer = true
        layer?.masksToBounds = false

        topBarGlass = makeGlassView()
        topBarGlass.isHidden = true
        addSubview(topBarGlass)

        bottomBarGlass = makeGlassView()
        bottomBarGlass.isHidden = true
        addSubview(bottomBarGlass)

        fullStripGlass = makeGlassView()
        fullStripGlass.isHidden = true
        addSubview(fullStripGlass)

        composerHostView.wantsLayer = true
        composerHostView.layer?.masksToBounds = false
        addSubview(composerHostView)

        scrollTopCap.isHidden = true
        scrollBottomCap.isHidden = true
        addSubview(scrollTopCap)
        addSubview(scrollBottomCap)

        if let hostLayer = composerHostView.layer {
            composer.attach(to: hostLayer)
        }

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleConfigChange),
            name: GlassInteractionCoordinator.modeDidChangeNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleConfigChange),
            name: MotionAccessibility.preferencesDidChangeNotification,
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
        } else {
            composer.cancelAll()
            isFocusedSurface = false
        }
        refreshGlassSurface(animateFocus: false)
    }

    open override func viewDidHide() {
        super.viewDidHide()
        composer.cancelSweeps()
    }

    open override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        refreshGlassSurface(animateFocus: false)
    }

    open override func layout() {
        super.layout()
        let coord = GlassInteractionCoordinator.shared
        let s = coord.uiScale
        let capH = OriginalDesignTokens.BaseMetrics.glassCapHeight * s
        let isMiniStrip = bounds.height <= (OriginalDesignTokens.BaseMetrics.miniBarStandardHeight * s + 2.0)

        let allowNativeGlass = coord.isEnhancedMode && !MotionCoordinator.shared.isReduceTransparencyEnabled
        let wantGlass = allowNativeGlass && (coord.useFrostedBarsInNormalMode || alwaysShowGlassBars)

        let showFull = !isScrollPresentationActive && allowNativeGlass && isMiniStrip
        let showBars = !isScrollPresentationActive && wantGlass && !isMiniStrip

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
        let hideComposerForEnhancedMini = isMiniStrip && allowNativeGlass
        composerHostView.isHidden = hideComposerForEnhancedMini
        composer.backgroundLayer.isHidden = hideComposerForEnhancedMini
        composer.ambientTintLayer.isHidden = hideComposerForEnhancedMini
        composer.focusedOverlayLayer.isHidden = hideComposerForEnhancedMini
        composer.sweepLayer.isHidden = isMiniStrip

        refreshGlassSurface(animateFocus: false)
    }

    @discardableResult
    public func triggerSpecularSweep(from startRatio: CGFloat, to endRatio: CGFloat) -> Bool {
        let uiScale = GlassInteractionCoordinator.shared.uiScale
        let backingScale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2.0
        return composer.triggerSweep(from: startRatio, to: endRatio, size: bounds.size, uiScale: uiScale, backingScale: backingScale)
    }

    public func cancelSpecularSweeps() {
        composer.cancelSweeps()
    }

    @objc private func handleConfigChange() {
        if MotionCoordinator.shared.isReduceMotionEnabled {
            composer.cancelSweeps()
        }
        needsLayout = true
        refreshGlassSurface(animateFocus: false)
    }

    @objc private func windowFocusChanged() {
        if let win = window {
            isFocusedSurface = win.isKeyWindow
        } else {
            isFocusedSurface = false
        }
    }

    public func refreshGlassSurface() {
        refreshGlassSurface(animateFocus: false)
    }

    /// Positions the two glass bars independently for glass-bar scroll open/collapse transitions,
    /// clipping the middle dark body cleanly between `[bottomBarFrame.maxY .. topBarFrame.minY]`.
    public func applyScrollPresentation(
        topBarFrame: NSRect,
        bottomBarFrame: NSRect,
        barAlpha: CGFloat = 1.0,
        outerClipRect: NSRect? = nil
    ) {
        if composer.focusedOverlayLayer.contents == nil && composer.backgroundLayer.contents == nil {
            refreshGlassSurface(animateFocus: false)
        }
        isScrollPresentationActive = true
        topBarGlass.isHidden = true
        bottomBarGlass.isHidden = true
        fullStripGlass.isHidden = true

        let coord = GlassInteractionCoordinator.shared
        let s = coord.uiScale
        let capH = OriginalDesignTokens.BaseMetrics.glassCapHeight * s
        let radius = OriginalDesignTokens.BaseMetrics.glassCornerRadius * s
        let allowNativeGlass = coord.isEnhancedMode && !MotionCoordinator.shared.isReduceTransparencyEnabled
        let useNativeBars = allowNativeGlass && (coord.useFrostedBarsInNormalMode || alwaysShowGlassBars)
        let backingScale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2.0
        let sprite = Self.cgImage(from: composer.focusedOverlayLayer.contents)
            ?? Self.cgImage(from: composer.backgroundLayer.contents)

        if scrollTopCap.superview === self && subviews.last !== scrollBottomCap {
            addSubview(scrollTopCap, positioned: .above, relativeTo: nil)
            addSubview(scrollBottomCap, positioned: .above, relativeTo: scrollTopCap)
        }

        scrollTopCap.configure(
            frame: topBarFrame,
            alpha: barAlpha,
            useNativeGlass: useNativeBars,
            spriteImage: sprite,
            fullHeight: bounds.height,
            capHeight: capH,
            cornerRadius: radius,
            backingScale: backingScale
        )
        scrollBottomCap.configure(
            frame: bottomBarFrame,
            alpha: barAlpha,
            useNativeGlass: useNativeBars,
            spriteImage: sprite,
            fullHeight: bounds.height,
            capHeight: capH,
            cornerRadius: radius,
            backingScale: backingScale
        )

        let bodyMinY = bottomBarFrame.maxY
        let bodyMaxY = topBarFrame.minY
        let bodyRect: CGRect = bodyMaxY > bodyMinY + 0.5
            ? CGRect(x: 0, y: bodyMinY - 1.0, width: bounds.width, height: (bodyMaxY - bodyMinY) + 2.0)
            : .zero

        let clipOuter = outerClipRect ?? CGRect(
            x: 0,
            y: bottomBarFrame.minY,
            width: bounds.width,
            height: max(0, topBarFrame.maxY - bottomBarFrame.minY)
        )
        let outerR = min(radius, min(clipOuter.width, clipOuter.height) * 0.5)

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        scrollBodyMaskLayer.path = CGPath(rect: bodyRect, transform: nil)
        composerHostView.layer?.mask = scrollBodyMaskLayer

        scrollOuterMaskLayer.path = CGPath(
            roundedRect: clipOuter,
            cornerWidth: outerR,
            cornerHeight: outerR,
            transform: nil
        )
        layer?.mask = scrollOuterMaskLayer
        CATransaction.commit()
    }

    /// Ends scroll-unroll presentation and restores normal glass bars and masks.
    public func clearScrollPresentation() {
        guard isScrollPresentationActive || layer?.mask != nil || composerHostView.layer?.mask != nil else { return }
        isScrollPresentationActive = false
        scrollTopCap.isHidden = true
        scrollBottomCap.isHidden = true
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        composerHostView.layer?.mask = nil
        layer?.mask = nil
        CATransaction.commit()
        needsLayout = true
        refreshGlassSurface(animateFocus: false)
    }

    private static func cgImage(from any: Any?) -> CGImage? {
        guard let any else { return nil }
        let cf = any as CFTypeRef
        guard CFGetTypeID(cf) == CGImage.typeID else { return nil }
        return unsafeDowncast(cf, to: CGImage.self)
    }

    public func refreshGlassSurface(animateFocus: Bool) {
        guard let hostLayer = composerHostView.layer else { return }
        let coord = GlassInteractionCoordinator.shared
        let s = coord.uiScale
        let isMiniStrip = bounds.height <= (OriginalDesignTokens.BaseMetrics.miniBarStandardHeight * s + 2.0)
        let allowNativeGlass = coord.isEnhancedMode && !MotionCoordinator.shared.isReduceTransparencyEnabled

        if isMiniStrip && allowNativeGlass { return }

        composer.attach(to: hostLayer)

        let backingScale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2.0
        composer.layout(bounds: bounds, backingScale: backingScale)

        let usesGlassBars = allowNativeGlass && (coord.useFrostedBarsInNormalMode || alwaysShowGlassBars)
        composer.updateBackground(
            size: bounds.size,
            uiScale: coord.uiScale,
            backingScale: backingScale,
            resolution: coord.resolutionMode,
            focusRatio: usesGlassBars ? 1.0 : (isFocusedSurface ? 1.0 : 0.0),
            hasMainGloss: hasMainGloss,
            frostedBars: usesGlassBars,
            artworkKey: artworkCacheKey,
            artworkImage: ambientArtwork,
            animateFocus: animateFocus
        )
    }
}
