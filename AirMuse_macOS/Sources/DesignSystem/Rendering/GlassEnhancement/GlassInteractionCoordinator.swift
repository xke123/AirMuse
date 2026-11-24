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
        static let trackpadGestures = "airmuse.ui.trackpadGestures"
        static let pinchModeGesture = "airmuse.ui.pinchModeGesture"
        static let modeSequenceTotalDuration = "airmuse.ui.modeSequenceTotalDuration"
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

    /// M24: Enables bounded area trackpad gestures (progress horizontal scrub, volume vertical scroll).
    public var enableTrackpadGestures: Bool {
        didSet {
            guard oldValue != enableTrackpadGestures else { return }
            UserDefaults.standard.set(enableTrackpadGestures, forKey: Keys.trackpadGestures)
        }
    }

    /// M24: Optional pinch gesture on player background to toggle Normal/Mini mode (off by default until user opts in).
    public var enablePinchToToggleMiniMode: Bool {
        didSet {
            guard oldValue != enablePinchToToggleMiniMode else { return }
            UserDefaults.standard.set(enablePinchToToggleMiniMode, forKey: Keys.pinchModeGesture)
        }
    }

    /// Total duration across the 3-step Normal <-> Mini choreography (1.0s / 1.2s / 1.5s).
    public var modeSequenceTotalDuration: TimeInterval {
        didSet {
            let clamped = min(max(modeSequenceTotalDuration, 0.3), 3.0)
            if abs(modeSequenceTotalDuration - clamped) > 0.001 {
                modeSequenceTotalDuration = clamped
                return
            }
            guard abs(oldValue - modeSequenceTotalDuration) > 0.001 else { return }
            UserDefaults.standard.set(modeSequenceTotalDuration, forKey: Keys.modeSequenceTotalDuration)
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

        if UserDefaults.standard.object(forKey: Keys.trackpadGestures) != nil {
            self.enableTrackpadGestures = UserDefaults.standard.bool(forKey: Keys.trackpadGestures)
        } else {
            self.enableTrackpadGestures = true
        }

        self.enablePinchToToggleMiniMode = UserDefaults.standard.bool(forKey: Keys.pinchModeGesture)

        let storedModeDuration = UserDefaults.standard.double(forKey: Keys.modeSequenceTotalDuration)
        self.modeSequenceTotalDuration = storedModeDuration >= 0.3 ? storedModeDuration : 1.0
    }
}
