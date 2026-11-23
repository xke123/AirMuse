import AppKit
import CoreGraphics
import CoreText
import Foundation

// MARK: - PixelFontRenderer

/// Renders AIRPLAY bitmap fonts (`TIMEFONT`, `MINIFONT`, `QUADFONT`),
/// Zion's 8-direction 1px compact halo text, and Windows `DrawGlyphHaloText`
/// (CoreText vector glyph path + 6 horizontal TearLayers + 12-sample Gaussian diffusion).
@MainActor
public enum PixelFontRenderer {

    /// Draws digital time text using `TIMEFONT` (90×14, 6×7 per glyph, 7px horizontal step).
    public static func drawTimeFont(
        in ctx: CGContext,
        text: String,
        origin: CGPoint,
        uiScale: CGFloat = 1.0,
        alpha: CGFloat = 0.88
    ) {
        guard let sheet = SkinAssetLoader.shared.image(for: .timeFont, resolution: .original1x) else { return }
        let charW: CGFloat = OriginalDesignTokens.BaseMetrics.timeFontCharWidth
        let charH: CGFloat = OriginalDesignTokens.BaseMetrics.timeFontCharHeight
        let step: CGFloat  = OriginalDesignTokens.BaseMetrics.timeFontCharStep

        ctx.saveGState()
        ctx.interpolationQuality = .none
        ctx.setAlpha(alpha)

        var curX = origin.x
        for ch in text {
            let col: Int?
            if let ascii = ch.asciiValue, ascii >= 48 && ascii <= 57 {
                col = Int(ascii - 48)
            } else if ch == ":" {
                col = 10
            } else if ch == "-" {
                col = 11
            } else if ch == "." {
                col = 12
            } else {
                col = nil
            }

            if let c = col,
               let glyph = sheet.cropping(to: CGRect(x: CGFloat(c) * charW, y: 0, width: charW, height: charH)) {
                ctx.draw(glyph, in: CGRect(x: curX, y: origin.y, width: charW * uiScale, height: charH * uiScale))
            }
            curX += step * uiScale
        }
        ctx.restoreGState()
    }

    /// Draws micro digits using `MINIFONT` (40×5, 4×5 per glyph, 5px horizontal step).
    public static func drawMiniFont(
        in ctx: CGContext,
        text: String,
        origin: CGPoint,
        uiScale: CGFloat = 1.0,
        alpha: CGFloat = 0.85
    ) {
        guard let sheet = SkinAssetLoader.shared.image(for: .miniFont, resolution: .original1x) else { return }
        let charW: CGFloat = OriginalDesignTokens.BaseMetrics.miniFontCharWidth
        let charH: CGFloat = OriginalDesignTokens.BaseMetrics.miniFontCharHeight
        let step: CGFloat  = 5.0

        ctx.saveGState()
        ctx.interpolationQuality = .none
        ctx.setAlpha(alpha)

        var curX = origin.x
        for ch in text {
            if let ascii = ch.asciiValue, ascii >= 48 && ascii <= 57 {
                let col = Int(ascii - 48)
                if let glyph = sheet.cropping(to: CGRect(x: CGFloat(col) * charW, y: 0, width: charW, height: charH)) {
                    ctx.draw(glyph, in: CGRect(x: curX, y: origin.y, width: charW * uiScale, height: charH * uiScale))
                }
            }
            curX += step * uiScale
        }
        ctx.restoreGState()
    }

    /// Creates an NSAttributedString with Zion's compact 1px halo shadow for crisp legibility on glass.
    public static func makeHaloAttributedString(
        _ string: String,
        font: NSFont,
        color: NSColor = OriginalDesignTokens.Colors.titleSilver,
        alignment: NSTextAlignment = .left,
        alpha: CGFloat = 1.0
    ) -> NSAttributedString {
        let shadow = NSShadow()
        shadow.shadowColor = OriginalDesignTokens.Colors.compactHalo.withAlphaComponent(0.75 * alpha)
        shadow.shadowOffset = NSSize(width: 0, height: -0.5)
        shadow.shadowBlurRadius = 1.2

        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = alignment
        paragraph.lineBreakMode = .byTruncatingTail

        return NSAttributedString(
            string: string,
            attributes: [
                .font: font,
                .foregroundColor: color.withAlphaComponent(alpha),
                .shadow: shadow,
                .paragraphStyle: paragraph
            ]
        )
    }

    /// Draws Zion's 8-direction 1px compact halo text directly into an AppKit graphics context.
    public static func drawCompactHaloText(
        _ text: String,
        in rect: CGRect,
        font: NSFont,
        textColor: NSColor = OriginalDesignTokens.Colors.titleSilver,
        haloColor: NSColor = OriginalDesignTokens.Colors.compactHalo,
        alignment: NSTextAlignment = .left,
        alpha: CGFloat = 1.0
    ) {
        guard !text.isEmpty, alpha > 0.01 else { return }

        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = alignment
        paragraph.lineBreakMode = .byTruncatingTail

        let haloAttrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: haloColor.withAlphaComponent(0.75 * alpha),
            .paragraphStyle: paragraph
        ]
        let fgAttrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: textColor.withAlphaComponent(alpha),
            .paragraphStyle: paragraph
        ]

        let offsets: [(CGFloat, CGFloat)] = [
            (-1, -1), (0, -1), (1, -1),
            (-1,  0),          (1,  0),
            (-1,  1), (0,  1), (1,  1)
        ]

        let nsStr = text as NSString
        for (dx, dy) in offsets {
            nsStr.draw(in: rect.offsetBy(dx: dx, dy: dy), withAttributes: haloAttrs)
        }
        nsStr.draw(in: rect, withAttributes: fgAttrs)
    }

    // MARK: - Windows DrawGlyphHaloText (TearLayer Horizontal Stretch + Gaussian Diffusion)

    private struct HaloCacheKey: Hashable {
        let text: String
        let fontName: String
        let fontSizeQ: Int
        let widthQ: Int
        let heightQ: Int
        let align: Int
        let scaleQ: Int
    }

    private static var glyphHaloCache: [HaloCacheKey: CGImage] = [:]
    private static var glyphHaloLRU: [HaloCacheKey] = []
    private static let haloPadX: CGFloat = 28.0
    private static let haloPadY: CGFloat = 22.0

    /// Replicates Windows `GlassRenderer::DrawGlyphHaloText` (`RenderGlyphHaloToBitmap`):
    /// Converts text glyphs into a vector `CGPath` via CoreText, renders 6 horizontally-stretched
    /// `TearLayer` silhouettes + 12-sample Gaussian glyph diffusion + 0.65px rim + crisp silver fill.
    public static func drawSoftGlyphHaloText(
        _ text: String,
        in rect: CGRect,
        font: NSFont,
        textColor: NSColor = OriginalDesignTokens.Colors.highlightSilver,
        alignment: NSTextAlignment = .center,
        alpha: CGFloat = 1.0
    ) {
        guard !text.isEmpty, alpha > 0.01, rect.width > 2, rect.height > 2,
              let ctx = NSGraphicsContext.current?.cgContext else { return }

        let backingScale = max(1.0, abs(ctx.convertToDeviceSpace(CGSize(width: 1, height: 1)).width))
        let key = HaloCacheKey(
            text: text,
            fontName: font.fontName,
            fontSizeQ: Int(round(font.pointSize * 10)),
            widthQ: Int(round(rect.width * 10)),
            heightQ: Int(round(rect.height * 10)),
            align: alignment.rawValue,
            scaleQ: Int(round(backingScale * 100))
        )

        let cachedImg: CGImage?
        if let hit = glyphHaloCache[key] {
            if let idx = glyphHaloLRU.firstIndex(of: key) {
                glyphHaloLRU.remove(at: idx)
                glyphHaloLRU.append(key)
            }
            cachedImg = hit
        } else {
            let rendered = renderGlyphHaloBitmap(
                text: text,
                font: font,
                rectSize: rect.size,
                alignment: alignment,
                textColor: textColor,
                backingScale: backingScale
            )
            if let rendered {
                if glyphHaloLRU.count >= 32, let oldest = glyphHaloLRU.first {
                    glyphHaloLRU.removeFirst()
                    glyphHaloCache.removeValue(forKey: oldest)
                }
                glyphHaloLRU.append(key)
                glyphHaloCache[key] = rendered
            }
            cachedImg = rendered
        }

        if let img = cachedImg {
            let drawRect = CGRect(
                x: round((rect.minX - haloPadX) * backingScale) / backingScale,
                y: round((rect.minY - haloPadY) * backingScale) / backingScale,
                width: rect.width + haloPadX * 2.0,
                height: rect.height + haloPadY * 2.0
            )
            ctx.saveGState()
            ctx.setAlpha(alpha)
            ctx.draw(img, in: drawRect)
            ctx.restoreGState()
        }

        // Draw single crisp foreground text via CoreText at the exact same baseline as the halo
        let ctFont = font as CTFont
        let attrStr = NSAttributedString(
            string: text,
            attributes: [
                .font: ctFont,
                .foregroundColor: textColor.withAlphaComponent(alpha)
            ]
        )
        let line = CTLineCreateWithAttributedString(attrStr)
        var ascent: CGFloat = 0
        var descent: CGFloat = 0
        var leading: CGFloat = 0
        let lineWidth = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, &leading))

        var tx = rect.minX
        if alignment == .center {
            tx = rect.midX - lineWidth * 0.5
        } else if alignment == .right {
            tx = rect.maxX - lineWidth
        }
        let ty = rect.midY - (ascent - descent) * 0.5
        let snappedTx = round(tx * backingScale) / backingScale
        let snappedTy = round(ty * backingScale) / backingScale

        ctx.saveGState()
        ctx.textMatrix = .identity
        ctx.textPosition = CGPoint(x: snappedTx, y: snappedTy)
        CTLineDraw(line, ctx)
        ctx.restoreGState()
    }

    private static func renderGlyphHaloBitmap(
        text: String,
        font: NSFont,
        rectSize: CGSize,
        alignment: NSTextAlignment,
        textColor: NSColor,
        backingScale: CGFloat
    ) -> CGImage? {
        let bmpW = max(1, Int(ceil((rectSize.width + haloPadX * 2.0) * backingScale)))
        let bmpH = max(1, Int(ceil((rectSize.height + haloPadY * 2.0) * backingScale)))
        let cs = CGColorSpaceCreateDeviceRGB()
        guard let bg = CGContext(
            data: nil,
            width: bmpW,
            height: bmpH,
            bitsPerComponent: 8,
            bytesPerRow: bmpW * 4,
            space: cs,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        bg.scaleBy(x: backingScale, y: backingScale)
        bg.clear(CGRect(x: 0, y: 0, width: rectSize.width + haloPadX * 2.0, height: rectSize.height + haloPadY * 2.0))

        let ctFont = font as CTFont
        let attrStr = NSAttributedString(string: text, attributes: [.font: ctFont])
        let line = CTLineCreateWithAttributedString(attrStr)
        var ascent: CGFloat = 0
        var descent: CGFloat = 0
        var leading: CGFloat = 0
        let lineWidth = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, &leading))
        let runs = CTLineGetGlyphRuns(line) as? [CTRun] ?? []

        let rawPath = CGMutablePath()
        for run in runs {
            let attrs = CTRunGetAttributes(run) as NSDictionary
            let runFont = (attrs[kCTFontAttributeName] as! CTFont?) ?? ctFont
            let count = CTRunGetGlyphCount(run)
            var glyphs = [CGGlyph](repeating: 0, count: count)
            var positions = [CGPoint](repeating: .zero, count: count)
            CTRunGetGlyphs(run, CFRangeMake(0, count), &glyphs)
            CTRunGetPositions(run, CFRangeMake(0, count), &positions)

            for i in 0..<count {
                if let gPath = CTFontCreatePathForGlyph(runFont, glyphs[i], nil) {
                    let t = CGAffineTransform(translationX: positions[i].x, y: positions[i].y)
                    rawPath.addPath(gPath, transform: t)
                }
            }
        }

        let bounds = rawPath.boundingBoxOfPath
        guard bounds.width > 0.1, bounds.height > 0.1 else { return nil }

        let localRect = CGRect(x: haloPadX, y: haloPadY, width: rectSize.width, height: rectSize.height)
        var tx = localRect.minX
        if alignment == .center {
            tx = localRect.midX - lineWidth * 0.5
        } else if alignment == .right {
            tx = localRect.maxX - lineWidth
        }
        let ty = localRect.midY - (ascent - descent) * 0.5

        var alignTransform = CGAffineTransform(translationX: tx, y: ty)
        guard let glyphPath = rawPath.copy(using: &alignTransform) else { return nil }
        let alignedBounds = glyphPath.boundingBoxOfPath
        let cx = alignedBounds.midX
        let cy = alignedBounds.midY

        bg.setLineJoin(.round)
        bg.setLineCap(.round)

        // 1. Windows TearLayers: horizontally-stretched dark glyph silhouettes
        struct TearLayer {
            let dx: CGFloat
            let dy: CGFloat
            let sx: CGFloat
            let width: CGFloat
            let alpha: CGFloat
        }
        let tears: [TearLayer] = [
            TearLayer(dx: -17.0, dy:  0.7, sx: 1.18, width: 11.5, alpha: 12.0 / 255.0),
            TearLayer(dx:  18.0, dy: -0.6, sx: 1.20, width: 12.0, alpha: 12.0 / 255.0),
            TearLayer(dx: -10.0, dy: -1.0, sx: 1.10, width:  9.5, alpha: 17.0 / 255.0),
            TearLayer(dx:  10.5, dy:  0.9, sx: 1.12, width:  9.5, alpha: 17.0 / 255.0),
            TearLayer(dx:  -4.5, dy:  0.4, sx: 1.05, width:  8.0, alpha: 22.0 / 255.0),
            TearLayer(dx:   5.0, dy: -0.4, sx: 1.05, width:  8.0, alpha: 22.0 / 255.0)
        ]

        for tl in tears {
            bg.saveGState()
            bg.translateBy(x: cx + tl.dx, y: cy + tl.dy)
            bg.scaleBy(x: tl.sx, y: 0.90)
            bg.translateBy(x: -cx, y: -cy)
            bg.setStrokeColor(CGColor(srgbRed: 14/255.0, green: 16/255.0, blue: 20/255.0, alpha: tl.alpha))
            bg.setLineWidth(tl.width)
            bg.addPath(glyphPath)
            bg.strokePath()
            bg.restoreGState()
        }

        // 2. 12-sample Gaussian glyph diffusion
        let kSamples = 12
        let kMaxRadius: CGFloat = 18.0
        let kSigma: CGFloat = 7.2
        let kPeakAlpha: CGFloat = 28.0 / 255.0

        for i in stride(from: kSamples, through: 1, by: -1) {
            let t = CGFloat(i) / CGFloat(kSamples)
            let radius = kMaxRadius * (t * t * 0.6 + t * 0.4)
            let gaussian = exp(-(radius * radius) / (2.0 * kSigma * kSigma))
            let a = min(1.0, kPeakAlpha * gaussian)
            if a <= 0.002 { continue }
            bg.setStrokeColor(CGColor(srgbRed: 14/255.0, green: 16/255.0, blue: 20/255.0, alpha: a))
            bg.setLineWidth(radius * 2.0)
            bg.addPath(glyphPath)
            bg.strokePath()
        }

        // 3. Subtle 0.65px dark outline behind foreground glyphs
        bg.setStrokeColor(CGColor(srgbRed: 18/255.0, green: 20/255.0, blue: 24/255.0, alpha: 38.0 / 255.0))
        bg.setLineWidth(0.65)
        bg.addPath(glyphPath)
        bg.strokePath()

        return bg.makeImage()
    }
}
