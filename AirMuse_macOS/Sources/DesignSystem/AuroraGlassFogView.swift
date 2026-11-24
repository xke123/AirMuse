import AppKit
import CoreGraphics

// MARK: - AuroraGlassFogView

/// A universal, edge-adaptive crystal glass fog bar view replicating the authentic AIRPLAY
/// laser-like aurora mist diffusion behind normal-mode glass bar controls and titles.
///
/// Features:
/// - **Normal-Mode Only**: Automatically skips rendering in mini-strip mode (`isMiniModeDisabled` / height ≤ 10pt).
/// - **Directional Seam Adhesion**: The side touching the dark player/panel body is 100% solid
///   (`OriginalDesignTokens.Colors.spillFogDark`), feathering out to alpha 0.0 within ≤ 90% (88%) bar height.
/// - **Horizontal Laser Trapezoid**: Steep right-trapezoid anchor on the outer edge, elongated laser mist tail
///   extending toward the bar interior (right-to-left when `.right`, left-to-right when `.left`).
/// - **Event Transparency**: Transparent to clicks (`hitTest` returns nil unless a subview is hit).
@MainActor
open class AuroraGlassFogView: NSView {

    public var seamEdge: OriginalGlassRenderer.BarSeamEdge = .bottom {
        didSet {
            guard oldValue != seamEdge else { return }
            needsDisplay = true
        }
    }

    /// Disables fog rendering (e.g. when the host window switches to mini-bar mode).
    public var isFogEnabled: Bool = true {
        didSet {
            guard oldValue != isFogEnabled else { return }
            needsDisplay = true
        }
    }

    public var barCornerRadius: CGFloat? {
        didSet {
            guard oldValue != barCornerRadius else { return }
            needsDisplay = true
        }
    }

    public typealias PlumeItem = OriginalGlassRenderer.AuroraFogPlumeSpec

    public var plumes: [PlumeItem] = [] {
        didSet {
            guard oldValue != plumes else { return }
            needsDisplay = true
        }
    }

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
    }

    open override func hitTest(_ point: NSPoint) -> NSView? {
        // `point` is in superview coordinates; convert to `self` before forwarding to subviews
        let localPoint = convert(point, from: superview)
        guard bounds.contains(localPoint) else { return nil }
        for sub in subviews.reversed() where !sub.isHidden {
            if let hit = sub.hitTest(localPoint) {
                return hit
            }
        }
        return nil
    }

    /// Computes a `PlumeItem` covering the combined horizontal bounds of `views` in `self` coordinates.
    public func makePlume(
        for views: [NSView],
        alignment: OriginalGlassRenderer.AuroraFogAlignment,
        anchorSpread: CGFloat? = nil,
        tailLength: CGFloat? = nil,
        peakAlpha: CGFloat = 1.0
    ) -> PlumeItem? {
        let valid = views.filter { !$0.isHidden }
        guard !valid.isEmpty else { return nil }
        var minX: CGFloat = .greatestFiniteMagnitude
        var maxX: CGFloat = -.greatestFiniteMagnitude
        for v in valid {
            let rectInSelf = convert(v.bounds, from: v)
            minX = min(minX, rectInSelf.minX)
            maxX = max(maxX, rectInSelf.maxX)
        }
        let s = GlassInteractionCoordinator.shared.uiScale
        return PlumeItem(
            xMin: minX,
            xMax: maxX,
            alignment: alignment,
            anchorSpread: anchorSpread ?? (10.0 * s),
            tailLength: tailLength ?? (64.0 * s),
            peakAlpha: peakAlpha
        )
    }

    /// Convenience for single-cluster bars.
    public func setPlume(
        for views: [NSView],
        alignment: OriginalGlassRenderer.AuroraFogAlignment = .right,
        anchorSpread: CGFloat? = nil,
        tailLength: CGFloat? = nil,
        peakAlpha: CGFloat = 1.0
    ) {
        if let item = makePlume(
            for: views,
            alignment: alignment,
            anchorSpread: anchorSpread,
            tailLength: tailLength,
            peakAlpha: peakAlpha
        ) {
            plumes = [item]
        } else {
            plumes = []
        }
    }

    open override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard isFogEnabled, !plumes.isEmpty, bounds.height > 8.0 else { return }
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let s = GlassInteractionCoordinator.shared.uiScale
        let radius = barCornerRadius ?? (OriginalDesignTokens.BaseMetrics.glassCornerRadius * s)
        OriginalGlassRenderer.drawAuroraFogPlumes(
            in: ctx,
            barBounds: bounds,
            plumes: plumes,
            seamEdge: seamEdge,
            cornerRadius: radius
        )
    }
}
