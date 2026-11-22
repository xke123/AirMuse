import Foundation
import QuartzCore

// MARK: - MotionTokens

/// Centralized timing, spring, and physics tokens for AirPlay restoration animations.
public enum MotionTokens {

    public enum Duration {
        /// Double-click mini/normal transition
        public static let miniToggle: TimeInterval = 0.28
        /// Hover control fade in/out
        public static let hoverFade: TimeInterval = 0.16
        /// Button state transition (Normal / Hover / Pressed)
        public static let buttonState: TimeInterval = 0.12
        /// Focus/Unfocus glass cross-fade
        public static let focusCrossFade: TimeInterval = 0.22
        /// Specular lens flare sweep across body
        public static let specularSweep: TimeInterval = 0.52
        /// Mini mode track info vertical slide
        public static let miniTextSlide: TimeInterval = 0.32
        /// Mini mode marquee scroll timer interval
        public static let marqueeTick: TimeInterval = 0.05
        /// Window startup scroll-unroll intro
        public static let scrollIntro: TimeInterval = 0.85
    }

    public enum Springs {
        public static let windowResize = SpringConfig(stiffness: 280.0, damping: 24.0)
        public static let panelHover   = SpringConfig(stiffness: 300.0, damping: 26.0)
        public static let buttonPress  = SpringConfig(stiffness: 340.0, damping: 26.0)
        public static let focusFade    = SpringConfig(stiffness: 160.0, damping: 24.0)
        public static let textSlide    = SpringConfig(stiffness: 260.0, damping: 34.0)
    }

    public enum Thresholds {
        /// Vertical cursor velocity (DIP/s) above which mid-line sweep is suppressed
        public static let fastMoveVelocity: CGFloat = 400.0
        /// Minimum gap before boundary sweep lock resets
        public static let boundaryResetMargin: CGFloat = 10.0
        /// Debounce window for rapid double-clicks
        public static let doubleClickDebounce: TimeInterval = 0.18
    }
}
