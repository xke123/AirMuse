import AppKit
import Domain
import Playback
import DesignSystem
import Infrastructure

// MARK: - Drag Pasteboard Type

private extension NSPasteboard.PasteboardType {
    static let airMuseQueueEntryIDs = NSPasteboard.PasteboardType("com.airmuse.queue.entryIDs")
}

// MARK: - QueueTableView

private final class QueueTableView: NSTableView {
    var onDeleteKey: (() -> Void)?
    var onEscapeKey: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 51 || event.keyCode == 117 { // Backspace or Forward Delete
            if selectedRowIndexes.count > 0 {
                onDeleteKey?()
                return
            }
        } else if event.keyCode == 53 { // Escape
            onEscapeKey?()
            return
        }
        super.keyDown(with: event)
    }
}

// MARK: - QueueEntryCellView

private final class QueueEntryCellView: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("QueueEntryCellView")

    private let artView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let artistLabel = NSTextField(labelWithString: "")
    private var currentEntryID: UUID?
    private var artworkTask: Task<Void, Never>?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupViews()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        artworkTask?.cancel()
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        artworkTask?.cancel()
        artworkTask = nil
        currentEntryID = nil
        artView.image = NSImage(systemSymbolName: "music.note", accessibilityDescription: nil)
    }

    private func setupViews() {
        wantsLayer = true
        artView.wantsLayer = true
        artView.layer?.cornerRadius = 4
        artView.layer?.masksToBounds = true
        artView.imageScaling = .scaleProportionallyUpOrDown
        artView.image = NSImage(systemSymbolName: "music.note", accessibilityDescription: nil)
        addSubview(artView)

        titleLabel.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        titleLabel.textColor = .labelColor
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.cell?.truncatesLastVisibleLine = true
        addSubview(titleLabel)

        artistLabel.font = NSFont.systemFont(ofSize: 10.5, weight: .regular)
        artistLabel.textColor = .secondaryLabelColor
        artistLabel.lineBreakMode = .byTruncatingTail
        artistLabel.cell?.truncatesLastVisibleLine = true
        addSubview(artistLabel)
    }

    override func layout() {
        super.layout()
        let h = bounds.height
        let w = bounds.width
        let artSize: CGFloat = 28
        artView.frame = NSRect(x: 6, y: (h - artSize) * 0.5, width: artSize, height: artSize)
        let textX: CGFloat = 40
        let textW = max(20, w - textX - 8)
        titleLabel.frame = NSRect(x: textX, y: h * 0.5, width: textW, height: 15)
        artistLabel.frame = NSRect(x: textX, y: h * 0.5 - 14, width: textW, height: 13)
    }

    func configure(with entry: QueueEntry) {
        currentEntryID = entry.id
        titleLabel.stringValue = entry.track.title
        artistLabel.stringValue = entry.track.artistName
        toolTip = "\(entry.track.title) — \(entry.track.artistName)\n来源: \(entry.origin.displayTitle)"

        artworkTask?.cancel()
        if let url = entry.track.artworkURL {
            let expectedID = entry.id
            artworkTask = Task { [weak self] in
                if let img = await ImageCacheV2.shared.image(for: url, targetPixelSize: 64),
                   !Task.isCancelled,
                   self?.currentEntryID == expectedID {
                    self?.artView.image = img
                }
            }
        } else {
            artView.image = NSImage(systemSymbolName: "music.note", accessibilityDescription: entry.track.title)
        }
    }
}

@MainActor
private final class FlippedDockContentView: NSView {
    override var isFlipped: Bool { true }
}

// MARK: - QueueAdditionVisualKind

/// Visual animation motif distinguishing what kind of media resource was added to the queue.
public enum QueueAdditionVisualKind: Sendable, Equatable {
    case song
    case multiSongs(count: Int)
    case album
    case playlist
    case station
}

// MARK: - LiquidFusionQueueDockView

/// Bottom-right Liquid Fusion Dock queue control & expandable upcoming queue overlay.
/// Uses native `NSGlassEffectContainerView` + `NSGlassEffectView` on macOS 26+ with
/// interruptible morph geometry, keyboard/drag support, and zero-overhead idle state.
@MainActor
public final class LiquidFusionQueueDockView: NSView, NSTableViewDataSource, NSTableViewDelegate {

    // MARK: - Public Callbacks & State

    public var onNavigateToOrigin: ((PlaybackOrigin) -> Void)?
    public var onQueueMediaAction: ((MediaAction) -> Void)?
    public var queueContextBuilder: ((MediaResourceReference, [UUID]) -> MediaActionContext)?
    public var onReportError: ((String) -> Void)?
    public var onRetryPagination: (() -> Void)?
    public private(set) var isExpanded: Bool = false

    private let coordinator: PlaybackCoordinatorV2
    private var snapshot: QueueSnapshot = .empty
    private var displayedEntries: [QueueEntry] = []
    private var streamTask: Task<Void, Never>?
    private var feedbackTask: Task<Void, Never>?
    private var transientFeedbackMessage: String?
    private var localClickMonitor: Any?
    private var mouseUpSwallowMonitor: Any?
    private let motionOwnerID = "QueueDock-\(UUID().uuidString)"
    private var isAnimatingMorph: Bool = false
    private var isCollapsedHovered: Bool = false
    private var collapsedTrackingArea: NSTrackingArea?
    private var lastObservedQueueCount: Int = 0
    private var hasObservedInitialSnapshot: Bool = false
    private var lastExplicitAnimationAt: CFTimeInterval = 0

    // MARK: - Native Glass Hierarchy

    private let glassContainer = NSGlassEffectContainerView(frame: .zero)
    private let morphGlassView = NSGlassEffectView(frame: .zero)
    private let glassContentView = NSView(frame: .zero)
    private let reduceTransparencyFallbackView = NSView(frame: .zero)

    // Floating Toast Pill (appears above the queue button)
    private let toastGlassView = NSGlassEffectView(frame: .zero)
    private let toastFallbackView = NSView(frame: .zero)
    private let toastLabel = NSTextField(labelWithString: "")

    // Collapsed trigger (embedded cleanly on bottom glass bar at rest; glass activates on hover/expand)
    private let collapsedOverlayView = NSView(frame: .zero)
    private let toggleIconView = NSImageView(frame: .zero)
    private let countLabel = NSTextField(labelWithString: "")
    private let toggleButton = NSButton(frame: .zero)

    // Expanded content container (inside morphGlassView.contentView)
    private let expandedContentView = FlippedDockContentView(frame: .zero)
    private let toolbarView = NSView(frame: .zero)
    private let clearButton = NSButton(frame: .zero)
    private let undoButton = NSButton(frame: .zero)
    private let shuffleButton = NSButton(frame: .zero)
    private let repeatOneButton = NSButton(frame: .zero)
    private let repeatAllButton = NSButton(frame: .zero)
    private let statusLabel = NSTextField(labelWithString: "")
    private let retryButton = NSButton(frame: .zero)
    private let scrollView = NSScrollView(frame: .zero)
    private let tableView = QueueTableView(frame: .zero)
    private let emptyStateLabel = NSTextField(labelWithString: "待播队列为空")

    // Metrics (QUEUE_UI.md)
    private let buttonSize: CGFloat = 24
    private let cornerMargin: CGFloat = 10
    public var bottomBarHeight: CGFloat = 30 {
        didSet {
            guard oldValue != bottomBarHeight else { return }
            needsLayout = true
        }
    }

    public init(coordinator: PlaybackCoordinatorV2) {
        self.coordinator = coordinator
        super.init(frame: .zero)
        setupUI()
        startObservingQueue()
    }

    public required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    isolated deinit {
        streamTask?.cancel()
        feedbackTask?.cancel()
        if let monitor = localClickMonitor {
            NSEvent.removeMonitor(monitor)
        }
        if let upMonitor = mouseUpSwallowMonitor {
            NSEvent.removeMonitor(upMonitor)
        }
        MotionCoordinator.shared.cancelAll(owner: motionOwnerID)
    }

    // MARK: - Hit Testing

    /// Intercepts clicks on the capsule button when collapsed (never falling through),
    /// and absorbs all clicks inside the panel when expanded so outside clicks only dismiss.
    public override func hitTest(_ point: NSPoint) -> NSView? {
        let localPt = convert(point, from: superview)
        if isExpanded {
            if morphGlassView.frame.contains(localPt) {
                return super.hitTest(point) ?? expandedContentView
            }
            return bounds.contains(localPt) ? self : nil
        } else {
            guard collapsedOverlayView.frame.contains(localPt) else {
                return nil
            }
            return toggleButton
        }
    }

    public override func mouseDown(with event: NSEvent) {
        if isExpanded {
            let pt = convert(event.locationInWindow, from: nil)
            if !morphGlassView.frame.contains(pt) {
                setExpanded(false)
                return
            }
        }
        super.mouseDown(with: event)
    }

    public override func rightMouseDown(with event: NSEvent) {
        if isExpanded {
            let pt = convert(event.locationInWindow, from: nil)
            if !morphGlassView.frame.contains(pt) {
                setExpanded(false)
                return
            }
        }
        super.rightMouseDown(with: event)
    }

    // MARK: - Setup

    private func setupUI() {
        wantsLayer = true

        glassContainer.spacing = 6
        addSubview(glassContainer)

        morphGlassView.style = .clear
        morphGlassView.cornerRadius = buttonSize * 0.5
        morphGlassView.isHidden = true
        glassContentView.wantsLayer = true
        morphGlassView.contentView = glassContentView
        glassContainer.addSubview(morphGlassView)

        reduceTransparencyFallbackView.wantsLayer = true
        reduceTransparencyFallbackView.layer?.backgroundColor = NSColor(calibratedWhite: 0.12, alpha: 0.96).cgColor
        reduceTransparencyFallbackView.layer?.cornerRadius = buttonSize * 0.5
        reduceTransparencyFallbackView.layer?.borderWidth = 0.5
        reduceTransparencyFallbackView.layer?.borderColor = NSColor(white: 1.0, alpha: 0.16).cgColor
        reduceTransparencyFallbackView.isHidden = true
        glassContentView.addSubview(reduceTransparencyFallbackView)

        // Collapsed trigger (`music.note.list` + queue count + full-capsule hit button) embedded on bottom glass bar
        collapsedOverlayView.wantsLayer = true
        addSubview(collapsedOverlayView)

        let symCfg = NSImage.SymbolConfiguration(pointSize: 12.0, weight: .semibold)
        toggleIconView.image = NSImage(systemSymbolName: "music.note.list", accessibilityDescription: "播放队列")?.withSymbolConfiguration(symCfg)
        toggleIconView.contentTintColor = .labelColor
        collapsedOverlayView.addSubview(toggleIconView)

        countLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 10.5, weight: .semibold)
        countLabel.textColor = .labelColor
        countLabel.alignment = .center
        countLabel.isHidden = true
        countLabel.isBezeled = false
        countLabel.drawsBackground = false
        countLabel.isEditable = false
        countLabel.isSelectable = false
        collapsedOverlayView.addSubview(countLabel)

        toggleButton.isBordered = false
        toggleButton.bezelStyle = .regularSquare
        toggleButton.focusRingType = .none
        toggleButton.title = ""
        toggleButton.image = nil
        toggleButton.toolTip = "播放队列"
        toggleButton.setAccessibilityLabel("播放队列")
        toggleButton.target = self
        toggleButton.action = #selector(toggleExpanded)
        collapsedOverlayView.addSubview(toggleButton)

        // Floating Toast Pill
        toastGlassView.style = .regular
        toastGlassView.cornerRadius = 13
        toastGlassView.isHidden = true
        toastGlassView.alphaValue = 0
        addSubview(toastGlassView)

        toastFallbackView.wantsLayer = true
        toastFallbackView.layer?.backgroundColor = NSColor(srgbRed: 28 / 255.0, green: 30 / 255.0, blue: 34 / 255.0, alpha: 0.94).cgColor
        toastFallbackView.layer?.cornerRadius = 13
        toastFallbackView.layer?.borderWidth = 0.5
        toastFallbackView.layer?.borderColor = NSColor(white: 1.0, alpha: 0.16).cgColor
        toastFallbackView.isHidden = true
        toastGlassView.addSubview(toastFallbackView)

        toastLabel.font = NSFont.systemFont(ofSize: 11.5, weight: .medium)
        toastLabel.textColor = NSColor(white: 0.96, alpha: 1.0)
        toastLabel.lineBreakMode = .byTruncatingTail
        toastLabel.alignment = .center
        toastGlassView.contentView = toastLabel

        // Expanded content
        expandedContentView.wantsLayer = true
        expandedContentView.isHidden = true
        expandedContentView.alphaValue = 0
        glassContentView.addSubview(expandedContentView)

        setupToolbar()
        setupTableView()
        applyAccessibilityAndTransparencyStyle()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(accessibilityDidChange),
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil
        )
    }

    private func setupToolbar() {
        expandedContentView.addSubview(toolbarView)

        configureToolbarButton(clearButton, symbol: "trash", tooltip: "清空待播队列", action: #selector(clearClicked))
        configureToolbarButton(undoButton, symbol: "arrow.uturn.backward", tooltip: "撤销", action: #selector(undoClicked))
        undoButton.isHidden = true

        configureToolbarButton(shuffleButton, symbol: "shuffle", tooltip: "随机播放", action: #selector(shuffleClicked))
        configureToolbarButton(repeatOneButton, symbol: "repeat.1", tooltip: "单曲循环", action: #selector(repeatOneClicked))
        configureToolbarButton(repeatAllButton, symbol: "repeat", tooltip: "列表循环", action: #selector(repeatAllClicked))

        toolbarView.addSubview(clearButton)
        toolbarView.addSubview(undoButton)
        toolbarView.addSubview(shuffleButton)
        toolbarView.addSubview(repeatOneButton)
        toolbarView.addSubview(repeatAllButton)

        statusLabel.font = NSFont.systemFont(ofSize: 10.5, weight: .medium)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail
        expandedContentView.addSubview(statusLabel)

        retryButton.title = "重试"
        retryButton.bezelStyle = .inline
        retryButton.font = NSFont.systemFont(ofSize: 10.5, weight: .semibold)
        retryButton.target = self
        retryButton.action = #selector(retryClicked)
        retryButton.isHidden = true
        expandedContentView.addSubview(retryButton)
    }

    private func configureToolbarButton(_ btn: NSButton, symbol: String, tooltip: String, action: Selector) {
        btn.isBordered = false
        btn.wantsLayer = true
        btn.layer?.cornerRadius = 6
        btn.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tooltip)
        btn.toolTip = tooltip
        btn.target = self
        btn.action = action
    }

    private func setupTableView() {
        let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("QueueColumn"))
        col.resizingMask = .autoresizingMask
        tableView.addTableColumn(col)
        tableView.headerView = nil
        tableView.rowHeight = 38
        tableView.backgroundColor = .clear
        tableView.selectionHighlightStyle = .regular
        tableView.allowsMultipleSelection = true
        tableView.dataSource = self
        tableView.delegate = self
        tableView.doubleAction = #selector(tableDoubleClicked)
        tableView.target = self
        tableView.registerForDraggedTypes([.airMuseQueueEntryIDs])
        tableView.setDraggingSourceOperationMask(.move, forLocal: true)
        tableView.onDeleteKey = { [weak self] in self?.removeSelectedEntries() }
        tableView.onEscapeKey = { [weak self] in self?.setExpanded(false) }

        let menu = NSMenu()
        menu.delegate = self
        tableView.menu = menu

        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.documentView = tableView
        expandedContentView.addSubview(scrollView)

        emptyStateLabel.font = NSFont.systemFont(ofSize: 12, weight: .regular)
        emptyStateLabel.textColor = .secondaryLabelColor
        emptyStateLabel.alignment = .center
        expandedContentView.addSubview(emptyStateLabel)
    }

    // MARK: - Layout & Morph Geometry

    public override func layout() {
        super.layout()
        glassContainer.frame = bounds
        let targetRect = targetMorphRect(expanded: isExpanded)
        if !isAnimatingMorph {
            morphGlassView.frame = targetRect
            morphGlassView.cornerRadius = isExpanded ? 14 : buttonSize * 0.5
        }
        layoutMorphSubviews(in: morphGlassView.bounds)
    }

    private func collapsedWidth(for count: Int) -> CGFloat {
        guard count > 0 else { return buttonSize }
        let digits = count >= 1000 ? 4 : (count >= 100 ? 3 : (count >= 10 ? 2 : 1))
        return buttonSize + CGFloat(digits * 7 + 8)
    }

    private func targetMorphRect(expanded: Bool) -> NSRect {
        let w = bounds.width
        let h = bounds.height
        let barH = max(buttonSize + 4, bottomBarHeight)
        let collapsedY = max(2, (barH - buttonSize) * 0.5)
        if !expanded {
            let cw = collapsedWidth(for: displayedEntries.count)
            return NSRect(
                x: max(cornerMargin, w - cw - cornerMargin),
                y: collapsedY,
                width: cw,
                height: buttonSize
            )
        }
        let maxAvailW = max(120, w - cornerMargin * 2)
        let maxAvailH = max(120, h - barH * 2 - 12)
        let targetW = min(max(240, w * 0.5), maxAvailW)
        let targetH = min(max(220, h * 0.65), maxAvailH)
        return NSRect(
            x: max(cornerMargin, w - targetW - cornerMargin),
            y: collapsedY,
            width: targetW,
            height: targetH
        )
    }

    private func layoutMorphSubviews(in rect: NSRect) {
        reduceTransparencyFallbackView.frame = rect
        reduceTransparencyFallbackView.layer?.cornerRadius = isExpanded ? 14 : buttonSize * 0.5

        let collapsedRect = targetMorphRect(expanded: false)
        collapsedOverlayView.frame = collapsedRect
        toggleButton.frame = NSRect(x: 0, y: 0, width: collapsedRect.width, height: buttonSize)
        if displayedEntries.isEmpty {
            toggleIconView.frame = NSRect(x: max(0, (collapsedRect.width - 14) * 0.5), y: (buttonSize - 14) * 0.5, width: 14, height: 14)
            countLabel.isHidden = true
        } else {
            let cw = collapsedWidth(for: displayedEntries.count)
            let countW = max(14, cw - buttonSize - 4)
            if !isExpanded {
                toggleIconView.frame = NSRect(x: 7, y: (buttonSize - 14) * 0.5, width: 14, height: 14)
                countLabel.frame = NSRect(x: buttonSize - 1, y: (buttonSize - 14) * 0.5, width: countW, height: 14)
                countLabel.isHidden = false
            } else {
                countLabel.isHidden = true
            }
        }
        updateCollapsedTrackingArea()
        updateCollapsedGlassVisibility()
        layoutToast()

        expandedContentView.frame = rect
        let w = rect.width
        let h = rect.height
        let pad: CGFloat = 10
        let toolbarH: CGFloat = 28

        toolbarView.frame = NSRect(x: pad, y: h - toolbarH - 8, width: max(40, w - pad * 2), height: toolbarH)
        clearButton.frame = NSRect(x: 0, y: 2, width: 24, height: 24)
        undoButton.frame = NSRect(x: 28, y: 2, width: 24, height: 24)

        let tw = toolbarView.bounds.width
        repeatAllButton.frame = NSRect(x: tw - 24, y: 2, width: 24, height: 24)
        repeatOneButton.frame = NSRect(x: tw - 52, y: 2, width: 24, height: 24)
        shuffleButton.frame = NSRect(x: tw - 80, y: 2, width: 24, height: 24)

        let statusY = toolbarView.frame.minY - 20
        retryButton.frame = NSRect(x: w - pad - 44, y: statusY - 1, width: 44, height: 18)
        let statusW = retryButton.isHidden ? max(20, w - pad * 2) : max(20, w - pad * 2 - 48)
        statusLabel.frame = NSRect(x: pad, y: statusY, width: statusW, height: 16)

        let listH = max(20, statusY - 8)
        scrollView.frame = NSRect(x: 4, y: 6, width: max(40, w - 8), height: listH)
        if let col = tableView.tableColumns.first {
            col.width = max(40, scrollView.bounds.width - 4)
        }
        emptyStateLabel.frame = NSRect(x: pad, y: 6 + (listH - 20) * 0.5, width: max(40, w - pad * 2), height: 20)
    }

    // MARK: - Expand / Collapse (Interruptible Liquid Fusion Morph)

    @objc public func toggleExpanded() {
        setExpanded(!isExpanded)
    }

    public func setExpanded(_ expanded: Bool) {
        guard isExpanded != expanded else { return }
        isExpanded = expanded
        AppLogger.shared.log(
            category: .userAction,
            level: .info,
            message: "用户\(expanded ? "展开" : "收起") Liquid Fusion 播放队列浮层 (待播 \(displayedEntries.count) 首)"
        )

        if expanded {
            installOutsideClickMonitor()
            expandedContentView.isHidden = false
            collapsedOverlayView.isHidden = true
            toastGlassView.isHidden = true
            morphGlassView.isHidden = false
            morphGlassView.style = .regular
        } else {
            removeOutsideClickMonitor()
            collapsedOverlayView.isHidden = false
            countLabel.isHidden = displayedEntries.isEmpty
            morphGlassView.style = .clear
            if let win = window, win.firstResponder === tableView || win.firstResponder === toggleButton {
                win.makeFirstResponder(nil)
            }
        }

        let targetFrame = targetMorphRect(expanded: expanded)
        let targetRadius: CGFloat = expanded ? 14 : buttonSize * 0.5
        let key = TransitionKey(owner: motionOwnerID, channel: "queueDock")
        let ticket = MotionCoordinator.shared.beginTransition(for: key, category: .stageGeometry)

        if MotionCoordinator.shared.isReduceMotionEnabled || window == nil || isHidden {
            isAnimatingMorph = false
            morphGlassView.frame = targetFrame
            morphGlassView.cornerRadius = targetRadius
            expandedContentView.alphaValue = expanded ? 1.0 : 0.0
            expandedContentView.isHidden = !expanded
            layoutMorphSubviews(in: morphGlassView.bounds)
            _ = MotionCoordinator.shared.complete(ticket)
            return
        }

        isAnimatingMorph = true
        // Capture live presentation frame for seamless mid-flight reversal
        if let presFrame = morphGlassView.layer?.presentation()?.frame, presFrame.width > 0 {
            morphGlassView.frame = presFrame
        }

        let duration = expanded ? 0.36 : 0.30
        MotionCoordinator.shared.animate(
            duration: duration,
            timingFunction: .easeInEaseOut,
            ticket: ticket,
            action: {
                self.morphGlassView.animator().frame = targetFrame
                self.morphGlassView.cornerRadius = targetRadius
                self.expandedContentView.animator().alphaValue = expanded ? 1.0 : 0.0
            },
            completion: { [weak self] committed in
                guard let self, committed else { return }
                self.isAnimatingMorph = false
                self.expandedContentView.isHidden = !self.isExpanded
                self.layoutMorphSubviews(in: self.morphGlassView.bounds)
            }
        )
    }

    public override func viewDidHide() {
        super.viewDidHide()
        removeOutsideClickMonitor()
        MotionCoordinator.shared.cancelAll(owner: motionOwnerID)
        if isExpanded {
            isExpanded = false
            isCollapsedHovered = false
            expandedContentView.isHidden = true
            expandedContentView.alphaValue = 0
            collapsedOverlayView.isHidden = false
            countLabel.isHidden = displayedEntries.isEmpty
            morphGlassView.style = .clear
            morphGlassView.isHidden = true
            needsLayout = true
        }
    }

    private func updateCollapsedTrackingArea() {
        if let existing = collapsedTrackingArea {
            collapsedOverlayView.removeTrackingArea(existing)
            collapsedTrackingArea = nil
        }
        let area = NSTrackingArea(
            rect: collapsedOverlayView.bounds,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        collapsedOverlayView.addTrackingArea(area)
        collapsedTrackingArea = area
    }

    public override func mouseEntered(with event: NSEvent) {
        guard !isExpanded else { return }
        isCollapsedHovered = true
        updateCollapsedGlassVisibility()
    }

    public override func mouseExited(with event: NSEvent) {
        guard isCollapsedHovered else { return }
        isCollapsedHovered = false
        updateCollapsedGlassVisibility()
    }

    private func updateCollapsedGlassVisibility() {
        let shouldShowGlass = isExpanded || isAnimatingMorph || isCollapsedHovered
        morphGlassView.isHidden = !shouldShowGlass
    }

    // MARK: - Outside Click & Accessibility

    private func installOutsideClickMonitor() {
        removeOutsideClickMonitor()
        localClickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self, self.isExpanded, let win = self.window, event.window === win else {
                return event
            }
            let ptInSelf = self.convert(event.locationInWindow, from: nil)
            if !self.morphGlassView.frame.contains(ptInSelf) {
                self.installOneShotMouseUpSwallow(for: win)
                self.setExpanded(false)
                return nil
            }
            return event
        }
    }

    private func installOneShotMouseUpSwallow(for targetWindow: NSWindow) {
        if let existing = mouseUpSwallowMonitor {
            NSEvent.removeMonitor(existing)
            mouseUpSwallowMonitor = nil
        }
        mouseUpSwallowMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseUp, .rightMouseUp]) { [weak self] upEvent in
            guard let self else { return upEvent }
            if let monitor = self.mouseUpSwallowMonitor {
                NSEvent.removeMonitor(monitor)
                self.mouseUpSwallowMonitor = nil
            }
            if upEvent.window === targetWindow {
                return nil
            }
            return upEvent
        }
    }

    private func removeOutsideClickMonitor() {
        if let monitor = localClickMonitor {
            NSEvent.removeMonitor(monitor)
            localClickMonitor = nil
        }
    }

    @objc private func accessibilityDidChange() {
        applyAccessibilityAndTransparencyStyle()
    }

    private func applyAccessibilityAndTransparencyStyle() {
        let reduceTransparency = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
        reduceTransparencyFallbackView.isHidden = !reduceTransparency
    }

    // MARK: - Snapshot Observation & Diffing

    private func startObservingQueue() {
        streamTask?.cancel()
        streamTask = Task { [weak self, coordinator] in
            let stream = await coordinator.queueStream()
            for await snap in stream {
                guard !Task.isCancelled, let self else { break }
                self.applySnapshot(snap)
            }
        }
    }

    private func applySnapshot(_ newSnapshot: QueueSnapshot) {
        let oldIDs = displayedEntries.map(\.id)
        let newIDs = newSnapshot.upcomingEntries.map(\.id)
        self.snapshot = newSnapshot
        self.displayedEntries = newSnapshot.upcomingEntries

        if oldIDs != newIDs {
            let selectedIDs = Set(tableView.selectedRowIndexes.compactMap { row -> UUID? in
                oldIDs.indices.contains(row) ? oldIDs[row] : nil
            })
            let scrollOrigin = scrollView.contentView.bounds.origin
            let diff = newIDs.difference(from: oldIDs)
            if diff.removals.count + diff.insertions.count <= 64 {
                tableView.beginUpdates()
                var removeIndices = IndexSet()
                for change in diff.removals {
                    if case .remove(let offset, _, _) = change { removeIndices.insert(offset) }
                }
                if !removeIndices.isEmpty {
                    tableView.removeRows(at: removeIndices, withAnimation: [])
                }
                var insertIndices = IndexSet()
                for change in diff.insertions {
                    if case .insert(let offset, _, _) = change { insertIndices.insert(offset) }
                }
                if !insertIndices.isEmpty {
                    tableView.insertRows(at: insertIndices, withAnimation: [])
                }
                tableView.endUpdates()
            } else {
                tableView.reloadData()
            }
            if !selectedIDs.isEmpty {
                var newSelection = IndexSet()
                for (idx, entry) in displayedEntries.enumerated() where selectedIDs.contains(entry.id) {
                    newSelection.insert(idx)
                }
                tableView.selectRowIndexes(newSelection, byExtendingSelection: false)
            }
            scrollView.contentView.scroll(to: scrollOrigin)
        }

        updateQueueCountBadge(previousCount: oldIDs.count, newCount: newIDs.count)
        updateToolbarAndStatus()
    }

    private func updateQueueCountBadge(previousCount: Int, newCount: Int) {
        countLabel.stringValue = newCount > 0 ? "\(newCount)" : ""
        countLabel.isHidden = isExpanded || newCount == 0
        toggleButton.toolTip = newCount > 0 ? "播放队列（\(newCount) 首待播）" : "播放队列"
        toggleButton.setAccessibilityValue(newCount > 0 ? "\(newCount) 首待播" : "空")

        if !isExpanded && !isAnimatingMorph {
            morphGlassView.frame = targetMorphRect(expanded: false)
            layoutMorphSubviews(in: morphGlassView.bounds)
        }

        let added = newCount - previousCount
        let now = CACurrentMediaTime()
        if hasObservedInitialSnapshot && added > 0 && (now - lastExplicitAnimationAt) > 0.45 {
            let inferredKind: QueueAdditionVisualKind = added > 1 ? .multiSongs(count: added) : .song
            animateQueueAddedPulse(kind: inferredKind)
        }
        hasObservedInitialSnapshot = true
        lastObservedQueueCount = newCount
    }

    /// Triggers a distinct, resource-aware queue-addition animation + optional toast feedback.
    public func playQueueAdditionAnimation(kind: QueueAdditionVisualKind, message: String? = nil) {
        lastExplicitAnimationAt = CACurrentMediaTime()
        if let message, !message.isEmpty {
            showFeedback(message)
        }
        guard !MotionCoordinator.shared.isReduceMotionEnabled else { return }
        animateQueueAddedPulse(kind: kind)
        spawnAdditionMotif(kind: kind)
    }

    private func animateQueueAddedPulse(kind: QueueAdditionVisualKind) {
        guard !MotionCoordinator.shared.isReduceMotionEnabled else { return }
        let targetView = isExpanded ? morphGlassView : collapsedOverlayView
        guard let layer = targetView.layer else { return }
        layer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        layer.position = CGPoint(
            x: targetView.frame.midX,
            y: targetView.frame.midY
        )

        let anim = CAKeyframeAnimation(keyPath: "transform.scale")
        switch kind {
        case .song:
            anim.values = [1.0, 1.14, 0.97, 1.0]
            anim.duration = 0.28
        case .multiSongs:
            anim.values = [1.0, 1.22, 0.94, 1.08, 1.0]
            anim.duration = 0.44
        case .album:
            anim.values = [1.0, 1.18, 0.95, 1.0]
            anim.duration = 0.36
        case .playlist:
            anim.values = [1.0, 1.18, 0.96, 1.05, 1.0]
            anim.duration = 0.40
        case .station:
            anim.values = [1.0, 1.20, 0.96, 1.0]
            anim.duration = 0.38
        }
        anim.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        anim.isRemovedOnCompletion = true
        layer.add(anim, forKey: "queueAddPulse")
    }

    private func spawnAdditionMotif(kind: QueueAdditionVisualKind) {
        guard let hostLayer = self.layer else { return }
        let anchorView = isExpanded ? morphGlassView : collapsedOverlayView
        let anchorCenter = CGPoint(x: anchorView.frame.midX, y: anchorView.frame.maxY + 2)

        switch kind {
        case .song:
            emitFloatingSymbolLayer(
                in: hostLayer,
                symbolName: "music.note",
                tint: NSColor.systemPink,
                center: anchorCenter,
                offsetY: 22,
                rotationRadians: 0,
                duration: 0.48,
                delay: 0
            )

        case .multiSongs(let count):
            let noteCount = min(4, max(2, count))
            for idx in 0..<noteCount {
                let xOffset = CGFloat(idx - noteCount / 2) * 8.0
                emitFloatingSymbolLayer(
                    in: hostLayer,
                    symbolName: idx % 2 == 0 ? "music.note" : "music.quarternote.3",
                    tint: idx % 2 == 0 ? NSColor.systemPink : NSColor.systemOrange,
                    center: CGPoint(x: anchorCenter.x + xOffset, y: anchorCenter.y),
                    offsetY: 26 + CGFloat(idx) * 3,
                    rotationRadians: CGFloat(idx % 2 == 0 ? -0.15 : 0.15),
                    duration: 0.50,
                    delay: Double(idx) * 0.055
                )
            }

        case .album:
            emitExpandingRing(in: hostLayer, center: CGPoint(x: anchorView.frame.midX, y: anchorView.frame.midY), color: NSColor.systemOrange, duration: 0.45)
            emitFloatingSymbolLayer(
                in: hostLayer,
                symbolName: "opticaldisc.fill",
                tint: NSColor.systemOrange,
                center: anchorCenter,
                offsetY: 24,
                rotationRadians: .pi,
                duration: 0.52,
                delay: 0
            )

        case .playlist:
            emitExpandingRing(in: hostLayer, center: CGPoint(x: anchorView.frame.midX, y: anchorView.frame.midY), color: NSColor.systemIndigo, duration: 0.45)
            for idx in 0..<2 {
                emitFloatingSymbolLayer(
                    in: hostLayer,
                    symbolName: idx == 0 ? "music.note.list" : "square.stack.fill",
                    tint: idx == 0 ? NSColor.systemTeal : NSColor.systemIndigo,
                    center: CGPoint(x: anchorCenter.x + CGFloat(idx * 6 - 3), y: anchorCenter.y),
                    offsetY: 22 + CGFloat(idx * 5),
                    rotationRadians: 0,
                    duration: 0.48,
                    delay: Double(idx) * 0.07
                )
            }

        case .station:
            let center = CGPoint(x: anchorView.frame.midX, y: anchorView.frame.midY)
            emitExpandingRing(in: hostLayer, center: center, color: NSColor.systemPink, duration: 0.55)
            emitExpandingRing(in: hostLayer, center: center, color: NSColor.systemPurple, duration: 0.65, delay: 0.10)
            emitFloatingSymbolLayer(
                in: hostLayer,
                symbolName: "dot.radiowaves.left.and.right",
                tint: NSColor.systemPink,
                center: anchorCenter,
                offsetY: 24,
                rotationRadians: 0,
                duration: 0.54,
                delay: 0
            )
        }
    }

    private func emitFloatingSymbolLayer(
        in hostLayer: CALayer,
        symbolName: String,
        tint: NSColor,
        center: CGPoint,
        offsetY: CGFloat,
        rotationRadians: CGFloat,
        duration: CFTimeInterval,
        delay: CFTimeInterval
    ) {
        let cfg = NSImage.SymbolConfiguration(pointSize: 13, weight: .bold)
        guard let img = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)?.withSymbolConfiguration(cfg) else {
            return
        }
        let tinted = NSImage(size: img.size, flipped: false) { rect in
            img.draw(in: rect)
            tint.set()
            rect.fill(using: .sourceAtop)
            return true
        }
        guard let cgImg = tinted.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }

        let badgeLayer = CALayer()
        badgeLayer.contents = cgImg
        badgeLayer.bounds = CGRect(x: 0, y: 0, width: 16, height: 16)
        badgeLayer.position = center
        badgeLayer.opacity = 0
        hostLayer.addSublayer(badgeLayer)

        let posAnim = CABasicAnimation(keyPath: "position.y")
        posAnim.fromValue = center.y
        posAnim.toValue = center.y + offsetY

        let scaleAnim = CAKeyframeAnimation(keyPath: "transform.scale")
        scaleAnim.values = [0.6, 1.18, 0.85]
        scaleAnim.keyTimes = [0.0, 0.45, 1.0]

        let rotAnim = CABasicAnimation(keyPath: "transform.rotation.z")
        rotAnim.fromValue = 0
        rotAnim.toValue = rotationRadians

        let opacityAnim = CAKeyframeAnimation(keyPath: "opacity")
        opacityAnim.values = [0.0, 1.0, 1.0, 0.0]
        opacityAnim.keyTimes = [0.0, 0.2, 0.65, 1.0]

        let group = CAAnimationGroup()
        group.animations = [posAnim, scaleAnim, rotAnim, opacityAnim]
        group.duration = duration
        group.beginTime = CACurrentMediaTime() + delay
        group.timingFunction = CAMediaTimingFunction(name: .easeOut)
        group.isRemovedOnCompletion = true

        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak badgeLayer] in
            badgeLayer?.removeFromSuperlayer()
        }
        badgeLayer.add(group, forKey: "motifFloat")
        CATransaction.commit()
    }

    private func emitExpandingRing(
        in hostLayer: CALayer,
        center: CGPoint,
        color: NSColor,
        duration: CFTimeInterval,
        delay: CFTimeInterval = 0
    ) {
        let ring = CAShapeLayer()
        let baseRect = CGRect(x: -12, y: -12, width: 24, height: 24)
        ring.path = CGPath(ellipseIn: baseRect, transform: nil)
        ring.position = center
        ring.fillColor = NSColor.clear.cgColor
        ring.strokeColor = color.withAlphaComponent(0.85).cgColor
        ring.lineWidth = 1.75
        ring.opacity = 0
        hostLayer.addSublayer(ring)

        let scaleAnim = CABasicAnimation(keyPath: "transform.scale")
        scaleAnim.fromValue = 0.85
        scaleAnim.toValue = 2.1

        let opacityAnim = CAKeyframeAnimation(keyPath: "opacity")
        opacityAnim.values = [0.0, 0.9, 0.0]
        opacityAnim.keyTimes = [0.0, 0.25, 1.0]

        let group = CAAnimationGroup()
        group.animations = [scaleAnim, opacityAnim]
        group.duration = duration
        group.beginTime = CACurrentMediaTime() + delay
        group.timingFunction = CAMediaTimingFunction(name: .easeOut)
        group.isRemovedOnCompletion = true

        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak ring] in
            ring?.removeFromSuperlayer()
        }
        ring.add(group, forKey: "ringRipple")
        CATransaction.commit()
    }

    private func layoutToast() {
        guard !toastGlassView.isHidden else { return }
        let maxW = max(120, bounds.width - cornerMargin * 2)
        let textW = ceil(toastLabel.intrinsicContentSize.width) + 22
        let toastW = min(maxW, max(96, textW))
        let toastH: CGFloat = 26
        let barH = max(buttonSize + 4, bottomBarHeight)
        let toastY = max(barH + 6, morphGlassView.frame.maxY + 6)
        let toastX = max(cornerMargin, bounds.width - toastW - cornerMargin)
        toastGlassView.frame = NSRect(x: toastX, y: toastY, width: toastW, height: toastH)
        toastFallbackView.frame = toastGlassView.bounds
    }

    private func updateToolbarAndStatus() {
        let caps = snapshot.capabilities

        clearButton.isEnabled = caps.canClear && snapshot.canClearUpcoming
        clearButton.toolTip = caps.canClear ? "清空待播队列" : "当前播放模式不支持清空"

        undoButton.isHidden = !snapshot.canUndo
        undoButton.toolTip = snapshot.undoDescription ?? "撤销"

        shuffleButton.isEnabled = caps.canToggleShuffle
        styleModeButton(shuffleButton, active: snapshot.shuffleEnabled, label: "随机播放")
        shuffleButton.toolTip = caps.canToggleShuffle ? "随机播放" : "当前播放模式不支持随机"

        repeatOneButton.isEnabled = caps.canRepeatOne
        styleModeButton(repeatOneButton, active: snapshot.repeatMode == .one, label: "单曲循环")
        repeatOneButton.toolTip = caps.canRepeatOne ? "单曲循环" : "当前播放模式不支持单曲循环"

        repeatAllButton.isEnabled = caps.canRepeatAll
        styleModeButton(repeatAllButton, active: snapshot.repeatMode == .all, label: "列表循环")
        repeatAllButton.toolTip = caps.canRepeatAll ? "列表循环" : "当前播放模式不支持列表循环"

        retryButton.isHidden = true
        if let transientFeedbackMessage {
            statusLabel.stringValue = transientFeedbackMessage
        } else if snapshot.owner == .remoteEngine {
            statusLabel.stringValue = "电台自动续播中"
            emptyStateLabel.stringValue = "电台由远端自动续播"
            emptyStateLabel.isHidden = !displayedEntries.isEmpty
        } else if snapshot.isPendingTargetFailed {
            statusLabel.stringValue = "当前曲目播放失败"
            retryButton.isHidden = false
            emptyStateLabel.isHidden = !displayedEntries.isEmpty
        } else if snapshot.playbackPhase == .waitingForPage {
            statusLabel.stringValue = "等待下一页加载..."
            emptyStateLabel.isHidden = !displayedEntries.isEmpty
        } else {
            switch snapshot.loadingState {
            case .idle, .complete:
                if snapshot.requestedShuffle && !snapshot.effectiveShuffle {
                    statusLabel.stringValue = "正在准备随机..."
                } else {
                    statusLabel.stringValue = displayedEntries.isEmpty ? "待播队列" : "接下来播放 · \(displayedEntries.count) 首"
                }
            case .loading(let loaded, let total):
                let shuffleNote = snapshot.requestedShuffle ? " · 正在准备随机" : ""
                if let total {
                    statusLabel.stringValue = "正在加载 \(loaded)/\(total) 首...\(shuffleNote)"
                } else {
                    statusLabel.stringValue = "已加载 \(loaded) 首...\(shuffleNote)"
                }
            case .partial(let loaded, let total):
                statusLabel.stringValue = total.map { "已加载 \(loaded)/\($0) 首" } ?? "已加载 \(loaded) 首"
            case .failed(let loaded, _, _, let retryable):
                statusLabel.stringValue = "部分加载失败 (已加载 \(loaded) 首)"
                retryButton.isHidden = !retryable
            }
            emptyStateLabel.stringValue = "待播队列为空"
            emptyStateLabel.isHidden = !displayedEntries.isEmpty
        }
        needsLayout = true
    }

    private func styleModeButton(_ button: NSButton, active: Bool, label: String) {
        button.contentTintColor = active ? .controlAccentColor : .secondaryLabelColor
        button.layer?.backgroundColor = active ? NSColor.controlAccentColor.withAlphaComponent(0.18).cgColor : nil
        button.layer?.borderWidth = active ? 0.75 : 0
        button.layer?.borderColor = active ? NSColor.controlAccentColor.withAlphaComponent(0.55).cgColor : nil
        button.setAccessibilityValue(active ? "已开启" : "未开启")
        button.setAccessibilityLabel(label)
    }

    // MARK: - Actions

    @objc private func clearClicked() {
        AppLogger.shared.log(category: .userAction, level: .info, message: "用户在队列浮层点击 [清空待播队列]")
        let qid = snapshot.queueID
        Task {
            do {
                try await coordinator.clearUpcoming(expectedQueueID: qid)
            } catch {
                onReportError?(error.localizedDescription)
            }
        }
    }

    @objc private func undoClicked() {
        let qid = snapshot.queueID
        Task {
            do {
                try await coordinator.undoLastQueueEdit(expectedQueueID: qid)
            } catch {
                onReportError?(error.localizedDescription)
            }
        }
    }

    @objc private func shuffleClicked() {
        let next = !snapshot.shuffleEnabled
        Task {
            await coordinator.setShuffleEnabled(next)
        }
    }

    @objc private func repeatOneClicked() {
        let next: PlaybackState.RepeatMode = (snapshot.repeatMode == .one) ? .off : .one
        Task {
            await coordinator.setRepeatMode(next)
        }
    }

    @objc private func repeatAllClicked() {
        let next: PlaybackState.RepeatMode = (snapshot.repeatMode == .all) ? .off : .all
        Task {
            await coordinator.setRepeatMode(next)
        }
    }

    public func showFeedback(_ message: String, durationSeconds: Double = 3.5) {
        feedbackTask?.cancel()
        transientFeedbackMessage = message
        updateToolbarAndStatus()

        guard !isExpanded else {
            feedbackTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(durationSeconds))
                guard !Task.isCancelled, let self else { return }
                self.transientFeedbackMessage = nil
                self.updateToolbarAndStatus()
            }
            return
        }

        toastLabel.stringValue = message
        let useFallback = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency || !GlassInteractionCoordinator.shared.isEnhancedMode
        toastFallbackView.isHidden = !useFallback
        toastGlassView.isHidden = false
        layoutToast()

        if MotionCoordinator.shared.isReduceMotionEnabled {
            toastGlassView.alphaValue = 1
        } else {
            toastGlassView.alphaValue = 0
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.16
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                toastGlassView.animator().alphaValue = 1
            }
        }

        feedbackTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(durationSeconds))
            guard !Task.isCancelled, let self else { return }
            self.transientFeedbackMessage = nil
            self.updateToolbarAndStatus()
            if MotionCoordinator.shared.isReduceMotionEnabled {
                self.toastGlassView.alphaValue = 0
                self.toastGlassView.isHidden = true
            } else {
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = 0.2
                    ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
                    self.toastGlassView.animator().alphaValue = 0
                } completionHandler: { [weak self] in
                    Task { @MainActor in
                        guard let self, self.transientFeedbackMessage == nil else { return }
                        self.toastGlassView.isHidden = true
                    }
                }
            }
        }
    }

    @objc private func retryClicked() {
        if case .failed(_, _, _, let retryable) = snapshot.loadingState, retryable {
            onRetryPagination?()
        } else {
            Task {
                try? await coordinator.retryPendingOrCurrent()
            }
        }
    }

    @objc private func tableDoubleClicked() {
        let row = tableView.clickedRow
        guard displayedEntries.indices.contains(row) else { return }
        let entry = displayedEntries[row]
        let qid = snapshot.queueID
        Task {
            do {
                try await coordinator.playEntry(id: entry.id, expectedQueueID: qid)
            } catch {
                onReportError?(error.localizedDescription)
            }
        }
    }

    private func removeSelectedEntries() {
        let ids = tableView.selectedRowIndexes.compactMap { row -> UUID? in
            displayedEntries.indices.contains(row) ? displayedEntries[row].id : nil
        }
        guard !ids.isEmpty else { return }
        let qid = snapshot.queueID
        Task {
            do {
                try await coordinator.removeEntries(ids: ids, expectedQueueID: qid)
            } catch {
                onReportError?(error.localizedDescription)
            }
        }
    }

    // MARK: - NSTableViewDataSource & Delegate (Drag & Drop)

    public func numberOfRows(in tableView: NSTableView) -> Int {
        displayedEntries.count
    }

    public func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard displayedEntries.indices.contains(row) else { return nil }
        let entry = displayedEntries[row]
        let cell = (tableView.makeView(withIdentifier: QueueEntryCellView.identifier, owner: self) as? QueueEntryCellView)
            ?? QueueEntryCellView(frame: .zero)
        cell.identifier = QueueEntryCellView.identifier
        cell.configure(with: entry)
        return cell
    }

    public func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> (any NSPasteboardWriting)? {
        guard snapshot.capabilities.canReorder, displayedEntries.indices.contains(row) else { return nil }
        let pbItem = NSPasteboardItem()
        let selected = tableView.selectedRowIndexes.contains(row)
            ? tableView.selectedRowIndexes.compactMap { displayedEntries.indices.contains($0) ? displayedEntries[$0].id.uuidString : nil }
            : [displayedEntries[row].id.uuidString]
        pbItem.setString(selected.joined(separator: ","), forType: .airMuseQueueEntryIDs)
        return pbItem
    }

    public func tableView(
        _ tableView: NSTableView,
        validateDrop info: any NSDraggingInfo,
        proposedRow row: Int,
        proposedDropOperation dropOperation: NSTableView.DropOperation
    ) -> NSDragOperation {
        guard snapshot.capabilities.canReorder, dropOperation == .above else {
            return []
        }
        return .move
    }

    public func tableView(
        _ tableView: NSTableView,
        acceptDrop info: any NSDraggingInfo,
        row: Int,
        dropOperation: NSTableView.DropOperation
    ) -> Bool {
        guard snapshot.capabilities.canReorder,
              let raw = info.draggingPasteboard.string(forType: .airMuseQueueEntryIDs) else {
            return false
        }
        let ids = raw.split(separator: ",").compactMap { UUID(uuidString: String($0)) }
        guard !ids.isEmpty else { return false }

        let targetID: UUID? = displayedEntries.indices.contains(row) ? displayedEntries[row].id : nil
        let qid = snapshot.queueID
        Task {
            do {
                try await coordinator.moveEntries(ids: ids, before: targetID, expectedQueueID: qid)
            } catch {
                onReportError?(error.localizedDescription)
            }
        }
        return true
    }
}

// MARK: - NSMenuDelegate (Context Menu)

extension LiquidFusionQueueDockView: NSMenuDelegate {
    public func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let clicked = tableView.clickedRow
        guard displayedEntries.indices.contains(clicked) else { return }

        let selectedIDs: [UUID]
        if tableView.selectedRowIndexes.contains(clicked) {
            selectedIDs = tableView.selectedRowIndexes.compactMap { displayedEntries.indices.contains($0) ? displayedEntries[$0].id : nil }
        } else {
            selectedIDs = [displayedEntries[clicked].id]
        }
        let primaryEntry = displayedEntries[clicked]
        let qid = snapshot.queueID

        let resource = MediaResourceReference(
            kind: .queueEntry,
            providerID: primaryEntry.track.providerID,
            canonicalID: primaryEntry.track.providerTrackID.isEmpty ? primaryEntry.track.id : primaryEntry.track.providerTrackID,
            catalogID: primaryEntry.track.providerTrackID.isEmpty ? nil : primaryEntry.track.providerTrackID,
            libraryID: primaryEntry.track.id,
            title: primaryEntry.track.title,
            subtitle: primaryEntry.track.artistName,
            artworkURL: primaryEntry.track.artworkURL,
            isLibrary: primaryEntry.track.id.hasPrefix("i.") || primaryEntry.origin.isLibrary,
            albumID: primaryEntry.track.albumID,
            albumTitle: primaryEntry.track.albumTitle.isEmpty ? nil : primaryEntry.track.albumTitle,
            artists: primaryEntry.track.artists,
            queueEntryID: primaryEntry.id,
            origin: primaryEntry.origin
        )

        let ctx: MediaActionContext
        if let built = queueContextBuilder?(resource, selectedIDs) {
            ctx = built
        } else {
            let caps = MediaActionCapabilities(
                isAuthenticated: false,
                canPlay: true,
                canReorderQueue: snapshot.capabilities.canReorder,
                canRemoveFromQueue: snapshot.capabilities.canRemove
            )
            ctx = MediaActionContext(
                resource: resource,
                location: .queueRow,
                state: .unknown,
                capabilities: caps,
                selectedCount: selectedIDs.count,
                selectedQueueEntryIDs: selectedIDs
            )
        }

        let descriptor = MediaActionResolver.resolveContextMenu(for: ctx)
        guard let builtMenu = MediaContextMenuBuilder.buildMenu(from: descriptor, onAction: { [weak self] action in
            self?.handleQueueMenuAction(action, expectedQueueID: qid)
        }) else {
            return
        }
        for item in builtMenu.items {
            builtMenu.removeItem(item)
            menu.addItem(item)
        }
    }

    private func handleQueueMenuAction(_ action: MediaAction, expectedQueueID qid: UUID) {
        switch action {
        case .playQueueEntry(let id):
            Task { [weak self] in
                do {
                    try await self?.coordinator.playEntry(id: id, expectedQueueID: qid)
                } catch {
                    self?.showFeedback("队列操作已过期或失败: \(error.localizedDescription)")
                }
            }
        case .moveQueueEntryToNext(let ids):
            let firstID = displayedEntries.first(where: { !ids.contains($0.id) })?.id
            Task { [weak self] in
                do {
                    try await self?.coordinator.moveEntries(ids: ids, before: firstID, expectedQueueID: qid)
                } catch {
                    self?.showFeedback("队列移动失败: \(error.localizedDescription)")
                }
            }
        case .moveQueueEntryToEnd(let ids):
            Task { [weak self] in
                do {
                    try await self?.coordinator.moveEntries(ids: ids, before: nil, expectedQueueID: qid)
                } catch {
                    self?.showFeedback("队列移动失败: \(error.localizedDescription)")
                }
            }
        case .removeQueueEntries(let ids):
            Task { [weak self] in
                do {
                    try await self?.coordinator.removeEntries(ids: ids, expectedQueueID: qid)
                } catch {
                    self?.showFeedback("队列移除失败: \(error.localizedDescription)")
                }
            }
        case .navigateToOrigin(let origin):
            setExpanded(false)
            onNavigateToOrigin?(origin)
        default:
            setExpanded(false)
            onQueueMediaAction?(action)
        }
    }
}
