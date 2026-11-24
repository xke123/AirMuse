import AppKit
import DesignSystem

// MARK: - SidebarCategory

public struct SidebarCategory: Identifiable, Sendable {
    public let id: String
    public let title: String
    public let iconName: String?

    public init(id: String, title: String, iconName: String? = nil) {
        self.id = id
        self.title = title
        self.iconName = iconName
    }
}

// MARK: - SidebarCategoryItemView

@MainActor
final class SidebarCategoryItemView: NSView {
    override var isFlipped: Bool { true }

    let title: String
    var onClick: (() -> Void)?

    var isSelected: Bool = false {
        didSet {
            guard oldValue != isSelected else { return }
            if isSelected {
                startMarqueeIfNeeded()
            } else {
                stopMarquee()
            }
            needsDisplay = true
        }
    }

    private var trackingArea: NSTrackingArea?
    private var isHovered: Bool = false {
        didSet {
            needsDisplay = true
        }
    }

    private var scrollOffset: CGFloat = 0
    private var marqueeDwellTask: Task<Void, Never>?
    private var marqueeDriverID: UUID?

    init(title: String) {
        self.title = title
        super.init(frame: .zero)
        wantsLayer = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    isolated deinit {
        stopMarquee()
    }

    private var currentFont: NSFont {
        NSFont.systemFont(ofSize: 13.5, weight: isSelected ? .semibold : .regular)
    }

    private var currentTextColor: NSColor {
        if isSelected {
            return .white
        } else if isHovered {
            return NSColor(white: 0.92, alpha: 1.0)
        } else {
            return NSColor(white: 0.65, alpha: 1.0)
        }
    }

    private var availableTextWidth: CGFloat {
        max(10, bounds.width - 19)
    }

    private func fullTextWidth() -> CGFloat {
        let attrs: [NSAttributedString.Key: Any] = [.font: currentFont]
        return ceil((title as NSString).size(withAttributes: attrs).width)
    }

    func restartMarqueeAfterLayoutIfSelected() {
        if isSelected {
            startMarqueeIfNeeded()
        }
    }

    private func stopMarquee() {
        marqueeDwellTask?.cancel()
        marqueeDwellTask = nil
        if let driverID = marqueeDriverID {
            MotionCoordinator.shared.displayDriver.stop(id: driverID)
            marqueeDriverID = nil
        }
        if scrollOffset != 0 {
            scrollOffset = 0
            needsDisplay = true
        }
    }

    private func startMarqueeIfNeeded() {
        stopMarquee()
        guard isSelected, window != nil, !isHiddenOrHasHiddenAncestor, !MotionCoordinator.shared.isReduceMotionEnabled else { return }

        let overflow = fullTextWidth() - availableTextWidth
        guard overflow > 2.0 else { return }

        marqueeDwellTask = Task { @MainActor [weak self] in
            // Wait 5 seconds after clicking before scrolling
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled,
                  let self,
                  self.isSelected,
                  self.window != nil,
                  !self.isHiddenOrHasHiddenAncestor,
                  !MotionCoordinator.shared.isReduceMotionEnabled else { return }
            self.beginDisplayDrivenMarquee()
        }
    }

    private func beginDisplayDrivenMarquee() {
        if let existing = marqueeDriverID {
            MotionCoordinator.shared.displayDriver.stop(id: existing)
            marqueeDriverID = nil
        }
        let speedPtPerSec: CGFloat = 28.0
        var phase: Int = 0 // 0: scroll, 1: pause at end (1.5s), 2: pause at start (2.0s)
        var holdElapsed: TimeInterval = 0
        marqueeDriverID = MotionCoordinator.shared.displayDriver.start { [weak self] dt, _ in
            guard let self,
                  self.isSelected,
                  self.window != nil,
                  !self.isHiddenOrHasHiddenAncestor,
                  !MotionCoordinator.shared.isReduceMotionEnabled else {
                self?.marqueeDriverID = nil
                return false
            }
            let currentOverflow = self.fullTextWidth() - self.availableTextWidth
            guard currentOverflow > 2.0 else {
                self.scrollOffset = 0
                self.needsDisplay = true
                self.marqueeDriverID = nil
                return false
            }
            let targetScroll = currentOverflow + 6.0
            switch phase {
            case 0:
                self.scrollOffset = min(targetScroll, self.scrollOffset + speedPtPerSec * CGFloat(dt))
                self.needsDisplay = true
                if self.scrollOffset >= targetScroll {
                    phase = 1
                    holdElapsed = 0
                }
            case 1:
                holdElapsed += dt
                if holdElapsed >= 1.5 {
                    self.scrollOffset = 0
                    self.needsDisplay = true
                    phase = 2
                    holdElapsed = 0
                }
            default:
                holdElapsed += dt
                if holdElapsed >= 2.0 {
                    phase = 0
                    holdElapsed = 0
                }
            }
            return true
        }
    }

    override func viewDidHide() {
        super.viewDidHide()
        stopMarquee()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil && isSelected {
            startMarqueeIfNeeded()
        } else if window == nil {
            stopMarquee()
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = trackingArea {
            removeTrackingArea(existing)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInActiveApp],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) { isHovered = false }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }

    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) {
            onClick?()
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        if isSelected {
            let bgPath = NSBezierPath(roundedRect: bounds.insetBy(dx: 1.5, dy: 1.5), xRadius: 6, yRadius: 6)
            NSColor(white: 1.0, alpha: 0.14).setFill()
            bgPath.fill()

            // Left silver accent indicator (3.5px wide)
            let barRect = NSRect(x: 2, y: 4, width: 3.5, height: bounds.height - 8)
            let barPath = NSBezierPath(roundedRect: barRect, xRadius: 1.75, yRadius: 1.75)
            NSColor(calibratedRed: 0.85, green: 0.85, blue: 0.85, alpha: 0.95).setFill()
            barPath.fill()
        } else if isHovered {
            let bgPath = NSBezierPath(roundedRect: bounds.insetBy(dx: 1.5, dy: 1.5), xRadius: 6, yRadius: 6)
            NSColor(white: 1.0, alpha: 0.07).setFill()
            bgPath.fill()
        }

        let font = currentFont
        let textH = ceil(font.ascender - font.descender + 2)
        let textRect = NSRect(
            x: 11,
            y: (bounds.height - textH) * 0.5,
            width: availableTextWidth,
            height: textH
        )

        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: textRect).addClip()

        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .left
        paragraph.lineBreakMode = scrollOffset > 0.1 ? .byClipping : .byTruncatingTail

        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: currentTextColor,
            .paragraphStyle: paragraph
        ]

        if scrollOffset > 0.1 {
            let fullW = fullTextWidth() + 4
            let drawRect = NSRect(x: textRect.minX - scrollOffset, y: textRect.minY, width: fullW, height: textH)
            (title as NSString).draw(in: drawRect, withAttributes: attrs)
        } else {
            (title as NSString).draw(in: textRect, withAttributes: attrs)
        }

        NSGraphicsContext.restoreGraphicsState()
    }
}

// MARK: - LibrarySidebarView

/// Left category bar (专区栏) rendered in Liquid Glass with dynamic text-only category items.
@MainActor
open class LibrarySidebarView: NSVisualEffectView {

    open override var isFlipped: Bool { true }

    public var onCategorySelected: ((Int) -> Void)?

    private let scrollView = NSScrollView()
    private let stackView = NSStackView()
    private var categoryViews: [SidebarCategoryItemView] = []
    public private(set) var selectedIndex: Int = 0
    public private(set) var categories: [SidebarCategory] = []

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupGlass()
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupGlass()
    }

    private func setupGlass() {
        material = .hudWindow
        blendingMode = .withinWindow
        state = .active
        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.masksToBounds = true
        layer?.borderWidth = 0.5
        layer?.borderColor = NSColor(white: 1.0, alpha: 0.10).cgColor

        // Scroll View with Flipped Clip
        let clip = FlippedClipView()
        clip.drawsBackground = false
        scrollView.contentView = clip
        scrollView.drawsBackground = false
        scrollView.applySubtleOverlayScrollbar()

        stackView.orientation = .vertical
        stackView.alignment = .width
        stackView.spacing = 3
        stackView.edgeInsets = NSEdgeInsets(top: 6, left: 4.5, bottom: 6, right: 4.5)
        stackView.translatesAutoresizingMaskIntoConstraints = false

        scrollView.documentView = stackView
        addSubview(scrollView)

        NSLayoutConstraint.activate([
            stackView.leadingAnchor.constraint(equalTo: scrollView.contentView.leadingAnchor),
            stackView.trailingAnchor.constraint(equalTo: scrollView.contentView.trailingAnchor),
            stackView.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor),
            stackView.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor)
        ])

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAccessibilityChanged),
            name: MotionAccessibility.preferencesDidChangeNotification,
            object: nil
        )
        handleAccessibilityChanged()
    }

    isolated deinit {
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func handleAccessibilityChanged() {
        if MotionCoordinator.shared.isReduceTransparencyEnabled {
            state = .inactive
            layer?.backgroundColor = NSColor(srgbRed: 22/255.0, green: 24/255.0, blue: 28/255.0, alpha: 0.96).cgColor
        } else {
            state = .active
            layer?.backgroundColor = NSColor.clear.cgColor
        }
    }

    open override func layout() {
        super.layout()
        scrollView.frame = bounds
    }

    public func setCategories(_ categories: [SidebarCategory], selectedIndex: Int = 0) {
        self.categories = categories
        self.selectedIndex = selectedIndex
        stackView.arrangedSubviews.forEach { $0.removeFromSuperview() }
        categoryViews.removeAll()

        for (idx, cat) in categories.enumerated() {
            let itemView = SidebarCategoryItemView(title: cat.title)
            itemView.onClick = { [weak self] in
                self?.categoryClicked(index: idx)
            }
            itemView.translatesAutoresizingMaskIntoConstraints = false
            itemView.heightAnchor.constraint(equalToConstant: 39).isActive = true
            stackView.addArrangedSubview(itemView)
            categoryViews.append(itemView)
        }

        updateSelection(index: selectedIndex)
    }

    private func categoryClicked(index: Int) {
        updateSelection(index: index)
        onCategorySelected?(index)
    }

    public func updateSelection(index: Int) {
        self.selectedIndex = index
        for (i, view) in categoryViews.enumerated() {
            view.isSelected = (i == index)
        }
    }
}
