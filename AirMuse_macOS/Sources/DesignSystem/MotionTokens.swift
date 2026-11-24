import Foundation
import QuartzCore

// MARK: - MotionTokens

/// Centralized timing, spring, geometry, and physics tokens for AirMuse Motion V2 (M01–M26).
/// Spec values serve as calibrated baseline targets; runtime accessibility overrides apply via `MotionCoordinator`.
public enum MotionTokens {

    public enum Duration {
        /// M01: Window startup glass-bar scroll-unroll intro
        public static let scrollIntro: TimeInterval = 0.38
        /// M01: Main window glass-bar scroll collapse
        public static let scrollCollapse: TimeInterval = 0.30
        /// M02: Double-click Normal/Mini continuous crystal morph (0–320ms)
        public static let miniToggle: TimeInterval = 0.32
        /// M03/M04: Hover control area crossfade
        public static let hoverFade: TimeInterval = 0.16
        /// M05: Legacy / shared button state transition
        public static let buttonState: TimeInterval = 0.12
        /// M05: Button hover enter
        public static let buttonHover: TimeInterval = 0.12
        /// M05: Button physical press down
        public static let buttonPress: TimeInterval = 0.08
        /// M05: Button release rebound
        public static let buttonRelease: TimeInterval = 0.18
        /// M06: Play/Pause icon transition (120–180ms)
        public static let playPauseMorph: TimeInterval = 0.15
        /// M07: Focus/Unfocus glass frame cross-fade
        public static let focusCrossFade: TimeInterval = 0.22
        /// M08: Specular lens flare sweep across body
        public static let specularSweep: TimeInterval = 0.52
        /// M08: Minimum cooldown between automatic sweeps
        public static let specularCooldown: TimeInterval = 0.18
        /// M09: Progress capsule hover/scrub expand
        public static let scrubExpand: TimeInterval = 0.12
        /// M09: Progress capsule release settle
        public static let scrubRelease: TimeInterval = 0.18
        /// M10: Volume HUD enter
        public static let volumeHUDIn: TimeInterval = 0.18
        /// M10: Volume HUD inactivity linger before dismiss
        public static let volumeHUDHold: TimeInterval = 0.90
        /// M10: Volume HUD exit
        public static let volumeHUDOut: TimeInterval = 0.20
        /// M12: Magnetic dock snap settle (180–240ms)
        public static let dockSnap: TimeInterval = 0.21
        /// M13: Library scroll-unroll expand/collapse
        public static let libraryReveal: TimeInterval = 0.36
        /// M14: Lyrics module expand/collapse (320–360ms)
        public static let lyricsResize: TimeInterval = 0.34
        /// M15: Mini mode track info vertical slide
        public static let miniTextSlide: TimeInterval = 0.32
        /// M15: Mini mode marquee scroll timer interval
        public static let marqueeTick: TimeInterval = 0.05
        /// M16: Album artwork crossfade
        public static let artworkCrossfade: TimeInterval = 0.26
        /// M17: Ambient artwork glow transition
        public static let ambientGlow: TimeInterval = 0.48
        /// M18: Lyrics active-line scroll transition
        public static let lyricLineScroll: TimeInterval = 0.32
        /// M19: Glass popover/menu reveal (180–300ms)
        public static let popoverReveal: TimeInterval = 0.22
        /// M20: Tooltip hover dwell delay
        public static let tooltipDelay: TimeInterval = 0.40
        /// M20: Tooltip enter fade
        public static let tooltipIn: TimeInterval = 0.12
        /// M21: Music card hover reveal
        public static let cardHover: TimeInterval = 0.12
        /// M21: Music card selection feedback
        public static let cardSelect: TimeInterval = 0.18
        /// M22: Search bar focus transition
        public static let searchFocus: TimeInterval = 0.18
        /// M22: Category content crossfade
        public static let categoryCrossfade: TimeInterval = 0.18
    }

    public enum Geometry {
        /// M03: Max vertical micro-displacement for hover reveal (pt)
        public static let hoverDisplacementPt: CGFloat = 3.0
        /// M05: Button hover scale factor (1.04–1.07)
        public static let buttonHoverScale: CGFloat = 1.05
        /// M05: Button press scale factor (0.92–0.96)
        public static let buttonPressScale: CGFloat = 0.94
        /// M05: Button press physical vertical sink at 1x (pt)
        public static let buttonPressSinkPt: CGFloat = 1.0
        /// M16: Max subtle artwork transition scale
        public static let artworkTransitionScale: CGFloat = 1.02
    }

    public enum Springs {
        public static let windowResize = SpringConfig(stiffness: 280.0, damping: 24.0)
        public static let panelHover   = SpringConfig(stiffness: 300.0, damping: 26.0)
        public static let buttonPress  = SpringConfig(stiffness: 340.0, damping: 26.0)
        public static let focusFade    = SpringConfig(stiffness: 160.0, damping: 24.0)
        public static let textSlide    = SpringConfig(stiffness: 260.0, damping: 34.0)
        public static let dockSnap     = SpringConfig(stiffness: 320.0, damping: 28.0)
        public static let lyricsScroll = SpringConfig(stiffness: 240.0, damping: 30.0)
        public static let scrubRelease = SpringConfig(stiffness: 360.0, damping: 28.0)
    }

    public enum Thresholds {
        /// M08: Vertical cursor velocity (DIP/s) above which mid-line sweep is suppressed
        public static let fastMoveVelocity: CGFloat = 400.0
        /// M08: Minimum gap before boundary sweep lock resets
        public static let boundaryResetMargin: CGFloat = 10.0
        /// M08: Maximum concurrent specular sweep layers
        public static let maxActiveSweeps: Int = 2
        /// M02: Debounce window for rapid double-clicks
        public static let doubleClickDebounce: TimeInterval = 0.18
        /// M12: Snap engagement distance at 1x (16–24pt)
        public static let snapEnterDistance: CGFloat = 20.0
        /// M12: Additional hysteresis distance required to break an active snap (+6pt)
        public static let snapExitHysteresis: CGFloat = 6.0
        /// M15: Marquee scroll velocity (pt/s at 1x)
        public static let marqueeSpeedPtPerSec: CGFloat = 20.0
        /// M15: Marquee loop gap (pt at 1x)
        public static let marqueeGapPt: CGFloat = 30.0
    }
}
