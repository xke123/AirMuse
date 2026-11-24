import AppKit

/// Root application delegate for AirMuse macOS.
/// Delegates startup, 2-second logo splash, parallel background warm-up, and shutdown to `AppLifecycleCoordinator`.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    private var lifecycleCoordinator: AppLifecycleCoordinator?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        let coordinator = AppLifecycleCoordinator()
        self.lifecycleCoordinator = coordinator
        coordinator.launch()
    }

    func applicationWillTerminate(_ notification: Notification) {
        lifecycleCoordinator?.shutdown()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }
}
