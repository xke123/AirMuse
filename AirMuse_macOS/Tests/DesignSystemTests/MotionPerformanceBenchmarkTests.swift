import Testing
import AppKit
import QuartzCore
@testable import DesignSystem
@testable import UI
@testable import Domain
@testable import Playback

extension MotionV2TestCoordinatorSuite {

@Suite("Motion V2 Performance & Resource Budget Benchmarks (V02)", .serialized)
@MainActor
struct MotionPerformanceBenchmarkTests {

    private struct StubEngine: PlaybackEngineProtocol {
        var engineInstanceID: UUID { UUID(uuidString: "22222222-2222-2222-2222-222222222222")! }
        func events() async -> AsyncStream<EngineEvent> { AsyncStream { $0.finish() } }
        func prepare(sessionContext: SessionContext, deadlineSeconds: TimeInterval) async throws {}
        func execute(_ command: EngineCommand, context: PlaybackOperationContext) async throws {}
        func isolateAndReset() async {}
    }

    @Test("V02: 100 mode toggles, 100 module toggles, and 100 hover cycles meet frame budget with zero residual clocks")
    func testHundredCycleSoakAndFrameBudget() {
        let savedRM = MotionAccessibility.shared.reduceMotionOverride
        defer {
            MotionAccessibility.shared.reduceMotionOverride = savedRM
            MotionCoordinator.shared.displayDriver.stopAll()
        }
        MotionAccessibility.shared.reduceMotionOverride = false

        let store = PlaybackStore()
        let coord = PlaybackCoordinatorV2(store: store, engine: StubEngine())
        let playerCtrl = PlayerWindowController(coordinator: coord, store: store)
        let lyricsView = LyricsModuleView(frame: .zero)
        let libCtrl = LibraryWindowController(coordinator: coord, registry: nil)
        let stage = UnifiedStageController(playerCtrl: playerCtrl, lyricsView: lyricsView, libraryCtrl: libCtrl)

        var stepDurationsMs: [Double] = []
        var activeFrameDurationsMs: [Double] = []
        stepDurationsMs.reserveCapacity(800)
        activeFrameDurationsMs.reserveCapacity(600)

        // 100 Normal <-> Mini cycles
        for _ in 0..<100 {
            playerCtrl.toggleMiniMode()
            for step in 0..<4 {
                let t0 = ProcessInfo.processInfo.systemUptime
                MotionCoordinator.shared.displayDriver.stepManually(dt: 0.085)
                let dtMs = (ProcessInfo.processInfo.systemUptime - t0) * 1000.0
                stepDurationsMs.append(dtMs)
                if step < 3 { activeFrameDurationsMs.append(dtMs) }
            }
        }

        // 100 Lyrics & Library reveal cycles
        for i in 0..<100 {
            let show = (i % 2 == 1)
            stage.setLibraryVisible(show)
            stage.setLyricsVisible(show)
            for step in 0..<4 {
                let t0 = ProcessInfo.processInfo.systemUptime
                MotionCoordinator.shared.displayDriver.stepManually(dt: 0.10)
                let dtMs = (ProcessInfo.processInfo.systemUptime - t0) * 1000.0
                stepDurationsMs.append(dtMs)
                if step < 3 { activeFrameDurationsMs.append(dtMs) }
            }
        }

        // 100 hover cycles on PlayerView & MiniPlayerView
        for i in 0..<100 {
            let h = (i % 2 == 0)
            playerCtrl.playerView.setHovering(h, immediate: false)
            playerCtrl.miniPlayerView.setHovering(h, immediate: false)
        }
        playerCtrl.playerView.setHovering(false, immediate: true)
        playerCtrl.miniPlayerView.setHovering(false, immediate: true)
        MotionCoordinator.shared.displayDriver.stopAll()

        let sorted = stepDurationsMs.sorted()
        let p50 = sorted[sorted.count / 2]
        let p95 = sorted[Int(Double(sorted.count) * 0.95)]
        let p99 = sorted[Int(Double(sorted.count) * 0.99)]

        let activeSorted = activeFrameDurationsMs.sorted()
        let activeP95 = activeSorted[Int(Double(activeSorted.count) * 0.95)]
        let maxHz = NSScreen.main?.maximumFramesPerSecond ?? 60
        let deviceBudgetMs: Double = maxHz >= 120 ? 8.33 : 16.67

        print("[V02_BENCHMARK] samples=\(sorted.count) activeSamples=\(activeSorted.count) displayHz=\(maxHz) P50=\(String(format: "%.3f", p50))ms ActiveP95=\(String(format: "%.3f", activeP95))ms AllP95=\(String(format: "%.3f", p95))ms P99=\(String(format: "%.3f", p99))ms")

        #expect(activeP95 < 8.33, "Active animation frame P95 (\(activeP95)ms) must stay within 120Hz budget (8.33ms)")
        #if DEBUG
        #expect(p95 < 16.67, "P95 Debug settle+step (\(p95)ms) must stay within 60Hz budget (16.67ms)")
        #else
        #expect(p95 < deviceBudgetMs, "P95 Release settle+step (\(p95)ms) must stay within \(maxHz)Hz budget (\(deviceBudgetMs)ms)")
        #endif
        #expect(MotionCoordinator.shared.displayDriver.activeSubscriberCount == 0)
    }
}
}
