import Testing
import AppKit
import CoreGraphics
@testable import DesignSystem
@testable import UI
@testable import Domain
@testable import Playback

@Suite("AirMuse Original Skin & Window Restoration Tests")
@MainActor
struct SkinAndWindowTests {

    @Test("1. Original 1x and 4x skin assets load from Bundle.module")
    func testOriginalSkinAssetsLoad() {
        let loader = SkinAssetLoader.shared
        for name in SkinAssetName.allCases {
            let img1x = loader.image(for: name, resolution: .original1x)
            #expect(img1x != nil, "1x asset \(name.rawValue) should load")
        }
        #expect(loader.image(for: .windowGlass, resolution: .original1x)?.width == 30)
        #expect(loader.image(for: .windowGlass, resolution: .original1x)?.height == 40)
        #expect(loader.image(for: .windowGlassFocus, resolution: .retina4x)?.width == 120)
        #expect(loader.image(for: .windowGlassFocus, resolution: .retina4x)?.height == 160)
    }

    @Test("2. SkinAtlas crops exact tile dimensions")
    func testSkinAtlasCroppingDimensions() {
        let atlas = SkinAtlas.shared
        let mainPlay1x = atlas.mainControl(.play, resolution: .original1x)
        #expect(mainPlay1x?.width == 32)
        #expect(mainPlay1x?.height == 32)

        let mainPlay4x = atlas.mainControl(.play, resolution: .retina4x)
        #expect(mainPlay4x?.width == 128)
        #expect(mainPlay4x?.height == 128)

        let miniStop1x = atlas.miniControl(.stop, resolution: .original1x)
        #expect(miniStop1x?.width == 16)
        #expect(miniStop1x?.height == 16)

        let winClose1x = atlas.windowButton(.close, resolution: .original1x)
        #expect(winClose1x?.width == 13)
        #expect(winClose1x?.height == 13)
    }

    @Test("3. 9-slice glass renders cleanly across 1x and 2x Retina DPI")
    func testNineSliceAndDPIRendering() {
        let sizes: [(CGFloat, CGFloat)] = [(330, 106), (330, 40), (495, 159)]
        for (w, h) in sizes {
            for backingScale: CGFloat in [1.0, 2.0] {
                let pxW = Int(w * backingScale)
                let pxH = Int(h * backingScale)
                let cs = CGColorSpaceCreateDeviceRGB()
                let ctx = CGContext(
                    data: nil, width: pxW, height: pxH,
                    bitsPerComponent: 8, bytesPerRow: pxW * 4,
                    space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                )!
                ctx.scaleBy(x: backingScale, y: backingScale)
                OriginalGlassRenderer.drawGlassFrame(
                    in: ctx,
                    size: CGSize(width: w, height: h),
                    uiScale: w > 400 ? 1.5 : 1.0,
                    resolution: backingScale > 1.5 ? .retina4x : .original1x,
                    focusRatio: 1.0,
                    hasMainGloss: h > 60
                )
                let img = ctx.makeImage()
                #expect(img != nil)
                #expect(img?.width == pxW)
                #expect(img?.height == pxH)
            }
        }
    }

    @Test("4. Mini mode rapid toggle state machine remains consistent")
    func testMiniModeRapidToggleState() {
        let store = PlaybackStore()
        let coord = PlaybackCoordinator(store: store)
        let ctrl = PlayerWindowController(coordinator: coord, store: store)

        #expect(!ctrl.isMiniMode)
        ctrl.toggleMiniMode()
        #expect(ctrl.isMiniMode)
        ctrl.toggleMiniMode()
        #expect(!ctrl.isMiniMode)
        ctrl.toggleMiniMode()
        #expect(ctrl.isMiniMode)
    }

    @Test("5. DockManager attaches and syncs lyrics and library windows")
    func testDockManagerSnapping() {
        let main = NSWindow(contentRect: NSRect(x: 100, y: 400, width: 495, height: 159), styleMask: .borderless, backing: .buffered, defer: false)
        let lyrics = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 495, height: 360), styleMask: .borderless, backing: .buffered, defer: false)
        let library = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 540, height: 570), styleMask: .borderless, backing: .buffered, defer: false)

        let dock = DockManager()
        dock.attachWindows(main: main, lyrics: lyrics, library: library)
        dock.syncAllDocked()

        #expect(dock.isLyricsDocked)
        #expect(dock.isLibraryDocked)
    }

    @Test("6. Original and Enhanced render modes toggle cleanly")
    func testRenderModeToggle() {
        let coord = GlassInteractionCoordinator.shared
        let saved = coord.renderMode
        defer { coord.renderMode = saved }

        coord.renderMode = .original
        #expect(!coord.isEnhancedMode)

        coord.renderMode = .enhanced
        #expect(coord.isEnhancedMode)
    }

    @Test("7. ControlState alpha and pressed vertical offset match disassembly")
    func testControlStatePhysics() {
        #expect(abs(ControlState.normal.alpha - 0.70) < 0.001)
        #expect(abs(ControlState.hover.alpha - 1.00) < 0.001)
        #expect(abs(ControlState.pressed.alpha - 0.90) < 0.001)
        #expect(abs(ControlState.pressed.pressedYOffset - 1.0) < 0.001)
        #expect(abs(ControlState.normal.pressedYOffset - 0.0) < 0.001)
    }

    @Test("8. SpringValue converges to target")
    func testSpringValueConvergence() {
        var spring = SpringValue(initial: 0.0, config: MotionTokens.Springs.windowResize)
        spring.setTarget(1.0)
        for _ in 0..<200 {
            _ = spring.step(dtSeconds: 1.0 / 60.0)
        }
        #expect(spring.isSettled)
        #expect(abs(spring.current - 1.0) < 0.01)
    }
}
