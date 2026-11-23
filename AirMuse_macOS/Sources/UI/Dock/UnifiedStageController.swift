import AppKit
import Domain
import DesignSystem

// MARK: - StageRootView

/// Transparent host root view that passes clicks through empty space between separated panels.
@MainActor
private final class StageRootView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? {
        for subview in subviews.reversed() where !subview.isHidden {
            if let hit = subview.hitTest(point) {
                return hit
            }
        }
        return nil
    }
}

// MARK: - ModuleTopBarDragHandle

/// Transparent drag handle placed over a module's top glass bar (`capH`).
/// Lets buttons underneath (`GlassButton` / `NSControl`) still receive clicks,
/// while dragging empty glass bar space moves only that single module.
@MainActor
private final class ModuleTopBarDragHandle: NSView {

    var onDragBegan: (() -> Void)?
    var onDragChanged: ((NSPoint) -> Void)?
    var onDragEnded: (() -> Void)?

    private var dragStartMouse: NSPoint = .zero
    private var isDragging = false

    override var mouseDownCanMoveWindow: Bool { false }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let localPt = convert(point, from: superview)
        guard bounds.contains(localPt), let host = superview else { return nil }
        let hostPt = convert(localPt, to: host)
        if containsInteractiveControl(in: host, at: hostPt) {
            return nil
        }
        return self
    }

    private func containsInteractiveControl(in view: NSView, at point: NSPoint) -> Bool {
        for sub in view.subviews where !sub.isHidden && sub !== self {
            let subPt = sub.convert(point, from: view)
            guard sub.bounds.contains(subPt) else { continue }
            if sub is NSControl || sub is GlassButton {
                return true
            }
            if containsInteractiveControl(in: sub, at: subPt) {
                return true
            }
        }
        return false
    }

    override func mouseDown(with event: NSEvent) {
        dragStartMouse = NSEvent.mouseLocation
        isDragging = true
        onDragBegan?()
    }

    override func mouseDragged(with event: NSEvent) {
        guard isDragging else { return }
        let cur = NSEvent.mouseLocation
        let delta = NSPoint(x: cur.x - dragStartMouse.x, y: cur.y - dragStartMouse.y)
        onDragChanged?(delta)
    }

    override func mouseUp(with event: NSEvent) {
        guard isDragging else { return }
        isDragging = false
        onDragEnded?()
    }
}

// MARK: - UnifiedStageController

/// Hosts Main/Mini Player, Lyrics, and Library modules inside a single transparent `PlayerWindow`
/// so all visible `NSGlassEffectView` panels share one `isKeyWindow` and render Liquid Glass in sync.
///
/// - Dragging the Main Player's top glass bar moves all docked panels together.
/// - Dragging Lyrics or Library's top glass bar moves only that panel; on mouseUp it snaps
///   to the nearest valid edge of the remaining panels (no floating detached state).
@MainActor
public final class UnifiedStageController {

    public enum Placement: String, Sendable {
        case top
        case bottom
        case left
        case right
    }

    private enum ModuleKind {
        case lyrics
        case library
    }

    private enum Keys {
        static let hasAnchor = "AirMuse_UnifiedAnchorSaved"
        static let anchorX = "AirMuse_UnifiedAnchorX"
        static let anchorY = "AirMuse_UnifiedAnchorY"
    }

    public let hostWindow: PlayerWindow
    private let stageRootView = StageRootView()

    private let playerCtrl: PlayerWindowController
    private let lyricsView: LyricsModuleView
    private let libraryCtrl: LibraryWindowController

    private let lyricsDragHandle = ModuleTopBarDragHandle()
    private let libraryDragHandle = ModuleTopBarDragHandle()

    public private(set) var isLyricsVisible: Bool = true
    public private(set) var isLibraryVisible: Bool = true

    public var lyricsPlacement: Placement = .bottom
    public var libraryPlacement: Placement = .right

    /// Screen-space origin of the player anchor slot; remains fixed when lyrics/library move/expand.
    public private(set) var playerScreenOrigin: NSPoint

    /// Offsets relative to `playerScreenOrigin` for custom snapped positions (nil = use default placement).
    private var customLyricsOffset: NSPoint?
    private var customLibraryOffset: NSPoint?

    /// Transient drag state for single-panel dragging.
    private var activeDragModule: ModuleKind?
    private var dragStartOrigin: NSPoint = .zero
    private var liveDragScreenOrigin: NSPoint = .zero

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

        lyricsView.addSubview(lyricsDragHandle, positioned: .above, relativeTo: nil)
        libraryCtrl.moduleView.addSubview(libraryDragHandle, positioned: .above, relativeTo: nil)
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
            self.playerScreenOrigin.y += (self.lastPlayerHeight - newH)
            self.lastPlayerHeight = newH
            self.customLyricsOffset = nil
            self.customLibraryOffset = nil
            if self.playerCtrl.isMiniMode && self.isLibraryVisible {
                self.chooseAdaptiveLibraryPlacementForMiniMode()
            } else if !self.playerCtrl.isMiniMode {
                self.libraryPlacement = .right
            }
            self.relayoutStage()
            self.hostWindow.refreshMenuStates()
        }

        lyricsView.onMiniModeDidChange = { [weak self] in
            guard let self else { return }
            self.relayoutStage()
            if self.customLyricsOffset != nil {
                self.resnapModuleIfNeeded(.lyrics)
            }
            if self.customLibraryOffset != nil {
                self.resnapModuleIfNeeded(.library)
            }
        }
        lyricsView.onClose = { [weak self] in
            self?.setLyricsVisible(false)
        }
        libraryCtrl.onClose = { [weak self] in
            self?.setLibraryVisible(false)
        }

        wireDragHandle(lyricsDragHandle, for: .lyrics)
        wireDragHandle(libraryDragHandle, for: .library)

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

    private func wireDragHandle(_ handle: ModuleTopBarDragHandle, for kind: ModuleKind) {
        handle.onDragBegan = { [weak self] in
            guard let self else { return }
            self.activeDragModule = kind
            let currentRect = self.screenRect(for: kind)
            self.dragStartOrigin = currentRect.origin
            self.liveDragScreenOrigin = currentRect.origin
        }
        handle.onDragChanged = { [weak self] delta in
            guard let self, self.activeDragModule == kind else { return }
            self.liveDragScreenOrigin = NSPoint(
                x: self.dragStartOrigin.x + delta.x,
                y: self.dragStartOrigin.y + delta.y
            )
            self.relayoutStage()
        }
        handle.onDragEnded = { [weak self] in
            guard let self, self.activeDragModule == kind else { return }
            let droppedOrigin = self.liveDragScreenOrigin
            self.activeDragModule = nil
            self.snapDroppedModule(kind, droppedOrigin: droppedOrigin)
        }
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
        if !visible { customLyricsOffset = nil }
        relayoutStage()
    }

    public func toggleLibrary() {
        setLibraryVisible(!isLibraryVisible)
    }

    public func setLibraryVisible(_ visible: Bool) {
        guard isLibraryVisible != visible else { return }
        isLibraryVisible = visible
        if !visible { customLibraryOffset = nil }
        if visible && playerCtrl.isMiniMode {
            chooseAdaptiveLibraryPlacementForMiniMode()
        } else if visible && !playerCtrl.isMiniMode && customLibraryOffset == nil {
            libraryPlacement = .right
        }
        relayoutStage()
    }

    private func applyTopMostLevel() {
        hostWindow.level = playerCtrl.isTopMost ? .floating : .normal
        hostWindow.refreshMenuStates()
    }

    private func screenRect(for kind: ModuleKind) -> NSRect {
        let view: NSView = (kind == .lyrics) ? lyricsView : libraryCtrl.moduleView
        let f = view.frame
        return NSRect(
            x: hostWindow.frame.minX + f.minX,
            y: hostWindow.frame.minY + f.minY,
            width: f.width,
            height: f.height
        )
    }

    /// Snaps the dragged module to the nearest valid edge of the remaining visible modules (gap = 0, no overlap).
    private func snapDroppedModule(_ kind: ModuleKind, droppedOrigin: NSPoint) {
        let s = GlassInteractionCoordinator.shared.uiScale
        let (playerSize, lyricsSize, librarySize) = currentModuleSizes(scale: s)
        let movedSize = (kind == .lyrics) ? lyricsSize : librarySize
        let droppedRect = NSRect(origin: droppedOrigin, size: movedSize)

        let playerScreenRect = NSRect(origin: playerScreenOrigin, size: playerSize)
        var targets: [NSRect] = [playerScreenRect]
        var otherRect: NSRect? = nil

        if kind == .lyrics && isLibraryVisible {
            let r = screenRect(for: .library)
            targets.append(r)
            otherRect = r
        } else if kind == .library && isLyricsVisible {
            let r = screenRect(for: .lyrics)
            targets.append(r)
            otherRect = r
        }

        let alignThreshold = 24.0 * s
        var bestRect: NSRect?
        var bestScore = CGFloat.greatestFiniteMagnitude

        for target in targets {
            let candidates = candidateSnapRects(
                for: movedSize,
                droppedRect: droppedRect,
                against: target,
                alignThreshold: alignThreshold
            )
            for cand in candidates {
                // Reject if overlapping player or the other module
                if cand.insetBy(dx: 1.0, dy: 1.0).intersects(playerScreenRect) { continue }
                if let other = otherRect, cand.insetBy(dx: 1.0, dy: 1.0).intersects(other) { continue }

                let dx = cand.midX - droppedRect.midX
                let dy = cand.midY - droppedRect.midY
                let dist = hypot(dx, dy)
                if dist < bestScore {
                    bestScore = dist
                    bestRect = cand
                }
            }
        }

        if let snapped = bestRect {
            let offset = NSPoint(x: snapped.minX - playerScreenOrigin.x, y: snapped.minY - playerScreenOrigin.y)
            if kind == .lyrics {
                customLyricsOffset = offset
            } else {
                customLibraryOffset = offset
            }
        }
        relayoutStage()
    }

    private func resnapModuleIfNeeded(_ kind: ModuleKind) {
        let cur = screenRect(for: kind)
        snapDroppedModule(kind, droppedOrigin: cur.origin)
    }

    /// Generates 4 edge-touching candidates (left, right, top, bottom of `target`),
    /// each with edge-alignment snapping (top/bottom/left/right) and clamping so edges actually touch.
    private func candidateSnapRects(
        for size: NSSize,
        droppedRect: NSRect,
        against target: NSRect,
        alignThreshold: CGFloat
    ) -> [NSRect] {
        var results: [NSRect] = []

        // 1. Left & Right of target -> align Y
        let minTouchY = target.minY - size.height + 20.0
        let maxTouchY = target.maxY - 20.0
        var snappedY = min(max(droppedRect.minY, minTouchY), maxTouchY)
        if abs(droppedRect.maxY - target.maxY) <= alignThreshold {
            snappedY = target.maxY - size.height
        } else if abs(droppedRect.minY - target.minY) <= alignThreshold {
            snappedY = target.minY
        }
        results.append(NSRect(x: target.minX - size.width, y: snappedY, width: size.width, height: size.height))
        results.append(NSRect(x: target.maxX, y: snappedY, width: size.width, height: size.height))

        // 2. Bottom & Top of target -> align X
        let minTouchX = target.minX - size.width + 20.0
        let maxTouchX = target.maxX - 20.0
        var snappedX = min(max(droppedRect.minX, minTouchX), maxTouchX)
        if abs(droppedRect.minX - target.minX) <= alignThreshold {
            snappedX = target.minX
        } else if abs(droppedRect.maxX - target.maxX) <= alignThreshold {
            snappedX = target.maxX - size.width
        }
        results.append(NSRect(x: snappedX, y: target.minY - size.height, width: size.width, height: size.height))
        results.append(NSRect(x: snappedX, y: target.maxY, width: size.width, height: size.height))

        return results
    }

    private func chooseAdaptiveLibraryPlacementForMiniMode() {
        let s = GlassInteractionCoordinator.shared.uiScale
        let (playerSize, _, libSize) = currentModuleSizes(scale: s)

        let vf = (hostWindow.screen ?? NSScreen.main)?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let pRect = NSRect(origin: playerScreenOrigin, size: playerSize)

        let topSpace = vf.maxY - pRect.maxY
        let bottomSpace = pRect.minY - vf.minY
        let rightSpace = vf.maxX - pRect.maxX
        let leftSpace = pRect.minX - vf.minX

        if topSpace >= libSize.height {
            libraryPlacement = .top
        } else if bottomSpace >= libSize.height {
            libraryPlacement = .bottom
        } else if rightSpace >= libSize.width {
            libraryPlacement = .right
        } else if leftSpace >= libSize.width {
            libraryPlacement = .left
        } else {
            let candidates: [(Placement, CGFloat)] = [
                (.top, topSpace - libSize.height),
                (.bottom, bottomSpace - libSize.height),
                (.right, rightSpace - libSize.width),
                (.left, leftSpace - libSize.width),
            ]
            libraryPlacement = candidates.max(by: { $0.1 < $1.1 })?.0 ?? .bottom
        }
    }

    private func currentModuleSizes(scale s: CGFloat) -> (player: NSSize, lyrics: NSSize, library: NSSize) {
        let playerSize = playerCtrl.preferredPlayerSize(for: s)
        let lyricsSize = lyricsView.preferredSize(for: s)
        var librarySize = libraryCtrl.preferredSize(for: s)
        librarySize.width = playerSize.width
        if !playerCtrl.isMiniMode && isLyricsVisible && customLyricsOffset == nil && customLibraryOffset == nil {
            librarySize.height = playerSize.height + lyricsSize.height
        }
        return (playerSize, lyricsSize, librarySize)
    }

    /// Recomputes module frames relative to `playerScreenOrigin` and resizes `hostWindow`
    /// while keeping the player module pinned at `playerScreenOrigin`.
    public func relayoutStage() {
        let s = GlassInteractionCoordinator.shared.uiScale
        let capH = OriginalDesignTokens.BaseMetrics.glassCapHeight * s
        let (playerSize, lyricsSize, librarySize) = currentModuleSizes(scale: s)

        let playerLocal = NSRect(origin: .zero, size: playerSize)
        var rects: [NSRect] = [playerLocal]

        var lyricsLocal = NSRect.zero
        if isLyricsVisible {
            if activeDragModule == .lyrics {
                let relOrigin = NSPoint(x: liveDragScreenOrigin.x - playerScreenOrigin.x, y: liveDragScreenOrigin.y - playerScreenOrigin.y)
                lyricsLocal = NSRect(origin: relOrigin, size: lyricsSize)
            } else if let custom = customLyricsOffset {
                lyricsLocal = NSRect(origin: custom, size: lyricsSize)
            } else {
                lyricsLocal = place(size: lyricsSize, relativeTo: playerLocal, side: lyricsPlacement)
            }
            rects.append(lyricsLocal)
        }

        var libraryLocal = NSRect.zero
        if isLibraryVisible {
            if activeDragModule == .library {
                let relOrigin = NSPoint(x: liveDragScreenOrigin.x - playerScreenOrigin.x, y: liveDragScreenOrigin.y - playerScreenOrigin.y)
                libraryLocal = NSRect(origin: relOrigin, size: librarySize)
            } else if let custom = customLibraryOffset {
                libraryLocal = NSRect(origin: custom, size: librarySize)
            } else {
                var anchor = playerLocal
                if isLyricsVisible && libraryPlacement == lyricsPlacement {
                    anchor = lyricsLocal
                }
                libraryLocal = place(size: librarySize, relativeTo: anchor, side: libraryPlacement)
            }
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
            lyricsDragHandle.frame = NSRect(x: 0, y: finalLyricsFrame.height - capH, width: finalLyricsFrame.width, height: capH)
        }

        libraryCtrl.moduleView.isHidden = !isLibraryVisible
        if isLibraryVisible {
            libraryCtrl.moduleView.frame = finalLibraryFrame
            libraryCtrl.moduleView.needsLayout = true
            libraryCtrl.moduleView.refreshGlassSurface()
            libraryDragHandle.frame = NSRect(x: 0, y: finalLibraryFrame.height - capH, width: finalLibraryFrame.width, height: capH)
        }

        hostWindow.invalidateShadow()
        isAdjustingFrame = false
    }

    private func place(size: NSSize, relativeTo anchor: NSRect, side: Placement) -> NSRect {
        switch side {
        case .bottom:
            return NSRect(x: anchor.minX, y: anchor.minY - size.height, width: size.width, height: size.height)
        case .top:
            return NSRect(x: anchor.minX, y: anchor.maxY, width: size.width, height: size.height)
        case .right:
            return NSRect(x: anchor.maxX, y: anchor.maxY - size.height, width: size.width, height: size.height)
        case .left:
            return NSRect(x: anchor.minX - size.width, y: anchor.maxY - size.height, width: size.width, height: size.height)
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
        customLyricsOffset = nil
        customLibraryOffset = nil
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
