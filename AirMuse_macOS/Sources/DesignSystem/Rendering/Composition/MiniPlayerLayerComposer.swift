import AppKit
import QuartzCore

// MARK: - MiniPlayerLayerComposer

/// Composes the AIRPLAY Mini Player's joined-cap crystal bar (40pt / 30pt @ 1×)
/// without any opaque dark rectangle fill.
@MainActor
public final class MiniPlayerLayerComposer {

    public let backgroundLayer = CALayer()

    public init() {
        backgroundLayer.contentsGravity = .resize
        backgroundLayer.needsDisplayOnBoundsChange = false
    }

    public func attach(to rootLayer: CALayer) {
        if backgroundLayer.superlayer == nil {
            rootLayer.insertSublayer(backgroundLayer, at: 0)
        }
    }

    public func layout(bounds: CGRect, backingScale: CGFloat) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        backgroundLayer.frame = bounds
        backgroundLayer.contentsScale = backingScale
        CATransaction.commit()
    }

    public func updateBackground(
        size: CGSize,
        uiScale: CGFloat,
        backingScale: CGFloat,
        resolution: SkinResolutionMode,
        focusRatio: CGFloat
    ) {
        guard size.width > 1, size.height > 1 else { return }

        let key = RenderCache.Key(
            width: size.width,
            height: size.height,
            uiScale: uiScale,
            backingScale: backingScale,
            resolution: resolution,
            focusRatio: focusRatio,
            hasMainGloss: false,
            artworkKey: "mini"
        )

        if let cached = RenderCache.shared.image(for: key) {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            backgroundLayer.contents = cached
            CATransaction.commit()
            return
        }

        let pxW = max(1, Int(round(size.width * backingScale)))
        let pxH = max(1, Int(round(size.height * backingScale)))
        let cs = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil,
            width: pxW,
            height: pxH,
            bitsPerComponent: 8,
            bytesPerRow: pxW * 4,
            space: cs,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return }

        ctx.scaleBy(x: backingScale, y: backingScale)
        ctx.clear(CGRect(origin: .zero, size: size))
        OriginalGlassRenderer.drawGlassFrame(
            in: ctx,
            size: size,
            uiScale: uiScale,
            resolution: resolution,
            focusRatio: focusRatio,
            hasMainGloss: false,
            ambientArtwork: nil
        )

        if let rendered = ctx.makeImage() {
            RenderCache.shared.store(rendered, for: key)
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            backgroundLayer.contents = rendered
            CATransaction.commit()
        }
    }
}
