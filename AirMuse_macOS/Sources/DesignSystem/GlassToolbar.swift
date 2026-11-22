import AppKit

// MARK: - GlassToolbar

/// A glass-styled horizontal toolbar container with segmented pills.
open class GlassToolbar: GlassSurface {

    public var onSegmentSelected: ((Int) -> Void)?
    public var onSearchToggled: (() -> Void)?

    private let segmentedControl = NSSegmentedControl()
    private let searchButton = GlassButton(image: NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: "Search"), size: CGSize(width: 20, height: 20))

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupToolbar()
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupToolbar()
    }

    private func setupToolbar() {
        cornerRadius = DesignTokens.CornerRadius.control

        segmentedControl.segmentCount = 5
        segmentedControl.setLabel("主页", forSegment: 0)
        segmentedControl.setLabel("新发现", forSegment: 1)
        segmentedControl.setLabel("广播", forSegment: 2)
        segmentedControl.setLabel("资料库", forSegment: 3)
        segmentedControl.setLabel("歌单", forSegment: 4)
        segmentedControl.selectedSegment = 0
        segmentedControl.target = self
        segmentedControl.action = #selector(segmentChanged(_:))
        segmentedControl.segmentStyle = .roundRect
        addSubview(segmentedControl)

        searchButton.onClick = { [weak self] in
            self?.onSearchToggled?()
        }
        addSubview(searchButton)
    }

    open override func layout() {
        super.layout()
        let searchW: CGFloat = 24
        let margin: CGFloat = 6
        searchButton.frame = NSRect(x: bounds.width - searchW - margin, y: (bounds.height - searchW) / 2, width: searchW, height: searchW)
        segmentedControl.frame = NSRect(x: margin, y: (bounds.height - 24) / 2, width: bounds.width - searchW - margin * 3, height: 24)
    }

    @objc private func segmentChanged(_ sender: NSSegmentedControl) {
        onSegmentSelected?(sender.selectedSegment)
    }
}

