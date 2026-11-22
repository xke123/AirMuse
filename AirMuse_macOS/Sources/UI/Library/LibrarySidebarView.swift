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

// MARK: - SidebarCategoryButton

final class SidebarCategoryButton: NSButton {
    override var isFlipped: Bool { true }

    var isSelected: Bool = false {
        didSet {
            updateColors()
            needsDisplay = true
        }
    }

    private var trackingArea: NSTrackingArea?
    private var isHovered: Bool = false {
        didSet {
            updateColors()
            needsDisplay = true
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        bezelStyle = .regularSquare
        isBordered = false
        imagePosition = .imageLeft
        alignment = .left
        font = NSFont.systemFont(ofSize: 9.5, weight: .regular)
        cell?.lineBreakMode = .byTruncatingTail
    }

    private func updateColors() {
        if isSelected {
            contentTintColor = NSColor.white
            font = NSFont.systemFont(ofSize: 9.5, weight: .semibold)
        } else if isHovered {
            contentTintColor = NSColor(white: 0.92, alpha: 1.0)
            font = NSFont.systemFont(ofSize: 9.5, weight: .regular)
        } else {
            contentTintColor = NSColor(white: 0.65, alpha: 1.0)
            font = NSFont.systemFont(ofSize: 9.5, weight: .regular)
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

    override func draw(_ dirtyRect: NSRect) {
        if isSelected {
            let bgPath = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 4, yRadius: 4)
            NSColor(white: 1.0, alpha: 0.14).setFill()
            bgPath.fill()

            // Left silver accent indicator (2.5px wide)
            let barRect = NSRect(x: 1.5, y: 3, width: 2.5, height: bounds.height - 6)
            let barPath = NSBezierPath(roundedRect: barRect, xRadius: 1.25, yRadius: 1.25)
            NSColor(calibratedRed: 0.85, green: 0.85, blue: 0.85, alpha: 0.95).setFill()
            barPath.fill()
        } else if isHovered {
            let bgPath = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 4, yRadius: 4)
            NSColor(white: 1.0, alpha: 0.07).setFill()
            bgPath.fill()
        }
        super.draw(dirtyRect)
    }
}

// MARK: - LibrarySidebarView

/// Left category bar (专区栏) rendered in Liquid Glass with dynamic category buttons.
@MainActor
open class LibrarySidebarView: NSVisualEffectView {

    open override var isFlipped: Bool { true }

    public var onCategorySelected: ((Int) -> Void)?

    private let scrollView = NSScrollView()
    private let stackView = NSStackView()
    private var categoryButtons: [SidebarCategoryButton] = []
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
        layer?.cornerRadius = 8
        layer?.masksToBounds = true
        layer?.borderWidth = 0.5
        layer?.borderColor = NSColor(white: 1.0, alpha: 0.10).cgColor

        // Scroll View with Flipped Clip
        let clip = FlippedClipView()
        clip.drawsBackground = false
        scrollView.contentView = clip
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true

        stackView.orientation = .vertical
        stackView.alignment = .leading
        stackView.spacing = 2
        stackView.edgeInsets = NSEdgeInsets(top: 4, left: 3, bottom: 4, right: 3)
        stackView.translatesAutoresizingMaskIntoConstraints = false

        scrollView.documentView = stackView
        addSubview(scrollView)

        NSLayoutConstraint.activate([
            stackView.leadingAnchor.constraint(equalTo: scrollView.contentView.leadingAnchor),
            stackView.trailingAnchor.constraint(equalTo: scrollView.contentView.trailingAnchor),
            stackView.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor)
        ])
    }

    open override func layout() {
        super.layout()
        scrollView.frame = bounds
        let btnW = max(50, bounds.width - 6)
        for btn in categoryButtons {
            btn.widthAnchor.constraint(equalToConstant: btnW).isActive = true
        }
    }

    public func setCategories(_ categories: [SidebarCategory], selectedIndex: Int = 0) {
        self.categories = categories
        self.selectedIndex = selectedIndex
        stackView.arrangedSubviews.forEach { $0.removeFromSuperview() }
        categoryButtons.removeAll()

        let btnW = max(50, bounds.width - 6)
        for (idx, cat) in categories.enumerated() {
            let btn = SidebarCategoryButton(frame: .zero)
            btn.title = cat.title
            btn.tag = idx
            btn.target = self
            btn.action = #selector(categoryClicked(_:))

            if let icon = cat.iconName {
                let config = NSImage.SymbolConfiguration(pointSize: 9.5, weight: .regular)
                if let img = NSImage(systemSymbolName: icon, accessibilityDescription: cat.title) {
                    btn.image = img.withSymbolConfiguration(config)
                }
            }

            btn.translatesAutoresizingMaskIntoConstraints = false
            btn.heightAnchor.constraint(equalToConstant: 26).isActive = true
            btn.widthAnchor.constraint(equalToConstant: btnW).isActive = true
            stackView.addArrangedSubview(btn)
            categoryButtons.append(btn)
        }

        updateSelection(index: selectedIndex)
    }

    @objc private func categoryClicked(_ sender: NSButton) {
        updateSelection(index: sender.tag)
        onCategorySelected?(sender.tag)
    }

    public func updateSelection(index: Int) {
        self.selectedIndex = index
        for (i, btn) in categoryButtons.enumerated() {
            btn.isSelected = (i == index)
        }
    }
}
