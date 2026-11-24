import AppKit
import QuartzCore

// MARK: - GlassMiniPlayer

/// Dual-mode Mini Player bar surface:
/// - **Enhanced mode** (without Reduce Transparency): Native macOS 26+ `NSGlassEffectView`.
/// - **Original mode** (or Reduce Transparency): Classic AIRPLAY 9-slice crystal mini strip (`WINDOWGLASS`/`WINDOWGLASSFOCUS`)
///   with M07 220ms focus crossfade via `MiniPlayerLayerComposer`.
open class GlassMiniPlayer: NSView {

    private var glassShellView: NSGlassEffectView!
    private let originalHostView = NSView()
    public let composer = MiniPlayerLayerComposer()

    public var isFocusedSurface: Bool = true {
        didSet {
            guard oldValue != isFocusedSurface else { return }
            refreshAppearance(animateFocus: true)
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

    isolated deinit {
        NotificationCenter.default.removeObserver(self)
    }

    private func setupMini() {
        wantsLayer = true
        layer?.masksToBounds = false

        originalHostView.wantsLayer = true
        originalHostView.layer?.masksToBounds = false
        originalHostView.autoresizingMask = [.width, .height]
        addSubview(originalHostView, positioned: .below, relativeTo: nil)
        if let hostLayer = originalHostView.layer {
            composer.attach(to: hostLayer)
        }

        let glass = NSGlassEffectView(frame: bounds)
        glass.style = .clear
        glass.cornerRadius = 8.0
        self.glassShellView = glass
        addSubview(glassShellView, positioned: .above, relativeTo: originalHostView)

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
            win.hasShadow = true
            win.invalidateShadow()
            NotificationCenter.default.addObserver(self, selector: #selector(windowFocusChanged), name: NSWindow.didBecomeKeyNotification, object: win)
            NotificationCenter.default.addObserver(self, selector: #selector(windowFocusChanged), name: NSWindow.didResignKeyNotification, object: win)
            isFocusedSurface = win.isKeyWindow
        } else {
            isFocusedSurface = false
        }
        refreshAppearance(animateFocus: false)
    }

    open override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        refreshAppearance(animateFocus: false)
    }

    open override func layout() {
        super.layout()
        glassShellView.frame = bounds
        originalHostView.frame = bounds
        refreshAppearance(animateFocus: false)
    }

    @objc private func handleConfigChange() {
        needsLayout = true
        refreshAppearance(animateFocus: false)
    }

    @objc private func windowFocusChanged() {
        if let win = window {
            isFocusedSurface = win.isKeyWindow
        } else {
            isFocusedSurface = false
        }
    }

    public func refreshAppearance(animateFocus: Bool = false) {
        let coord = GlassInteractionCoordinator.shared
        let useNativeGlass = coord.isEnhancedMode && !MotionCoordinator.shared.isReduceTransparencyEnabled
        glassShellView.isHidden = !useNativeGlass
        originalHostView.isHidden = useNativeGlass

        if !useNativeGlass, let hostLayer = originalHostView.layer {
            composer.attach(to: hostLayer)
            let backingScale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2.0
            composer.layout(bounds: bounds, backingScale: backingScale)
            composer.updateBackground(
                size: bounds.size,
                uiScale: coord.uiScale,
                backingScale: backingScale,
                resolution: coord.resolutionMode,
                focusRatio: isFocusedSurface ? 1.0 : 0.0,
                animateFocus: animateFocus
            )
        }
    }
}
