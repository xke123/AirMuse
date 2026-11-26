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

// MARK: - LiquidFusionQueueDockView

/// Bottom-right Liquid Fusion Dock queue control & expandable upcoming queue overlay.
/// Uses native `NSGlassEffectContainerView` + `NSGlassEffectView` on macOS 26+ with
/// interruptible morph geometry, keyboard/drag support, and zero-overhead idle state.
@MainActor
public final class LiquidFusionQueueDockView: NSView, NSTableViewDataSource, NSTableViewDelegate {

    // MARK: - Public Callbacks & State

    public var onNavigateToOrigin: ((PlaybackOrigin) -> Void)?
    public var onReportError: ((String) -> Void)?
    public private(set) var isExpanded: Bool = false

    private let coordinator: PlaybackCoordinatorV2
    private var snapshot: QueueSnapshot = .empty
    private var displayedEntries: [QueueEntry] = []
    private var streamTask: Task<Void, Never>?
    private var localClickMonitor: Any?
    private let motionOwnerID = "QueueDock-\(UUID().uuidString)"
    private var isAnimatingMorph: Bool = false

    // MARK: - Native Glass Hierarchy

    private let glassContainer = NSGlassEffectContainerView(frame: .zero)
    private let morphGlassView = NSGlassEffectView(frame: .zero)
    private let glassContentView = NSView(frame: .zero)
    private let reduceTransparencyFallbackView = NSView(frame: .zero)

    // Collapsed trigger button
    private let toggleButton = NSButton(frame: .zero)

    // Expanded content container (inside morphGlassView.contentView)
    private let expandedContentView = NSView(frame: .zero)
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
    private let buttonSize: CGFloat = 26
    private let cornerMargin: CGFloat = 7

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
        if let monitor = localClickMonitor {
            NSEvent.removeMonitor(monitor)
        }
        MotionCoordinator.shared.cancelAll(owner: motionOwnerID)
    }

    // MARK: - Hit Testing

    /// Only intercept hits inside the visible glass morph view so the rest of the library remains interactive.
    public override func hitTest(_ point: NSPoint) -> NSView? {
        let localPt = convert(point, from: superview)
        let glassPt = glassContainer.convert(localPt, from: self)
        guard morphGlassView.frame.contains(glassPt) else {
            return nil
        }
        return super.hitTest(point) ?? (isExpanded ? expandedContentView : toggleButton)
    }

    // MARK: - Setup

    private func setupUI() {
        wantsLayer = true

        glassContainer.spacing = 6
        addSubview(glassContainer)

        morphGlassView.style = .clear
        morphGlassView.cornerRadius = buttonSize * 0.5
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

        // Collapsed circular toggle button
        toggleButton.isBordered = false
        toggleButton.bezelStyle = .regularSquare
        toggleButton.image = NSImage(systemSymbolName: "list.bullet", accessibilityDescription: "播放队列")
        toggleButton.contentTintColor = .labelColor
        toggleButton.toolTip = "播放队列"
        toggleButton.target = self
        toggleButton.action = #selector(toggleExpanded)
        glassContentView.addSubview(toggleButton)

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

    private func targetMorphRect(expanded: Bool) -> NSRect {
        let w = bounds.width
        let h = bounds.height
        if !expanded {
            return NSRect(
                x: max(cornerMargin, w - buttonSize - cornerMargin),
                y: cornerMargin,
                width: buttonSize,
                height: buttonSize
            )
        }
        let targetW = min(max(240, w * 0.5), max(240, w - cornerMargin * 2))
        let targetH = min(max(220, h * 0.7), max(220, h - cornerMargin * 2))
        return NSRect(
            x: max(cornerMargin, w - targetW - cornerMargin),
            y: cornerMargin,
            width: targetW,
            height: targetH
        )
    }

    private func layoutMorphSubviews(in rect: NSRect) {
        reduceTransparencyFallbackView.frame = rect
        reduceTransparencyFallbackView.layer?.cornerRadius = isExpanded ? 14 : buttonSize * 0.5
        toggleButton.frame = NSRect(x: max(0, rect.width - buttonSize), y: 0, width: buttonSize, height: buttonSize)

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
            toggleButton.isHidden = true
            morphGlassView.style = .regular
        } else {
            removeOutsideClickMonitor()
            toggleButton.isHidden = false
            morphGlassView.style = .clear
            window?.makeFirstResponder(toggleButton)
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
                guard let self else { return }
                self.isAnimatingMorph = false
                guard committed else { return }
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
            expandedContentView.isHidden = true
            expandedContentView.alphaValue = 0
            toggleButton.isHidden = false
            morphGlassView.style = .clear
            needsLayout = true
        }
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
                self.setExpanded(false)
            }
            return event
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
            tableView.reloadData()
            if !selectedIDs.isEmpty {
                var newSelection = IndexSet()
                for (idx, entry) in displayedEntries.enumerated() where selectedIDs.contains(entry.id) {
                    newSelection.insert(idx)
                }
                tableView.selectRowIndexes(newSelection, byExtendingSelection: false)
            }
            scrollView.contentView.scroll(to: scrollOrigin)
        }

        updateToolbarAndStatus()
    }

    private func updateToolbarAndStatus() {
        let caps = snapshot.capabilities

        clearButton.isEnabled = caps.canClear && !displayedEntries.isEmpty
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
        if snapshot.owner == .remoteEngine {
            statusLabel.stringValue = "电台自动续播中"
            emptyStateLabel.stringValue = "电台由远端自动续播"
            emptyStateLabel.isHidden = !displayedEntries.isEmpty
        } else {
            switch snapshot.loadingState {
            case .idle, .complete:
                statusLabel.stringValue = displayedEntries.isEmpty ? "待播队列" : "接下来播放 · \(displayedEntries.count) 首"
            case .loading(let loaded, let total):
                if let total {
                    statusLabel.stringValue = "正在加载 \(loaded)/\(total) 首..."
                } else {
                    statusLabel.stringValue = "已加载 \(loaded) 首..."
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

    @objc private func retryClicked() {
        Task {
            try? await coordinator.retryPendingOrCurrent()
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

        let playItem = NSMenuItem(title: "立即播放", action: #selector(ctxPlay(_:)), keyEquivalent: "")
        playItem.target = self
        playItem.representedObject = primaryEntry.id
        menu.addItem(playItem)

        if snapshot.capabilities.canReorder {
            let moveNextItem = NSMenuItem(title: "移到下一首", action: #selector(ctxMoveToNext(_:)), keyEquivalent: "")
            moveNextItem.target = self
            moveNextItem.representedObject = (selectedIDs, qid)
            menu.addItem(moveNextItem)

            let moveEndItem = NSMenuItem(title: "移到末尾", action: #selector(ctxMoveToEnd(_:)), keyEquivalent: "")
            moveEndItem.target = self
            moveEndItem.representedObject = (selectedIDs, qid)
            menu.addItem(moveEndItem)
        }

        if snapshot.capabilities.canRemove {
            let removeItem = NSMenuItem(title: selectedIDs.count > 1 ? "移除所选 (\(selectedIDs.count))" : "移除", action: #selector(ctxRemove(_:)), keyEquivalent: "")
            removeItem.target = self
            removeItem.representedObject = (selectedIDs, qid)
            menu.addItem(removeItem)
        }

        if primaryEntry.origin.canNavigate {
            menu.addItem(.separator())
            let originItem = NSMenuItem(title: "前往来源（\(primaryEntry.origin.displayTitle)）", action: #selector(ctxNavigateOrigin(_:)), keyEquivalent: "")
            originItem.target = self
            originItem.representedObject = primaryEntry.origin
            menu.addItem(originItem)
        }
    }

    @objc private func ctxPlay(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID else { return }
        let qid = snapshot.queueID
        Task { try? await coordinator.playEntry(id: id, expectedQueueID: qid) }
    }

    @objc private func ctxMoveToNext(_ sender: NSMenuItem) {
        guard let (ids, qid) = sender.representedObject as? ([UUID], UUID) else { return }
        let firstID = displayedEntries.first(where: { !ids.contains($0.id) })?.id
        Task { try? await coordinator.moveEntries(ids: ids, before: firstID, expectedQueueID: qid) }
    }

    @objc private func ctxMoveToEnd(_ sender: NSMenuItem) {
        guard let (ids, qid) = sender.representedObject as? ([UUID], UUID) else { return }
        Task { try? await coordinator.moveEntries(ids: ids, before: nil, expectedQueueID: qid) }
    }

    @objc private func ctxRemove(_ sender: NSMenuItem) {
        guard let (ids, qid) = sender.representedObject as? ([UUID], UUID) else { return }
        Task { try? await coordinator.removeEntries(ids: ids, expectedQueueID: qid) }
    }

    @objc private func ctxNavigateOrigin(_ sender: NSMenuItem) {
        guard let origin = sender.representedObject as? PlaybackOrigin else { return }
        setExpanded(false)
        onNavigateToOrigin?(origin)
    }
}
