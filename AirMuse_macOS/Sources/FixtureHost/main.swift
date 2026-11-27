import AppKit
import Domain
import Playback
import PlatformRuntime
import Application
import DesignSystem
import UI
import Infrastructure

/// Standalone FixtureHost executable linking NO Apple Music Adapter or Providers target.
/// Verifies R02: generic UI + Application + PlatformRuntime + Playback boot and operate
/// cleanly with an independent FixturePlatformAdapter or zero platforms.
@main
@MainActor
struct FixtureHostMain {
    static func main() async {
        let registry = ProviderSessionRegistry()
        let store = PlaybackStore()
        let engine = NoOpFixtureEngine()
        let coordinator = PlaybackCoordinatorV2(store: store, engine: engine)
        let libraryController = LibraryWindowController(coordinator: coordinator, registry: registry)
        let logController = LogWindowController()
        await DiagnosticSnapshotCoordinator.shared.register(registry)
        await DiagnosticSnapshotCoordinator.shared.register(coordinator)
        let snapBundle = await DiagnosticSnapshotCoordinator.shared.captureAll()
        _ = (libraryController, logController)
        print("FixtureHost booted cleanly without AppleMusicAdapter (browsingProvider=\(String(describing: await registry.browsingProviderID)), snapshots=\(snapBundle.components.count))")
    }
}

private actor NoOpFixtureEngine: PlaybackEngineProtocol {
    let engineInstanceID = UUID()
    func events() async -> AsyncStream<EngineEvent> {
        AsyncStream { _ in }
    }
    func prepare(sessionContext: SessionContext, deadlineSeconds: TimeInterval) async throws {}
    func execute(_ command: EngineCommand, context: PlaybackOperationContext) async throws {}
    func isolateAndReset() async {}
}
