import AppKit

// MARK: - PlayerWindow

/// Floating borderless panel for the AirMuse main controller.
/// Replicates the Windows WS_EX_LAYERED + WS_EX_TOPMOST behavior with AppKit NSPanel.
open class PlayerWindow: NSPanel {

    public var onDoubleClicked: (() -> Void)?
    public var onToggleLog: (() -> Void)?

    public init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        isFloatingPanel = true
        level = .floating
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isMovableByWindowBackground = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        animationBehavior = .none

        setupContextMenu()
    }

    private func setupContextMenu() {
        let menu = NSMenu(title: "AirMuse")
        menu.addItem(NSMenuItem(title: "切换迷你模式", action: #selector(toggleMiniAction), keyEquivalent: "m"))
        menu.addItem(NSMenuItem(title: "打开诊断日志 (⌥⌘L)", action: #selector(toggleLogAction), keyEquivalent: "l"))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "退出 AirMuse", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        contentView?.menu = menu
    }

    @objc private func toggleMiniAction() {
        onDoubleClicked?()
    }

    @objc private func toggleLogAction() {
        onToggleLog?()
    }

    open override var canBecomeKey: Bool {
        true
    }

    open override var canBecomeMain: Bool {
        true
    }

    open override func mouseUp(with event: NSEvent) {
        super.mouseUp(with: event)
        if event.clickCount == 2 {
            onDoubleClicked?()
        }
    }
}

