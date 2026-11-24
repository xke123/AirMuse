import AppKit
import QuartzCore
import Foundation
import OSLog

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

/// Physics-based spring value simulation with substepped stability for custom rendering loops.
public struct SpringValue: Sendable, Equatable {
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

    /// Advances the spring by dtSeconds using bounded substeps (max 1/120s per substep).
    /// Returns true if still in motion.
    @discardableResult
    public mutating func step(dtSeconds: Float) -> Bool {
        let totalDt = min(max(dtSeconds, 0), 0.05)
        let displacement = current - target
        if abs(displacement) < 0.002 && abs(velocity) < 0.002 {
            current = target
            velocity = 0.0
            return false
        }
        let maxSubDt: Float = 1.0 / 120.0
        let substeps = max(1, Int(ceil(totalDt / maxSubDt)))
        let subDt = totalDt / Float(substeps)
        for _ in 0..<substeps {
            let disp = current - target
            let force = -config.stiffness * disp - config.damping * velocity
            velocity += force * subDt
            current += velocity * subDt
        }
        if abs(current - target) < 0.002 && abs(velocity) < 0.002 {
            current = target
            velocity = 0.0
            return false
        }
        return true
    }
}

// MARK: - MotionClock

public protocol MotionClock: Sendable {
    var now: TimeInterval { get }
}

public struct SystemUptimeMotionClock: MotionClock {
    public init() {}
    public var now: TimeInterval {
        ProcessInfo.processInfo.systemUptime
    }
}

/// Deterministic manual clock for unit and interruption testing.
public final class ManualMotionClock: MotionClock, @unchecked Sendable {
    private let lock = NSLock()
    private var currentTime: TimeInterval

    public init(initial: TimeInterval = 0) {
        self.currentTime = initial
    }

    public var now: TimeInterval {
        lock.withLock { currentTime }
    }

    public func advance(by seconds: TimeInterval) {
        lock.withLock {
            currentTime += max(0, seconds)
        }
    }

    public func set(_ time: TimeInterval) {
        lock.withLock {
            currentTime = time
        }
    }
}

// MARK: - Transition Contracts

public struct TransitionKey: Hashable, Sendable {
    public let owner: String
    public let channel: String

    public init(owner: String, channel: String) {
        self.owner = owner
        self.channel = channel
    }
}

public struct MotionTicket: Equatable, Hashable, Sendable {
    public let key: TransitionKey
    public let generation: UInt64

    public init(key: TransitionKey, generation: UInt64) {
        self.key = key
        self.generation = generation
    }
}

public enum TransitionCategory: Sendable, Equatable {
    case stageGeometry
    case controlInteraction
    case content
    case decorative
}

// MARK: - MotionAccessibility

/// Centralizes Reduce Motion & Reduce Transparency state with live runtime change notifications
/// and deterministic test overrides (M26).
@MainActor
public final class MotionAccessibility {

    public static let shared = MotionAccessibility()
    public static let preferencesDidChangeNotification = Notification.Name("AirMuseMotionAccessibilityDidChange")

    /// Optional overrides for deterministic automated testing (nil = read system NSWorkspace).
    public var reduceMotionOverride: Bool? {
        didSet {
            guard oldValue != reduceMotionOverride else { return }
            notifyObservers()
        }
    }

    public var reduceTransparencyOverride: Bool? {
        didSet {
            guard oldValue != reduceTransparencyOverride else { return }
            notifyObservers()
        }
    }

    public var isReduceMotionEnabled: Bool {
        reduceMotionOverride ?? NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    public var isReduceTransparencyEnabled: Bool {
        reduceTransparencyOverride ?? NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
    }

    private var workspaceObserver: NSObjectProtocol?

    public init() {
        workspaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.notifyObservers()
            }
        }
    }

    isolated deinit {
        if let observer = workspaceObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
    }

    private func notifyObservers() {
        if isReduceMotionEnabled {
            MotionCoordinator.shared.cancelDecorativeTransitions()
        }
        NotificationCenter.default.post(name: Self.preferencesDidChangeNotification, object: self)
    }
}

// MARK: - MotionDisplayDriver

/// On-demand VSync display driver backed by AppKit's `CADisplayLink` when attached to a view/window,
/// falling back cleanly when running headless. Guarantees zero active clocks when idle.
@MainActor
public final class MotionDisplayDriver: NSObject {

    public typealias TickHandler = @MainActor (_ dt: TimeInterval, _ now: TimeInterval) -> Bool

    private final class Subscription {
        let id: UUID
        let label: String
        let handler: TickHandler

        init(id: UUID, label: String, handler: @escaping TickHandler) {
            self.id = id
            self.label = label
            self.handler = handler
        }
    }

    private var subscriptions: [UUID: Subscription] = [:]
    private var orderedIDs: [UUID] = []
    private var displayLink: CADisplayLink?
    private weak var hostView: NSView?
    private var fallbackTimer: Timer?
    private var lastTickTime: TimeInterval = 0
    private let clock: any MotionClock

    public var activeSubscriberCount: Int { subscriptions.count }
    public var activeSubscriberLabels: [String] { orderedIDs.compactMap { subscriptions[$0]?.label } }
    public var isRunning: Bool { displayLink != nil || fallbackTimer != nil }

    public init(clock: any MotionClock = SystemUptimeMotionClock()) {
        self.clock = clock
        super.init()
    }

    isolated deinit {
        displayLink?.invalidate()
        fallbackTimer?.invalidate()
    }

    public func attach(to view: NSView?) {
        hostView = view
        if isRunning {
            stopDriver()
            if !subscriptions.isEmpty {
                startDriverIfNeeded()
            }
        }
    }

    @discardableResult
    public func start(file: String = #fileID, line: Int = #line, handler: @escaping TickHandler) -> UUID {
        let id = UUID()
        subscriptions[id] = Subscription(id: id, label: "\(file):\(line)", handler: handler)
        orderedIDs.append(id)
        startDriverIfNeeded()
        return id
    }

    public func stop(id: UUID) {
        subscriptions.removeValue(forKey: id)
        orderedIDs.removeAll { $0 == id }
        if subscriptions.isEmpty {
            stopDriver()
        }
    }

    public func stopAll() {
        subscriptions.removeAll()
        orderedIDs.removeAll()
        stopDriver()
    }

    /// Deterministically advances all active subscribers (primarily for headless/unit tests).
    public func stepManually(dt: TimeInterval) {
        let now = clock.now
        dispatchTick(dt: dt, now: now)
    }

    private func startDriverIfNeeded() {
        guard displayLink == nil, fallbackTimer == nil, !subscriptions.isEmpty else { return }
        lastTickTime = clock.now

        if let view = hostView, view.window != nil {
            let link = view.displayLink(target: self, selector: #selector(handleDisplayLink(_:)))
            link.add(to: .main, forMode: .common)
            displayLink = link
        } else if let mainScreen = NSScreen.main {
            let link = mainScreen.displayLink(target: self, selector: #selector(handleDisplayLink(_:)))
            link.add(to: .main, forMode: .common)
            displayLink = link
        } else {
            let timer = Timer(timeInterval: 1.0 / 60.0, target: self, selector: #selector(handleFallbackTimer), userInfo: nil, repeats: true)
            RunLoop.main.add(timer, forMode: .common)
            fallbackTimer = timer
        }
    }

    private func stopDriver() {
        displayLink?.invalidate()
        displayLink = nil
        fallbackTimer?.invalidate()
        fallbackTimer = nil
    }

    @objc private func handleDisplayLink(_ link: CADisplayLink) {
        let now = clock.now
        let rawDt = lastTickTime > 0 ? (now - lastTickTime) : (link.targetTimestamp - link.timestamp)
        lastTickTime = now
        // Realign clock cleanly after sleep/wake or long stall (> 250ms)
        let clampedDt = rawDt > 0.25 ? (1.0 / 60.0) : min(max(rawDt, 0.001), 0.05)
        dispatchTick(dt: clampedDt, now: now)
    }

    @objc private func handleFallbackTimer() {
        let now = clock.now
        let rawDt = lastTickTime > 0 ? (now - lastTickTime) : (1.0 / 60.0)
        lastTickTime = now
        let clampedDt = rawDt > 0.25 ? (1.0 / 60.0) : min(max(rawDt, 0.001), 0.05)
        dispatchTick(dt: clampedDt, now: now)
    }

    private func dispatchTick(dt: TimeInterval, now: TimeInterval) {
        let ids = orderedIDs
        for id in ids {
            guard let sub = subscriptions[id] else { continue }
            let keepAlive = sub.handler(dt, now)
            if !keepAlive {
                subscriptions.removeValue(forKey: id)
                orderedIDs.removeAll { $0 == id }
            }
        }
        if subscriptions.isEmpty {
            stopDriver()
        }
    }
}

// MARK: - MotionCoordinator

/// Authoritative MainActor transition scheduler for AirMuse Motion V2.
/// Guarantees latest-intent-wins conflict domains, generation-isolated completions,
/// presentation-aware retargeting, zero persistent fillMode hacks, and live accessibility compliance.
@MainActor
public final class MotionCoordinator {

    public static let shared = MotionCoordinator()

    private struct ActiveTransition {
        let ticket: MotionTicket
        let category: TransitionCategory
        let onCancel: (() -> Void)?
    }

    public var clock: any MotionClock
    public let accessibility: MotionAccessibility
    public let displayDriver: MotionDisplayDriver

    private var generations: [TransitionKey: UInt64] = [:]
    private var activeTransitions: [TransitionKey: ActiveTransition] = [:]
    private let signposter = OSSignposter(subsystem: "com.airmuse.macos", category: "MotionV2")

    public var isReduceMotionEnabled: Bool {
        accessibility.isReduceMotionEnabled
    }

    public var isReduceTransparencyEnabled: Bool {
        accessibility.isReduceTransparencyEnabled
    }

    public var activeTransitionCount: Int {
        activeTransitions.count
    }

    public init(
        clock: any MotionClock = SystemUptimeMotionClock(),
        accessibility: MotionAccessibility = .shared
    ) {
        self.clock = clock
        self.accessibility = accessibility
        self.displayDriver = MotionDisplayDriver(clock: clock)
    }

    // MARK: - Conflict Domain & Generation Management

    /// Starts a transition in `key`'s conflict domain.
    /// Cancels any active transition in the same domain first so latest intent always wins.
    @discardableResult
    public func beginTransition(
        for key: TransitionKey,
        category: TransitionCategory = .controlInteraction,
        onCancel: (() -> Void)? = nil
    ) -> MotionTicket {
        if let existing = activeTransitions.removeValue(forKey: key) {
            signposter.emitEvent("TransitionRetarget")
            existing.onCancel?()
        } else {
            signposter.emitEvent("TransitionBegin")
        }
        let nextGen = (generations[key] ?? 0) &+ 1
        generations[key] = nextGen
        let ticket = MotionTicket(key: key, generation: nextGen)
        activeTransitions[key] = ActiveTransition(ticket: ticket, category: category, onCancel: onCancel)
        return ticket
    }

    /// Returns true if any transition is currently active for `key`.
    public func hasActiveTransition(for key: TransitionKey) -> Bool {
        activeTransitions[key] != nil
    }

    /// Returns true only if `ticket` is still the latest active generation for its key.
    public func isCurrent(_ ticket: MotionTicket) -> Bool {
        activeTransitions[ticket.key]?.ticket.generation == ticket.generation
    }

    /// Marks `ticket` completed if and only if its generation matches the active transition.
    /// Returns true if the caller may commit final state; false if stale/cancelled.
    @discardableResult
    public func complete(_ ticket: MotionTicket) -> Bool {
        guard let active = activeTransitions[ticket.key],
              active.ticket.generation == ticket.generation else {
            return false
        }
        activeTransitions.removeValue(forKey: ticket.key)
        signposter.emitEvent("TransitionEnd")
        return true
    }

    /// Cancels the active transition for `key` (if any) and invalidates any in-flight completion callbacks.
    public func cancel(key: TransitionKey) {
        generations[key] = (generations[key] ?? 0) &+ 1
        if let existing = activeTransitions.removeValue(forKey: key) {
            signposter.emitEvent("TransitionCancel")
            existing.onCancel?()
        }
    }

    /// Cancels all active transitions owned by `owner`.
    public func cancelAll(owner: String) {
        let matchingKeys = Set(activeTransitions.keys.filter { $0.owner == owner } + generations.keys.filter { $0.owner == owner })
        for key in matchingKeys {
            cancel(key: key)
        }
    }

    /// Cancels all decorative transitions (e.g. when Reduce Motion turns on or window hides).
    public func cancelDecorativeTransitions() {
        let decoKeys = activeTransitions.compactMap { (key, entry) in
            entry.category == .decorative ? key : nil
        }
        for key in decoKeys {
            cancel(key: key)
        }
    }

    /// Cancels every active transition (used on teardown or hard reset).
    public func cancelAllTransitions() {
        for key in Array(activeTransitions.keys) {
            cancel(key: key)
        }
    }

    // MARK: - Core Animation Helpers (Model-First, Presentation-Sampled, Generation-Guarded)

    /// Creates a `CASpringAnimation` tuned to the specified preset.
    /// Model layer should be updated to `toValue` before adding so `isRemovedOnCompletion = true` leaves clean state.
    public func makeSpringAnimation(
        keyPath: String,
        from fromValue: Any?,
        to toValue: Any?,
        preset: SpringConfig = .smooth,
        initialVelocity: CGFloat = 0.0
    ) -> CASpringAnimation {
        let anim = CASpringAnimation(keyPath: keyPath)
        anim.fromValue = fromValue
        anim.toValue = toValue
        anim.stiffness = CGFloat(preset.stiffness)
        anim.damping = CGFloat(preset.damping)
        anim.mass = 1.0
        anim.initialVelocity = initialVelocity

        if isReduceMotionEnabled {
            anim.duration = 0.01
        } else {
            anim.duration = anim.settlingDuration
        }
        anim.isRemovedOnCompletion = true
        return anim
    }

    /// Animates a CALayer scalar CGFloat property from its current presentation value (if any) to `target`,
    /// setting the model layer immediately and guarding completion with `MotionTicket`.
    @discardableResult
    public func animateLayerFloat(
        _ layer: CALayer,
        keyPath: String,
        animationKey: String,
        to target: CGFloat,
        duration: TimeInterval,
        timingFunction: CAMediaTimingFunctionName = .easeOut,
        ticket: MotionTicket,
        setModel: (CALayer, CGFloat) -> Void,
        completion: (@MainActor (Bool) -> Void)? = nil
    ) -> Bool {
        let currentPresented: CGFloat? = (layer.presentation()?.value(forKeyPath: keyPath) as? NSNumber).map { CGFloat($0.doubleValue) }
        let startVal = currentPresented ?? (layer.value(forKeyPath: keyPath) as? NSNumber).map { CGFloat($0.doubleValue) } ?? target

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.removeAnimation(forKey: animationKey)
        setModel(layer, target)
        CATransaction.commit()

        if isReduceMotionEnabled || duration <= 0.005 || abs(startVal - target) < 0.0001 {
            let committed = complete(ticket)
            completion?(committed)
            return committed
        }

        CATransaction.begin()
        let anim = CABasicAnimation(keyPath: keyPath)
        anim.fromValue = startVal
        anim.toValue = target
        anim.duration = duration
        anim.timingFunction = CAMediaTimingFunction(name: timingFunction)
        anim.isRemovedOnCompletion = true
        CATransaction.setCompletionBlock { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                let committed = self.complete(ticket)
                completion?(committed)
            }
        }
        layer.add(anim, forKey: animationKey)
        CATransaction.commit()
        return true
    }

    /// Performs an AppKit NSAnimationContext group with Reduce Motion awareness and generation-guarded completion.
    public func animate(
        duration: TimeInterval = 0.35,
        timingFunction: CAMediaTimingFunctionName = .easeInEaseOut,
        ticket: MotionTicket? = nil,
        action: @escaping () -> Void,
        completion: (@MainActor (Bool) -> Void)? = nil
    ) {
        let resolvedDuration = isReduceMotionEnabled ? 0.0 : max(0, duration)
        if resolvedDuration <= 0.001 {
            NSAnimationContext.beginGrouping()
            NSAnimationContext.current.duration = 0
            NSAnimationContext.current.allowsImplicitAnimation = false
            action()
            NSAnimationContext.endGrouping()
            if let ticket {
                let committed = complete(ticket)
                completion?(committed)
            } else {
                completion?(true)
            }
            return
        }

        NSAnimationContext.runAnimationGroup({ context in
            context.duration = resolvedDuration
            context.allowsImplicitAnimation = true
            context.timingFunction = CAMediaTimingFunction(name: timingFunction)
            action()
        }, completionHandler: { [weak self] in
            Task { @MainActor in
                if let ticket {
                    let committed = self?.complete(ticket) ?? false
                    completion?(committed)
                } else {
                    completion?(true)
                }
            }
        })
    }

    /// Legacy compatibility overload preserving existing call signature.
    public func animate(
        duration: TimeInterval = 0.35,
        timingFunction: CAMediaTimingFunctionName = .easeInEaseOut,
        action: @escaping () -> Void,
        completion: (@Sendable () -> Void)? = nil
    ) {
        animate(duration: duration, timingFunction: timingFunction, ticket: nil, action: action) { _ in
            completion?()
        }
    }
}
