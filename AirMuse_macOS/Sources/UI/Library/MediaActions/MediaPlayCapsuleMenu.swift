import AppKit
import QuartzCore
import Domain
import DesignSystem

// MARK: - MediaPlayCapsuleButton

/// Native Liquid Glass Play Capsule button with a chevron that opens the unified 5-intent Play Menu.
/// Preserves Original skin fallback and Reduce Transparency / Reduce Motion accessibility.
@MainActor
public final class MediaPlayCapsuleButton: NSView {
    public override var isFlipped: Bool { true }
    public override var acceptsFirstResponder: Bool { true }

    public var onSelectIntent: ((MediaPlayIntent) -> Void)?
    public var menuDescriptorProvider: (() -> MediaActionMenuDescriptor)?

    private let button = NSButton()
    private var popoverController: MediaPlayMenuPopoverController?
    private var isMenuOpen: Bool = false

    public var titleText: String = "播放" {
        didSet { updateButtonTitle() }
    }

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    isolated deinit {
        NotificationCenter.default.removeObserver(self)
        popoverController?.dismiss(returnFocus: false)
    }

    private func setup() {
        wantsLayer = true
        layer?.cornerRadius = 14
        layer?.masksToBounds = true

        button.bezelStyle = .inline
        button.isBordered = false
        button.target = self
        button.action = #selector(toggleMenu)
        button.setAccessibilityRole(.popUpButton)
        button.setAccessibilityLabel("播放选项")
        addSubview(button)

        updateButtonTitle()
        updateMaterialMode()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(updateMaterialMode),
            name: GlassInteractionCoordinator.modeDidChangeNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(updateMaterialMode),
            name: MotionAccessibility.preferencesDidChangeNotification,
            object: nil
        )
    }

    @objc private func updateMaterialMode() {
        let useGlass = GlassInteractionCoordinator.shared.isEnhancedMode && !MotionCoordinator.shared.isReduceTransparencyEnabled
        if useGlass {
            layer?.backgroundColor = NSColor(red: 0.98, green: 0.22, blue: 0.35, alpha: 0.88).cgColor
        } else {
            layer?.backgroundColor = NSColor(red: 0.98, green: 0.22, blue: 0.35, alpha: 0.95).cgColor
        }
    }

    private func updateButtonTitle() {
        let pstyle = NSMutableParagraphStyle()
        pstyle.alignment = .center
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12.5, weight: .bold),
            .foregroundColor: NSColor.white,
            .paragraphStyle: pstyle
        ]
        button.attributedTitle = NSAttributedString(string: "▶ \(titleText) ▾", attributes: attrs)
        button.toolTip = "\(titleText)（展开播放菜单）"
        button.setAccessibilityTitle("\(titleText)，播放菜单")
    }

    public override func layout() {
        super.layout()
        layer?.cornerRadius = bounds.height * 0.5
        button.frame = bounds
    }

    public override func keyDown(with event: NSEvent) {
        if event.keyCode == 49 || event.keyCode == 36 || event.keyCode == 125 { // Space, Return, Down
            toggleMenu()
            return
        }
        super.keyDown(with: event)
    }

    @objc private func toggleMenu() {
        if isMenuOpen {
            popoverController?.dismiss(returnFocus: true)
            return
        }
        guard let descriptor = menuDescriptorProvider?(), !descriptor.isEmpty else {
            onSelectIntent?(.replaceAndPlay)
            return
        }

        // Single-action (e.g. station "收听") executes directly
        if descriptor.allActions.count == 1,
           case .play(let intent, _, _, _) = descriptor.allActions[0] {
            onSelectIntent?(intent)
            return
        }

        let controller = MediaPlayMenuPopoverController(
            descriptor: descriptor,
            anchorView: self,
            onSelect: { [weak self] intent in
                self?.onSelectIntent?(intent)
            },
            onDismissed: { [weak self] in
                self?.isMenuOpen = false
                self?.popoverController = nil
            }
        )
        popoverController = controller
        isMenuOpen = true
        controller.present()
    }
}

// MARK: - MediaPlayMenuPopoverController

@MainActor
private final class MediaPlayMenuPopoverController: NSObject {
    private let descriptor: MediaActionMenuDescriptor
    private weak var anchorView: NSView?
    private let onSelect: (MediaPlayIntent) -> Void
    private let onDismissed: () -> Void

    private var panel: NSPanel?
    private var surfaceView: MediaPlayMenuSurfaceView?
    private var localMonitor: Any?
    private var isClosing: Bool = false
    private var animationGeneration: UInt64 = 0

    init(
        descriptor: MediaActionMenuDescriptor,
        anchorView: NSView,
        onSelect: @escaping (MediaPlayIntent) -> Void,
        onDismissed: @escaping () -> Void
    ) {
        self.descriptor = descriptor
        self.anchorView = anchorView
        self.onSelect = onSelect
        self.onDismissed = onDismissed
    }

    func present() {
        guard let anchorView, let parentWindow = anchorView.window else {
            onDismissed()
            return
        }

        let surface = MediaPlayMenuSurfaceView(descriptor: descriptor) { [weak self] intent in
            self?.dismiss(returnFocus: true)
            self?.onSelect(intent)
        } onCancel: { [weak self] in
            self?.dismiss(returnFocus: true)
        }
        self.surfaceView = surface

        let targetSize = surface.fittingSize
        let anchorRectInWin = anchorView.convert(anchorView.bounds, to: nil)
        let anchorRectInScreen = parentWindow.convertToScreen(anchorRectInWin)
        let parentFrame = parentWindow.frame

        var originX = anchorRectInScreen.maxX - targetSize.width
        var originY = anchorRectInScreen.minY - targetSize.height - 6

        // Clamp within parent window / screen bounds
        originX = max(parentFrame.minX + 8, min(originX, parentFrame.maxX - targetSize.width - 8))
        if originY < parentFrame.minY + 8 {
            originY = anchorRectInScreen.maxY + 6
        }

        let panel = NSPanel(
            contentRect: NSRect(x: originX, y: originY, width: targetSize.width, height: targetSize.height),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .popUpMenu
        panel.contentView = surface
        self.panel = panel

        parentWindow.addChildWindow(panel, ordered: .above)
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(surface)

        animationGeneration &+= 1
        let gen = animationGeneration
        let reduceMotion = MotionCoordinator.shared.isReduceMotionEnabled

        if reduceMotion {
            surface.alphaValue = 1
        } else {
            surface.alphaValue = 0
            surface.layer?.transform = CATransform3DMakeScale(0.96, 0.96, 1)
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.16
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                surface.animator().alphaValue = 1
            } completionHandler: { [weak self, weak surface] in
                Task { @MainActor in
                    guard let self, self.animationGeneration == gen, !self.isClosing else { return }
                    surface?.layer?.transform = CATransform3DIdentity
                }
            }
        }

        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown]) { [weak self] event in
            guard let self, let panel = self.panel else { return event }
            if event.type == .keyDown && event.keyCode == 53 { // Escape
                self.dismiss(returnFocus: true)
                return nil
            }
            if event.type == .leftMouseDown || event.type == .rightMouseDown {
                if event.window != panel {
                    self.dismiss(returnFocus: false)
                }
            }
            return event
        }
    }

    func dismiss(returnFocus: Bool) {
        guard !isClosing else { return }
        isClosing = true
        animationGeneration &+= 1
        let gen = animationGeneration

        if let localMonitor {
            NSEvent.removeMonitor(localMonitor)
            self.localMonitor = nil
        }

        guard let panel else {
            onDismissed()
            return
        }

        let finishDismiss: @MainActor () -> Void = { [weak self, weak panel] in
            if let panel {
                panel.parent?.removeChildWindow(panel)
                panel.orderOut(nil)
            }
            if returnFocus, let anchor = self?.anchorView {
                anchor.window?.makeFirstResponder(anchor)
            }
            self?.panel = nil
            self?.surfaceView = nil
            self?.onDismissed()
        }

        if MotionCoordinator.shared.isReduceMotionEnabled {
            finishDismiss()
        } else {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.12
                ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
                panel.contentView?.animator().alphaValue = 0
            } completionHandler: { [weak self] in
                Task { @MainActor in
                    guard let self, self.animationGeneration == gen else { return }
                    finishDismiss()
                }
            }
        }
    }
}

// MARK: - MediaPlayMenuSurfaceView

@MainActor
private final class MediaPlayMenuSurfaceView: NSView {
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    private let glassView = NSGlassEffectView(frame: .zero)
    private let stack = NSStackView()
    private var itemRows: [(intent: MediaPlayIntent, view: MediaPlayMenuRowView)] = []
    private var highlightedIndex: Int = 0
    private let onSelect: (MediaPlayIntent) -> Void
    private let onCancel: () -> Void

    init(
        descriptor: MediaActionMenuDescriptor,
        onSelect: @escaping (MediaPlayIntent) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.onSelect = onSelect
        self.onCancel = onCancel
        super.init(frame: .zero)
        setup(descriptor: descriptor)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setup(descriptor: MediaActionMenuDescriptor) {
        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.masksToBounds = true

        glassView.style = .regular
        glassView.cornerRadius = 12
        glassView.autoresizingMask = [.width, .height]
        addSubview(glassView)

        stack.orientation = .vertical
        stack.alignment = .width
        stack.spacing = 2
        stack.edgeInsets = NSEdgeInsets(top: 6, left: 6, bottom: 6, right: 6)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])

        for (secIdx, section) in descriptor.sections.enumerated() {
            if secIdx > 0 {
                let sep = NSBox()
                sep.boxType = .separator
                stack.addArrangedSubview(sep)
            }
            for action in section.actions {
                guard case .play(let intent, let title, let symbolName, _) = action else { continue }
                let rowIdx = itemRows.count
                let row = MediaPlayMenuRowView(title: title, symbolName: symbolName)
                row.onHover = { [weak self] inside in
                    if inside { self?.setHighlighted(rowIdx) }
                }
                row.onActivate = { [weak self] in
                    self?.onSelect(intent)
                }
                stack.addArrangedSubview(row)
                itemRows.append((intent, row))
            }
        }

        setHighlighted(0)
        updateSurfaceMode()
    }

    private func updateSurfaceMode() {
        let useGlass = GlassInteractionCoordinator.shared.isEnhancedMode && !MotionCoordinator.shared.isReduceTransparencyEnabled
        glassView.isHidden = !useGlass
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let useGlass = GlassInteractionCoordinator.shared.isEnhancedMode && !MotionCoordinator.shared.isReduceTransparencyEnabled
        if useGlass { return }

        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 12, yRadius: 12)
        NSColor(srgbRed: 26/255.0, green: 28/255.0, blue: 32/255.0, alpha: 0.97).setFill()
        path.fill()
        NSColor(white: 1.0, alpha: 0.25).setStroke()
        path.lineWidth = 1.0
        path.stroke()
    }

    override func layout() {
        super.layout()
        glassView.frame = bounds
    }

    private func setHighlighted(_ index: Int) {
        guard !itemRows.isEmpty else { return }
        highlightedIndex = max(0, min(index, itemRows.count - 1))
        for (i, item) in itemRows.enumerated() {
            item.view.setHighlighted(i == highlightedIndex)
        }
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 125: // Down
            setHighlighted((highlightedIndex + 1) % max(1, itemRows.count))
        case 126: // Up
            setHighlighted((highlightedIndex - 1 + itemRows.count) % max(1, itemRows.count))
        case 36, 49: // Return / Space
            if itemRows.indices.contains(highlightedIndex) {
                onSelect(itemRows[highlightedIndex].intent)
            }
        case 53: // Escape
            onCancel()
        default:
            super.keyDown(with: event)
        }
    }
}

@MainActor
private final class MediaPlayMenuRowView: NSView {
    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: 210, height: 28) }

    var onHover: ((Bool) -> Void)?
    var onActivate: (() -> Void)?

    private let iconView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private var trackingArea: NSTrackingArea?
    private var isHighlighted: Bool = false

    init(title: String, symbolName: String) {
        super.init(frame: NSRect(x: 0, y: 0, width: 210, height: 28))
        wantsLayer = true
        layer?.cornerRadius = 7

        iconView.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: title)
        iconView.contentTintColor = NSColor(white: 0.95, alpha: 1.0)
        addSubview(iconView)

        titleLabel.stringValue = title
        titleLabel.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        titleLabel.textColor = NSColor(white: 0.96, alpha: 1.0)
        titleLabel.lineBreakMode = .byTruncatingTail
        addSubview(titleLabel)

        setAccessibilityRole(.menuItem)
        setAccessibilityLabel(title)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func setHighlighted(_ highlighted: Bool) {
        isHighlighted = highlighted
        layer?.backgroundColor = highlighted ? NSColor(white: 1.0, alpha: 0.14).cgColor : NSColor.clear.cgColor
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow], owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        onHover?(true)
    }

    override func mouseExited(with event: NSEvent) {
        onHover?(false)
    }

    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) {
            onActivate?()
        }
    }

    override func layout() {
        super.layout()
        iconView.frame = NSRect(x: 10, y: (bounds.height - 14) / 2, width: 14, height: 14)
        titleLabel.frame = NSRect(x: 32, y: (bounds.height - 17) / 2, width: max(40, bounds.width - 42), height: 17)
    }
}
