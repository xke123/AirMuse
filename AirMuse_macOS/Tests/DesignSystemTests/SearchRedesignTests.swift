import AppKit
import Foundation
import Testing
@testable import Domain
@testable import DesignSystem
@testable import UI

@MainActor
@Suite("Search Redesign Tests (S01-S08)")
struct SearchRedesignTests {

    @Test("S01: SearchHistoryStore keeps max 5 deduplicated items, supports single delete and clearAll")
    func testSearchHistoryStore() {
        let suiteName = "AirMuse.SearchHistoryTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = SearchHistoryStore(defaults: defaults, storageKey: "test_history", maxCount: 5)
        #expect(store.items.isEmpty)

        store.add("  ")
        #expect(store.items.isEmpty)

        for q in ["Jay Chou", "Taylor Swift", "Radiohead", "Daft Punk", "Coldplay", "Oasis"] {
            store.add(q)
        }
        #expect(store.items == ["Oasis", "Coldplay", "Daft Punk", "Radiohead", "Taylor Swift"])

        // Case-insensitive dedup moves existing to top
        store.add("daft punk")
        #expect(store.items == ["daft punk", "Oasis", "Coldplay", "Radiohead", "Taylor Swift"])

        // Single delete
        store.remove("Coldplay")
        #expect(store.items == ["daft punk", "Oasis", "Radiohead", "Taylor Swift"])

        // Persisted across reload
        let reloaded = SearchHistoryStore(defaults: defaults, storageKey: "test_history", maxCount: 5)
        #expect(reloaded.items == ["daft punk", "Oasis", "Radiohead", "Taylor Swift"])

        // Clear all
        reloaded.clearAll()
        #expect(reloaded.items.isEmpty)
    }

    @Test("S02: SearchCategoryKind maps dynamic AMP keys and preserves SearchSection pagination cursor")
    func testDynamicSearchSectionModels() {
        #expect(SearchCategoryKind(ampKey: "top") == .topResults)
        #expect(SearchCategoryKind(ampKey: "top").displayTitle == "最佳结果")
        #expect(SearchCategoryKind(ampKey: "library-songs") == .songs)
        #expect(SearchCategoryKind(ampKey: "songs").displayTitle == "歌曲")
        #expect(SearchCategoryKind(ampKey: "playlists").displayTitle == "播放列表")
        #expect(SearchCategoryKind(ampKey: "stations") == .stations)
        #expect(SearchCategoryKind(ampKey: "stations").displayTitle == "广播单集")
        #expect(SearchCategoryKind(ampKey: "music-videos").displayTitle == "音乐视频")
        #expect(SearchCategoryKind(ampKey: "apple-curators").displayTitle == "类别")

        let station = MusicStation(id: "st.1", name: "Pop Hits Radio", providerID: "apple_music", providerStationID: "st.1")
        let section = SearchSection(
            id: "stations",
            kind: .stations,
            items: [.station(station)],
            nextURL: "/v1/catalog/cn/search?offset=25"
        )
        let result = MusicSearchResult(stations: [station], sections: [section])
        #expect(!result.isEmpty)
        #expect(result.sections.count == 1)
        #expect(result.sections[0].nextURL == "/v1/catalog/cn/search?offset=25")
    }

    @Test("S03 & S04: LibraryTopBarView defaults to Apple Music scope and SearchHistoryExpandView collapses cleanly")
    func testTopBarDefaultScopeAndExpandPopover() {
        let topBar = LibraryTopBarView(frame: NSRect(x: 0, y: 0, width: 480, height: 34))
        #expect(topBar.currentSearchScope == 0)
        topBar.setSearchMode(true, animated: false)
        #expect(topBar.isSearchMode == true)
        #expect(topBar.currentSearchScope == 0)

        let expand = SearchHistoryExpandView(frame: NSRect(x: 0, y: 0, width: 460, height: 180))
        expand.updateQueries(["周杰伦", "林俊杰"])
        #expect(expand.preferredHeight > 0)
        expand.setExpanded(true, animated: false)
        #expect(expand.isHidden == false)
        expand.setExpanded(false, animated: false)
        #expect(expand.isHidden == true)
    }

    @Test("S05 & S07: LibraryContentView supports 3-column browse grid and appendItems pagination")
    func testContentViewThreeColumnsAndAppend() {
        let content = LibraryContentView(frame: NSRect(x: 0, y: 0, width: 480, height: 500))
        content.setColumnCountOverride(3)
        let browseItems = (0..<6).map { i in
            MediaCardItem(id: "b_\(i)", title: "Cat \(i)", subtitle: "流派", type: .chart, browseCategoryID: "b_\(i)")
        }
        content.displayItems(browseItems, animated: false)
        #expect(content.columnCountOverride == 3)
        #expect(content.displayedItems.count == 6)

        content.setColumnCountOverride(nil)
        let page1 = (0..<25).map { i in
            MediaCardItem(id: "s_\(i)", title: "Song \(i)", subtitle: "Artist", type: .song)
        }
        content.displayItems(page1, animated: false)
        #expect(content.displayedItems.count == 25)

        let page2 = (25..<50).map { i in
            MediaCardItem(id: "s_\(i)", title: "Song \(i)", subtitle: "Artist", type: .song)
        }
        content.appendItems(page2)
        #expect(content.displayedItems.count == 50)
    }

    @Test("ArtistPage: MusicArtistDetail, LibraryTopBarView artist mode, and ArtistSidebarHeaderView layout")
    func testArtistPageComponents() {
        #expect(ArtistViewKind(viewKey: "top-songs").displayTitle == "热门歌曲")
        #expect(ArtistViewKind(viewKey: "full-albums").displayTitle == "专辑")
        #expect(ArtistViewKind(viewKey: "similar-artists").displayTitle == "相似艺人")

        let topBar = LibraryTopBarView(frame: NSRect(x: 0, y: 0, width: 480, height: 34))
        topBar.setArtistMode(true, artistName: "周杰伦", animated: false)
        #expect(topBar.isArtistMode == true)
        topBar.setArtistMode(false, animated: false)
        #expect(topBar.isArtistMode == false)

        let sidebar = LibrarySidebarView(frame: NSRect(x: 0, y: 0, width: 126, height: 500))
        let header = ArtistSidebarHeaderView(frame: NSRect(x: 0, y: 0, width: 126, height: ArtistSidebarHeaderView.preferredHeight))
        header.configure(artworkURL: nil, isFavorited: true)
        sidebar.setTopHeaderView(header, height: ArtistSidebarHeaderView.preferredHeight)
        sidebar.setCategories([SidebarCategory(id: "top-songs", title: "热门歌曲")], selectedIndex: 0)
        #expect(sidebar.categories.count == 1)
        sidebar.setTopHeaderView(nil)
    }
}
