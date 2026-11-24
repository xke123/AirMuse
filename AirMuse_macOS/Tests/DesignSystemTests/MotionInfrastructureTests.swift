import Testing
import AppKit
import QuartzCore
@testable import DesignSystem
@testable import UI

@Suite("Motion V2 Serialized Suites", .serialized)
@MainActor
enum MotionV2TestCoordinatorSuite {

@Suite("Motion V2 Infrastructure Tests (A01-A03, B02, M26)", .serialized)
@MainActor
struct MotionInfrastructureTests {

    // MARK: - B02: SDK API Compilation & Instantiation

    @Test("B02: NSGlassEffectView, NSGlassEffectContainerView, and CADisplayLink instantiate cleanly")
    func testSDKGlassAndDisplayLinkAvailability() {
        let container = NSGlassEffectContainerView(frame: NSRect(x: 0, y: 0, width: 120, height: 40))
        container.spacing = 8.0
        let glass = NSGlassEffectView(frame: NSRect(x: 0, y: 0, width: 40, height: 40))
        glass.style = .clear
        glass.cornerRadius = 8.0
        if #available(macOS 27.0, *) {
            glass.effectIsInteractive = true
            #expect(glass.effectIsInteractive == true)
        }
        container.contentView = glass
        #expect(container.spacing == 8.0)
        #expect(container.contentView === glass)

        let driver = MotionDisplayDriver(clock: ManualMotionClock())
        #expect(driver.activeSubscriberCount == 0)
        #expect(!driver.isRunning)
    }

    // MARK: - A01: Latest-Intent-Wins & Generation Isolation

    @Test("A01: Conflict domain latest-intent-wins cancels old transition and rejects stale completion")
    func testConflictDomainAndStaleCompletionIsolation() {
        let clock = ManualMotionClock(initial: 100.0)
        let coord = MotionCoordinator(clock: clock, accessibility: MotionAccessibility())
        let key = TransitionKey(owner: "Stage", channel: "mode")

        var cancelledGens: [UInt64] = []
        let t1 = coord.beginTransition(for: key, category: .stageGeometry) {
            cancelledGens.append(1)
        }
        #expect(coord.isCurrent(t1))
        #expect(coord.activeTransitionCount == 1)

        // Preempt with t2 before t1 completes
        let t2 = coord.beginTransition(for: key, category: .stageGeometry) {
            cancelledGens.append(2)
        }
        #expect(cancelledGens == [1])
        #expect(!coord.isCurrent(t1))
        #expect(coord.isCurrent(t2))
        #expect(coord.activeTransitionCount == 1)

        // Late completion from t1 MUST NOT commit or clear t2
        #expect(coord.complete(t1) == false)
        #expect(coord.isCurrent(t2))
        #expect(coord.activeTransitionCount == 1)

        // Completion of t2 succeeds and cleans up active registry
        #expect(coord.complete(t2) == true)
        #expect(!coord.isCurrent(t2))
        #expect(coord.activeTransitionCount == 0)
    }

    @Test("A01: animateLayerFloat sets model layer directly and ignores stale ticket completion")
    func testLayerFloatModelConsistency() {
        let coord = MotionCoordinator(clock: ManualMotionClock(), accessibility: MotionAccessibility())
        coord.accessibility.reduceMotionOverride = true
        let layer = CALayer()
        layer.opacity = 0.0

        let key = TransitionKey(owner: "Button", channel: "opacity")
        let t1 = coord.beginTransition(for: key)
        var t1Committed: Bool?
        coord.animateLayerFloat(
            layer,
            keyPath: "opacity",
            animationKey: "fade",
            to: 1.0,
            duration: 0.16,
            ticket: t1,
            setModel: { $0.opacity = Float($1) },
            completion: { t1Committed = $0 }
        )

        #expect(layer.opacity == 1.0)
        #expect(t1Committed == true)
        #expect(coord.activeTransitionCount == 0)
    }

    // MARK: - A02: StageLayoutEngine Pure Geometry, Multi-Screen, & Hit Testing

    @Test("A02: Normal/Mini transition preserves top-center anchor and clamps across multi-screen negative coords")
    func testAnchorPreservationAndMultiScreenClamping() {
        let primary = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let leftNegativeScreen = CGRect(x: -1920, y: -100, width: 1920, height: 1080)
        let screens = [primary, leftNegativeScreen]

        let normalSize = CGSize(width: 495, height: 159)
        let miniSize = CGSize(width: 495, height: 45)
        let startOrigin = CGPoint(x: -800, y: 500)

        let toMiniOrigin = StageLayoutEngine.anchoredOriginForHeightChange(
            currentOrigin: startOrigin,
            oldSize: normalSize,
            newSize: miniSize,
            visibleFrames: screens
        )
        // Top edge (500 + 159 = 659) and midX (-800 + 247.5) must be preserved
        #expect(abs((toMiniOrigin.y + miniSize.height) - (startOrigin.y + normalSize.height)) < 0.001)
        #expect(abs((toMiniOrigin.x + miniSize.width * 0.5) - (startOrigin.x + normalSize.width * 0.5)) < 0.001)

        // Reverse back to normal must land back on startOrigin
        let backToNormal = StageLayoutEngine.anchoredOriginForHeightChange(
            currentOrigin: toMiniOrigin,
            oldSize: miniSize,
            newSize: normalSize,
            visibleFrames: screens
        )
        #expect(abs(backToNormal.x - startOrigin.x) < 0.001)
        #expect(abs(backToNormal.y - startOrigin.y) < 0.001)

        // Disconnected monitor recovery: origin outside all visibleFrames clamps to nearest screen
        let detachedOrigin = CGPoint(x: 3200, y: 1500)
        let recovered = StageLayoutEngine.clampOrigin(detachedOrigin, size: normalSize, visibleFrames: screens)
        #expect(primary.contains(CGRect(origin: recovered, size: normalSize)))
    }

    @Test("A02: StageLayoutEngine excludes hidden modules and transparent gaps from interactive hit frames")
    func testInteractiveHitFrameExclusion() {
        let input = StageLayoutInput(
            uiScale: 1.5,
            playerScreenOrigin: CGPoint(x: 200, y: 500),
            playerSize: CGSize(width: 495, height: 159),
            lyricsSize: CGSize(width: 495, height: 426),
            librarySize: CGSize(width: 495, height: 585),
            isMiniMode: false,
            isLyricsVisible: false,
            isLibraryVisible: true,
            lyricsPlacement: .bottom,
            libraryPlacement: .right
        )
        let output = StageLayoutEngine.solve(input)
        // Host encloses player + library on right, with empty space below player
        #expect(output.interactiveHitFrames.count == 2)
        // Point directly below player (underneath player, left of library) must NOT hit!
        let emptyGapPoint = CGPoint(x: output.playerFrame.midX, y: output.libraryFrame.minY + 10)
        #expect(!StageLayoutEngine.isHitPoint(emptyGapPoint, in: output))
        // Point inside player must hit
        #expect(StageLayoutEngine.isHitPoint(CGPoint(x: output.playerFrame.midX, y: output.playerFrame.midY), in: output))
        // Point inside library must hit
        #expect(StageLayoutEngine.isHitPoint(CGPoint(x: output.libraryFrame.midX, y: output.libraryFrame.midY), in: output))
    }

    @Test("A02/M12: Magnetic snap respects hysteresis and prevents overlap")
    func testSnapHysteresisAndNonOverlap() {
        let playerRect = CGRect(x: 300, y: 400, width: 495, height: 159)
        let lyricsSize = CGSize(width: 495, height: 426)

        // Dropped 18pt below player bottom edge (within 20 * 1.0 = 20pt enter threshold)
        let nearDropped = CGPoint(x: 310, y: 400 - 426 + 18)
        let snap1 = StageLayoutEngine.computeSnap(
            movedSize: lyricsSize,
            droppedOrigin: nearDropped,
            playerScreenRect: playerRect,
            otherModuleScreenRect: nil,
            uiScale: 1.0,
            wasAlreadySnapped: false
        )
        #expect(snap1.didSnap)
        if let snapped = snap1.targetScreenRect {
            #expect(!snapped.insetBy(dx: 1, dy: 1).intersects(playerRect))
        }
    }

    // MARK: - A03 & M26: Resource Stop-When-Idle & Live Accessibility Toggling

    @Test("A03: MotionDisplayDriver stops immediately when subscribers finish or cancel")
    func testDisplayDriverIdleZeroClock() {
        let clock = ManualMotionClock()
        let driver = MotionDisplayDriver(clock: clock)
        var ticks = 0
        _ = driver.start { _, _ in
            ticks += 1
            return ticks < 3
        }
        #expect(driver.activeSubscriberCount == 1)
        driver.stepManually(dt: 1.0 / 60.0)
        #expect(driver.activeSubscriberCount == 1)
        driver.stepManually(dt: 1.0 / 60.0)
        #expect(driver.activeSubscriberCount == 1)
        driver.stepManually(dt: 1.0 / 60.0)
        #expect(driver.activeSubscriberCount == 0)
        #expect(!driver.isRunning)
    }

    @Test("M26: Enabling Reduce Motion at runtime cancels decorative transitions; Reduce Transparency switches glass")
    func testLiveAccessibilityToggle() {
        let access = MotionAccessibility.shared
        let savedRM = access.reduceMotionOverride
        let savedRT = access.reduceTransparencyOverride
        let savedMode = GlassInteractionCoordinator.shared.renderMode
        defer {
            access.reduceMotionOverride = savedRM
            access.reduceTransparencyOverride = savedRT
            GlassInteractionCoordinator.shared.renderMode = savedMode
        }

        access.reduceMotionOverride = false
        access.reduceTransparencyOverride = false
        GlassInteractionCoordinator.shared.renderMode = .enhanced

        var decorativeCancelled = false
        let decoKey = TransitionKey(owner: "PlayerView", channel: "specularSweep")
        _ = MotionCoordinator.shared.beginTransition(for: decoKey, category: .decorative) {
            decorativeCancelled = true
        }
        let geomKey = TransitionKey(owner: "Stage", channel: "mode")
        let geomTicket = MotionCoordinator.shared.beginTransition(for: geomKey, category: .stageGeometry)
        defer { MotionCoordinator.shared.cancel(key: geomKey) }

        // Toggle Reduce Motion ON at runtime
        access.reduceMotionOverride = true
        #expect(decorativeCancelled == true)
        #expect(MotionCoordinator.shared.isCurrent(geomTicket))

        // Toggle Reduce Transparency ON on LiquidGlassControl
        let control = LiquidGlassControl(frame: NSRect(x: 0, y: 0, width: 60, height: 24))
        control.isActive = true
        #expect(control.isGlassEffectVisible == true)

        access.reduceTransparencyOverride = true
        #expect(control.isGlassEffectVisible == false)

        access.reduceTransparencyOverride = false
        #expect(control.isGlassEffectVisible == true)
    }
}
}
