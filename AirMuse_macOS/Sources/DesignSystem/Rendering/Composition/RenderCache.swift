import CoreGraphics
import Foundation

// MARK: - RenderCache

/// Caches static rendered glass frame CGImages keyed by geometry, scale, focus, and artwork key
/// so static windows never re-render 9-slice glass every frame.
@MainActor
public final class RenderCache {

    public static let shared = RenderCache()

    public struct Key: Hashable {
        public let widthPx: Int
        public let heightPx: Int
        public let scaleQ: Int
        public let resolution: SkinResolutionMode
        public let focusQ: Int
        public let hasMainGloss: Bool
        public let frostedBars: Bool
        public let artworkKey: String

        public init(
            width: CGFloat,
            height: CGFloat,
            uiScale: CGFloat,
            backingScale: CGFloat,
            resolution: SkinResolutionMode,
            focusRatio: CGFloat,
            hasMainGloss: Bool,
            frostedBars: Bool = false,
            artworkKey: String
        ) {
            self.widthPx = Int(round(width * backingScale))
            self.heightPx = Int(round(height * backingScale))
            self.scaleQ = Int(round(uiScale * 100))
            self.resolution = resolution
            self.focusQ = Int(round(min(max(focusRatio, 0), 1) * 100))
            self.hasMainGloss = hasMainGloss
            self.frostedBars = frostedBars
            self.artworkKey = artworkKey
        }
    }

    private var cache: [Key: CGImage] = [:]
    private var lruOrder: [Key] = []
    private let maxEntries: Int = 24

    public init() {}

    public func image(for key: Key) -> CGImage? {
        if let hit = cache[key] {
            if let idx = lruOrder.firstIndex(of: key) {
                lruOrder.remove(at: idx)
                lruOrder.append(key)
            }
            return hit
        }
        return nil
    }

    public func store(_ image: CGImage, for key: Key) {
        if cache[key] == nil {
            if lruOrder.count >= maxEntries, let oldest = lruOrder.first {
                lruOrder.removeFirst()
                cache.removeValue(forKey: oldest)
            }
            lruOrder.append(key)
        }
        cache[key] = image
    }

    public func invalidateAll() {
        cache.removeAll()
        lruOrder.removeAll()
    }
}
