import AppKit
import QuartzCore
import Foundation

// MARK: - SpringConfig

/// Physical spring-damping configuration matching Windows SpringAnimator.hpp.
public struct SpringConfig: Sendable, Equatable {
    public var stiffness: Float
    public var damping: Float

    public init(stiffness: Float, damping: Float) {
        self.stiffness = stiffness
        self.damping = damping
    }

    // Presets directly corresponding to Windows MotionPreset
    /// Quick feedback: button hover, press down, toggle (high responsiveness, light rebound)
    public static let snappy = SpringConfig(stiffness: 340.0, damping: 26.0)
    /// Bouncy: popups, card scale, badge bounce
    public static let bouncy = SpringConfig(stiffness: 220.0, damping: 18.0)
    /// Smooth: marquee text, lyrics scroll, slider follow (critical damping)
    public static let smooth = SpringConfig(stiffness: 260.0, damping: 32.0)
    /// Gentle: focus switch, ambient glow breathing, fade transitions
    public static let gentle = SpringConfig(stiffness: 160.0, damping: 24.0)
}

// MARK: - SpringValue

/// Physics-based spring value simulation for custom rendering loops.
public struct SpringValue: Sendable {
    public var current: Float = 0.0
    public var target: Float = 0.0
    public var velocity: Float = 0.0
    public var config: SpringConfig

    public init(initial: Float = 0.0, config: SpringConfig = .smooth) {
        self.current = initial
        self.target = initial
        self.velocity = 0.0
        self.config = config
    }

    public mutating func setTarget(_ value: Float) {
        target = value
    }

    public mutating func snapTo(_ value: Float) {
        current = value
        target = value
        velocity = 0.0
    }

    public var isSettled: Bool {
        abs(current - target) < 0.002 && abs(velocity) < 0.002
    }

    /// Advances the spring by dtSeconds (clamped to 0.05s). Returns true if still in motion.
    @discardableResult
    public mutating func step(dtSeconds: Float) -> Bool {
        let dt = min(dtSeconds, 0.05)
        let displacement = current - target
        if abs(displacement) < 0.002 && abs(velocity) < 0.002 {
            current = target
            velocity = 0.0
            return false
        }
        let force = -config.stiffness * displacement - config.damping * velocity
        velocity += force * dt
        current  += velocity * dt
        return true
    }
}

// MARK: - MotionCoordinator

/// Coordinates UI animations across windows, providing CoreAnimation spring helpers
/// and respecting system accessibility settings.
@MainActor
public final class MotionCoordinator {

    public static let shared = MotionCoordinator()

    public var isReduceMotionEnabled: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    public init() {}

    /// Creates a CASpringAnimation tuned to the specified preset.
    public func makeSpringAnimation(
        keyPath: String,
        from fromValue: Any?,
        to toValue: Any?,
        preset: SpringConfig = .smooth
    ) -> CASpringAnimation {
        let anim = CASpringAnimation(keyPath: keyPath)
        anim.fromValue = fromValue
        anim.toValue = toValue
        anim.stiffness = CGFloat(preset.stiffness)
        anim.damping = CGFloat(preset.damping)
        anim.mass = 1.0
        anim.initialVelocity = 0.0

        if isReduceMotionEnabled {
            anim.duration = 0.01
        } else {
            anim.duration = anim.settlingDuration
        }
        anim.fillMode = .forwards
        anim.isRemovedOnCompletion = false
        return anim
    }

    /// Performs an animated block with NSAnimationContext using spring or smooth ease.
    public func animate(
        duration: TimeInterval = 0.35,
        timingFunction: CAMediaTimingFunctionName = .easeInEaseOut,
        action: @escaping () -> Void,
        completion: (@Sendable () -> Void)? = nil
    ) {
        let handler: (@Sendable () -> Void)?
        if let completion {
            handler = { @Sendable in
                _ = Task { @MainActor in
                    completion()
                }
            }
        } else {
            handler = nil
        }

        if isReduceMotionEnabled {
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.01
                action()
            }, completionHandler: handler)
        } else {
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = duration
                context.timingFunction = CAMediaTimingFunction(name: timingFunction)
                action()
            }, completionHandler: handler)
        }
    }
}
