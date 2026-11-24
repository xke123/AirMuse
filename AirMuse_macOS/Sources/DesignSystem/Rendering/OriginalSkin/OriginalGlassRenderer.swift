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

            // Roll shadows at top and bottom of middle body (gives physical depth where glass overlaps body)
            let shadowDepth = min(10.0 * uiScale, midH * 0.45)
            if shadowDepth > 1.0 {
                let cs = CGColorSpaceCreateDeviceRGB()
                let rollDark = CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 90.0 / 255.0)
                let rollClear = CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.0)
                if let rollGrad = CGGradient(colorsSpace: cs, colors: [rollDark, rollClear] as CFArray, locations: [0.0, 1.0]) {
                    // Top roll shadow (fades downward from capH + midH)
                    ctx.drawLinearGradient(
                        rollGrad,
                        start: CGPoint(x: sideInset, y: capH + midH),
                        end: CGPoint(x: sideInset, y: capH + midH - shadowDepth),
                        options: []
                    )
                    // Bottom roll shadow (fades upward from capH)
                    ctx.drawLinearGradient(
                        rollGrad,
                        start: CGPoint(x: sideInset, y: capH),
                        end: CGPoint(x: sideInset, y: capH + shadowDepth),
                        options: []
                    )
                }
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

    /// Directional edge of the body seam from which the aurora fog spills into the crystal glass bar.
    public enum BarSeamEdge: Sendable, Equatable {
        /// Seam is at the bottom of the bar (e.g. Top Glass Bar). Spills upward from bar's bottom edge into glass.
        case bottom
        /// Seam is at the top of the bar (e.g. Bottom Glass Bar). Spills downward from bar's top edge into glass.
        case top
    }

    /// Horizontal anchoring and laser-tail extension direction inside a glass bar.
    public enum AuroraFogAlignment: Sendable, Equatable {
        /// Anchored on the left (steep right-trapezoid edge), elongated laser mist tail extending right.
        case left
        /// Anchored on the right (steep right-trapezoid edge), elongated laser mist tail extending left.
        case right
    }

    /// Specification for a single laser-mist plume behind a button cluster or text label.
    public struct AuroraFogPlumeSpec: Sendable, Equatable {
        public var xMin: CGFloat
        public var xMax: CGFloat
        public var alignment: AuroraFogAlignment
        public var anchorSpread: CGFloat
        public var tailLength: CGFloat
        public var peakAlpha: CGFloat

        public init(
            xMin: CGFloat,
            xMax: CGFloat,
            alignment: AuroraFogAlignment,
            anchorSpread: CGFloat = 10.0,
            tailLength: CGFloat = 64.0,
            peakAlpha: CGFloat = 1.0
        ) {
            self.xMin = xMin
            self.xMax = xMax
            self.alignment = alignment
            self.anchorSpread = anchorSpread
            self.tailLength = tailLength
            self.peakAlpha = peakAlpha
        }
    }

    private static let sRGBColorSpace: CGColorSpace =
        CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()

    /// Draws one or more edge-adaptive, laser-like right-trapezoid aurora mist plumes into a normal-mode glass bar.
    /// - Vertical adaptability: 100% solid at the panel seam, strictly ≤ 88% (≤ 90%) of bar height on the outer edge.
    /// - Horizontal adaptability: Steep right-trapezoid anchor on the outer side, elongated laser tail toward the bar interior.
    /// - Multi-plume blending: Uses per-pixel `max` across plumes to prevent muddy overlap darkening.
    public static func drawAuroraFogPlumes(
        in ctx: CGContext,
        barBounds: CGRect,
        plumes: [AuroraFogPlumeSpec],
        seamEdge: BarSeamEdge,
        cornerRadius: CGFloat = 0.0
    ) {
        let activePlumes = plumes.filter { $0.peakAlpha > 0.015 }
        guard !activePlumes.isEmpty, barBounds.width > 2.0, barBounds.height > 8.0 else { return }

        let scaleX = max(1.0, abs(ctx.ctm.a))
        let scaleY = max(1.0, abs(ctx.ctm.d))
        let pxW = max(1, Int(round(barBounds.width * scaleX)))
        let pxH = max(1, Int(round(barBounds.height * scaleY)))

        // Unified fog color from OriginalDesignTokens.Colors.spillFogDark in sRGB
        let fogColor = OriginalDesignTokens.Colors.spillFogDark.usingColorSpace(.sRGB)
            ?? OriginalDesignTokens.Colors.spillFogDark
        let baseR = fogColor.redComponent
        let baseG = fogColor.greenComponent
        let baseB = fogColor.blueComponent

        let barW = barBounds.width
        let barH = barBounds.height
        let maxReachH = barH * 0.88 // Strictly <= 90% of glass bar height

        var bytes = [UInt8](repeating: 0, count: pxW * pxH * 4)

        for row in 0..<pxH {
            // In CGImage drawn via ctx.draw(_:in:), row 0 is the top (maxY) and row pxH-1 is the bottom (minY)
            let yFromTop = (CGFloat(row) + 0.5) / CGFloat(pxH) * barH
            let yFromBottom = barH - yFromTop
            let distFromSeam = (seamEdge == .bottom) ? yFromBottom : yFromTop

            if distFromSeam >= maxReachH {
                continue
            }

            let rowOffset = row * pxW * 4
            for col in 0..<pxW {
                let x = barBounds.minX + (CGFloat(col) + 0.5) / CGFloat(pxW) * barW
                var bestAlpha: CGFloat = 0.0

                for plume in activePlumes {
                    let cMin = max(barBounds.minX, min(plume.xMin, plume.xMax))
                    let cMax = min(barBounds.maxX, max(plume.xMin, plume.xMax))
                    let anchorS = max(1.0, plume.anchorSpread)
                    let tailL = max(1.0, plume.tailLength)

                    let hAlpha: CGFloat
                    let localH: CGFloat

                    switch plume.alignment {
                    case .right:
                        if x >= cMin && x <= cMax {
                            hAlpha = 1.0
                            localH = maxReachH
                        } else if x > cMax {
                            let dx = x - cMax
                            if dx >= anchorS { continue }
                            let t = dx / anchorS
                            // Smoothstep drop on the steep right-angled trapezoid edge
                            hAlpha = 1.0 - (t * t * (3.0 - 2.0 * t))
                            localH = maxReachH
                        } else {
                            let dx = cMin - x
                            if dx >= tailL { continue }
                            let t = dx / tailL
                            // Elongated laser tail: linear trapezoid taper + smooth power falloff
                            localH = maxReachH * (1.0 - 0.82 * t)
                            hAlpha = pow(1.0 - t, 1.75)
                        }

                    case .left:
                        if x >= cMin && x <= cMax {
                            hAlpha = 1.0
                            localH = maxReachH
                        } else if x < cMin {
                            let dx = cMin - x
                            if dx >= anchorS { continue }
                            let t = dx / anchorS
                            hAlpha = 1.0 - (t * t * (3.0 - 2.0 * t))
                            localH = maxReachH
                        } else {
                            let dx = x - cMax
                            if dx >= tailL { continue }
                            let t = dx / tailL
                            localH = maxReachH * (1.0 - 0.82 * t)
                            hAlpha = pow(1.0 - t, 1.75)
                        }
                    }

                    guard localH > 0.5, distFromSeam < localH else { continue }
                    let vNorm = distFromSeam / localH
                    let vBase = max(0.0, 1.0 - pow(vNorm, 2.1))
                    let vAlpha = pow(vBase, 1.8)

                    let candidate = plume.peakAlpha * hAlpha * vAlpha
                    if candidate > bestAlpha {
                        bestAlpha = candidate
                    }
                }

                if bestAlpha > 0.002 {
                    let a = min(1.0, bestAlpha)
                    let idx = rowOffset + col * 4
                    bytes[idx]     = UInt8((baseR * a * 255.0).rounded())
                    bytes[idx + 1] = UInt8((baseG * a * 255.0).rounded())
                    bytes[idx + 2] = UInt8((baseB * a * 255.0).rounded())
                    bytes[idx + 3] = UInt8((a * 255.0).rounded())
                }
            }
        }

        let data = Data(bytes)
        guard let provider = CGDataProvider(data: data as CFData),
              let fogImage = CGImage(
                width: pxW,
                height: pxH,
                bitsPerComponent: 8,
                bitsPerPixel: 32,
                bytesPerRow: pxW * 4,
                space: sRGBColorSpace,
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                provider: provider,
                decode: nil,
                shouldInterpolate: true,
                intent: .defaultIntent
              ) else { return }

        ctx.saveGState()
        if cornerRadius > 0.5 {
            let clipPath = makeBarClipPath(rect: barBounds, cornerRadius: cornerRadius, seamEdge: seamEdge)
            ctx.addPath(clipPath)
            ctx.clip()
        } else {
            ctx.clip(to: barBounds)
        }
        ctx.draw(fogImage, in: barBounds)
        ctx.restoreGState()
    }

    private static func makeBarClipPath(rect: CGRect, cornerRadius r: CGFloat, seamEdge: BarSeamEdge) -> CGPath {
        let clampedR = min(r, min(rect.width * 0.5, rect.height * 0.5))
        let path = CGMutablePath()
        let minX = rect.minX
        let maxX = rect.maxX
        let minY = rect.minY
        let maxY = rect.maxY

        if seamEdge == .bottom {
            // Top bar: bottom corners are square (flush with panel), top corners are rounded
            path.move(to: CGPoint(x: minX, y: minY))
            path.addLine(to: CGPoint(x: maxX, y: minY))
            path.addLine(to: CGPoint(x: maxX, y: maxY - clampedR))
            path.addQuadCurve(to: CGPoint(x: maxX - clampedR, y: maxY), control: CGPoint(x: maxX, y: maxY))
            path.addLine(to: CGPoint(x: minX + clampedR, y: maxY))
            path.addQuadCurve(to: CGPoint(x: minX, y: maxY - clampedR), control: CGPoint(x: minX, y: maxY))
            path.closeSubpath()
        } else {
            // Bottom bar: top corners are square (flush with panel), bottom corners are rounded
            path.move(to: CGPoint(x: minX, y: maxY))
            path.addLine(to: CGPoint(x: maxX, y: maxY))
            path.addLine(to: CGPoint(x: maxX, y: minY + clampedR))
            path.addQuadCurve(to: CGPoint(x: maxX - clampedR, y: minY), control: CGPoint(x: maxX, y: minY))
            path.addLine(to: CGPoint(x: minX + clampedR, y: minY))
            path.addQuadCurve(to: CGPoint(x: minX, y: minY + clampedR), control: CGPoint(x: minX, y: minY))
            path.closeSubpath()
        }
        return path
    }

    /// Convenience single-plume wrapper.
    public static func drawAuroraFogPlume(
        in ctx: CGContext,
        barBounds: CGRect,
        xMin: CGFloat,
        xMax: CGFloat,
        seamEdge: BarSeamEdge,
        alignment: AuroraFogAlignment? = nil,
        anchorSpread: CGFloat = 10.0,
        tailLength: CGFloat = 64.0,
        peakAlpha: CGFloat = 1.0,
        cornerRadius: CGFloat = 0.0
    ) {
        let resolvedAlignment: AuroraFogAlignment = alignment ?? {
            let center = (xMin + xMax) * 0.5
            return (center >= barBounds.midX) ? .right : .left
        }()
        let spec = AuroraFogPlumeSpec(
            xMin: xMin,
            xMax: xMax,
            alignment: resolvedAlignment,
            anchorSpread: anchorSpread,
            tailLength: tailLength,
            peakAlpha: peakAlpha
        )
        drawAuroraFogPlumes(
            in: ctx,
            barBounds: barBounds,
            plumes: [spec],
            seamEdge: seamEdge,
            cornerRadius: cornerRadius
        )
    }

    /// Legacy bridge method maintaining backwards compatibility.
    public static func drawBarSpillFog(
        in ctx: CGContext,
        barClip: CGRect,
        anchorX: CGFloat,
        leftSpan: CGFloat,
        rightSpan: CGFloat,
        fromBottom: Bool = true,
        peakAlpha: CGFloat
    ) {
        let alignment: AuroraFogAlignment = (anchorX >= barClip.midX) ? .right : .left
        drawAuroraFogPlume(
            in: ctx,
            barBounds: barClip,
            xMin: anchorX - leftSpan,
            xMax: anchorX + rightSpan,
            seamEdge: fromBottom ? .bottom : .top,
            alignment: alignment,
            anchorSpread: min(leftSpan, rightSpan) * 0.35,
            tailLength: max(leftSpan, rightSpan) * 0.85,
            peakAlpha: peakAlpha
        )
    }

    /// Draws an elliptical dark halo behind button clusters or text to ensure contrast against glass highlights.
    public static func drawTextHalo(
        in ctx: CGContext,
        center: CGPoint,
        rx: CGFloat,
        ry: CGFloat,
        centerAlpha: CGFloat
    ) {
        guard centerAlpha > 0.015, rx > 2.0, ry > 2.0 else { return }
        ctx.saveGState()
        let cs = CGColorSpaceCreateDeviceRGB()
        let cColor = CGColor(srgbRed: 12/255.0, green: 14/255.0, blue: 18/255.0, alpha: centerAlpha)
        let edgeColor = CGColor(srgbRed: 12/255.0, green: 14/255.0, blue: 18/255.0, alpha: 0.0)
        if let grad = CGGradient(colorsSpace: cs, colors: [cColor, edgeColor] as CFArray, locations: [0.0, 1.0]) {
            ctx.translateBy(x: center.x, y: center.y)
            ctx.scaleBy(x: 1.0, y: ry / max(1.0, rx))
            ctx.drawRadialGradient(grad, startCenter: .zero, startRadius: 0, endCenter: .zero, endRadius: rx, options: [])
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
