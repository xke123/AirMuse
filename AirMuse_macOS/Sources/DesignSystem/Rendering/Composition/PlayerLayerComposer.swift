import AppKit
import QuartzCore

// MARK: - PlayerLayerComposer

/// Composes the AIRPLAY Main Player's layered visual hierarchy using Core Animation:
/// 1. Cached static crystal glass shell (`RenderCache` + `OriginalGlassRenderer`) with M07 GPU crossfade
/// 2. Clipped middle-body specular lens-flare sweep layer (M08: max 2 concurrent flares, 180ms cooldown)
@MainActor
public final class PlayerLayerComposer {

    public let backgroundLayer = CALayer()
    public let ambientTintLayer = CAGradientLayer()
    public let focusedOverlayLayer = CALayer()
    public let sweepLayer = CALayer()

    private let ownerID = "PlayerLayerComposer-\(UUID().uuidString)"
    private var lastSweepTime: TimeInterval = -.infinity
    private var activeFlares: [CALayer] = []
    private var sweepSlotIndex: Int = 0
    private var lastTargetFocusRatio: CGFloat = 1.0

    public var activeSweepCount: Int { activeFlares.count }

    public init() {
        backgroundLayer.contentsGravity = .resize
        backgroundLayer.needsDisplayOnBoundsChange = false

        focusedOverlayLayer.contentsGravity = .resize
        focusedOverlayLayer.needsDisplayOnBoundsChange = false
        focusedOverlayLayer.opacity = 1.0

        ambientTintLayer.startPoint = CGPoint(x: 0.0, y: 0.85)
        ambientTintLayer.endPoint = CGPoint(x: 0.9, y: 0.1)
        ambientTintLayer.opacity = 0.0
        ambientTintLayer.masksToBounds = true

        sweepLayer.masksToBounds = true
    }

    public func attach(to rootLayer: CALayer) {
        if backgroundLayer.superlayer == nil {
            rootLayer.insertSublayer(backgroundLayer, at: 0)
        }
        if ambientTintLayer.superlayer == nil {
            rootLayer.insertSublayer(ambientTintLayer, above: backgroundLayer)
        }
        if focusedOverlayLayer.superlayer == nil {
            rootLayer.insertSublayer(focusedOverlayLayer, above: ambientTintLayer)
        }
        if sweepLayer.superlayer == nil {
            rootLayer.insertSublayer(sweepLayer, above: focusedOverlayLayer)
        }
    }

    public func layout(bounds: CGRect, backingScale: CGFloat) {
        let s = GlassInteractionCoordinator.shared.uiScale
        let borderW = OriginalDesignTokens.BaseMetrics.glassBorderThickness * s
        let capH = OriginalDesignTokens.BaseMetrics.glassCapHeight * s
        let bodyRect = CGRect(
            x: borderW,
            y: capH,
            width: max(0, bounds.width - borderW * 2.0),
            height: max(0, bounds.height - capH * 2.0)
        )
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        backgroundLayer.frame = bounds
        backgroundLayer.contentsScale = backingScale
        ambientTintLayer.frame = bodyRect
        ambientTintLayer.contentsScale = backingScale
        focusedOverlayLayer.frame = bounds
        focusedOverlayLayer.contentsScale = backingScale
        sweepLayer.frame = bounds
        sweepLayer.contentsScale = backingScale
        CATransaction.commit()
    }

    /// M17: Transitions localized inner-body ambient glow color (never staining the outer crystal frame).
    public func updateAmbientColor(_ color: NSColor?, animated: Bool = true) {
        let key = TransitionKey(owner: ownerID, channel: "ambient")
        let ticket = MotionCoordinator.shared.beginTransition(for: key, category: .content)
        let targetOpacity: CGFloat = (color != nil) ? 0.28 : 0.0

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if let color = color?.usingColorSpace(.sRGB) {
            let c1 = color.withAlphaComponent(0.65).cgColor
            let c2 = color.withAlphaComponent(0.18).cgColor
            let c3 = CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.0)
            ambientTintLayer.colors = [c1, c2, c3]
            ambientTintLayer.locations = [0.0, 0.55, 1.0]
        }
        CATransaction.commit()

        if !animated || MotionCoordinator.shared.isReduceMotionEnabled {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            ambientTintLayer.removeAnimation(forKey: "ambientGlow")
            ambientTintLayer.opacity = Float(targetOpacity)
            CATransaction.commit()
            _ = MotionCoordinator.shared.complete(ticket)
        } else {
            MotionCoordinator.shared.animateLayerFloat(
                ambientTintLayer,
                keyPath: "opacity",
                animationKey: "ambientGlow",
                to: targetOpacity,
                duration: MotionTokens.Duration.ambientGlow,
                timingFunction: .easeInEaseOut,
                ticket: ticket,
                setModel: { $0.opacity = Float($1) }
            )
        }
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
        artworkImage: CGImage?,
        animateFocus: Bool = false
    ) {
        guard size.width > 1, size.height > 1 else { return }

        let unfocusedImg = cachedOrRenderFrame(
            size: size,
            uiScale: uiScale,
            backingScale: backingScale,
            resolution: resolution,
            focusRatio: 0.0,
            hasMainGloss: hasMainGloss,
            frostedBars: frostedBars,
            artworkKey: artworkKey,
            artworkImage: artworkImage
        )
        let focusedImg = cachedOrRenderFrame(
            size: size,
            uiScale: uiScale,
            backingScale: backingScale,
            resolution: resolution,
            focusRatio: 1.0,
            hasMainGloss: hasMainGloss,
            frostedBars: frostedBars,
            artworkKey: artworkKey,
            artworkImage: artworkImage
        )

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        backgroundLayer.contents = unfocusedImg
        focusedOverlayLayer.contents = focusedImg
        CATransaction.commit()

        let clampedFocus = min(max(focusRatio, 0), 1)
        let focusChanged = abs(clampedFocus - lastTargetFocusRatio) > 0.001
        lastTargetFocusRatio = clampedFocus

        let key = TransitionKey(owner: ownerID, channel: "focus")
        if !animateFocus {
            // Only snap if focus target actually changed or no focus animation is currently running
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

    private func cachedOrRenderFrame(
        size: CGSize,
        uiScale: CGFloat,
        backingScale: CGFloat,
        resolution: SkinResolutionMode,
        focusRatio: CGFloat,
        hasMainGloss: Bool,
        frostedBars: Bool,
        artworkKey: String,
        artworkImage: CGImage?
    ) -> CGImage? {
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
            hasMainGloss: hasMainGloss,
            frostedBars: frostedBars,
            ambientArtwork: artworkImage
        )

        guard let rendered = ctx.makeImage() else { return nil }
        RenderCache.shared.store(rendered, for: key)
        return rendered
    }

    @discardableResult
    public func triggerSweep(
        from startPos: CGFloat,
        to endPos: CGFloat,
        size: CGSize,
        uiScale: CGFloat,
        backingScale: CGFloat
    ) -> Bool {
        guard !MotionCoordinator.shared.isReduceMotionEnabled else {
            cancelSweeps()
            return false
        }
        guard size.width > 20, size.height > 44 * uiScale else { return false }

        let now = MotionCoordinator.shared.clock.now
        guard now - lastSweepTime >= MotionTokens.Duration.specularCooldown else {
            return false
        }
        lastSweepTime = now

        let borderW = OriginalDesignTokens.BaseMetrics.glassBorderThickness * uiScale
        let capH = OriginalDesignTokens.BaseMetrics.glassCapHeight * uiScale
        let midH = size.height - capH * 2.0
        let fw = size.width - borderW * 2.0
        guard midH > 10, fw > 10 else { return false }

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
        ) else { return false }

        ctx.scaleBy(x: backingScale, y: backingScale)
        let localSize = CGSize(width: fw, height: bandH)

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

        guard let bandImg = ctx.makeImage() else { return false }

        // Enforce bounded active sweep layers (max 2)
        while activeFlares.count >= MotionTokens.Thresholds.maxActiveSweeps {
            let oldest = activeFlares.removeFirst()
            oldest.removeAllAnimations()
            oldest.removeFromSuperlayer()
        }

        if sweepLayer.mask == nil || sweepLayer.bounds.size != size {
            let maskLayer = CAShapeLayer()
            maskLayer.path = CGPath(rect: CGRect(x: borderW, y: capH, width: fw, height: midH), transform: nil)
            sweepLayer.mask = maskLayer
        }

        let flare = CALayer()
        flare.contents = bandImg
        flare.contentsScale = backingScale
        flare.bounds = CGRect(x: 0, y: 0, width: fw, height: bandH)

        let fromY = (capH + midH) - startPos * midH
        let toY = (capH + midH) - endPos * midH
        flare.position = CGPoint(x: borderW + fw * 0.5, y: toY)
        flare.opacity = 0.0
        sweepLayer.addSublayer(flare)
        activeFlares.append(flare)

        let slot = sweepSlotIndex
        sweepSlotIndex = (sweepSlotIndex + 1) % MotionTokens.Thresholds.maxActiveSweeps
        let sweepKey = TransitionKey(owner: ownerID, channel: "sweep-\(slot)")
        let ticket = MotionCoordinator.shared.beginTransition(for: sweepKey, category: .decorative) { [weak self, weak flare] in
            flare?.removeAllAnimations()
            flare?.removeFromSuperlayer()
            if let flare {
                self?.activeFlares.removeAll { $0 === flare }
            }
        }

        CATransaction.begin()
        let posAnim = CABasicAnimation(keyPath: "position.y")
        posAnim.fromValue = fromY
        posAnim.toValue = toY
        posAnim.duration = MotionTokens.Duration.specularSweep
        posAnim.timingFunction = CAMediaTimingFunction(controlPoints: 0.25, 0.1, 0.25, 1.0)

        let opAnim = CAKeyframeAnimation(keyPath: "opacity")
        opAnim.values = [0.0, 1.0, 0.85, 0.0]
        opAnim.keyTimes = [0.0, 0.25, 0.70, 1.0]
        opAnim.duration = MotionTokens.Duration.specularSweep

        let group = CAAnimationGroup()
        group.animations = [posAnim, opAnim]
        group.duration = MotionTokens.Duration.specularSweep
        group.isRemovedOnCompletion = true

        CATransaction.setCompletionBlock { [weak self, weak flare] in
            Task { @MainActor in
                _ = MotionCoordinator.shared.complete(ticket)
                if let flare {
                    flare.removeFromSuperlayer()
                    self?.activeFlares.removeAll { $0 === flare }
                }
            }
        }
        flare.add(group, forKey: "specularSweep")
        CATransaction.commit()
        return true
    }

    public func cancelSweeps() {
        MotionCoordinator.shared.cancelAll(owner: ownerID)
        for flare in activeFlares {
            flare.removeAllAnimations()
            flare.removeFromSuperlayer()
        }
        activeFlares.removeAll()
        sweepLayer.sublayers?.forEach { $0.removeFromSuperlayer() }
    }

    public func cancelAll() {
        cancelSweeps()
        MotionCoordinator.shared.cancel(key: TransitionKey(owner: ownerID, channel: "focus"))
    }
}
