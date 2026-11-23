import AppKit
import DesignSystem

// MARK: - PlayerWindow

/// Floating borderless panel for the AirMuse main controller.
/// Replicates the Windows WS_EX_LAYERED + WS_EX_TOPMOST behavior with AppKit NSPanel,
/// including double-click mode switching, position persistence, and render mode menus.
open class PlayerWindow: NSPanel {

    public var onDoubleClicked: (() -> Void)?
    public var onToggleLog: (() -> Void)?
    public var onToggleTopMost: (() -> Void)?
    public var doubleClickHitFilter: ((NSPoint) -> Bool)?

    private var lastDoubleClickTime: TimeInterval = 0

    private var originalModeItem: NSMenuItem?
    private var enhancedModeItem: NSMenuItem?
    private var scale1xItem: NSMenuItem?
    private var scale15xItem: NSMenuItem?
    private var topMostItem: NSMenuItem?

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
        hasShadow = false
        isMovableByWindowBackground = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        animationBehavior = .none

        setupContextMenu()
    }

    private func setupContextMenu() {
        let menu = NSMenu(title: "AirMuse")
        menu.addItem(NSMenuItem(title: "切换迷你模式", action: #selector(toggleMiniAction), keyEquivalent: "m"))

        let topItem = NSMenuItem(title: "总在最前", action: #selector(toggleTopMostAction), keyEquivalent: "t")
        topItem.state = level == .floating ? .on : .off
        self.topMostItem = topItem
        menu.addItem(topItem)

        menu.addItem(NSMenuItem.separator())

        // Render Mode submenu
        let modeMenu = NSMenu(title: "渲染模式")
        let origItem = NSMenuItem(title: "Original（原版 AIRPLAY 复刻）", action: #selector(selectOriginalMode), keyEquivalent: "")
        let enhItem = NSMenuItem(title: "Enhanced（原版 + 局部 Liquid Glass）", action: #selector(selectEnhancedMode), keyEquivalent: "")
        self.originalModeItem = origItem
        self.enhancedModeItem = enhItem
        modeMenu.addItem(origItem)
        modeMenu.addItem(enhItem)
        let modeRoot = NSMenuItem(title: "视觉渲染模式", action: nil, keyEquivalent: "")
        modeRoot.submenu = modeMenu
        menu.addItem(modeRoot)

        // UI Scale submenu
        let scaleMenu = NSMenu(title: "界面缩放")
        let s1x = NSMenuItem(title: "1.0× 原版逻辑尺寸 (330×106)", action: #selector(selectScale1x), keyEquivalent: "")
        let s15x = NSMenuItem(title: "1.5× Retina 舒适尺寸 (495×159)", action: #selector(selectScale15x), keyEquivalent: "")
        self.scale1xItem = s1x
        self.scale15xItem = s15x
        scaleMenu.addItem(s1x)
        scaleMenu.addItem(s15x)
        let scaleRoot = NSMenuItem(title: "界面缩放比例", action: nil, keyEquivalent: "")
        scaleRoot.submenu = scaleMenu
        menu.addItem(scaleRoot)

        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "打开诊断日志 (⌥⌘L)", action: #selector(toggleLogAction), keyEquivalent: "l"))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "退出 AirMuse", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

        contentView?.menu = menu
        refreshMenuStates()
    }

    public func refreshMenuStates() {
        let coord = GlassInteractionCoordinator.shared
        originalModeItem?.state = coord.renderMode == .original ? .on : .off
        enhancedModeItem?.state = coord.renderMode == .enhanced ? .on : .off
        scale1xItem?.state = abs(coord.uiScale - 1.0) < 0.1 ? .on : .off
        scale15xItem?.state = abs(coord.uiScale - 1.5) < 0.1 ? .on : .off
        topMostItem?.state = level == .floating ? .on : .off
    }

    @objc private func toggleMiniAction() {
        onDoubleClicked?()
    }

    @objc private func toggleTopMostAction() {
        onToggleTopMost?()
        refreshMenuStates()
    }

    @objc private func selectOriginalMode() {
        GlassInteractionCoordinator.shared.renderMode = .original
        refreshMenuStates()
    }

    @objc private func selectEnhancedMode() {
        GlassInteractionCoordinator.shared.renderMode = .enhanced
        refreshMenuStates()
    }

    @objc private func selectScale1x() {
        GlassInteractionCoordinator.shared.resolutionMode = .original1x
        GlassInteractionCoordinator.shared.uiScale = OriginalDesignTokens.Scale.original1x
        refreshMenuStates()
    }

    @objc private func selectScale15x() {
        GlassInteractionCoordinator.shared.resolutionMode = .retina4x
        GlassInteractionCoordinator.shared.uiScale = OriginalDesignTokens.Scale.macDefault
        refreshMenuStates()
    }

    @objc private func toggleLogAction() {
        onToggleLog?()
    }

    open override var canBecomeKey: Bool { true }
    open override var canBecomeMain: Bool { true }

    open override func mouseUp(with event: NSEvent) {
        super.mouseUp(with: event)
        if event.clickCount == 2, (doubleClickHitFilter?(event.locationInWindow) ?? true) {
            let now = ProcessInfo.processInfo.systemUptime
            if now - lastDoubleClickTime >= MotionTokens.Thresholds.doubleClickDebounce {
                lastDoubleClickTime = now
                onDoubleClicked?()
            }
        }
    }
}
