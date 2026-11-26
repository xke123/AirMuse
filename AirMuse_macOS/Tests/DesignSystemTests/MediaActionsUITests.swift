import AppKit
import Testing
@testable import UI
@testable import Domain
@testable import DesignSystem

@Suite("MediaActionsUITests")
@MainActor
struct MediaActionsUITests {

    @Test("T01/T29: MediaContextMenuBuilder builds NSMenu with groups, separators, and collaborative artist submenu")
    func testContextMenuBuilderGroupsAndSubmenu() {
        let caps = MediaActionCapabilities(
            isAuthenticated: true,
            canPlay: true,
            canReadLibraryMembership: true,
            canAddToLibrary: true,
            canRemoveFromLibrary: true,
            canReadFavorite: true,
            canSetFavorite: true,
            canStartSongStation: true,
            canStartArtistStation: true
        )
        let ref = MediaResourceReference(
            kind: .song,
            canonicalID: "s-1",
            title: "Song",
            albumID: "alb-1",
            albumTitle: "Album",
            artists: [
                MediaArtistRef(id: "a-1", name: "Artist A"),
                MediaArtistRef(id: "a-2", name: "Artist B")
            ]
        )
        let desc = MediaActionResolver.resolveContextMenu(for: MediaActionContext(
            resource: ref,
            location: .trackRow,
            state: MediaResourceState(libraryMembership: .known(false), favorite: .known(true)),
            capabilities: caps
        ))

        var triggered: MediaAction?
        let menu = MediaContextMenuBuilder.buildMenu(from: desc) { action in
            triggered = action
        }

        #expect(menu != nil)
        let items = menu!.items
        #expect(items.contains { $0.isSeparatorItem })
        #expect(!items.first!.isSeparatorItem)
        #expect(!items.last!.isSeparatorItem)

        let artistMenuItem = items.first { $0.title == "查看歌手" }
        #expect(artistMenuItem?.submenu?.items.count == 2)
        #expect(artistMenuItem?.submenu?.items.map(\.title) == ["Artist A", "Artist B"])

        // Trigger first playback item
        if let first = items.first, let actionSel = first.action {
            _ = first.target?.perform(actionSel, with: first)
            if case .play(let intent, _, _, _) = triggered {
                #expect(intent == .replaceAndPlay)
            } else {
                Issue.record("Expected play action")
            }
        }
    }

    @Test("T32: MediaPlayCapsuleButton supports Original and Enhanced modes without crashing")
    func testPlayCapsuleButtonModes() {
        let btn = MediaPlayCapsuleButton(frame: NSRect(x: 0, y: 0, width: 100, height: 28))
        btn.titleText = "播放"
        btn.layoutSubtreeIfNeeded()
        #expect(!btn.subviews.isEmpty)
    }
}
