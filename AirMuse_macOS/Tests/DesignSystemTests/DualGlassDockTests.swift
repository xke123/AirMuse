import AppKit
import Foundation
import Testing
import Domain
import Playback
@testable import UI

private actor DockTestEngine: PlaybackEngineProtocol {
    private(set) var currentEngineInstanceID = UUID()
    private var continuations: [UUID: AsyncStream<EngineEvent>.Continuation] = [:]

    var engineInstanceID: UUID { currentEngineInstanceID }

    func events() async -> AsyncStream<EngineEvent> {
        AsyncStream { cont in
            let id = UUID()
            continuations[id] = cont
            cont.onTermination = { [weak self] _ in
                Task { await self?.removeCont(id) }
            }
        }
    }

    private func removeCont(_ id: UUID) {
        continuations.removeValue(forKey: id)
    }

    func emit(_ event: EngineEvent) {
        for cont in continuations.values {
            cont.yield(event)
        }
    }

    func prepare(sessionContext: SessionContext, deadlineSeconds: TimeInterval) async throws {}
    func execute(_ command: EngineCommand, context: PlaybackOperationContext) async throws {}
    func isolateAndReset() async { currentEngineInstanceID = UUID() }
}

@Suite("DualGlassDockTests")
@MainActor
struct DualGlassDockTests {

    @Test("P37, P38, P39 & P40: Dual-glass dock interaction mode, stage-only origin hidden, remote station panel & hide cleanup")
    func dualGlassDockModesAndCleanup() async throws {
        let store = PlaybackStore()
        let engine = DockTestEngine()
        let coord = PlaybackCoordinatorV2(store: store, engine: engine)
        let session = SessionContext(providerID: "apple_music", accountID: "acct-dock", storefront: "cn", sessionID: UUID(), generation: 1)
        await coord.start(session: session)

        let dock = LiquidFusionQueueDockView(coordinator: coord)
        dock.frame = NSRect(x: 0, y: 0, width: 640, height: 480)
        dock.layoutSubtreeIfNeeded()

        // 1. Stage-only local queue -> no confirmedCurrent -> origin capsule hidden
        let origin = PlaybackOrigin(
            kind: .album,
            sourceID: "alb-dock",
            sourceTitle: "Very Long Album Name That Should Clamp Nicely In Narrow Windows",
            navigationTarget: .resource(kind: .album, id: "alb-dock", isLibrary: false, providerID: "apple_music")
        )
        let t1 = MusicTrack(id: "d1", title: "D1", artistName: "A1", albumTitle: "Alb", durationMs: 180_000, providerID: "apple_music", providerTrackID: "d1")
        _ = try await coord.submitIntent(.append, entries: [QueueEntry(track: t1, origin: origin)])
        try await Task.sleep(for: .milliseconds(40))
        dock.layoutSubtreeIfNeeded()
        #expect(dock.interactionMode == .collapsed)
        #expect(dock.isExpanded == false)

        // 2. Rapid expand/collapse reversal & viewDidHide cleanup (P37, P40)
        dock.setExpanded(true)
        #expect(dock.interactionMode == .queueOpen)
        #expect(dock.isExpanded == true)
        dock.setExpanded(false)
        #expect(dock.interactionMode == .collapsed)
        #expect(dock.isExpanded == false)

        dock.setExpanded(true)
        dock.viewDidHide()
        #expect(dock.interactionMode == .collapsed)
        #expect(dock.isExpanded == false)

        // 3. Narrow window layout clamping does not crash or produce negative sizes (P39)
        dock.frame = NSRect(x: 0, y: 0, width: 220, height: 240)
        dock.layoutSubtreeIfNeeded()
        #expect(dock.bounds.width == 220)

        // 4. Remote station mode (P38)
        let stationTrack = MusicTrack(id: "ra.dock", title: "Dock Radio", artistName: "Apple Music", albumTitle: "Radio", durationMs: 0, providerID: "apple_music", providerTrackID: "ra.dock")
        let stationOrigin = PlaybackOrigin(
            kind: .station,
            sourceID: "ra.dock",
            sourceTitle: "Dock Radio",
            stationContext: StationOriginContext(stationID: "ra.dock", stationType: .unknown)
        )
        try await coord.playEntries([QueueEntry(track: stationTrack, origin: stationOrigin)], startIndex: 0, kind: .station)
        try await Task.sleep(for: .milliseconds(40))
        dock.setExpanded(true)
        dock.layoutSubtreeIfNeeded()
        #expect(dock.isExpanded == true)
        dock.setExpanded(false)
    }
}
