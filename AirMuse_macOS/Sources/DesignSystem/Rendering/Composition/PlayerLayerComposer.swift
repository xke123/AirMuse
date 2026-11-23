import AppKit
import QuartzCore

// MARK: - PlayerLayerComposer

/// Composes the AIRPLAY Main Player's layered visual hierarchy using Core Animation:
/// 1. Cached static crystal glass shell (`RenderCache` + `OriginalGlassRenderer`)
/// 2. Clipped middle-body specular lens-flare sweep layer
/// 3. Top/Bottom bar spill-fog layer for crisp icon/text legibility
@MainActor
public final class PlayerLayerComposer {

    public let backgroundLayer = CALayer()
    public let sweepLayer = CALayer()
    public let fogLayer = CALayer()

    private var sweepStartPos: CGFloat = 0.0
    private var sweepEndPos: CGFloat = 1.0
    private var sweepProgress: CGFloat = 1.0
    private var isSweeping: Bool = false

    public init() {
        backgroundLayer.contentsGravity = .resize
        backgroundLayer.needsDisplayOnBoundsChange = false

        sweepLayer.masksToBounds = true
        fogLayer.masksToBounds = false
        fogLayer.opacity = 0.0
    }

    public func attach(to rootLayer: CALayer) {
        if backgroundLayer.superlayer == nil {
            rootLayer.insertSublayer(backgroundLayer, at: 0)
        }
        if sweepLayer.superlayer == nil {
            rootLayer.insertSublayer(sweepLayer, above: backgroundLayer)
        }
        if fogLayer.superlayer == nil {
            rootLayer.insertSublayer(fogLayer, above: sweepLayer)
        }
    }

    public func layout(bounds: CGRect, backingScale: CGFloat) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        backgroundLayer.frame = bounds
        backgroundLayer.contentsScale = backingScale
        sweepLayer.frame = bounds
        sweepLayer.contentsScale = backingScale
        fogLayer.frame = bounds
        fogLayer.contentsScale = backingScale
        CATransaction.commit()
    }

    public func updateBackground(
        size: CGSize,
        uiScale: CGFloat,
        backingScale: CGFloat,
        resolution: SkinResolutionMode,
        focusRatio: CGFloat,
        hasMainGloss: Bool,
        frostedBars: Bool = false,
        artworkKey: String,
        artworkImage: CGImage?
    ) {
        guard size.width > 1, size.height > 1 else { return }

        let key = RenderCache.Key(
            width: size.width,
            height: size.height,
            uiScale: uiScale,
            backingScale: backingScale,
            resolution: resolution,
            focusRatio: focusRatio,
            hasMainGloss: hasMainGloss,
            frostedBars: frostedBars,
            artworkKey: artworkKey
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
            hasMainGloss: hasMainGloss,
            frostedBars: frostedBars,
            ambientArtwork: artworkImage
        )

        if let rendered = ctx.makeImage() {
            RenderCache.shared.store(rendered, for: key)
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            backgroundLayer.contents = rendered
            CATransaction.commit()
        }

        updateFog(size: size, uiScale: uiScale, backingScale: backingScale)
    }

    public func updateFog(size: CGSize, uiScale: CGFloat, backingScale: CGFloat) {
        guard size.width > 20, size.height > 40 * uiScale else {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            fogLayer.contents = nil
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

        let w = size.width
        let h = size.height
        let s = uiScale
        let capH = OriginalDesignTokens.BaseMetrics.glassCapHeight * s

        // 1. Top right window buttons aurora plume (seam at bottom connects flush with panel body)
        let topClip = CGRect(x: 3.0 * s, y: h - capH, width: w - 6.0 * s, height: capH)
        OriginalGlassRenderer.drawAuroraFogPlume(
            in: ctx,
            barBounds: topClip,
            xMin: w - 101.0 * s,
            xMax: w - 16.0 * s,
            seamEdge: .bottom,
            spreadLeft: 34.0 * s,
            spreadRight: 14.0 * s,
            peakAlpha: 1.0
        )

        // 2. Bottom left platform buttons aurora plume (seam at top connects flush with panel body)
        let botClip = CGRect(x: 3.0 * s, y: 0.0, width: w - 6.0 * s, height: capH)
        OriginalGlassRenderer.drawAuroraFogPlume(
            in: ctx,
            barBounds: botClip,
            xMin: 20.0 * s,
            xMax: 71.0 * s,
            seamEdge: .top,
            spreadLeft: 14.0 * s,
            spreadRight: 34.0 * s,
            peakAlpha: 1.0
        )

        // 3. Bottom right panel buttons aurora plume (seam at top connects flush with panel body)
        OriginalGlassRenderer.drawAuroraFogPlume(
            in: ctx,
            barBounds: botClip,
            xMin: w - 48.0 * s,
            xMax: w - 16.0 * s,
            seamEdge: .top,
            spreadLeft: 30.0 * s,
            spreadRight: 14.0 * s,
            peakAlpha: 1.0
        )

        if let fogImg = ctx.makeImage() {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            fogLayer.contents = fogImg
            CATransaction.commit()
        }
    }

    public func triggerSweep(from startPos: CGFloat, to endPos: CGFloat, size: CGSize, uiScale: CGFloat, backingScale: CGFloat) {
        guard !MotionCoordinator.shared.isReduceMotionEnabled else { return }
        guard size.width > 20, size.height > 44 * uiScale else { return }

        sweepStartPos = startPos
        sweepEndPos = endPos
        sweepProgress = 0.0
        isSweeping = true

        // Render specular band into sweepLayer and animate its position across the body
        let borderW = OriginalDesignTokens.BaseMetrics.glassBorderThickness * uiScale
        let capH = OriginalDesignTokens.BaseMetrics.glassCapHeight * uiScale
        let midH = size.height - capH * 2.0
        let fw = size.width - borderW * 2.0
        guard midH > 10, fw > 10 else { return }

        let bandH = max(56.0 * uiScale, size.height * (2.0 / 3.0))
        let pxW = max(1, Int(round(fw * backingScale)))
        let pxH = max(1, Int(round(bandH * backingScale)))
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
        let localSize = CGSize(width: fw, height: bandH)

        // Draw centered Gaussian specular band
        func drawBand(h: CGFloat, alpha: CGFloat, r: CGFloat, g: CGFloat, b: CGFloat) {
            let cy = localSize.height * 0.5
            let y0 = cy - h * 0.5
            let y1 = cy + h * 0.5
            let positions: [CGFloat] = [0.0, 0.20, 0.35, 0.50, 0.65, 0.80, 1.0]
            let weights: [CGFloat]   = [0.0, 0.50, 0.80, 1.00, 0.80, 0.50, 0.0]
            let colors = weights.map { CGColor(srgbRed: r, green: g, blue: b, alpha: alpha * $0) } as CFArray
            if let grad = CGGradient(colorsSpace: cs, colors: colors, locations: positions) {
                ctx.drawLinearGradient(grad, start: CGPoint(x: 0, y: y0), end: CGPoint(x: 0, y: y1), options: [])
            }
        }
        drawBand(h: bandH, alpha: 24.0 / 255.0, r: 130/255.0, g: 215/255.0, b: 1.0)
        drawBand(h: bandH * 0.55, alpha: 22.0 / 255.0, r: 250/255.0, g: 252/255.0, b: 1.0)
        drawBand(h: 14.0 * uiScale, alpha: 10.0 / 255.0, r: 1.0, g: 1.0, b: 1.0)

        guard let bandImg = ctx.makeImage() else { return }

        sweepLayer.sublayers?.forEach { $0.removeFromSuperlayer() }
        let maskLayer = CAShapeLayer()
        maskLayer.path = CGPath(rect: CGRect(x: borderW, y: capH, width: fw, height: midH), transform: nil)
        sweepLayer.mask = maskLayer

        let flare = CALayer()
        flare.contents = bandImg
        flare.contentsScale = backingScale
        flare.bounds = CGRect(x: 0, y: 0, width: fw, height: bandH)

        let fromY = (capH + midH) - startPos * midH
        let toY = (capH + midH) - endPos * midH
        flare.position = CGPoint(x: borderW + fw * 0.5, y: toY)
        sweepLayer.addSublayer(flare)

        let posAnim = CABasicAnimation(keyPath: "position.y")
        posAnim.fromValue = fromY
        posAnim.toValue = toY
        posAnim.duration = MotionTokens.Duration.specularSweep
        posAnim.timingFunction = CAMediaTimingFunction(controlPoints: 0.25, 0.1, 0.25, 1.0)

        let opAnim = CAKeyframeAnimation(keyPath: "opacity")
        opAnim.values = [0.0, 1.0, 0.85, 0.0]
        opAnim.keyTimes = [0.0, 0.25, 0.70, 1.0]
        opAnim.duration = MotionTokens.Duration.specularSweep
        flare.opacity = 0.0

        let group = CAAnimationGroup()
        group.animations = [posAnim, opAnim]
        group.duration = MotionTokens.Duration.specularSweep
        group.isRemovedOnCompletion = true

        flare.add(group, forKey: "specularSweep")
        isSweeping = false
        _ = isSweeping
        _ = sweepProgress
    }
}
