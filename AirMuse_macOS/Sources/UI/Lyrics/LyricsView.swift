import AppKit
import Domain
import DesignSystem
import Infrastructure

// MARK: - LyricsView

private class FlippedStackView: NSStackView {
    override var isFlipped: Bool { true }
}

/// Synced lyrics presentation view with smooth spring auto-scrolling, AIRPLAY palette,
/// and dedicated single-line soft-halo mini-lyrics mode.
open class LyricsView: NSView {

    public var onAdjustOffset: ((Int64) -> Void)?

    private let scrollView = NSScrollView()
    private let documentView = FlippedStackView()
    private let statusLabel = NSTextField(labelWithString: "暂无歌词")
    private let miniLyricView = CarouselHaloTextView()

    private let offsetControlBar = NSView()
    private let offsetLabel = NSTextField(labelWithString: "偏移: 0.0s")
    private let minusButton = GlassButton(image: NSImage(systemSymbolName: "minus", accessibilityDescription: "-0.5s"), size: CGSize(width: 24, height: 24))
    private let plusButton = GlassButton(image: NSImage(systemSymbolName: "plus", accessibilityDescription: "+0.5s"), size: CGSize(width: 24, height: 24))

    private var currentDocument: LyricsDocument = .empty
    private var activeLineIndex: Int = -1
    private var currentOffsetMs: Int64 = 0
    private var isMiniMode: Bool = false

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupViews()
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupViews()
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

        statusLabel.font = DesignTokens.Typography.titleFont
        statusLabel.textColor = OriginalDesignTokens.Colors.subSilver
        statusLabel.alignment = .center
        addSubview(statusLabel)

        miniLyricView.isHidden = true
        addSubview(miniLyricView)

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

    public func setMiniMode(_ mini: Bool) {
        isMiniMode = mini
        needsLayout = true
        updateMiniLyricText()
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
            let leftPad = 14.0 * s
            miniLyricView.frame = NSRect(x: leftPad, y: 0, width: max(20, bounds.width - leftPad * 2.0), height: bounds.height)
            return
        }

        let barH: CGFloat = 32
        offsetControlBar.frame = NSRect(x: 0, y: 0, width: bounds.width, height: barH)
        scrollView.frame = NSRect(x: 0, y: barH, width: bounds.width, height: max(10, bounds.height - barH))
        statusLabel.frame = NSRect(x: 0, y: (bounds.height - 36) / 2, width: bounds.width, height: 36)

        if currentDocument.lines.isEmpty {
            statusLabel.isHidden = false
            scrollView.isHidden = true
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
        currentDocument = doc
        currentOffsetMs = doc.offsetMs
        updateOffsetLabel()

        documentView.arrangedSubviews.forEach { $0.removeFromSuperview() }
        activeLineIndex = -1
        scrollView.contentView.setBoundsOrigin(NSPoint(x: 0, y: 0))

        updateMiniLyricText()

        if doc.lines.isEmpty {
            statusLabel.stringValue = doc.statusText
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

        for line in doc.lines {
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
        scrollView.contentView.animator().setBoundsOrigin(NSPoint(x: 0, y: 0))
        for view in documentView.arrangedSubviews {
            guard let stack = view as? NSStackView,
                  let mainLabel = stack.arrangedSubviews.first as? NSTextField else { continue }
            mainLabel.font = DesignTokens.Typography.lyricsNormal
            mainLabel.textColor = OriginalDesignTokens.Colors.dimSilver
            stack.animator().alphaValue = 0.70
        }
    }

    public func updatePlaybackPosition(ms: Int64) {
        guard !currentDocument.lines.isEmpty else { return }
        let adjustedMs = ms - currentOffsetMs

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
        highlightActiveLine(index: newIdx)
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

    private func highlightActiveLine(index: Int) {
        if index <= 0 {
            scrollView.contentView.animator().setBoundsOrigin(NSPoint(x: 0, y: 0))
        }
        let subviews = documentView.arrangedSubviews
        for (i, view) in subviews.enumerated() {
            guard let stack = view as? NSStackView,
                  let mainLabel = stack.arrangedSubviews.first as? NSTextField else { continue }

            let isActive = (i == index)
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.20
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

            if isActive && index > 0 {
                let targetY = view.frame.origin.y - (scrollView.contentView.bounds.height / 2) + (view.frame.height / 2)
                let maxY = max(0, documentView.frame.height - scrollView.contentView.bounds.height)
                let clampedY = max(0, min(maxY, targetY))
                scrollView.contentView.animator().setBoundsOrigin(NSPoint(x: 0, y: clampedY))
            }
        }
    }

    private func updateOffsetLabel() {
        let sec = Double(currentOffsetMs) / 1000.0
        offsetLabel.stringValue = String(format: "偏移: %+.1fs", sec)
    }
}
