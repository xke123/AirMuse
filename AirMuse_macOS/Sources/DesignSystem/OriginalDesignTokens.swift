import AppKit
import Foundation

// MARK: - OriginalDesignTokens

/// Pixel-accurate geometry, color, and typography tokens extracted from
/// AIRPLAY-zion_unpacked.exe and AirMuse_Remastered.
public enum OriginalDesignTokens {

    /// Supported UI scale presets.
    /// - `1.0` = Exact 1:1 original AIRPLAY logical dimensions (330×106, 330×40)
    /// - `1.5` = Default macOS Retina-comfortable scale (495×159, 495×60)
    public enum Scale {
        public static let original1x: CGFloat = 1.0
        public static let macDefault: CGFloat = 1.5
    }

    /// 1× Original logical geometry (DIP) before applying `uiScale`.
    public enum BaseMetrics {
        // Glass Frame (from WINDOWGLASS 30×40 & disassembly 0x47DA6A, 0x47BB2F)
        public static let glassBorderThickness: CGFloat = 5.0
        public static let glassCapHeight: CGFloat       = 20.0
        public static let glassCornerCapWidth: CGFloat  = 15.0
        public static let glassTotalVFrame: CGFloat     = 40.0
        public static let glassCornerRadius: CGFloat    = 4.0
        public static let miniCornerRadius: CGFloat     = 3.2

        // Window Dimensions (1×)
        public static let mainPlayerWidth: CGFloat      = 330.0
        public static let mainPlayerHeight: CGFloat     = 106.0
        public static let miniBarStandardHeight: CGFloat = 40.0
        public static let miniBarCompactHeight: CGFloat  = 30.0
        public static let lyricsWindowWidth: CGFloat    = 330.0
        public static let lyricsWindowHeight: CGFloat   = 284.0
        public static let libraryWindowWidth: CGFloat   = 360.0
        public static let libraryWindowHeight: CGFloat  = 380.0

        // Dock & Snap (from DockManager.cpp)
        public static let dockSnapDistance: CGFloat     = 16.0
        public static let dockOverlap: CGFloat          = 10.0

        // Sprite Sizes (1×)
        public static let mainControlSize: CGFloat      = 32.0
        public static let miniControlSize: CGFloat      = 16.0
        public static let windowButtonSize: CGFloat     = 13.0
        public static let iconButtonSize: CGFloat       = 15.0
        public static let timeFontCharWidth: CGFloat    = 6.0
        public static let timeFontCharHeight: CGFloat   = 7.0
        public static let timeFontCharStep: CGFloat     = 7.0
        public static let miniFontCharWidth: CGFloat    = 4.0
        public static let miniFontCharHeight: CGFloat   = 5.0
        public static let quadFontCharWidth: CGFloat    = 10.0
        public static let quadFontCharHeight: CGFloat   = 8.0
    }

    public enum Colors {
        // Middle body backgrounds (from GlassRenderer.cpp)
        public static let mainBodyTop = NSColor(srgbRed: 58/255.0, green: 58/255.0, blue: 58/255.0, alpha: 1.0)
        public static let mainBodyBottom = NSColor(srgbRed: 31/255.0, green: 31/255.0, blue: 31/255.0, alpha: 1.0)
        public static let panelBody = NSColor(srgbRed: 23/255.0, green: 23/255.0, blue: 23/255.0, alpha: 1.0)

        // Groove seams between glass caps and body
        public static let grooveDark = NSColor(srgbRed: 12/255.0, green: 13/255.0, blue: 16/255.0, alpha: 1.0)
        public static let grooveLight = NSColor(white: 1.0, alpha: 1.0)

        // Text colors (from MINI_MODE_SPECIFICATION & MainWindow.cpp)
        public static let titleSilver = NSColor(srgbRed: 235/255.0, green: 235/255.0, blue: 235/255.0, alpha: 1.0)
        public static let subSilver = NSColor(srgbRed: 166/255.0, green: 166/255.0, blue: 166/255.0, alpha: 1.0)
        public static let highlightSilver = NSColor(srgbRed: 201/255.0, green: 201/255.0, blue: 201/255.0, alpha: 1.0)
        public static let dimSilver = NSColor(srgbRed: 110/255.0, green: 110/255.0, blue: 110/255.0, alpha: 1.0)
        public static let compactHalo = NSColor(srgbRed: 15/255.0, green: 15/255.0, blue: 15/255.0, alpha: 0.78)
        public static let spillFogDark = NSColor(srgbRed: 14/255.0, green: 16/255.0, blue: 20/255.0, alpha: 1.0)

        // Specular sweep lens flare
        public static let sweepCyan = NSColor(srgbRed: 130/255.0, green: 215/255.0, blue: 255/255.0, alpha: 1.0)
        public static let sweepCore = NSColor(srgbRed: 250/255.0, green: 252/255.0, blue: 255/255.0, alpha: 1.0)
    }
}
