import Testing
import AppKit
import QuartzCore
@testable import DesignSystem
@testable import UI
@testable import Domain
@testable import Playback
@testable import Providers

extension MotionV2TestCoordinatorSuite {

@Suite("Motion V2 Stage & Window Tests (M01, M02, M07, M08, M11, M13, M14, M25)", .serialized)
@MainActor
struct MotionStageTests {

    private struct StubEngine: PlaybackEngineProtocol {
        var engineInstanceID: UUID { UUID(uuidString: "11111111-1111-1111-1111-111111111111")! }
        func events() async -> AsyncStream<EngineEvent> { AsyncStream { $0.finish() } }
        func prepare(sessionContext: SessionContext, deadlineSeconds: TimeInterval) async throws {}
        func execute(_ command: EngineCommand, context: PlaybackOperationContext) async throws {}
        func isolateAndReset() async {}
    }

    private func makeStage() -> (UnifiedStageController, PlayerWindowController, LyricsModuleView, LibraryWindowController, WebRuntime) {
        let store = PlaybackStore()
        let coord = PlaybackCoordinatorV2(store: store, engine: StubEngine())
        let playerCtrl = PlayerWindowController(coordinator: coord, store: store)
        let lyricsView = LyricsModuleView(frame: .zero)
        let libCtrl = LibraryWindowController(coordinator: coord, registry: nil)
        let webRuntime = WebRuntime()
        webRuntime.attach(to: playerCtrl.playerSlotView)
        let stage = UnifiedStageController(playerCtrl: playerCtrl, lyricsView: lyricsView, libraryCtrl: libCtrl)
        return (stage, playerCtrl, lyricsView, libCtrl, webRuntime)
    }

    @Test("M01: Startup scroll-unroll is non-blocking and cancels immediately on first mouseDown")
    func testScrollIntroNonBlockingAndCancelsOnClick() {
        let savedRM = MotionAccessibility.shared.reduceMotionOverride
        defer { MotionAccessibility.shared.reduceMotionOverride = savedRM }
        MotionAccessibility.shared.reduceMotionOverride = false

        let player = PlayerView(frame: NSRect(x: 0, y: 0, width: 495, height: 159))
        player.layoutSubtreeIfNeeded()
        player.playScrollIntro()
        #expect(player.isScrollIntroActive == true)

        // Advance partially
        MotionCoordinator.shared.displayDriver.stepManually(dt: 0.15)
        #expect(player.isScrollIntroActive == true)

        // First click cancels decorative intro immediately without blocking
        if let clickEvent = NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: NSPoint(x: 100, y: 80),
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1.0
        ) {
            player.mouseDown(with: clickEvent)
        }
        #expect(player.isScrollIntroActive == false)
        #expect(player.layer?.mask == nil)
        #expect(MotionCoordinator.shared.displayDriver.activeSubscriberCount == 0)
    }

    @Test("M02: 10 rapid Normal/Mini reversals settle cleanly with identical WebRuntime instance")
    func testRapidMiniModeReversalsAndWebKitPreservation() {
        let savedRM = MotionAccessibility.shared.reduceMotionOverride
        let savedMode = GlassInteractionCoordinator.shared.renderMode
        defer {
            MotionAccessibility.shared.reduceMotionOverride = savedRM
            GlassInteractionCoordinator.shared.renderMode = savedMode
            MotionCoordinator.shared.displayDriver.stopAll()
        }

        for mode in [AirMuseRenderMode.original, AirMuseRenderMode.enhanced] {
            MotionAccessibility.shared.reduceMotionOverride = false
            GlassInteractionCoordinator.shared.renderMode = mode

            let (stage, playerCtrl, _, _, webRuntime) = makeStage()
            let initialWebView = webRuntime.webView
            let initialEngineID = webRuntime.engineInstanceID
            #expect(initialWebView != nil)

            // 10 rapid toggles mid-flight
            for step in 0..<10 {
                playerCtrl.toggleMiniMode()
                #expect(playerCtrl.isMiniMode == (step % 2 == 0))
                MotionCoordinator.shared.displayDriver.stepManually(dt: 0.08)
            }

            // Step to completion
            for _ in 0..<30 {
                MotionCoordinator.shared.displayDriver.stepManually(dt: 0.02)
            }

            #expect(!stage.isStageTransitioning)
            #expect(playerCtrl.isMiniMode == false)
            #expect(playerCtrl.playerView.isHidden == false)
            #expect(playerCtrl.miniPlayerView.isHidden == true)
            #expect(abs(playerCtrl.playerSlotView.frame.height - playerCtrl.preferredPlayerSize(for: GlassInteractionCoordinator.shared.uiScale).height) < 0.5)
            #expect(webRuntime.webView === initialWebView)
            #expect(webRuntime.engineInstanceID == initialEngineID)
        }
    }

    @Test("M07: Focus crossfade leaves zero residual highlight when unfocused")
    func testFocusCrossfadeAndZeroResidualHighlight() {
        let savedRM = MotionAccessibility.shared.reduceMotionOverride
        defer { MotionAccessibility.shared.reduceMotionOverride = savedRM }
        MotionAccessibility.shared.reduceMotionOverride = true

        let surface = GlassSurface(frame: NSRect(x: 0, y: 0, width: 330, height: 106))
        surface.alwaysShowGlassBars = false
        let savedFrosted = GlassInteractionCoordinator.shared.useFrostedBarsInNormalMode
        let savedMode = GlassInteractionCoordinator.shared.renderMode
        defer {
            GlassInteractionCoordinator.shared.useFrostedBarsInNormalMode = savedFrosted
            GlassInteractionCoordinator.shared.renderMode = savedMode
        }
        GlassInteractionCoordinator.shared.renderMode = .original
        GlassInteractionCoordinator.shared.useFrostedBarsInNormalMode = false

        surface.isFocusedSurface = true
        surface.refreshGlassSurface(animateFocus: false)
        #expect(surface.composer.focusedOverlayLayer.opacity == 1.0)

        surface.isFocusedSurface = false
        surface.refreshGlassSurface(animateFocus: true)
        #expect(surface.composer.focusedOverlayLayer.opacity == 0.0)
    }

    @Test("M08: Specular sweep caps active layers at max 2 and respects cooldown")
    func testSpecularSweepBoundedLayersAndCooldown() {
        let savedRM = MotionAccessibility.shared.reduceMotionOverride
        let clock = ManualMotionClock(initial: 10.0)
        let savedClock = MotionCoordinator.shared.clock
        defer {
            MotionAccessibility.shared.reduceMotionOverride = savedRM
            MotionCoordinator.shared.clock = savedClock
        }
        MotionAccessibility.shared.reduceMotionOverride = false
        MotionCoordinator.shared.clock = clock

        let composer = PlayerLayerComposer()
        let host = CALayer()
        composer.attach(to: host)
        let size = CGSize(width: 495, height: 159)

        // First trigger succeeds
        #expect(composer.triggerSweep(from: 0.5, to: 1.0, size: size, uiScale: 1.5, backingScale: 2.0) == true)
        #expect(composer.activeSweepCount == 1)

        // Immediate trigger within 180ms cooldown is suppressed
        clock.advance(by: 0.05)
        #expect(composer.triggerSweep(from: 0.5, to: 0.0, size: size, uiScale: 1.5, backingScale: 2.0) == false)
        #expect(composer.activeSweepCount == 1)

        // After cooldown, 2nd and 3rd triggers keep active layers <= 2
        clock.advance(by: 0.20)
        #expect(composer.triggerSweep(from: 0.0, to: 1.0, size: size, uiScale: 1.5, backingScale: 2.0) == true)
        #expect(composer.activeSweepCount == 2)

        clock.advance(by: 0.20)
        #expect(composer.triggerSweep(from: 1.0, to: 0.0, size: size, uiScale: 1.5, backingScale: 2.0) == true)
        #expect(composer.activeSweepCount <= 2)

        composer.cancelSweeps()
        #expect(composer.activeSweepCount == 0)
    }

    @Test("M11: Interactive controls reject window-background drag")
    func testInteractiveControlsDoNotDragWindow() {
        let btn = GlassButton(image: nil, size: CGSize(width: 24, height: 24))
        #expect(btn.mouseDownCanMoveWindow == false)
    }

    @Test("M13 & M14: Rapid library and lyrics toggle reversals settle cleanly with zero active clocks")
    func testLibraryAndLyricsRevealReversals() {
        let savedRM = MotionAccessibility.shared.reduceMotionOverride
        defer {
            MotionAccessibility.shared.reduceMotionOverride = savedRM
            MotionCoordinator.shared.displayDriver.stopAll()
        }
        MotionAccessibility.shared.reduceMotionOverride = false

        let (stage, _, lyricsView, libCtrl, _) = makeStage()

        // Reverse Library mid-collapse
        stage.setLibraryVisible(false)
        MotionCoordinator.shared.displayDriver.stepManually(dt: 0.10)
        stage.setLibraryVisible(true)
        for _ in 0..<30 {
            MotionCoordinator.shared.displayDriver.stepManually(dt: 0.02)
        }
        #expect(stage.isLibraryVisible == true)
        #expect(libCtrl.moduleView.isHidden == false)
        #expect(libCtrl.moduleView.layer?.mask == nil)
        #expect(libCtrl.contentContainerView.alphaValue == 1.0)

        // Reverse Lyrics mid-collapse and toggle mini-lyrics mode
        stage.setLyricsVisible(false)
        MotionCoordinator.shared.displayDriver.stepManually(dt: 0.10)
        stage.setLyricsVisible(true)
        for _ in 0..<30 {
            MotionCoordinator.shared.displayDriver.stepManually(dt: 0.02)
        }
        #expect(stage.isLyricsVisible == true)
        #expect(lyricsView.isHidden == false)
        #expect(lyricsView.layer?.mask == nil)

        lyricsView.toggleMiniLyricsMode()
        for _ in 0..<30 {
            MotionCoordinator.shared.displayDriver.stepManually(dt: 0.02)
        }
        #expect(lyricsView.isMiniLyricsMode == true)
        #expect(!stage.isStageTransitioning)

        // Hiding the mini lyrics module must stop any overflowing placeholder marquee clock cleanly (zero hidden clocks)
        stage.setLyricsVisible(false)
        for _ in 0..<30 {
            MotionCoordinator.shared.displayDriver.stepManually(dt: 0.02)
        }
        #expect(lyricsView.isHidden == true)
        #expect(MotionCoordinator.shared.displayDriver.activeSubscriberCount == 0, "Residual drivers: \(MotionCoordinator.shared.displayDriver.activeSubscriberLabels)")
    }

    @Test("M25: Scale change updates stage layout cleanly")
    func testScaleSwitchUpdatesStage() {
        let savedScale = GlassInteractionCoordinator.shared.uiScale
        defer { GlassInteractionCoordinator.shared.uiScale = savedScale }

        let (stage, playerCtrl, _, _, _) = makeStage()
        GlassInteractionCoordinator.shared.uiScale = 1.0
        let s1 = playerCtrl.playerSlotView.frame.size
        #expect(abs(s1.width - 330.0) < 0.5)
        #expect(abs(s1.height - 106.0) < 0.5)

        GlassInteractionCoordinator.shared.uiScale = 1.5
        let s15 = playerCtrl.playerSlotView.frame.size
        #expect(abs(s15.width - 495.0) < 0.5)
        #expect(abs(s15.height - 159.0) < 0.5)
        _ = stage
    }

    @Test("V01(P1-2): M13/M14 hide-to-show reversal resumes seamlessly from live reveal progress")
    func testHideToShowReversalResumesFromLiveProgress() {
        let savedRM = MotionAccessibility.shared.reduceMotionOverride
        defer {
            MotionAccessibility.shared.reduceMotionOverride = savedRM
            MotionCoordinator.shared.displayDriver.stopAll()
        }
        MotionAccessibility.shared.reduceMotionOverride = false

        let (stage, _, _, _, _) = makeStage()
        stage.setLibraryVisible(false)
        MotionCoordinator.shared.displayDriver.stepManually(dt: 0.12)
        let midHideRect = stage.currentStageLayoutSnapshot().libraryFrame
        #expect(midHideRect.width > 20.0)

        stage.setLibraryVisible(true)
        let resumedRect = stage.currentStageLayoutSnapshot().libraryFrame
        #expect(abs(resumedRect.width - midHideRect.width) < 1.5)

        for _ in 0..<30 {
            MotionCoordinator.shared.displayDriver.stepManually(dt: 0.02)
        }
        #expect(stage.isLibraryVisible == true)
        #expect(!stage.isStageTransitioning)
    }

    @Test("V01(P1-2): M02 continuous height morph preserves Frame-0 alpha and smooth reversal")
    func testMorphContinuousHeightAlphaAndFrame0() {
        let savedRM = MotionAccessibility.shared.reduceMotionOverride
        defer {
            MotionAccessibility.shared.reduceMotionOverride = savedRM
            MotionCoordinator.shared.displayDriver.stopAll()
        }
        MotionAccessibility.shared.reduceMotionOverride = false

        let (stage, playerCtrl, _, _, _) = makeStage()
        #expect(playerCtrl.isMiniMode == false)

        playerCtrl.toggleMiniMode()
        // Frame 0 immediately starts at full height with full player alpha and 0 mini alpha (no flash)
        #expect(playerCtrl.playerView.alphaValue > 0.95)
        #expect(playerCtrl.miniPlayerView.alphaValue < 0.05)

        MotionCoordinator.shared.displayDriver.stepManually(dt: 0.14)
        let midAlphaPlayer = playerCtrl.playerView.alphaValue
        let midAlphaMini = playerCtrl.miniPlayerView.alphaValue

        // Mid-flight reverse back to Normal preserves alpha continuity instead of snapping to 0/1
        playerCtrl.toggleMiniMode()
        #expect(abs(playerCtrl.playerView.alphaValue - midAlphaPlayer) < 0.05)
        #expect(abs(playerCtrl.miniPlayerView.alphaValue - midAlphaMini) < 0.05)

        for _ in 0..<30 {
            MotionCoordinator.shared.displayDriver.stepManually(dt: 0.02)
        }
        #expect(playerCtrl.isMiniMode == false)
        #expect(!stage.isStageTransitioning)
    }

    @Test("V01(P1-6 & P1-7): Focus crossfade survives layout() and sweep keys rotate without self-cancel")
    func testFocusCrossfadeSurvivesLayoutAndRotatingSweeps() {
        let savedRM = MotionAccessibility.shared.reduceMotionOverride
        let savedFrosted = GlassInteractionCoordinator.shared.useFrostedBarsInNormalMode
        let savedMode = GlassInteractionCoordinator.shared.renderMode
        let savedClock = MotionCoordinator.shared.clock
        let clock = ManualMotionClock(initial: 10.0)
        defer {
            MotionAccessibility.shared.reduceMotionOverride = savedRM
            GlassInteractionCoordinator.shared.useFrostedBarsInNormalMode = savedFrosted
            GlassInteractionCoordinator.shared.renderMode = savedMode
            MotionCoordinator.shared.clock = savedClock
        }
        MotionAccessibility.shared.reduceMotionOverride = false
        GlassInteractionCoordinator.shared.renderMode = .original
        GlassInteractionCoordinator.shared.useFrostedBarsInNormalMode = false
        MotionCoordinator.shared.clock = clock

        let composer = PlayerLayerComposer()
        let host = CALayer()
        host.bounds = CGRect(x: 0, y: 0, width: 330, height: 106)
        composer.attach(to: host)

        composer.updateBackground(size: host.bounds.size, uiScale: 1.0, backingScale: 2.0, resolution: .original1x, focusRatio: 0.0, hasMainGloss: true, artworkKey: "none", artworkImage: nil, animateFocus: false)
        composer.updateBackground(size: host.bounds.size, uiScale: 1.0, backingScale: 2.0, resolution: .original1x, focusRatio: 1.0, hasMainGloss: true, artworkKey: "none", artworkImage: nil, animateFocus: true)
        #expect(composer.focusedOverlayLayer.animation(forKey: "focusCrossFade") != nil)
        // Subsequent non-animated layout pass with identical focusRatio must not kill active focus animation
        composer.updateBackground(size: host.bounds.size, uiScale: 1.0, backingScale: 2.0, resolution: .original1x, focusRatio: 1.0, hasMainGloss: true, artworkKey: "none", artworkImage: nil, animateFocus: false)
        #expect(composer.focusedOverlayLayer.opacity == 1.0)
        #expect(composer.focusedOverlayLayer.animation(forKey: "focusCrossFade") != nil)

        #expect(composer.triggerSweep(from: 0.5, to: 1.0, size: host.bounds.size, uiScale: 1.0, backingScale: 2.0) == true)
        clock.advance(by: 0.25)
        #expect(composer.triggerSweep(from: 0.5, to: 0.0, size: host.bounds.size, uiScale: 1.0, backingScale: 2.0) == true)
        #expect(composer.activeSweepCount == 2)
        composer.cancelSweeps()
    }

    @Test("Glass-bar launch choreography: Main opens two bars -> scroll unroll, then Lyrics & Library emerge in 2 phases")
    func testChoreographedLaunchSequenceAndMainCollapse() {
        let savedRM = MotionAccessibility.shared.reduceMotionOverride
        defer {
            MotionAccessibility.shared.reduceMotionOverride = savedRM
            MotionCoordinator.shared.displayDriver.stopAll()
        }
        MotionAccessibility.shared.reduceMotionOverride = false

        let (stage, playerCtrl, lyricsView, libCtrl, _) = makeStage()
        stage.playLaunchIntroIfNeeded()

        // Stage 1 active: Main player unrolling, Lyrics & Library waiting hidden behind Main
        #expect(playerCtrl.playerView.isScrollIntroActive == true)
        #expect(playerCtrl.playerView.isScrollPresentationActive == true)
        #expect(lyricsView.isHidden == true)
        #expect(libCtrl.moduleView.isHidden == true)

        // Advance past Stage 1 (Main completes at ~0.38s) -> triggers Stage 2 dock emerge
        for _ in 0..<22 {
            MotionCoordinator.shared.displayDriver.stepManually(dt: 0.02)
        }
        #expect(playerCtrl.playerView.isScrollIntroActive == false)
        #expect(playerCtrl.playerView.isScrollPresentationActive == false)
        #expect(stage.isStageTransitioning == true)
        #expect(lyricsView.isHidden == false)
        #expect(libCtrl.moduleView.isHidden == false)
        #expect(lyricsView.isScrollPresentationActive == true)
        #expect(libCtrl.moduleView.isScrollPresentationActive == true)

        // Advance Stage 2 to completion (~0.40s) -> all panels open, zero active drivers
        for _ in 0..<25 {
            MotionCoordinator.shared.displayDriver.stepManually(dt: 0.02)
        }
        #expect(!stage.isStageTransitioning)
        #expect(lyricsView.isScrollPresentationActive == false)
        #expect(libCtrl.moduleView.isScrollPresentationActive == false)
        #expect(lyricsView.contentContainerView.alphaValue == 1.0)
        #expect(libCtrl.contentContainerView.alphaValue == 1.0)

        // Main reverse glass-bar collapse completes cleanly
        var collapseCommitted = false
        playerCtrl.playScrollCollapseIfEligible { committed in
            collapseCommitted = committed
        }
        #expect(playerCtrl.playerView.isScrollIntroActive == true)
        for _ in 0..<20 {
            MotionCoordinator.shared.displayDriver.stepManually(dt: 0.02)
        }
        #expect(collapseCommitted == true)
        #expect(playerCtrl.playerView.alphaValue == 0.0)
        #expect(playerCtrl.playerView.isScrollPresentationActive == false)
        #expect(MotionCoordinator.shared.displayDriver.activeSubscriberCount == 0)
    }

    @Test("Choreographed Mini Mode: Library collapse -> Main mini -> Lyrics mini, symmetric expand & mid-flight reversal")
    func testChoreographedThreeStepMiniSequenceAndReversal() {
        let savedRM = MotionAccessibility.shared.reduceMotionOverride
        let savedModeDur = GlassInteractionCoordinator.shared.modeSequenceTotalDuration
        defer {
            MotionAccessibility.shared.reduceMotionOverride = savedRM
            GlassInteractionCoordinator.shared.modeSequenceTotalDuration = savedModeDur
            MotionCoordinator.shared.displayDriver.stopAll()
        }
        MotionAccessibility.shared.reduceMotionOverride = false
        GlassInteractionCoordinator.shared.modeSequenceTotalDuration = 1.2

        let (stage, playerCtrl, lyricsView, libCtrl, webRuntime) = makeStage()
        let initialWebView = webRuntime.webView

        // Trigger via double-click (identical to Mini mode button)
        stage.hostWindow.onDoubleClicked?()

        // Step 1 active: Library collapsing; Main is still Normal & Lyrics is still Full
        #expect(stage.isStageTransitioning == true)
        #expect(playerCtrl.isMiniMode == false)
        #expect(lyricsView.isMiniLyricsMode == false)

        // Complete Step 1 (0.40s) -> Step 2 (Main morph) starts
        for _ in 0..<22 {
            MotionCoordinator.shared.displayDriver.stepManually(dt: 0.02)
        }
        #expect(stage.isLibraryVisible == false)
        #expect(libCtrl.moduleView.isHidden == true)
        #expect(playerCtrl.isMiniMode == true)
        #expect(lyricsView.isMiniLyricsMode == false)

        // Complete Step 2 (0.40s) -> Step 3 (Lyrics shrink to Mini) starts
        for _ in 0..<22 {
            MotionCoordinator.shared.displayDriver.stepManually(dt: 0.02)
        }
        #expect(lyricsView.isMiniLyricsMode == true)

        // Complete Step 3 (0.40s) -> All settled cleanly
        for _ in 0..<22 {
            MotionCoordinator.shared.displayDriver.stepManually(dt: 0.02)
        }
        #expect(!stage.isStageTransitioning)
        #expect(playerCtrl.isMiniMode == true)
        #expect(lyricsView.isMiniLyricsMode == true)
        #expect(stage.isLibraryVisible == false)
        #expect(webRuntime.webView === initialWebView)

        // Expand back to Normal using startup order: Main Normal -> Lyrics Full -> Library Open
        playerCtrl.onChoreographedMiniToggleRequested?()
        #expect(stage.isStageTransitioning == true)
        #expect(playerCtrl.isMiniMode == false)
        #expect(lyricsView.isMiniLyricsMode == true)
        #expect(stage.isLibraryVisible == false)

        // Complete Step 1 (0.40s) -> Step 2 (Lyrics Full) starts
        for _ in 0..<22 {
            MotionCoordinator.shared.displayDriver.stepManually(dt: 0.02)
        }
        #expect(lyricsView.isMiniLyricsMode == false)
        #expect(stage.isLibraryVisible == false)

        // Complete Step 2 (0.40s) -> Step 3 (Library Open) starts
        for _ in 0..<22 {
            MotionCoordinator.shared.displayDriver.stepManually(dt: 0.02)
        }
        #expect(stage.isLibraryVisible == true)

        // Complete Step 3 (0.40s) -> All settled cleanly
        for _ in 0..<22 {
            MotionCoordinator.shared.displayDriver.stepManually(dt: 0.02)
        }
        #expect(!stage.isStageTransitioning)
        #expect(playerCtrl.isMiniMode == false)
        #expect(lyricsView.isMiniLyricsMode == false)
        #expect(stage.isLibraryVisible == true)

        // Mid-flight interruption: start Mini entry, then immediately reverse mid-Step-1
        stage.enterMiniModeChoreographed()
        MotionCoordinator.shared.displayDriver.stepManually(dt: 0.08)
        stage.exitMiniModeChoreographed()
        for _ in 0..<75 {
            MotionCoordinator.shared.displayDriver.stepManually(dt: 0.02)
        }
        #expect(!stage.isStageTransitioning)
        #expect(playerCtrl.isMiniMode == false)
        #expect(lyricsView.isMiniLyricsMode == false)
        #expect(stage.isLibraryVisible == true)

        // Hide lyrics before defer to stop any placeholder marquee
        stage.setLyricsVisible(false)
        for _ in 0..<25 {
            MotionCoordinator.shared.displayDriver.stepManually(dt: 0.02)
        }
        #expect(MotionCoordinator.shared.displayDriver.activeSubscriberCount == 0)
    }

    @Test("Mini mode records original origin and restores it on expand even after moving mini bar")
    func testMiniModeRestoresPreMiniOrigin() {
        let savedRM = MotionAccessibility.shared.reduceMotionOverride
        defer { MotionAccessibility.shared.reduceMotionOverride = savedRM }
        MotionAccessibility.shared.reduceMotionOverride = true

        let (stage, playerCtrl, _, _, _) = makeStage()
        let originalOrigin = stage.playerScreenOrigin
        #expect(playerCtrl.isMiniMode == false)

        stage.enterMiniModeChoreographed()
        #expect(playerCtrl.isMiniMode == true)

        // Simulate user dragging the mini bar to a completely different position
        stage.hostWindow.setFrameOrigin(NSPoint(x: originalOrigin.x + 120, y: originalOrigin.y - 80))
        NotificationCenter.default.post(name: NSWindow.didMoveNotification, object: stage.hostWindow)
        #expect(abs(stage.playerScreenOrigin.x - originalOrigin.x) > 50)

        // Expanding back restores the exact pre-mini origin
        stage.exitMiniModeChoreographed()
        #expect(playerCtrl.isMiniMode == false)
        #expect(abs(stage.playerScreenOrigin.x - originalOrigin.x) < 1.0)
        #expect(abs(stage.playerScreenOrigin.y - originalOrigin.y) < 1.0)
    }

    @Test("Main-window screen authority prevents auxiliary panels from snapping onto another screen")
    func testMainScreenAuthorityBlocksCrossScreenPanelSnap() {
        let mainScreen = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let playerRect = CGRect(x: 1100, y: 500, width: 330, height: 106)
        let librarySize = CGSize(width: 400, height: 500)
        // Dragged near right edge of main screen (where right-side snap would push into x=1430..1830 on a second screen)
        let snap = StageLayoutEngine.computeSnap(
            movedSize: librarySize,
            droppedOrigin: CGPoint(x: 1425, y: 106),
            playerScreenRect: playerRect,
            otherModuleScreenRect: nil,
            uiScale: 1.0,
            wasAlreadySnapped: false,
            visibleFrames: [mainScreen]
        )
        if snap.didSnap, let rect = snap.targetScreenRect {
            #expect(rect.maxX <= mainScreen.maxX + 1.0)
            #expect(rect.minX >= mainScreen.minX - 1.0)
        }
    }
}
}
