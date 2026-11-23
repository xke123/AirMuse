import AppKit
import Domain
import DesignSystem

// MARK: - UnifiedStageController

/// Hosts Main/Mini Player, Lyrics, and Library modules inside a single transparent `PlayerWindow`
/// so all visible `NSGlassEffectView` panels share one `isKeyWindow` and render Liquid Glass in sync.
@MainActor
public final class UnifiedStageController {

    public enum Placement: String, Sendable {
        case top
        case bottom
        case left
        case right
    }

    private enum Keys {
        static let hasAnchor = "AirMuse_UnifiedAnchorSaved"
        static let anchorX = "AirMuse_UnifiedAnchorX"
        static let anchorY = "AirMuse_UnifiedAnchorY"
    }

    public let hostWindow: PlayerWindow
    private let stageRootView = NSView()

    private let playerCtrl: PlayerWindowController
    private let lyricsView: LyricsModuleView
    private let libraryCtrl: LibraryWindowController

    public private(set) var isLyricsVisible: Bool = true
    public private(set) var isLibraryVisible: Bool = true

    public var lyricsPlacement: Placement = .bottom
    public var libraryPlacement: Placement = .right

    /// Screen-space origin of the player anchor slot; remains fixed when lyrics/library expand or collapse.
    public private(set) var playerScreenOrigin: NSPoint
    private var isAdjustingFrame = false
    private var lastPlayerHeight: CGFloat = 0

    public init(
        playerCtrl: PlayerWindowController,
        lyricsView: LyricsModuleView,
        libraryCtrl: LibraryWindowController
    ) {
        self.playerCtrl = playerCtrl
        self.lyricsView = lyricsView
        self.libraryCtrl = libraryCtrl

        let s = GlassInteractionCoordinator.shared.uiScale
        let initialPlayerSize = playerCtrl.preferredPlayerSize(for: s)
        var initialOrigin = NSPoint(
            x: 200,
            y: (NSScreen.main?.visibleFrame.maxY ?? 800) - initialPlayerSize.height - 50
        )
        if UserDefaults.standard.bool(forKey: Keys.hasAnchor) {
            initialOrigin = NSPoint(
                x: UserDefaults.standard.double(forKey: Keys.anchorX),
                y: UserDefaults.standard.double(forKey: Keys.anchorY)
            )
        }
        self.playerScreenOrigin = Self.clampOriginToScreens(initialOrigin, size: initialPlayerSize)
        self.lastPlayerHeight = initialPlayerSize.height

        let window = PlayerWindow(contentRect: NSRect(origin: self.playerScreenOrigin, size: initialPlayerSize))
        window.hasShadow = true
        window.invalidateShadow()
        self.hostWindow = window

        setupStage()
        wireEvents()
        relayoutStage()
    }

    public var contentContainerView: NSView {
        stageRootView
    }

    private func setupStage() {
        stageRootView.wantsLayer = true
        stageRootView.layer?.masksToBounds = false
        stageRootView.menu = hostWindow.contentView?.menu
        hostWindow.contentView = stageRootView

        stageRootView.addSubview(playerCtrl.playerSlotView)
        stageRootView.addSubview(lyricsView)
        stageRootView.addSubview(libraryCtrl.moduleView)
    }

    private func wireEvents() {
        hostWindow.onDoubleClicked = { [weak self] in
            self?.playerCtrl.toggleMiniMode()
        }
        hostWindow.onToggleLog = { [weak self] in
            self?.playerCtrl.onToggleLog?()
        }
        hostWindow.doubleClickHitFilter = { [weak self] pt in
            self?.playerCtrl.playerSlotView.frame.contains(pt) ?? false
        }
        hostWindow.onToggleTopMost = { [weak self] in
            self?.playerCtrl.toggleTopMost()
        }

        playerCtrl.onTopMostDidChange = { [weak self] in
            self?.applyTopMostLevel()
        }

        playerCtrl.onModeDidTransition = { [weak self] in
            guard let self else { return }
            let s = GlassInteractionCoordinator.shared.uiScale
            let newH = self.playerCtrl.preferredPlayerSize(for: s).height
            // Keep the top edge (maxY) of the player pinned when switching Main <-> Mini
            self.playerScreenOrigin.y += (self.lastPlayerHeight - newH)
            self.lastPlayerHeight = newH
            if self.playerCtrl.isMiniMode && self.isLibraryVisible {
                self.chooseAdaptiveLibraryPlacementForMiniMode()
            } else if !self.playerCtrl.isMiniMode {
                self.libraryPlacement = .right
            }
            self.relayoutStage()
            self.hostWindow.refreshMenuStates()
        }

        lyricsView.onMiniModeDidChange = { [weak self] in
            self?.relayoutStage()
        }
        lyricsView.onClose = { [weak self] in
            self?.setLyricsVisible(false)
        }
        libraryCtrl.onClose = { [weak self] in
            self?.setLibraryVisible(false)
        }

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleWindowDidMove),
            name: NSWindow.didMoveNotification,
            object: hostWindow
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleScaleOrModeChange),
            name: GlassInteractionCoordinator.modeDidChangeNotification,
            object: nil
        )
    }

    public func showAndFocus() {
        relayoutStage()
        hostWindow.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    public func toggleLyrics() {
        setLyricsVisible(!isLyricsVisible)
    }

    public func setLyricsVisible(_ visible: Bool) {
        guard isLyricsVisible != visible else { return }
        isLyricsVisible = visible
        relayoutStage()
    }

    public func toggleLibrary() {
        setLibraryVisible(!isLibraryVisible)
    }

    public func setLibraryVisible(_ visible: Bool) {
        guard isLibraryVisible != visible else { return }
        isLibraryVisible = visible
        if visible && playerCtrl.isMiniMode {
            chooseAdaptiveLibraryPlacementForMiniMode()
        } else if visible && !playerCtrl.isMiniMode {
            libraryPlacement = .right
        }
        relayoutStage()
    }

    private func applyTopMostLevel() {
        hostWindow.level = playerCtrl.isTopMost ? .floating : .normal
        hostWindow.refreshMenuStates()
    }

    /// Chooses library placement around the player/mini bar in priority order: Top -> Bottom -> Right -> Left.
    private func chooseAdaptiveLibraryPlacementForMiniMode() {
        let s = GlassInteractionCoordinator.shared.uiScale
        let playerSize = playerCtrl.preferredPlayerSize(for: s)
        let libSize = libraryCtrl.preferredSize(for: s)
        let gap = 6.0 * s

        let vf = (hostWindow.screen ?? NSScreen.main)?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let pRect = NSRect(origin: playerScreenOrigin, size: playerSize)

        let topSpace = vf.maxY - pRect.maxY
        let bottomSpace = pRect.minY - vf.minY
        let rightSpace = vf.maxX - pRect.maxX
        let leftSpace = pRect.minX - vf.minX

        if topSpace >= libSize.height + gap {
            libraryPlacement = .top
        } else if bottomSpace >= libSize.height + gap {
            libraryPlacement = .bottom
        } else if rightSpace >= libSize.width + gap {
            libraryPlacement = .right
        } else if leftSpace >= libSize.width + gap {
            libraryPlacement = .left
        } else {
            // Pick the direction with maximum available space
            let candidates: [(Placement, CGFloat)] = [
                (.top, topSpace - libSize.height),
                (.bottom, bottomSpace - libSize.height),
                (.right, rightSpace - libSize.width),
                (.left, leftSpace - libSize.width),
            ]
            libraryPlacement = candidates.max(by: { $0.1 < $1.1 })?.0 ?? .bottom
        }
    }

    /// Recomputes module frames relative to `playerScreenOrigin` and resizes `hostWindow`
    /// while keeping the player module pinned at `playerScreenOrigin`.
    public func relayoutStage() {
        let s = GlassInteractionCoordinator.shared.uiScale
        let gap = 6.0 * s

        let playerSize = playerCtrl.preferredPlayerSize(for: s)
        let lyricsSize = lyricsView.preferredSize(for: s)
        let librarySize = libraryCtrl.preferredSize(for: s)

        let playerLocal = NSRect(origin: .zero, size: playerSize)
        var rects: [NSRect] = [playerLocal]

        var lyricsLocal = NSRect.zero
        if isLyricsVisible {
            lyricsLocal = place(size: lyricsSize, relativeTo: playerLocal, side: lyricsPlacement, gap: gap)
            rects.append(lyricsLocal)
        }

        var libraryLocal = NSRect.zero
        if isLibraryVisible {
            var anchor = playerLocal
            // If both lyrics and library share the same side, stack library outside lyrics
            if isLyricsVisible && libraryPlacement == lyricsPlacement {
                anchor = lyricsLocal
            }
            libraryLocal = place(size: librarySize, relativeTo: anchor, side: libraryPlacement, gap: gap)
            rects.append(libraryLocal)
        }

        let unionRect = rects.dropFirst().reduce(rects[0]) { $0.union($1) }
        let shiftX = -unionRect.minX
        let shiftY = -unionRect.minY

        let finalPlayerFrame = playerLocal.offsetBy(dx: shiftX, dy: shiftY)
        let finalLyricsFrame = lyricsLocal.offsetBy(dx: shiftX, dy: shiftY)
        let finalLibraryFrame = libraryLocal.offsetBy(dx: shiftX, dy: shiftY)

        let newHostOrigin = NSPoint(
            x: playerScreenOrigin.x + unionRect.minX,
            y: playerScreenOrigin.y + unionRect.minY
        )
        let hostFrame = NSRect(origin: newHostOrigin, size: unionRect.size)

        isAdjustingFrame = true
        hostWindow.setFrame(hostFrame, display: true, animate: false)
        stageRootView.frame = NSRect(origin: .zero, size: unionRect.size)

        playerCtrl.layoutSlot(frame: finalPlayerFrame)

        lyricsView.isHidden = !isLyricsVisible
        if isLyricsVisible {
            lyricsView.frame = finalLyricsFrame
            lyricsView.needsLayout = true
            lyricsView.refreshGlass()
        }

        libraryCtrl.moduleView.isHidden = !isLibraryVisible
        if isLibraryVisible {
            libraryCtrl.moduleView.frame = finalLibraryFrame
            libraryCtrl.moduleView.needsLayout = true
            libraryCtrl.moduleView.refreshGlassSurface()
        }

        hostWindow.invalidateShadow()
        isAdjustingFrame = false
    }

    private func place(size: NSSize, relativeTo anchor: NSRect, side: Placement, gap: CGFloat) -> NSRect {
        switch side {
        case .bottom:
            return NSRect(x: anchor.minX, y: anchor.minY - gap - size.height, width: size.width, height: size.height)
        case .top:
            return NSRect(x: anchor.minX, y: anchor.maxY + gap, width: size.width, height: size.height)
        case .right:
            return NSRect(x: anchor.maxX + gap, y: anchor.maxY - size.height, width: size.width, height: size.height)
        case .left:
            return NSRect(x: anchor.minX - gap - size.width, y: anchor.maxY - size.height, width: size.width, height: size.height)
        }
    }

    @objc private func handleWindowDidMove() {
        guard !isAdjustingFrame else { return }
        let slotOrigin = playerCtrl.playerSlotView.frame.origin
        playerScreenOrigin = NSPoint(
            x: hostWindow.frame.minX + slotOrigin.x,
            y: hostWindow.frame.minY + slotOrigin.y
        )
        UserDefaults.standard.set(true, forKey: Keys.hasAnchor)
        UserDefaults.standard.set(Double(playerScreenOrigin.x), forKey: Keys.anchorX)
        UserDefaults.standard.set(Double(playerScreenOrigin.y), forKey: Keys.anchorY)
    }

    @objc private func handleScaleOrModeChange() {
        let s = GlassInteractionCoordinator.shared.uiScale
        let newSize = playerCtrl.preferredPlayerSize(for: s)
        playerScreenOrigin.y += (lastPlayerHeight - newSize.height)
        lastPlayerHeight = newSize.height
        playerScreenOrigin = Self.clampOriginToScreens(playerScreenOrigin, size: newSize)
        relayoutStage()
        hostWindow.refreshMenuStates()
    }

    private static func clampOriginToScreens(_ origin: NSPoint, size: NSSize) -> NSPoint {
        for screen in NSScreen.screens {
            let vf = screen.visibleFrame
            if vf.intersects(NSRect(origin: origin, size: size)) {
                let x = min(max(origin.x, vf.minX), vf.maxX - size.width)
                let y = min(max(origin.y, vf.minY), vf.maxY - size.height)
                return NSPoint(x: x, y: y)
            }
        }
        if let mainVF = NSScreen.main?.visibleFrame {
            let x = min(max(origin.x, mainVF.minX), mainVF.maxX - size.width)
            let y = min(max(origin.y, mainVF.minY), mainVF.maxY - size.height)
            return NSPoint(x: x, y: y)
        }
        return origin
    }
}
