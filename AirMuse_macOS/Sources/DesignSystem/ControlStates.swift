import CoreGraphics

// MARK: - ControlState

/// Interaction states matching AIRPLAY disassembly (0x004574DA - 0x0045754E).
public enum ControlState: Int, Sendable, Equatable, Hashable {
    case normal   = 0
    case hover    = 1
    case pressed  = 2
    case disabled = 3

    /// Master opacity for sprite rendering.
    public var alpha: CGFloat {
        switch self {
        case .normal:   return 0.70   // Alpha 180/255
        case .hover:    return 1.00   // Alpha 255/255
        case .pressed:  return 0.90   // Alpha 230/255
        case .disabled: return 0.35
        }
    }

    /// Brightness multiplier for hover highlight.
    public var brightness: CGFloat {
        switch self {
        case .normal:   return 1.00
        case .hover:    return 1.18
        case .pressed:  return 1.05
        case .disabled: return 0.75
        }
    }

    /// Vertical indentation in 1× logical points when pressed (+1pt down).
    public var pressedYOffset: CGFloat {
        self == .pressed ? 1.0 : 0.0
    }
}

// MARK: - RenderMode

/// User-selectable visual rendering mode.
public enum AirMuseRenderMode: String, Sendable, CaseIterable, Codable {
    /// Strict 1:1 restoration of the original AIRPLAY-zion crystal glass UI.
    case original
    /// Original AIRPLAY identity with macOS 26+ local Liquid Glass enhancements.
    case enhanced
}

// MARK: - SkinResolutionMode

/// Selects whether to sample 1× original bitmaps or 4× supersampled Retina bitmaps.
public enum SkinResolutionMode: String, Sendable, CaseIterable, Codable {
    /// Exact 1× original decoded bitmaps from AIRPLAY-zion_unpacked.exe (nearest-neighbor crispness).
    case original1x
    /// 4× supersampled Retina assets from AirMuse_Remastered.
    case retina4x
}
