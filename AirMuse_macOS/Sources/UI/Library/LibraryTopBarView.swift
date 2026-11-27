import AppKit
import DesignSystem
import Infrastructure

// MARK: - LibraryTopBarView

/// Liquid Glass Top Bar replicating airmuse_ui_core.js:
/// - Navigation mode: Refresh button, capsule tab group [主页, 新发现, 广播, 资料库, 歌单], Layout toggle, Search toggle, Log button, Close button.
/// - Search mode: Back button, search input field with clear button, scope selector [曲库 | 资料库], Layout toggle, Close button.
@MainActor
open class LibraryTopBarView: NSView, NSSearchFieldDelegate {

    private let glassView = NSGlassEffectView(frame: .zero)

    public var onTabSelected: ((Int) -> Void)?
    public var onRefresh: (() -> Void)?
    public var onToggleLayout: (() -> Void)?
    public var onSearchQuery: ((String, Int) -> Void)?
    public var onSearchSubmit: ((String, Int) -> Void)?
    public var onSearchModeChanged: ((Bool) -> Void)?
    public var onArtistBack: (() -> Void)?
    public var onArtistPlayTop: (() -> Void)?
    public var onToggleLog: (() -> Void)?
    public var onToggleAccount: (() -> Void)?
    public var onClose: (() -> Void)?

    public private(set) var selectedTabIndex: Int = 0
    public private(set) var isSearchMode: Bool = false
    public private(set) var isArtistMode: Bool = false
    public private(set) var is2Col: Bool = true
    public var currentSearchScope: Int { currentScope }
    public var currentSearchText: String { searchField.stringValue }

    // MARK: - Subviews: Navigation Mode

    private let navContainer = NSView()
    private let refreshButton = NSButton()
    private let tabSegment = NSSegmentedControl()
    private let layoutButton = NSButton()
    private let searchButton = NSButton()
    private let logButton = NSButton()
    private let accountButton = NSButton()
    private let closeButton = NSButton()

    // MARK: - Subviews: Search Mode (3 Capsules: Back | SearchField | Scope)

    private let searchContainer = NSView()
    private let searchGlassContainer = NSGlassEffectContainerView(frame: .zero)
    private let backCapsuleGlass = NSGlassEffectView(frame: .zero)
    private let fieldCapsuleGlass = NSGlassEffectView(frame: .zero)
    private let fieldWrapperView = NSView()
    private let searchIconView = NSImageView()
    private let searchBackButton = NSButton()
    private let searchField = NSSearchField()
    private let scopeSegment = NSSegmentedControl()

    /// Frame of the middle search-box capsule in `LibraryTopBarView` coordinates.
    public var searchBoxFrame: NSRect { fieldCapsuleGlass.frame }

    // MARK: - Subviews: Artist Mode (3 Liquid Glass Capsules: Back | ArtistName | PlayTop)

    private let artistContainer = NSView()
    private let artistGlassContainer = NSGlassEffectContainerView(frame: .zero)
    private let artistBackCapsuleGlass = NSGlassEffectView(frame: .zero)
    private let artistTitleCapsuleGlass = NSGlassEffectView(frame: .zero)
    private let artistTitleWrapper = NSView()
    private let artistPlayCapsuleGlass = NSGlassEffectView(frame: .zero)
    private let artistBackButton = NSButton()
    private let artistTitleLabel = NSTextField(labelWithString: "")
    private let artistPlayButton = NSButton()

    private let topBarMotionID = "LibraryTopBar-\(UUID().uuidString)"
    private var debounceTask: Task<Void, Never>?
    private var currentScope: Int = 0

    // MARK: - Init

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupGlass()
        setupNavMode()
        setupSearchMode()
        setupArtistMode()
        setSearchMode(false, animated: false)
        updateLayoutIcon(is2Col: true)
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupGlass()
        setupNavMode()
        setupSearchMode()
        setupArtistMode()
        setSearchMode(false, animated: false)
        updateLayoutIcon(is2Col: true)
    }

    deinit {
        debounceTask?.cancel()
    }

    // MARK: - Setup Glass

    private func setupGlass() {
        wantsLayer = true

        // Single-layer native macOS 26+ Liquid Glass floating pill backdrop.
        glassView.style = .regular
        glassView.cornerRadius = 17
        glassView.autoresizingMask = [.width, .height]
        addSubview(glassView, positioned: .below, relativeTo: nil)
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
        tabSegment.font = NSFont.systemFont(ofSize: 12.5, weight: .medium)
        navContainer.addSubview(tabSegment)

        // Layout Toggle (⚏ / ☰)
        configureIconButton(layoutButton, symbolName: "square.grid.2x2", tooltip: "切换单栏 / 双栏 (⚏)", action: #selector(layoutClicked))
        navContainer.addSubview(layoutButton)

        // Search Button (🔍)
        configureIconButton(searchButton, symbolName: "magnifyingglass", tooltip: "搜索音乐 (替换顶部栏)", action: #selector(searchOpenClicked))
        navContainer.addSubview(searchButton)
    }

    // MARK: - Setup Search Mode

    private func setupSearchMode() {
        searchContainer.wantsLayer = true
        searchContainer.isHidden = true
        addSubview(searchContainer)

        searchGlassContainer.spacing = 6
        searchContainer.addSubview(searchGlassContainer)

        backCapsuleGlass.style = .regular
        fieldCapsuleGlass.style = .regular
        searchGlassContainer.addSubview(backCapsuleGlass)
        searchGlassContainer.addSubview(fieldCapsuleGlass)

        // 1. Left Capsule: Back Button (‹)
        configureIconButton(searchBackButton, symbolName: "chevron.backward", tooltip: "返回主导航 (Esc)", action: #selector(searchBackClicked))
        backCapsuleGlass.contentView = searchBackButton

        // 2. Middle Capsule: Magnifying Glass + Borderless Search Field (prevents icon/placeholder overlap)
        fieldWrapperView.wantsLayer = true
        let iconCfg = NSImage.SymbolConfiguration(pointSize: 12.5, weight: .medium)
        searchIconView.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil)?
            .withSymbolConfiguration(iconCfg)
        searchIconView.contentTintColor = NSColor(white: 0.65, alpha: 1.0)
        fieldWrapperView.addSubview(searchIconView)

        searchField.placeholderString = "搜索音乐、艺人或歌单…"
        searchField.focusRingType = .none
        searchField.isBordered = false
        searchField.drawsBackground = false
        searchField.font = NSFont.systemFont(ofSize: 13.0, weight: .regular)
        searchField.delegate = self
        searchField.target = self
        searchField.action = #selector(searchFieldSubmitted(_:))
        if let cell = searchField.cell as? NSSearchFieldCell {
            cell.searchButtonCell = nil
            cell.cancelButtonCell?.target = self
            cell.cancelButtonCell?.action = #selector(clearSearchClicked)
        }
        fieldWrapperView.addSubview(searchField)
        fieldCapsuleGlass.contentView = fieldWrapperView

        // 3. Right Capsule: Scope Segment [Apple Music | 资料库] (standalone native capsule, no double glass layer)
        scopeSegment.segmentCount = 2
        scopeSegment.setLabel("Apple Music", forSegment: 0)
        scopeSegment.setLabel("资料库", forSegment: 1)
        scopeSegment.selectedSegment = 0
        scopeSegment.segmentStyle = .capsule
        scopeSegment.font = NSFont.systemFont(ofSize: 11.5, weight: .medium)
        scopeSegment.target = self
        scopeSegment.action = #selector(scopeChanged(_:))
        searchContainer.addSubview(scopeSegment)
    }

    // MARK: - Setup Artist Mode

    private func setupArtistMode() {
        artistContainer.wantsLayer = true
        artistContainer.isHidden = true
        addSubview(artistContainer)

        artistGlassContainer.spacing = 6
        artistContainer.addSubview(artistGlassContainer)

        artistBackCapsuleGlass.style = .regular
        artistTitleCapsuleGlass.style = .regular
        artistPlayCapsuleGlass.style = .regular
        artistGlassContainer.addSubview(artistBackCapsuleGlass)
        artistGlassContainer.addSubview(artistTitleCapsuleGlass)
        artistGlassContainer.addSubview(artistPlayCapsuleGlass)

        configureIconButton(artistBackButton, symbolName: "chevron.backward", tooltip: "返回", action: #selector(artistBackClicked))
        artistBackCapsuleGlass.contentView = artistBackButton

        artistTitleLabel.font = NSFont.systemFont(ofSize: 13.5, weight: .semibold)
        artistTitleLabel.textColor = NSColor(white: 0.96, alpha: 1.0)
        artistTitleLabel.alignment = .center
        artistTitleLabel.lineBreakMode = .byTruncatingTail
        artistTitleWrapper.addSubview(artistTitleLabel)
        artistTitleCapsuleGlass.contentView = artistTitleWrapper

        artistPlayButton.bezelStyle = .regularSquare
        artistPlayButton.isBordered = false
        artistPlayButton.title = "▶ 播放热门"
        artistPlayButton.font = NSFont.systemFont(ofSize: 12.0, weight: .semibold)
        artistPlayButton.contentTintColor = NSColor(red: 0.98, green: 0.25, blue: 0.38, alpha: 1.0)
        artistPlayButton.target = self
        artistPlayButton.action = #selector(artistPlayClicked)
        artistPlayCapsuleGlass.contentView = artistPlayButton
    }

    private func configureIconButton(_ btn: NSButton, symbolName: String, tooltip: String, action: Selector) {
        btn.bezelStyle = .regularSquare
        btn.isBordered = false
        btn.focusRingType = .none
        btn.toolTip = tooltip
        btn.target = self
        btn.action = action

        let cfg = NSImage.SymbolConfiguration(pointSize: 13.5, weight: .medium)
        if let img = NSImage(systemSymbolName: symbolName, accessibilityDescription: tooltip) {
            btn.image = img.withSymbolConfiguration(cfg)
        }
        btn.contentTintColor = NSColor(white: 0.78, alpha: 1.0)
    }

    // MARK: - Layout

    open override func layout() {
        super.layout()
        let w = bounds.width
        let h = bounds.height

        glassView.frame = bounds
        glassView.cornerRadius = h * 0.5
        navContainer.frame = bounds
        searchContainer.frame = bounds

        // Nav Mode Layout: Two ends aligned, tab group centered
        let btnSize: CGFloat = 24
        let padding: CGFloat = 6

        // Left end: Refresh Button
        refreshButton.frame = NSRect(x: padding, y: (h - btnSize) / 2, width: btnSize, height: btnSize)

        // Right end: Search Button & Layout Button
        let searchX = w - padding - btnSize
        searchButton.frame = NSRect(x: searchX, y: (h - btnSize) / 2, width: btnSize, height: btnSize)
        let layoutX = searchButton.frame.minX - 4 - btnSize
        layoutButton.frame = NSRect(x: layoutX, y: (h - btnSize) / 2, width: btnSize, height: btnSize)

        // Center: Tab Segment strictly centered between the window edges
        let tabH: CGFloat = 26
        let tabW = min(265.0, max(50.0, w - (padding + btnSize * 2 + 12) * 2))
        let tabX = (w - tabW) / 2
        tabSegment.frame = NSRect(x: tabX, y: (h - tabH) / 2, width: tabW, height: tabH)

        // Search Mode Layout: 3 capsules (Back | SearchField | Scope)
        let gap: CGFloat = 6
        let backW: CGFloat = h
        let scopeW: CGFloat = 148
        let fieldCapW = max(60, w - backW - scopeW - gap * 2)

        searchGlassContainer.frame = NSRect(x: 0, y: 0, width: backW + gap + fieldCapW, height: h)

        backCapsuleGlass.frame = NSRect(x: 0, y: 0, width: backW, height: h)
        backCapsuleGlass.cornerRadius = h * 0.5

        fieldCapsuleGlass.frame = NSRect(x: backW + gap, y: 0, width: fieldCapW, height: h)
        fieldCapsuleGlass.cornerRadius = h * 0.5
        fieldWrapperView.frame = NSRect(x: 0, y: 0, width: fieldCapW, height: h)
        searchIconView.frame = NSRect(x: 11, y: (h - 14) / 2, width: 14, height: 14)
        searchField.frame = NSRect(x: 28, y: (h - 20) / 2, width: max(30, fieldCapW - 36), height: 20)

        let scopeH: CGFloat = 26
        scopeSegment.frame = NSRect(x: backW + gap + fieldCapW + gap, y: (h - scopeH) / 2, width: scopeW, height: scopeH)

        // Artist Mode Layout: 3 Liquid Glass capsules (Back | ArtistName | PlayTop)
        artistContainer.frame = bounds
        artistGlassContainer.frame = bounds
        let playW: CGFloat = 94
        let titleCapW = max(60, w - backW - playW - gap * 2)
        artistBackCapsuleGlass.frame = NSRect(x: 0, y: 0, width: backW, height: h)
        artistBackCapsuleGlass.cornerRadius = h * 0.5
        artistTitleCapsuleGlass.frame = NSRect(x: backW + gap, y: 0, width: titleCapW, height: h)
        artistTitleCapsuleGlass.cornerRadius = h * 0.5
        artistTitleWrapper.frame = NSRect(x: 0, y: 0, width: titleCapW, height: h)
        artistTitleLabel.frame = NSRect(x: 10, y: (h - 18) * 0.5, width: max(20, titleCapW - 20), height: 18)
        artistPlayCapsuleGlass.frame = NSRect(x: backW + gap + titleCapW + gap, y: 0, width: playW, height: h)
        artistPlayCapsuleGlass.cornerRadius = h * 0.5
    }

    // MARK: - Public State Controls

    public func selectTab(index: Int) {
        guard index >= 0 && index < tabSegment.segmentCount else { return }
        selectedTabIndex = index
        tabSegment.selectedSegment = index
    }

    public func setArtistMode(_ active: Bool, artistName: String = "", animated: Bool = true) {
        isArtistMode = active
        if active {
            artistTitleLabel.stringValue = artistName
            glassView.isHidden = true
            navContainer.isHidden = true
            searchContainer.isHidden = true
            artistContainer.isHidden = false
            artistContainer.alphaValue = 1.0
        } else {
            artistContainer.isHidden = true
            glassView.isHidden = isSearchMode
            navContainer.isHidden = isSearchMode
            navContainer.alphaValue = isSearchMode ? 0.0 : 1.0
            searchContainer.isHidden = !isSearchMode
            searchContainer.alphaValue = isSearchMode ? 1.0 : 0.0
        }
    }

    public func setSearchMode(_ active: Bool, animated: Bool = true) {
        isArtistMode = false
        artistContainer.isHidden = true
        let wasActive = isSearchMode
        isSearchMode = active
        let key = TransitionKey(owner: topBarMotionID, channel: "searchMode")
        let ticket = MotionCoordinator.shared.beginTransition(for: key, category: .controlInteraction)

        if active {
            currentScope = 0
            scopeSegment.selectedSegment = 0
            searchContainer.isHidden = false
            focusSearchField()
        } else {
            debounceTask?.cancel()
            searchField.stringValue = ""
        }

        if !animated || MotionCoordinator.shared.isReduceMotionEnabled {
            glassView.isHidden = active
            navContainer.isHidden = active
            navContainer.alphaValue = active ? 0.0 : 1.0
            searchContainer.isHidden = !active
            searchContainer.alphaValue = active ? 1.0 : 0.0
            _ = MotionCoordinator.shared.complete(ticket)
            if active { focusSearchField() }
            if wasActive != active { onSearchModeChanged?(active) }
            return
        }

        glassView.isHidden = active
        navContainer.isHidden = false
        searchContainer.isHidden = false
        MotionCoordinator.shared.animate(
            duration: MotionTokens.Duration.searchFocus,
            timingFunction: .easeInEaseOut,
            ticket: ticket,
            action: {
                self.navContainer.animator().alphaValue = active ? 0.0 : 1.0
                self.searchContainer.animator().alphaValue = active ? 1.0 : 0.0
            },
            completion: { [weak self] committed in
                guard committed, let self else { return }
                self.navContainer.isHidden = self.isSearchMode
                self.searchContainer.isHidden = !self.isSearchMode
                if self.isSearchMode {
                    self.focusSearchField()
                }
            }
        )
        if wasActive != active {
            onSearchModeChanged?(active)
        }
    }

    public func focusSearchField() {
        guard let win = window else { return }
        if !win.isKeyWindow {
            win.makeKey()
        }
        win.makeFirstResponder(searchField)
    }

    public func setSearchQuery(_ query: String, submit: Bool = true) {
        debounceTask?.cancel()
        searchField.stringValue = query
        if submit {
            triggerSearch(recordHistory: true)
        }
    }

    public func updateLayoutIcon(is2Col: Bool) {
        self.is2Col = is2Col
        let iconName = is2Col ? "rectangle.grid.1x2" : "square.grid.2x2"
        let tip = is2Col ? "切换为单栏列表 (☰)" : "切换为双栏卡片 (⚏)"
        let cfg = NSImage.SymbolConfiguration(pointSize: 15, weight: .medium)
        if let img = NSImage(systemSymbolName: iconName, accessibilityDescription: tip) {
            layoutButton.image = img.withSymbolConfiguration(cfg)
        }
        layoutButton.toolTip = tip
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

    @objc private func artistBackClicked() {
        onArtistBack?()
    }

    @objc private func artistPlayClicked() {
        onArtistPlayTop?()
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
        let text = sender.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty {
            triggerSearch(recordHistory: false)
            return
        }
        debounceTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard let self, !Task.isCancelled else { return }
            self.triggerSearch(recordHistory: false)
        }
    }

    @objc private func clearSearchClicked() {
        debounceTask?.cancel()
        searchField.stringValue = ""
        focusSearchField()
        triggerSearch(recordHistory: false)
    }

    @objc private func searchFieldSubmitted(_ sender: NSSearchField) {
        debounceTask?.cancel()
        triggerSearch(recordHistory: true)
    }

    private func triggerSearch(recordHistory: Bool = false) {
        let q = searchField.stringValue
        if recordHistory {
            onSearchSubmit?(q, currentScope)
        }
        onSearchQuery?(q, currentScope)
    }

    // MARK: - NSSearchFieldDelegate

    public func controlTextDidChange(_ obj: Notification) {
        guard let field = obj.object as? NSSearchField, field === searchField else { return }
        searchQueryChanged(field)
    }

    public func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            if !searchField.stringValue.isEmpty {
                debounceTask?.cancel()
                searchField.stringValue = ""
                triggerSearch(recordHistory: false)
            } else {
                searchBackClicked()
            }
            return true
        }
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            debounceTask?.cancel()
            triggerSearch(recordHistory: true)
            return true
        }
        return false
    }

    // MARK: - Z-Axis Pass-Through Protection

    public override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden, alphaValue > 0.01 else { return nil }
        let local = convert(point, from: superview)
        guard bounds.contains(local) else { return nil }
        return super.hitTest(point) ?? self
    }

    public override func mouseDown(with event: NSEvent) {}
    public override func mouseUp(with event: NSEvent) {}
    public override func rightMouseDown(with event: NSEvent) {}
    public override func otherMouseDown(with event: NSEvent) {}
    public override func scrollWheel(with event: NSEvent) {}
}
