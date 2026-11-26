import AppKit

/// Root application delegate for AirMuse macOS.
/// Delegates startup, 2-second logo splash, parallel background warm-up, and shutdown to `AppLifecycleCoordinator`.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    private var lifecycleCoordinator: AppLifecycleCoordinator?
    private var statusItem: NSStatusItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        setupStatusItem()

        let coordinator = AppLifecycleCoordinator()
        self.lifecycleCoordinator = coordinator
        coordinator.launch()
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let statusItem {
            NSStatusBar.system.removeStatusItem(statusItem)
            self.statusItem = nil
        }
        lifecycleCoordinator?.shutdown()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            let icon = NSImage(systemSymbolName: "music.note", accessibilityDescription: "AirMuse")
            icon?.isTemplate = true
            button.image = icon
            button.toolTip = "AirMuse"
        }

        let menu = NSMenu()
        let showItem = NSMenuItem(title: "显示 AirMuse", action: #selector(activateApp), keyEquivalent: "")
        showItem.target = self
        menu.addItem(showItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "退出 AirMuse", action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        item.menu = menu
        self.statusItem = item
    }

    @objc private func activateApp() {
        NSApp.activate(ignoringOtherApps: true)
        for window in NSApp.windows where !(window is NSPanel) {
            window.makeKeyAndOrderFront(nil)
        }
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }
}
