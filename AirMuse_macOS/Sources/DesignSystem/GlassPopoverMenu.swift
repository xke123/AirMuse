import AppKit
import QuartzCore

// MARK: - GlassPopoverMenuItem

public struct GlassPopoverMenuItem: Sendable {
    public let id: String
    public let title: String
    public let symbolName: String?
    public let isSelected: Bool
    public let isEnabled: Bool
    public let action: @MainActor () -> Void

    public init(
        id: String,
        title: String,
        symbolName: String? = nil,
        isSelected: Bool = false,
        isEnabled: Bool = true,
        action: @escaping @MainActor () -> Void
    ) {
        self.id = id
        self.title = title
        self.symbolName = symbolName
        self.isSelected = isSelected
        self.isEnabled = isEnabled
        self.action = action
    }
}

// MARK: - GlassPopoverMenuView

@MainActor
private final class GlassPopoverMenuSurfaceView: NSView {
    override var isFlipped: Bool { true }

    private let glassContainer = NSGlassEffectContainerView(frame: .zero)
    private let glassView = NSGlassEffectView(frame: .zero)
    private let rowsStack = NSStackView()
    private var rowViews: [GlassPopoverRowView] = []
    private var items: [GlassPopoverMenuItem] = []
    private var highlightedIndex: Int = -1
    var onDismiss: (() -> Void)?

    override var acceptsFirstResponder: Bool { true }

    init(items: [GlassPopoverMenuItem]) {
        self.items = items
        super.init(frame: .zero)
        setup()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setup() {
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.masksToBounds = true

        glassContainer.spacing = 6.0
        glassView.style = .regular
        glassView.cornerRadius = 10
        glassContainer.contentView = glassView
        glassContainer.autoresizingMask = [.width, .height]
        addSubview(glassContainer)

        rowsStack.orientation = .vertical
        rowsStack.alignment = .width
        rowsStack.spacing = 2
        rowsStack.edgeInsets = NSEdgeInsets(top: 6, left: 6, bottom: 6, right: 6)
        rowsStack.autoresizingMask = [.width, .height]
        addSubview(rowsStack)

        for (idx, item) in items.enumerated() {
            let row = GlassPopoverRowView(item: item)
            row.onHover = { [weak self] inside in
                if inside { self?.setHighlightedIndex(idx) }
            }
            row.onSelect = { [weak self] in
                self?.activateItem(at: idx)
            }
            rowsStack.addArrangedSubview(row)
            rowViews.append(row)
        }
        updateSurfaceMode()
    }

    func updateSurfaceMode() {
        let useGlass = GlassInteractionCoordinator.shared.isEnhancedMode && !MotionCoordinator.shared.isReduceTransparencyEnabled
        glassContainer.isHidden = !useGlass
        needsDisplay = true
    }

    override func layout() {
        super.layout()
        glassContainer.frame = bounds
        glassView.frame = glassContainer.bounds
        rowsStack.frame = bounds
    }

    override func draw(_ dirtyRect: NSRect) {
        let useGlass = GlassInteractionCoordinator.shared.isEnhancedMode && !MotionCoordinator.shared.isReduceTransparencyEnabled
        if useGlass { return }

        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        if !MotionCoordinator.shared.isReduceTransparencyEnabled,
           let plate = SkinAssetLoader.shared.image(for: .menuGlass, resolution: GlassInteractionCoordinator.shared.resolutionMode) {
            NineSliceRenderer.drawPlate9Slice(in: ctx, plate: plate, rect: bounds, cap: 12.0, alpha: 0.96)
        } else {
            let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 10, yRadius: 10)
            NSColor(srgbRed: 26/255.0, green: 28/255.0, blue: 32/255.0, alpha: 0.97).setFill()
            path.fill()
            NSColor(white: 1.0, alpha: 0.30).setStroke()
            path.lineWidth = 1.0
            path.stroke()
        }
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53: // Esc
            onDismiss?()
        case 125: // Down arrow
            moveHighlight(delta: 1)
        case 126: // Up arrow
            moveHighlight(delta: -1)
        case 36, 49, 76: // Return / Space
            if highlightedIndex >= 0 && highlightedIndex < items.count {
                activateItem(at: highlightedIndex)
            }
        default:
            super.keyDown(with: event)
        }
    }

    func moveHighlight(delta: Int) {
        guard !items.isEmpty else { return }
        var next = highlightedIndex + delta
        if next < 0 { next = items.count - 1 }
        if next >= items.count { next = 0 }
        setHighlightedIndex(next)
    }

    func setHighlightedIndex(_ index: Int) {
        highlightedIndex = index
        for (i, row) in rowViews.enumerated() {
            row.isHighlightedRow = (i == index)
        }
    }

    func activateItem(at index: Int) {
        guard index >= 0 && index < items.count, items[index].isEnabled else { return }
        let action = items[index].action
        onDismiss?()
        action()
    }
}

@MainActor
private final class GlassPopoverRowView: NSView {
    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: 190, height: 26) }

    var isHighlightedRow: Bool = false {
        didSet { needsDisplay = true }
    }
    var onHover: ((Bool) -> Void)?
    var onSelect: (() -> Void)?

    private let item: GlassPopoverMenuItem
    private let label = NSTextField(labelWithString: "")
    private let checkLabel = NSTextField(labelWithString: "")
    private var trackingArea: NSTrackingArea?

    init(item: GlassPopoverMenuItem) {
        self.item = item
        super.init(frame: NSRect(x: 0, y: 0, width: 190, height: 26))
        wantsLayer = true
        checkLabel.stringValue = item.isSelected ? "✓" : ""
        checkLabel.font = NSFont.systemFont(ofSize: 11.5, weight: .semibold)
        checkLabel.textColor = OriginalDesignTokens.Colors.titleSilver
        addSubview(checkLabel)

        label.stringValue = item.title
        label.font = NSFont.systemFont(ofSize: 12.0, weight: item.isSelected ? .semibold : .regular)
        label.textColor = item.isEnabled ? OriginalDesignTokens.Colors.titleSilver : OriginalDesignTokens.Colors.dimSilver
        label.lineBreakMode = .byTruncatingTail
        addSubview(label)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        checkLabel.frame = NSRect(x: 6, y: 4, width: 14, height: 18)
        label.frame = NSRect(x: 22, y: 4, width: max(20, bounds.width - 28), height: 18)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = trackingArea { removeTrackingArea(existing) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) { onHover?(true) }
    override func mouseExited(with event: NSEvent) { onHover?(false) }
    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) {
            onSelect?()
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        if isHighlightedRow && item.isEnabled {
            let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 6, yRadius: 6)
            NSColor(white: 1.0, alpha: 0.16).setFill()
            path.fill()
        }
    }
}

private final class PopoverMenuPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

// MARK: - GlassPopoverMenu (M19)

/// Native Liquid Glass / MENUGLASS popover menu with 180–300ms reveal,
/// keyboard navigation, click-outside & Esc dismissal, and Reduce Motion/Transparency support.
@MainActor
public final class GlassPopoverMenu {

    public static let shared = GlassPopoverMenu()

    private let ownerID = "GlassPopoverMenu"
    private var panel: PopoverMenuPanel?
    private var surfaceView: GlassPopoverMenuSurfaceView?
    private var eventMonitor: Any?
    private var resignObserver: NSObjectProtocol?
    private var lastOutsideDismissPoint: NSPoint?
    private var lastOutsideDismissUptime: TimeInterval = -.infinity

    public var isPresented: Bool { panel?.isVisible == true }

    public init() {}

    isolated deinit {
        dismiss(animated: false)
    }

    public func present(
        items: [GlassPopoverMenuItem],
        relativeTo anchorRectInScreen: NSRect,
        parentWindow: NSWindow?
    ) {
        if panel == nil,
           let pt = lastOutsideDismissPoint,
           (ProcessInfo.processInfo.systemUptime - lastOutsideDismissUptime) < 0.45,
           anchorRectInScreen.insetBy(dx: -4, dy: -4).contains(pt) {
            lastOutsideDismissPoint = nil
            return
        }
        dismiss(animated: false)
        guard !items.isEmpty else { return }

        let rowH: CGFloat = 28
        let width: CGFloat = 212
        let height: CGFloat = CGFloat(items.count) * rowH + 12
        let desiredOrigin = NSPoint(
            x: anchorRectInScreen.minX,
            y: anchorRectInScreen.minY - height - 4
        )
        let vf = parentWindow?.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let clampedX = min(max(desiredOrigin.x, vf.minX + 6), vf.maxX - width - 6)
        let clampedY = min(max(desiredOrigin.y, vf.minY + 6), vf.maxY - height - 6)

        let p = PopoverMenuPanel(
            contentRect: NSRect(x: clampedX, y: clampedY, width: width, height: height),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        p.isFloatingPanel = true
        p.level = .popUpMenu
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true

        let surface = GlassPopoverMenuSurfaceView(items: items)
        surface.frame = NSRect(x: 0, y: 0, width: width, height: height)
        surface.onDismiss = { [weak self] in
            self?.dismiss(animated: true)
        }
        p.contentView = surface
        self.panel = p
        self.surfaceView = surface

        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self, weak p] event in
            guard let self, let p, p.isVisible else { return event }
            if event.window !== p {
                self.lastOutsideDismissPoint = NSEvent.mouseLocation
                self.lastOutsideDismissUptime = ProcessInfo.processInfo.systemUptime
                self.dismiss(animated: true)
            }
            return event
        }
        resignObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.dismiss(animated: true)
            }
        }

        let ticket = MotionCoordinator.shared.beginTransition(for: TransitionKey(owner: ownerID, channel: "present"), category: .controlInteraction)
        if MotionCoordinator.shared.isReduceMotionEnabled {
            p.alphaValue = 1.0
            p.makeKeyAndOrderFront(nil)
            p.makeFirstResponder(surface)
            _ = MotionCoordinator.shared.complete(ticket)
        } else {
            p.alphaValue = 0.0
            p.makeKeyAndOrderFront(nil)
            p.makeFirstResponder(surface)
            MotionCoordinator.shared.animate(
                duration: MotionTokens.Duration.popoverReveal,
                timingFunction: .easeOut,
                ticket: ticket,
                action: {
                    p.animator().alphaValue = 1.0
                }
            )
        }
    }

    public func sendKeyEvent(_ event: NSEvent) {
        surfaceView?.keyDown(with: event)
    }

    public func dismiss(animated: Bool = true) {
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
            eventMonitor = nil
        }
        if let obs = resignObserver {
            NotificationCenter.default.removeObserver(obs)
            resignObserver = nil
        }
        guard let p = panel else { return }
        let key = TransitionKey(owner: ownerID, channel: "present")
        let ticket = MotionCoordinator.shared.beginTransition(for: key, category: .controlInteraction)

        if !animated || MotionCoordinator.shared.isReduceMotionEnabled {
            p.orderOut(nil)
            panel = nil
            surfaceView = nil
            _ = MotionCoordinator.shared.complete(ticket)
            return
        }

        MotionCoordinator.shared.animate(
            duration: 0.14,
            timingFunction: .easeIn,
            ticket: ticket,
            action: {
                p.animator().alphaValue = 0.0
            },
            completion: { [weak self, weak p] committed in
                guard committed, let p else { return }
                p.orderOut(nil)
                if self?.panel === p {
                    self?.panel = nil
                    self?.surfaceView = nil
                }
            }
        )
    }
}
