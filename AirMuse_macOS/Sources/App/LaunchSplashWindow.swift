import AppKit
import DesignSystem

// MARK: - LaunchSplashView

@MainActor
private final class LaunchSplashView: NSView {
    private let glassView = NSGlassEffectView(frame: .zero)
    private let emblemView = SplashEmblemView()
    private let titleLabel = NSTextField(labelWithString: "AirMuse")
    private let statusLabel = NSTextField(labelWithString: "正在启动后台引擎…")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupViews()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupViews()
    }

    private func setupViews() {
        wantsLayer = true
        layer?.masksToBounds = false

        glassView.style = .regular
        glassView.cornerRadius = 24
        glassView.autoresizingMask = [.width, .height]
        addSubview(glassView, positioned: .below, relativeTo: nil)

        addSubview(emblemView)

        titleLabel.font = NSFont.systemFont(ofSize: 20, weight: .bold)
        titleLabel.textColor = OriginalDesignTokens.Colors.titleSilver
        titleLabel.alignment = .center
        addSubview(titleLabel)

        statusLabel.font = NSFont.systemFont(ofSize: 11.5, weight: .medium)
        statusLabel.textColor = OriginalDesignTokens.Colors.glassBarForegroundMuted
        statusLabel.alignment = .center
        addSubview(statusLabel)
    }

    override func layout() {
        super.layout()
        let w = bounds.width
        let h = bounds.height
        glassView.frame = bounds
        glassView.cornerRadius = 24

        let emblemSize: CGFloat = 68
        emblemView.frame = NSRect(x: (w - emblemSize) * 0.5, y: h - 30 - emblemSize, width: emblemSize, height: emblemSize)
        titleLabel.frame = NSRect(x: 16, y: emblemView.frame.minY - 32, width: w - 32, height: 26)
        statusLabel.frame = NSRect(x: 16, y: 20, width: w - 32, height: 18)
    }

    func updateStatus(_ text: String) {
        statusLabel.stringValue = text
    }
}

// MARK: - SplashEmblemView

@MainActor
private final class SplashEmblemView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let rect = bounds.insetBy(dx: 4, dy: 4)
        let cx = rect.midX
        let cy = rect.midY
        let r = min(rect.width, rect.height) * 0.5
        let cs = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()

        // Outer ambient cyan glow
        if let glow = CGGradient(
            colorsSpace: cs,
            colors: [
                CGColor(srgbRed: 130/255.0, green: 215/255.0, blue: 255/255.0, alpha: 0.38),
                CGColor(srgbRed: 130/255.0, green: 215/255.0, blue: 255/255.0, alpha: 0.0)
            ] as CFArray,
            locations: [0.0, 1.0]
        ) {
            ctx.drawRadialGradient(glow, startCenter: CGPoint(x: cx, y: cy), startRadius: r * 0.25, endCenter: CGPoint(x: cx, y: cy), endRadius: r * 1.15, options: [])
        }

        // Crystal orb body
        let orbRect = CGRect(x: cx - r * 0.82, y: cy - r * 0.82, width: r * 1.64, height: r * 1.64)
        let orbPath = CGPath(ellipseIn: orbRect, transform: nil)
        ctx.saveGState()
        ctx.addPath(orbPath)
        ctx.clip()

        if let bodyGrad = CGGradient(
            colorsSpace: cs,
            colors: [
                CGColor(srgbRed: 96/255.0, green: 112/255.0, blue: 132/255.0, alpha: 0.92),
                CGColor(srgbRed: 34/255.0, green: 38/255.0, blue: 46/255.0, alpha: 0.96)
            ] as CFArray,
            locations: [0.0, 1.0]
        ) {
            ctx.drawLinearGradient(bodyGrad, start: CGPoint(x: cx, y: orbRect.maxY), end: CGPoint(x: cx, y: orbRect.minY), options: [])
        }

        // Top specular crescent
        let specRect = CGRect(x: orbRect.minX + 6, y: orbRect.midY + 2, width: orbRect.width - 12, height: orbRect.height * 0.42)
        if let specGrad = CGGradient(
            colorsSpace: cs,
            colors: [
                CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.55),
                CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.0)
            ] as CFArray,
            locations: [0.0, 1.0]
        ) {
            ctx.saveGState()
            ctx.addEllipse(in: specRect)
            ctx.clip()
            ctx.drawLinearGradient(specGrad, start: CGPoint(x: cx, y: specRect.maxY), end: CGPoint(x: cx, y: specRect.minY), options: [])
            ctx.restoreGState()
        }
        ctx.restoreGState()

        // Crisp glass rim
        ctx.saveGState()
        ctx.addPath(orbPath)
        ctx.setStrokeColor(CGColor(srgbRed: 235/255.0, green: 245/255.0, blue: 255/255.0, alpha: 0.65))
        ctx.setLineWidth(1.2)
        ctx.strokePath()
        ctx.restoreGState()

        // Center music note symbol
        let cfg = NSImage.SymbolConfiguration(pointSize: 26, weight: .semibold)
        if let sym = NSImage(systemSymbolName: "music.note", accessibilityDescription: "AirMuse")?.withSymbolConfiguration(cfg) {
            let tinted = NSImage(size: sym.size, flipped: false) { drawRect in
                sym.draw(in: drawRect)
                OriginalDesignTokens.Colors.titleSilver.set()
                drawRect.fill(using: .sourceAtop)
                return true
            }
            let iconRect = NSRect(x: cx - sym.size.width * 0.5, y: cy - sym.size.height * 0.5, width: sym.size.width, height: sym.size.height)
            tinted.draw(in: iconRect)
        }
    }
}

// MARK: - LaunchSplashWindow

/// 2-second floating Liquid Glass splash shown on launch while background services warm up.
@MainActor
public final class LaunchSplashWindow: NSPanel {

    private let splashView = LaunchSplashView(frame: NSRect(x: 0, y: 0, width: 256, height: 176))

    public init() {
        let size = NSSize(width: 256, height: 176)
        let screenFrame = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let origin = NSPoint(
            x: screenFrame.midX - size.width * 0.5,
            y: screenFrame.midY - size.height * 0.5 + 30
        )
        super.init(
            contentRect: NSRect(origin: origin, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        level = .floating
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        contentView = splashView
    }

    public func present() {
        alphaValue = 0.0
        makeKeyAndOrderFront(nil)
        NSApp.activate()
        if MotionCoordinator.shared.isReduceMotionEnabled {
            alphaValue = 1.0
        } else {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.22
                animator().alphaValue = 1.0
            }
        }
    }

    public func updateStatus(_ text: String) {
        splashView.updateStatus(text)
    }

    public func dismiss(completion: @escaping @MainActor () -> Void) {
        if MotionCoordinator.shared.isReduceMotionEnabled {
            orderOut(nil)
            completion()
            return
        }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.24
            animator().alphaValue = 0.0
        }, completionHandler: { [weak self] in
            Task { @MainActor in
                self?.orderOut(nil)
                completion()
            }
        })
    }

    public override var canBecomeKey: Bool { true }
}
