import AppKit
import QuartzCore
import Domain
import DesignSystem
import Infrastructure

// MARK: - LyricsView (M18)

private class FlippedStackView: NSStackView {
    override var isFlipped: Bool { true }
}

/// Synced lyrics presentation view with M18 time-anchored spring scrolling (320ms),
/// out-of-order line normalization, seek jump snap, manual-scroll pause with resume pill,
/// and dedicated single-line soft-halo mini-lyrics mode.
open class LyricsView: NSView {

    public var onAdjustOffset: ((Int64) -> Void)?

    private let lyricsMotionID = "LyricsView-\(UUID().uuidString)"
    private let scrollView = NSScrollView()
    private let documentView = FlippedStackView()
    private let statusLabel = NSTextField(labelWithString: "暂无歌词")
    private let miniLyricView = CarouselHaloTextView()
    private let resumeFollowButton = NSButton()

    private let offsetControlBar = NSView()
    private let offsetLabel = NSTextField(labelWithString: "偏移: 0.0s")
    private let minusButton = GlassButton(image: NSImage(systemSymbolName: "minus", accessibilityDescription: "-0.5s"), size: CGSize(width: 24, height: 24))
    private let plusButton = GlassButton(image: NSImage(systemSymbolName: "plus", accessibilityDescription: "+0.5s"), size: CGSize(width: 24, height: 24))

    private var currentDocument: LyricsDocument = .empty
    public private(set) var activeLineIndex: Int = -1
    private var currentOffsetMs: Int64 = 0
    private var isMiniMode: Bool = false
    private var lastPlaybackPositionMs: Int64 = 0

    /// M18: Manual scroll pause state; resets on resume click, track switch, or view hide.
    public private(set) var isManualScrollPaused: Bool = false

    private var scrollDriverID: UUID?
    private var scrollTicket: MotionTicket?

    public override var mouseDownCanMoveWindow: Bool { false }

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupViews()
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupViews()
    }

    isolated deinit {
        stopScrollDriver()
        MotionCoordinator.shared.cancelAll(owner: lyricsMotionID)
        NotificationCenter.default.removeObserver(self)
    }

    private func setupViews() {
        wantsLayer = true

        scrollView.drawsBackground = false
        scrollView.applySubtleOverlayScrollbar()

        documentView.orientation = .vertical
        documentView.alignment = .centerX
        documentView.spacing = 18
        documentView.edgeInsets = NSEdgeInsets(top: 100, left: 20, bottom: 100, right: 20)
        scrollView.documentView = documentView
        addSubview(scrollView)

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleUserDidStartLiveScroll),
            name: NSScrollView.willStartLiveScrollNotification,
            object: scrollView
        )

        statusLabel.font = DesignTokens.Typography.titleFont
        statusLabel.textColor = OriginalDesignTokens.Colors.subSilver
        statusLabel.alignment = .center
        addSubview(statusLabel)

        miniLyricView.isHidden = true
        addSubview(miniLyricView)

        resumeFollowButton.title = "回到当前歌词"
        resumeFollowButton.bezelStyle = .inline
        resumeFollowButton.isBordered = false
        resumeFollowButton.wantsLayer = true
        resumeFollowButton.layer?.backgroundColor = NSColor(srgbRed: 30/255.0, green: 34/255.0, blue: 42/255.0, alpha: 0.90).cgColor
        resumeFollowButton.layer?.borderColor = NSColor(white: 1.0, alpha: 0.28).cgColor
        resumeFollowButton.layer?.borderWidth = 0.75
        resumeFollowButton.layer?.cornerRadius = 11
        resumeFollowButton.font = NSFont.systemFont(ofSize: 11, weight: .medium)
        resumeFollowButton.contentTintColor = OriginalDesignTokens.Colors.titleSilver
        resumeFollowButton.target = self
        resumeFollowButton.action = #selector(resumeAutoFollow)
        resumeFollowButton.isHidden = true
        addSubview(resumeFollowButton)

        offsetControlBar.wantsLayer = true
        offsetLabel.font = DesignTokens.Typography.timeFont
        offsetLabel.textColor = OriginalDesignTokens.Colors.subSilver
        offsetControlBar.addSubview(offsetLabel)

        minusButton.onClick = { [weak self] in
            guard let self else { return }
            self.currentOffsetMs -= 500
            AppLogger.shared.log(category: .userAction, level: .info, message: "用户点击歌词微调 [-0.5s] (当前偏移: \(self.currentOffsetMs)ms)")
            self.updateOffsetLabel()
            self.onAdjustOffset?(-500)
        }
        offsetControlBar.addSubview(minusButton)

        plusButton.onClick = { [weak self] in
            guard let self else { return }
            self.currentOffsetMs += 500
            AppLogger.shared.log(category: .userAction, level: .info, message: "用户点击歌词微调 [+0.5s] (当前偏移: \(self.currentOffsetMs)ms)")
            self.updateOffsetLabel()
            self.onAdjustOffset?(500)
        }
        offsetControlBar.addSubview(plusButton)
        addSubview(offsetControlBar)
    }

    @objc private func handleUserDidStartLiveScroll() {
        guard !currentDocument.lines.isEmpty, !isMiniMode else { return }
        pauseAutoFollowForManualScroll()
    }

    public func pauseAutoFollowForManualScroll() {
        isManualScrollPaused = true
        stopScrollDriver()
        resumeFollowButton.isHidden = false
    }

    @objc public func resumeAutoFollow() {
        isManualScrollPaused = false
        resumeFollowButton.isHidden = true
        if activeLineIndex >= 0 {
            scrollToLine(index: activeLineIndex, immediate: false)
        }
    }

    public func setMiniMode(_ mini: Bool) {
        isMiniMode = mini
        if mini {
            stopScrollDriver()
            resumeFollowButton.isHidden = true
        }
        needsLayout = true
        updateMiniLyricText()
    }

    open override func viewDidHide() {
        super.viewDidHide()
        stopScrollDriver()
    }

    open override func layout() {
        super.layout()
        let s = GlassInteractionCoordinator.shared.uiScale
        let mini = isMiniMode || bounds.height < 60 * s
        offsetControlBar.isHidden = mini
        miniLyricView.isHidden = !mini

        if mini {
            scrollView.isHidden = true
            statusLabel.isHidden = true
            resumeFollowButton.isHidden = true
            let leftPad = 14.0 * s
            let rightPad = 48.0 * s
            miniLyricView.frame = NSRect(x: leftPad, y: 0, width: max(20, bounds.width - leftPad - rightPad), height: bounds.height)
            return
        }

        let barH: CGFloat = 32
        offsetControlBar.frame = NSRect(x: 0, y: 0, width: bounds.width, height: barH)
        scrollView.frame = NSRect(x: 0, y: barH, width: bounds.width, height: max(10, bounds.height - barH))
        statusLabel.frame = NSRect(x: 0, y: (bounds.height - 36) / 2, width: bounds.width, height: 36)

        let btnW: CGFloat = 94
        let btnH: CGFloat = 22
        resumeFollowButton.frame = NSRect(x: bounds.width - btnW - 12, y: barH + 8, width: btnW, height: btnH)

        if currentDocument.lines.isEmpty {
            statusLabel.isHidden = false
            scrollView.isHidden = true
            resumeFollowButton.isHidden = true
        } else {
            statusLabel.isHidden = true
            scrollView.isHidden = false
        }

        minusButton.frame = NSRect(x: 14, y: 4, width: 22, height: 22)
        plusButton.frame = NSRect(x: 42, y: 4, width: 22, height: 22)
        offsetLabel.frame = NSRect(x: 72, y: 2, width: 150, height: 24)

        updateDocumentFrame()
    }

    private func updateDocumentFrame() {
        let contentWidth = max(50, scrollView.contentView.bounds.width)
        let fittingH = max(scrollView.contentView.bounds.height, documentView.fittingSize.height)
        documentView.frame = NSRect(x: 0, y: 0, width: contentWidth, height: fittingH)
    }

    private func updateMiniLyricText() {
        if !currentDocument.lines.isEmpty {
            let idx = (activeLineIndex >= 0 && activeLineIndex < currentDocument.lines.count) ? activeLineIndex : 0
            miniLyricView.setSingleLine(currentDocument.lines[idx].text)
        } else {
            miniLyricView.setSingleLine(currentDocument.statusText)
        }
    }

    public func updateLyrics(_ doc: LyricsDocument) {
        // M18: Normalize out-of-order lyrics stably by timeMs
        var normalizedDoc = doc
        if doc.lines.count > 1 {
            let isSorted = zip(doc.lines, doc.lines.dropFirst()).allSatisfy { $0.timeMs <= $1.timeMs }
            if !isSorted {
                normalizedDoc.lines = doc.lines.sorted { $0.timeMs < $1.timeMs }
            }
        }

        currentDocument = normalizedDoc
        currentOffsetMs = normalizedDoc.offsetMs
        isManualScrollPaused = false
        resumeFollowButton.isHidden = true
        stopScrollDriver()
        updateOffsetLabel()

        documentView.arrangedSubviews.forEach { $0.removeFromSuperview() }
        activeLineIndex = -1
        lastPlaybackPositionMs = 0
        scrollView.contentView.setBoundsOrigin(NSPoint(x: 0, y: 0))

        updateMiniLyricText()

        if normalizedDoc.lines.isEmpty {
            statusLabel.stringValue = normalizedDoc.statusText
            if !isMiniMode {
                statusLabel.isHidden = false
                scrollView.isHidden = true
            }
            return
        }

        if !isMiniMode {
            statusLabel.isHidden = true
            scrollView.isHidden = false
        }

        for line in normalizedDoc.lines {
            let lineView = makeLineView(for: line)
            documentView.addArrangedSubview(lineView)
        }

        needsLayout = true
        layoutSubtreeIfNeeded()
        updateDocumentFrame()
        scrollView.contentView.setBoundsOrigin(NSPoint(x: 0, y: 0))
    }

    public func resetToTop() {
        activeLineIndex = -1
        updateMiniLyricText()
        stopScrollDriver()
        if !isManualScrollPaused {
            scrollView.contentView.setBoundsOrigin(NSPoint(x: 0, y: 0))
        }
        for view in documentView.arrangedSubviews {
            guard let stack = view as? NSStackView,
                  let mainLabel = stack.arrangedSubviews.first as? NSTextField else { continue }
            mainLabel.font = DesignTokens.Typography.lyricsNormal
            mainLabel.textColor = OriginalDesignTokens.Colors.dimSilver
            stack.alphaValue = 0.70
        }
    }

    public func updatePlaybackPosition(ms: Int64) {
        let prevPos = lastPlaybackPositionMs
        lastPlaybackPositionMs = ms
        guard !currentDocument.lines.isEmpty else { return }

        let adjustedMs = ms - currentOffsetMs
        let isSeekJump = (ms < prevPos - 500) || (ms - prevPos > 1800)

        if let firstLine = currentDocument.lines.first, adjustedMs < firstLine.timeMs {
            if activeLineIndex != -1 {
                resetToTop()
            }
            return
        }

        var newIdx = -1
        for (i, line) in currentDocument.lines.enumerated() {
            if line.timeMs <= adjustedMs + 150 {
                newIdx = i
            } else {
                break
            }
        }

        guard newIdx != activeLineIndex else { return }
        activeLineIndex = newIdx
        updateMiniLyricText()
        highlightActiveLine(index: newIdx, immediateScroll: isSeekJump)
    }

    private func makeLineView(for line: LyricsLine) -> NSView {
        let container = NSStackView()
        container.orientation = .vertical
        container.alignment = .centerX
        container.spacing = 4.0

        let mainLabel = NSTextField(labelWithString: line.text)
        mainLabel.font = DesignTokens.Typography.lyricsNormal
        mainLabel.textColor = OriginalDesignTokens.Colors.dimSilver
        mainLabel.alignment = .center
        mainLabel.lineBreakMode = .byWordWrapping
        mainLabel.maximumNumberOfLines = 0
        container.addArrangedSubview(mainLabel)

        if let trans = line.translation, !trans.isEmpty {
            let transLabel = NSTextField(labelWithString: trans)
            transLabel.font = DesignTokens.Typography.artistFont
            transLabel.textColor = OriginalDesignTokens.Colors.subSilver
            transLabel.alignment = .center
            transLabel.lineBreakMode = .byWordWrapping
            transLabel.maximumNumberOfLines = 0
            container.addArrangedSubview(transLabel)
        }

        return container
    }

    private func highlightActiveLine(index: Int, immediateScroll: Bool) {
        let subviews = documentView.arrangedSubviews
        let key = TransitionKey(owner: lyricsMotionID, channel: "highlight")
        let ticket = MotionCoordinator.shared.beginTransition(for: key, category: .content)

        MotionCoordinator.shared.animate(
            duration: 0.22,
            timingFunction: .easeOut,
            ticket: ticket,
            action: {
                for (i, view) in subviews.enumerated() {
                    guard let stack = view as? NSStackView,
                          let mainLabel = stack.arrangedSubviews.first as? NSTextField else { continue }
                    let isActive = (i == index)
                    if isActive {
                        mainLabel.font = DesignTokens.Typography.lyricsActive
                        mainLabel.textColor = OriginalDesignTokens.Colors.highlightSilver
                        stack.animator().alphaValue = 1.0
                    } else {
                        mainLabel.font = DesignTokens.Typography.lyricsNormal
                        mainLabel.textColor = OriginalDesignTokens.Colors.dimSilver
                        stack.animator().alphaValue = 0.70
                    }
                }
            }
        )

        if !isManualScrollPaused && !isMiniMode {
            scrollToLine(index: index, immediate: immediateScroll)
        }
    }

    private func scrollToLine(index: Int, immediate: Bool) {
        let subviews = documentView.arrangedSubviews
        guard index >= 0 && index < subviews.count else { return }

        documentView.layoutSubtreeIfNeeded()
        updateDocumentFrame()

        let targetY: CGFloat
        if index <= 0 {
            targetY = 0
        } else {
            let view = subviews[index]
            let rawY = view.frame.origin.y - (scrollView.contentView.bounds.height / 2) + (view.frame.height / 2)
            let maxY = max(0, documentView.frame.height - scrollView.contentView.bounds.height)
            targetY = max(0, min(maxY, rawY))
        }

        stopScrollDriver()
        let key = TransitionKey(owner: lyricsMotionID, channel: "scroll")
        let ticket = MotionCoordinator.shared.beginTransition(for: key, category: .content) { [weak self] in
            self?.stopScrollDriver()
        }
        scrollTicket = ticket

        if immediate || MotionCoordinator.shared.isReduceMotionEnabled || window == nil || isHidden {
            scrollView.contentView.setBoundsOrigin(NSPoint(x: 0, y: targetY))
            _ = MotionCoordinator.shared.complete(ticket)
            scrollTicket = nil
            return
        }

        let startY = scrollView.contentView.bounds.origin.y
        var elapsed: TimeInterval = 0
        let total = MotionTokens.Duration.lyricLineScroll
        scrollDriverID = MotionCoordinator.shared.displayDriver.start { [weak self] dt, _ in
            guard let self, MotionCoordinator.shared.isCurrent(ticket), !self.isManualScrollPaused else {
                return false
            }
            elapsed += dt
            let raw = min(1.0, elapsed / max(0.01, total))
            let t = CGFloat(1.0 - pow(1.0 - raw, 3.0))
            let curY = startY + (targetY - startY) * t
            self.scrollView.contentView.setBoundsOrigin(NSPoint(x: 0, y: curY))
            if raw >= 1.0 {
                if MotionCoordinator.shared.complete(ticket) {
                    self.scrollDriverID = nil
                    self.scrollTicket = nil
                }
                return false
            }
            return true
        }
    }

    private func stopScrollDriver() {
        if let id = scrollDriverID {
            MotionCoordinator.shared.displayDriver.stop(id: id)
            scrollDriverID = nil
        }
        scrollTicket = nil
    }

    private func updateOffsetLabel() {
        let sec = Double(currentOffsetMs) / 1000.0
        offsetLabel.stringValue = String(format: "偏移: %+.1fs", sec)
    }
}
