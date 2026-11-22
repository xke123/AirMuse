import AppKit
import QuartzCore

// MARK: - GlassSurface

/// A native macOS Liquid Glass surface container view.
/// Adapts to system appearance, supporting NSVisualEffectView and modern glass borders.
open class GlassSurface: NSView {

    private let effectView = NSVisualEffectView()
    private let borderLayer = CAShapeLayer()
    private let highlightLayer = CAShapeLayer()

    public var cornerRadius: CGFloat = DesignTokens.CornerRadius.window {
        didSet {
            updateCorners()
        }
    }

    public var isFocusedSurface: Bool = false {
        didSet {
            updateBorderColor()
        }
    }

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

        // Configure visual effect view
        effectView.blendingMode = .behindWindow
        effectView.material = .hudWindow
        effectView.state = .active
        effectView.autoresizingMask = [.width, .height]
        effectView.frame = bounds
        addSubview(effectView, positioned: .below, relativeTo: nil)

        // Glass border outline
        borderLayer.fillColor = nil
        borderLayer.lineWidth = DesignTokens.Metrics.glassBorderWidth
        layer?.addSublayer(borderLayer)

        // Subtle specular highlight line at the top
        highlightLayer.fillColor = nil
        highlightLayer.lineWidth = 1.0
        highlightLayer.strokeColor = DesignTokens.Colors.glassHighlight.cgColor
        layer?.addSublayer(highlightLayer)

        updateCorners()
        updateBorderColor()
    }

    open override func layout() {
        super.layout()
        effectView.frame = bounds
        updatePath()
    }

    private func updateCorners() {
        wantsLayer = true
        layer?.cornerRadius = cornerRadius
        effectView.wantsLayer = true
        effectView.layer?.cornerRadius = cornerRadius
        effectView.layer?.masksToBounds = true
        updatePath()
    }

    private func updatePath() {
        guard bounds.width > 0, bounds.height > 0 else { return }
        let path = CGPath(roundedRect: bounds, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)
        borderLayer.path = path

        // Highlight line across top curve
        let highlightPath = CGMutablePath()
        highlightPath.addArc(center: CGPoint(x: cornerRadius, y: bounds.height - cornerRadius),
                             radius: cornerRadius, startAngle: .pi, endAngle: .pi * 0.5, clockwise: true)
        highlightPath.addLine(to: CGPoint(x: bounds.width - cornerRadius, y: bounds.height))
        highlightPath.addArc(center: CGPoint(x: bounds.width - cornerRadius, y: bounds.height - cornerRadius),
                             radius: cornerRadius, startAngle: .pi * 0.5, endAngle: 0, clockwise: true)
        highlightLayer.path = highlightPath
    }

    private func updateBorderColor() {
        if isFocusedSurface {
            borderLayer.strokeColor = DesignTokens.Colors.glassBorderLight.cgColor
        } else {
            borderLayer.strokeColor = DesignTokens.Colors.glassBorderDark.cgColor
        }
    }
}

