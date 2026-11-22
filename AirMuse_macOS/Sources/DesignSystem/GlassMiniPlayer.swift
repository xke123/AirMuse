import AppKit

// MARK: - GlassMiniPlayer

/// The 40pt height mini player container.
/// Follows the AirPlay Zion specification:
/// - 40px height
/// - 4px corner radius
/// - 5px glass border thickness
/// - Pure transparent glass channels without opaque dark rectangle artifacts
open class GlassMiniPlayer: GlassSurface {

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        cornerRadius = DesignTokens.CornerRadius.mini
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
        cornerRadius = DesignTokens.CornerRadius.mini
    }
}

