import AppKit
import CoreGraphics
import Foundation

// MARK: - PixelFontRenderer

/// Renders AIRPLAY bitmap fonts (`TIMEFONT`, `MINIFONT`, `QUADFONT`) and
/// Zion's 8-direction 1px compact halo text.
@MainActor
public enum PixelFontRenderer {

    /// Draws digital time text using `TIMEFONT` (90×14, 6×7 per glyph, 7px horizontal step).
    /// Supported chars: '0'..'9', ':', '-', '.', ' '.
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
                col = Int(ascii - 48) // '0'..'9' -> 0..9
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

    /// Draws Zion's 8-direction 1px compact halo text directly into a flipped/unflipped AppKit graphics context.
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

    /// Replicates Windows `GlassRenderer::DrawGlyphHaloText`:
    /// Soft multi-pass Gaussian dark-mist bloom behind crisp `rgb(201, 201, 201)` silver glyphs.
    public static func drawSoftGlyphHaloText(
        _ text: String,
        in rect: CGRect,
        font: NSFont,
        textColor: NSColor = OriginalDesignTokens.Colors.highlightSilver,
        alignment: NSTextAlignment = .center,
        alpha: CGFloat = 1.0
    ) {
        guard !text.isEmpty, alpha > 0.01, let ctx = NSGraphicsContext.current?.cgContext else { return }

        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = alignment
        paragraph.lineBreakMode = .byTruncatingTail

        let nsStr = text as NSString
        let measuredW = min(rect.width, nsStr.size(withAttributes: [.font: font]).width)
        let centerX: CGFloat
        switch alignment {
        case .left:   centerX = rect.minX + measuredW * 0.5
        case .right:  centerX = rect.maxX - measuredW * 0.5
        default:      centerX = rect.midX
        }
        let centerY = rect.midY

        let rx = max(24.0, measuredW * 0.62 + 18.0)
        let ry = max(10.0, rect.height * 0.45)
        let cs = CGColorSpaceCreateDeviceRGB()
        let mistCenter = CGColor(srgbRed: 14/255.0, green: 16/255.0, blue: 20/255.0, alpha: 0.48 * alpha)
        let mistEdge = CGColor(srgbRed: 14/255.0, green: 16/255.0, blue: 20/255.0, alpha: 0.0)
        if let grad = CGGradient(colorsSpace: cs, colors: [mistCenter, mistEdge] as CFArray, locations: [0.0, 1.0]) {
            ctx.saveGState()
            ctx.translateBy(x: centerX, y: centerY)
            ctx.scaleBy(x: 1.0, y: ry / rx)
            ctx.drawRadialGradient(grad, startCenter: .zero, startRadius: 0, endCenter: .zero, endRadius: rx, options: [])
            ctx.restoreGState()
        }

        let shadowPasses: [(blur: CGFloat, a: CGFloat)] = [
            (12.0, 0.55 * alpha),
            (5.0,  0.45 * alpha),
            (1.2,  0.22 * alpha)
        ]
        for pass in shadowPasses {
            ctx.saveGState()
            ctx.setShadow(offset: .zero, blur: pass.blur, color: CGColor(srgbRed: 14/255.0, green: 16/255.0, blue: 20/255.0, alpha: pass.a))
            let attrs: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: textColor.withAlphaComponent(0.05 * alpha),
                .paragraphStyle: paragraph
            ]
            nsStr.draw(in: rect, withAttributes: attrs)
            ctx.restoreGState()
        }

        let fgAttrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: textColor.withAlphaComponent(alpha),
            .paragraphStyle: paragraph
        ]
        nsStr.draw(in: rect, withAttributes: fgAttrs)
    }
}
