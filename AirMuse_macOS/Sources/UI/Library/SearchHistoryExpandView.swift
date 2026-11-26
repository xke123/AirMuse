import AppKit
import DesignSystem

// MARK: - SearchHistoryExpandView

/// Liquid Glass expandable floating panel below the search bar showing up to 5 recent searches
/// with single-item delete and clear-all actions.
@MainActor
public final class SearchHistoryExpandView: NSView {

    public override var isFlipped: Bool { true }

    public var onSelectQuery: ((String) -> Void)?
    public var onDeleteQuery: ((String) -> Void)?
    public var onClearAll: (() -> Void)?

    private let glassContainer = NSGlassEffectContainerView(frame: .zero)
    private let glassView = NSGlassEffectView(frame: .zero)
    private let fallbackLayer = CALayer()
    private let headerLabel = NSTextField(labelWithString: "最近搜索")
    private let clearAllButton = NSButton()
    private let rowsStack = NSStackView()

    private let motionID = "SearchHistoryExpand-\(UUID().uuidString)"
    private var currentQueries: [String] = []

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        wantsLayer = true
        layer?.cornerRadius = 14
        layer?.masksToBounds = true
        isHidden = true
        alphaValue = 0.0

        fallbackLayer.backgroundColor = NSColor(srgbRed: 22 / 255.0, green: 24 / 255.0, blue: 28 / 255.0, alpha: 0.94).cgColor
        fallbackLayer.borderColor = NSColor(white: 1.0, alpha: 0.24).cgColor
        fallbackLayer.borderWidth = 0.75
        fallbackLayer.cornerRadius = 14
        layer?.addSublayer(fallbackLayer)

        glassView.style = .regular
        glassView.cornerRadius = 14
        glassContainer.addSubview(glassView)
        addSubview(glassContainer)

        headerLabel.font = NSFont.systemFont(ofSize: 11.5, weight: .semibold)
        headerLabel.textColor = NSColor(white: 0.65, alpha: 1.0)
        addSubview(headerLabel)

        clearAllButton.title = "全部清除"
        clearAllButton.bezelStyle = .regularSquare
        clearAllButton.isBordered = false
        clearAllButton.font = NSFont.systemFont(ofSize: 11.5, weight: .medium)
        clearAllButton.contentTintColor = NSColor(red: 0.98, green: 0.28, blue: 0.40, alpha: 1.0)
        clearAllButton.target = self
        clearAllButton.action = #selector(clearAllClicked)
        addSubview(clearAllButton)

        rowsStack.orientation = .vertical
        rowsStack.alignment = .leading
        rowsStack.spacing = 2
        addSubview(rowsStack)

        updateMaterialMode()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAppearanceChange),
            name: GlassInteractionCoordinator.modeDidChangeNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAppearanceChange),
            name: MotionAccessibility.preferencesDidChangeNotification,
            object: nil
        )
    }

    isolated deinit {
        NotificationCenter.default.removeObserver(self)
        MotionCoordinator.shared.cancel(key: TransitionKey(owner: motionID, channel: "expand"))
    }

    @objc private func handleAppearanceChange() {
        updateMaterialMode()
    }

    private func updateMaterialMode() {
        let useGlass = GlassInteractionCoordinator.shared.isEnhancedMode && !MotionCoordinator.shared.isReduceTransparencyEnabled
        glassContainer.isHidden = !useGlass
        fallbackLayer.isHidden = useGlass
    }

    public func updateQueries(_ queries: [String]) {
        currentQueries = Array(queries.prefix(5))
        rowsStack.arrangedSubviews.forEach { $0.removeFromSuperview() }

        for q in currentQueries {
            let row = SearchHistoryRowView(query: q)
            row.onSelect = { [weak self] query in
                self?.onSelectQuery?(query)
            }
            row.onDelete = { [weak self] query in
                self?.onDeleteQuery?(query)
            }
            row.translatesAutoresizingMaskIntoConstraints = false
            rowsStack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: rowsStack.widthAnchor).isActive = true
            row.heightAnchor.constraint(equalToConstant: 28).isActive = true
        }
        needsLayout = true
    }

    public var preferredHeight: CGFloat {
        guard !currentQueries.isEmpty else { return 0 }
        let headerH: CGFloat = 28
        let rowsH = CGFloat(currentQueries.count) * 28 + CGFloat(max(0, currentQueries.count - 1)) * 2
        return headerH + rowsH + 10
    }

    public func setExpanded(_ expanded: Bool, animated: Bool = true) {
        let shouldShow = expanded && !currentQueries.isEmpty
        let key = TransitionKey(owner: motionID, channel: "expand")
        let ticket = MotionCoordinator.shared.beginTransition(for: key, category: .controlInteraction)

        if !animated || MotionCoordinator.shared.isReduceMotionEnabled || window == nil {
            isHidden = !shouldShow
            alphaValue = shouldShow ? 1.0 : 0.0
            layer?.setAffineTransform(.identity)
            _ = MotionCoordinator.shared.complete(ticket)
            return
        }

        if shouldShow {
            isHidden = false
            alphaValue = 0.0
            layer?.setAffineTransform(CGAffineTransform(translationX: 0, y: -8).scaledBy(x: 0.98, y: 0.92))
        }

        MotionCoordinator.shared.animate(
            duration: MotionTokens.Duration.searchFocus,
            timingFunction: .easeOut,
            ticket: ticket,
            action: {
                self.animator().alphaValue = shouldShow ? 1.0 : 0.0
                self.layer?.setAffineTransform(
                    shouldShow ? .identity : CGAffineTransform(translationX: 0, y: -6).scaledBy(x: 0.98, y: 0.94)
                )
            },
            completion: { [weak self] committed in
                guard committed, let self else { return }
                self.isHidden = !shouldShow
                self.layer?.setAffineTransform(.identity)
            }
        )
    }

    public override func layout() {
        super.layout()
        glassContainer.frame = bounds
        glassView.frame = bounds
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        fallbackLayer.frame = bounds
        CATransaction.commit()

        let padX: CGFloat = 12
        headerLabel.frame = NSRect(x: padX, y: 7, width: 120, height: 18)
        clearAllButton.frame = NSRect(x: bounds.width - padX - 60, y: 6, width: 60, height: 20)
        rowsStack.frame = NSRect(x: 6, y: 28, width: max(20, bounds.width - 12), height: max(0, bounds.height - 34))
    }

    @objc private func clearAllClicked() {
        onClearAll?()
    }
}

// MARK: - SearchHistoryRowView

@MainActor
private final class SearchHistoryRowView: NSView {
    override var isFlipped: Bool { true }

    private let query: String
    var onSelect: ((String) -> Void)?
    var onDelete: ((String) -> Void)?

    private let iconView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let deleteButton = NSButton()
    private var trackingArea: NSTrackingArea?
    private var isHovered = false {
        didSet { needsDisplay = true }
    }

    init(query: String) {
        self.query = query
        super.init(frame: .zero)
        setup()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setup() {
        wantsLayer = true
        layer?.cornerRadius = 7

        let cfg = NSImage.SymbolConfiguration(pointSize: 11.5, weight: .regular)
        iconView.image = NSImage(systemSymbolName: "clock.arrow.circlepath", accessibilityDescription: nil)?
            .withSymbolConfiguration(cfg)
        iconView.contentTintColor = NSColor(white: 0.62, alpha: 1.0)
        addSubview(iconView)

        titleLabel.stringValue = query
        titleLabel.font = NSFont.systemFont(ofSize: 12.5, weight: .regular)
        titleLabel.textColor = NSColor(white: 0.92, alpha: 1.0)
        titleLabel.lineBreakMode = .byTruncatingTail
        addSubview(titleLabel)

        deleteButton.bezelStyle = .regularSquare
        deleteButton.isBordered = false
        deleteButton.toolTip = "删除"
        let delCfg = NSImage.SymbolConfiguration(pointSize: 10.5, weight: .semibold)
        deleteButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "删除")?.withSymbolConfiguration(delCfg)
        deleteButton.contentTintColor = NSColor(white: 0.62, alpha: 1.0)
        deleteButton.target = self
        deleteButton.action = #selector(deleteClicked)
        addSubview(deleteButton)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = trackingArea { removeTrackingArea(existing) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) { isHovered = false }

    override func draw(_ dirtyRect: NSRect) {
        if isHovered {
            NSColor(white: 1.0, alpha: 0.11).setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 7, yRadius: 7).fill()
        }
    }

    override func layout() {
        super.layout()
        let h = bounds.height
        iconView.frame = NSRect(x: 8, y: (h - 14) * 0.5, width: 14, height: 14)
        deleteButton.frame = NSRect(x: bounds.width - 26, y: (h - 20) * 0.5, width: 20, height: 20)
        titleLabel.frame = NSRect(x: 28, y: (h - 16) * 0.5, width: max(20, deleteButton.frame.minX - 32), height: 16)
    }

    override func mouseUp(with event: NSEvent) {
        let pt = convert(event.locationInWindow, from: nil)
        guard bounds.contains(pt), !deleteButton.frame.contains(pt) else { return }
        onSelect?(query)
    }

    @objc private func deleteClicked() {
        onDelete?(query)
    }
}
