import AppKit
import Foundation

// MARK: - DesignTokens

/// Shared design tokens for AirMuse macOS Liquid Glass UI.
@MainActor
public enum DesignTokens {

    // MARK: - Dimensions

    public enum Metrics {
        public static let mainPlayerWidth: CGFloat    = 330
        public static let mainPlayerHeight: CGFloat   = 106

        public static let miniPlayerWidth: CGFloat    = 330
        public static let miniPlayerHeight: CGFloat   = 40

        public static let lyricsWindowWidth: CGFloat  = 330
        public static let lyricsWindowHeight: CGFloat = 240

        public static let libraryWindowWidth: CGFloat = 540
        public static let libraryWindowHeight: CGFloat = 570

        public static let glassBorderWidth: CGFloat   = 1.0
        public static let snapDistance: CGFloat       = 16.0
    }

    // MARK: - Corner Radii

    public enum CornerRadius {
        public static let capsule: CGFloat = 999.0
        public static let panel: CGFloat   = 16.0
        public static let window: CGFloat  = 12.0
        public static let control: CGFloat = 8.0
        public static let artwork: CGFloat = 6.0
        public static let mini: CGFloat    = 4.0   // Classic AirPlay 4px radius
    }

    // MARK: - Spacing

    public enum Spacing {
        public static let xxs: CGFloat = 2.0
        public static let xs: CGFloat  = 4.0
        public static let sm: CGFloat  = 8.0
        public static let md: CGFloat  = 12.0
        public static let lg: CGFloat  = 16.0
        public static let xl: CGFloat  = 20.0
    }

    // MARK: - Colors & Tints

    @MainActor
    public enum Colors {
        public static let primaryText   = NSColor(white: 0.95, alpha: 1.0)
        public static let secondaryText = NSColor(white: 0.70, alpha: 1.0)
        public static let tertiaryText  = NSColor(white: 0.45, alpha: 1.0)

        // Glass overlay and borders
        public static let glassBorderLight  = NSColor(white: 1.0, alpha: 0.22)
        public static let glassBorderDark   = NSColor(white: 0.0, alpha: 0.35)
        public static let glassHighlight    = NSColor(white: 1.0, alpha: 0.15)
        public static let glassBackground   = NSColor(calibratedRed: 0.11, green: 0.11, blue: 0.13, alpha: 0.65)

        // Platform Brand Colors
        public static let appleMusicPink = NSColor(calibratedRed: 0.98, green: 0.14, blue: 0.24, alpha: 1.0)
        public static let spotifyGreen   = NSColor(calibratedRed: 0.11, green: 0.73, blue: 0.33, alpha: 1.0)
        public static let qqMusicGreen   = NSColor(calibratedRed: 0.19, green: 0.76, blue: 0.49, alpha: 1.0)

        // Halo text shadow color (from Zion reverse engineering)
        public static let haloShadow     = NSColor(white: 0.05, alpha: 0.85)
    }

    // MARK: - Typography

    @MainActor
    public enum Typography {
        public static let titleFont    = NSFont.systemFont(ofSize: 12, weight: .semibold)
        public static let artistFont   = NSFont.systemFont(ofSize: 10, weight: .regular)
        public static let timeFont     = NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .medium)
        public static let miniFont     = NSFont.systemFont(ofSize: 9, weight: .regular)
        public static let lyricsActive = NSFont.systemFont(ofSize: 14, weight: .bold)
        public static let lyricsNormal = NSFont.systemFont(ofSize: 12, weight: .regular)
    }
}
