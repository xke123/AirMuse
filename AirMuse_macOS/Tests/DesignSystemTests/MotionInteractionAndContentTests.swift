import Testing
import AppKit
import QuartzCore
@testable import DesignSystem
@testable import UI
@testable import Domain
@testable import Playback

extension MotionV2TestCoordinatorSuite {

@Suite("Motion V2 Controls, Glass & Content Tests (M03-M06, M09-M10, M15-M24)", .serialized)
@MainActor
struct MotionInteractionAndContentTests {

    @Test("M03: PlayerView hover controls reject clicks when hidden and respond when hovered")
    func testPlayerHoverHitIsolation() {
        let savedRM = MotionAccessibility.shared.reduceMotionOverride
        defer { MotionAccessibility.shared.reduceMotionOverride = savedRM }
        MotionAccessibility.shared.reduceMotionOverride = true

        let player = PlayerView(frame: NSRect(x: 0, y: 0, width: 495, height: 159))
        player.layoutSubtreeIfNeeded()
        #expect(player.isHoverControlsInteractive == false)

        // Point at center of top-right quit button (w - 24 - 9.75 = 461.25, h - 11.25 = 147.75) while NOT hovering must NOT hit hidden controls
        let quitHitPoint = NSPoint(x: 461.0, y: 148.0)
        let hitWhenHidden = player.hitTest(quitHitPoint)
        #expect(!(hitWhenHidden is GlassButton))

        player.setHovering(true, immediate: true)
        #expect(player.isHoverControlsInteractive == true)
        let hitWhenHovered = player.hitTest(quitHitPoint)
        #expect(hitWhenHovered is GlassButton)

        // Also verify hit-testing passes through NSGlassEffectContainerView to playPauseButton
        let playCenter = NSPoint(x: 114.0 + 170.0 * 0.5, y: 159.0 - (26.0 + 16.0) * 1.5)
        let hitPlay = player.hitTest(playCenter)
        #expect(hitPlay is GlassButton)

        player.setHovering(false, immediate: true)
        #expect(player.isHoverControlsInteractive == false)
    }

    @Test("M04: MiniPlayerView hover does not resize window, isolates hidden hits, and supports keyboard focus")
    func testMiniHoverInvariants() {
        let savedRM = MotionAccessibility.shared.reduceMotionOverride
        defer { MotionAccessibility.shared.reduceMotionOverride = savedRM }
        MotionAccessibility.shared.reduceMotionOverride = true

        let initialRect = NSRect(x: 0, y: 0, width: 495, height: 45)
        let mini = MiniPlayerView(frame: initialRect)
        mini.layoutSubtreeIfNeeded()
        #expect(mini.isHoverControlsInteractive == false)

        mini.setHovering(true, immediate: true)
        #expect(mini.isHoverControlsInteractive == true)
        #expect(mini.frame == initialRect)

        mini.setHovering(false, immediate: true)
        #expect(mini.isHoverControlsInteractive == false)

        mini.setKeyboardControlsFocused(true)
        #expect(mini.isHoverControlsInteractive == true)
        mini.setKeyboardControlsFocused(false)
        #expect(mini.isHoverControlsInteractive == false)
    }

    @Test("M05: GlassButton press-drag-outside-release does not trigger onClick; keyboard activation fires once")
    func testGlassButtonPressReleaseAndKeyboard() {
        let btn = GlassButton(image: nil, size: CGSize(width: 32, height: 32))
        btn.frame = NSRect(x: 0, y: 0, width: 32, height: 32)
        var clicks = 0
        btn.onClick = { clicks += 1 }

        if let down = NSEvent.mouseEvent(with: .leftMouseDown, location: NSPoint(x: 16, y: 16), modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1),
           let dragOut = NSEvent.mouseEvent(with: .leftMouseDragged, location: NSPoint(x: 100, y: 100), modifierFlags: [], timestamp: 0.05, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1),
           let upOut = NSEvent.mouseEvent(with: .leftMouseUp, location: NSPoint(x: 100, y: 100), modifierFlags: [], timestamp: 0.1, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 0) {
            btn.mouseDown(with: down)
            #expect(btn.currentControlState == .pressed)
            btn.mouseDragged(with: dragOut)
            #expect(btn.currentControlState == .normal)
            btn.mouseUp(with: upOut)
        }
        #expect(clicks == 0)

        btn.triggerKeyboardActivate()
        #expect(clicks == 1)
        #expect(btn.currentControlState == .normal)
    }

    @Test("M06 & M23: Buffering state activates loading bar without faking Playing; Playing stops loading bar")
    func testBufferingAndPlayingStateHonesty() {
        let savedRM = MotionAccessibility.shared.reduceMotionOverride
        defer { MotionAccessibility.shared.reduceMotionOverride = savedRM }
        MotionAccessibility.shared.reduceMotionOverride = false

        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 495, height: 159), styleMask: .borderless, backing: .buffered, defer: false)
        let player = PlayerView(frame: NSRect(x: 0, y: 0, width: 495, height: 159))
        win.contentView = player
        player.layoutSubtreeIfNeeded()

        let track = MusicTrack(id: "t1", title: "Song", artistName: "Artist", albumTitle: "Album", durationMs: 180_000, providerID: "apple_music", providerTrackID: "t1")
        player.updateState(PlaybackState(status: .buffering, isPlaying: false, positionMs: 0, durationMs: 180_000, currentTrack: track))
        #expect(player.isStreamLoadingAnimating == true)

        player.updateState(PlaybackState(status: .playing, isPlaying: true, positionMs: 1000, durationMs: 180_000, currentTrack: track))
        #expect(player.isStreamLoadingAnimating == false)

        player.updateState(PlaybackState(status: .loading, isPlaying: false, positionMs: 0, durationMs: 180_000, currentTrack: track))
        #expect(player.isStreamLoadingAnimating == true)

        player.updateState(PlaybackState(status: .failed, isPlaying: false, positionMs: 0, durationMs: 180_000, currentTrack: track, errorMessage: "Network Error"))
        #expect(player.isStreamLoadingAnimating == false)
    }

    @Test("M09: Track switch mid-scrub cancels pending seek and never seeks new track")
    func testProgressScrubCancelOnTrackSwitch() {
        let player = PlayerView(frame: NSRect(x: 0, y: 0, width: 495, height: 159))
        player.layoutSubtreeIfNeeded()

        let t1 = MusicTrack(id: "t1", title: "Track 1", artistName: "A", albumTitle: "B", durationMs: 200_000, providerID: "apple_music", providerTrackID: "t1")
        let t2 = MusicTrack(id: "t2", title: "Track 2", artistName: "A", albumTitle: "B", durationMs: 200_000, providerID: "apple_music", providerTrackID: "t2")

        var seeks: [Int64] = []
        player.onSeek = { seeks.append($0) }

        player.updateState(PlaybackState(status: .playing, isPlaying: true, positionMs: 10_000, durationMs: 200_000, currentTrack: t1))

        // Locate progress subview
        let progress = player.subviews.first { String(describing: type(of: $0)) == "CapsuleProgressView" }
        #expect(progress != nil)
        if let progress {
            let loc = progress.convert(NSPoint(x: progress.bounds.width * 0.5, y: progress.bounds.midY), to: nil)
            if let down = NSEvent.mouseEvent(with: .leftMouseDown, location: loc, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) {
                progress.mouseDown(with: down)
            }
            // Switch track while user is still holding scrub
            player.updateState(PlaybackState(status: .playing, isPlaying: true, positionMs: 0, durationMs: 200_000, currentTrack: t2))
            if let up = NSEvent.mouseEvent(with: .leftMouseUp, location: loc, modifierFlags: [], timestamp: 0.1, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 0) {
                progress.mouseUp(with: up)
            }
        }
        #expect(seeks.isEmpty)
    }

    @Test("M10: Volume clamping stays strictly in 0...1 and triggers HUD callback")
    func testVolumeClampingAndHUD() {
        let player = PlayerView(frame: NSRect(x: 0, y: 0, width: 495, height: 159))
        player.layoutSubtreeIfNeeded()
        player.updateState(PlaybackState(status: .idle, isPlaying: false, volume: 1.8))
        let volView = player.subviews.compactMap { $0.subviews.first { String(describing: type(of: $0)) == "VolumeSegmentsView" } }.first as? VolumeSegmentsView
        #expect(volView != nil)
        #expect(volView?.volume == 1.0)

        player.updateState(PlaybackState(status: .idle, isPlaying: false, volume: -0.4))
        #expect(volView?.volume == 0.0)
    }

    @Test("M15: CarouselHaloTextView measures CJK, RTL, and emoji cleanly and stops marquee when paused")
    func testMiniTextMarqueeCJKRTLEmojiAndPause() {
        let savedRM = MotionAccessibility.shared.reduceMotionOverride
        defer {
            MotionAccessibility.shared.reduceMotionOverride = savedRM
            MotionCoordinator.shared.displayDriver.stopAll()
        }
        MotionAccessibility.shared.reduceMotionOverride = false

        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 120, height: 30), styleMask: .borderless, backing: .buffered, defer: false)
        let view = CarouselHaloTextView(frame: NSRect(x: 0, y: 0, width: 120, height: 30))
        win.contentView = view

        let font = NSFont.systemFont(ofSize: 12.5)
        for sample in ["周杰伦 - 最伟大的作品 (Live) 🎵", "فيروز - سألوني الناس", "Short"] {
            let w = view.measureTextWidth(sample, font: font)
            #expect(w > 0)
        }

        view.setSingleLine("这是一首特别长特别长一定会触发跑马灯滚动的中文歌曲名 🎧")
        for _ in 0..<25 { MotionCoordinator.shared.displayDriver.stepManually(dt: 0.02) }
        #expect(view.isMarqueeActive == true)

        view.setPaused(true)
        #expect(view.isMarqueeActive == false)
    }

    @Test("M17: Ambient glow layer stays confined strictly to inner body (outer borders untouched)")
    func testAmbientLayerBoundsExcludeOuterFrame() {
        let composer = PlayerLayerComposer()
        let size = CGSize(width: 495, height: 159)
        composer.layout(bounds: CGRect(origin: .zero, size: size), backingScale: 2.0)

        let s = GlassInteractionCoordinator.shared.uiScale
        let borderW = OriginalDesignTokens.BaseMetrics.glassBorderThickness * s
        let capH = OriginalDesignTokens.BaseMetrics.glassCapHeight * s
        let f = composer.ambientTintLayer.frame
        #expect(f.minX >= borderW - 0.1)
        #expect(f.maxX <= size.width - borderW + 0.1)
        #expect(f.minY >= capH - 0.1)
        #expect(f.maxY <= size.height - capH + 0.1)
    }

    @Test("M18: LyricsView normalizes out-of-order lines, handles empty lyrics, and respects manual scroll pause")
    func testLyricsNormalizationManualPauseAndEmpty() {
        let lyricsView = LyricsView(frame: NSRect(x: 0, y: 0, width: 495, height: 426))
        lyricsView.layoutSubtreeIfNeeded()

        // Empty lyrics
        lyricsView.updateLyrics(.empty)
        #expect(lyricsView.activeLineIndex == -1)

        // Out-of-order lines
        let unordered = LyricsDocument(
            trackKey: "k1",
            lines: [
                LyricsLine(timeMs: 10_000, text: "Line B"),
                LyricsLine(timeMs: 3_000, text: "Line A"),
                LyricsLine(timeMs: 20_000, text: "Line C with very long wrapping text to verify layout resilience")
            ]
        )
        lyricsView.updateLyrics(unordered)
        lyricsView.updatePlaybackPosition(ms: 4_000)
        #expect(lyricsView.activeLineIndex == 0) // Normalized Line A at 3000ms

        lyricsView.pauseAutoFollowForManualScroll()
        #expect(lyricsView.isManualScrollPaused == true)
        lyricsView.resumeAutoFollow()
        #expect(lyricsView.isManualScrollPaused == false)
    }

    @Test("M19 & M20: GlassPopoverMenu and GlassTooltipManager dismiss cleanly on Esc / hide")
    func testPopoverMenuAndTooltipLifecycle() {
        let savedRM = MotionAccessibility.shared.reduceMotionOverride
        defer { MotionAccessibility.shared.reduceMotionOverride = savedRM }
        MotionAccessibility.shared.reduceMotionOverride = true

        let win = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 330, height: 106), styleMask: .borderless, backing: .buffered, defer: false)
        let anchor = NSView(frame: NSRect(x: 20, y: 20, width: 20, height: 20))
        win.contentView?.addSubview(anchor)

        var selected = false
        GlassPopoverMenu.shared.present(
            items: [GlassPopoverMenuItem(id: "a", title: "Option A", action: { selected = true })],
            relativeTo: NSRect(x: 120, y: 120, width: 20, height: 20),
            parentWindow: win
        )
        #expect(GlassPopoverMenu.shared.isPresented == true)

        if let esc = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 53) {
            GlassPopoverMenu.shared.sendKeyEvent(esc)
        }
        #expect(GlassPopoverMenu.shared.isPresented == false)
        #expect(selected == false)

        GlassTooltipManager.shared.scheduleTooltip(text: "Tip", for: anchor, delay: 0.0)
        GlassTooltipManager.shared.hideImmediately()
        #expect(GlassTooltipManager.shared.isTooltipVisible == false)
    }

    @Test("M21 & M22: LibraryContentView creates zero NSGlassEffectView per card; TopBar search transitions cleanly")
    func testLibraryCardsNoGlassExplosionAndSearchToggle() {
        let content = LibraryContentView(frame: NSRect(x: 0, y: 0, width: 340, height: 500))
        content.layoutSubtreeIfNeeded()
        let items = (0..<150).map { i in
            MediaCardItem(id: "id_\(i)", title: "Title \(i)", subtitle: "Artist \(i)", type: .album)
        }
        content.displayItems(items)

        func countGlassViews(in view: NSView) -> Int {
            var c = (view is NSGlassEffectView) ? 1 : 0
            for sub in view.subviews { c += countGlassViews(in: sub) }
            return c
        }
        // Only DetailOverlayView header has 1 NSGlassEffectView; 150 cards add 0!
        #expect(countGlassViews(in: content) <= 1)

        let savedRM = MotionAccessibility.shared.reduceMotionOverride
        defer { MotionAccessibility.shared.reduceMotionOverride = savedRM }
        MotionAccessibility.shared.reduceMotionOverride = true

        let topBar = LibraryTopBarView(frame: NSRect(x: 0, y: 0, width: 320, height: 34))
        topBar.setSearchMode(true, animated: true)
        #expect(topBar.isSearchMode == true)
        topBar.setSearchMode(false, animated: true)
        #expect(topBar.isSearchMode == false)
    }

    @Test("M24: Trackpad gesture setting toggles cleanly")
    func testTrackpadGestureToggle() {
        let coord = GlassInteractionCoordinator.shared
        let saved = coord.enableTrackpadGestures
        defer { coord.enableTrackpadGestures = saved }
        coord.enableTrackpadGestures = false
        #expect(coord.enableTrackpadGestures == false)
        coord.enableTrackpadGestures = true
        #expect(coord.enableTrackpadGestures == true)
    }

    @Test("V01(P1-3): MiniPlayerView time slot stays clickable while hover controls are active")
    func testMiniTimeViewHitTestWhileHovered() {
        let savedRM = MotionAccessibility.shared.reduceMotionOverride
        defer { MotionAccessibility.shared.reduceMotionOverride = savedRM }
        MotionAccessibility.shared.reduceMotionOverride = true

        let mini = MiniPlayerView(frame: NSRect(x: 0, y: 0, width: 495, height: 45))
        mini.layoutSubtreeIfNeeded()
        mini.setHovering(true, immediate: true)

        let timeHit = mini.hitTest(NSPoint(x: 24.0, y: 22.0))
        #expect(timeHit != nil)
        #expect(timeHit !== mini)
        #expect(!(timeHit is GlassButton))
    }

    @Test("V01(P1-4): GlassButton layout preserves image bounds under press state")
    func testGlassButtonPreservesImageBoundsWhilePressed() {
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 80, height: 80), styleMask: .borderless, backing: .buffered, defer: false)
        let btn = GlassButton(image: nil, size: CGSize(width: 32, height: 32))
        btn.frame = NSRect(x: 10, y: 10, width: 32, height: 32)
        win.contentView?.addSubview(btn)
        btn.layoutSubtreeIfNeeded()

        if let down = NSEvent.mouseEvent(with: .leftMouseDown, location: NSPoint(x: 26, y: 26), modifierFlags: [], timestamp: 0, windowNumber: win.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) {
            btn.mouseDown(with: down)
        }
        btn.needsLayout = true
        btn.layoutSubtreeIfNeeded()

        #expect(btn.currentControlState == .pressed)
        #expect(btn.subviews.last?.bounds.size == NSSize(width: 32, height: 32))
    }

    @Test("V01(P1-8): Tab activates keyboard hover controls on PlayerView and MiniPlayerView")
    func testTabActivatesKeyboardHoverControls() {
        let savedRM = MotionAccessibility.shared.reduceMotionOverride
        defer { MotionAccessibility.shared.reduceMotionOverride = savedRM }
        MotionAccessibility.shared.reduceMotionOverride = true

        let player = PlayerView(frame: NSRect(x: 0, y: 0, width: 495, height: 159))
        let mini = MiniPlayerView(frame: NSRect(x: 0, y: 0, width: 495, height: 45))

        if let tabEvent = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, characters: "\t", charactersIgnoringModifiers: "\t", isARepeat: false, keyCode: 48),
           let escEvent = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 53) {
            player.keyDown(with: tabEvent)
            #expect(player.isHoverControlsInteractive == true)
            player.keyDown(with: escEvent)
            #expect(player.isHoverControlsInteractive == false)

            mini.keyDown(with: tabEvent)
            #expect(mini.isHoverControlsInteractive == true)
            mini.keyDown(with: escEvent)
            #expect(mini.isHoverControlsInteractive == false)
        }
    }

    @Test("LyricsModuleView mini mode centers top-bar buttons inside the bar and preserves hit-testing")
    func testLyricsMiniModeButtonAlignmentAndHitTest() {
        let savedRM = MotionAccessibility.shared.reduceMotionOverride
        defer { MotionAccessibility.shared.reduceMotionOverride = savedRM }
        MotionAccessibility.shared.reduceMotionOverride = true

        let s = GlassInteractionCoordinator.shared.uiScale
        let size = NSSize(width: OriginalDesignTokens.BaseMetrics.lyricsWindowWidth * s, height: OriginalDesignTokens.BaseMetrics.miniBarStandardHeight * s)
        let win = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: .borderless, backing: .buffered, defer: false)
        let module = LyricsModuleView(frame: NSRect(origin: .zero, size: size))
        win.contentView?.addSubview(module)
        module.toggleMiniLyricsMode()
        module.setHovering(true, immediate: true)
        module.layoutSubtreeIfNeeded()

        let wb = 13.0 * s
        let closeCenter = NSPoint(x: size.width - 12.0 * s - wb * 0.5, y: size.height * 0.5)
        let toggleCenter = NSPoint(x: size.width - 12.0 * s - wb - 5.0 * s - wb * 0.5, y: size.height * 0.5)

        let closeHit = module.hitTest(closeCenter)
        let toggleHit = module.hitTest(toggleCenter)
        #expect(closeHit is GlassButton)
        #expect(toggleHit is GlassButton)
        #expect(closeHit !== toggleHit)
    }

    @Test("LyricsModuleView double-clicking top or bottom glass bar toggles mini mode, ignoring body and buttons")
    func testLyricsGlassBarDoubleClickTogglesMiniMode() {
        let savedRM = MotionAccessibility.shared.reduceMotionOverride
        defer { MotionAccessibility.shared.reduceMotionOverride = savedRM }
        MotionAccessibility.shared.reduceMotionOverride = true

        let s = GlassInteractionCoordinator.shared.uiScale
        let normalSize = NSSize(
            width: OriginalDesignTokens.BaseMetrics.lyricsWindowWidth * s,
            height: OriginalDesignTokens.BaseMetrics.lyricsWindowHeight * s
        )
        let miniSize = NSSize(
            width: OriginalDesignTokens.BaseMetrics.lyricsWindowWidth * s,
            height: OriginalDesignTokens.BaseMetrics.miniBarStandardHeight * s
        )
        let win = NSWindow(contentRect: NSRect(origin: .zero, size: normalSize), styleMask: .borderless, backing: .buffered, defer: false)
        let module = LyricsModuleView(frame: NSRect(origin: .zero, size: normalSize))
        win.contentView?.addSubview(module)
        module.setHovering(true, immediate: true)
        module.layoutSubtreeIfNeeded()

        func makeDoubleClick(at pt: NSPoint) -> NSEvent {
            NSEvent.mouseEvent(
                with: .leftMouseUp,
                location: pt,
                modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: win.windowNumber,
                context: nil,
                eventNumber: 1,
                clickCount: 2,
                pressure: 0
            )!
        }

        // 1. Middle body double-click must NOT toggle
        let bodyPt = NSPoint(x: normalSize.width * 0.5, y: normalSize.height * 0.5)
        module.mouseUp(with: makeDoubleClick(at: bodyPt))
        #expect(module.isMiniLyricsMode == false)

        // 2. Close button double-click must NOT toggle
        let wb = 13.0 * s
        let capH = OriginalDesignTokens.BaseMetrics.glassCapHeight * s
        let closePt = NSPoint(x: normalSize.width - 16.0 * s - wb * 0.5, y: normalSize.height - capH * 0.5)
        module.mouseUp(with: makeDoubleClick(at: closePt))
        #expect(module.isMiniLyricsMode == false)

        // 3. Top glass bar double-click toggles Normal -> Mini
        let topBarPt = NSPoint(x: normalSize.width * 0.3, y: normalSize.height - capH * 0.5)
        module.mouseUp(with: makeDoubleClick(at: topBarPt))
        #expect(module.isMiniLyricsMode == true)

        // Resize to mini bar & wait past debounce, then double-click lower half of mini bar to restore Normal
        module.frame = NSRect(origin: .zero, size: miniSize)
        win.setFrame(NSRect(origin: .zero, size: miniSize), display: false)
        module.layoutSubtreeIfNeeded()
        Thread.sleep(forTimeInterval: MotionTokens.Thresholds.doubleClickDebounce + 0.02)
        let miniBarLowerPt = NSPoint(x: miniSize.width * 0.3, y: miniSize.height * 0.25)
        module.mouseUp(with: makeDoubleClick(at: miniBarLowerPt))
        #expect(module.isMiniLyricsMode == false)

        // 4. Bottom glass bar double-click toggles Normal -> Mini
        module.frame = NSRect(origin: .zero, size: normalSize)
        win.setFrame(NSRect(origin: .zero, size: normalSize), display: false)
        module.layoutSubtreeIfNeeded()
        Thread.sleep(forTimeInterval: MotionTokens.Thresholds.doubleClickDebounce + 0.02)
        let bottomBarPt = NSPoint(x: normalSize.width * 0.3, y: capH * 0.5)
        module.mouseUp(with: makeDoubleClick(at: bottomBarPt))
        #expect(module.isMiniLyricsMode == true)
    }
}
}
