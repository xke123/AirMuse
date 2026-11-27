import AppKit
import Domain
import DesignSystem
import Infrastructure

// MARK: - LogWindow

open class LogWindow: NSPanel {
    public init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless, .resizable, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        level = .floating
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isMovableByWindowBackground = true
        minSize = NSSize(width: 540, height: 340)
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    }

    open override var canBecomeKey: Bool { true }
    open override var canBecomeMain: Bool { true }
}

// MARK: - LogWindowController (Platform-Agnostic Diagnostics Center)

@MainActor
open class LogWindowController: NSWindowController, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate {

    public enum Tab: Int, CaseIterable {
        case events = 0
        case snapshots = 1
        case performance = 2
    }

    private let panel = GlassPanel()
    private let titleLabel = NSTextField(labelWithString: "AirMuse Diagnostics Center")
    private let badgeLabel = NSTextField(labelWithString: "0 条")

    private let tabControl = NSSegmentedControl(labels: ["事件", "状态快照", "性能"], trackingMode: .selectOne, target: nil, action: nil)
    private let levelPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let searchField = NSSearchField()
    private let followButton = NSButton(checkboxWithTitle: "跟随", target: nil, action: nil)
    private let pauseButton = NSButton(checkboxWithTitle: "暂停", target: nil, action: nil)

    private let copySummaryButton = NSButton()
    private let exportZipButton = NSButton()
    private let snapshotRefreshButton = NSButton()
    private let probeButton = NSButton()
    private let clearViewButton = NSButton()
    private let deleteLogsButton = NSButton()
    private let closeButton = GlassButton(image: NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close"), size: CGSize(width: 14, height: 14))

    // Tab 0: Events (virtualized NSTableView + detail inspector)
    private let eventsScrollView = NSScrollView()
    private let eventsTableView = NSTableView()
    private let detailScrollView = NSScrollView()
    private let detailTextView = NSTextView()

    // Tab 1 & 2: Snapshots & Performance text view
    private let reportScrollView = NSScrollView()
    private let reportTextView = NSTextView()

    private var activeTab: Tab = .events
    private var allEvents: [DiagnosticEvent] = []
    private var filteredEvents: [DiagnosticEvent] = []
    private var isFollowing: Bool = true
    private var isPausedDisplay: Bool = false
    private var lastCursor: UInt64 = 0
    private var subscriptionTask: Task<Void, Never>?

    private var diagnosticFetch: (@Sendable () async throws -> [MusicTrack])?
    private var diagnosticsProvider: (@Sendable () async -> String)?
    private var activeProbe: (@Sendable () async throws -> String)?

    public init(
        diagnosticFetch: (@Sendable () async throws -> [MusicTrack])? = nil,
        diagnosticsProvider: (@Sendable () async -> String)? = nil,
        activeProbe: (@Sendable () async throws -> String)? = nil
    ) {
        self.diagnosticFetch = diagnosticFetch
        self.diagnosticsProvider = diagnosticsProvider
        self.activeProbe = activeProbe

        let screenFrame = NSScreen.main?.visibleFrame ?? NSRect(x: 100, y: 100, width: 1200, height: 800)
        let rect = NSRect(
            x: screenFrame.minX + 40,
            y: screenFrame.maxY - 520,
            width: 720,
            height: 480
        )
        let window = LogWindow(contentRect: rect)
        super.init(window: window)
        window.delegate = self

        setupUI(window)
        startOrResumeSubscription()
    }

    public required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Window Lifecycle (Stop subscription when hidden)

    open override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        startOrResumeSubscription()
    }

    public func windowWillClose(_ notification: Notification) {
        stopSubscription()
    }

    private func stopSubscription() {
        subscriptionTask?.cancel()
        subscriptionTask = nil
        AppLogger.shared.emit(
            eventName: "diagnostic.subscriber.changed",
            category: "DIAGNOSTICS",
            level: .debug,
            source: DiagnosticSourceLocation(module: "UI", component: "LogWindowController", function: "stopSubscription"),
            payload: { DiagnosticEventPayload(fields: ["visible": .bool(false)], message: "Diagnostics UI hidden; unsubscribed") }
        )
    }

    private func startOrResumeSubscription() {
        guard subscriptionTask == nil else { return }
        let (snapshot, nextCursor, _, stream) = AppLogger.shared.subscribe(fromCursor: lastCursor > 0 ? lastCursor : nil)
        lastCursor = nextCursor
        if !isPausedDisplay {
            allEvents.append(contentsOf: snapshot)
            if allEvents.count > 10_000 {
                allEvents.removeFirst(allEvents.count - 10_000)
            }
            applyFilters()
        }

        AppLogger.shared.emit(
            eventName: "diagnostic.subscriber.changed",
            category: "DIAGNOSTICS",
            level: .debug,
            source: DiagnosticSourceLocation(module: "UI", component: "LogWindowController", function: "startOrResumeSubscription"),
            payload: { DiagnosticEventPayload(fields: ["visible": .bool(true)], message: "Diagnostics UI visible; subscribed") }
        )

        subscriptionTask = Task { [weak self] in
            for await batch in stream {
                guard let self, !Task.isCancelled else { break }
                if batch.resetRequired {
                    self.allEvents.removeAll()
                    self.lastCursor = batch.nextCursor
                    self.applyFilters()
                    continue
                }
                self.lastCursor = max(self.lastCursor, batch.nextCursor)
                guard !self.isPausedDisplay, !batch.events.isEmpty else { continue }
                self.allEvents.append(contentsOf: batch.events)
                if self.allEvents.count > 10_000 {
                    self.allEvents.removeFirst(self.allEvents.count - 10_000)
                }
                self.applyFilters()
            }
        }
    }

    // MARK: - UI Setup

    private func setupUI(_ window: LogWindow) {
        window.contentView = panel
        let container = panel.contentView

        titleLabel.font = NSFont.systemFont(ofSize: 11.5, weight: .semibold)
        titleLabel.textColor = NSColor(white: 0.95, alpha: 1.0)
        container.addSubview(titleLabel)

        badgeLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 9.5, weight: .regular)
        badgeLabel.textColor = NSColor(white: 0.65, alpha: 1.0)
        container.addSubview(badgeLabel)

        tabControl.selectedSegment = 0
        tabControl.target = self
        tabControl.action = #selector(tabChanged)
        tabControl.setAccessibilityLabel("Diagnostics Tabs")
        container.addSubview(tabControl)

        levelPopup.addItems(withTitles: ["All", "INFO+", "WARN+", "ERROR+"])
        levelPopup.font = NSFont.systemFont(ofSize: 9.5)
        levelPopup.target = self
        levelPopup.action = #selector(filterChanged)
        container.addSubview(levelPopup)

        searchField.placeholderString = "筛选 event / trace / category"
        searchField.font = NSFont.systemFont(ofSize: 10)
        searchField.target = self
        searchField.action = #selector(filterChanged)
        container.addSubview(searchField)

        followButton.state = .on
        followButton.font = NSFont.systemFont(ofSize: 9.5)
        followButton.contentTintColor = .white
        followButton.target = self
        followButton.action = #selector(followToggled)
        container.addSubview(followButton)

        pauseButton.state = .off
        pauseButton.font = NSFont.systemFont(ofSize: 9.5)
        pauseButton.contentTintColor = .white
        pauseButton.target = self
        pauseButton.action = #selector(pauseToggled)
        container.addSubview(pauseButton)

        configureActionButton(copySummaryButton, title: "复制摘要", action: #selector(copySummaryClicked))
        configureActionButton(exportZipButton, title: "导出 ZIP", action: #selector(exportZipClicked))
        configureActionButton(snapshotRefreshButton, title: "采集快照", action: #selector(refreshSnapshotsClicked))
        configureActionButton(probeButton, title: "主动探测", action: #selector(activeProbeClicked))
        configureActionButton(clearViewButton, title: "清空视图", action: #selector(clearViewClicked))
        configureActionButton(deleteLogsButton, title: "删除日志", action: #selector(deleteLogsClicked))

        closeButton.onClick = { [weak self] in
            self?.stopSubscription()
            self?.window?.orderOut(nil)
        }
        container.addSubview(closeButton)

        // Table View (virtualized event list)
        let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("EventColumn"))
        col.title = "Events"
        col.resizingMask = .autoresizingMask
        eventsTableView.addTableColumn(col)
        eventsTableView.headerView = nil
        eventsTableView.backgroundColor = NSColor(calibratedRed: 0.07, green: 0.07, blue: 0.09, alpha: 0.85)
        eventsTableView.rowHeight = 20
        eventsTableView.dataSource = self
        eventsTableView.delegate = self

        eventsScrollView.drawsBackground = false
        eventsScrollView.hasVerticalScroller = true
        eventsScrollView.documentView = eventsTableView
        container.addSubview(eventsScrollView)

        detailTextView.isEditable = false
        detailTextView.isSelectable = true
        detailTextView.backgroundColor = NSColor(calibratedRed: 0.05, green: 0.05, blue: 0.07, alpha: 0.92)
        detailTextView.textColor = NSColor(white: 0.88, alpha: 1.0)
        detailTextView.font = NSFont.monospacedSystemFont(ofSize: 9.5, weight: .regular)
        detailScrollView.drawsBackground = false
        detailScrollView.hasVerticalScroller = true
        detailScrollView.documentView = detailTextView
        container.addSubview(detailScrollView)

        reportTextView.isEditable = false
        reportTextView.isSelectable = true
        reportTextView.backgroundColor = NSColor(calibratedRed: 0.06, green: 0.06, blue: 0.08, alpha: 0.90)
        reportTextView.textColor = NSColor(white: 0.90, alpha: 1.0)
        reportTextView.font = NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)
        reportScrollView.drawsBackground = false
        reportScrollView.hasVerticalScroller = true
        reportScrollView.documentView = reportTextView
        reportScrollView.isHidden = true
        container.addSubview(reportScrollView)

        panel.onLayout = { [weak self] _ in
            self?.layoutViews()
        }
        layoutViews()
    }

    private func configureActionButton(_ button: NSButton, title: String, action: Selector) {
        button.title = title
        button.font = NSFont.systemFont(ofSize: 9.5, weight: .medium)
        button.bezelStyle = .recessed
        button.contentTintColor = NSColor(white: 0.88, alpha: 1.0)
        button.target = self
        button.action = action
        panel.contentView.addSubview(button)
    }

    private func layoutViews() {
        let bounds = panel.contentView.bounds
        let w = bounds.width
        let h = bounds.height

        titleLabel.frame = NSRect(x: 10, y: 8, width: 175, height: 18)
        badgeLabel.frame = NSRect(x: 190, y: 9, width: 70, height: 16)
        tabControl.frame = NSRect(x: 265, y: 5, width: 180, height: 22)
        closeButton.frame = NSRect(x: w - 24, y: 8, width: 16, height: 16)

        // Second toolbar row
        let row2Y: CGFloat = 32
        levelPopup.frame = NSRect(x: 10, y: row2Y, width: 78, height: 20)
        searchField.frame = NSRect(x: 94, y: row2Y, width: max(100, w - 530), height: 20)
        followButton.frame = NSRect(x: w - 428, y: row2Y, width: 52, height: 20)
        pauseButton.frame = NSRect(x: w - 374, y: row2Y, width: 52, height: 20)
        snapshotRefreshButton.frame = NSRect(x: w - 320, y: row2Y, width: 62, height: 20)
        probeButton.frame = NSRect(x: w - 254, y: row2Y, width: 62, height: 20)
        copySummaryButton.frame = NSRect(x: w - 188, y: row2Y, width: 62, height: 20)
        exportZipButton.frame = NSRect(x: w - 122, y: row2Y, width: 60, height: 20)
        clearViewButton.frame = NSRect(x: w - 58, y: row2Y, width: 50, height: 20)
        deleteLogsButton.frame = NSRect(x: w - 95, y: 6, width: 64, height: 20)

        let topH: CGFloat = 58
        let bodyH = max(40, h - topH - 8)
        let detailH: CGFloat = min(110, bodyH * 0.32)

        eventsScrollView.frame = NSRect(x: 8, y: topH, width: max(10, w - 16), height: max(20, bodyH - detailH - 4))
        detailScrollView.frame = NSRect(x: 8, y: topH + bodyH - detailH, width: max(10, w - 16), height: detailH)
        reportScrollView.frame = NSRect(x: 8, y: topH, width: max(10, w - 16), height: bodyH)
    }

    // MARK: - Filtering & Rendering

    private func applyFilters() {
        let minLevel: DiagnosticLevel = switch levelPopup.indexOfSelectedItem {
        case 1: .info
        case 2: .warn
        case 3: .error
        default: .trace
        }
        let q = searchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        filteredEvents = allEvents.filter { ev in
            guard ev.level >= minLevel else { return false }
            if q.isEmpty { return true }
            return ev.eventName.lowercased().contains(q)
                || ev.category.lowercased().contains(q)
                || ev.traceID.uuidString.lowercased().contains(q)
                || ev.message.lowercased().contains(q)
        }

        badgeLabel.stringValue = "\(filteredEvents.count)/\(allEvents.count)"
        eventsTableView.reloadData()
        if isFollowing && !filteredEvents.isEmpty && activeTab == .events {
            eventsTableView.scrollRowToVisible(filteredEvents.count - 1)
        }
    }

    // MARK: - NSTableViewDataSource & Delegate

    public func numberOfRows(in tableView: NSTableView) -> Int {
        filteredEvents.count
    }

    public func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row < filteredEvents.count else { return nil }
        let ev = filteredEvents[row]
        let id = NSUserInterfaceItemIdentifier("DiagRowCell")
        let cell = (tableView.makeView(withIdentifier: id, owner: self) as? NSTextField) ?? {
            let tf = NSTextField(labelWithString: "")
            tf.identifier = id
            tf.font = NSFont.monospacedSystemFont(ofSize: 9.5, weight: .regular)
            tf.lineBreakMode = .byTruncatingTail
            return tf
        }()
        let entry = LogEntry(from: ev)
        cell.stringValue = "[\(entry.formattedTime)] [\(ev.level.rawValue)] [\(ev.eventName)] [\(ev.traceID.uuidString.prefix(8))] \(ev.message)"
        cell.textColor = ev.level >= .error
            ? NSColor(calibratedRed: 1.0, green: 0.45, blue: 0.45, alpha: 1.0)
            : (ev.level == .warn ? NSColor(calibratedRed: 0.95, green: 0.78, blue: 0.25, alpha: 1.0) : NSColor(white: 0.90, alpha: 1.0))
        return cell
    }

    public func tableViewSelectionDidChange(_ notification: Notification) {
        let row = eventsTableView.selectedRow
        guard row >= 0, row < filteredEvents.count else { return }
        let ev = filteredEvents[row]
        let encoder = DiagnosticJSONLCodec.makeEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(ev), let json = String(data: data, encoding: .utf8) {
            detailTextView.string = json
        }
    }

    // MARK: - Actions

    @objc private func tabChanged() {
        activeTab = Tab(rawValue: tabControl.selectedSegment) ?? .events
        let showEvents = (activeTab == .events)
        eventsScrollView.isHidden = !showEvents
        detailScrollView.isHidden = !showEvents
        reportScrollView.isHidden = showEvents
        if activeTab == .snapshots {
            refreshSnapshotsClicked()
        } else if activeTab == .performance {
            renderPerformanceTab()
        }
    }

    @objc private func filterChanged() {
        applyFilters()
    }

    @objc private func followToggled() {
        isFollowing = (followButton.state == .on)
    }

    @objc private func pauseToggled() {
        isPausedDisplay = (pauseButton.state == .on)
        if !isPausedDisplay {
            let delta = AppLogger.shared.getEvents(afterSequence: allEvents.last?.sequence ?? 0)
            if !delta.isEmpty {
                allEvents.append(contentsOf: delta)
            }
            applyFilters()
        }
    }

    @objc private func refreshSnapshotsClicked() {
        Task { [weak self] in
            guard let self else { return }
            let bundle = await DiagnosticSnapshotCoordinator.shared.captureAll()
            let encoder = DiagnosticJSONLCodec.makeEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let json = (try? encoder.encode(bundle)).flatMap { String(data: $0, encoding: .utf8) } ?? "unavailable"
            self.reportTextView.string = json
        }
    }

    private func renderPerformanceTab() {
        let summaries = DiagnosticPerformanceAggregator.shared.allSummaries()
        if summaries.isEmpty {
            reportTextView.string = "Performance metrics: unavailable (no real samples recorded yet)."
            return
        }
        let encoder = DiagnosticJSONLCodec.makeEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        reportTextView.string = (try? encoder.encode(summaries)).flatMap { String(data: $0, encoding: .utf8) } ?? "unavailable"
    }

    @objc private func copySummaryClicked() {
        Task {
            let retained = await AppLogger.shared.exportRetained(timeoutSeconds: 1.5)
            let snapshots = await DiagnosticSnapshotCoordinator.shared.captureAll()
            let perf = DiagnosticPerformanceAggregator.shared.allSummaries()
            let md = DiagnosticBundleExporter.buildSummaryMarkdown(
                retained: retained,
                snapshots: snapshots,
                perf: perf,
                environment: AppLogger.shared.environment
            )
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(md, forType: .string)
        }
    }

    @objc private func exportZipClicked() {
        let savePanel = NSSavePanel()
        savePanel.allowedContentTypes = [.zip]
        savePanel.nameFieldStringValue = "AirMuse_Diagnostics_\(AppLogger.shared.runID.uuidString.prefix(8)).zip"
        savePanel.begin { response in
            guard response == .OK, let url = savePanel.url else { return }
            Task {
                _ = try? await DiagnosticBundleExporter.exportBundle(to: url)
            }
        }
    }

    @objc private func clearViewClicked() {
        AppLogger.shared.clear()
        allEvents.removeAll()
        filteredEvents.removeAll()
        applyFilters()
        detailTextView.string = ""
    }

    @objc private func deleteLogsClicked() {
        let alert = NSAlert()
        alert.messageText = "删除本地诊断日志？"
        alert.informativeText = "这将永久清除内存与磁盘保留的诊断日志分段，不会影响播放状态或用户资料库。"
        alert.addButton(withTitle: "删除")
        alert.addButton(withTitle: "取消")
        if alert.runModal() == .alertFirstButtonReturn {
            Task { [weak self] in
                await AppLogger.shared.deleteAllLogs()
                await MainActor.run {
                    self?.allEvents.removeAll()
                    self?.applyFilters()
                }
            }
        }
    }

    @objc private func activeProbeClicked() {
        let alert = NSAlert()
        alert.messageText = "执行主动网络诊断探测？"
        alert.informativeText = "默认诊断仅使用本地只读状态。确认后将发起一次只读网络探测并记录独立 Trace。"
        alert.addButton(withTitle: "确认探测")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let probeTrace = DiagnosticTrace.makeRoot()
        AppLogger.shared.emit(
            eventName: "diagnostic.probe.requested",
            category: "DIAGNOSTICS",
            level: .info,
            phase: .begin,
            traceContext: probeTrace,
            source: DiagnosticSourceLocation(module: "UI", component: "LogWindowController", function: "activeProbeClicked"),
            payload: { DiagnosticEventPayload(fields: ["probeKind": .string("explicit_user_probe"), "userConsent": .bool(true)], message: "User confirmed active probe") }
        )

        Task { [weak self] in
            guard let self else { return }
            do {
                let summary: String
                if let activeProbe = self.activeProbe {
                    summary = try await DiagnosticTrace.withContext(probeTrace) { try await activeProbe() }
                } else if let diagnosticFetch = self.diagnosticFetch {
                    let tracks = try await DiagnosticTrace.withContext(probeTrace) { try await diagnosticFetch() }
                    summary = "tracks=\(tracks.count)"
                } else {
                    AppLogger.shared.emit(
                        eventName: "diagnostic.probe.completed",
                        category: "DIAGNOSTICS",
                        level: .warn,
                        phase: .end,
                        outcome: .unsupported,
                        traceContext: probeTrace,
                        source: DiagnosticSourceLocation(module: "UI", component: "LogWindowController", function: "activeProbeClicked"),
                        payload: { DiagnosticEventPayload(message: "No active platform probe attached") }
                    )
                    return
                }
                AppLogger.shared.emit(
                    eventName: "diagnostic.probe.completed",
                    category: "DIAGNOSTICS",
                    level: .info,
                    phase: .end,
                    outcome: .succeeded,
                    traceContext: probeTrace,
                    source: DiagnosticSourceLocation(module: "UI", component: "LogWindowController", function: "activeProbeClicked"),
                    payload: { DiagnosticEventPayload(fields: ["summary": .string(summary)], message: "Active probe succeeded (\(summary))") }
                )
            } catch {
                AppLogger.shared.emit(
                    eventName: "diagnostic.probe.completed",
                    category: "DIAGNOSTICS",
                    level: .error,
                    phase: .end,
                    outcome: .failed,
                    traceContext: probeTrace,
                    source: DiagnosticSourceLocation(module: "UI", component: "LogWindowController", function: "activeProbeClicked"),
                    payload: { DiagnosticEventPayload(error: LogSanitizer.sanitizeError(error, stage: "active_probe"), message: "Active probe failed") }
                )
            }
        }
    }
}
