import Foundation
import Testing
@testable import Domain
@testable import Providers

@Suite("PD03: AppleMusicAdapter & Cursor Isolation Tests")
struct AppleMusicAdapterTests {

    @Test("Descriptor exposes static metadata without creating WebKit or network state")
    func testDescriptorStaticMetadata() {
        let desc = AppleMusicAdapterFactory.defaultDescriptor
        #expect(desc.providerID == .appleMusic)
        #expect(desc.isAvailableInProduction)
        #expect(desc.supportedBrowseTabs.map(\.id) == ["home", "browse", "radio", "library"])
    }

    @Test("AmpCategory mapping preserves opaque PageCursor and rejects cross-provider/scope reuse")
    func testAmpCategoryAndCursorMapping() async {
        let url = URL(string: "https://amp-api.music.apple.com/v1/catalog/cn/albums/123/tracks?offset=100")!
        let cat = AmpCategory(
            id: "cat-1",
            title: "精选推荐",
            items: [
                AmpCategoryItem(id: "alb-1", title: "Album", subtitle: "Artist", type: "album", isLibrary: false)
            ],
            nextURL: url
        )
        let mapped = AppleMusicAdapter.mapCategory(cat, scope: .catalog(region: "cn"), routeFingerprint: "tab:home")
        #expect(mapped.items.count == 1)
        #expect(mapped.items[0].identity.providerID == .appleMusic)
        #expect(mapped.items[0].identity.kind == .album)
        #expect(mapped.nextCursor?.providerID == .appleMusic)
        #expect(mapped.nextCursor?.matches(
            providerID: .appleMusic,
            scope: .catalog(region: "cn"),
            routeFingerprint: "tab:home:cat-1"
        ) == true)
        #expect(mapped.nextCursor?.matches(
            providerID: ProviderID("fixture"),
            scope: .catalog(region: "cn"),
            routeFingerprint: "tab:home:cat-1"
        ) == false)
    }

    @Test("Personal recommendation playlists with p. prefix map to library scope even when item.isLibrary is false")
    func testLibraryPrefixMapsToLibraryScope() {
        let item = AmpCategoryItem(
            id: "p.QvDQV35hJRZvL5",
            title: "爱不释耳",
            subtitle: "Apple Music",
            type: "playlists",
            isLibrary: false
        )
        let card = AppleMusicAdapter.mapItem(item, scope: .catalog(region: nil))
        #expect(card.identity.kind == .playlist)
        #expect(card.identity.scope.isLibrary)
        #expect(card.identity.opaqueID == "p.QvDQV35hJRZvL5")
    }
}
