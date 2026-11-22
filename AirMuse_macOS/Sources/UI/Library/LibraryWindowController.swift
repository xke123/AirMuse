import AppKit
import Domain
import DesignSystem
import Playback
import Providers
import Infrastructure

// MARK: - LibraryWindowController

/// Controls the Library and Search window presentation, Liquid Glass tab navigation, and category content switching.
@MainActor
open class LibraryWindowController: NSWindowController {

    public var onToggleLog: (() -> Void)?
    public var onToggleAccount: (() -> Void)?

    private let panel = GlassPanel()
    private let topBar = LibraryTopBarView()
    private let sidebar = LibrarySidebarView()
    private let contentView = LibraryContentView()

    private let coordinator: PlaybackCoordinator
    private var appleMusicProvider: AppleMusicProvider?

    private var activeTabIndex: Int = 0
    private var activeCategoryIndex: Int = 0

    private var categoryLoadTask: Task<Void, Never>?
    private var searchTask: Task<Void, Never>?

    // Dynamic remote categories cached per tab index (0: Home recommendations, 1: Browse editorial, 2: Radio)
    private var loadedEditorialCategories: [Int: [AmpCategory]] = LibraryCacheStore.shared.load() ?? [:]

    public init(coordinator: PlaybackCoordinator, appleMusicProvider: AppleMusicProvider? = nil) {
        self.coordinator = coordinator
        self.appleMusicProvider = appleMusicProvider

        let initialRect = NSRect(
            x: 200 + DesignTokens.Metrics.mainPlayerWidth + 10,
            y: (NSScreen.main?.visibleFrame.maxY ?? 800) - DesignTokens.Metrics.libraryWindowHeight - 50,
            width: DesignTokens.Metrics.libraryWindowWidth,
            height: DesignTokens.Metrics.libraryWindowHeight
        )
        let window = LibraryWindow(contentRect: initialRect, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        super.init(window: window)

        setupUI(window)
        wireCallbacks()
    }

    public required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupUI(_ window: LibraryWindow) {
        window.contentView = panel

        let container = panel.contentView
        container.addSubview(topBar)
        container.addSubview(sidebar)
        container.addSubview(contentView)

        // Apple Music Web Player is attached to primary Player Window to ensure continuous background playback

        panel.onLayout = { [weak self] _ in
            self?.layoutViews()
        }

        layoutViews()
    }

    private func layoutViews() {
        guard window != nil else { return }
        let bounds = panel.contentView.bounds
        guard bounds.width > 20 && bounds.height > 20 else { return }

        let topBarH: CGFloat = 48
        let sidebarW: CGFloat = 126
        let padding: CGFloat = 6

        topBar.frame = NSRect(x: padding, y: padding, width: bounds.width - padding * 2, height: topBarH)

        let contentY = topBarH + padding * 2
        let contentH = max(10, bounds.height - contentY - padding)

        if topBar.isSearchMode {
            sidebar.isHidden = true
            contentView.frame = NSRect(x: padding, y: contentY, width: bounds.width - padding * 2, height: contentH)
        } else {
            sidebar.isHidden = false
            sidebar.frame = NSRect(x: padding, y: contentY, width: sidebarW, height: contentH)
            contentView.frame = NSRect(x: sidebarW + padding * 2, y: contentY, width: bounds.width - sidebarW - padding * 3, height: contentH)
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

        topBar.onSearchQuery = { [weak self] query, scope in
            let scopeName = (scope == 0) ? "Apple Music 全球曲库" : "个人资料库"
            AppLogger.shared.log(category: .userAction, level: .info, message: "用户提交搜索: \"\(query)\" (检索范围: \(scopeName))")
            self?.performSearch(query: query, scope: scope)
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
            self?.window?.orderOut(nil)
        }

        // Observe Apple Music Session changes (login / logout / token refreshed)
        AppleMusicSessionManager.shared.onStateChanged = { [weak self] state in
            Task { @MainActor [weak self] in
                guard let self else { return }
                AppLogger.shared.log(category: .auth, level: .info, message: "Apple Music 会话状态变更，重置缓存并刷新当前页面")
                if case .loggedOut = state {
                    LibraryCacheStore.shared.clear()
                }
                self.loadedEditorialCategories.removeAll()
                self.handleTabSelected(self.activeTabIndex)
            }
        }

        // Sidebar Events
        sidebar.onCategorySelected = { [weak self] categoryIndex in
            guard let self else { return }
            AppLogger.shared.log(category: .userAction, level: .info, message: "用户切换左侧专区: 索引 \(categoryIndex)")
            self.handleCategorySelected(categoryIndex)
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
            let index = allTracks.firstIndex(where: { $0.id == track.id }) ?? 0
            let queue = PlaybackQueue(items: allTracks.isEmpty ? [track] : allTracks, currentIndex: index)
            Task {
                do {
                    try await self.coordinator.playTrack(track, in: queue)
                } catch {
                    self.handlePlaybackError(error)
                }
            }
        }

        contentView.onPlayAll = { [weak self] tracks in
            guard let self, let first = tracks.first else { return }
            AppLogger.shared.log(category: .userAction, level: .info, message: "用户点击 [全部播放] (共 \(tracks.count) 首歌曲，首曲: \(first.title))")
            Task {
                do {
                    try await self.coordinator.playTrack(first, in: PlaybackQueue(items: tracks, currentIndex: 0))
                } catch {
                    self.handlePlaybackError(error)
                }
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
        guard let provider = appleMusicProvider else { return }
        Task { [weak self] in
            guard let self else { return }
            guard let recs = try? await provider.fetchRecommendations(), !recs.isEmpty else { return }
            await MainActor.run {
                guard self.activeTabIndex == 0 else { return }
                self.loadedEditorialCategories[0] = recs
                LibraryCacheStore.shared.save(categories: self.loadedEditorialCategories)
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
                LibraryCacheStore.shared.save(categories: self.loadedEditorialCategories)
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
            LibraryCacheStore.shared.save(categories: loadedEditorialCategories)
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

            guard !Task.isCancelled, self.activeTabIndex == targetTab, self.activeCategoryIndex == targetCategory else {
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
                self.contentView.displayItems([])
            } else if items.isEmpty {
                self.contentView.setTitle("\(currentCat.title) (暂无内容)")
                self.contentView.displayItems([])
            } else {
                self.contentView.displayItems(items)
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
                if !playlists.isEmpty {
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
                } else {
                    return self.sampleCardItems().filter { $0.type == .playlist }
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
                if !playlists.isEmpty {
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
                } else {
                    return self.sampleCardItems().filter { $0.type == .playlist }
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

    private func performSearch(query: String, scope: Int) {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        searchTask?.cancel()
        guard !trimmed.isEmpty else {
            handleTabSelected(activeTabIndex)
            return
        }

        layoutViews()
        let scopeName = scope == 1 ? "资料库" : "Apple Music"
        contentView.setTitle("搜索: \"\(trimmed)\" (\(scopeName))")
        contentView.setLoading(true)

        searchTask = Task { [weak self] in
            guard let self else { return }
            var items: [MediaCardItem] = []
            var searchError: Error?

            if let provider = self.appleMusicProvider {
                do {
                    let result: MusicSearchResult
                    if scope == 1 {
                        result = try await provider.searchLibrary(query: trimmed)
                    } else {
                        result = try await provider.searchCatalog(query: trimmed, limit: 30)
                    }
                    let songItems = result.tracks.map { tr in
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
                    let albumItems = result.albums.map { al in
                        MediaCardItem(
                            id: al.id,
                            title: al.title,
                            subtitle: "\(al.artistName) · \(al.trackCount) 首",
                            type: .album,
                            artworkURL: al.artworkURL,
                            albumID: al.id
                        )
                    }
                    let artistItems = result.artists.map { ar in
                        MediaCardItem(
                            id: ar.id,
                            title: ar.name,
                            subtitle: "艺人",
                            type: .artist,
                            artworkURL: ar.artworkURL
                        )
                    }
                    let playlistItems = result.playlists.map { pl in
                        MediaCardItem(
                            id: pl.id,
                            title: pl.name,
                            subtitle: pl.ownerName ?? "歌单",
                            type: .playlist,
                            artworkURL: pl.artworkURL,
                            playlistID: pl.id
                        )
                    }
                    items = songItems + albumItems + artistItems + playlistItems
                } catch is CancellationError {
                    return
                } catch {
                    searchError = error
                    AppLogger.shared.log(category: .error, level: .warn, message: "搜索失败: \(error.localizedDescription)")
                }
            }

            guard !Task.isCancelled else { return }

            self.contentView.setLoading(false)
            if let searchError {
                self.contentView.setTitle("搜索失败: \(searchError.localizedDescription)")
                self.contentView.displayItems([])
            } else if items.isEmpty {
                self.contentView.setTitle("未找到 \"\(trimmed)\" 的相关结果")
                self.contentView.displayItems([])
            } else {
                self.contentView.displayItems(items)
            }
        }
    }

    // MARK: - Item Click

    private func handleItemClicked(_ item: MediaCardItem) {
        switch item.type {
        case .album:
            let albumID = item.albumID ?? item.id
            let isLib = albumID.hasPrefix("l.") || albumID.hasPrefix("i.")
            contentView.showDetail(title: item.title, tracks: [])
            Task { [weak self] in
                guard let self else { return }
                var tracks: [MusicTrack] = []
                if let provider = self.appleMusicProvider {
                    tracks = (try? await provider.fetchAlbumTracks(albumID: albumID, isLibrary: isLib)) ?? []
                }
                if tracks.isEmpty {
                    tracks = self.sampleAlbumTracks(albumTitle: item.title)
                }
                await MainActor.run {
                    self.contentView.updateDetailTracks(tracks)
                }
            }

        case .playlist:
            let playlistID = item.playlistID ?? item.id
            let isLib = playlistID.hasPrefix("p.") || playlistID.hasPrefix("l.")
            contentView.showDetail(title: item.title, tracks: [])
            Task { [weak self] in
                guard let self else { return }
                var tracks: [MusicTrack] = []
                if let provider = self.appleMusicProvider {
                    tracks = (try? await provider.fetchPlaylistTracks(playlistID: playlistID, isLibrary: isLib)) ?? []
                }
                if tracks.isEmpty {
                    tracks = self.sampleAlbumTracks(albumTitle: item.title)
                }
                await MainActor.run {
                    self.contentView.updateDetailTracks(tracks)
                }
            }

        case .artist:
            let artistID = item.id
            let isLib = artistID.hasPrefix("l.") || artistID.hasPrefix("i.")
            contentView.showDetail(title: item.title, tracks: [])
            Task { [weak self] in
                guard let self else { return }
                var tracks: [MusicTrack] = []
                if let provider = self.appleMusicProvider {
                    tracks = (try? await provider.fetchArtistTopSongs(artistID: artistID, isLibrary: isLib)) ?? []
                }
                if tracks.isEmpty {
                    tracks = self.sampleAlbumTracks(albumTitle: item.title)
                }
                await MainActor.run {
                    self.contentView.updateDetailTracks(tracks)
                }
            }

        case .song, .radio, .chart:
            let allItems = contentView.displayedItems
            let tracks: [MusicTrack] = allItems.compactMap { it in
                it.track ?? MusicTrack(
                    id: it.id,
                    title: it.title,
                    artistName: it.subtitle,
                    albumTitle: "Apple Music",
                    durationMs: 0,
                    providerID: "apple_music",
                    providerTrackID: it.id
                )
            }
            let clickedTrack = item.track ?? MusicTrack(
                id: item.id,
                title: item.title,
                artistName: item.subtitle,
                albumTitle: "Apple Music",
                durationMs: 0,
                providerID: "apple_music",
                providerTrackID: item.id
            )
            let index = tracks.firstIndex(where: { $0.id == clickedTrack.id }) ?? 0
            let queue = PlaybackQueue(items: tracks.isEmpty ? [clickedTrack] : tracks, currentIndex: index)
            Task {
                do {
                    try await self.coordinator.playTrack(clickedTrack, in: queue)
                } catch {
                    self.handlePlaybackError(error)
                }
            }
        }
    }

    @MainActor
    private func handlePlaybackError(_ error: Error) {
        let isAlreadyLoggedIn = AppleMusicSessionManager.shared.webSessionState.isLoggedIn
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

    // MARK: - Utilities & Sample Fallbacks

    private func formatDuration(_ seconds: Double?) -> String {
        guard let seconds, seconds > 0 else { return "" }
        let total = Int(seconds)
        let m = total / 60
        let s = total % 60
        return String(format: "%02d:%02d", m, s)
    }

    private func sampleCardItems() -> [MediaCardItem] {
        [
            MediaCardItem(
                id: "1",
                title: "优质过客",
                subtitle: "AirMuse Ensemble",
                type: .chart,
                duration: "03:35",
                track: MusicTrack(
                    id: "1",
                    title: "优质过客",
                    artistName: "AirMuse Ensemble",
                    albumTitle: "AirMuse Sessions",
                    durationMs: 215_000,
                    providerID: "apple_music",
                    providerTrackID: "1"
                )
            ),
            MediaCardItem(
                id: "2",
                title: "Liquid Glass Dreams",
                subtitle: "Zion Echo · 10 首",
                type: .album,
                albumID: "sample_al_2"
            ),
            MediaCardItem(
                id: "3",
                title: "每日新发现",
                subtitle: "歌单 · 25 首",
                type: .playlist,
                playlistID: "sample_pl_3"
            ),
            MediaCardItem(
                id: "4",
                title: "Apple Music 1 经典电台",
                subtitle: "Apple Music Radio",
                type: .radio,
                track: MusicTrack(
                    id: "4",
                    title: "Apple Music 1 经典电台",
                    artistName: "Apple Music Radio",
                    albumTitle: "Radio",
                    durationMs: 0,
                    providerID: "apple_music",
                    providerTrackID: "4"
                )
            ),
            MediaCardItem(
                id: "5",
                title: "夜航星 (Night Navigation)",
                subtitle: "不才 · 三体原声",
                type: .song,
                duration: "04:12",
                track: MusicTrack(
                    id: "5",
                    title: "夜航星 (Night Navigation)",
                    artistName: "不才",
                    albumTitle: "三体原声",
                    durationMs: 252_000,
                    providerID: "apple_music",
                    providerTrackID: "5"
                )
            ),
            MediaCardItem(
                id: "6",
                title: "范特西 (Fantasy)",
                subtitle: "周杰伦 · 10 首",
                type: .album,
                albumID: "sample_al_6"
            )
        ]
    }

    private func sampleAlbumTracks(albumTitle: String) -> [MusicTrack] {
        [
            MusicTrack(id: "t1", title: "爱在西元前", artistName: "周杰伦", albumTitle: albumTitle, durationMs: 223000, providerID: "apple_music", providerTrackID: "t1"),
            MusicTrack(id: "t2", title: "爸我回来了", artistName: "周杰伦", albumTitle: albumTitle, durationMs: 235000, providerID: "apple_music", providerTrackID: "t2"),
            MusicTrack(id: "t3", title: "简单爱", artistName: "周杰伦", albumTitle: albumTitle, durationMs: 270000, providerID: "apple_music", providerTrackID: "t3"),
            MusicTrack(id: "t4", title: "开不了口", artistName: "周杰伦", albumTitle: albumTitle, durationMs: 284000, providerID: "apple_music", providerTrackID: "t4"),
            MusicTrack(id: "t5", title: "上海一九四三", artistName: "周杰伦", albumTitle: albumTitle, durationMs: 195000, providerID: "apple_music", providerTrackID: "t5"),
            MusicTrack(id: "t6", title: "安静", artistName: "周杰伦", albumTitle: albumTitle, durationMs: 334000, providerID: "apple_music", providerTrackID: "t6")
        ]
    }
}
