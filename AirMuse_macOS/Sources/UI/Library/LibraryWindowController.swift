import AppKit
import Domain
import DesignSystem
import Playback
import Providers
import Infrastructure

// MARK: - LibraryHoverTrackerView

private final class LibraryHoverTrackerView: NSView {
    var onHoverChanged: ((Bool) -> Void)?
    private var trackingArea: NSTrackingArea?

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = trackingArea { removeTrackingArea(existing) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        onHoverChanged?(true)
    }

    override func mouseExited(with event: NSEvent) {
        onHoverChanged?(false)
    }

    override func viewDidHide() {
        super.viewDidHide()
        onHoverChanged?(false)
    }
}

// MARK: - LibraryWindowController

/// Controls the Library and Search window presentation, Liquid Glass tab navigation, and category content switching.
@MainActor
open class LibraryWindowController: NSWindowController {

    public var onToggleLog: (() -> Void)?
    public var onToggleAccount: (() -> Void)?
    public var onClose: (() -> Void)?
    public var onArtistSelected: ((_ artistID: String, _ isLibrary: Bool) -> Void)?

    private let panel = GlassPanel()
    public var moduleView: GlassPanel { panel }
    public var contentContainerView: NSView { panel.contentView }
    private let topBar = LibraryTopBarView()
    private let sidebar = LibrarySidebarView()
    private let contentView = LibraryContentView()
    private let searchHistoryStore = SearchHistoryStore()
    private let searchHistoryExpand = SearchHistoryExpandView()
    private let artistSidebarHeader = ArtistSidebarHeaderView()
    private lazy var queueDockView = LiquidFusionQueueDockView(coordinator: coordinator)

    // Top glass bar controls & aurora fog
    private let hoverTracker = LibraryHoverTrackerView()
    private let auroraFogView = AuroraGlassFogView()
    private var isHovering: Bool = false
    private let titleLabel = NSTextField()
    private let logButton = GlassButton(sprite: nil, size: CGSize(width: 13, height: 13), buttonStyle: .glassBar)
    private let accountButton = GlassButton(sprite: nil, size: CGSize(width: 13, height: 13), buttonStyle: .glassBar)
    private let closeButton = GlassButton(sprite: nil, size: CGSize(width: 13, height: 13), buttonStyle: .glassBar)

    private let coordinator: PlaybackCoordinatorV2
    private let sessionCoordinator: SessionCoordinator?
    private var appleMusicProvider: AppleMusicProvider?
    private var currentSessionSnapshot: SessionSnapshot = .initial
    private var sessionTask: Task<Void, Never>?

    private var activeTabIndex: Int = 0
    private var activeCategoryIndex: Int = 0

    private var categoryLoadTask: Task<Void, Never>?
    private var searchTask: Task<Void, Never>?
    private var searchPageTask: Task<Void, Never>?
    private var browseLoadTask: Task<Void, Never>?
    private var categoryGeneration: UInt64 = 0
    private var searchGeneration: UInt64 = 0
    private var detailGeneration: UInt64 = 0
    private var artistGeneration: UInt64 = 0
    private var detailLoadTask: Task<Void, Never>?
    private var artistLoadTask: Task<Void, Never>?
    private var isLoadingHomeSidebar: Bool = false
    private let queuePaginationLoader = QueuePaginationLoader()
    private var currentDetailOrigin: PlaybackOrigin = .unknown
    private var currentDetailNextURL: URL?
    private var currentDetailIsLibrary: Bool = false
    private var currentDetailTotalCount: Int?

    // Dynamic remote categories cached per tab index (0: Home recommendations, 1: Browse editorial, 2: Radio)
    private var loadedEditorialCategories: [Int: [AmpCategory]] = [:]
    private var loadedSearchBrowseCategories: [AmpCategory] = []
    private var searchSections: [SearchSection] = []
    private var activeSearchSectionIndex: Int = 0
    private var isSearchResultsActive: Bool = false
    private var isLoadingNextSearchPage: Bool = false
    private var artistStack: [MusicArtistDetail] = []
    private var activeArtistSectionIndex: Int = 0
    private var savedArtistOrigin: ArtistOriginSnapshot?

    private struct ArtistOriginSnapshot {
        let tabIndex: Int
        let categoryIndex: Int
        let title: String
        let items: [MediaCardItem]
        let columnCountOverride: Int?
        let scrollOrigin: NSPoint
        let isSearchMode: Bool
        let isSearchResultsActive: Bool
    }

    public init(coordinator: PlaybackCoordinatorV2, sessionCoordinator: SessionCoordinator? = nil, appleMusicProvider: AppleMusicProvider? = nil) {
        self.coordinator = coordinator
        self.sessionCoordinator = sessionCoordinator
        self.appleMusicProvider = appleMusicProvider

        super.init(window: nil)

        setupPanelUI()
        wireCallbacks()
        observeSession()
    }

    isolated deinit {
        sessionTask?.cancel()
        categoryLoadTask?.cancel()
        searchTask?.cancel()
        searchPageTask?.cancel()
        browseLoadTask?.cancel()
        detailLoadTask?.cancel()
        artistLoadTask?.cancel()
        queuePaginationLoader.cancel()
        MotionCoordinator.shared.cancel(key: TransitionKey(owner: "LibraryWindow-\(ObjectIdentifier(self).hashValue)", channel: "hover"))
    }

    public required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    public func preferredSize(for scale: CGFloat) -> NSSize {
        NSSize(
            width: OriginalDesignTokens.BaseMetrics.libraryWindowWidth * scale,
            height: OriginalDesignTokens.BaseMetrics.libraryWindowHeight * scale
        )
    }

    private func setupPanelUI() {
        panel.wantsLayer = true

        // Hover tracker spanning full panel (including top glass bar)
        hoverTracker.autoresizingMask = [.width, .height]
        hoverTracker.onHoverChanged = { [weak self] hovering in
            self?.setHovering(hovering)
        }
        panel.addSubview(hoverTracker)

        // Top glass bar aurora fog container (visible on hover)
        auroraFogView.seamEdge = .bottom
        auroraFogView.alphaValue = 0.0
        panel.addSubview(auroraFogView)

        // Top glass bar title: "<Username>的Apple Music"
        titleLabel.isBezeled = false
        titleLabel.isEditable = false
        titleLabel.isSelectable = false
        titleLabel.drawsBackground = false
        titleLabel.lineBreakMode = .byTruncatingTail
        auroraFogView.addSubview(titleLabel)

        // Top glass bar right-side window buttons
        logButton.enableDarkHalo = false
        logButton.toolTip = "运行诊断日志 (⌥⌘L)"
        logButton.onClick = { [weak self] in
            AppLogger.shared.log(category: .userAction, level: .info, message: "用户点击顶部玻璃条日志按钮")
            self?.onToggleLog?()
        }
        auroraFogView.addSubview(logButton)

        accountButton.enableDarkHalo = false
        accountButton.toolTip = "Apple Music 账户与会话 (⌥⌘A)"
        accountButton.onClick = { [weak self] in
            AppLogger.shared.log(category: .userAction, level: .info, message: "用户点击顶部玻璃条账户按钮")
            self?.onToggleAccount?()
        }
        auroraFogView.addSubview(accountButton)

        closeButton.enableDarkHalo = false
        closeButton.toolTip = "关闭面板"
        closeButton.onClick = { [weak self] in
            AppLogger.shared.log(category: .userAction, level: .info, message: "用户点击顶部玻璃条关闭按钮")
            self?.onClose?()
        }
        auroraFogView.addSubview(closeButton)

        let container = panel.contentView
        container.addSubview(sidebar)
        artistSidebarHeader.isHidden = true
        container.addSubview(artistSidebarHeader)
        container.addSubview(contentView)
        // topBar floats above contentView so scrolled cards pass underneath its Liquid Glass pill
        container.addSubview(topBar)
        container.addSubview(searchHistoryExpand)
        container.addSubview(queueDockView)

        panel.onLayout = { [weak self] _ in
            self?.layoutViews()
        }

        reloadTopBarSymbols()
        updateTopBarTitle()
        layoutViews()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleSkinChange),
            name: GlassInteractionCoordinator.modeDidChangeNotification,
            object: nil
        )
    }

    private func layoutViews() {
        let s = GlassInteractionCoordinator.shared.uiScale
        let pBounds = panel.bounds
        let wb = 13.0 * s
        let capH = OriginalDesignTokens.BaseMetrics.glassCapHeight * s
        let topBarBtnY = (capH - wb) * 0.5
        let btnSpacing = 5.0 * s

        // Hover tracker & top glass bar aurora fog view span the entire panel / top glass bar
        hoverTracker.frame = pBounds
        auroraFogView.frame = NSRect(x: 0, y: pBounds.height - capH, width: pBounds.width, height: capH)

        // Right side glass bar buttons
        closeButton.frame = NSRect(x: pBounds.width - 16.0 * s - wb, y: topBarBtnY, width: wb, height: wb)
        accountButton.frame = NSRect(x: closeButton.frame.minX - btnSpacing - wb, y: topBarBtnY, width: wb, height: wb)
        logButton.frame = NSRect(x: accountButton.frame.minX - btnSpacing - wb, y: topBarBtnY, width: wb, height: wb)

        // Left side glass bar title
        let titleH: CGFloat = 18.0 * s
        let titleY = (capH - titleH) * 0.5
        let titleX = 16.0 * s
        let maxTitleW = max(50.0 * s, logButton.frame.minX - 16.0 * s - titleX)
        let idealTextW = titleLabel.attributedStringValue.size().width + 8.0 * s
        let actualTitleW = min(maxTitleW, max(40.0 * s, idealTextW))
        titleLabel.frame = NSRect(x: titleX, y: titleY, width: actualTitleW, height: titleH)

        updateAuroraFog()

        let bounds = panel.contentView.bounds
        guard bounds.width > 20 && bounds.height > 20 else { return }

        let topBarH: CGFloat = 34
        let sidebarW: CGFloat = 126
        let padding: CGFloat = 6

        topBar.frame = NSRect(x: padding, y: padding, width: bounds.width - padding * 2, height: topBarH)

        let sidebarY = topBarH + padding * 2
        let sidebarH = max(10, bounds.height - sidebarY - padding)
        let fullContentH = max(10, bounds.height - padding * 2)
        contentView.topContentInset = topBarH + padding

        if (topBar.isSearchMode && !isSearchResultsActive) && !topBar.isArtistMode {
            sidebar.isHidden = true
            artistSidebarHeader.isHidden = true
            contentView.frame = NSRect(x: padding, y: padding, width: bounds.width - padding * 2, height: fullContentH)
        } else if topBar.isArtistMode {
            let headerH = artistSidebarHeader.currentPreferredHeight
            let headerGap: CGFloat = 6
            artistSidebarHeader.isHidden = false
            artistSidebarHeader.frame = NSRect(x: padding, y: sidebarY, width: sidebarW, height: headerH)
            sidebar.isHidden = false
            sidebar.frame = NSRect(x: padding, y: sidebarY + headerH + headerGap, width: sidebarW, height: max(40, sidebarH - headerH - headerGap))
            contentView.frame = NSRect(x: sidebarW + padding * 2, y: padding, width: bounds.width - sidebarW - padding * 3, height: fullContentH)
        } else {
            artistSidebarHeader.isHidden = true
            sidebar.isHidden = false
            sidebar.frame = NSRect(x: padding, y: sidebarY, width: sidebarW, height: sidebarH)
            contentView.frame = NSRect(x: sidebarW + padding * 2, y: padding, width: bounds.width - sidebarW - padding * 3, height: fullContentH)
        }

        topBar.layoutSubtreeIfNeeded()
        let expandH = searchHistoryExpand.preferredHeight
        let boxFrame = topBar.searchBoxFrame
        let expandX = boxFrame.width > 20 ? (topBar.frame.minX + boxFrame.minX) : padding
        let expandW = boxFrame.width > 20 ? boxFrame.width : (bounds.width - padding * 2)
        searchHistoryExpand.frame = NSRect(
            x: expandX,
            y: topBar.frame.maxY + 4,
            width: expandW,
            height: expandH
        )
        queueDockView.frame = bounds
    }

    private func setHovering(_ hovering: Bool) {
        guard isHovering != hovering else { return }
        isHovering = hovering
        let targetAlpha: CGFloat = hovering ? 1.0 : 0.0
        let key = TransitionKey(owner: "LibraryWindow-\(ObjectIdentifier(self).hashValue)", channel: "hover")
        let ticket = MotionCoordinator.shared.beginTransition(for: key, category: .controlInteraction)
        if MotionCoordinator.shared.isReduceMotionEnabled {
            auroraFogView.alphaValue = targetAlpha
            _ = MotionCoordinator.shared.complete(ticket)
        } else {
            MotionCoordinator.shared.animate(
                duration: MotionTokens.Duration.hoverFade,
                timingFunction: .easeInEaseOut,
                ticket: ticket,
                action: {
                    self.auroraFogView.animator().alphaValue = targetAlpha
                }
            )
        }
    }

    private func reloadTopBarSymbols() {
        let s = GlassInteractionCoordinator.shared.uiScale
        closeButton.setSymbol(name: "xmark", pointSize: 8.5 * s, weight: .bold)
        accountButton.setSymbol(name: "person.crop.circle", pointSize: 9.5 * s, weight: .medium)
        logButton.setSymbol(name: "terminal", pointSize: 9.0 * s, weight: .medium)
    }

    public func updateTopBarTitle() {
        let s = GlassInteractionCoordinator.shared.uiScale
        let font = NSFont.systemFont(ofSize: 10.5 * s, weight: .semibold)
        let isLogged = currentSessionSnapshot.sessionState == .authenticated

        let text: String
        if isLogged {
            let name = Self.resolveUserDisplayName(from: currentSessionSnapshot)
            text = "\(name)的Apple Music"
        } else {
            text = "未登录的Apple Music"
        }
        titleLabel.attributedStringValue = PixelFontRenderer.makeHaloAttributedString(
            text,
            font: font,
            color: isLogged ? OriginalDesignTokens.Colors.glassBarForeground : OriginalDesignTokens.Colors.glassBarForegroundMuted,
            alignment: .left
        )
        updateAuroraFog()
    }

    /// Dynamically renders edge-adaptive laser-mist plumes based on title width and button cluster
    private func updateAuroraFog() {
        let s = GlassInteractionCoordinator.shared.uiScale
        let titlePlume = auroraFogView.makePlume(
            for: [titleLabel],
            alignment: .left,
            anchorSpread: 10.0 * s,
            tailLength: 56.0 * s,
            peakAlpha: 0.95
        )
        let buttonsPlume = auroraFogView.makePlume(
            for: [logButton, accountButton, closeButton],
            alignment: .right,
            anchorSpread: 10.0 * s,
            tailLength: 64.0 * s,
            peakAlpha: 1.0
        )
        auroraFogView.plumes = [titlePlume, buttonsPlume].compactMap { $0 }
    }

    /// Resolves the authenticated user's display name truthfully without hardcoded personal fallbacks.
    public static func resolveUserDisplayName(from snapshot: SessionSnapshot = .initial) -> String {
        if let accountName = snapshot.account?.displayName,
           !accountName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return accountName
        }
        return "Apple Music"
    }

    @objc private func handleSkinChange() {
        reloadTopBarSymbols()
        updateTopBarTitle()
        layoutViews()
        panel.refreshGlassSurface()
    }

    private func observeSession() {
        guard let sessionCoordinator else { return }
        sessionTask = Task { @MainActor [weak self] in
            let stream = await sessionCoordinator.snapshots()
            for await snap in stream {
                guard !Task.isCancelled, let self else { break }
                let prevState = self.currentSessionSnapshot.sessionState
                self.currentSessionSnapshot = snap
                self.updateTopBarTitle()
                switch snap.sessionState {
                case .signedOut, .expired, .invalidating:
                    if prevState != snap.sessionState {
                        self.queuePaginationLoader.cancel()
                        self.loadedEditorialCategories.removeAll()
                        self.handleTabSelected(self.activeTabIndex)
                    }
                case .authenticated:
                    if prevState != .authenticated {
                        if self.activeTabIndex == 0 && (self.loadedEditorialCategories[0]?.isEmpty == false) {
                            self.loadDynamicHomeSidebar()
                        } else {
                            self.handleTabSelected(self.activeTabIndex)
                        }
                    }
                default:
                    break
                }
            }
        }
    }

    private func wireCallbacks() {
        // Top Bar Events
        topBar.onTabSelected = { [weak self] tabIndex in
            guard let self else { return }
            AppLogger.shared.log(category: .userAction, level: .info, message: "用户切换主标签页: [\(self.tabTitle(tabIndex))] (索引: \(tabIndex))")
            self.handleTabSelected(tabIndex)
        }

        topBar.onRefresh = { [weak self] in
            guard let self else { return }
            AppLogger.shared.log(category: .userAction, level: .info, message: "用户点击顶部刷新按钮")
            self.loadCurrentCategory(forceRefresh: true)
        }

        topBar.onToggleLayout = { [weak self] in
            guard let self else { return }
            let is2Col = self.topBar.is2Col
            AppLogger.shared.log(category: .userAction, level: .info, message: "用户切换排版布局: \(is2Col ? "双栏卡片 (⚏)" : "单栏列表 (☰)")")
            self.contentView.setLayout2Col(is2Col)
        }

        topBar.onSearchModeChanged = { [weak self] active in
            guard let self else { return }
            if active {
                self.enterSearchEmptyState()
            } else {
                self.exitSearchModeCleanup()
            }
        }

        topBar.onSearchQuery = { [weak self] query, scope in
            let scopeName = (scope == 0) ? "Apple Music 全球曲库" : "个人资料库"
            AppLogger.shared.log(category: .userAction, level: .info, message: "用户提交搜索: \"\(query)\" (检索范围: \(scopeName))")
            self?.performSearch(query: query, scope: scope)
        }

        topBar.onSearchSubmit = { [weak self] query, _ in
            guard let self else { return }
            self.searchHistoryStore.add(query)
            self.searchHistoryExpand.updateQueries(self.searchHistoryStore.items)
        }

        searchHistoryExpand.onSelectQuery = { [weak self] query in
            guard let self else { return }
            self.searchHistoryExpand.setExpanded(false)
            self.topBar.setSearchQuery(query, submit: true)
        }

        searchHistoryExpand.onDeleteQuery = { [weak self] query in
            guard let self else { return }
            self.searchHistoryStore.remove(query)
            self.searchHistoryExpand.updateQueries(self.searchHistoryStore.items)
            self.layoutViews()
            if self.searchHistoryStore.items.isEmpty {
                self.searchHistoryExpand.setExpanded(false)
            }
        }

        searchHistoryExpand.onClearAll = { [weak self] in
            guard let self else { return }
            self.searchHistoryStore.clearAll()
            self.searchHistoryExpand.updateQueries([])
            self.searchHistoryExpand.setExpanded(false)
            self.layoutViews()
        }

        contentView.onReachedBottom = { [weak self] in
            self?.loadNextSearchPageIfNeeded()
        }

        topBar.onArtistBack = { [weak self] in
            self?.popArtistPage()
        }

        topBar.onArtistPlayTop = { [weak self] in
            self?.playArtistTopSongs()
        }

        artistSidebarHeader.onInfoClicked = { [weak self] anchor in
            self?.showArtistInfoPopover(relativeTo: anchor)
        }

        artistSidebarHeader.onFavoriteClicked = { [weak self] in
            self?.toggleArtistFavorite()
        }

        artistSidebarHeader.onMoreClicked = { [weak self] anchor in
            self?.showArtistMoreMenu(relativeTo: anchor)
        }

        artistSidebarHeader.onPreferredHeightChanged = { [weak self] in
            self?.layoutViews()
        }

        topBar.onToggleLog = { [weak self] in
            AppLogger.shared.log(category: .userAction, level: .info, message: "用户打开运行诊断日志视窗")
            self?.onToggleLog?()
        }

        topBar.onToggleAccount = { [weak self] in
            AppLogger.shared.log(category: .userAction, level: .info, message: "用户打开 Apple Music 账户管理窗口")
            self?.onToggleAccount?()
        }

        topBar.onClose = { [weak self] in
            AppLogger.shared.log(category: .userAction, level: .info, message: "用户关闭音乐资料库窗口")
            self?.onClose?()
        }

        // Sidebar Events
        sidebar.onCategorySelected = { [weak self] categoryIndex in
            guard let self else { return }
            if self.topBar.isArtistMode {
                self.selectArtistSection(at: categoryIndex)
            } else if self.topBar.isSearchMode && self.isSearchResultsActive {
                self.selectSearchSection(at: categoryIndex)
            } else {
                AppLogger.shared.log(category: .userAction, level: .info, message: "用户切换左侧专区: 索引 \(categoryIndex)")
                self.handleCategorySelected(categoryIndex)
            }
        }

        // Content View Events
        contentView.onItemClicked = { [weak self] item in
            guard let self else { return }
            AppLogger.shared.log(category: .userAction, level: .info, message: "用户点击卡片项: [\(item.type.rawValue)] \(item.title) - \(item.subtitle) (ID: \(item.id))")
            self.handleItemClicked(item)
        }

        contentView.onTrackSelected = { [weak self] track in
            guard let self else { return }
            AppLogger.shared.log(category: .userAction, level: .info, message: "用户在曲目列表中选中播放: \(track.title) - \(track.artistName) (ID: \(track.id))")
            let allTracks = self.contentView.currentDetailTracksList
            let sourceTracks = allTracks.isEmpty ? [track] : allTracks
            let index = sourceTracks.firstIndex(where: { $0.id == track.id }) ?? 0
            self.playDetailTracks(sourceTracks, startIndex: index)
        }

        contentView.onTrackQueueAction = { [weak self] track, action in
            guard let self else { return }
            self.handleTracksQueueAction([track], origin: self.currentDetailOrigin, action: action)
        }

        contentView.onPlayAll = { [weak self] tracks in
            guard let self, !tracks.isEmpty else { return }
            AppLogger.shared.log(category: .userAction, level: .info, message: "用户点击 [全部播放] (共 \(tracks.count) 首歌曲，首曲: \(tracks[0].title))")
            self.playDetailTracks(tracks, startIndex: 0)
        }

        contentView.onDetailBatchQueueAction = { [weak self] tracks, action in
            guard let self, !tracks.isEmpty else { return }
            self.handleTracksQueueAction(tracks, origin: self.currentDetailOrigin, action: action)
        }

        contentView.onItemQueueAction = { [weak self] item, action in
            guard let self else { return }
            self.handleCardQueueAction(item, action: action)
        }

        queueDockView.onNavigateToOrigin = { [weak self] origin in
            guard let self, let sourceID = origin.sourceID else { return }
            switch origin.kind {
            case .album:
                let card = MediaCardItem(id: sourceID, title: origin.displayTitle, subtitle: "", type: .album, artworkURL: origin.artworkURL, albumID: sourceID)
                self.handleItemClicked(card)
            case .playlist:
                let card = MediaCardItem(id: sourceID, title: origin.displayTitle, subtitle: "", type: .playlist, artworkURL: origin.artworkURL, playlistID: sourceID)
                self.handleItemClicked(card)
            case .artist:
                self.openArtistPage(artistID: sourceID, isLibrary: origin.isLibrary, initialName: origin.displayTitle, artworkURL: origin.artworkURL)
            default:
                break
            }
        }

        queueDockView.onReportError = { message in
            AppLogger.shared.log(category: .playback, level: .warn, message: "队列操作提示: \(message)")
        }

        // Initial tab: 主页
        handleTabSelected(0)
    }

    // MARK: - Tab & Category Management

    private func handleTabSelected(_ tabIndex: Int) {
        self.activeTabIndex = tabIndex
        self.activeCategoryIndex = 0
        layoutViews()

        let categories = categoriesForTab(tabIndex)
        sidebar.setCategories(categories, selectedIndex: 0)

        loadCurrentCategory()

        // Asynchronously load remote dynamic categories if applicable
        if tabIndex == 0 {
            loadDynamicHomeSidebar()
        } else if tabIndex == 1 || tabIndex == 2 {
            loadDynamicEditorialSidebar(tabIndex: tabIndex)
        }
    }

    private func handleCategorySelected(_ categoryIndex: Int) {
        self.activeCategoryIndex = categoryIndex
        loadCurrentCategory()
    }

    private func categoriesForTab(_ tabIndex: Int) -> [SidebarCategory] {
        switch tabIndex {
        case 0: // 主页
            if let dynamic = loadedEditorialCategories[0], !dynamic.isEmpty {
                return dynamic.enumerated().map { idx, cat in
                    let icon: String
                    switch idx % 4 {
                    case 0: icon = "sparkles"
                    case 1: icon = "flame.fill"
                    case 2: icon = "square.stack.fill"
                    default: icon = "music.note.list"
                    }
                    return SidebarCategory(id: cat.id, title: cat.title, iconName: icon)
                }
            }
            return [
                SidebarCategory(id: "home_rec", title: "为你推荐", iconName: "sparkles"),
                SidebarCategory(id: "home_charts", title: "今日热门", iconName: "flame.fill"),
                SidebarCategory(id: "home_albums", title: "精选专辑", iconName: "square.stack.fill"),
                SidebarCategory(id: "home_playlists", title: "官方歌单", iconName: "music.note.list")
            ]
        case 1: // 新发现
            if let dynamic = loadedEditorialCategories[1], !dynamic.isEmpty {
                return dynamic.enumerated().map { idx, cat in
                    let icon: String
                    switch idx % 4 {
                    case 0: icon = "sparkles"
                    case 1: icon = "star.fill"
                    case 2: icon = "calendar"
                    default: icon = "clock.fill"
                    }
                    return SidebarCategory(id: cat.id, title: cat.title, iconName: icon)
                }
            }
            return [
                SidebarCategory(id: "exp_new_songs", title: "新歌精选", iconName: "sparkles"),
                SidebarCategory(id: "exp_spotlight", title: "瞩目之星", iconName: "star.fill"),
                SidebarCategory(id: "exp_releases", title: "本周新发", iconName: "calendar"),
                SidebarCategory(id: "exp_recent", title: "新近发布", iconName: "clock.fill")
            ]
        case 2: // 广播
            if let dynamic = loadedEditorialCategories[2], !dynamic.isEmpty {
                return dynamic.enumerated().map { idx, cat in
                    let icon: String
                    switch idx % 3 {
                    case 0: icon = "radio.fill"
                    case 1: icon = "antenna.radiowaves.left.and.right"
                    default: icon = "sparkle"
                    }
                    return SidebarCategory(id: cat.id, title: cat.title, iconName: icon)
                }
            }
            return [
                SidebarCategory(id: "radio_am", title: "AM 电台", iconName: "radio.fill"),
                SidebarCategory(id: "radio_live", title: "全球直播", iconName: "antenna.radiowaves.left.and.right"),
                SidebarCategory(id: "radio_classics", title: "畅销经典", iconName: "sparkle")
            ]
        case 3: // 资料库
            return [
                SidebarCategory(id: "lib_recent", title: "最近添加", iconName: "clock.arrow.circlepath"),
                SidebarCategory(id: "lib_favs", title: "喜爱歌曲", iconName: "heart.fill"),
                SidebarCategory(id: "lib_songs", title: "已存单曲", iconName: "music.note"),
                SidebarCategory(id: "lib_albums", title: "已存专辑", iconName: "square.stack"),
                SidebarCategory(id: "lib_artists", title: "关注艺人", iconName: "person.2.fill")
            ]
        case 4: // 歌单
            return [
                SidebarCategory(id: "pl_all", title: "全部歌单", iconName: "music.note.list"),
                SidebarCategory(id: "pl_mfy", title: "为你推荐", iconName: "sparkles.rectangle.stack"),
                SidebarCategory(id: "pl_user", title: "自建歌单", iconName: "person.badge.plus"),
                SidebarCategory(id: "pl_fav", title: "收藏歌单", iconName: "star.bubble")
            ]
        default:
            return []
        }
    }

    private func loadDynamicHomeSidebar() {
        guard !isLoadingHomeSidebar, let provider = appleMusicProvider else { return }
        isLoadingHomeSidebar = true
        Task { [weak self] in
            defer {
                Task { @MainActor [weak self] in self?.isLoadingHomeSidebar = false }
            }
            guard let self else { return }
            guard let recs = try? await provider.fetchRecommendations(), !recs.isEmpty else { return }
            await MainActor.run {
                guard self.activeTabIndex == 0 else { return }
                self.loadedEditorialCategories[0] = recs
                let categories = self.categoriesForTab(0)
                let prevIndex = min(self.activeCategoryIndex, max(0, categories.count - 1))
                self.sidebar.setCategories(categories, selectedIndex: prevIndex)
            }
        }
    }

    private func loadDynamicEditorialSidebar(tabIndex: Int) {
        guard let provider = appleMusicProvider else { return }
        let groupingName = (tabIndex == 2) ? "radio" : "music"
        Task { [weak self] in
            guard let self else { return }
            guard let groups = try? await provider.fetchEditorialCategories(name: groupingName), !groups.isEmpty else { return }
            await MainActor.run {
                guard self.activeTabIndex == tabIndex else { return }
                self.loadedEditorialCategories[tabIndex] = groups
                let categories = self.categoriesForTab(tabIndex)
                let prevIndex = min(self.activeCategoryIndex, max(0, categories.count - 1))
                self.sidebar.setCategories(categories, selectedIndex: prevIndex)
            }
        }
    }

    // MARK: - Data Loading

    private func loadCurrentCategory(forceRefresh: Bool = false) {
        let targetTab = activeTabIndex
        let targetCategory = activeCategoryIndex

        if forceRefresh {
            loadedEditorialCategories.removeValue(forKey: targetTab)
            if targetTab == 0 {
                loadDynamicHomeSidebar()
            } else if targetTab == 1 || targetTab == 2 {
                loadDynamicEditorialSidebar(tabIndex: targetTab)
            }
        }

        let categories = categoriesForTab(targetTab)
        guard targetCategory >= 0 && targetCategory < categories.count else { return }
        let currentCat = categories[targetCategory]

        AppLogger.shared.log(
            category: .ampAPI,
            level: .info,
            message: "开始拉取标签页 [\(tabTitle(targetTab))] -> 专区 [\(currentCat.title)] 数据"
        )

        categoryLoadTask?.cancel()
        categoryGeneration &+= 1
        let expectedGen = categoryGeneration
        contentView.setTitle(currentCat.title)
        contentView.setLoading(true)

        categoryLoadTask = Task { [weak self] in
            guard let self else { return }
            var items: [MediaCardItem] = []
            var loadError: Error?

            if let provider = self.appleMusicProvider {
                do {
                    items = try await self.fetchItems(forTab: targetTab, categoryIndex: targetCategory, provider: provider)
                } catch is CancellationError {
                    return
                } catch {
                    loadError = error
                    AppLogger.shared.log(
                        category: .error,
                        level: .warn,
                        message: "拉取 [\(currentCat.title)] 失败: \(error.localizedDescription)"
                    )
                }
            }

            guard !Task.isCancelled,
                  self.categoryGeneration == expectedGen,
                  self.activeTabIndex == targetTab,
                  self.activeCategoryIndex == targetCategory else {
                return
            }

            AppLogger.shared.log(
                category: .render,
                level: .info,
                message: "[\(currentCat.title)] 数据就绪，向视图传递 \(items.count) 个渲染项"
            )

            self.contentView.setLoading(false)
            if let loadError {
                self.contentView.setTitle("\(currentCat.title) (加载失败: \(loadError.localizedDescription))")
                self.contentView.displayItems([], animated: true)
            } else if items.isEmpty {
                self.contentView.setTitle("\(currentCat.title) (暂无内容)")
                self.contentView.displayItems([], animated: true)
            } else {
                self.contentView.displayItems(items, animated: true)
            }
        }
    }

    private func fetchItems(forTab tabIndex: Int, categoryIndex: Int, provider: AppleMusicProvider) async throws -> [MediaCardItem] {
        switch tabIndex {
        case 0: // 主页
            if let dynamic = loadedEditorialCategories[0], categoryIndex < dynamic.count {
                let targetGroup = dynamic[categoryIndex]
                return targetGroup.items.map { item in
                    let mType: MediaItemType
                    switch item.type {
                    case "song": mType = .song
                    case "album": mType = .album
                    case "playlist": mType = .playlist
                    case "station": mType = .radio
                    case "artist": mType = .artist
                    default: mType = .chart
                    }
                    return MediaCardItem(
                        id: item.id,
                        title: item.title,
                        subtitle: item.subtitle,
                        type: mType,
                        artworkURL: item.artworkURL,
                        duration: item.durationMs != nil ? self.formatDuration(Double(item.durationMs!) / 1000.0) : nil,
                        track: item.track,
                        albumID: item.album?.id,
                        playlistID: item.playlist?.id
                    )
                }
            }
            switch categoryIndex {
            case 0: // 为你推荐
                let recs = try? await provider.fetchRecommendations()
                if let recs, !recs.isEmpty {
                    let allItems = recs.flatMap(\.items)
                    return allItems.map { item in
                        let mType: MediaItemType
                        switch item.type {
                        case "song": mType = .song
                        case "album": mType = .album
                        case "playlist": mType = .playlist
                        case "station": mType = .radio
                        case "artist": mType = .artist
                        default: mType = .chart
                        }
                        return MediaCardItem(
                            id: item.id,
                            title: item.title,
                            subtitle: item.subtitle,
                            type: mType,
                            artworkURL: item.artworkURL,
                            duration: item.durationMs != nil ? self.formatDuration(Double(item.durationMs!) / 1000.0) : nil,
                            track: item.track,
                            albumID: item.album?.id,
                            playlistID: item.playlist?.id
                        )
                    }
                }
                let tracks = try await provider.fetchTopCharts()
                return tracks.map { tr in
                    MediaCardItem(
                        id: tr.id,
                        title: tr.title,
                        subtitle: tr.artistName,
                        type: .chart,
                        artworkURL: tr.artworkURL,
                        duration: self.formatDuration(tr.durationSeconds),
                        track: tr
                    )
                }
            case 1: // 今日热门 (单曲)
                let tracks = try await provider.fetchTopCharts()
                return tracks.map { tr in
                    MediaCardItem(
                        id: tr.id,
                        title: tr.title,
                        subtitle: tr.artistName,
                        type: .chart,
                        artworkURL: tr.artworkURL,
                        duration: self.formatDuration(tr.durationSeconds),
                        track: tr
                    )
                }
            case 2: // 精选专辑
                let albums = try await provider.fetchNewReleases()
                return albums.map { al in
                    MediaCardItem(
                        id: al.id,
                        title: al.title,
                        subtitle: "\(al.artistName) · \(al.trackCount) 首",
                        type: .album,
                        artworkURL: al.artworkURL,
                        albumID: al.id
                    )
                }
            case 3: // 官方歌单
                let groupings = try? await provider.fetchEditorialCategories(name: "music")
                if let groupings, !groupings.isEmpty {
                    let plItems = groupings.flatMap(\.items).filter { $0.type == "playlist" || $0.playlist != nil }
                    if !plItems.isEmpty {
                        return plItems.map { item in
                            MediaCardItem(
                                id: item.id,
                                title: item.title,
                                subtitle: item.subtitle,
                                type: .playlist,
                                artworkURL: item.artworkURL,
                                playlistID: item.playlist?.id ?? item.id
                            )
                        }
                    }
                }
                let playlists = try await provider.fetchLibraryPlaylists()
                return playlists.map { pl in
                    MediaCardItem(
                        id: pl.id,
                        title: pl.name,
                        subtitle: "歌单 · \(pl.trackCount) 首",
                        type: .playlist,
                        artworkURL: pl.artworkURL,
                        playlistID: pl.id
                    )
                }
            default:
                return []
            }

        case 1: // 新发现
            let groupings: [AmpCategory]?
            if let cached = loadedEditorialCategories[1] {
                groupings = cached
            } else {
                groupings = try? await provider.fetchEditorialCategories(name: "music")
            }
            if let groupings, !groupings.isEmpty {
                let targetGroup = (categoryIndex < groupings.count) ? groupings[categoryIndex] : groupings[0]
                return targetGroup.items.map { item in
                    let mType: MediaItemType
                    switch item.type {
                    case "song": mType = .song
                    case "album": mType = .album
                    case "playlist": mType = .playlist
                    default: mType = .chart
                    }
                    return MediaCardItem(
                        id: item.id,
                        title: item.title,
                        subtitle: item.subtitle,
                        type: mType,
                        artworkURL: item.artworkURL,
                        track: item.track,
                        albumID: item.album?.id,
                        playlistID: item.playlist?.id
                    )
                }
            } else {
                let albums = try await provider.fetchNewReleases()
                return albums.map { al in
                    MediaCardItem(
                        id: al.id,
                        title: al.title,
                        subtitle: "\(al.artistName) · \(al.trackCount) 首",
                        type: .album,
                        artworkURL: al.artworkURL,
                        albumID: al.id
                    )
                }
            }

        case 2: // 广播
            let groupings: [AmpCategory]?
            if let cached = loadedEditorialCategories[2] {
                groupings = cached
            } else {
                groupings = try? await provider.fetchEditorialCategories(name: "radio")
            }
            if let groupings, !groupings.isEmpty {
                let targetGroup = (categoryIndex < groupings.count) ? groupings[categoryIndex] : groupings[0]
                return targetGroup.items.map { item in
                    MediaCardItem(
                        id: item.id,
                        title: item.title,
                        subtitle: item.subtitle,
                        type: .radio,
                        artworkURL: item.artworkURL,
                        track: item.track
                    )
                }
            } else {
                let tracks = try await provider.fetchTopCharts()
                return tracks.map { tr in
                    MediaCardItem(
                        id: tr.id,
                        title: tr.title,
                        subtitle: tr.artistName,
                        type: .radio,
                        artworkURL: tr.artworkURL,
                        duration: self.formatDuration(tr.durationSeconds),
                        track: tr
                    )
                }
            }

        case 3: // 资料库
            switch categoryIndex {
            case 0: // 最近添加
                let recent = (try? await provider.fetchRecentlyAdded()) ?? []
                if !recent.isEmpty {
                    return recent.map { item in
                        let mType: MediaItemType
                        switch item.type {
                        case "song": mType = .song
                        case "album": mType = .album
                        case "playlist": mType = .playlist
                        case "artist": mType = .artist
                        default: mType = .song
                        }
                        return MediaCardItem(
                            id: item.id,
                            title: item.title,
                            subtitle: item.subtitle,
                            type: mType,
                            artworkURL: item.artworkURL,
                            duration: item.durationMs != nil ? self.formatDuration(Double(item.durationMs!) / 1000.0) : nil,
                            track: item.track,
                            albumID: item.album?.id ?? (mType == .album ? item.id : nil),
                            playlistID: item.playlist?.id ?? (mType == .playlist ? item.id : nil)
                        )
                    }
                }
                let tracks = try await provider.fetchLibraryTracks()
                return tracks.map { tr in
                    MediaCardItem(
                        id: tr.id,
                        title: tr.title,
                        subtitle: tr.artistName,
                        type: .song,
                        artworkURL: tr.artworkURL,
                        duration: self.formatDuration(tr.durationSeconds),
                        track: tr
                    )
                }
            case 1: // 喜爱歌曲
                let favs = try await provider.fetchFavoriteSongs()
                return favs.map { tr in
                    MediaCardItem(
                        id: tr.id,
                        title: tr.title,
                        subtitle: tr.artistName,
                        type: .song,
                        artworkURL: tr.artworkURL,
                        duration: self.formatDuration(tr.durationSeconds),
                        track: tr
                    )
                }
            case 2: // 已存单曲
                let tracks = try await provider.fetchLibraryTracks()
                return tracks.map { tr in
                    MediaCardItem(
                        id: tr.id,
                        title: tr.title,
                        subtitle: tr.artistName,
                        type: .song,
                        artworkURL: tr.artworkURL,
                        duration: self.formatDuration(tr.durationSeconds),
                        track: tr
                    )
                }
            case 3: // 已存专辑
                let albums = try await provider.fetchLibraryAlbums()
                return albums.map { al in
                    MediaCardItem(
                        id: al.id,
                        title: al.title,
                        subtitle: "\(al.artistName) · \(al.trackCount) 首",
                        type: .album,
                        artworkURL: al.artworkURL,
                        albumID: al.id
                    )
                }
            case 4: // 关注艺人
                let artists = try await provider.fetchLibraryArtists()
                return artists.map { ar in
                    MediaCardItem(
                        id: ar.id,
                        title: ar.name,
                        subtitle: "艺人",
                        type: .artist,
                        artworkURL: ar.artworkURL
                    )
                }
            default:
                return []
            }

        case 4: // 歌单
            switch categoryIndex {
            case 0: // 全部歌单
                let playlists = try await provider.fetchLibraryPlaylists()
                return playlists.map { pl in
                    MediaCardItem(
                        id: pl.id,
                        title: pl.name,
                        subtitle: "歌单 · \(pl.trackCount) 首",
                        type: .playlist,
                        artworkURL: pl.artworkURL,
                        playlistID: pl.id
                    )
                }
            case 1: // 为你推荐
                let mfy = try await provider.fetchMadeForYouPlaylists()
                if !mfy.isEmpty {
                    return mfy.map { pl in
                        MediaCardItem(
                            id: pl.id,
                            title: pl.name,
                            subtitle: "Apple Music 为你推荐",
                            type: .playlist,
                            artworkURL: pl.artworkURL,
                            playlistID: pl.id
                        )
                    }
                }
                return []
            case 2: // 自建歌单
                let userPlaylists = try await provider.fetchUserPlaylists()
                return userPlaylists.map { pl in
                    MediaCardItem(
                        id: pl.id,
                        title: pl.name,
                        subtitle: "自建歌单",
                        type: .playlist,
                        artworkURL: pl.artworkURL,
                        playlistID: pl.id
                    )
                }
            case 3: // 收藏歌单
                let favPlaylists = try await provider.fetchFavoritePlaylists()
                return favPlaylists.map { pl in
                    MediaCardItem(
                        id: pl.id,
                        title: pl.name,
                        subtitle: pl.ownerName ?? "收藏歌单",
                        type: .playlist,
                        artworkURL: pl.artworkURL,
                        playlistID: pl.id
                    )
                }
            default:
                return []
            }

        default:
            return []
        }
    }

    private func tabTitle(_ index: Int) -> String {
        switch index {
        case 0: return "主页"
        case 1: return "新发现"
        case 2: return "广播"
        case 3: return "资料库"
        case 4: return "歌单"
        default: return "导航"
        }
    }

    // MARK: - Search

    private func exitSearchModeCleanup() {
        searchTask?.cancel()
        searchPageTask?.cancel()
        browseLoadTask?.cancel()
        isLoadingNextSearchPage = false
        isSearchResultsActive = false
        searchSections = []
        activeSearchSectionIndex = 0
        searchHistoryExpand.setExpanded(false)
        contentView.setColumnCountOverride(nil)
        layoutViews()
    }

    private func enterSearchEmptyState() {
        searchTask?.cancel()
        searchPageTask?.cancel()
        isLoadingNextSearchPage = false
        isSearchResultsActive = false
        searchSections = []
        activeSearchSectionIndex = 0

        searchHistoryExpand.updateQueries(searchHistoryStore.items)
        contentView.setColumnCountOverride(3)
        layoutViews()
        searchHistoryExpand.setExpanded(!searchHistoryStore.items.isEmpty)

        loadSearchBrowseCategories()
    }

    private func loadSearchBrowseCategories() {
        contentView.setTitle("类别浏览")
        if !loadedSearchBrowseCategories.isEmpty {
            displayBrowseCategories(loadedSearchBrowseCategories)
            return
        }
        if let cached = loadedEditorialCategories[1], !cached.isEmpty {
            loadedSearchBrowseCategories = cached
            displayBrowseCategories(cached)
            return
        }

        let fallback = defaultSearchBrowseCategories()
        displayBrowseCategories(fallback)

        guard let provider = appleMusicProvider else { return }
        browseLoadTask?.cancel()
        browseLoadTask = Task { [weak self] in
            guard let self else { return }
            guard let fetched = try? await provider.fetchEditorialCategories(name: "music"), !fetched.isEmpty else { return }
            guard !Task.isCancelled else { return }
            self.loadedEditorialCategories[1] = fetched
            self.loadedSearchBrowseCategories = fetched
            if self.topBar.isSearchMode && !self.isSearchResultsActive {
                self.displayBrowseCategories(fetched)
            }
        }
    }

    private func displayBrowseCategories(_ categories: [AmpCategory]) {
        let cards = categories.map { cat in
            MediaCardItem(
                id: "browse:\(cat.id)",
                title: cat.title,
                subtitle: "\(cat.items.count > 0 ? "\(cat.items.count) 项" : "流派与精选")",
                type: .chart,
                artworkURL: cat.items.first?.artworkURL,
                browseCategoryID: cat.id
            )
        }
        contentView.displayItems(cards, animated: false)
    }

    private func defaultSearchBrowseCategories() -> [AmpCategory] {
        let titles = [
            "流行", "华语流行", "嘻哈/说唱", "摇滚", "R&B/灵魂乐", "电子舞曲",
            "古典", "爵士", "民谣", "日韩流行", "影视原声", "专注与放松"
        ]
        return titles.enumerated().map { idx, title in
            AmpCategory(id: "default_browse_\(idx)", title: title, items: [])
        }
    }

    private func performSearch(query: String, scope: Int) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        searchTask?.cancel()
        searchPageTask?.cancel()
        isLoadingNextSearchPage = false
        searchGeneration &+= 1
        let expectedGen = searchGeneration

        guard !trimmed.isEmpty else {
            if topBar.isSearchMode {
                enterSearchEmptyState()
            } else {
                exitSearchModeCleanup()
                handleTabSelected(activeTabIndex)
            }
            return
        }

        searchHistoryExpand.setExpanded(false)
        isSearchResultsActive = true
        contentView.setColumnCountOverride(nil)
        layoutViews()

        let scopeName = scope == 1 ? "资料库" : "Apple Music"
        contentView.setTitle("搜索: \"\(trimmed)\" (\(scopeName))")
        contentView.setLoading(true)

        searchTask = Task { [weak self] in
            guard let self else { return }
            var sections: [SearchSection] = []
            var searchError: Error?

            if let provider = self.appleMusicProvider {
                do {
                    let result: MusicSearchResult
                    if scope == 1 {
                        result = try await provider.searchLibrary(query: trimmed)
                    } else {
                        result = try await provider.searchCatalog(query: trimmed, limit: 25)
                    }
                    sections = result.sections
                    if sections.isEmpty && !result.isEmpty {
                        sections = self.fallbackSections(from: result)
                    }
                    // Filter out Music Videos from the search results left sidebar
                    sections = sections.filter { $0.kind != .musicVideos }
                } catch is CancellationError {
                    return
                } catch {
                    searchError = error
                    AppLogger.shared.log(category: .error, level: .warn, message: "搜索失败: \(error.localizedDescription)")
                }
            }

            guard !Task.isCancelled, self.searchGeneration == expectedGen else { return }

            self.contentView.setLoading(false)
            if let searchError {
                self.searchSections = []
                self.sidebar.setCategories([], selectedIndex: 0)
                self.contentView.setTitle("搜索失败: \(searchError.localizedDescription)")
                self.contentView.displayItems([], animated: true)
            } else if sections.isEmpty {
                self.searchSections = []
                self.sidebar.setCategories([], selectedIndex: 0)
                self.contentView.setTitle("未找到 \"\(trimmed)\" 的相关结果")
                self.contentView.displayItems([], animated: true)
            } else {
                self.searchHistoryStore.add(trimmed)
                self.searchHistoryExpand.updateQueries(self.searchHistoryStore.items)
                self.searchSections = sections
                let sidebarCats = sections.map { sec in
                    SidebarCategory(id: sec.id, title: sec.title)
                }
                self.sidebar.setCategories(sidebarCats, selectedIndex: 0)
                self.selectSearchSection(at: 0, animated: true)
            }
        }
    }

    private func selectSearchSection(at index: Int, animated: Bool = false) {
        guard index >= 0, index < searchSections.count else { return }
        searchPageTask?.cancel()
        isLoadingNextSearchPage = false
        activeSearchSectionIndex = index
        let sec = searchSections[index]
        contentView.setTitle(sec.title)
        contentView.displayItems(sec.items.map { mediaCardItem(from: $0) }, animated: animated)
    }

    private func loadNextSearchPageIfNeeded() {
        guard topBar.isSearchMode,
              isSearchResultsActive,
              !isLoadingNextSearchPage,
              activeSearchSectionIndex >= 0,
              activeSearchSectionIndex < searchSections.count,
              let nextURL = searchSections[activeSearchSectionIndex].nextURL,
              let provider = appleMusicProvider else { return }

        isLoadingNextSearchPage = true
        let expectedGen = searchGeneration
        let expectedSecIdx = activeSearchSectionIndex
        let isLib = topBar.currentSearchScope == 1

        searchPageTask = Task { [weak self] in
            guard let self else { return }
            defer {
                Task { @MainActor [weak self] in
                    self?.isLoadingNextSearchPage = false
                }
            }
            guard let page = try? await provider.fetchSearchPage(nextPath: nextURL, isLibrary: isLib, limit: 25) else {
                return
            }
            guard !Task.isCancelled,
                  self.searchGeneration == expectedGen,
                  self.activeSearchSectionIndex == expectedSecIdx,
                  expectedSecIdx < self.searchSections.count else { return }

            self.searchSections[expectedSecIdx].items.append(contentsOf: page.items)
            self.searchSections[expectedSecIdx].nextURL = page.nextURL
            let appendedCards = page.items.map { self.mediaCardItem(from: $0) }
            self.contentView.appendItems(appendedCards)
        }
    }

    private func fallbackSections(from result: MusicSearchResult) -> [SearchSection] {
        var out: [SearchSection] = []
        if !result.tracks.isEmpty {
            out.append(SearchSection(id: "songs", kind: .songs, items: result.tracks.map { .track($0) }))
        }
        if !result.albums.isEmpty {
            out.append(SearchSection(id: "albums", kind: .albums, items: result.albums.map { .album($0) }))
        }
        if !result.artists.isEmpty {
            out.append(SearchSection(id: "artists", kind: .artists, items: result.artists.map { .artist($0) }))
        }
        if !result.playlists.isEmpty {
            out.append(SearchSection(id: "playlists", kind: .playlists, items: result.playlists.map { .playlist($0) }))
        }
        if !result.stations.isEmpty {
            out.append(SearchSection(id: "stations", kind: .stations, items: result.stations.map { .station($0) }))
        }
        return out
    }

    private func mediaCardItem(from item: MusicSearchItem) -> MediaCardItem {
        switch item {
        case .track(let tr):
            return MediaCardItem(
                id: tr.id,
                title: tr.title,
                subtitle: tr.artistName,
                type: .song,
                artworkURL: tr.artworkURL,
                duration: formatDuration(tr.durationSeconds),
                track: tr
            )
        case .album(let al):
            return MediaCardItem(
                id: al.id,
                title: al.title,
                subtitle: "\(al.artistName) · \(al.trackCount) 首",
                type: .album,
                artworkURL: al.artworkURL,
                albumID: al.id
            )
        case .artist(let ar):
            return MediaCardItem(
                id: ar.id,
                title: ar.name,
                subtitle: "艺人",
                type: .artist,
                artworkURL: ar.artworkURL
            )
        case .playlist(let pl):
            return MediaCardItem(
                id: pl.id,
                title: pl.name,
                subtitle: pl.ownerName ?? "播放列表",
                type: .playlist,
                artworkURL: pl.artworkURL,
                playlistID: pl.id
            )
        case .station(let st):
            return MediaCardItem(
                id: st.id,
                title: st.name,
                subtitle: st.description.isEmpty ? "广播单集" : st.description,
                type: .radio,
                artworkURL: st.artworkURL
            )
        case .musicVideo(let mv):
            return MediaCardItem(
                id: mv.id,
                title: mv.title,
                subtitle: "\(mv.artistName) · 音乐视频",
                type: .song,
                artworkURL: mv.artworkURL,
                duration: formatDuration(mv.durationSeconds),
                track: mv
            )
        case .curator(let id, let name, let subtitle, let artworkURL):
            return MediaCardItem(
                id: id,
                title: name,
                subtitle: subtitle ?? "类别",
                type: .chart,
                artworkURL: artworkURL,
                browseCategoryID: id
            )
        }
    }

    // MARK: - Item Click

    private func handleItemClicked(_ item: MediaCardItem) {
        if let browseID = item.browseCategoryID {
            if let cat = loadedSearchBrowseCategories.first(where: { $0.id == browseID }), !cat.items.isEmpty {
                let cards = cat.items.map { ampItem in
                    let mType: MediaItemType
                    switch ampItem.type {
                    case "song": mType = .song
                    case "album": mType = .album
                    case "playlist": mType = .playlist
                    case "station": mType = .radio
                    case "artist": mType = .artist
                    default: mType = .chart
                    }
                    return MediaCardItem(
                        id: ampItem.id,
                        title: ampItem.title,
                        subtitle: ampItem.subtitle,
                        type: mType,
                        artworkURL: ampItem.artworkURL,
                        duration: ampItem.durationMs != nil ? formatDuration(Double(ampItem.durationMs!) / 1000.0) : nil,
                        track: ampItem.track,
                        albumID: ampItem.album?.id,
                        playlistID: ampItem.playlist?.id
                    )
                }
                contentView.setColumnCountOverride(nil)
                contentView.setTitle(cat.title)
                contentView.displayItems(cards, animated: true)
            } else {
                topBar.setSearchQuery(item.title, submit: true)
            }
            return
        }

        switch item.type {
        case .album:
            let albumID = item.albumID ?? item.id
            let isLib = albumID.hasPrefix("l.") || albumID.hasPrefix("i.")
            currentDetailOrigin = PlaybackOrigin(kind: .album, sourceID: albumID, sourceTitle: item.title, isLibrary: isLib, artworkURL: item.artworkURL)
            currentDetailIsLibrary = isLib
            currentDetailNextURL = nil
            currentDetailTotalCount = nil
            detailGeneration &+= 1
            let expectedGen = detailGeneration
            detailLoadTask?.cancel()
            contentView.showDetail(title: item.title, tracks: [])
            detailLoadTask = Task { [weak self] in
                guard let self else { return }
                var page = AppleMusicAmpClient.TrackPage(tracks: [])
                if let provider = self.appleMusicProvider {
                    page = (try? await provider.fetchAlbumTracksPage(albumID: albumID, isLibrary: isLib)) ?? AppleMusicAmpClient.TrackPage(tracks: [])
                }
                guard !Task.isCancelled, self.detailGeneration == expectedGen else { return }
                self.currentDetailNextURL = page.nextURL
                self.currentDetailTotalCount = page.totalCount
                self.contentView.updateDetailTracks(page.tracks)
            }

        case .playlist:
            let playlistID = item.playlistID ?? item.id
            let isLib = playlistID.hasPrefix("p.") || playlistID.hasPrefix("l.")
            currentDetailOrigin = PlaybackOrigin(kind: .playlist, sourceID: playlistID, sourceTitle: item.title, isLibrary: isLib, artworkURL: item.artworkURL)
            currentDetailIsLibrary = isLib
            currentDetailNextURL = nil
            currentDetailTotalCount = nil
            detailGeneration &+= 1
            let expectedGen = detailGeneration
            detailLoadTask?.cancel()
            contentView.showDetail(title: item.title, tracks: [])
            detailLoadTask = Task { [weak self] in
                guard let self else { return }
                var page = AppleMusicAmpClient.TrackPage(tracks: [])
                if let provider = self.appleMusicProvider {
                    page = (try? await provider.fetchPlaylistTracksPage(playlistID: playlistID, isLibrary: isLib)) ?? AppleMusicAmpClient.TrackPage(tracks: [])
                }
                guard !Task.isCancelled, self.detailGeneration == expectedGen else { return }
                self.currentDetailNextURL = page.nextURL
                self.currentDetailTotalCount = page.totalCount
                self.contentView.updateDetailTracks(page.tracks)
            }

        case .artist:
            let artistID = item.id
            let isLib = artistID.hasPrefix("r.") || artistID.hasPrefix("l.") || artistID.hasPrefix("i.")
            if let onArtistSelected {
                onArtistSelected(artistID, isLib)
                return
            }
            openArtistPage(artistID: artistID, isLibrary: isLib, initialName: item.title, artworkURL: item.artworkURL)

        case .song, .radio, .chart:
            let allItems = contentView.displayedItems
            let origin = currentBrowseOrigin(for: item)
            let entries: [QueueEntry] = allItems.compactMap { it in
                let track = it.track ?? MusicTrack(
                    id: it.id,
                    title: it.title,
                    artistName: it.subtitle,
                    albumTitle: "Apple Music",
                    durationMs: 0,
                    artworkURL: it.artworkURL,
                    providerID: "apple_music",
                    providerTrackID: it.id
                )
                return QueueEntry(track: track, origin: currentBrowseOrigin(for: it))
            }
            let clickedTrack = item.track ?? MusicTrack(
                id: item.id,
                title: item.title,
                artistName: item.subtitle,
                albumTitle: "Apple Music",
                durationMs: 0,
                artworkURL: item.artworkURL,
                providerID: "apple_music",
                providerTrackID: item.id
            )
            let index = entries.firstIndex(where: { $0.track.id == clickedTrack.id }) ?? 0
            let effectiveEntries = entries.isEmpty ? [QueueEntry(track: clickedTrack, origin: origin)] : entries
            let kind: PlayableKind = (item.type == .radio) ? .station : .song
            queuePaginationLoader.cancel()
            Task {
                do {
                    try await self.coordinator.playEntries(effectiveEntries, startIndex: index, kind: kind)
                } catch {
                    self.handlePlaybackError(error)
                }
            }
        }
    }

    // MARK: - Artist Personal Page

    public func openArtistPage(
        artistID: String,
        isLibrary: Bool,
        initialName: String? = nil,
        artworkURL: URL? = nil
    ) {
        artistGeneration &+= 1
        let expectedGen = artistGeneration
        artistLoadTask?.cancel()
        detailLoadTask?.cancel()
        contentView.hideDetail()
        searchHistoryExpand.setExpanded(false)

        if artistStack.isEmpty {
            savedArtistOrigin = ArtistOriginSnapshot(
                tabIndex: activeTabIndex,
                categoryIndex: activeCategoryIndex,
                title: contentView.currentTitleText,
                items: contentView.displayedItems,
                columnCountOverride: contentView.columnCountOverride,
                scrollOrigin: contentView.currentScrollOrigin,
                isSearchMode: topBar.isSearchMode,
                isSearchResultsActive: isSearchResultsActive
            )
        }

        let placeholderArtist = MusicArtist(id: artistID, name: initialName ?? "艺人", artworkURL: artworkURL, providerID: "apple_music", providerArtistID: artistID)
        let placeholder = MusicArtistDetail(artist: placeholderArtist)
        artistStack.append(placeholder)
        activeArtistSectionIndex = 0

        topBar.setArtistMode(true, artistName: placeholderArtist.name)
        artistSidebarHeader.configure(artworkURL: artworkURL, isFavorited: false)
        sidebar.setTopHeaderView(nil)
        sidebar.setCategories([], selectedIndex: 0)
        contentView.setColumnCountOverride(nil)
        contentView.setTitle("加载中...")
        contentView.setLoading(true)
        contentView.displayItems([], animated: false)
        layoutViews()

        guard let provider = appleMusicProvider else { return }
        artistLoadTask = Task { [weak self] in
            guard let self else { return }
            do {
                let detail = try await provider.fetchArtistDetail(artistID: artistID, isLibrary: isLibrary)
                guard !Task.isCancelled, self.artistGeneration == expectedGen else { return }
                if !self.artistStack.isEmpty {
                    self.artistStack[self.artistStack.count - 1] = detail
                } else {
                    self.artistStack = [detail]
                }
                self.contentView.setLoading(false)
                self.renderCurrentArtistDetail()
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled, self.artistGeneration == expectedGen else { return }
                self.contentView.setLoading(false)
                self.contentView.setTitle("加载艺人信息失败")
            }
        }
    }

    private func renderCurrentArtistDetail() {
        guard let detail = artistStack.last else { return }
        topBar.setArtistMode(true, artistName: detail.artist.name)
        artistSidebarHeader.configure(artworkURL: detail.artist.artworkURL, isFavorited: detail.isFavorited)
        sidebar.setTopHeaderView(nil)

        let cats = detail.views.map { SidebarCategory(id: $0.id, title: $0.title) }
        let idx = min(activeArtistSectionIndex, max(0, cats.count - 1))
        activeArtistSectionIndex = idx
        sidebar.setCategories(cats, selectedIndex: idx)
        layoutViews()

        if !detail.views.isEmpty {
            selectArtistSection(at: idx, animated: true)
        } else {
            contentView.setTitle(detail.artist.name)
            contentView.displayItems([], animated: false)
        }
    }

    public func popArtistPage() {
        artistLoadTask?.cancel()
        detailLoadTask?.cancel()
        contentView.hideDetail()
        if !artistStack.isEmpty {
            artistStack.removeLast()
        }
        activeArtistSectionIndex = 0

        if !artistStack.isEmpty {
            renderCurrentArtistDetail()
            return
        }

        sidebar.setTopHeaderView(nil)
        topBar.setArtistMode(false)

        if let origin = savedArtistOrigin {
            savedArtistOrigin = nil
            if origin.isSearchMode {
                if origin.isSearchResultsActive && !searchSections.isEmpty {
                    let cats = searchSections.map { SidebarCategory(id: $0.id, title: $0.title) }
                    let idx = min(activeSearchSectionIndex, max(0, cats.count - 1))
                    sidebar.setCategories(cats, selectedIndex: idx)
                    contentView.setColumnCountOverride(origin.columnCountOverride)
                    layoutViews()
                    contentView.setTitle(origin.title)
                    contentView.displayItems(origin.items, animated: false)
                    contentView.restoreScrollOrigin(origin.scrollOrigin)
                } else {
                    contentView.setColumnCountOverride(origin.columnCountOverride)
                    layoutViews()
                    contentView.setTitle(origin.title)
                    contentView.displayItems(origin.items, animated: false)
                    contentView.restoreScrollOrigin(origin.scrollOrigin)
                }
            } else {
                activeTabIndex = origin.tabIndex
                activeCategoryIndex = origin.categoryIndex
                topBar.selectTab(index: origin.tabIndex)
                sidebar.setCategories(categoriesForTab(origin.tabIndex), selectedIndex: origin.categoryIndex)
                contentView.setColumnCountOverride(origin.columnCountOverride)
                layoutViews()
                contentView.setTitle(origin.title)
                contentView.displayItems(origin.items, animated: false)
                contentView.restoreScrollOrigin(origin.scrollOrigin)
            }
            return
        }

        if topBar.isSearchMode {
            if isSearchResultsActive && !searchSections.isEmpty {
                let cats = searchSections.map { SidebarCategory(id: $0.id, title: $0.title) }
                let idx = min(activeSearchSectionIndex, max(0, cats.count - 1))
                sidebar.setCategories(cats, selectedIndex: idx)
                layoutViews()
                selectSearchSection(at: idx)
            } else {
                enterSearchEmptyState()
            }
        } else {
            layoutViews()
            handleTabSelected(activeTabIndex)
        }
    }

    private func selectArtistSection(at index: Int, animated: Bool = false) {
        guard let detail = artistStack.last, index >= 0, index < detail.views.count else { return }
        activeArtistSectionIndex = index
        let sec = detail.views[index]
        contentView.setTitle(sec.title)
        contentView.displayItems(sec.items.map { mediaCardItem(from: $0) }, animated: animated)
    }

    private func playArtistTopSongs() {
        guard let detail = artistStack.last else { return }
        let topSec = detail.views.first(where: { $0.kind == .topSongs }) ?? detail.views.first
        let tracks: [MusicTrack] = topSec?.items.compactMap {
            if case .track(let t) = $0 { return t } else { return nil }
        } ?? []
        guard !tracks.isEmpty else { return }
        let origin = PlaybackOrigin(
            kind: .artist,
            sourceID: detail.artist.id,
            sourceTitle: detail.artist.name,
            isLibrary: detail.artist.id.hasPrefix("r.") || detail.artist.id.hasPrefix("l.") || detail.artist.id.hasPrefix("i."),
            artworkURL: detail.artist.artworkURL
        )
        let entries = tracks.map { QueueEntry(track: $0, origin: origin) }
        queuePaginationLoader.cancel()
        Task {
            try? await coordinator.playEntries(entries, startIndex: 0)
        }
    }

    private func showArtistInfoPopover(relativeTo anchor: NSView) {
        guard let detail = artistStack.last else { return }
        let popover = NSPopover()
        popover.behavior = .transient
        let vc = NSViewController()
        let box = NSView(frame: NSRect(x: 0, y: 0, width: 260, height: 170))
        let nameLbl = NSTextField(labelWithString: detail.artist.name)
        nameLbl.font = NSFont.systemFont(ofSize: 14, weight: .bold)
        nameLbl.frame = NSRect(x: 14, y: 136, width: 232, height: 20)
        box.addSubview(nameLbl)

        let genreText = detail.genreNames.isEmpty ? "Apple Music 艺人" : detail.genreNames.joined(separator: " · ")
        let genreLbl = NSTextField(labelWithString: genreText)
        genreLbl.font = NSFont.systemFont(ofSize: 11.5, weight: .medium)
        genreLbl.textColor = .secondaryLabelColor
        genreLbl.frame = NSRect(x: 14, y: 114, width: 232, height: 16)
        box.addSubview(genreLbl)

        let scroll = NSScrollView(frame: NSRect(x: 14, y: 12, width: 232, height: 96))
        scroll.drawsBackground = false
        let tv = NSTextView(frame: NSRect(x: 0, y: 0, width: 232, height: 96))
        tv.isEditable = false
        tv.drawsBackground = false
        tv.font = NSFont.systemFont(ofSize: 12)
        tv.string = detail.editorialNotes ?? "暂无艺人简介。"
        scroll.documentView = tv
        box.addSubview(scroll)

        vc.view = box
        popover.contentViewController = vc
        popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .maxX)
    }

    private func toggleArtistFavorite() {
        guard var detail = artistStack.last, let provider = appleMusicProvider else { return }
        let nextFav = !detail.isFavorited
        detail.isFavorited = nextFav
        if nextFav { detail.isSuggestLess = false }
        artistStack[artistStack.count - 1] = detail
        artistSidebarHeader.setFavorited(nextFav)

        let artistID = detail.artist.id
        Task {
            do {
                try await provider.setArtistRating(artistID: artistID, value: nextFav ? 1 : nil)
            } catch {
                AppLogger.shared.log(category: .error, level: .warn, message: "收藏艺人操作失败: \(error.localizedDescription)")
            }
        }
    }

    private func showArtistMoreMenu(relativeTo anchor: NSView) {
        guard let detail = artistStack.last else { return }
        let isSuggestLess = detail.isSuggestLess
        let items: [GlassPopoverMenuItem] = [
            GlassPopoverMenuItem(
                id: "artist_station",
                title: "创建艺人电台",
                symbolName: "dot.radiowaves.left.and.right",
                action: { [weak self] in
                    self?.startArtistStation()
                }
            ),
            GlassPopoverMenuItem(
                id: "artist_suggest_less",
                title: isSuggestLess ? "取消减少推荐" : "减少推荐",
                symbolName: "hand.thumbsdown",
                isSelected: isSuggestLess,
                action: { [weak self] in
                    self?.toggleArtistSuggestLess()
                }
            )
        ]
        let anchorInWindow = anchor.convert(anchor.bounds, to: nil)
        let anchorInScreen = anchor.window?.convertToScreen(anchorInWindow) ?? anchorInWindow
        GlassPopoverMenu.shared.present(items: items, relativeTo: anchorInScreen, parentWindow: anchor.window)
    }

    private func startArtistStation() {
        guard let detail = artistStack.last, let provider = appleMusicProvider else { return }
        let artistID = detail.artist.id
        Task { [weak self] in
            guard let self else { return }
            if let station = try? await provider.fetchArtistStation(artistID: artistID) {
                let track = MusicTrack(
                    id: station.id,
                    title: station.name,
                    artistName: detail.artist.name,
                    albumTitle: "艺人电台",
                    durationMs: 0,
                    artworkURL: station.artworkURL ?? detail.artist.artworkURL,
                    providerID: "apple_music",
                    providerTrackID: station.id
                )
                let origin = PlaybackOrigin(
                    kind: .station,
                    sourceID: station.id,
                    sourceTitle: station.name,
                    isLibrary: false,
                    artworkURL: station.artworkURL ?? detail.artist.artworkURL
                )
                let entry = QueueEntry(track: track, origin: origin)
                self.queuePaginationLoader.cancel()
                try? await self.coordinator.playEntries([entry], startIndex: 0, kind: .station)
            }
        }
    }

    private func toggleArtistSuggestLess() {
        guard var detail = artistStack.last, let provider = appleMusicProvider else { return }
        let nextLess = !detail.isSuggestLess
        detail.isSuggestLess = nextLess
        if nextLess {
            detail.isFavorited = false
            artistSidebarHeader.setFavorited(false)
        }
        artistStack[artistStack.count - 1] = detail
        let artistID = detail.artist.id
        Task {
            try? await provider.setArtistRating(artistID: artistID, value: nextLess ? -1 : nil)
        }
    }

    @MainActor
    private func handlePlaybackError(_ error: Error) {
        let isAlreadyLoggedIn = currentSessionSnapshot.sessionState == .authenticated
        if let amErr = error as? AppleMusicError {
            switch amErr {
            case .notAuthorized, .requiresSubscription:
                if !isAlreadyLoggedIn {
                    AppLogger.shared.log(category: .playback, level: .warn, message: "播放需登录 Apple 官方账号，已调出登录引导窗口")
                    self.onToggleAccount?()
                } else {
                    AppLogger.shared.log(category: .playback, level: .warn, message: "当前账号暂无此曲目播放权限或播放器正在就绪中")
                }
                return
            default:
                break
            }
        }
        if case .requiresAuthorization = error as? AuthenticationError {
            if !isAlreadyLoggedIn {
                AppLogger.shared.log(category: .playback, level: .warn, message: "此操作需登录 Apple 官方账号，已调出登录引导窗口")
                self.onToggleAccount?()
            }
            return
        }
        AppLogger.shared.log(category: .playback, level: .error, message: "曲目播放失败: \(error.localizedDescription)")
    }

    // MARK: - Queue Actions & Pagination Helpers

    private func currentBrowseOrigin(for item: MediaCardItem) -> PlaybackOrigin {
        if item.type == .radio {
            return PlaybackOrigin(kind: .station, sourceID: item.id, sourceTitle: item.title, isLibrary: false, artworkURL: item.artworkURL)
        }
        if topBar.isArtistMode, let detail = artistStack.last {
            let isLib = detail.artist.id.hasPrefix("r.") || detail.artist.id.hasPrefix("l.") || detail.artist.id.hasPrefix("i.")
            return PlaybackOrigin(kind: .artist, sourceID: detail.artist.id, sourceTitle: detail.artist.name, isLibrary: isLib, artworkURL: detail.artist.artworkURL)
        }
        if topBar.isSearchMode {
            return PlaybackOrigin(kind: .search, sourceID: nil, sourceTitle: "搜索结果", isLibrary: false, artworkURL: item.artworkURL)
        }
        switch activeTabIndex {
        case 0: return PlaybackOrigin(kind: .forYou, sourceID: nil, sourceTitle: "为你推荐", isLibrary: false, artworkURL: item.artworkURL)
        case 1: return PlaybackOrigin(kind: .browse, sourceID: nil, sourceTitle: "浏览", isLibrary: false, artworkURL: item.artworkURL)
        case 2: return PlaybackOrigin(kind: .station, sourceID: item.id, sourceTitle: item.title, isLibrary: false, artworkURL: item.artworkURL)
        case 3: return PlaybackOrigin(kind: .library, sourceID: nil, sourceTitle: "资料库", isLibrary: true, artworkURL: item.artworkURL)
        default: return .unknown
        }
    }

    private func playDetailTracks(_ tracks: [MusicTrack], startIndex: Int) {
        let origin = currentDetailOrigin
        let batchID = UUID()
        let entries = tracks.map { QueueEntry(track: $0, origin: origin, batchID: batchID) }
        let nextURL = currentDetailNextURL
        let isLib = currentDetailIsLibrary
        let totalCount = currentDetailTotalCount
        let loadingState: QueueLoadingState = nextURL != nil
            ? .loading(loadedCount: entries.count, totalCount: totalCount)
            : .complete(totalCount: entries.count)

        queuePaginationLoader.cancel()
        Task {
            do {
                try await self.coordinator.playEntries(entries, startIndex: startIndex, loadingState: loadingState, batchID: batchID)
                if let nextURL, let provider = self.appleMusicProvider {
                    let snap = await self.coordinator.currentStructuredQueueSnapshot()
                    self.queuePaginationLoader.startBackgroundPagination(
                        coordinator: self.coordinator,
                        batchID: batchID,
                        expectedQueueID: snap.queueID,
                        expectedSessionScope: snap.sessionScope,
                        origin: origin,
                        initialLoadedCount: entries.count,
                        initialNextURL: nextURL,
                        totalCount: totalCount
                    ) { url in
                        let page = try await provider.fetchTracksPage(nextURL: url, isLibrary: isLib)
                        return QueuePageFetchResult(tracks: page.tracks, nextURL: page.nextURL, totalCount: page.totalCount)
                    }
                }
            } catch {
                self.handlePlaybackError(error)
            }
        }
    }

    private func handleTracksQueueAction(_ tracks: [MusicTrack], origin: PlaybackOrigin, action: LibraryQueueAction) {
        guard !tracks.isEmpty else { return }
        let actionName: String = switch action {
        case .playNow: "立即播放"
        case .playNext: "下一首播放"
        case .appendToQueue: "添加到队列"
        }
        AppLogger.shared.log(
            category: .userAction,
            level: .info,
            message: "用户在音乐库触发队列操作 [\(actionName)]: \(tracks.count) 首 (首曲: \(tracks[0].title), 来源: \(origin.displayTitle))"
        )
        let entries = tracks.map { QueueEntry(track: $0, origin: origin) }
        Task {
            do {
                switch action {
                case .playNow:
                    self.queuePaginationLoader.cancel()
                    try await self.coordinator.playEntries(entries, startIndex: 0)
                case .playNext:
                    try await self.coordinator.insertNext(entries)
                case .appendToQueue:
                    try await self.coordinator.append(entries)
                }
            } catch let editErr as QueueEditError {
                if case .remoteQueueRequiresSwitch(let stationTitle) = editErr {
                    self.promptRemoteStationSwitch(stationTitle: stationTitle, entries: entries, action: action)
                } else {
                    self.handlePlaybackError(editErr)
                }
            } catch {
                self.handlePlaybackError(error)
            }
        }
    }

    private func handleCardQueueAction(_ item: MediaCardItem, action: LibraryQueueAction) {
        switch item.type {
        case .song, .radio, .chart:
            if action == .playNow {
                handleItemClicked(item)
                return
            }
            let track = item.track ?? MusicTrack(
                id: item.id,
                title: item.title,
                artistName: item.subtitle,
                albumTitle: "Apple Music",
                durationMs: 0,
                artworkURL: item.artworkURL,
                providerID: "apple_music",
                providerTrackID: item.id
            )
            handleTracksQueueAction([track], origin: currentBrowseOrigin(for: item), action: action)

        case .album, .playlist:
            guard let provider = appleMusicProvider else { return }
            let isAlbum = (item.type == .album)
            let sourceID = isAlbum ? (item.albumID ?? item.id) : (item.playlistID ?? item.id)
            let isLib = isAlbum ? (sourceID.hasPrefix("l.") || sourceID.hasPrefix("i.")) : (sourceID.hasPrefix("p.") || sourceID.hasPrefix("l."))
            let origin = PlaybackOrigin(
                kind: isAlbum ? .album : .playlist,
                sourceID: sourceID,
                sourceTitle: item.title,
                isLibrary: isLib,
                artworkURL: item.artworkURL
            )

            Task {
                do {
                    let firstPage = isAlbum
                        ? try await provider.fetchAlbumTracksPage(albumID: sourceID, isLibrary: isLib)
                        : try await provider.fetchPlaylistTracksPage(playlistID: sourceID, isLibrary: isLib)
                    guard !firstPage.tracks.isEmpty else { return }

                    if action == .playNow {
                        let batchID = UUID()
                        let entries = firstPage.tracks.map { QueueEntry(track: $0, origin: origin, batchID: batchID) }
                        let loadingState: QueueLoadingState = firstPage.nextURL != nil
                            ? .loading(loadedCount: entries.count, totalCount: firstPage.totalCount)
                            : .complete(totalCount: entries.count)
                        self.queuePaginationLoader.cancel()
                        try await self.coordinator.playEntries(entries, startIndex: 0, loadingState: loadingState, batchID: batchID)
                        if let nextURL = firstPage.nextURL {
                            let snap = await self.coordinator.currentStructuredQueueSnapshot()
                            self.queuePaginationLoader.startBackgroundPagination(
                                coordinator: self.coordinator,
                                batchID: batchID,
                                expectedQueueID: snap.queueID,
                                expectedSessionScope: snap.sessionScope,
                                origin: origin,
                                initialLoadedCount: entries.count,
                                initialNextURL: nextURL,
                                totalCount: firstPage.totalCount
                            ) { url in
                                let page = try await provider.fetchTracksPage(nextURL: url, isLibrary: isLib)
                                return QueuePageFetchResult(tracks: page.tracks, nextURL: page.nextURL, totalCount: page.totalCount)
                            }
                        }
                    } else {
                        // Whole-collection insertNext/append loads all pages first so batch order is guaranteed
                        var allTracks = firstPage.tracks
                        var nextURL = firstPage.nextURL
                        var visited: Set<String> = []
                        var pages = 1
                        while let url = nextURL, pages < 100, !visited.contains(url.absoluteString) {
                            visited.insert(url.absoluteString)
                            pages += 1
                            let page = try await provider.fetchTracksPage(nextURL: url, isLibrary: isLib)
                            allTracks.append(contentsOf: page.tracks)
                            nextURL = page.nextURL
                        }
                        self.handleTracksQueueAction(allTracks, origin: origin, action: action)
                    }
                } catch {
                    self.handlePlaybackError(error)
                }
            }

        case .artist:
            break
        }
    }

    private func promptRemoteStationSwitch(stationTitle: String?, entries: [QueueEntry], action: LibraryQueueAction) {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "切换为本地播放队列？"
        let name = (stationTitle?.isEmpty == false) ? "「\(stationTitle!)」" : "电台"
        alert.informativeText = "当前正在收听\(name)，电台不支持直接插入或追加普通曲目。是否停止电台并改用新队列？"
        alert.addButton(withTitle: "切换并\(action == .playNext ? "下一首播放" : "添加到队列")")
        alert.addButton(withTitle: "取消")
        if alert.runModal() == .alertFirstButtonReturn {
            AppLogger.shared.log(category: .queue, level: .info, message: "用户确认从电台切换为本地队列并执行队列操作")
            queuePaginationLoader.cancel()
            Task {
                try? await self.coordinator.playEntries(entries, startIndex: 0)
            }
        } else {
            AppLogger.shared.log(category: .queue, level: .info, message: "用户取消电台切换本地队列，保持当前电台播放")
        }
    }

    // MARK: - Utilities & Sample Fallbacks

    private func formatDuration(_ seconds: Double?) -> String {
        guard let seconds, seconds > 0 else { return "" }
        let total = Int(seconds)
        let m = total / 60
        let s = total % 60
        return String(format: "%02d:%02d", m, s)
    }
}
