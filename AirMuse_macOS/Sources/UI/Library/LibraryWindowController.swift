import AppKit
import Domain
import DesignSystem
import Playback
import PlatformRuntime
import Application
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
    private let registry: ProviderSessionRegistry?
    private let browseService: BrowseService?
    private let searchService: SearchCollectionService?
    private let playbackIntentService: PlaybackIntentService?
    private let navigationService: NavigationService?
    private let stateStore = MediaResourceStateStore()
    private var stateObserverID: UUID?
    public var onObservedResourceStateChanged: ((String, MediaResourceState) -> Void)?
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
    private var navigationGeneration: UInt64 = 0
    private var detailLoadTask: Task<Void, Never>?
    private var artistLoadTask: Task<Void, Never>?
    private var locateTask: Task<Void, Never>?
    private var isLoadingHomeSidebar: Bool = false
    private let queuePaginationLoader = QueuePaginationLoader()
    private var currentDetailOrigin: PlaybackOrigin = .unknown
    private var currentDetailNextCursor: PageCursor?
    private var currentDetailIsLibrary: Bool = false
    private var currentDetailTotalCount: Int?
    private var playIntentGeneration: UInt64 = 0
    private var pendingQueueSubmissionChain: Task<Void, Never>?
    private var activeCollectionActionKeys: Set<String> = []

    // Dynamic remote sections cached per tab index (0: Home, 1: Browse, 2: Radio)
    private var loadedEditorialSections: [Int: [BrowseSectionModel]] = [:]
    private var loadedSearchBrowseSections: [BrowseSectionModel] = []
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

    public init(coordinator: PlaybackCoordinatorV2, registry: ProviderSessionRegistry? = nil) {
        self.coordinator = coordinator
        self.registry = registry
        self.browseService = registry.map { BrowseService(registry: $0) }
        self.searchService = registry.map { SearchCollectionService(registry: $0) }
        self.playbackIntentService = registry.map { PlaybackIntentService(coordinator: coordinator, registry: $0) }
        self.navigationService = registry.map { NavigationService(registry: $0) }

        super.init(window: nil)

        if let registry {
            Task { @MainActor [weak self] in
                guard let self else { return }
                let pid = await registry.browsingProviderID ?? .appleMusic
                if let adapter = try? await registry.activate(providerID: pid) {
                    self.stateStore.configure(provider: adapter.mutationProvider)
                }
            }
        }
        if let cacheDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("AirMuse/MediaState", isDirectory: true) {
            stateStore.configurePersistence(directory: cacheDir, ttlSeconds: 900)
        }
        stateObserverID = stateStore.addObserver { [weak self] normalizedKey, state in
            guard let self else { return }
            if var detail = self.artistStack.last {
                let artistRef = MediaResourceReference(
                    kind: .artist,
                    providerID: self.currentDetailOrigin.providerID,
                    canonicalID: detail.artist.id,
                    title: detail.artist.name,
                    isLibrary: self.currentDetailIsLibrary
                )
                if artistRef.normalizedKey == normalizedKey {
                    let confirmedFav = state.favorite.confirmedBool ?? detail.isFavorited
                    detail.isFavorited = confirmedFav
                    self.artistStack[self.artistStack.count - 1] = detail
                    self.artistSidebarHeader.setFavorited(confirmedFav)
                }
            }
            if self.currentDetailResourceReference().normalizedKey == normalizedKey {
                self.refreshDetailActionButtons()
            }
            self.onObservedResourceStateChanged?(normalizedKey, state)
        }

        setupPanelUI()
        wireCallbacks()
        observeSession()
    }

    isolated deinit {
        if let stateObserverID {
            stateStore.removeObserver(stateObserverID)
        }
        sessionTask?.cancel()
        categoryLoadTask?.cancel()
        searchTask?.cancel()
        searchPageTask?.cancel()
        browseLoadTask?.cancel()
        detailLoadTask?.cancel()
        artistLoadTask?.cancel()
        let loader = queuePaginationLoader
        Task { await loader.cancel() }
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
        panel.addSubview(queueDockView)

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
        queueDockView.bottomBarHeight = capH
        queueDockView.frame = pBounds
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
        guard let registry else { return }
        sessionTask = Task { @MainActor [weak self] in
            let stream = await registry.sessionSnapshots()
            for await (pid, snap) in stream {
                guard !Task.isCancelled, let self else { break }
                let browsingPID = await registry.browsingProviderID ?? .appleMusic
                guard pid == browsingPID else { continue }
                let prevState = self.currentSessionSnapshot.sessionState
                self.currentSessionSnapshot = snap
                self.stateStore.setScope(.init(
                    providerID: pid.rawValue,
                    accountID: snap.context?.accountID ?? "",
                    storefront: snap.context?.storefront ?? ""
                ))
                self.updateTopBarTitle()
                switch snap.sessionState {
                case .signedOut, .expired, .invalidating:
                    if prevState != snap.sessionState {
                        Task { await self.queuePaginationLoader.cancel() }
                        self.loadedEditorialSections.removeAll()
                        self.handleTabSelected(self.activeTabIndex)
                    }
                case .authenticated:
                    if prevState != .authenticated {
                        if self.activeTabIndex == 0 {
                            self.loadDynamicHomeSidebar()
                        }
                        self.loadCurrentCategory(forceRefresh: true)
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

        contentView.onTrackIndexSelected = { [weak self] idx, track in
            guard let self else { return }
            AppLogger.shared.log(category: .userAction, level: .info, message: "用户在曲目列表中选中播放: \(track.title) - \(track.artistName) (row=\(idx), ID: \(track.id))")
            let allTracks = self.contentView.currentDetailTracksList
            let sourceTracks = allTracks.isEmpty ? [track] : allTracks
            let safeIndex = sourceTracks.indices.contains(idx) ? idx : (sourceTracks.firstIndex(where: { $0.id == track.id }) ?? 0)
            self.playDetailTracks(sourceTracks, startIndex: safeIndex)
        }

        contentView.onTrackContextMenuRequested = { [weak self] track in
            guard let self else { return nil }
            let resource = self.resourceReference(for: track)
            let caps = self.mediaCapabilities(for: resource)
            let state = self.stateStore.state(for: resource)
            self.prefetchResourceStateIfNeeded(resource: resource, state: state, capabilities: caps)
            let ctx = MediaActionContext(
                resource: resource,
                location: .trackRow,
                state: state,
                capabilities: caps,
                currentDetail: self.currentDetailIdentity()
            )
            let descriptor = MediaActionResolver.resolveContextMenu(for: ctx)
            return MediaContextMenuBuilder.buildMenu(from: descriptor) { [weak self] action in
                self?.dispatchMediaAction(action, tracks: [track], origin: self?.currentDetailOrigin ?? .unknown)
            }
        }

        contentView.detailPlayMenuDescriptorProvider = { [weak self] in
            guard let self else { return MediaActionMenuDescriptor(sections: []) }
            let resource = self.currentDetailResourceReference()
            let caps = self.mediaCapabilities(for: resource)
            let state = self.stateStore.state(for: resource)
            self.prefetchResourceStateIfNeeded(resource: resource, state: state, capabilities: caps)
            let ctx = MediaActionContext(
                resource: resource,
                location: .pageHeader,
                state: state,
                capabilities: caps,
                currentDetail: self.currentDetailIdentity()
            )
            return MediaActionResolver.resolveContextMenu(for: ctx)
        }

        contentView.onDetailMediaAction = { [weak self] tracks, action in
            guard let self else { return }
            self.dispatchMediaAction(action, tracks: tracks, origin: self.currentDetailOrigin)
        }

        contentView.onDetailContextMenuRequested = { [weak self] tracks in
            guard let self, !tracks.isEmpty else { return nil }
            let resource = self.currentDetailResourceReference()
            let ctx = MediaActionContext(
                resource: resource,
                location: .pageHeader,
                state: self.stateStore.state(for: resource),
                capabilities: self.mediaCapabilities(for: resource),
                currentDetail: self.currentDetailIdentity()
            )
            let descriptor = MediaActionResolver.resolveContextMenu(for: ctx)
            return MediaContextMenuBuilder.buildMenu(from: descriptor) { [weak self] action in
                self?.dispatchMediaAction(action, tracks: tracks, origin: self?.currentDetailOrigin ?? .unknown)
            }
        }

        contentView.onItemContextMenuRequested = { [weak self] item in
            guard let self else { return nil }
            let resource = self.resourceReference(for: item)
            let caps = self.mediaCapabilities(for: resource)
            let state = self.stateStore.state(for: resource)
            self.prefetchResourceStateIfNeeded(resource: resource, state: state, capabilities: caps)
            let ctx = MediaActionContext(
                resource: resource,
                location: .card,
                state: state,
                capabilities: caps,
                currentDetail: self.currentDetailIdentity()
            )
            let descriptor = MediaActionResolver.resolveContextMenu(for: ctx)
            return MediaContextMenuBuilder.buildMenu(from: descriptor) { [weak self] action in
                self?.dispatchMediaAction(action, item: item)
            }
        }

        queueDockView.queueContextBuilder = { [weak self] resource, selectedIDs in
            guard let self else {
                return MediaActionContext(resource: resource, location: .queueRow, selectedCount: selectedIDs.count, selectedQueueEntryIDs: selectedIDs)
            }
            return MediaActionContext(
                resource: resource,
                location: .queueRow,
                state: self.stateStore.state(for: resource),
                capabilities: self.mediaCapabilities(for: resource),
                currentDetail: self.currentDetailIdentity(),
                selectedCount: selectedIDs.count,
                selectedQueueEntryIDs: selectedIDs
            )
        }

        queueDockView.onQueueMediaAction = { [weak self] action in
            self?.dispatchMediaAction(action)
        }

        queueDockView.onNavigateToOrigin = { [weak self] origin in
            self?.navigateToOriginPurely(origin, targetTrack: nil)
        }
        queueDockView.onOriginNavigateAction = { [weak self] action, entry in
            guard let self else { return }
            switch action {
            case .navigateToOrigin(let origin), .navigateToOriginConcise(let origin):
                self.navigateToOriginPurely(origin, targetTrack: entry.track)
            case .navigateToAlbum(let id, let title, let isLibrary):
                let origin = PlaybackOrigin(
                    kind: .album,
                    sourceID: id,
                    sourceTitle: title,
                    isLibrary: isLibrary,
                    navigationTarget: .resource(kind: .album, id: id, isLibrary: isLibrary, providerID: entry.track.providerID)
                )
                self.navigateToOriginPurely(origin, targetTrack: entry.track)
            default:
                self.dispatchMediaAction(action)
            }
        }
        queueDockView.currentDetailIdentityProvider = { [weak self] in
            self?.currentDetailIdentity()
        }
        queueDockView.onResolveTrackRelationships = { [weak self] track in
            await self?.searchService?.resolveTrackRelationships(for: track)
        }

        queueDockView.onReportError = { [weak self] message in
            AppLogger.shared.log(category: .playback, level: .warn, message: "队列操作提示: \(message)")
            self?.queueDockView.showFeedback(message)
        }

        queueDockView.onRetryPagination = { [weak self] in
            guard let self else { return }
            Task {
                await self.queuePaginationLoader.retryFailedPagination()
            }
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
            if let dynamic = loadedEditorialSections[0], !dynamic.isEmpty {
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
            if let dynamic = loadedEditorialSections[1], !dynamic.isEmpty {
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
            if let dynamic = loadedEditorialSections[2], !dynamic.isEmpty {
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

    private func mediaCardItem(from model: MediaCardModel) -> MediaCardItem {
        let mType: MediaItemType = switch model.identity.kind {
        case .song: .song
        case .album: .album
        case .playlist: .playlist
        case .station: .radio
        case .artist: .artist
        default: .chart
        }
        return MediaCardItem(
            id: model.identity.opaqueID,
            title: model.title,
            subtitle: model.subtitle,
            type: mType,
            artworkURL: model.artworkURL,
            duration: model.track.map { formatDuration($0.durationSeconds) },
            track: model.track,
            albumID: model.identity.kind == .album ? model.identity.opaqueID : model.track?.albumID,
            playlistID: model.identity.kind == .playlist ? model.identity.opaqueID : nil,
            isLibrary: model.identity.scope.isLibrary,
            providerID: model.identity.providerID.rawValue,
            scope: model.identity.scope
        )
    }

    private func loadDynamicHomeSidebar() {
        guard !isLoadingHomeSidebar, let browseService, let registry else { return }
        isLoadingHomeSidebar = true
        Task { [weak self] in
            defer {
                Task { @MainActor [weak self] in self?.isLoadingHomeSidebar = false }
            }
            guard let self else { return }
            let pid = await registry.browsingProviderID ?? .appleMusic
            let route = BrowseRoute(providerID: pid, scope: .catalog(region: nil), kind: .tab(id: "home"))
            guard let (_, page) = try? await browseService.fetchBrowsePage(route: route), !page.sections.isEmpty else { return }
            guard self.activeTabIndex == 0 else { return }
            self.loadedEditorialSections[0] = page.sections
            let categories = self.categoriesForTab(0)
            let prevIndex = min(self.activeCategoryIndex, max(0, categories.count - 1))
            self.sidebar.setCategories(categories, selectedIndex: prevIndex)
        }
    }

    private func loadDynamicEditorialSidebar(tabIndex: Int) {
        guard let browseService, let registry else { return }
        let tabID = (tabIndex == 2) ? "radio" : "browse"
        Task { [weak self] in
            guard let self else { return }
            let pid = await registry.browsingProviderID ?? .appleMusic
            let route = BrowseRoute(providerID: pid, scope: .catalog(region: nil), kind: .tab(id: tabID))
            guard let (_, page) = try? await browseService.fetchBrowsePage(route: route), !page.sections.isEmpty else { return }
            guard self.activeTabIndex == tabIndex else { return }
            self.loadedEditorialSections[tabIndex] = page.sections
            let categories = self.categoriesForTab(tabIndex)
            let prevIndex = min(self.activeCategoryIndex, max(0, categories.count - 1))
            self.sidebar.setCategories(categories, selectedIndex: prevIndex)
        }
    }

    // MARK: - Data Loading

    private func loadCurrentCategory(forceRefresh: Bool = false) {
        let targetTab = activeTabIndex
        let targetCategory = activeCategoryIndex

        if forceRefresh {
            loadedEditorialSections.removeValue(forKey: targetTab)
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
            category: .render,
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

            if let browseService = self.browseService, let registry = self.registry {
                do {
                    items = try await self.fetchItems(forTab: targetTab, categoryIndex: targetCategory, browseService: browseService, registry: registry)
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

    private func fetchItems(forTab tabIndex: Int, categoryIndex: Int, browseService: BrowseService, registry: ProviderSessionRegistry) async throws -> [MediaCardItem] {
        if let dynamic = loadedEditorialSections[tabIndex], categoryIndex < dynamic.count {
            return dynamic[categoryIndex].items.map { mediaCardItem(from: $0) }
        }
        let pid = await registry.browsingProviderID ?? .appleMusic
        let tabID: String = switch tabIndex {
        case 0: "home"
        case 1: "browse"
        case 2: "radio"
        case 3: "library"
        case 4: "library"
        default: "home"
        }
        let route = BrowseRoute(providerID: pid, scope: (tabIndex == 3 || tabIndex == 4) ? .library(accountID: "", region: nil) : .catalog(region: nil), kind: .tab(id: tabID))
        let (_, page) = try await browseService.fetchBrowsePage(route: route)
        if !page.sections.isEmpty {
            loadedEditorialSections[tabIndex] = page.sections
            let idx = min(categoryIndex, page.sections.count - 1)
            return page.sections[idx].items.map { mediaCardItem(from: $0) }
        }
        return []
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
        if !loadedSearchBrowseSections.isEmpty {
            displayBrowseSections(loadedSearchBrowseSections)
            return
        }
        if let cached = loadedEditorialSections[1], !cached.isEmpty {
            loadedSearchBrowseSections = cached
            displayBrowseSections(cached)
            return
        }

        let fallback = defaultSearchBrowseSections()
        displayBrowseSections(fallback)

        guard let browseService, let registry else { return }
        browseLoadTask?.cancel()
        browseLoadTask = Task { [weak self] in
            guard let self else { return }
            let pid = await registry.browsingProviderID ?? .appleMusic
            let route = BrowseRoute(providerID: pid, scope: .catalog(region: nil), kind: .tab(id: "browse"))
            guard let (_, page) = try? await browseService.fetchBrowsePage(route: route), !page.sections.isEmpty else { return }
            guard !Task.isCancelled else { return }
            self.loadedEditorialSections[1] = page.sections
            self.loadedSearchBrowseSections = page.sections
            if self.topBar.isSearchMode && !self.isSearchResultsActive {
                self.displayBrowseSections(page.sections)
            }
        }
    }

    private func displayBrowseSections(_ sections: [BrowseSectionModel]) {
        let cards = sections.map { sec in
            MediaCardItem(
                id: "browse:\(sec.id)",
                title: sec.title,
                subtitle: "\(sec.items.count > 0 ? "\(sec.items.count) 项" : "流派与精选")",
                type: .chart,
                artworkURL: sec.items.first?.artworkURL,
                browseCategoryID: sec.id
            )
        }
        contentView.displayItems(cards, animated: false)
    }

    private func defaultSearchBrowseSections() -> [BrowseSectionModel] {
        let titles = [
            "流行", "华语流行", "嘻哈/说唱", "摇滚", "R&B/灵魂乐", "电子舞曲",
            "古典", "爵士", "民谣", "日韩流行", "影视原声", "专注与放松"
        ]
        return titles.enumerated().map { idx, title in
            BrowseSectionModel(id: "default_browse_\(idx)", title: title, items: [])
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

            if let browseService = self.browseService, let registry = self.registry {
                do {
                    let pid = await registry.browsingProviderID ?? .appleMusic
                    let resScope: ResourceScope = scope == 1 ? .library(accountID: "", region: nil) : .catalog(region: nil)
                    let route = BrowseRoute(providerID: pid, scope: resScope, kind: .search(query: trimmed, scope: scope == 1 ? "library" : "catalog"))
                    let (_, page) = try await browseService.fetchBrowsePage(route: route)
                    sections = page.sections.map { sec in
                        let searchItems: [MusicSearchItem] = sec.items.compactMap { card in
                            if let t = card.track { return .track(t) }
                            switch card.identity.kind {
                            case .album:
                                return .album(MusicAlbum(id: card.identity.opaqueID, title: card.title, artistName: card.subtitle, artworkURL: card.artworkURL))
                            case .artist:
                                return .artist(MusicArtist(id: card.identity.opaqueID, name: card.title, artworkURL: card.artworkURL))
                            case .playlist:
                                return .playlist(MusicPlaylist(id: card.identity.opaqueID, name: card.title, description: "", artworkURL: card.artworkURL, providerID: card.identity.providerID.rawValue, providerPlaylistID: card.identity.opaqueID))
                            case .station:
                                return .station(MusicStation(id: card.identity.opaqueID, name: card.title, description: card.subtitle, artworkURL: card.artworkURL, providerID: card.identity.providerID.rawValue, providerStationID: card.identity.opaqueID))
                            default:
                                return nil
                            }
                        }
                        return SearchSection(id: sec.id, kind: .unknown, title: sec.title, items: searchItems, nextURL: sec.nextCursor?.opaqueToken)
                    }
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
              let nextToken = searchSections[activeSearchSectionIndex].nextURL,
              let browseService, let registry else { return }

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
            let pid = await registry.browsingProviderID ?? .appleMusic
            let cursor = PageCursor(
                opaqueToken: nextToken,
                providerID: pid,
                scope: isLib ? .library(accountID: "", region: nil) : .catalog(region: nil),
                routeFingerprint: "search"
            )
            guard let secPage = try? await browseService.fetchSectionPage(cursor: cursor) else {
                return
            }
            guard !Task.isCancelled,
                  self.searchGeneration == expectedGen,
                  self.activeSearchSectionIndex == expectedSecIdx,
                  expectedSecIdx < self.searchSections.count else { return }

            let appendedCards = secPage.items.map { self.mediaCardItem(from: $0) }
            self.searchSections[expectedSecIdx].nextURL = secPage.nextCursor?.opaqueToken
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
            if let sec = loadedSearchBrowseSections.first(where: { $0.id == browseID }), !sec.items.isEmpty {
                let cards = sec.items.map { mediaCardItem(from: $0) }
                contentView.setColumnCountOverride(nil)
                contentView.setTitle(sec.title)
                contentView.displayItems(cards, animated: true)
            } else {
                topBar.setSearchQuery(item.title, submit: true)
            }
            return
        }

        switch item.type {
        case .album:
            let albumID = item.albumID ?? item.id
            let isLib = item.isLibrary ?? false
            let pid = item.providerID ?? ProviderID.appleMusic.rawValue
            let scope: ResourceScope = item.scope ?? (isLib ? .library(accountID: "", region: nil) : .catalog(region: nil))
            currentDetailOrigin = PlaybackOrigin(
                kind: .album,
                sourceID: albumID,
                sourceTitle: item.title,
                isLibrary: isLib,
                providerID: pid,
                scope: scope,
                artworkURL: item.artworkURL,
                navigationTarget: .resource(kind: .album, id: albumID, isLibrary: isLib, providerID: pid)
            )
            currentDetailIsLibrary = isLib
            currentDetailNextCursor = nil
            currentDetailTotalCount = nil
            detailGeneration &+= 1
            let expectedGen = detailGeneration
            detailLoadTask?.cancel()
            contentView.showDetail(title: item.title, tracks: [])
            let detailRef = currentDetailResourceReference()
            prefetchResourceStateIfNeeded(resource: detailRef, state: stateStore.state(for: detailRef), capabilities: mediaCapabilities(for: detailRef))
            detailLoadTask = Task { [weak self] in
                guard let self else { return }
                var page = CollectionTrackPage(tracks: [])
                if let searchService = self.searchService {
                    let identity = ResourceIdentity(providerID: ProviderID(rawValue: pid), kind: .album, opaqueID: albumID, scope: scope)
                    page = (try? await searchService.fetchCollectionTracks(identity: identity, cursor: nil)) ?? CollectionTrackPage(tracks: [])
                }
                guard !Task.isCancelled, self.detailGeneration == expectedGen else { return }
                self.currentDetailNextCursor = page.nextCursor
                self.currentDetailTotalCount = page.totalCount
                self.contentView.updateDetailTracks(page.tracks)
                let trackRefs = page.tracks.map { self.resourceReference(for: $0) }
                Task { @MainActor [weak self] in
                    await self?.stateStore.refreshStates(for: trackRefs)
                }
            }

        case .playlist:
            let playlistID = item.playlistID ?? item.id
            let isLib = item.isLibrary ?? false
            let pid = item.providerID ?? ProviderID.appleMusic.rawValue
            let scope: ResourceScope = item.scope ?? (isLib ? .library(accountID: "", region: nil) : .catalog(region: nil))
            currentDetailOrigin = PlaybackOrigin(
                kind: .playlist,
                sourceID: playlistID,
                sourceTitle: item.title,
                isLibrary: isLib,
                providerID: pid,
                scope: scope,
                artworkURL: item.artworkURL,
                navigationTarget: .resource(kind: .playlist, id: playlistID, isLibrary: isLib, providerID: pid)
            )
            currentDetailIsLibrary = isLib
            currentDetailNextCursor = nil
            currentDetailTotalCount = nil
            detailGeneration &+= 1
            let expectedGen = detailGeneration
            detailLoadTask?.cancel()
            contentView.showDetail(title: item.title, tracks: [])
            let detailRef = currentDetailResourceReference()
            prefetchResourceStateIfNeeded(resource: detailRef, state: stateStore.state(for: detailRef), capabilities: mediaCapabilities(for: detailRef))
            detailLoadTask = Task { [weak self] in
                guard let self else { return }
                var page = CollectionTrackPage(tracks: [])
                if let searchService = self.searchService {
                    let identity = ResourceIdentity(providerID: ProviderID(rawValue: pid), kind: .playlist, opaqueID: playlistID, scope: scope)
                    page = (try? await searchService.fetchCollectionTracks(identity: identity, cursor: nil)) ?? CollectionTrackPage(tracks: [])
                }
                guard !Task.isCancelled, self.detailGeneration == expectedGen else { return }
                self.currentDetailNextCursor = page.nextCursor
                self.currentDetailTotalCount = page.totalCount
                self.contentView.updateDetailTracks(page.tracks)
                let trackRefs = page.tracks.map { self.resourceReference(for: $0) }
                Task { @MainActor [weak self] in
                    await self?.stateStore.refreshStates(for: trackRefs)
                }
            }

        case .artist:
            let artistID = item.id
            let isLib = item.isLibrary ?? false
            if let onArtistSelected {
                onArtistSelected(artistID, isLib)
                return
            }
            openArtistPage(artistID: artistID, isLibrary: isLib, initialName: item.title, artworkURL: item.artworkURL)

        case .radio:
            let origin = currentBrowseOrigin(for: item)
            let stationTrack = item.track ?? MusicTrack(
                id: item.id,
                title: item.title,
                artistName: item.subtitle,
                albumTitle: "电台",
                durationMs: 0,
                artworkURL: item.artworkURL,
                providerID: "apple_music",
                providerTrackID: item.id
            )
            let stationEntry = QueueEntry(track: stationTrack, origin: origin)
            playIntentGeneration &+= 1
            let expectedIntentGen = playIntentGeneration
            Task {
                await self.queuePaginationLoader.cancel()
                guard self.playIntentGeneration == expectedIntentGen else { return }
                do {
                    try await self.coordinator.playEntries([stationEntry], startIndex: 0, kind: .station)
                    self.queueDockView.playQueueAdditionAnimation(kind: .station, message: "已提交播放「\(stationTrack.title)」")
                } catch {
                    self.handlePlaybackError(error)
                }
            }

        case .song, .chart:
            let playableItems = contentView.displayedItems.filter { $0.type == .song || $0.type == .chart }
            let origin = currentBrowseOrigin(for: item)
            let entries: [QueueEntry] = playableItems.map { it in
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
            playIntentGeneration &+= 1
            let expectedIntentGen = playIntentGeneration
            Task {
                await self.queuePaginationLoader.cancel()
                guard self.playIntentGeneration == expectedIntentGen else { return }
                do {
                    try await self.coordinator.playEntries(effectiveEntries, startIndex: index, kind: .song)
                    let vKind: QueueAdditionVisualKind = effectiveEntries.count > 1 ? .multiSongs(count: effectiveEntries.count) : .song
                    self.queueDockView.playQueueAdditionAnimation(kind: vKind, message: "已提交播放「\(clickedTrack.title)」")
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

        guard let searchService, let registry else { return }
        artistLoadTask = Task { [weak self] in
            guard let self else { return }
            do {
                let pid = await registry.browsingProviderID ?? .appleMusic
                let scope: ResourceScope = isLibrary ? .library(accountID: "", region: nil) : .catalog(region: nil)
                let identity = ResourceIdentity(providerID: pid, kind: .artist, opaqueID: artistID, scope: scope)
                let detail = try await searchService.fetchArtistDetail(identity: identity)
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

    private func playArtistTopSongs(intent: MediaPlayIntent = .replaceAndPlay) {
        guard let detail = artistStack.last else { return }
        let topSec = detail.views.first(where: { $0.kind == .topSongs }) ?? detail.views.first
        let tracks: [MusicTrack] = topSec?.items.compactMap {
            if case .track(let t) = $0 { return t } else { return nil }
        } ?? []
        guard !tracks.isEmpty else {
            queueDockView.showFeedback("该艺人暂无可播放热门歌曲")
            return
        }
        let isArtistLib = currentDetailIsLibrary
        let origin = PlaybackOrigin(
            kind: .artist,
            sourceID: detail.artist.id,
            sourceTitle: detail.artist.name,
            isLibrary: isArtistLib,
            artworkURL: detail.artist.artworkURL,
            navigationTarget: .resource(kind: .artist, id: detail.artist.id, isLibrary: isArtistLib, providerID: "apple_music")
        )
        handleTracksQueueAction(tracks, origin: origin, intent: intent)
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
        guard var detail = artistStack.last else { return }
        let prevFav = detail.isFavorited
        let nextFav = !prevFav
        let artistRef = MediaResourceReference(
            kind: .artist,
            canonicalID: detail.artist.id,
            title: detail.artist.name,
            artworkURL: detail.artist.artworkURL
        )
        stateStore.seedKnownState(for: artistRef, favorite: prevFav)

        // Show pending visual state while preserving real rollback on failure
        detail.isFavorited = nextFav
        artistStack[artistStack.count - 1] = detail
        artistSidebarHeader.setFavorited(nextFav)

        let expectedArtistID = detail.artist.id
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let updated = try await self.stateStore.setFavorite(artistRef, enabled: nextFav)
                if let confirmed = updated.favorite.effectiveBool,
                   var latest = self.artistStack.last, latest.artist.id == expectedArtistID {
                    latest.isFavorited = confirmed
                    self.artistStack[self.artistStack.count - 1] = latest
                    self.artistSidebarHeader.setFavorited(confirmed)
                }
                self.queueDockView.showFeedback(nextFav ? "已收藏艺人「\(detail.artist.name)」" : "已取消收藏「\(detail.artist.name)」")
            } catch {
                if var latest = self.artistStack.last, latest.artist.id == expectedArtistID {
                    latest.isFavorited = prevFav
                    self.artistStack[self.artistStack.count - 1] = latest
                    self.artistSidebarHeader.setFavorited(prevFav)
                }
                AppLogger.shared.log(category: .error, level: .warn, message: "收藏艺人操作失败: \(error.localizedDescription)")
                self.queueDockView.showFeedback("收藏艺人失败: \(error.localizedDescription)")
            }
        }
    }

    private func showArtistMoreMenu(relativeTo anchor: NSView) {
        guard artistStack.last != nil else { return }
        let items: [GlassPopoverMenuItem] = [
            GlassPopoverMenuItem(
                id: "artist_station",
                title: "艺人电台",
                symbolName: "dot.radiowaves.left.and.right",
                action: { [weak self] in
                    self?.startArtistStation()
                }
            )
        ]
        let anchorInWindow = anchor.convert(anchor.bounds, to: nil)
        let anchorInScreen = anchor.window?.convertToScreen(anchorInWindow) ?? anchorInWindow
        GlassPopoverMenu.shared.present(items: items, relativeTo: anchorInScreen, parentWindow: anchor.window)
    }

    private func startArtistStation() {
        guard let detail = artistStack.last else { return }
        let ref = MediaArtistRef(
            id: detail.artist.id,
            name: detail.artist.name,
            isLibrary: currentDetailIsLibrary
        )
        startArtistStation(for: ref, fallbackArtworkURL: detail.artist.artworkURL)
    }

    private func startArtistStation(for artistRef: MediaArtistRef, fallbackArtworkURL: URL? = nil) {
        guard let searchService, let registry else { return }
        playIntentGeneration &+= 1
        let expectedIntentGen = playIntentGeneration
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let pid = await registry.browsingProviderID ?? .appleMusic
                guard let station = try await searchService.fetchArtistStation(providerID: pid, artistID: artistRef.id, scope: .catalog(region: nil)) else {
                    guard self.playIntentGeneration == expectedIntentGen, !Task.isCancelled else { return }
                    self.queueDockView.showFeedback("暂无可用的艺人电台")
                    return
                }
                guard self.playIntentGeneration == expectedIntentGen, !Task.isCancelled else { return }
                let artURL = station.artworkURL ?? fallbackArtworkURL
                let track = MusicTrack(
                    id: station.id,
                    title: station.name,
                    artistName: artistRef.name,
                    albumTitle: "艺人电台",
                    durationMs: 0,
                    artworkURL: artURL,
                    providerID: pid.rawValue,
                    providerTrackID: station.id
                )
                let seed = StationSeedResource(
                    kind: .artist,
                    id: artistRef.id,
                    title: artistRef.name,
                    isLibrary: artistRef.isLibrary,
                    providerID: pid.rawValue
                )
                let stationCtx = StationOriginContext(
                    stationID: station.id,
                    stationType: station.isLive ? .live : .algorithmic,
                    seedResource: seed,
                    sourceNavigationTarget: .resource(kind: .artist, id: artistRef.id, isLibrary: artistRef.isLibrary, providerID: pid.rawValue)
                )
                let origin = PlaybackOrigin(
                    kind: .station,
                    sourceID: station.id,
                    sourceTitle: station.name,
                    isLibrary: false,
                    providerID: pid.rawValue,
                    artworkURL: artURL,
                    navigationTarget: .resource(kind: .artist, id: artistRef.id, isLibrary: artistRef.isLibrary, providerID: pid.rawValue),
                    stationContext: stationCtx
                )
                let entry = QueueEntry(track: track, origin: origin)
                await self.queuePaginationLoader.cancel()
                guard self.playIntentGeneration == expectedIntentGen, !Task.isCancelled else { return }
                _ = try await self.coordinator.submitIntent(.replaceAndPlay, entries: [entry], startIndex: 0, kind: .station)
                self.queueDockView.playQueueAdditionAnimation(kind: .station, message: "正在收听电台：\(station.name)")
            } catch {
                guard self.playIntentGeneration == expectedIntentGen, !Task.isCancelled else { return }
                self.queueDockView.showFeedback("启动艺人电台失败: \(error.localizedDescription)")
                self.handlePlaybackError(error)
            }
        }
    }

    @MainActor
    private func handlePlaybackError(_ error: Error) {
        let isAlreadyLoggedIn = currentSessionSnapshot.sessionState == .authenticated
        if let coreErr = error as? CoreError {
            switch coreErr {
            case .userCredentialInvalid, .clientCredentialInvalid, .subscriptionRequired:
                if !isAlreadyLoggedIn {
                    AppLogger.shared.log(category: .playback, level: .warn, message: "播放需登录账号，已调出登录引导窗口")
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
        let cats = categoriesForTab(activeTabIndex)
        let activeCat = (activeCategoryIndex >= 0 && activeCategoryIndex < cats.count) ? cats[activeCategoryIndex] : nil
        let browseNav: OriginNavigationTarget? = activeCat.map {
            if activeTabIndex == 3 {
                return .librarySection(id: $0.id, title: $0.title)
            }
            return .browseSection(id: $0.id, title: $0.title)
        }

        if item.type == .radio {
            let stationCtx = StationOriginContext(
                stationID: item.id,
                stationType: .unknown,
                seedResource: nil,
                sourceNavigationTarget: browseNav
            )
            return PlaybackOrigin(
                kind: .station,
                sourceID: item.id,
                sourceTitle: item.title,
                isLibrary: false,
                artworkURL: item.artworkURL,
                navigationTarget: browseNav,
                stationContext: stationCtx
            )
        }
        if topBar.isArtistMode, let detail = artistStack.last {
            let isLib = currentDetailIsLibrary
            return PlaybackOrigin(
                kind: .artist,
                sourceID: detail.artist.id,
                sourceTitle: detail.artist.name,
                isLibrary: isLib,
                artworkURL: detail.artist.artworkURL,
                navigationTarget: .resource(kind: .artist, id: detail.artist.id, isLibrary: isLib, providerID: "apple_music")
            )
        }
        if topBar.isSearchMode {
            let query = topBar.currentSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
            let scope = topBar.currentSearchScope == 1 ? "library" : "catalog"
            let secID = (activeSearchSectionIndex >= 0 && activeSearchSectionIndex < searchSections.count) ? searchSections[activeSearchSectionIndex].id : nil
            let nav: OriginNavigationTarget? = query.isEmpty ? nil : .search(query: query, scope: scope, sectionID: secID)
            let title = query.isEmpty ? "搜索结果" : "搜索「\(query)」"
            return PlaybackOrigin(
                kind: .search,
                sourceID: query.isEmpty ? nil : query,
                sourceTitle: title,
                isLibrary: topBar.currentSearchScope == 1,
                artworkURL: item.artworkURL,
                navigationTarget: nav
            )
        }
        switch activeTabIndex {
        case 0:
            return PlaybackOrigin(
                kind: .forYou,
                sourceID: activeCat?.id,
                sourceTitle: activeCat?.title ?? "为你推荐",
                isLibrary: false,
                artworkURL: item.artworkURL,
                navigationTarget: browseNav
            )
        case 1:
            let isChart = (item.type == .chart)
            let nav = activeCat.map { isChart ? OriginNavigationTarget.chart(id: $0.id, title: $0.title, isLibrary: false) : .browseSection(id: $0.id, title: $0.title) }
            return PlaybackOrigin(
                kind: isChart ? .chart : .browse,
                sourceID: activeCat?.id,
                sourceTitle: activeCat?.title ?? "浏览",
                isLibrary: false,
                artworkURL: item.artworkURL,
                navigationTarget: nav
            )
        case 2:
            let isChart = (item.type == .chart)
            return PlaybackOrigin(
                kind: isChart ? .chart : .browse,
                sourceID: activeCat?.id,
                sourceTitle: activeCat?.title ?? "广播栏目",
                isLibrary: false,
                artworkURL: item.artworkURL,
                navigationTarget: browseNav
            )
        case 3:
            return PlaybackOrigin(
                kind: .library,
                sourceID: activeCat?.id,
                sourceTitle: activeCat?.title ?? "资料库",
                isLibrary: true,
                artworkURL: item.artworkURL,
                navigationTarget: browseNav
            )
        default:
            return .unknown
        }
    }

    private func playDetailTracks(_ tracks: [MusicTrack], startIndex: Int) {
        let origin = currentDetailOrigin
        let batchID = UUID()
        let entries = tracks.map { QueueEntry(track: $0, origin: origin, batchID: batchID) }
        let nextCursor = currentDetailNextCursor
        let totalCount = currentDetailTotalCount
        let loadingState: QueueLoadingState = nextCursor != nil
            ? .loading(loadedCount: entries.count, totalCount: totalCount)
            : .complete(totalCount: entries.count)

        playIntentGeneration &+= 1
        let expectedIntentGen = playIntentGeneration
        Task {
            await self.queuePaginationLoader.cancel()
            guard self.playIntentGeneration == expectedIntentGen else { return }
            do {
                try await self.coordinator.playEntries(entries, startIndex: startIndex, loadingState: loadingState, batchID: batchID)
                let safeStart = min(max(0, startIndex), entries.count - 1)
                let vKind: QueueAdditionVisualKind
                switch origin.kind {
                case .station: vKind = .station
                case .album where entries.count > 1: vKind = .album
                case .playlist where entries.count > 1: vKind = .playlist
                default: vKind = entries.count > 1 ? .multiSongs(count: entries.count) : .song
                }
                self.queueDockView.playQueueAdditionAnimation(kind: vKind, message: "已提交播放「\(entries[safeStart].track.title)」")
                if let nextCursor, let searchService = self.searchService, self.playIntentGeneration == expectedIntentGen {
                    let snap = await self.coordinator.currentStructuredQueueSnapshot()
                    await self.queuePaginationLoader.startBackgroundPagination(
                        coordinator: self.coordinator,
                        batchID: batchID,
                        expectedQueueID: snap.queueID,
                        expectedSessionScope: snap.sessionScope,
                        expectedDestructiveEpoch: snap.destructiveEpoch,
                        origin: origin,
                        initialLoadedCount: entries.count,
                        initialCursor: nextCursor,
                        totalCount: totalCount
                    ) { cursor in
                        let identity = ResourceIdentity(
                            providerID: cursor.providerID,
                            kind: origin.kind == .album ? .album : .playlist,
                            opaqueID: origin.sourceID ?? "",
                            scope: cursor.scope
                        )
                        return try await searchService.fetchCollectionTracks(identity: identity, cursor: cursor)
                    }
                }
            } catch {
                self.handlePlaybackError(error)
            }
        }
    }

    private func handleTracksQueueAction(_ tracks: [MusicTrack], origin: PlaybackOrigin, intent: MediaPlayIntent) {
        guard !tracks.isEmpty else { return }
        let entries = tracks.map { QueueEntry(track: $0, origin: origin) }
        let queueIntent = intent.queueInsertionIntent

        if queueIntent == .replaceAndPlay || queueIntent == .shuffleAndPlay || queueIntent == .interruptAndPlay {
            playIntentGeneration &+= 1
        }
        let expectedIntentGen = playIntentGeneration

        let prevChain = pendingQueueSubmissionChain
        let task = Task {
            let preSnap = await self.coordinator.currentStructuredQueueSnapshot()
            if queueIntent == .prepend || queueIntent == .append {
                await prevChain?.value
            }
            if (queueIntent == .replaceAndPlay || queueIntent == .shuffleAndPlay || queueIntent == .interruptAndPlay),
               self.playIntentGeneration != expectedIntentGen {
                return
            }
            if queueIntent == .replaceAndPlay || queueIntent == .shuffleAndPlay {
                await self.queuePaginationLoader.cancel()
                guard self.playIntentGeneration == expectedIntentGen else { return }
            }
            do {
                let res = try await self.coordinator.submitIntent(
                    queueIntent,
                    entries: entries,
                    startIndex: 0,
                    expectedQueueID: (queueIntent == .prepend || queueIntent == .append) ? preSnap.queueID : nil,
                    expectedDestructiveEpoch: (queueIntent == .prepend || queueIntent == .append) ? preSnap.destructiveEpoch : nil,
                    explicitShuffleMode: (queueIntent == .replaceAndPlay) ? false : nil
                )
                let visualKind: QueueAdditionVisualKind
                switch origin.kind {
                case .station: visualKind = .station
                case .album where tracks.count > 1: visualKind = .album
                case .playlist where tracks.count > 1: visualKind = .playlist
                default: visualKind = tracks.count > 1 ? .multiSongs(count: tracks.count) : .song
                }
                self.queueDockView.playQueueAdditionAnimation(kind: visualKind, message: res.message)
            } catch let editErr as QueueEditError {
                if case .remoteQueueRequiresSwitch(let stationTitle) = editErr {
                    self.promptRemoteStationSwitch(
                        stationTitle: stationTitle,
                        entries: entries,
                        intent: intent,
                        expectedQueueID: preSnap.queueID,
                        expectedDestructiveEpoch: preSnap.destructiveEpoch,
                        expectedSessionScope: preSnap.sessionScope
                    )
                } else {
                    self.queueDockView.showFeedback(editErr.localizedDescription)
                    self.handlePlaybackError(editErr)
                }
            } catch {
                self.queueDockView.showFeedback("队列操作失败: \(error.localizedDescription)")
                self.handlePlaybackError(error)
            }
        }
        if queueIntent == .prepend || queueIntent == .append {
            pendingQueueSubmissionChain = task
        }
    }

    private func handleCardQueueAction(_ item: MediaCardItem, intent: MediaPlayIntent) {
        switch item.type {
        case .song, .radio, .chart:
            if intent == .replaceAndPlay && item.type != .song {
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
            handleTracksQueueAction([track], origin: currentBrowseOrigin(for: item), intent: intent)

        case .album, .playlist:
            guard let searchService else { return }
            let isAlbum = (item.type == .album)
            let sourceID = isAlbum ? (item.albumID ?? item.id) : (item.playlistID ?? item.id)
            let isLib = item.isLibrary ?? false
            let pid = item.providerID ?? ProviderID.appleMusic.rawValue
            let scope: ResourceScope = item.scope ?? (isLib ? .library(accountID: "", region: nil) : .catalog(region: nil))
            let origin = PlaybackOrigin(
                kind: isAlbum ? .album : .playlist,
                sourceID: sourceID,
                sourceTitle: item.title,
                isLibrary: isLib,
                providerID: pid,
                scope: scope,
                artworkURL: item.artworkURL,
                navigationTarget: .resource(kind: isAlbum ? .album : .playlist, id: sourceID, isLibrary: isLib, providerID: pid)
            )
            let identity = ResourceIdentity(providerID: ProviderID(rawValue: pid), kind: isAlbum ? .album : .playlist, opaqueID: sourceID, scope: scope)
            executeCollectionQueueAction(
                actionKey: "\(sourceID)|\(intent.rawValue)",
                displayTitle: item.title,
                isLibrary: isLib,
                origin: origin,
                intent: intent,
                visualKind: isAlbum ? .album : .playlist,
                fetchFirstPage: {
                    try await searchService.fetchCollectionTracks(identity: identity, cursor: nil)
                },
                searchService: searchService
            )

        case .artist:
            guard let searchService else { return }
            let artistID = item.id
            let isLib = item.isLibrary ?? false
            let pid = item.providerID ?? ProviderID.appleMusic.rawValue
            let scope: ResourceScope = item.scope ?? (isLib ? .library(accountID: "", region: nil) : .catalog(region: nil))
            let origin = PlaybackOrigin(
                kind: .artist,
                sourceID: artistID,
                sourceTitle: item.title,
                isLibrary: isLib,
                providerID: pid,
                scope: scope,
                artworkURL: item.artworkURL,
                navigationTarget: .resource(kind: .artist, id: artistID, isLibrary: isLib, providerID: pid)
            )
            let queueIntent = intent.queueInsertionIntent
            let isReplaceOrInterrupt = (queueIntent == .replaceAndPlay || queueIntent == .shuffleAndPlay || queueIntent == .interruptAndPlay)
            if isReplaceOrInterrupt {
                playIntentGeneration &+= 1
            }
            let expectedIntentGen = playIntentGeneration
            Task { @MainActor [weak self] in
                guard let self else { return }
                do {
                    let identity = ResourceIdentity(providerID: ProviderID(rawValue: pid), kind: .artist, opaqueID: artistID, scope: scope)
                    let page = try await searchService.fetchCollectionTracks(identity: identity, cursor: nil)
                    let topSongs = page.tracks
                    if isReplaceOrInterrupt, self.playIntentGeneration != expectedIntentGen || Task.isCancelled {
                        return
                    }
                    guard !topSongs.isEmpty else {
                        self.queueDockView.showFeedback("该艺人暂无可播放热门歌曲")
                        return
                    }
                    self.handleTracksQueueAction(topSongs, origin: origin, intent: intent)
                } catch {
                    if isReplaceOrInterrupt, self.playIntentGeneration != expectedIntentGen || Task.isCancelled {
                        return
                    }
                    self.queueDockView.showFeedback("加载艺人热门歌曲失败: \(error.localizedDescription)")
                }
            }
        }
    }

    private func handleDetailTracksQueueAction(_ tracks: [MusicTrack], origin: PlaybackOrigin, intent: MediaPlayIntent) {
        guard !tracks.isEmpty else { return }
        if (origin.kind == .album || origin.kind == .playlist),
           let sourceID = origin.sourceID, !sourceID.isEmpty,
           currentDetailNextCursor != nil,
           let searchService {
            let firstPage = CollectionTrackPage(
                tracks: tracks,
                nextCursor: currentDetailNextCursor,
                totalCount: currentDetailTotalCount
            )
            let visualKind: QueueAdditionVisualKind = origin.kind == .album ? .album : .playlist
            executeCollectionQueueAction(
                actionKey: "\(sourceID)|\(intent.rawValue)",
                displayTitle: origin.displayTitle,
                isLibrary: currentDetailIsLibrary,
                origin: origin,
                intent: intent,
                visualKind: visualKind,
                preloadedFirstPage: firstPage,
                fetchFirstPage: { firstPage },
                searchService: searchService
            )
            return
        }
        handleTracksQueueAction(tracks, origin: origin, intent: intent)
    }

    private func executeCollectionQueueAction(
        actionKey: String,
        displayTitle: String,
        isLibrary: Bool,
        origin: PlaybackOrigin,
        intent: MediaPlayIntent,
        visualKind: QueueAdditionVisualKind,
        preloadedFirstPage: CollectionTrackPage? = nil,
        fetchFirstPage: @escaping @Sendable () async throws -> CollectionTrackPage,
        searchService: SearchCollectionService
    ) {
        guard !activeCollectionActionKeys.contains(actionKey) else {
            queueDockView.showFeedback("正在加载「\(displayTitle)」，请稍候…")
            return
        }
        activeCollectionActionKeys.insert(actionKey)

        let queueIntent = intent.queueInsertionIntent
        if queueIntent == .replaceAndPlay || queueIntent == .shuffleAndPlay || queueIntent == .interruptAndPlay {
            playIntentGeneration &+= 1
        }
        let expectedIntentGen = playIntentGeneration
        let prevChain = pendingQueueSubmissionChain

        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.activeCollectionActionKeys.remove(actionKey) }
            do {
                let preSnap = await self.coordinator.currentStructuredQueueSnapshot()
                let firstPage = try await (preloadedFirstPage != nil ? preloadedFirstPage! : fetchFirstPage())
                guard !firstPage.tracks.isEmpty else { return }

                if queueIntent == .replaceAndPlay {
                    guard self.playIntentGeneration == expectedIntentGen, !Task.isCancelled else { return }
                    await self.queuePaginationLoader.cancel()
                    guard self.playIntentGeneration == expectedIntentGen, !Task.isCancelled else { return }
                    let batchID = UUID()
                    let entries = firstPage.tracks.map { QueueEntry(track: $0, origin: origin, batchID: batchID) }
                    let loadingState: QueueLoadingState = firstPage.nextCursor != nil
                        ? .loading(loadedCount: entries.count, totalCount: firstPage.totalCount)
                        : .complete(totalCount: entries.count)
                    let res = try await self.coordinator.submitIntent(
                        .replaceAndPlay,
                        entries: entries,
                        startIndex: 0,
                        loadingState: loadingState,
                        batchID: batchID,
                        explicitShuffleMode: false
                    )
                    self.queueDockView.playQueueAdditionAnimation(kind: visualKind, message: res.message)
                    if let nextCursor = firstPage.nextCursor, self.playIntentGeneration == expectedIntentGen {
                        let snap = await self.coordinator.currentStructuredQueueSnapshot()
                        await self.queuePaginationLoader.startBackgroundPagination(
                            coordinator: self.coordinator,
                            batchID: batchID,
                            expectedQueueID: snap.queueID,
                            expectedSessionScope: snap.sessionScope,
                            expectedDestructiveEpoch: snap.destructiveEpoch,
                            origin: origin,
                            initialLoadedCount: entries.count,
                            initialCursor: nextCursor,
                            totalCount: firstPage.totalCount
                        ) { cursor in
                            let identity = ResourceIdentity(
                                providerID: cursor.providerID,
                                kind: origin.kind == .album ? .album : .playlist,
                                opaqueID: origin.sourceID ?? "",
                                scope: cursor.scope
                            )
                            return try await searchService.fetchCollectionTracks(identity: identity, cursor: cursor)
                        }
                    }
                } else {
                    var allTracks = firstPage.tracks
                    var nextCursor = firstPage.nextCursor
                    var visited: Set<String> = []
                    var pages = 1
                    var hitCircularCursor = false
                    while let cursor = nextCursor, pages < 100 {
                        guard visited.insert(cursor.opaqueToken).inserted else {
                            hitCircularCursor = true
                            break
                        }
                        pages += 1
                        let identity = ResourceIdentity(
                            providerID: cursor.providerID,
                            kind: origin.kind == .album ? .album : .playlist,
                            opaqueID: origin.sourceID ?? "",
                            scope: cursor.scope
                        )
                        let page = try await searchService.fetchCollectionTracks(identity: identity, cursor: cursor)
                        allTracks.append(contentsOf: page.tracks)
                        nextCursor = page.nextCursor
                    }
                    if hitCircularCursor || nextCursor != nil {
                        self.queueDockView.showFeedback("「\(displayTitle)」未能完整加载，无法执行该队列操作，请重试")
                        return
                    }
                    if queueIntent == .prepend || queueIntent == .append {
                        await prevChain?.value
                    } else if self.playIntentGeneration != expectedIntentGen || Task.isCancelled {
                        return
                    }
                    if queueIntent == .shuffleAndPlay {
                        guard self.playIntentGeneration == expectedIntentGen else { return }
                        await self.queuePaginationLoader.cancel()
                        guard self.playIntentGeneration == expectedIntentGen else { return }
                    }
                    let entries = allTracks.map { QueueEntry(track: $0, origin: origin) }
                    do {
                        let res = try await self.coordinator.submitIntent(
                            queueIntent,
                            entries: entries,
                            startIndex: 0,
                            expectedQueueID: (queueIntent == .prepend || queueIntent == .append) ? preSnap.queueID : nil,
                            expectedDestructiveEpoch: (queueIntent == .prepend || queueIntent == .append) ? preSnap.destructiveEpoch : nil
                        )
                        self.queueDockView.playQueueAdditionAnimation(kind: visualKind, message: res.message)
                    } catch let editErr as QueueEditError {
                        if case .remoteQueueRequiresSwitch(let stationTitle) = editErr {
                            self.promptRemoteStationSwitch(
                                stationTitle: stationTitle,
                                entries: entries,
                                intent: intent,
                                expectedQueueID: preSnap.queueID,
                                expectedDestructiveEpoch: preSnap.destructiveEpoch,
                                expectedSessionScope: preSnap.sessionScope
                            )
                        } else {
                            throw editErr
                        }
                    }
                }
            } catch let editErr as QueueEditError {
                if case .remoteQueueRequiresSwitch(let stationTitle) = editErr {
                    self.queueDockView.showFeedback("当前正在收听「\(stationTitle ?? "电台")」，请先结束电台后再操作队列")
                } else {
                    self.queueDockView.showFeedback(editErr.localizedDescription)
                    self.handlePlaybackError(editErr)
                }
            } catch {
                self.queueDockView.showFeedback("加载失败: \(error.localizedDescription)")
                self.handlePlaybackError(error)
            }
        }
        if queueIntent == .prepend || queueIntent == .append {
            pendingQueueSubmissionChain = task
        }
    }

    private func promptRemoteStationSwitch(
        stationTitle: String?,
        entries: [QueueEntry],
        intent: MediaPlayIntent,
        expectedQueueID: UUID,
        expectedDestructiveEpoch: UInt64,
        expectedSessionScope: String
    ) {
        guard !entries.isEmpty else { return }
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "结束电台并切换队列？"
        let name = (stationTitle?.isEmpty == false) ? "「\(stationTitle!)」" : "电台"
        let willAutoPlay = (intent == .replaceAndPlay || intent == .shuffleAndPlay || intent == .interruptAndPlay)
        alert.informativeText = willAutoPlay
            ? "当前正在收听\(name)，电台不支持直接插入或追加普通曲目。是否结束当前电台并立即播放所选歌曲？"
            : "当前正在收听\(name)，电台不支持直接插入或追加普通曲目。是否结束当前电台并建立本地待播队列（不自动播放）？"
        alert.addButton(withTitle: willAutoPlay ? "结束电台并立即播放" : "结束电台并建立队列")
        alert.addButton(withTitle: "继续收听电台")
        if alert.runModal() == .alertFirstButtonReturn {
            AppLogger.shared.log(category: .queue, level: .info, message: "用户确认结束电台并切换为本地队列 (autoPlay=\(willAutoPlay))")
            playIntentGeneration &+= 1
            let expectedIntentGen = playIntentGeneration
            Task {
                await self.queuePaginationLoader.cancel()
                guard self.playIntentGeneration == expectedIntentGen else { return }
                let liveSnap = await self.coordinator.currentStructuredQueueSnapshot()
                guard liveSnap.queueID == expectedQueueID,
                      liveSnap.destructiveEpoch == expectedDestructiveEpoch,
                      liveSnap.sessionScope == expectedSessionScope else {
                    self.queueDockView.showFeedback("电台会话已变化，已取消本次切换")
                    return
                }
                do {
                    if willAutoPlay {
                        let res = try await self.coordinator.submitIntent(
                            intent == .shuffleAndPlay ? .shuffleAndPlay : .replaceAndPlay,
                            entries: entries,
                            startIndex: 0,
                            explicitShuffleMode: intent == .replaceAndPlay ? false : nil
                        )
                        self.queueDockView.showFeedback(res.message ?? "已切换为本地队列")
                    } else {
                        let res = try await self.coordinator.switchRemoteToStagedLocal(
                            entries: entries,
                            expectedQueueID: expectedQueueID,
                            expectedDestructiveEpoch: expectedDestructiveEpoch,
                            expectedSessionScope: expectedSessionScope
                        )
                        self.queueDockView.showFeedback(res.message ?? "已建立本地待播队列")
                    }
                } catch {
                    self.queueDockView.showFeedback("切换队列失败: \(error.localizedDescription)")
                    self.handlePlaybackError(error)
                }
            }
        } else {
            AppLogger.shared.log(category: .queue, level: .info, message: "用户选择继续收听电台，保持当前电台播放")
        }
    }

    // MARK: - Unified Media Action Helpers (MA03–MA07)

    private func currentDetailIdentity() -> MediaDetailIdentity? {
        if topBar.isArtistMode, let detail = artistStack.last {
            return .artist(id: detail.artist.id)
        }
        guard contentView.isDetailVisible else {
            return nil
        }
        if let sourceID = currentDetailOrigin.sourceID, !sourceID.isEmpty {
            switch currentDetailOrigin.kind {
            case .album: return .album(id: sourceID)
            case .playlist: return .playlist(id: sourceID)
            case .artist: return .artist(id: sourceID)
            case .station: return .station(id: sourceID)
            default: return nil
            }
        }
        return nil
    }

    private func currentDetailResourceReference() -> MediaResourceReference {
        let sourceID = currentDetailOrigin.sourceID ?? ""
        let title = currentDetailOrigin.displayTitle
        switch currentDetailOrigin.kind {
        case .album:
            return MediaResourceReference(
                kind: .album,
                canonicalID: sourceID,
                title: title,
                artworkURL: currentDetailOrigin.artworkURL,
                isLibrary: currentDetailOrigin.isLibrary
            )
        case .playlist:
            let ownership = playlistOwnership(for: sourceID, isLibrary: currentDetailOrigin.isLibrary)
            return MediaResourceReference(
                kind: .playlist(ownership),
                canonicalID: sourceID,
                title: title,
                artworkURL: currentDetailOrigin.artworkURL,
                isLibrary: currentDetailOrigin.isLibrary
            )
        case .station:
            return MediaResourceReference(
                kind: .station,
                canonicalID: sourceID,
                title: title,
                artworkURL: currentDetailOrigin.artworkURL,
                isLibrary: false
            )
        default:
            return MediaResourceReference(
                kind: .album,
                canonicalID: sourceID,
                title: title,
                artworkURL: currentDetailOrigin.artworkURL,
                isLibrary: currentDetailOrigin.isLibrary
            )
        }
    }

    private func playlistOwnership(for id: String, isLibrary: Bool, explicit: PlaylistOwnership? = nil) -> PlaylistOwnership {
        if let explicit, explicit != .unknown {
            return explicit
        }
        return .unknown
    }

    private func resourceReference(for item: MediaCardItem) -> MediaResourceReference {
        let pid = item.providerID ?? ProviderID.unknown.rawValue
        switch item.type {
        case .song, .chart:
            if let track = item.track {
                return MediaResourceReference.from(track: track, fallbackAlbumID: item.albumID)
            }
            let isLib = item.isLibrary ?? false
            let catID = item.catalogID ?? (!isLib ? item.id : nil)
            let libID = item.libraryID ?? (isLib ? item.id : nil)
            return MediaResourceReference(
                kind: .song,
                providerID: pid,
                canonicalID: catID ?? libID ?? item.id,
                catalogID: catID,
                libraryID: libID,
                title: item.title,
                subtitle: item.subtitle,
                artworkURL: item.artworkURL,
                isLibrary: isLib,
                albumID: item.albumID
            )
        case .album:
            let aid = item.albumID ?? item.id
            let isLib = item.isLibrary ?? false
            let catID = item.catalogID ?? (!isLib ? aid : nil)
            let libID = item.libraryID ?? (isLib ? aid : nil)
            return MediaResourceReference(
                kind: .album,
                providerID: pid,
                canonicalID: catID ?? libID ?? aid,
                catalogID: catID,
                libraryID: libID,
                title: item.title,
                subtitle: item.subtitle,
                artworkURL: item.artworkURL,
                isLibrary: isLib
            )
        case .playlist:
            let plid = item.playlistID ?? item.id
            let isLib = item.isLibrary ?? false
            let catID = item.catalogID ?? (!isLib ? plid : nil)
            let libID = item.libraryID ?? (isLib ? plid : nil)
            let ownership = playlistOwnership(for: plid, isLibrary: isLib, explicit: item.playlistOwnership)
            return MediaResourceReference(
                kind: .playlist(ownership),
                providerID: pid,
                canonicalID: catID ?? libID ?? plid,
                catalogID: catID,
                libraryID: libID,
                title: item.title,
                subtitle: item.subtitle,
                artworkURL: item.artworkURL,
                isLibrary: isLib
            )
        case .artist:
            let isLib = item.isLibrary ?? false
            return MediaResourceReference(
                kind: .artist,
                providerID: pid,
                canonicalID: item.id,
                catalogID: isLib ? item.catalogID : item.id,
                libraryID: isLib ? item.id : item.libraryID,
                title: item.title,
                subtitle: item.subtitle,
                artworkURL: item.artworkURL,
                isLibrary: isLib
            )
        case .radio:
            return MediaResourceReference(
                kind: .station,
                canonicalID: item.id,
                title: item.title,
                subtitle: item.subtitle,
                artworkURL: item.artworkURL,
                isLibrary: false
            )
        }
    }

    private func resourceReference(for track: MusicTrack) -> MediaResourceReference {
        MediaResourceReference.from(
            track: track,
            fallbackAlbumID: currentDetailOrigin.kind == .album ? currentDetailOrigin.sourceID : nil
        )
    }

    private func refreshDetailActionButtons() {
        contentView.refreshOpenDetailPlayMenu()
    }

    public func currentFavoriteStatus(for track: MusicTrack) -> (normalizedKey: String, isFavorited: Bool?, isPending: Bool, isEnabled: Bool) {
        let resource = MediaResourceReference.from(track: track)
        let caps = mediaCapabilities(for: resource)
        let state = stateStore.state(for: resource)
        prefetchResourceStateIfNeeded(resource: resource, state: state, capabilities: caps)
        return (
            resource.normalizedKey,
            state.favorite.confirmedBool,
            state.favorite.isPending,
            caps.isAuthenticated && caps.canSetFavorite
        )
    }

    public func toggleFavoriteForTrack(_ track: MusicTrack) {
        let resource = MediaResourceReference.from(track: track)
        let caps = mediaCapabilities(for: resource)
        guard caps.isAuthenticated, caps.canSetFavorite else {
            queueDockView.showFeedback("请先登录 Apple Music 后再操作收藏")
            return
        }
        let state = stateStore.state(for: resource)
        if state.favorite.confirmedBool == true {
            dispatchMediaAction(.unfavorite(resource))
        } else {
            dispatchMediaAction(.favorite(resource))
        }
    }

    private func prefetchResourceStateIfNeeded(
        resource: MediaResourceReference,
        state: MediaResourceState,
        capabilities: MediaActionCapabilities
    ) {
        let needsLib = capabilities.canReadLibraryMembership && state.libraryMembership == .unknown
        let needsFav = capabilities.canReadFavorite && state.favorite == .unknown
        guard needsLib || needsFav else { return }
        Task { @MainActor [weak self] in
            _ = try? await self?.stateStore.refreshState(for: resource)
        }
    }

    private func mediaCapabilities(for resource: MediaResourceReference) -> MediaActionCapabilities {
        stateStore.capabilities(for: resource)
    }

    private func dispatchMediaAction(
        _ action: MediaAction,
        item: MediaCardItem? = nil,
        tracks: [MusicTrack] = [],
        origin: PlaybackOrigin = .unknown
    ) {
        switch action {
        case .play(let intent, _, _, _):
            if let item {
                handleCardQueueAction(item, intent: intent)
            } else if !tracks.isEmpty {
                if tracks.count > 1 {
                    handleDetailTracksQueueAction(tracks, origin: origin, intent: intent)
                } else {
                    handleTracksQueueAction(tracks, origin: origin, intent: intent)
                }
            }

        case .addToLibrary(let resource):
            Task { @MainActor [weak self] in
                guard let self else { return }
                do {
                    let outcome = try await self.stateStore.setLibraryMembershipWithOutcome(resource, inLibrary: true)
                    switch outcome {
                    case .confirmed(_, let msg):
                        self.queueDockView.showFeedback(msg ?? "已添加到资料库：\(resource.title)")
                    case .reconciledDifferent(_, let actual):
                        self.queueDockView.showFeedback(actual ? "资料库状态已同步：已在资料库" : "资料库添加未生效：\(resource.title)")
                    case .unknownOutcome(_, let msg):
                        self.queueDockView.showFeedback(msg)
                    case .superseded:
                        break
                    }
                } catch {
                    self.queueDockView.showFeedback("添加到资料库失败: \(error.localizedDescription)")
                }
            }

        case .removeFromLibrary(let resource):
            guard confirmRemoveFromLibrary(resource) else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                do {
                    let outcome = try await self.stateStore.setLibraryMembershipWithOutcome(resource, inLibrary: false)
                    switch outcome {
                    case .confirmed(_, let msg):
                        self.queueDockView.showFeedback(msg ?? "已从资料库移除：\(resource.title)")
                    case .reconciledDifferent(_, let actual):
                        self.queueDockView.showFeedback(actual ? "资料库移除未生效：\(resource.title)" : "资料库状态已同步：已移除")
                    case .unknownOutcome(_, let msg):
                        self.queueDockView.showFeedback(msg)
                    case .superseded:
                        break
                    }
                } catch {
                    self.queueDockView.showFeedback("从资料库移除失败: \(error.localizedDescription)")
                }
            }

        case .favorite(let resource):
            Task { @MainActor [weak self] in
                guard let self else { return }
                do {
                    let outcome = try await self.stateStore.setFavoriteWithOutcome(resource, enabled: true)
                    switch outcome {
                    case .confirmed(_, let msg):
                        self.queueDockView.showFeedback(msg ?? "已收藏：\(resource.title)")
                    case .reconciledDifferent(_, let actual):
                        self.queueDockView.showFeedback(actual ? "收藏状态已同步：已收藏" : "收藏未生效：\(resource.title)")
                    case .unknownOutcome(_, let msg):
                        self.queueDockView.showFeedback(msg)
                    case .superseded:
                        break
                    }
                } catch {
                    self.queueDockView.showFeedback("收藏失败: \(error.localizedDescription)")
                }
            }

        case .unfavorite(let resource):
            Task { @MainActor [weak self] in
                guard let self else { return }
                do {
                    let outcome = try await self.stateStore.setFavoriteWithOutcome(resource, enabled: false)
                    switch outcome {
                    case .confirmed(_, let msg):
                        self.queueDockView.showFeedback(msg ?? "已取消收藏：\(resource.title)")
                    case .reconciledDifferent(_, let actual):
                        self.queueDockView.showFeedback(actual ? "取消收藏未生效：\(resource.title)" : "收藏状态已同步：已取消收藏")
                    case .unknownOutcome(_, let msg):
                        self.queueDockView.showFeedback(msg)
                    case .superseded:
                        break
                    }
                } catch {
                    self.queueDockView.showFeedback("取消收藏失败: \(error.localizedDescription)")
                }
            }

        case .startSongStation(let songRef):
            guard let searchService else { return }
            let songID = songRef.catalogID ?? songRef.canonicalID
            let pid = ProviderID(rawValue: songRef.providerID)
            playIntentGeneration &+= 1
            let expectedIntentGen = playIntentGeneration
            Task { @MainActor [weak self] in
                guard let self else { return }
                do {
                    guard let station = try await searchService.fetchSongStation(providerID: pid, songID: songID, scope: .catalog(region: nil)) else {
                        guard self.playIntentGeneration == expectedIntentGen, !Task.isCancelled else { return }
                        self.queueDockView.showFeedback("暂无可用的歌曲电台")
                        return
                    }
                    guard self.playIntentGeneration == expectedIntentGen, !Task.isCancelled else { return }
                    let track = MusicTrack(
                        id: station.id,
                        title: station.name,
                        artistName: songRef.subtitle ?? songRef.title,
                        albumTitle: "歌曲电台",
                        durationMs: 0,
                        artworkURL: station.artworkURL ?? songRef.artworkURL,
                        providerID: pid.rawValue,
                        providerTrackID: station.id
                    )
                    let seed = StationSeedResource(
                        kind: .song,
                        id: songRef.canonicalID,
                        title: songRef.title,
                        isLibrary: songRef.isLibrary,
                        providerID: songRef.providerID,
                        albumID: songRef.albumID,
                        albumTitle: songRef.albumTitle
                    )
                    let seedNav: OriginNavigationTarget? = songRef.albumID.flatMap {
                        $0.isEmpty ? nil : .resource(kind: .album, id: $0, isLibrary: songRef.isLibrary, providerID: songRef.providerID)
                    }
                    let stationCtx = StationOriginContext(
                        stationID: station.id,
                        stationType: station.isLive ? .live : .algorithmic,
                        seedResource: seed,
                        sourceNavigationTarget: seedNav
                    )
                    let stationOrigin = PlaybackOrigin(
                        kind: .station,
                        sourceID: station.id,
                        sourceTitle: station.name,
                        isLibrary: false,
                        artworkURL: station.artworkURL ?? songRef.artworkURL,
                        navigationTarget: seedNav,
                        stationContext: stationCtx
                    )
                    let entry = QueueEntry(track: track, origin: stationOrigin)
                    await self.queuePaginationLoader.cancel()
                    guard self.playIntentGeneration == expectedIntentGen, !Task.isCancelled else { return }
                    _ = try await self.coordinator.submitIntent(.replaceAndPlay, entries: [entry], startIndex: 0, kind: .station)
                    self.queueDockView.playQueueAdditionAnimation(kind: .station, message: "正在收听歌曲电台：\(station.name)")
                } catch {
                    guard self.playIntentGeneration == expectedIntentGen, !Task.isCancelled else { return }
                    self.queueDockView.showFeedback("启动歌曲电台失败: \(error.localizedDescription)")
                    self.handlePlaybackError(error)
                }
            }

        case .startArtistStation(let artistRef):
            startArtistStation(for: artistRef)

        case .navigateToAlbum(let id, let title, let isLibrary):
            let origin = PlaybackOrigin(
                kind: .album,
                sourceID: id,
                sourceTitle: title,
                isLibrary: isLibrary,
                navigationTarget: .resource(kind: .album, id: id, isLibrary: isLibrary, providerID: "apple_music")
            )
            navigateToOriginPurely(origin, targetTrack: nil)

        case .navigateToPlaylist(let id, let title, let isLibrary):
            let origin = PlaybackOrigin(
                kind: .playlist,
                sourceID: id,
                sourceTitle: title,
                isLibrary: isLibrary,
                navigationTarget: .resource(kind: .playlist, id: id, isLibrary: isLibrary, providerID: "apple_music")
            )
            navigateToOriginPurely(origin, targetTrack: nil)

        case .navigateToArtist(let artistRef):
            navigationGeneration &+= 1
            locateTask?.cancel()
            openArtistPage(artistID: artistRef.id, isLibrary: artistRef.isLibrary, initialName: artistRef.name)

        case .navigateToSeedArtist(let artistRef):
            navigationGeneration &+= 1
            locateTask?.cancel()
            openArtistPage(artistID: artistRef.id, isLibrary: artistRef.isLibrary, initialName: artistRef.name)

        case .navigateToSeedAlbum(let id, let title, let isLibrary):
            let origin = PlaybackOrigin(
                kind: .album,
                sourceID: id,
                sourceTitle: title,
                isLibrary: isLibrary,
                navigationTarget: .resource(kind: .album, id: id, isLibrary: isLibrary, providerID: "apple_music")
            )
            navigateToOriginPurely(origin, targetTrack: nil)

        case .navigateToStationDetail(_, let title):
            queueDockView.showFeedback("电台「\(title)」暂无独立内部详情页")

        case .navigateToOrigin(let targetOrigin), .navigateToOriginConcise(let targetOrigin):
            navigateToOriginPurely(targetOrigin, targetTrack: nil)

        default:
            break
        }
    }

    private func exitArtistPagesRestoringOrigin() {
        while !artistStack.isEmpty {
            popArtistPage()
        }
        if topBar.isArtistMode {
            sidebar.setTopHeaderView(nil)
            topBar.setArtistMode(false, animated: false)
            layoutViews()
        }
        currentDetailOrigin = .unknown
    }

    private func navigateToTab(_ tab: Int, categoryIndex: Int) {
        exitArtistPagesRestoringOrigin()
        topBar.setSearchMode(false, animated: false)
        contentView.hideDetail()
        topBar.selectTab(index: tab)
        activeTabIndex = tab
        let categories = categoriesForTab(tab)
        let safeCat = categories.indices.contains(categoryIndex) ? categoryIndex : 0
        activeCategoryIndex = safeCat
        sidebar.setCategories(categories, selectedIndex: safeCat)
        layoutViews()
        loadCurrentCategory()
    }

    /// Pure internal navigation for Origin Capsule and Queue Context Menus.
    /// Never triggers playback, transport, queue writes, or platform mutations.
    public func navigateToOriginPurely(_ origin: PlaybackOrigin, targetTrack: MusicTrack? = nil) {
        navigationGeneration &+= 1
        let expectedNavGen = navigationGeneration
        locateTask?.cancel()

        guard let target = origin.resolvedNavigationTarget else {
            AppLogger.shared.log(category: .userAction, level: .warn, message: "纯内部来源跳转降级: 「\(origin.displayTitle)」(kind=\(origin.kind.rawValue)) 无可访问内部路由")
            queueDockView.showFeedback("该来源暂无可跳转的内部页面")
            return
        }
        AppLogger.shared.log(
            category: .userAction,
            level: .info,
            message: "执行纯内部来源跳转: 「\(origin.displayTitle)」(navGen=\(expectedNavGen), kind=\(origin.kind.rawValue), targetTrack=\(targetTrack?.title ?? "-"))"
        )

        switch target {
        case .resource(let kind, let id, let isLibrary, let providerID):
            let pid = ProviderID(rawValue: providerID)
            guard !pid.isUnknown else {
                queueDockView.showFeedback("未知平台来源，无法内部定位")
                return
            }
            if let registry {
                Task { await registry.setBrowsingProvider(pid) }
            }
            switch kind {
            case .album:
                exitArtistPagesRestoringOrigin()
                if currentDetailIdentity() == .album(id: id, providerID: pid, scope: origin.scope) {
                    if let targetTrack {
                        locateTrackInCurrentDetail(targetTrack, expectedNavGen: expectedNavGen)
                    }
                    return
                }
                let card = MediaCardItem(id: id, title: origin.displayTitle, subtitle: "", type: .album, artworkURL: origin.artworkURL, albumID: id, isLibrary: isLibrary, providerID: providerID, scope: origin.scope)
                handleItemClicked(card)
                if let targetTrack {
                    locateTask = Task { @MainActor [weak self] in
                        await self?.detailLoadTask?.value
                        guard let self, self.navigationGeneration == expectedNavGen, !Task.isCancelled else { return }
                        self.locateTrackInCurrentDetail(targetTrack, expectedNavGen: expectedNavGen)
                    }
                }

            case .playlist:
                exitArtistPagesRestoringOrigin()
                if currentDetailIdentity() == .playlist(id: id, providerID: pid, scope: origin.scope) {
                    if let targetTrack {
                        locateTrackInCurrentDetail(targetTrack, expectedNavGen: expectedNavGen)
                    }
                    return
                }
                let card = MediaCardItem(id: id, title: origin.displayTitle, subtitle: "", type: .playlist, artworkURL: origin.artworkURL, playlistID: id, isLibrary: isLibrary, providerID: providerID, scope: origin.scope)
                handleItemClicked(card)
                if let targetTrack {
                    locateTask = Task { @MainActor [weak self] in
                        await self?.detailLoadTask?.value
                        guard let self, self.navigationGeneration == expectedNavGen, !Task.isCancelled else { return }
                        self.locateTrackInCurrentDetail(targetTrack, expectedNavGen: expectedNavGen)
                    }
                }

            case .artist:
                if currentDetailIdentity() == .artist(id: id, providerID: pid, scope: origin.scope) {
                    return
                }
                openArtistPage(artistID: id, isLibrary: isLibrary, initialName: origin.displayTitle, artworkURL: origin.artworkURL)

            case .station, .song, .unknown:
                queueDockView.showFeedback("该来源暂无可跳转的内部页面")
            }

        case .librarySection(let id, let title):
            let cats = categoriesForTab(3)
            let idx = cats.firstIndex(where: { $0.id == id })
                ?? title.flatMap { t in cats.firstIndex(where: { $0.title == t }) }
                ?? 0
            navigateToTab(3, categoryIndex: idx)

        case .search(let query, let scope, _):
            artistStack.removeAll()
            topBar.setArtistMode(false, animated: false)
            contentView.hideDetail()
            let scopeIdx = (scope == "library") ? 1 : 0
            topBar.setSearchMode(true)
            topBar.setSearchScope(scopeIdx)
            topBar.setSearchQuery(query, submit: true)

        case .chart(let id, let title, _), .browseSection(let id, let title):
            for tab in [0, 1, 2] {
                let cats = categoriesForTab(tab)
                if let idx = cats.firstIndex(where: { $0.id == id }) {
                    navigateToTab(tab, categoryIndex: idx)
                    return
                }
            }
            let fallbackTitle = title ?? origin.sourceTitle
            if let fallbackTitle {
                for tab in [0, 1, 2] {
                    let cats = categoriesForTab(tab)
                    if let idx = cats.firstIndex(where: { $0.title == fallbackTitle }) {
                        navigateToTab(tab, categoryIndex: idx)
                        return
                    }
                }
            }
            queueDockView.showFeedback("未找到对应的浏览栏目")

        case .stationDetail(_, let title, _):
            queueDockView.showFeedback("电台「\(title ?? origin.displayTitle)」暂无独立内部详情页")

        case .unknown:
            queueDockView.showFeedback("该来源暂无可跳转的内部页面")
        }
    }

    private func locateTrackInCurrentDetail(_ track: MusicTrack, expectedNavGen: UInt64, maxExtraPages: Int = 3) {
        var ids: Set<String> = [track.id]
        if !track.providerTrackID.isEmpty { ids.insert(track.providerTrackID) }
        if let cid = track.catalogID, !cid.isEmpty { ids.insert(cid) }
        if let lid = track.libraryID, !lid.isEmpty { ids.insert(lid) }

        if contentView.highlightDetailTrack(matchingIDs: ids) {
            AppLogger.shared.log(category: .render, level: .info, message: "来源定位成功: 当前详情页已高亮「\(track.title)」")
            return
        }
        guard let nextCursor = currentDetailNextCursor else {
            AppLogger.shared.log(category: .render, level: .info, message: "来源定位结束: 「\(track.title)」已不在当前完整列表中")
            queueDockView.showFeedback("该曲目已不在当前列表中")
            return
        }
        guard let searchService else {
            queueDockView.showFeedback("尚未定位到该曲目")
            return
        }
        locateTask = Task { @MainActor [weak self] in
            guard let self else { return }
            var cursor: PageCursor? = nextCursor
            var pagesLoaded = 0
            var allTracks = self.contentView.currentDetailTracksList
            while let activeCursor = cursor, pagesLoaded < maxExtraPages {
                guard self.navigationGeneration == expectedNavGen, !Task.isCancelled else { return }
                pagesLoaded += 1
                let identity = ResourceIdentity(
                    providerID: activeCursor.providerID,
                    kind: self.currentDetailOrigin.kind == .album ? .album : .playlist,
                    opaqueID: self.currentDetailOrigin.sourceID ?? "",
                    scope: activeCursor.scope
                )
                guard let page = try? await searchService.fetchCollectionTracks(identity: identity, cursor: activeCursor) else {
                    break
                }
                guard self.navigationGeneration == expectedNavGen, !Task.isCancelled else { return }
                allTracks.append(contentsOf: page.tracks)
                cursor = page.nextCursor
                self.currentDetailNextCursor = cursor
                self.contentView.updateDetailTracks(allTracks)
                if self.contentView.highlightDetailTrack(matchingIDs: ids) {
                    return
                }
            }
            guard self.navigationGeneration == expectedNavGen, !Task.isCancelled else { return }
            if cursor == nil {
                AppLogger.shared.log(category: .render, level: .info, message: "来源定位结束: 已扫描全部页，「\(track.title)」不在当前列表中")
                self.queueDockView.showFeedback("该曲目已不在当前列表中")
            } else {
                AppLogger.shared.log(category: .render, level: .info, message: "来源定位达到有界上限 (\(maxExtraPages) 页)，尚未命中「\(track.title)」")
                self.queueDockView.showFeedback("尚未在前 \(maxExtraPages) 页中定位到该曲目")
            }
        }
    }

    private func confirmRemoveFromLibrary(_ resource: MediaResourceReference) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "确定从资料库移除「\(resource.title)」？"
        alert.informativeText = "此操作将从你的 Apple Music 资料库中移除该内容，且可能同步影响关联的下载或歌单内容。"
        alert.addButton(withTitle: "从资料库移除")
        alert.addButton(withTitle: "取消")
        return alert.runModal() == .alertFirstButtonReturn
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
