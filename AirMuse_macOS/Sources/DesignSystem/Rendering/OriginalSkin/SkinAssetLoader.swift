import AppKit
import CoreGraphics
import Foundation

// MARK: - SkinAssetName

public enum SkinAssetName: String, CaseIterable, Sendable {
    case windowGlass       = "WINDOWGLASS"
    case windowGlassFocus  = "WINDOWGLASSFOCUS"
    case mainControl       = "MAINCONTROL"
    case miniControl       = "MINICONTROL"
    case windowButton      = "WINDOWBUTTON"
    case iconButton        = "ICONBUTTON"
    case timeFont          = "TIMEFONT"
    case miniFont          = "MINIFONT"
    case quadFont          = "QUADFONT"
    case hintGlass         = "HINTGLASS"
    case menuGlass         = "MENUGLASS"
    case menuIcon          = "MENUICON"
    case packHint          = "PACKHINT"
    case rating            = "RATING"
}

// MARK: - SkinAssetLoader

/// Loads and caches original AIRPLAY 1× and 4× Retina PNG skin assets from Bundle.module.
@MainActor
public final class SkinAssetLoader {

    public static let shared = SkinAssetLoader()

    private struct CacheKey: Hashable {
        let name: SkinAssetName
        let resolution: SkinResolutionMode
    }

    private var cache: [CacheKey: CGImage] = [:]

    public init() {}

    /// Returns the CGImage for the requested skin asset and resolution mode.
    /// Falls back to 1× if a 4× asset is not available.
    public func image(for name: SkinAssetName, resolution: SkinResolutionMode = .retina4x) -> CGImage? {
        let key = CacheKey(name: name, resolution: resolution)
        if let cached = cache[key] {
            return cached
        }

        let subdirs: [String] = resolution == .retina4x
            ? ["Resources/Skin/4x", "Resources/Skin/1x", "Skin/4x", "Skin/1x"]
            : ["Resources/Skin/1x", "Skin/1x", "Resources/Skin/4x"]

        for subdir in subdirs {
            if let url = Bundle.module.url(forResource: name.rawValue, withExtension: "png", subdirectory: subdir),
               let nsImg = NSImage(contentsOf: url) {
                var rect = NSRect(origin: .zero, size: nsImg.size)
                if let cg = nsImg.cgImage(forProposedRect: &rect, context: nil, hints: nil) {
                    cache[key] = cg
                    return cg
                }
            }
        }
        return nil
    }

    /// Returns the scale factor of the loaded asset relative to 1× original dimensions.
    public func assetScaleFactor(for name: SkinAssetName, resolution: SkinResolutionMode) -> CGFloat {
        guard let cg = image(for: name, resolution: resolution) else { return 1.0 }
        switch name {
        case .windowGlass, .windowGlassFocus:
            return CGFloat(cg.width) / 30.0
        case .mainControl:
            return CGFloat(cg.width) / 192.0
        case .miniControl:
            return CGFloat(cg.width) / 96.0
        case .windowButton:
            return CGFloat(cg.width) / 130.0
        case .iconButton:
            return CGFloat(cg.width) / 165.0
        default:
            return 1.0
        }
    }

    /// Preloads all core skin assets into memory.
    public func preloadCoreAssets(resolution: SkinResolutionMode = .retina4x) {
        let core: [SkinAssetName] = [
            .windowGlass, .windowGlassFocus, .mainControl, .miniControl,
            .windowButton, .iconButton, .timeFont, .miniFont, .hintGlass, .menuGlass
        ]
        for item in core {
            _ = image(for: item, resolution: resolution)
        }
    }

    public func clearCache() {
        cache.removeAll()
    }
}
