import AppKit
import CoreGraphics
import Foundation

// MARK: - OriginalGlassRenderer

/// Renders the complete AIRPLAY-zion crystal glass window shell:
/// 1. Middle body background (main gradient rgb 58->31 or panel rgb 23,23,23)
/// 2. Optional ambient artwork diffuse (15% alpha)
/// 3. 9-slice WINDOWGLASS / WINDOWGLASSFOCUS cross-faded by focusRatio
/// 4. 1px physical groove seams at y = 20 and y = H - 20
/// 5. Bar spill fog behind glass-bar controls/titles
/// 6. Gaussian lens-flare specular sweep across the middle body
@MainActor
public enum OriginalGlassRenderer {

    public static func drawGlassFrame(
        in ctx: CGContext,
        size: CGSize,
        uiScale: CGFloat = 1.0,
        resolution: SkinResolutionMode = .retina4x,
        focusRatio: CGFloat = 1.0,
        hasMainGloss: Bool = false,
        frostedBars: Bool = false,
        ambientArtwork: CGImage? = nil
    ) {
        let w = size.width
        let h = size.height
        guard w > 0, h > 0 else { return }

        let clampedFocus = min(max(focusRatio, 0), 1)
        let capH = OriginalDesignTokens.BaseMetrics.glassCapHeight * uiScale
        let borderW = OriginalDesignTokens.BaseMetrics.glassBorderThickness * uiScale
        let isMiniStrip = h <= (OriginalDesignTokens.BaseMetrics.miniBarStandardHeight * uiScale + 2.0)

        let glassFocus = SkinAssetLoader.shared.image(for: .windowGlassFocus, resolution: resolution)
        let glassNormal = SkinAssetLoader.shared.image(for: .windowGlass, resolution: resolution)
        let crisp1x = (resolution == .original1x && abs(uiScale - 1.0) < 0.01)

        if isMiniStrip {
            // Pure transparent crystal bar: zero opaque dark fill!
            let cornerR = OriginalDesignTokens.BaseMetrics.miniCornerRadius * uiScale
            ctx.saveGState()
            let clipPath = CGPath(roundedRect: CGRect(origin: .zero, size: size), cornerWidth: cornerR, cornerHeight: cornerR, transform: nil)
            ctx.addPath(clipPath)
            ctx.clip()

            if clampedFocus >= 0.99, let gf = glassFocus {
                NineSliceRenderer.drawGlass9Slice(in: ctx, glass: gf, rect: CGRect(origin: .zero, size: size), uiScale: uiScale, alpha: 1.0, crisp1x: crisp1x)
            } else if clampedFocus <= 0.01, let gn = glassNormal {
                NineSliceRenderer.drawGlass9Slice(in: ctx, glass: gn, rect: CGRect(origin: .zero, size: size), uiScale: uiScale, alpha: 1.0, crisp1x: crisp1x)
            } else {
                if let gn = glassNormal {
                    NineSliceRenderer.drawGlass9Slice(in: ctx, glass: gn, rect: CGRect(origin: .zero, size: size), uiScale: uiScale, alpha: 1.0, crisp1x: crisp1x)
                }
                if let gf = glassFocus {
                    NineSliceRenderer.drawGlass9Slice(in: ctx, glass: gf, rect: CGRect(origin: .zero, size: size), uiScale: uiScale, alpha: clampedFocus, crisp1x: crisp1x)
                }
            }
            ctx.restoreGState()
            return
        }

        // 1. Middle Main Body (CGContext origin is bottom-left: y = capH .. h - capH)
        // In frostedBars mode there is no 9-slice side border, so body spans full width to match the glass bars.
        let sideInset: CGFloat = frostedBars ? 0.0 : borderW
        let midH = h - capH * 2.0
        let midW = w - sideInset * 2.0
        if midH > 0, midW > 0 {
            let bodyRect = CGRect(x: sideInset, y: capH, width: midW, height: midH)
            ctx.saveGState()
            ctx.clip(to: bodyRect)

            if hasMainGloss {
                // Top rgb(58,58,58) -> Bottom rgb(31,31,31)
                let cs = CGColorSpaceCreateDeviceRGB()
                let topCol = OriginalDesignTokens.Colors.mainBodyTop.cgColor
                let botCol = OriginalDesignTokens.Colors.mainBodyBottom.cgColor
                if let grad = CGGradient(colorsSpace: cs, colors: [topCol, botCol] as CFArray, locations: [0.0, 1.0]) {
                    ctx.drawLinearGradient(
                        grad,
                        start: CGPoint(x: sideInset, y: capH + midH),
                        end: CGPoint(x: sideInset, y: capH),
                        options: []
                    )
                }
            } else {
                ctx.setFillColor(OriginalDesignTokens.Colors.panelBody.cgColor)
                ctx.fill(bodyRect)
            }

            // Optional subtle ambient artwork diffuse (15% opacity)
            if let art = ambientArtwork {
                ctx.saveGState()
                ctx.setAlpha(0.15)
                let artRect = CGRect(x: sideInset, y: capH + midH - midW + 30.0 * uiScale, width: midW, height: midW)
                ctx.draw(art, in: artRect)
                ctx.restoreGState()
            }

            ctx.restoreGState()
        }

        if !frostedBars {
            // 2. 9-slice Crystal Glass Border (smooth anti-aliased rounded clip to prevent jagged outer alpha fringe)
            let fullRect = CGRect(origin: .zero, size: size)
            let outerCornerR = OriginalDesignTokens.BaseMetrics.glassCornerRadius * uiScale
            ctx.saveGState()
            ctx.setAllowsAntialiasing(true)
            ctx.setShouldAntialias(true)
            let outerClip = CGPath(roundedRect: fullRect.insetBy(dx: 0.5, dy: 0.5), cornerWidth: outerCornerR, cornerHeight: outerCornerR, transform: nil)
            ctx.addPath(outerClip)
            ctx.clip()

            if clampedFocus >= 0.99, let gf = glassFocus {
                NineSliceRenderer.drawGlass9Slice(in: ctx, glass: gf, rect: fullRect, uiScale: uiScale, alpha: 1.0, crisp1x: crisp1x)
            } else if clampedFocus <= 0.01, let gn = glassNormal {
                NineSliceRenderer.drawGlass9Slice(in: ctx, glass: gn, rect: fullRect, uiScale: uiScale, alpha: 1.0, crisp1x: crisp1x)
            } else {
                if let gn = glassNormal {
                    NineSliceRenderer.drawGlass9Slice(in: ctx, glass: gn, rect: fullRect, uiScale: uiScale, alpha: 1.0, crisp1x: crisp1x)
                }
                if let gf = glassFocus {
                    NineSliceRenderer.drawGlass9Slice(in: ctx, glass: gf, rect: fullRect, uiScale: uiScale, alpha: clampedFocus, crisp1x: crisp1x)
                }
            }
            ctx.restoreGState()
        }

        // 3. Groove Seams (drawn AFTER 9-slice so the glass-to-body boundary is razor sharp)
        if midH > 0, midW > 0 {
            let darkAlpha = (190.0 + 35.0 * clampedFocus) / 255.0
            let lightAlpha = (45.0 + 35.0 * clampedFocus) / 255.0
            let darkCol = CGColor(srgbRed: 12/255.0, green: 13/255.0, blue: 16/255.0, alpha: darkAlpha)
            let lightCol = CGColor(srgbRed: 1.0, green: 1.0, blue: 1.0, alpha: lightAlpha)

            // Top seam (CG y = h - capH)
            let topSeamY = h - capH
            ctx.setLineWidth(1.0)
            ctx.setStrokeColor(darkCol)
            ctx.move(to: CGPoint(x: sideInset, y: topSeamY))
            ctx.addLine(to: CGPoint(x: sideInset + midW, y: topSeamY))
            ctx.strokePath()

            ctx.setStrokeColor(lightCol)
            ctx.move(to: CGPoint(x: sideInset, y: topSeamY - 1.0))
            ctx.addLine(to: CGPoint(x: sideInset + midW, y: topSeamY - 1.0))
            ctx.strokePath()

            // Bottom seam (CG y = capH)
            let botSeamY = capH
            ctx.setStrokeColor(darkCol)
            ctx.move(to: CGPoint(x: sideInset, y: botSeamY + 1.0))
            ctx.addLine(to: CGPoint(x: sideInset + midW, y: botSeamY + 1.0))
            ctx.strokePath()

            ctx.setStrokeColor(lightCol)
            ctx.move(to: CGPoint(x: sideInset, y: botSeamY))
            ctx.addLine(to: CGPoint(x: sideInset + midW, y: botSeamY))
            ctx.strokePath()
        }
    }

    /// Draws the subtle dark fog spill behind top/bottom glass bar icons & labels so silver sprites stay legible.
    public static func drawBarSpillFog(
        in ctx: CGContext,
        barClip: CGRect,
        anchorX: CGFloat,
        leftSpan: CGFloat,
        rightSpan: CGFloat,
        peakAlpha: CGFloat
    ) {
        guard peakAlpha > 0.015, (leftSpan + rightSpan) > 4.0, barClip.width > 2, barClip.height > 2 else { return }

        ctx.saveGState()
        ctx.clip(to: barClip)

        let cs = CGColorSpaceCreateDeviceRGB()
        let centerPt = CGPoint(x: anchorX, y: barClip.midY)
        let radius = max(leftSpan, rightSpan)
        let centerColor = CGColor(srgbRed: 14/255.0, green: 16/255.0, blue: 20/255.0, alpha: peakAlpha * 0.65)
        let edgeColor = CGColor(srgbRed: 14/255.0, green: 16/255.0, blue: 20/255.0, alpha: 0.0)

        if let grad = CGGradient(colorsSpace: cs, colors: [centerColor, edgeColor] as CFArray, locations: [0.0, 1.0]) {
            ctx.saveGState()
            ctx.translateBy(x: centerPt.x, y: centerPt.y)
            ctx.scaleBy(x: 1.0, y: max(0.25, barClip.height / max(1.0, radius)))
            ctx.drawRadialGradient(grad, startCenter: .zero, startRadius: 0, endCenter: .zero, endRadius: radius, options: [])
            ctx.restoreGState()
        }

        ctx.restoreGState()
    }

    /// Draws the Gaussian AR-coated specular lens flare sweep across the middle body.
    public static func drawSpecularSweep(
        in ctx: CGContext,
        size: CGSize,
        uiScale: CGFloat,
        sweepRatio: CGFloat,
        intensity: CGFloat
    ) {
        guard intensity > 0.005 else { return }
        let borderW = OriginalDesignTokens.BaseMetrics.glassBorderThickness * uiScale
        let capH = OriginalDesignTokens.BaseMetrics.glassCapHeight * uiScale
        let fw = size.width - borderW * 2.0
        let midH = size.height - capH * 2.0
        guard fw > 10, midH > 10 else { return }

        let midClip = CGRect(x: borderW, y: capH, width: fw, height: midH)
        ctx.saveGState()
        ctx.clip(to: midClip)

        // sweepRatio 0 = top of body, 1 = bottom of body -> convert to CG bottom-left
        let cy = (capH + midH) - sweepRatio * midH
        let totalH = max(56.0 * uiScale, size.height * (2.0 / 3.0))

        func drawGaussianBand(bandH: CGFloat, peakAlpha: CGFloat, r: CGFloat, g: CGFloat, b: CGFloat) {
            guard peakAlpha > 0.002, bandH > 1.0 else { return }
            let y0 = cy - bandH * 0.5
            let y1 = cy + bandH * 0.5
            let positions: [CGFloat] = [0.0, 0.18, 0.32, 0.50, 0.68, 0.82, 1.0]
            let weights: [CGFloat]   = [0.0, 0.54, 0.80, 1.00, 0.80, 0.54, 0.0]
            let colors = weights.map { CGColor(srgbRed: r, green: g, blue: b, alpha: peakAlpha * $0) } as CFArray
            let cs = CGColorSpaceCreateDeviceRGB()
            if let grad = CGGradient(colorsSpace: cs, colors: colors, locations: positions) {
                ctx.drawLinearGradient(grad, start: CGPoint(x: borderW, y: y0), end: CGPoint(x: borderW, y: y1), options: [])
            }
        }

        // 1. Broad AR-Coating Cyan Glow
        drawGaussianBand(bandH: totalH, peakAlpha: min(1.0, intensity * (22.0 / 255.0)), r: 130/255.0, g: 215/255.0, b: 1.0)
        // 2. Core Specular Glare
        drawGaussianBand(bandH: totalH * 0.55, peakAlpha: min(1.0, intensity * (22.0 / 255.0)), r: 250/255.0, g: 252/255.0, b: 1.0)
        // 3. Soft Filament Bloom
        drawGaussianBand(bandH: 14.0 * uiScale, peakAlpha: min(1.0, intensity * (10.0 / 255.0)), r: 1.0, g: 1.0, b: 1.0)

        ctx.restoreGState()
    }
}
