import AppKit
import Domain

// MARK: - MediaMenuActionProxy

@MainActor
private final class MediaMenuActionProxy: NSObject {
    let handler: () -> Void

    init(_ handler: @escaping () -> Void) {
        self.handler = handler
    }

    @objc func trigger(_ sender: Any?) {
        handler()
    }
}

// MARK: - MediaContextMenuBuilder

/// Unified NSMenu builder driven solely by `MediaActionMenuDescriptor`.
/// Performs zero network requests during menu construction.
@MainActor
public enum MediaContextMenuBuilder {

    public static func buildMenu(
        from descriptor: MediaActionMenuDescriptor,
        onAction: @escaping @MainActor (MediaAction) -> Void
    ) -> NSMenu? {
        guard !descriptor.isEmpty else { return nil }
        let menu = NSMenu()
        menu.autoenablesItems = false

        for (sectionIndex, section) in descriptor.sections.enumerated() {
            guard !section.actions.isEmpty else { continue }
            if sectionIndex > 0 && !menu.items.isEmpty {
                menu.addItem(.separator())
            }
            for action in section.actions {
                menu.addItem(makeMenuItem(for: action, onAction: onAction))
            }
        }
        return menu.items.isEmpty ? nil : menu
    }

    private static func makeMenuItem(
        for action: MediaAction,
        onAction: @escaping @MainActor (MediaAction) -> Void
    ) -> NSMenuItem {
        if case .navigateToArtistsSubmenu(let artists) = action {
            let parentItem = NSMenuItem(title: action.title, action: nil, keyEquivalent: "")
            parentItem.image = NSImage(systemSymbolName: action.symbolName, accessibilityDescription: action.title)
            let submenu = NSMenu()
            submenu.autoenablesItems = false
            for artist in artists {
                let subAction = MediaAction.navigateToArtist(artist)
                let subItem = NSMenuItem(
                    title: artist.name,
                    action: #selector(MediaMenuActionProxy.trigger(_:)),
                    keyEquivalent: ""
                )
                let proxy = MediaMenuActionProxy { onAction(subAction) }
                subItem.target = proxy
                subItem.representedObject = proxy
                subItem.image = NSImage(systemSymbolName: "music.mic", accessibilityDescription: artist.name)
                submenu.addItem(subItem)
            }
            parentItem.submenu = submenu
            return parentItem
        }

        let item = NSMenuItem(
            title: action.title,
            action: action.isEnabled ? #selector(MediaMenuActionProxy.trigger(_:)) : nil,
            keyEquivalent: ""
        )
        item.isEnabled = action.isEnabled
        item.image = NSImage(systemSymbolName: action.symbolName, accessibilityDescription: action.title)

        if action.isEnabled {
            let proxy = MediaMenuActionProxy { onAction(action) }
            item.target = proxy
            item.representedObject = proxy
        }
        return item
    }
}
