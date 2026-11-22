import AppKit

// MARK: - GlassSearchField

/// A search input field with frosted glass background and scope switch (Apple Music | 资料库).
open class GlassSearchField: GlassSurface {

    public var onQueryChanged: ((String) -> Void)?
    public var onScopeChanged: ((Int) -> Void)?   // 0: Global Catalog, 1: User Library

    private let textField = NSSearchField()
    private let scopeSegment = NSSegmentedControl()

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupSearch()
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupSearch()
    }

    private func setupSearch() {
        cornerRadius = DesignTokens.CornerRadius.control

        textField.placeholderString = "搜索音乐、艺人或歌单…"
        textField.focusRingType = .none
        textField.isBordered = false
        textField.drawsBackground = false
        textField.target = self
        textField.action = #selector(textDidChange(_:))
        addSubview(textField)

        scopeSegment.segmentCount = 2
        scopeSegment.setLabel("曲库", forSegment: 0)
        scopeSegment.setLabel("资料库", forSegment: 1)
        scopeSegment.selectedSegment = 0
        scopeSegment.segmentStyle = .capsule
        scopeSegment.target = self
        scopeSegment.action = #selector(scopeDidChange(_:))
        addSubview(scopeSegment)
    }

    open override func layout() {
        super.layout()
        let scopeW: CGFloat = 110
        let padding: CGFloat = 6
        textField.frame = NSRect(x: padding, y: 4, width: bounds.width - scopeW - padding * 3, height: bounds.height - 8)
        scopeSegment.frame = NSRect(x: bounds.width - scopeW - padding, y: (bounds.height - 20) / 2, width: scopeW, height: 20)
    }

    @objc private func textDidChange(_ sender: NSSearchField) {
        onQueryChanged?(sender.stringValue)
    }

    @objc private func scopeDidChange(_ sender: NSSegmentedControl) {
        onScopeChanged?(sender.selectedSegment)
    }
}

