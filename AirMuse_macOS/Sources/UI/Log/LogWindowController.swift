import AppKit
import DesignSystem
import Infrastructure
import Providers

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
        minSize = NSSize(width: 420, height: 280)
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    }

    open override var canBecomeKey: Bool { true }
    open override var canBecomeMain: Bool { true }
}

// MARK: - LogWindowController

@MainActor
open class LogWindowController: NSWindowController {

    private let panel = GlassPanel()
    private let titleLabel = NSTextField(labelWithString: "AirMuse Core V2 诊断日志")
    private let badgeLabel = NSTextField(labelWithString: "0 条")
    private let copyButton = NSButton()
    private let refreshButton = NSButton()
    private let clearButton = NSButton()
    private let closeButton = GlassButton(image: NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close"), size: CGSize(width: 14, height: 14))

    private let scrollView = NSScrollView()
    private let textView = NSTextView()

    private var appleMusicProvider: AppleMusicProvider?
    private var diagnosticsProvider: (@Sendable () async -> String)?

    public init(
        appleMusicProvider: AppleMusicProvider? = nil,
        diagnosticsProvider: (@Sendable () async -> String)? = nil
    ) {
        self.appleMusicProvider = appleMusicProvider
        self.diagnosticsProvider = diagnosticsProvider

        let screenFrame = NSScreen.main?.visibleFrame ?? NSRect(x: 100, y: 100, width: 1200, height: 800)
        let rect = NSRect(
            x: screenFrame.minX + 40,
            y: screenFrame.maxY - 460,
            width: 560,
            height: 420
        )
        let window = LogWindow(contentRect: rect)
        super.init(window: window)

        setupUI(window)
        loadInitialLogs()
        listenForNewLogs()
    }

    public required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupUI(_ window: LogWindow) {
        window.contentView = panel

        let container = panel.contentView

        // Header
        titleLabel.font = NSFont.systemFont(ofSize: 11.5, weight: .semibold)
        titleLabel.textColor = NSColor(white: 0.95, alpha: 1.0)
        container.addSubview(titleLabel)

        badgeLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 9.5, weight: .regular)
        badgeLabel.textColor = NSColor(white: 0.55, alpha: 1.0)
        container.addSubview(badgeLabel)

        // Copy button
        copyButton.title = "📋 复制日志"
        copyButton.font = NSFont.systemFont(ofSize: 9.5, weight: .medium)
        copyButton.bezelStyle = .roundRect
        copyButton.contentTintColor = NSColor(calibratedRed: 0.15, green: 0.15, blue: 0.15, alpha: 1.0)
        copyButton.wantsLayer = true
        copyButton.layer?.backgroundColor = NSColor(calibratedRed: 0.88, green: 0.88, blue: 0.90, alpha: 1.0).cgColor
        copyButton.layer?.cornerRadius = 4
        copyButton.target = self
        copyButton.action = #selector(copyLogsClicked)
        container.addSubview(copyButton)

        // Refresh test button
        refreshButton.title = "🔄 V2 诊断"
        refreshButton.font = NSFont.systemFont(ofSize: 9.5, weight: .regular)
        refreshButton.bezelStyle = .recessed
        refreshButton.contentTintColor = NSColor(white: 0.75, alpha: 1.0)
        refreshButton.target = self
        refreshButton.action = #selector(testFetchClicked)
        container.addSubview(refreshButton)

        // Clear button
        clearButton.title = "🗑 清空"
        clearButton.font = NSFont.systemFont(ofSize: 9.5, weight: .regular)
        clearButton.bezelStyle = .recessed
        clearButton.contentTintColor = NSColor(white: 0.60, alpha: 1.0)
        clearButton.target = self
        clearButton.action = #selector(clearLogsClicked)
        container.addSubview(clearButton)

        // Close button
        closeButton.onClick = { [weak self] in
            self?.window?.orderOut(nil)
        }
        container.addSubview(closeButton)

        // Text Scroll View
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true

        textView.isEditable = false
        textView.isSelectable = true
        textView.backgroundColor = NSColor(calibratedRed: 0.07, green: 0.07, blue: 0.09, alpha: 0.85)
        textView.textColor = NSColor(calibratedRed: 0.90, green: 0.90, blue: 0.92, alpha: 1.0)
        textView.font = NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)
        textView.textContainerInset = NSSize(width: 8, height: 8)
        textView.isHorizontallyResizable = true
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = false
        textView.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)

        scrollView.documentView = textView
        container.addSubview(scrollView)

        panel.onLayout = { [weak self] _ in
            self?.layoutViews()
        }
        layoutViews()
    }

    private func layoutViews() {
        guard let contentView = panel.contentView as NSView? else { return }
        let bounds = contentView.bounds
        let w = bounds.width
        let h = bounds.height

        titleLabel.frame = NSRect(x: 10, y: 8, width: 170, height: 18)
        badgeLabel.frame = NSRect(x: 184, y: 9, width: 60, height: 16)

        closeButton.frame = NSRect(x: w - 24, y: 8, width: 16, height: 16)
        copyButton.frame = NSRect(x: w - 114, y: 6, width: 84, height: 22)
        refreshButton.frame = NSRect(x: w - 198, y: 6, width: 80, height: 22)
        clearButton.frame = NSRect(x: w - 256, y: 6, width: 54, height: 22)

        let topH: CGFloat = 34
        scrollView.frame = NSRect(x: 6, y: topH, width: max(10, w - 12), height: max(10, h - topH - 8))
    }

    private func loadInitialLogs() {
        let entries = AppLogger.shared.getEntries()
        badgeLabel.stringValue = "\(entries.count) 条"
        let fullText = NSMutableAttributedString()
        for entry in entries {
            fullText.append(formatEntry(entry))
            fullText.append(NSAttributedString(string: "\n"))
        }
        textView.textStorage?.setAttributedString(fullText)
        scrollToBottom()
    }

    private func listenForNewLogs() {
        AppLogger.shared.onNewEntry = { [weak self] entry in
            guard let self else { return }
            let formatted = self.formatEntry(entry)
            let newline = NSAttributedString(string: "\n")

            if let storage = self.textView.textStorage {
                storage.append(formatted)
                storage.append(newline)
            }
            let count = AppLogger.shared.getEntries().count
            self.badgeLabel.stringValue = "\(count) 条"
            self.scrollToBottom()
        }
    }

    private func formatEntry(_ entry: LogEntry) -> NSAttributedString {
        let result = NSMutableAttributedString()

        // Time
        let timeAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 9.5, weight: .regular),
            .foregroundColor: NSColor(white: 0.50, alpha: 1.0)
        ]
        result.append(NSAttributedString(string: "[\(entry.formattedTime)] ", attributes: timeAttrs))

        // Level
        let levelColor: NSColor = switch entry.level {
        case .info:  NSColor(calibratedRed: 0.40, green: 0.70, blue: 0.95, alpha: 1.0)
        case .debug: NSColor(white: 0.65, alpha: 1.0)
        case .warn:  NSColor(calibratedRed: 0.95, green: 0.75, blue: 0.20, alpha: 1.0)
        case .error: NSColor(calibratedRed: 0.95, green: 0.30, blue: 0.35, alpha: 1.0)
        }
        let levelAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 9.5, weight: .semibold),
            .foregroundColor: levelColor
        ]
        result.append(NSAttributedString(string: "[\(entry.level.rawValue)] ", attributes: levelAttrs))

        // Category
        let catColor: NSColor = switch entry.category {
        case .lifecycle:  NSColor(calibratedRed: 0.75, green: 0.45, blue: 0.95, alpha: 1.0) // purple
        case .userAction: NSColor(calibratedRed: 0.98, green: 0.70, blue: 0.20, alpha: 1.0) // gold/yellow
        case .session:    NSColor(calibratedRed: 0.35, green: 0.85, blue: 0.95, alpha: 1.0) // bright cyan
        case .auth:       NSColor(calibratedRed: 0.95, green: 0.40, blue: 0.65, alpha: 1.0) // pink
        case .engine:     NSColor(calibratedRed: 0.95, green: 0.55, blue: 0.25, alpha: 1.0) // coral orange
        case .injection:  NSColor(calibratedRed: 0.95, green: 0.65, blue: 0.20, alpha: 1.0) // amber
        case .ampAPI:     NSColor(calibratedRed: 0.15, green: 0.80, blue: 0.90, alpha: 1.0) // cyan
        case .musicKit:   NSColor(calibratedRed: 0.30, green: 0.65, blue: 1.00, alpha: 1.0) // blue
        case .render:     NSColor(calibratedRed: 0.25, green: 0.85, blue: 0.55, alpha: 1.0) // emerald
        case .playback:   NSColor(calibratedRed: 0.85, green: 0.50, blue: 0.95, alpha: 1.0) // violet
        case .lyrics:     NSColor(calibratedRed: 0.40, green: 0.85, blue: 0.65, alpha: 1.0) // mint
        case .cache:      NSColor(calibratedRed: 0.60, green: 0.75, blue: 0.95, alpha: 1.0) // sky blue
        case .database:   NSColor(calibratedRed: 0.80, green: 0.60, blue: 0.90, alpha: 1.0) // lavender
        case .network:    NSColor(calibratedRed: 0.40, green: 0.85, blue: 0.85, alpha: 1.0) // teal
        case .error:      NSColor(calibratedRed: 0.95, green: 0.25, blue: 0.25, alpha: 1.0) // red
        }
        let catAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 9.5, weight: .bold),
            .foregroundColor: catColor
        ]
        result.append(NSAttributedString(string: "[\(entry.category.rawValue)] ", attributes: catAttrs))

        // Correlation ID
        if let corr = entry.correlationID, !corr.isEmpty {
            let corrAttrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedSystemFont(ofSize: 9.0, weight: .medium),
                .foregroundColor: NSColor(white: 0.55, alpha: 1.0)
            ]
            result.append(NSAttributedString(string: "[\(corr)] ", attributes: corrAttrs))
        }

        // Message
        let msgAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 10, weight: .regular),
            .foregroundColor: entry.level == .error ? NSColor(calibratedRed: 1.0, green: 0.4, blue: 0.4, alpha: 1.0) : NSColor(white: 0.92, alpha: 1.0)
        ]
        result.append(NSAttributedString(string: entry.message, attributes: msgAttrs))

        // Details
        if let details = entry.details, !details.isEmpty {
            let detailAttrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedSystemFont(ofSize: 9, weight: .regular),
                .foregroundColor: NSColor(white: 0.60, alpha: 1.0)
            ]
            result.append(NSAttributedString(string: "\n  ↳ \(details)", attributes: detailAttrs))
        }

        return result
    }

    private func scrollToBottom() {
        guard let textStorage = textView.textStorage else { return }
        let endRange = NSRange(location: textStorage.length, length: 0)
        textView.scrollRangeToVisible(endRange)
    }

    @objc private func copyLogsClicked() {
        let md = AppLogger.shared.exportMarkdown()
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(md, forType: .string)

        copyButton.title = "✓ 已复制到剪贴板!"
        copyButton.layer?.backgroundColor = NSColor(calibratedRed: 0.20, green: 0.75, blue: 0.40, alpha: 1.0).cgColor
        copyButton.contentTintColor = .white

        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            self?.copyButton.title = "📋 复制日志"
            self?.copyButton.layer?.backgroundColor = NSColor(calibratedRed: 0.88, green: 0.88, blue: 0.90, alpha: 1.0).cgColor
            self?.copyButton.contentTintColor = NSColor(calibratedRed: 0.15, green: 0.15, blue: 0.15, alpha: 1.0)
        }
    }

    @objc private func clearLogsClicked() {
        AppLogger.shared.clear()
        textView.string = ""
        badgeLabel.stringValue = "0 条"
        AppLogger.shared.log(category: .lifecycle, level: .info, message: "日志已清空")
    }

    @objc private func testFetchClicked() {
        let diagID = "diag-\(UUID().uuidString.prefix(6))"
        AppLogger.shared.log(category: .lifecycle, level: .info, correlationID: diagID, message: "开始执行 Core V2 全链路诊断自检...")
        Task { [weak self] in
            guard let self else { return }
            if let diag = self.diagnosticsProvider {
                let summary = await diag()
                AppLogger.shared.log(category: .lifecycle, level: .info, correlationID: diagID, message: "Core V2 子系统实时快照", details: summary)
            }
            do {
                if let provider = self.appleMusicProvider {
                    let tracks = try await provider.fetchTopCharts()
                    AppLogger.shared.log(
                        category: .ampAPI,
                        level: .info,
                        correlationID: diagID,
                        message: "诊断测试成功: 成功拉取到 \(tracks.count) 首榜单曲目",
                        details: "首曲: \(tracks.first?.title ?? "none") - \(tracks.first?.artistName ?? "")"
                    )
                } else {
                    AppLogger.shared.log(category: .ampAPI, level: .warn, correlationID: diagID, message: "AppleMusicProvider 未挂载")
                }
            } catch {
                AppLogger.shared.log(
                    category: .error,
                    level: .error,
                    correlationID: diagID,
                    message: "诊断测试失败: \(error.localizedDescription)",
                    details: "\(error)"
                )
            }
        }
    }
}
