import AppKit
import QuartzCore

// MARK: - MiniPlayerLayerComposer

/// Composes the AIRPLAY Mini Player's joined-cap crystal bar (30pt @ 1×)
/// without any opaque dark rectangle fill, supporting M07 GPU focus crossfade.
@MainActor
public final class MiniPlayerLayerComposer {

    public let backgroundLayer = CALayer()
    public let focusedOverlayLayer = CALayer()

    private let ownerID = "MiniPlayerLayerComposer-\(UUID().uuidString)"
    private var lastTargetFocusRatio: CGFloat = 1.0

    public init() {
        backgroundLayer.contentsGravity = .resize
        backgroundLayer.needsDisplayOnBoundsChange = false

        focusedOverlayLayer.contentsGravity = .resize
        focusedOverlayLayer.needsDisplayOnBoundsChange = false
        focusedOverlayLayer.opacity = 1.0
    }

    public func attach(to rootLayer: CALayer) {
        if backgroundLayer.superlayer == nil {
            rootLayer.insertSublayer(backgroundLayer, at: 0)
        }
        if focusedOverlayLayer.superlayer == nil {
            rootLayer.insertSublayer(focusedOverlayLayer, above: backgroundLayer)
        }
    }

    public func layout(bounds: CGRect, backingScale: CGFloat) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        backgroundLayer.frame = bounds
        backgroundLayer.contentsScale = backingScale
        focusedOverlayLayer.frame = bounds
        focusedOverlayLayer.contentsScale = backingScale
        CATransaction.commit()
    }

    public func updateBackground(
        size: CGSize,
        uiScale: CGFloat,
        backingScale: CGFloat,
        resolution: SkinResolutionMode,
        focusRatio: CGFloat,
        animateFocus: Bool = false
    ) {
        guard size.width > 1, size.height > 1 else { return }

        let unfocused = cachedOrRender(size: size, uiScale: uiScale, backingScale: backingScale, resolution: resolution, focusRatio: 0.0)
        let focused = cachedOrRender(size: size, uiScale: uiScale, backingScale: backingScale, resolution: resolution, focusRatio: 1.0)

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        backgroundLayer.contents = unfocused
        focusedOverlayLayer.contents = focused
        CATransaction.commit()

        let clampedFocus = min(max(focusRatio, 0), 1)
        let focusChanged = abs(clampedFocus - lastTargetFocusRatio) > 0.001
        lastTargetFocusRatio = clampedFocus

        let key = TransitionKey(owner: ownerID, channel: "focus")
        if !animateFocus {
            if focusChanged || !MotionCoordinator.shared.hasActiveTransition(for: key) {
                MotionCoordinator.shared.cancel(key: key)
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                focusedOverlayLayer.removeAnimation(forKey: "focusCrossFade")
                focusedOverlayLayer.opacity = Float(clampedFocus)
                CATransaction.commit()
            }
        } else if MotionCoordinator.shared.isReduceMotionEnabled {
            MotionCoordinator.shared.cancel(key: key)
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            focusedOverlayLayer.removeAnimation(forKey: "focusCrossFade")
            focusedOverlayLayer.opacity = Float(clampedFocus)
            CATransaction.commit()
        } else {
            let ticket = MotionCoordinator.shared.beginTransition(for: key, category: .controlInteraction)
            MotionCoordinator.shared.animateLayerFloat(
                focusedOverlayLayer,
                keyPath: "opacity",
                animationKey: "focusCrossFade",
                to: clampedFocus,
                duration: MotionTokens.Duration.focusCrossFade,
                timingFunction: .easeInEaseOut,
                ticket: ticket,
                setModel: { $0.opacity = Float($1) }
            )
        }
    }

    private func cachedOrRender(
        size: CGSize,
        uiScale: CGFloat,
        backingScale: CGFloat,
        resolution: SkinResolutionMode,
        focusRatio: CGFloat
    ) -> CGImage? {
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
            return cached
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
        ) else { return nil }

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

        guard let rendered = ctx.makeImage() else { return nil }
        RenderCache.shared.store(rendered, for: key)
        return rendered
    }
}
