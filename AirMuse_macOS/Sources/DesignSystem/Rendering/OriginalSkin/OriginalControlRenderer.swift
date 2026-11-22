import AppKit
import CoreGraphics
import Foundation

// MARK: - OriginalControlRenderer

/// Renders original AIRPLAY sprite controls, capsule progress bar, and 8-segment volume meter.
@MainActor
public enum OriginalControlRenderer {

    /// Draws a sprite image with AIRPLAY's exact Normal / Hover / Pressed / Disabled state physics.
    public static func drawSprite(
        in ctx: CGContext,
        sprite: CGImage,
        rect: CGRect,
        state: ControlState,
        crisp1x: Bool = false
    ) {
        guard rect.width > 0, rect.height > 0 else { return }

        var drawRect = rect
        // CGContext is bottom-up, so +1pt down means y -= 1
        if state == .pressed {
            drawRect.origin.y -= 1.0
        }

        ctx.saveGState()
        ctx.interpolationQuality = crisp1x ? .none : .high
        ctx.setAlpha(state.alpha)
        ctx.draw(sprite, in: drawRect)

        // Subtle additive highlight pass for Hover brightness boost
        if state == .hover {
            ctx.setBlendMode(.plusLighter)
            ctx.setAlpha(0.18)
            ctx.draw(sprite, in: drawRect)
        }
        ctx.restoreGState()
    }

    /// Draws the AIRPLAY capsule progress bar matching GlassRenderer::DrawCapsuleProgress.
    public static func drawCapsuleProgress(
        in ctx: CGContext,
        rect: CGRect,
        ratio: CGFloat,
        isHighlighted: Bool,
        isScrubbing: Bool
    ) {
        let clamped = min(max(ratio, 0), 1)
        let h = isScrubbing ? rect.height + 2.0 : rect.height
        let y = isScrubbing ? rect.minY - 1.0 : rect.minY
        let barRect = CGRect(x: rect.minX, y: y, width: rect.width, height: h)
        let r = h * 0.5

        let bgPath = CGPath(roundedRect: barRect, cornerWidth: r, cornerHeight: r, transform: nil)
        ctx.saveGState()
        ctx.setFillColor(CGColor(srgbRed: 23/255.0, green: 23/255.0, blue: 23/255.0, alpha: 180/255.0))
        ctx.addPath(bgPath)
        ctx.fillPath()

        let borderAlpha: CGFloat = (isHighlighted || isScrubbing) ? (160/255.0) : (60/255.0)
        ctx.setStrokeColor(CGColor(srgbRed: 201/255.0, green: 201/255.0, blue: 201/255.0, alpha: borderAlpha))
        ctx.setLineWidth(1.0)
        ctx.addPath(bgPath)
        ctx.strokePath()

        if clamped > 0.015 {
            let fillW = max(h - 2.0, (rect.width - 2.0) * clamped)
            let fillRect = CGRect(x: rect.minX + 1.0, y: y + 1.0, width: fillW, height: max(1.0, h - 2.0))
            let fr = fillRect.height * 0.5
            let fgPath = CGPath(roundedRect: fillRect, cornerWidth: fr, cornerHeight: fr, transform: nil)

            ctx.addPath(fgPath)
            ctx.clip()

            let cs = CGColorSpaceCreateDeviceRGB()
            let topC = CGColor(srgbRed: 201/255.0, green: 201/255.0, blue: 201/255.0, alpha: 245/255.0)
            let botC = CGColor(srgbRed: 166/255.0, green: 166/255.0, blue: 166/255.0, alpha: 220/255.0)
            if let grad = CGGradient(colorsSpace: cs, colors: [topC, botC] as CFArray, locations: [0, 1]) {
                ctx.drawLinearGradient(
                    grad,
                    start: CGPoint(x: fillRect.minX, y: fillRect.maxY),
                    end: CGPoint(x: fillRect.minX, y: fillRect.minY),
                    options: []
                )
            }
        }
        ctx.restoreGState()
    }

    /// Draws the 8-segment vertical volume meter on the right side of the main player.
    public static func drawVolumeSegments(
        in ctx: CGContext,
        origin: CGPoint,
        uiScale: CGFloat,
        volume: Float,
        alpha: CGFloat
    ) {
        guard alpha > 0.01 else { return }
        let volPercent = Int(round(min(max(volume, 0), 1) * 100.0))
        let segW = 7.0 * uiScale
        let segH = 2.0 * uiScale
        let stepY = 4.0 * uiScale

        ctx.saveGState()
        for seg in 0..<8 {
            let active = (seg * 12) < volPercent
            let segAlpha = (active ? (200.0 / 255.0) : (65.0 / 255.0)) * alpha
            let col = active
                ? CGColor(srgbRed: 201/255.0, green: 201/255.0, blue: 201/255.0, alpha: segAlpha)
                : CGColor(srgbRed: 80/255.0, green: 80/255.0, blue: 80/255.0, alpha: segAlpha)
            ctx.setFillColor(col)
            ctx.fill(CGRect(x: origin.x, y: origin.y + CGFloat(seg) * stepY, width: segW, height: segH))
        }
        ctx.restoreGState()
    }
}
