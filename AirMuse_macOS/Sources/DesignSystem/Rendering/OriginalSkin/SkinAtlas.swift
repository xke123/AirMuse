import CoreGraphics
import Foundation

// MARK: - Sprite Indices

public enum MainControlSprite: Int, CaseIterable, Sendable {
    case stop     = 0
    case previous = 1
    case play     = 2
    case pause    = 3
    case next     = 4
    case eject    = 5
}

public enum WindowButtonSprite: Sendable, Equatable {
    // Row 0 (10 cols, 13×13 each @ 1x)
    case minimize      // (0, 0)
    case maximize      // (1, 0)
    case close         // (2, 0)
    case expandDown    // (3, 0)
    case collapseUp    // (4, 0)
    case unpinned      // (5, 0)
    case pinned        // (6, 0)
    case miniToggle    // (7, 0)
    case libraryPanel  // (8, 0)
    case dockArrow     // (9, 0)
    // Row 1
    case disc          // (0, 1)
    case dropdown      // (1, 1)
    case upArrow       // (3, 1)
    case downArrow     // (4, 1)
    case playlist      // (5, 1)
    case lyricsNote    // (6, 1)

    public var gridCoord: (col: Int, row: Int) {
        switch self {
        case .minimize:     return (0, 0)
        case .maximize:     return (1, 0)
        case .close:        return (2, 0)
        case .expandDown:   return (3, 0)
        case .collapseUp:   return (4, 0)
        case .unpinned:     return (5, 0)
        case .pinned:       return (6, 0)
        case .miniToggle:   return (7, 0)
        case .libraryPanel: return (8, 0)
        case .dockArrow:    return (9, 0)
        case .disc:         return (0, 1)
        case .dropdown:     return (1, 1)
        case .upArrow:      return (3, 1)
        case .downArrow:    return (4, 1)
        case .playlist:     return (5, 1)
        case .lyricsNote:   return (6, 1)
        }
    }
}

// MARK: - SkinAtlas

/// Crops and caches individual sprite tiles from original AIRPLAY sprite sheets.
@MainActor
public final class SkinAtlas {

    public static let shared = SkinAtlas()

    private struct TileKey: Hashable {
        let asset: SkinAssetName
        let resolution: SkinResolutionMode
        let col: Int
        let row: Int
        let cols: Int
        let rows: Int
    }

    private var tileCache: [TileKey: CGImage] = [:]

    public init() {}

    public func tile(
        from asset: SkinAssetName,
        col: Int,
        row: Int,
        cols: Int,
        rows: Int,
        resolution: SkinResolutionMode = .retina4x
    ) -> CGImage? {
        let key = TileKey(asset: asset, resolution: resolution, col: col, row: row, cols: cols, rows: rows)
        if let cached = tileCache[key] {
            return cached
        }
        guard let sheet = SkinAssetLoader.shared.image(for: asset, resolution: resolution) else {
            return nil
        }
        let tileW = sheet.width / cols
        let tileH = sheet.height / rows
        guard tileW > 0, tileH > 0, col >= 0, col < cols, row >= 0, row < rows else {
            return nil
        }
        // CGImage.cropping uses top-left origin!
        let cropRect = CGRect(x: col * tileW, y: row * tileH, width: tileW, height: tileH)
        guard let cropped = sheet.cropping(to: cropRect) else {
            return nil
        }
        tileCache[key] = cropped
        return cropped
    }

    public func mainControl(_ sprite: MainControlSprite, resolution: SkinResolutionMode = .retina4x) -> CGImage? {
        tile(from: .mainControl, col: sprite.rawValue, row: 0, cols: 6, rows: 1, resolution: resolution)
    }

    public func miniControl(_ sprite: MainControlSprite, resolution: SkinResolutionMode = .retina4x) -> CGImage? {
        tile(from: .miniControl, col: sprite.rawValue, row: 0, cols: 6, rows: 1, resolution: resolution)
    }

    public func windowButton(_ sprite: WindowButtonSprite, resolution: SkinResolutionMode = .retina4x) -> CGImage? {
        let coord = sprite.gridCoord
        return tile(from: .windowButton, col: coord.col, row: coord.row, cols: 10, rows: 2, resolution: resolution)
    }

    public func iconButton(col: Int, row: Int, resolution: SkinResolutionMode = .retina4x) -> CGImage? {
        tile(from: .iconButton, col: col, row: row, cols: 11, rows: 3, resolution: resolution)
    }

    public func clearCache() {
        tileCache.removeAll()
    }
}
