import AppKit
import Foundation

// MARK: - GlassInteractionCoordinator

/// Coordinates global rendering preferences (`Original` vs `Enhanced`, `1×` vs `Retina 4×`, `uiScale`, frosted normal bars)
/// and notifies subscribed views when the user switches modes.
@MainActor
public final class GlassInteractionCoordinator {

    public static let shared = GlassInteractionCoordinator()

    public static let modeDidChangeNotification = Notification.Name("AirMuseRenderModeDidChange")

    private enum Keys {
        static let renderMode = "airmuse.ui.renderMode"
        static let resolutionMode = "airmuse.ui.resolutionMode"
        static let uiScale = "airmuse.ui.scale"
        static let frostedNormalBars = "airmuse.ui.frostedNormalBars"
    }

    public var renderMode: AirMuseRenderMode {
        didSet {
            guard oldValue != renderMode else { return }
            UserDefaults.standard.set(renderMode.rawValue, forKey: Keys.renderMode)
            NotificationCenter.default.post(name: Self.modeDidChangeNotification, object: self)
        }
    }

    public var resolutionMode: SkinResolutionMode {
        didSet {
            guard oldValue != resolutionMode else { return }
            UserDefaults.standard.set(resolutionMode.rawValue, forKey: Keys.resolutionMode)
            RenderCache.shared.invalidateAll()
            NotificationCenter.default.post(name: Self.modeDidChangeNotification, object: self)
        }
    }

    public var uiScale: CGFloat {
        didSet {
            let clamped = min(max(uiScale, 1.0), 2.0)
            if abs(uiScale - clamped) > 0.001 {
                uiScale = clamped
                return
            }
            guard abs(oldValue - uiScale) > 0.001 else { return }
            UserDefaults.standard.set(Double(uiScale), forKey: Keys.uiScale)
            RenderCache.shared.invalidateAll()
            NotificationCenter.default.post(name: Self.modeDidChangeNotification, object: self)
        }
    }

    public var useFrostedBarsInNormalMode: Bool {
        didSet {
            guard oldValue != useFrostedBarsInNormalMode else { return }
            UserDefaults.standard.set(useFrostedBarsInNormalMode, forKey: Keys.frostedNormalBars)
            RenderCache.shared.invalidateAll()
            NotificationCenter.default.post(name: Self.modeDidChangeNotification, object: self)
        }
    }

    public var isEnhancedMode: Bool {
        renderMode == .enhanced
    }

    public init() {
        if let raw = UserDefaults.standard.string(forKey: Keys.renderMode),
           let mode = AirMuseRenderMode(rawValue: raw) {
            self.renderMode = mode
        } else {
            self.renderMode = .enhanced
        }

        if let rawRes = UserDefaults.standard.string(forKey: Keys.resolutionMode),
           let res = SkinResolutionMode(rawValue: rawRes) {
            self.resolutionMode = res
        } else {
            self.resolutionMode = .retina4x
        }

        let storedScale = UserDefaults.standard.double(forKey: Keys.uiScale)
        self.uiScale = storedScale >= 1.0 ? CGFloat(storedScale) : OriginalDesignTokens.Scale.macDefault

        if UserDefaults.standard.object(forKey: Keys.frostedNormalBars) != nil {
            self.useFrostedBarsInNormalMode = UserDefaults.standard.bool(forKey: Keys.frostedNormalBars)
        } else {
            self.useFrostedBarsInNormalMode = true
        }
    }
}
