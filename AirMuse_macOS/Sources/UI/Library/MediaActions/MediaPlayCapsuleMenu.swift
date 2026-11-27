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
    public var onSelectAction: ((MediaAction) -> Void)?
    public var menuDescriptorProvider: (() -> MediaActionMenuDescriptor)?

    private let button = NSButton()
    private var popoverController: MediaPlayMenuPopoverController?
    private var isMenuOpen: Bool = false

    public var titleText: String = "播放" {
        didSet { updateButtonTitle() }
    }
    public var isIconOnly: Bool = false {
        didSet { updateButtonTitle() }
    }
    public var usesTransparentBackground: Bool = false {
        didSet { updateMaterialMode() }
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
        if usesTransparentBackground {
            layer?.backgroundColor = NSColor.clear.cgColor
            return
        }
        let useGlass = GlassInteractionCoordinator.shared.isEnhancedMode && !MotionCoordinator.shared.isReduceTransparencyEnabled
        if useGlass {
            layer?.backgroundColor = NSColor(red: 0.98, green: 0.22, blue: 0.35, alpha: 0.88).cgColor
        } else {
            layer?.backgroundColor = NSColor(red: 0.98, green: 0.22, blue: 0.35, alpha: 0.95).cgColor
        }
    }

    private func updateButtonTitle() {
        if isIconOnly {
            button.attributedTitle = NSAttributedString(string: "")
            button.title = ""
            button.image = NSImage(systemSymbolName: "play.fill", accessibilityDescription: "播放与操作")?
                .withSymbolConfiguration(.init(pointSize: 13.5, weight: .semibold))
            button.contentTintColor = NSColor(red: 0.98, green: 0.25, blue: 0.38, alpha: 1.0)
            button.toolTip = "播放与更多操作"
            button.setAccessibilityTitle("播放与更多操作")
            return
        }
        button.image = nil
        button.contentTintColor = .white
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

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil && isMenuOpen {
            popoverController?.dismiss(returnFocus: false)
        }
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
            return
        }

        // Single-action (e.g. station "收听") executes directly only if enabled
        if descriptor.allActions.count == 1,
           let onlyAction = descriptor.allActions.first,
           onlyAction.isEnabled,
           case .play(let intent, _, _, _) = onlyAction {
            onSelectAction?(onlyAction)
            onSelectIntent?(intent)
            return
        }

        let controller = MediaPlayMenuPopoverController(
            descriptor: descriptor,
            anchorView: self,
            onSelect: { [weak self] action in
                self?.onSelectAction?(action)
                if case .play(let intent, _, _, _) = action {
                    self?.onSelectIntent?(intent)
                }
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

    public func refreshMenuIfOpen() {
        guard isMenuOpen,
              let descriptor = menuDescriptorProvider?(),
              !descriptor.isEmpty else { return }
        popoverController?.updateDescriptor(descriptor)
    }
}

// MARK: - MediaPlayMenuPopoverController

@MainActor
private final class MediaPlayMenuPopoverController: NSObject {
    private var descriptor: MediaActionMenuDescriptor
    private weak var anchorView: NSView?
    private let onSelect: (MediaAction) -> Void
    private let onDismissed: () -> Void

    private var panel: NSPanel?
    private var surfaceView: MediaPlayMenuSurfaceView?
    private var localMonitor: Any?
    private var notificationObservers: [NSObjectProtocol] = []
    private var isClosing: Bool = false
    private var hasSelected: Bool = false
    private var animationGeneration: UInt64 = 0

    init(
        descriptor: MediaActionMenuDescriptor,
        anchorView: NSView,
        onSelect: @escaping (MediaAction) -> Void,
        onDismissed: @escaping () -> Void
    ) {
        self.descriptor = descriptor
        self.anchorView = anchorView
        self.onSelect = onSelect
        self.onDismissed = onDismissed
    }

    func updateDescriptor(_ newDescriptor: MediaActionMenuDescriptor) {
        guard !isClosing, let panel else { return }
        self.descriptor = newDescriptor
        let surface = MediaPlayMenuSurfaceView(descriptor: newDescriptor) { [weak self] action in
            guard let self, !self.isClosing, !self.hasSelected else { return }
            self.hasSelected = true
            self.dismiss(returnFocus: true)
            self.onSelect(action)
        } onCancel: { [weak self] in
            self?.dismiss(returnFocus: true)
        }
        self.surfaceView = surface
        let targetSize = surface.fittingSize
        var frame = panel.frame
        let topY = frame.maxY
        frame.size = targetSize
        frame.origin.y = topY - targetSize.height
        panel.setFrame(frame, display: true)
        panel.contentView = surface
        panel.makeFirstResponder(surface)
    }

    func present() {
        guard let anchorView, let parentWindow = anchorView.window else {
            onDismissed()
            return
        }

        let surface = MediaPlayMenuSurfaceView(descriptor: descriptor) { [weak self] action in
            guard let self, !self.isClosing, !self.hasSelected else { return }
            self.hasSelected = true
            self.dismiss(returnFocus: true)
            self.onSelect(action)
        } onCancel: { [weak self] in
            self?.dismiss(returnFocus: true)
        }
        self.surfaceView = surface

        let targetSize = surface.fittingSize
        let anchorRectInWin = anchorView.convert(anchorView.bounds, to: nil)
        let anchorRectInScreen = parentWindow.convertToScreen(anchorRectInWin)
        let visibleFrame = parentWindow.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? parentWindow.frame

        var originX = anchorRectInScreen.maxX - targetSize.width
        var originY = anchorRectInScreen.minY - targetSize.height - 6

        // Clamp within visible screen bounds (multi-display safe)
        originX = max(visibleFrame.minX + 8, min(originX, visibleFrame.maxX - targetSize.width - 8))
        if originY < visibleFrame.minY + 8 {
            originY = min(anchorRectInScreen.maxY + 6, visibleFrame.maxY - targetSize.height - 8)
        }
        originY = max(visibleFrame.minY + 8, originY)

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

        let nc = NotificationCenter.default
        notificationObservers.append(nc.addObserver(forName: NSWindow.willCloseNotification, object: parentWindow, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.dismiss(returnFocus: false) }
        })
        notificationObservers.append(nc.addObserver(forName: NSWindow.didMiniaturizeNotification, object: parentWindow, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.dismiss(returnFocus: false) }
        })
        notificationObservers.append(nc.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.dismiss(returnFocus: false) }
        })
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
        for obs in notificationObservers {
            NotificationCenter.default.removeObserver(obs)
        }
        notificationObservers.removeAll()

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
    private var itemRows: [(action: MediaAction, view: MediaPlayMenuRowView)] = []
    private var highlightedIndex: Int = 0
    private let onSelect: (MediaAction) -> Void
    private let onCancel: () -> Void

    init(
        descriptor: MediaActionMenuDescriptor,
        onSelect: @escaping (MediaAction) -> Void,
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

        glassView.style = .regular
        glassView.cornerRadius = 14
        glassView.autoresizingMask = [.width, .height]
        addSubview(glassView)

        stack.orientation = .vertical
        stack.alignment = .width
        stack.spacing = 4
        stack.edgeInsets = NSEdgeInsets(top: 10, left: 10, bottom: 10, right: 10)
        stack.translatesAutoresizingMaskIntoConstraints = false
        glassView.contentView = stack

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: glassView.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: glassView.trailingAnchor),
            stack.topAnchor.constraint(equalTo: glassView.topAnchor),
            stack.bottomAnchor.constraint(equalTo: glassView.bottomAnchor)
        ])

        // Extract top quick-action bar: [Library, Favorite, Primary Play] when library or favorite actions exist
        let allActions = descriptor.allActions
        let libraryAction = allActions.first {
            switch $0 {
            case .addToLibrary, .removeFromLibrary, .libraryStatusPlaceholder: return true
            default: return false
            }
        }
        let favoriteAction = allActions.first {
            switch $0 {
            case .favorite, .unfavorite, .favoriteStatusPlaceholder: return true
            default: return false
            }
        }
        let primaryPlayAction = allActions.first {
            if case .play(let intent, _, _, _) = $0, intent == .replaceAndPlay { return true }
            return false
        }

        let hasTopQuickBar = (libraryAction != nil || favoriteAction != nil)
        var consumedTopActions: [MediaAction] = []
        if hasTopQuickBar {
            let quickBar = NSStackView()
            quickBar.orientation = .horizontal
            quickBar.distribution = .fillEqually
            quickBar.spacing = 8
            quickBar.edgeInsets = NSEdgeInsets(top: 2, left: 0, bottom: 4, right: 0)

            if let libAct = libraryAction {
                let libTint: NSColor? = {
                    if case .removeFromLibrary = libAct {
                        return NSColor(red: 0.35, green: 0.78, blue: 1.0, alpha: 1.0)
                    }
                    return nil
                }()
                quickBar.addArrangedSubview(makeQuickIconButton(for: libAct, shortLabel: shortQuickLabel(for: libAct), tint: libTint))
                consumedTopActions.append(libAct)
            }
            if let favAct = favoriteAction {
                let favTint: NSColor? = {
                    if case .unfavorite = favAct {
                        return NSColor(red: 1.0, green: 0.76, blue: 0.25, alpha: 1.0)
                    }
                    return nil
                }()
                quickBar.addArrangedSubview(makeQuickIconButton(for: favAct, shortLabel: shortQuickLabel(for: favAct), tint: favTint))
                consumedTopActions.append(favAct)
            }
            if let playAct = primaryPlayAction {
                quickBar.addArrangedSubview(
                    makeQuickIconButton(
                        for: playAct,
                        shortLabel: "播放",
                        tint: NSColor(red: 0.98, green: 0.25, blue: 0.38, alpha: 1.0),
                        isAccent: true
                    )
                )
                consumedTopActions.append(playAct)
            }
            stack.addArrangedSubview(quickBar)
            stack.addArrangedSubview(makeHairlineDivider())
        }

        var renderedSectionCount = 0
        for section in descriptor.sections {
            let remaining = section.actions.filter { act in
                !consumedTopActions.contains(act)
            }
            guard !remaining.isEmpty else { continue }
            if renderedSectionCount > 0 {
                stack.addArrangedSubview(makeHairlineDivider())
            }
            renderedSectionCount += 1
            for action in remaining {
                if case .navigateToArtistsSubmenu(let artists) = action {
                    for artist in artists {
                        let subAction = MediaAction.navigateToArtist(artist)
                        appendRow(for: subAction, titleOverride: "查看歌手：\(artist.name)")
                    }
                    continue
                }
                appendRow(for: action, titleOverride: nil)
            }
        }

        if let firstEnabled = itemRows.firstIndex(where: { $0.action.isEnabled }) {
            setHighlighted(firstEnabled)
        }
        updateSurfaceMode()
    }

    private func shortQuickLabel(for action: MediaAction) -> String {
        switch action {
        case .addToLibrary: return "入库"
        case .removeFromLibrary: return "已入库"
        case .libraryStatusPlaceholder: return "资料库"
        case .favorite: return "收藏"
        case .unfavorite: return "已收藏"
        case .favoriteStatusPlaceholder: return "收藏"
        case .play: return "播放"
        default: return action.title
        }
    }

    private func makeHairlineDivider() -> NSView {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        let line = NSView()
        line.wantsLayer = true
        line.layer?.backgroundColor = NSColor(white: 1.0, alpha: 0.12).cgColor
        line.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(line)
        NSLayoutConstraint.activate([
            container.heightAnchor.constraint(equalToConstant: 9),
            line.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 6),
            line.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -6),
            line.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            line.heightAnchor.constraint(equalToConstant: 1)
        ])
        return container
    }

    private func makeQuickIconButton(for action: MediaAction, shortLabel: String, tint: NSColor? = nil, isAccent: Bool = false) -> NSView {
        let btn = MediaQuickActionIconButton(action: action, shortLabel: shortLabel, tint: tint, isAccent: isAccent)
        if action.isEnabled {
            btn.onActivate = { [weak self] in
                self?.onSelect(action)
            }
        }
        return btn
    }

    private func appendRow(for action: MediaAction, titleOverride: String?) {
        let rowIdx = itemRows.count
        let row = MediaPlayMenuRowView(
            title: titleOverride ?? action.title,
            symbolName: action.symbolName,
            isEnabled: action.isEnabled
        )
        if action.isEnabled {
            row.onHover = { [weak self] inside in
                if inside { self?.setHighlighted(rowIdx) }
            }
            row.onActivate = { [weak self] in
                self?.onSelect(action)
            }
        }
        stack.addArrangedSubview(row)
        itemRows.append((action, row))
    }

    private func updateSurfaceMode() {
        let useGlass = !MotionCoordinator.shared.isReduceTransparencyEnabled
        glassView.isHidden = !useGlass
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let useGlass = !MotionCoordinator.shared.isReduceTransparencyEnabled
        if useGlass { return }

        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 14, yRadius: 14)
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
            if itemRows.indices.contains(highlightedIndex), itemRows[highlightedIndex].action.isEnabled {
                onSelect(itemRows[highlightedIndex].action)
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
    override var intrinsicContentSize: NSSize { NSSize(width: 224, height: 30) }

    var onHover: ((Bool) -> Void)?
    var onActivate: (() -> Void)?

    private let iconView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private var trackingArea: NSTrackingArea?
    private var isHighlighted: Bool = false
    private let isRowEnabled: Bool

    init(title: String, symbolName: String, isEnabled: Bool = true) {
        self.isRowEnabled = isEnabled
        super.init(frame: NSRect(x: 0, y: 0, width: 224, height: 30))
        wantsLayer = true
        layer?.cornerRadius = 8

        let cfg = NSImage.SymbolConfiguration(pointSize: 12.5, weight: .medium)
        iconView.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: title)?
            .withSymbolConfiguration(cfg)
        iconView.imageScaling = .scaleProportionallyDown
        iconView.contentTintColor = isEnabled ? NSColor(white: 0.94, alpha: 1.0) : NSColor(white: 0.50, alpha: 1.0)
        addSubview(iconView)

        titleLabel.stringValue = title
        titleLabel.font = NSFont.systemFont(ofSize: 12.5, weight: .medium)
        titleLabel.textColor = isEnabled ? NSColor(white: 0.96, alpha: 1.0) : NSColor(white: 0.50, alpha: 1.0)
        titleLabel.lineBreakMode = .byTruncatingTail
        addSubview(titleLabel)

        setAccessibilityRole(.menuItem)
        setAccessibilityLabel(title)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func setHighlighted(_ highlighted: Bool) {
        guard isRowEnabled else { return }
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
        iconView.frame = NSRect(x: 10, y: (bounds.height - 15) / 2, width: 15, height: 15)
        titleLabel.frame = NSRect(x: 33, y: (bounds.height - 16) / 2, width: max(40, bounds.width - 43), height: 16)
    }
}

@MainActor
private final class MediaQuickActionIconButton: NSView {
    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: 68, height: 50) }

    var onActivate: (() -> Void)?
    private let iconView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private var trackingArea: NSTrackingArea?
    private let isActionEnabled: Bool
    private let isAccent: Bool
    private var isHovered: Bool = false

    init(action: MediaAction, shortLabel: String, tint: NSColor? = nil, isAccent: Bool = false) {
        self.isActionEnabled = action.isEnabled
        self.isAccent = isAccent
        super.init(frame: NSRect(x: 0, y: 0, width: 68, height: 50))
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.borderWidth = 0.75
        updateBackground()

        let activeTint = tint ?? (action.isEnabled ? NSColor(white: 0.96, alpha: 1.0) : NSColor(white: 0.50, alpha: 1.0))
        let cfg = NSImage.SymbolConfiguration(pointSize: 14.5, weight: .semibold)
        iconView.image = NSImage(systemSymbolName: action.symbolName, accessibilityDescription: action.title)?
            .withSymbolConfiguration(cfg)
        iconView.imageScaling = .scaleProportionallyDown
        iconView.contentTintColor = activeTint
        addSubview(iconView)

        titleLabel.stringValue = shortLabel
        titleLabel.font = NSFont.systemFont(ofSize: 10.5, weight: .medium)
        titleLabel.alignment = .center
        titleLabel.textColor = action.isEnabled ? NSColor(white: 0.88, alpha: 1.0) : NSColor(white: 0.48, alpha: 1.0)
        titleLabel.lineBreakMode = .byTruncatingTail
        addSubview(titleLabel)

        toolTip = action.title
        setAccessibilityRole(.button)
        setAccessibilityLabel(action.title)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func updateBackground() {
        if !isActionEnabled {
            layer?.backgroundColor = NSColor(white: 1.0, alpha: 0.04).cgColor
            layer?.borderColor = NSColor(white: 1.0, alpha: 0.06).cgColor
        } else if isAccent {
            layer?.backgroundColor = NSColor(red: 0.98, green: 0.25, blue: 0.38, alpha: isHovered ? 0.24 : 0.16).cgColor
            layer?.borderColor = NSColor(red: 0.98, green: 0.25, blue: 0.38, alpha: isHovered ? 0.42 : 0.28).cgColor
        } else {
            layer?.backgroundColor = NSColor(white: 1.0, alpha: isHovered ? 0.16 : 0.08).cgColor
            layer?.borderColor = NSColor(white: 1.0, alpha: isHovered ? 0.20 : 0.10).cgColor
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow], owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        guard isActionEnabled else { return }
        isHovered = true
        updateBackground()
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        updateBackground()
    }

    override func mouseUp(with event: NSEvent) {
        guard isActionEnabled else { return }
        if bounds.contains(convert(event.locationInWindow, from: nil)) {
            onActivate?()
        }
    }

    override func layout() {
        super.layout()
        let w = bounds.width
        iconView.frame = NSRect(x: (w - 18) * 0.5, y: 8, width: 18, height: 18)
        titleLabel.frame = NSRect(x: 4, y: 29, width: max(20, w - 8), height: 14)
    }
}
