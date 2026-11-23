import AppKit
import CoreGraphics

// MARK: - AuroraGlassFogView

/// A universal, edge-adaptive crystal glass fog bar view replicating the authentic AIRPLAY
/// aurora-style mist diffusion.
///
/// Features:
/// - **Directional Seam Adhesion**: The side touching the dark player/panel body is 100% solid dark
///   (alpha 1.0), appearing as an organic extension of the dark panel into the crystal glass bar.
/// - **88% Height Ceiling**: Feathers out smoothly along the Y-axis and strictly hits alpha 0.0 before
///   reaching the outer edge (≤ 88% bar height, keeping the top/bottom glass reflection visible).
/// - **Dynamic Aurora Plumes**: Adapts horizontally to arbitrary text lengths and button clusters,
///   providing dense backing under controls with smooth elliptical wing diffusion on either side.
/// - **Event Transparency**: Transparent to clicks (`hitTest` returns nil unless a subview is hit),
///   letting drag handles and panel gestures pass through naturally.
@MainActor
open class AuroraGlassFogView: NSView {

    public var seamEdge: OriginalGlassRenderer.BarSeamEdge = .bottom {
        didSet { needsDisplay = true }
    }

    public struct PlumeItem: Sendable {
        public var xMin: CGFloat
        public var xMax: CGFloat
        public var spreadLeft: CGFloat
        public var spreadRight: CGFloat
        public var peakAlpha: CGFloat

        public init(
            xMin: CGFloat,
            xMax: CGFloat,
            spreadLeft: CGFloat = 28.0,
            spreadRight: CGFloat = 28.0,
            peakAlpha: CGFloat = 1.0
        ) {
            self.xMin = xMin
            self.xMax = xMax
            self.spreadLeft = spreadLeft
            self.spreadRight = spreadRight
            self.peakAlpha = peakAlpha
        }
    }

    public var plumes: [PlumeItem] = [] {
        didSet { needsDisplay = true }
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
        // Forward hit tests to clickable subviews (like buttons inside this view)
        for sub in subviews.reversed() where !sub.isHidden {
            let pt = sub.convert(point, from: self)
            if let hit = sub.hitTest(pt) {
                return hit
            }
        }
        return nil
    }

    /// Sets or updates a plume covering the combined bounding box of the given subviews/controls.
    public func setPlume(
        for views: [NSView],
        spreadLeft: CGFloat = 28.0,
        spreadRight: CGFloat = 28.0,
        peakAlpha: CGFloat = 1.0
    ) {
        let valid = views.filter { !$0.isHidden }
        guard !valid.isEmpty else {
            plumes = []
            return
        }
        var minX: CGFloat = .greatestFiniteMagnitude
        var maxX: CGFloat = -.greatestFiniteMagnitude
        for v in valid {
            let rectInSelf = convert(v.bounds, from: v)
            minX = min(minX, rectInSelf.minX)
            maxX = max(maxX, rectInSelf.maxX)
        }
        plumes = [PlumeItem(xMin: minX, xMax: maxX, spreadLeft: spreadLeft, spreadRight: spreadRight, peakAlpha: peakAlpha)]
    }

    open override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        for plume in plumes {
            OriginalGlassRenderer.drawAuroraFogPlume(
                in: ctx,
                barBounds: bounds,
                xMin: plume.xMin,
                xMax: plume.xMax,
                seamEdge: seamEdge,
                spreadLeft: plume.spreadLeft,
                spreadRight: plume.spreadRight,
                peakAlpha: plume.peakAlpha
            )
        }
    }
}
