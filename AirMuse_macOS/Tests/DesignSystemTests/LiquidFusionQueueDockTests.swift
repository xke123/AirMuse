import AppKit
import Testing
import Domain
import Playback
@testable import UI

private actor MockQueueUIEngine: PlaybackEngineProtocol {
    let engineInstanceID = UUID()
    func events() async -> AsyncStream<EngineEvent> { AsyncStream { _ in } }
    func prepare(sessionContext: SessionContext, deadlineSeconds: TimeInterval) async throws {}
    func execute(_ command: EngineCommand, context: PlaybackOperationContext) async throws {}
    func isolateAndReset() async {}
}

@Suite("LiquidFusionQueueDockTests")
@MainActor
struct LiquidFusionQueueDockTests {

    private func makeEntry(_ id: String) -> QueueEntry {
        let track = MusicTrack(
            id: id,
            title: "Song \(id)",
            artistName: "Artist \(id)",
            albumTitle: "Album",
            durationMs: 180_000,
            providerID: "apple_music",
            providerTrackID: id
        )
        return QueueEntry(track: track, origin: PlaybackOrigin(kind: .album, sourceID: "alb1", sourceTitle: "Album 1"))
    }

    @Test("T21 & T23: Expand/collapse geometry, hit-testing, mid-flight reversal, and viewDidHide cleanup")
    func expandCollapseAndHitTest() async throws {
        let store = PlaybackStore()
        let engine = MockQueueUIEngine()
        let coord = PlaybackCoordinatorV2(store: store, engine: engine)
        await coord.start()

        let host = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        let dock = LiquidFusionQueueDockView(coordinator: coord)
        dock.frame = host.bounds
        host.addSubview(dock)
        dock.layoutSubtreeIfNeeded()

        // Collapsed: hit outside bottom-right button returns nil; hit on button returns an NSControl (toggleButton)
        #expect(!dock.isExpanded)
        #expect(dock.hitTest(NSPoint(x: 100, y: 300)) == nil)
        let hitView = dock.hitTest(NSPoint(x: 780, y: 18))
        #expect(hitView is NSButton)

        // Expand & rapid mid-flight collapse
        dock.setExpanded(true)
        #expect(dock.isExpanded)
        dock.setExpanded(false)
        #expect(!dock.isExpanded)

        // Expand then hide parent: cleans up expanded state
        dock.setExpanded(true)
        #expect(dock.isExpanded)
        dock.isHidden = true
        dock.viewDidHide()
        #expect(!dock.isExpanded)
    }

    @Test("T22: Dock reflects real coordinator queue snapshot updates")
    func dockReflectsRealQueueSnapshot() async throws {
        let store = PlaybackStore()
        let engine = MockQueueUIEngine()
        let coord = PlaybackCoordinatorV2(store: store, engine: engine)
        await coord.start()

        let dock = LiquidFusionQueueDockView(coordinator: coord)
        dock.frame = NSRect(x: 0, y: 0, width: 700, height: 500)
        dock.layoutSubtreeIfNeeded()

        let e1 = makeEntry("1"), e2 = makeEntry("2"), e3 = makeEntry("3")
        try await coord.playEntries([e1, e2, e3], startIndex: 0)

        for _ in 0..<40 {
            if dock.numberOfRows(in: NSTableView()) == 2 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(dock.numberOfRows(in: NSTableView()) == 2)
    }
}
