import CoreGraphics
import Foundation

// MARK: - NineSliceRenderer

/// Faithful 9-slice renderer for AIRPLAY glass frames (`WINDOWGLASS`, `WINDOWGLASSFOCUS`, `HINTGLASS`, `MENUGLASS`).
/// Preserves corner geometry and specular rim endpoints without stretching corners.
public enum NineSliceRenderer {

    /// Draws an AIRPLAY 9-slice glass frame into a Core Graphics context (bottom-left CG origin).
    /// - Parameters:
    ///   - ctx: Target CGContext in logical points (or scaled).
    ///   - glass: The 30×40 (1×) or 120×160 (4×) glass asset.
    ///   - rect: Destination rect in CGContext coordinates.
    ///   - uiScale: UI scale multiplier (1.0 for 330×106, 1.5 for 495×159).
    ///   - alpha: Opacity [0, 1].
    ///   - crisp1x: When true, uses `.none` interpolation for pixel-sharp 1× edges.
    public static func drawGlass9Slice(
        in ctx: CGContext,
        glass: CGImage,
        rect: CGRect,
        uiScale: CGFloat = 1.0,
        alpha: CGFloat = 1.0,
        crisp1x: Bool = false
    ) {
        guard rect.width > 0, rect.height > 0, alpha > 0.001 else { return }

        let s = CGFloat(glass.width) / 30.0
        let dstCW = OriginalDesignTokens.BaseMetrics.glassCornerCapWidth * uiScale  // 15 * scale
        let dstCH = min(OriginalDesignTokens.BaseMetrics.glassCapHeight * uiScale, rect.height * 0.5)
        let srcCW = 15.0 * s
        let srcCH = 20.0 * s
        let srcW = CGFloat(glass.width)
        let srcH = CGFloat(glass.height)

        ctx.saveGState()
        ctx.setAlpha(alpha)
        ctx.interpolationQuality = crisp1x ? .none : .high

        let x0 = rect.minX
        let y0 = rect.minY
        let w = rect.width
        let h = rect.height

        // Helper to crop (top-left CGImage coords) and draw into CGContext (bottom-left coords)
        func blit(src: CGRect, dst: CGRect) {
            guard dst.width > 0.01, dst.height > 0.01,
                  let sub = glass.cropping(to: src) else { return }
            ctx.draw(sub, in: dst)
        }

        // 1. Top Cap (CGImage y: 0..20*s -> CGContext dst y: y0 + h - dstCH .. y0 + h)
        let topDstY = y0 + h - dstCH
        if w <= dstCW * 2.0 {
            let halfW = w * 0.5
            let ratio = halfW / dstCW
            blit(src: CGRect(x: 0, y: 0, width: srcCW * ratio, height: srcCH),
                 dst: CGRect(x: x0, y: topDstY, width: halfW, height: dstCH))
            blit(src: CGRect(x: srcW - srcCW * ratio, y: 0, width: srcCW * ratio, height: srcCH),
                 dst: CGRect(x: x0 + halfW, y: topDstY, width: halfW, height: dstCH))
        } else {
            let edgeDstW = w - dstCW * 2.0
            blit(src: CGRect(x: 0, y: 0, width: srcCW, height: srcCH),
                 dst: CGRect(x: x0, y: topDstY, width: dstCW, height: dstCH))
            blit(src: CGRect(x: srcW - srcCW, y: 0, width: srcCW, height: srcCH),
                 dst: CGRect(x: x0 + w - dstCW, y: topDstY, width: dstCW, height: dstCH))
            blit(src: CGRect(x: 14.0 * s, y: 0, width: 2.0 * s, height: srcCH),
                 dst: CGRect(x: x0 + dstCW, y: topDstY, width: edgeDstW, height: dstCH))
        }

        // 2. Bottom Cap (CGImage y: srcH - 20*s .. srcH -> CGContext dst y: y0 .. y0 + dstCH)
        let botSrcY = srcH - srcCH
        if w <= dstCW * 2.0 {
            let halfW = w * 0.5
            let ratio = halfW / dstCW
            blit(src: CGRect(x: 0, y: botSrcY, width: srcCW * ratio, height: srcCH),
                 dst: CGRect(x: x0, y: y0, width: halfW, height: dstCH))
            blit(src: CGRect(x: srcW - srcCW * ratio, y: botSrcY, width: srcCW * ratio, height: srcCH),
                 dst: CGRect(x: x0 + halfW, y: y0, width: halfW, height: dstCH))
        } else {
            let edgeDstW = w - dstCW * 2.0
            blit(src: CGRect(x: 0, y: botSrcY, width: srcCW, height: srcCH),
                 dst: CGRect(x: x0, y: y0, width: dstCW, height: dstCH))
            blit(src: CGRect(x: srcW - srcCW, y: botSrcY, width: srcCW, height: srcCH),
                 dst: CGRect(x: x0 + w - dstCW, y: y0, width: dstCW, height: dstCH))
            blit(src: CGRect(x: 14.0 * s, y: botSrcY, width: 2.0 * s, height: srcCH),
                 dst: CGRect(x: x0 + dstCW, y: y0, width: edgeDstW, height: dstCH))
        }

        // 3. Left & Right Vertical Edges (5px * uiScale wide, only when height > 40 * uiScale)
        let midH = h - dstCH * 2.0
        if midH > 0.5 {
            let edgeW = OriginalDesignTokens.BaseMetrics.glassBorderThickness * uiScale
            let srcEdgeW = 5.0 * s
            let srcEdgeY = 19.0 * s
            let srcEdgeH = 2.0 * s
            blit(src: CGRect(x: 0, y: srcEdgeY, width: srcEdgeW, height: srcEdgeH),
                 dst: CGRect(x: x0, y: y0 + dstCH, width: edgeW, height: midH))
            blit(src: CGRect(x: srcW - srcEdgeW, y: srcEdgeY, width: srcEdgeW, height: srcEdgeH),
                 dst: CGRect(x: x0 + w - edgeW, y: y0 + dstCH, width: edgeW, height: midH))
        }

        ctx.restoreGState()
    }

    /// Draws a generic 9-slice glass plate (e.g. HINTGLASS or MENUGLASS 40×40) with 12px borders.
    public static func drawPlate9Slice(
        in ctx: CGContext,
        plate: CGImage,
        rect: CGRect,
        cap: CGFloat = 12.0,
        alpha: CGFloat = 1.0
    ) {
        guard rect.width > 0, rect.height > 0, alpha > 0.001 else { return }
        let pw = CGFloat(plate.width)
        let ph = CGFloat(plate.height)
        let c = min(cap, min(rect.width, rect.height) * 0.45)
        let sc = min(cap, min(pw, ph) * 0.45)

        ctx.saveGState()
        ctx.setAlpha(alpha)
        ctx.interpolationQuality = .high

        func blit(_ sx: CGFloat, _ sy: CGFloat, _ sw: CGFloat, _ sh: CGFloat,
                  _ dx: CGFloat, _ dy: CGFloat, _ dw: CGFloat, _ dh: CGFloat) {
            guard dw > 0.01, dh > 0.01, sw > 0.01, sh > 0.01,
                  let sub = plate.cropping(to: CGRect(x: sx, y: sy, width: sw, height: sh)) else { return }
            ctx.draw(sub, in: CGRect(x: dx, y: dy, width: dw, height: dh))
        }

        let x0 = rect.minX, y0 = rect.minY, w = rect.width, h = rect.height
        let midW = w - c * 2, midH = h - c * 2
        let srcMidW = pw - sc * 2, srcMidH = ph - sc * 2

        // Top row (CGImage y: 0..sc -> dst y: y0+h-c..y0+h)
        blit(0, 0, sc, sc, x0, y0 + h - c, c, c)
        blit(sc, 0, srcMidW, sc, x0 + c, y0 + h - c, midW, c)
        blit(pw - sc, 0, sc, sc, x0 + w - c, y0 + h - c, c, c)

        // Middle row
        blit(0, sc, sc, srcMidH, x0, y0 + c, c, midH)
        blit(sc, sc, srcMidW, srcMidH, x0 + c, y0 + c, midW, midH)
        blit(pw - sc, sc, sc, srcMidH, x0 + w - c, y0 + c, c, midH)

        // Bottom row (CGImage y: ph-sc..ph -> dst y: y0..y0+c)
        blit(0, ph - sc, sc, sc, x0, y0, c, c)
        blit(sc, ph - sc, srcMidW, sc, x0 + c, y0, midW, c)
        blit(pw - sc, ph - sc, sc, sc, x0 + w - c, y0, c, c)

        ctx.restoreGState()
    }
}
