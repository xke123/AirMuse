import AppKit
import DesignSystem
import Infrastructure

// MARK: - LibraryTopBarView

/// Liquid Glass Top Bar replicating airmuse_ui_core.js:
/// - Navigation mode: Refresh button, capsule tab group [主页, 新发现, 广播, 资料库, 歌单], Layout toggle, Search toggle, Log button, Close button.
/// - Search mode: Back button, search input field with clear button, scope selector [曲库 | 资料库], Layout toggle, Close button.
@MainActor
open class LibraryTopBarView: NSVisualEffectView {

    public var onTabSelected: ((Int) -> Void)?
    public var onRefresh: (() -> Void)?
    public var onToggleLayout: (() -> Void)?
    public var onSearchQuery: ((String, Int) -> Void)?
    public var onToggleLog: (() -> Void)?
    public var onToggleAccount: (() -> Void)?
    public var onClose: (() -> Void)?

    public private(set) var selectedTabIndex: Int = 0
    public private(set) var isSearchMode: Bool = false
    public private(set) var is2Col: Bool = false

    // MARK: - Subviews: Navigation Mode

    private let navContainer = NSView()
    private let refreshButton = NSButton()
    private let tabSegment = NSSegmentedControl()
    private let layoutButton = NSButton()
    private let searchButton = NSButton()
    private let logButton = NSButton()
    private let accountButton = NSButton()
    private let closeButton = NSButton()

    // MARK: - Subviews: Search Mode

    private let searchContainer = NSView()
    private let searchBackButton = NSButton()
    private let searchField = NSSearchField()
    private let scopeSegment = NSSegmentedControl()
    private let searchLayoutButton = NSButton()
    private let searchCloseButton = NSButton()

    private var debounceTask: Task<Void, Never>?
    private var currentScope: Int = 0

    // MARK: - Init

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupGlass()
        setupNavMode()
        setupSearchMode()
        setSearchMode(false, animated: false)
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupGlass()
        setupNavMode()
        setupSearchMode()
        setSearchMode(false, animated: false)
    }

    deinit {
        debounceTask?.cancel()
    }

    // MARK: - Setup Glass

    private func setupGlass() {
        material = .hudWindow
        blendingMode = .withinWindow
        state = .active
        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.masksToBounds = true
        layer?.borderWidth = 0.5
        layer?.borderColor = NSColor(white: 1.0, alpha: 0.12).cgColor
    }

    // MARK: - Setup Navigation Mode

    private func setupNavMode() {
        navContainer.wantsLayer = true
        addSubview(navContainer)

        // Refresh Button (⟳)
        configureIconButton(refreshButton, symbolName: "arrow.clockwise", tooltip: "刷新数据", action: #selector(refreshClicked))
        navContainer.addSubview(refreshButton)

        // Center Tab Group: [主页, 新发现, 广播, 资料库, 歌单]
        let tabs = ["主页", "新发现", "广播", "资料库", "歌单"]
        tabSegment.segmentCount = tabs.count
        for (i, t) in tabs.enumerated() {
            tabSegment.setLabel(t, forSegment: i)
        }
        tabSegment.selectedSegment = 0
        tabSegment.segmentStyle = .capsule
        tabSegment.target = self
        tabSegment.action = #selector(tabChanged(_:))
        tabSegment.font = NSFont.systemFont(ofSize: 13.5, weight: .medium)
        navContainer.addSubview(tabSegment)

        // Layout Toggle (⚏ / ☰)
        configureIconButton(layoutButton, symbolName: "square.grid.2x2", tooltip: "切换单栏 / 双栏 (⚏)", action: #selector(layoutClicked))
        navContainer.addSubview(layoutButton)

        // Search Button (🔍)
        configureIconButton(searchButton, symbolName: "magnifyingglass", tooltip: "搜索音乐 (替换顶部栏)", action: #selector(searchOpenClicked))
        navContainer.addSubview(searchButton)

        // Log Button (terminal)
        configureIconButton(logButton, symbolName: "terminal", tooltip: "运行诊断日志 (⌥⌘L)", action: #selector(logClicked))
        navContainer.addSubview(logButton)

        // Account / Auth Button (person.crop.circle)
        configureIconButton(accountButton, symbolName: "person.crop.circle", tooltip: "Apple Music 账户与会话 (⌥⌘A)", action: #selector(accountClicked))
        navContainer.addSubview(accountButton)

        // Close Button (✕)
        configureIconButton(closeButton, symbolName: "xmark", tooltip: "关闭面板", action: #selector(closeClicked))
        navContainer.addSubview(closeButton)
    }

    // MARK: - Setup Search Mode

    private func setupSearchMode() {
        searchContainer.wantsLayer = true
        searchContainer.isHidden = true
        addSubview(searchContainer)

        // Back Button (‹)
        configureIconButton(searchBackButton, symbolName: "chevron.backward", tooltip: "返回主导航 (Esc)", action: #selector(searchBackClicked))
        searchContainer.addSubview(searchBackButton)

        // Search Input Field
        searchField.placeholderString = "搜索音乐、艺人或歌单…"
        searchField.focusRingType = .none
        searchField.isBordered = false
        searchField.drawsBackground = false
        searchField.font = NSFont.systemFont(ofSize: 14.5, weight: .regular)
        searchField.target = self
        searchField.action = #selector(searchQueryChanged(_:))
        searchContainer.addSubview(searchField)

        // Scope Segment [曲库 | 资料库]
        scopeSegment.segmentCount = 2
        scopeSegment.setLabel("曲库", forSegment: 0)
        scopeSegment.setLabel("资料库", forSegment: 1)
        scopeSegment.selectedSegment = 0
        scopeSegment.segmentStyle = .capsule
        scopeSegment.font = NSFont.systemFont(ofSize: 13, weight: .regular)
        scopeSegment.target = self
        scopeSegment.action = #selector(scopeChanged(_:))
        searchContainer.addSubview(scopeSegment)

        // Search Layout Toggle
        configureIconButton(searchLayoutButton, symbolName: "square.grid.2x2", tooltip: "切换单栏 / 双栏", action: #selector(layoutClicked))
        searchContainer.addSubview(searchLayoutButton)

        // Search Close Button
        configureIconButton(searchCloseButton, symbolName: "xmark", tooltip: "关闭面板", action: #selector(closeClicked))
        searchContainer.addSubview(searchCloseButton)
    }

    private func configureIconButton(_ btn: NSButton, symbolName: String, tooltip: String, action: Selector) {
        btn.bezelStyle = .regularSquare
        btn.isBordered = false
        btn.toolTip = tooltip
        btn.target = self
        btn.action = action

        let cfg = NSImage.SymbolConfiguration(pointSize: 15, weight: .medium)
        if let img = NSImage(systemSymbolName: symbolName, accessibilityDescription: tooltip) {
            btn.image = img.withSymbolConfiguration(cfg)
        }
        btn.contentTintColor = NSColor(white: 0.75, alpha: 1.0)
    }

    // MARK: - Layout

    open override func layout() {
        super.layout()
        let w = bounds.width
        let h = bounds.height

        navContainer.frame = bounds
        searchContainer.frame = bounds

        // Nav Mode Layout
        let btnSize: CGFloat = 30
        let padding: CGFloat = 6

        // Refresh Button
        refreshButton.frame = NSRect(x: padding, y: (h - btnSize) / 2, width: btnSize, height: btnSize)

        // Right side buttons
        var rx = w - padding - btnSize
        closeButton.frame = NSRect(x: rx, y: (h - btnSize) / 2, width: btnSize, height: btnSize)
        rx -= (btnSize + 4)

        accountButton.frame = NSRect(x: rx, y: (h - btnSize) / 2, width: btnSize, height: btnSize)
        rx -= (btnSize + 4)

        logButton.frame = NSRect(x: rx, y: (h - btnSize) / 2, width: btnSize, height: btnSize)
        rx -= (btnSize + 4)

        searchButton.frame = NSRect(x: rx, y: (h - btnSize) / 2, width: btnSize, height: btnSize)
        rx -= (btnSize + 4)

        layoutButton.frame = NSRect(x: rx, y: (h - btnSize) / 2, width: btnSize, height: btnSize)

        // Center Tab Group: fit strictly between refresh and right buttons
        let leftLimit = refreshButton.frame.maxX + 8
        let rightLimit = layoutButton.frame.minX - 8
        let availableCenterW = max(50, rightLimit - leftLimit)
        let tabW = min(285, availableCenterW)
        let tabX = leftLimit + (availableCenterW - tabW) / 2
        tabSegment.frame = NSRect(x: tabX, y: (h - 32) / 2, width: tabW, height: 32)

        // Search Mode Layout
        searchBackButton.frame = NSRect(x: padding, y: (h - btnSize) / 2, width: btnSize, height: btnSize)

        var srx = w - padding - btnSize
        searchCloseButton.frame = NSRect(x: srx, y: (h - btnSize) / 2, width: btnSize, height: btnSize)
        srx -= (btnSize + 4)

        searchLayoutButton.frame = NSRect(x: srx, y: (h - btnSize) / 2, width: btnSize, height: btnSize)
        srx -= 6

        let scopeW: CGFloat = 128
        srx -= scopeW
        scopeSegment.frame = NSRect(x: srx, y: (h - 28) / 2, width: scopeW, height: 28)

        let fieldX = padding + btnSize + 6
        let fieldW = max(50, srx - fieldX - 6)
        searchField.frame = NSRect(x: fieldX, y: (h - 28) / 2, width: fieldW, height: 28)
    }

    // MARK: - Public State Controls

    public func selectTab(index: Int) {
        guard index >= 0 && index < tabSegment.segmentCount else { return }
        selectedTabIndex = index
        tabSegment.selectedSegment = index
    }

    public func setSearchMode(_ active: Bool, animated: Bool = true) {
        isSearchMode = active
        navContainer.isHidden = active
        searchContainer.isHidden = !active

        if active {
            window?.makeFirstResponder(searchField)
        } else {
            searchField.stringValue = ""
        }
    }

    public func updateLayoutIcon(is2Col: Bool) {
        self.is2Col = is2Col
        let iconName = is2Col ? "rectangle.grid.1x2" : "square.grid.2x2"
        let tip = is2Col ? "切换为单栏列表 (☰)" : "切换为双栏卡片 (⚏)"
        let cfg = NSImage.SymbolConfiguration(pointSize: 10.5, weight: .medium)
        if let img = NSImage(systemSymbolName: iconName, accessibilityDescription: tip) {
            layoutButton.image = img.withSymbolConfiguration(cfg)
            searchLayoutButton.image = img.withSymbolConfiguration(cfg)
        }
        layoutButton.toolTip = tip
        searchLayoutButton.toolTip = tip
    }

    // MARK: - Actions

    @objc private func refreshClicked() {
        onRefresh?()
    }

    @objc private func tabChanged(_ sender: NSSegmentedControl) {
        selectedTabIndex = sender.selectedSegment
        onTabSelected?(selectedTabIndex)
    }

    @objc private func layoutClicked() {
        is2Col.toggle()
        updateLayoutIcon(is2Col: is2Col)
        onToggleLayout?()
    }

    @objc private func searchOpenClicked() {
        setSearchMode(true)
    }

    @objc private func searchBackClicked() {
        setSearchMode(false)
        onTabSelected?(selectedTabIndex)
    }

    @objc private func logClicked() {
        onToggleLog?()
    }

    @objc private func accountClicked() {
        onToggleAccount?()
    }

    @objc private func closeClicked() {
        onClose?()
    }

    @objc private func scopeChanged(_ sender: NSSegmentedControl) {
        currentScope = sender.selectedSegment
        triggerSearch()
    }

    @objc private func searchQueryChanged(_ sender: NSSearchField) {
        debounceTask?.cancel()
        debounceTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard let self, !Task.isCancelled else { return }
            self.triggerSearch()
        }
    }

    private func triggerSearch() {
        let q = searchField.stringValue
        onSearchQuery?(q, currentScope)
    }
}
