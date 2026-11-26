import AppKit
import QuartzCore
import Domain
import DesignSystem

// MARK: - StageRootView

/// Transparent host root view that passes clicks through empty space between separated panels
/// and excludes collapsed/hidden regions during transitions.
@MainActor
private final class StageRootView: NSView {
    var interactiveHitFrames: [NSRect] = []

    override func hitTest(_ point: NSPoint) -> NSView? {
        if !interactiveHitFrames.isEmpty {
            let insideActive = interactiveHitFrames.contains { $0.contains(point) }
            if !insideActive {
                return nil
            }
        }
        for subview in subviews.reversed() where !subview.isHidden && subview.alphaValue > 0.01 {
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
    var onDragCancelled: (() -> Void)?
    var onDoubleClicked: (() -> Void)?

    private var dragStartMouse: NSPoint = .zero
    private var isDragging = false
    private var didDrag = false
    private var lastDoubleClickTime: TimeInterval = 0

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
            if let textField = sub as? NSTextField, !textField.isEditable, !textField.isSelectable {
                continue
            }
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
        didDrag = false
        onDragBegan?()
    }

    override func mouseDragged(with event: NSEvent) {
        guard isDragging else { return }
        let cur = NSEvent.mouseLocation
        let delta = NSPoint(x: cur.x - dragStartMouse.x, y: cur.y - dragStartMouse.y)
        if hypot(delta.x, delta.y) >= 2.0 {
            didDrag = true
        }
        if didDrag {
            onDragChanged?(delta)
        }
    }

    override func mouseUp(with event: NSEvent) {
        guard isDragging else { return }
        isDragging = false
        if didDrag {
            onDragEnded?()
            return
        }
        onDragCancelled?()
        if event.clickCount == 2, let onDoubleClicked {
            let now = ProcessInfo.processInfo.systemUptime
            if now - lastDoubleClickTime >= MotionTokens.Thresholds.doubleClickDebounce {
                lastDoubleClickTime = now
                onDoubleClicked()
            }
        }
    }
}

// MARK: - UnifiedStageController

/// Single-host stage coordinator for Main/Mini Player, Lyrics, and Library modules inside `PlayerWindow`.
/// Owns all stage geometry transitions (`M01`, `M02`, `M11`, `M12`, `M13`, `M14`, `M25`, `M26`) via
/// `StageLayoutEngine` + `MotionCoordinator`, preserving latest-intent-wins and WebKit instance continuity.
@MainActor
public final class UnifiedStageController {

    public typealias Placement = StagePlacement

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

    /// Transient drag vs M12 snap state for single-panel positioning.
    private var activeDragModule: ModuleKind?
    private var dragStartOrigin: NSPoint = .zero
    private var liveDragScreenOrigin: NSPoint = .zero
    private var dragStartedSnapped: Bool = false
    private var activeSnapResult: StageSnapResult?
    private var activeSnapModule: ModuleKind?
    private var liveSnapScreenOrigin: NSPoint = .zero

    private var isAdjustingFrame = false
    private var lastPlayerHeight: CGFloat = 0
    private var hasPlayedLaunchIntro = false
    private var isLaunchSequencePendingDockAppear = false
    private var isCollapsingForAction = false

    // Choreographed 3-step Mini Mode sequence state & generation guard
    private var modeSequenceGeneration: UInt64 = 0
    private var targetMiniSequenceState: Bool = false
    private var isRunningMiniSequence: Bool = false
    private var restoreLibraryOnExpand: Bool = false
    private var restoreLyricsFullOnExpand: Bool = false

    // Active stage animation tracking (M02 / M12 / M13 / M14)
    private let stageOwnerID = "UnifiedStage-\(UUID().uuidString)"
    private var stageDriverSubID: UUID?
    private var stageTicket: MotionTicket?
    private var snapDriverSubID: UUID?
    private var snapTicket: MotionTicket?

    // Live presentation state in screen coordinates during active stage transitions
    private var livePlayerScreenRect: CGRect = .zero
    private var liveLyricsScreenRect: CGRect = .zero
    private var liveLibraryScreenRect: CGRect = .zero
    private var liveLyricsRevealProgress: CGFloat = 1.0
    private var liveLibraryRevealProgress: CGFloat = 1.0
    private var liveModeProgress: CGFloat = 1.0

    public var isStageTransitioning: Bool {
        stageTicket != nil || snapTicket != nil
    }

    public var isSnapPreviewVisible: Bool {
        false
    }

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
        self.playerScreenOrigin = StageLayoutEngine.clampOrigin(
            initialOrigin,
            size: initialPlayerSize,
            visibleFrames: Self.screenVisibleFrames()
        )
        self.lastPlayerHeight = initialPlayerSize.height

        let window = PlayerWindow(contentRect: NSRect(origin: self.playerScreenOrigin, size: initialPlayerSize))
        window.hasShadow = false
        self.hostWindow = window

        setupStage()
        wireEvents()
        relayoutStage()
    }

    isolated deinit {
        cancelAllStageAnimations()
        NotificationCenter.default.removeObserver(self)
    }

    public var contentContainerView: NSView {
        stageRootView
    }

    private func setupStage() {
        stageRootView.wantsLayer = true
        stageRootView.layer?.masksToBounds = false
        stageRootView.menu = hostWindow.contentView?.menu
        hostWindow.contentView = stageRootView

        stageRootView.addSubview(lyricsView)
        stageRootView.addSubview(libraryCtrl.moduleView)
        // Main player sits above dock modules so Lyrics/Library cleanly emerge from behind Main's edges
        stageRootView.addSubview(playerCtrl.playerSlotView)

        lyricsView.addSubview(lyricsDragHandle, positioned: .above, relativeTo: nil)
        libraryCtrl.moduleView.addSubview(libraryDragHandle, positioned: .above, relativeTo: nil)

        MotionCoordinator.shared.displayDriver.attach(to: stageRootView)
    }

    private func wireEvents() {
        hostWindow.onDoubleClicked = { [weak self] in
            self?.toggleChoreographedMiniMode()
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

        playerCtrl.onChoreographedMiniToggleRequested = { [weak self] in
            self?.toggleChoreographedMiniMode()
        }

        playerCtrl.onModeTransitionRequested = { [weak self] nextMini in
            self?.performModeMorphTransition(toMini: nextMini)
        }

        playerCtrl.onModeDidTransition = { [weak self] in
            guard let self else { return }
            self.performModeMorphTransition(toMini: self.playerCtrl.isMiniMode)
        }

        lyricsView.onMiniModeTransitionRequested = { [weak self] _ in
            self?.performLyricsResizeTransition()
        }
        lyricsView.onMiniModeDidChange = { [weak self] in
            self?.performLyricsResizeTransition()
        }
        lyricsView.onClose = { [weak self] in
            self?.setLyricsVisible(false)
        }
        libraryCtrl.onClose = { [weak self] in
            self?.setLibraryVisible(false)
        }
        playerCtrl.onMinimizeRequested = { [weak self] in
            self?.collapseStageAndMiniaturize()
        }
        playerCtrl.onQuitRequested = { [weak self] in
            self?.collapseStageAndTerminate()
        }

        wireDragHandle(lyricsDragHandle, for: .lyrics)
        wireDragHandle(libraryDragHandle, for: .library)
        lyricsDragHandle.onDoubleClicked = { [weak self] in
            self?.lyricsView.toggleMiniLyricsMode()
        }

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleWindowDidMove),
            name: NSWindow.didMoveNotification,
            object: hostWindow
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleWindowDidDeminiaturize),
            name: NSWindow.didDeminiaturizeNotification,
            object: hostWindow
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleScaleOrModeChange),
            name: GlassInteractionCoordinator.modeDidChangeNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleScreenParametersChanged),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAccessibilityChanged),
            name: MotionAccessibility.preferencesDidChangeNotification,
            object: nil
        )
    }

    private func wireDragHandle(_ handle: ModuleTopBarDragHandle, for kind: ModuleKind) {
        handle.onDragBegan = { [weak self] in
            guard let self else { return }
            self.cancelAllStageAnimations()
            self.activeDragModule = kind
            let currentRect = self.screenRect(for: kind)
            self.dragStartOrigin = currentRect.origin
            self.liveDragScreenOrigin = currentRect.origin
            self.dragStartedSnapped = (kind == .lyrics) ? (self.customLyricsOffset != nil) : (self.customLibraryOffset != nil)
            self.activeSnapResult = nil
        }
        handle.onDragChanged = { [weak self] delta in
            guard let self, self.activeDragModule == kind else { return }
            let rawOrigin = NSPoint(
                x: self.dragStartOrigin.x + delta.x,
                y: self.dragStartOrigin.y + delta.y
            )
            let s = GlassInteractionCoordinator.shared.uiScale
            let (playerSize, lyricsSize, librarySize) = self.currentModuleSizes(scale: s)
            let movedSize = (kind == .lyrics) ? lyricsSize : librarySize
            self.liveDragScreenOrigin = rawOrigin

            let playerScreenRect = CGRect(origin: self.playerScreenOrigin, size: playerSize)
            let otherRect: CGRect? = {
                if kind == .lyrics && self.isLibraryVisible {
                    return self.screenRect(for: .library)
                } else if kind == .library && self.isLyricsVisible {
                    return self.screenRect(for: .lyrics)
                }
                return nil
            }()

            let snap = StageLayoutEngine.computeSnap(
                movedSize: movedSize,
                droppedOrigin: rawOrigin,
                playerScreenRect: playerScreenRect,
                otherModuleScreenRect: otherRect,
                uiScale: s,
                wasAlreadySnapped: self.dragStartedSnapped,
                visibleFrames: Self.screenVisibleFrames()
            )
            self.activeSnapResult = snap
            self.relayoutStage()
        }
        handle.onDragEnded = { [weak self] in
            guard let self, self.activeDragModule == kind else { return }
            let droppedOrigin = self.liveDragScreenOrigin
            let snap = self.activeSnapResult
            self.activeDragModule = nil
            self.activeSnapResult = nil
            self.snapDroppedModule(kind, droppedOrigin: droppedOrigin, precomputedSnap: snap)
        }
        handle.onDragCancelled = { [weak self] in
            guard let self, self.activeDragModule == kind else { return }
            self.activeDragModule = nil
            self.activeSnapResult = nil
        }
    }

    public func showAndFocus() {
        relayoutStage()
        hostWindow.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    /// Triggers M01 non-blocking glass-bar scroll intro on Main Player, followed automatically
    /// by the two-phase glass-bar emerge & unroll of Lyrics (below Main) and Library (left-to-right from Main).
    public func playLaunchIntroIfNeeded() {
        guard !hasPlayedLaunchIntro else { return }
        hasPlayedLaunchIntro = true
        playChoreographedStageOpen()
    }

    private func playChoreographedStageOpen() {
        let s = GlassInteractionCoordinator.shared.uiScale
        let targetLayout = computeTargetLayout(scale: s)
        if MotionCoordinator.shared.isReduceMotionEnabled || playerCtrl.isMiniMode {
            commitFinalLayout(targetLayout, targetMini: playerCtrl.isMiniMode)
            return
        }

        if isLyricsVisible {
            lyricsView.isHidden = true
            lyricsView.clearScrollPresentation()
            liveLyricsRevealProgress = 0.0
            liveLyricsScreenRect = .zero
        }
        if isLibraryVisible {
            libraryCtrl.moduleView.isHidden = true
            libraryCtrl.moduleView.clearScrollPresentation()
            liveLibraryRevealProgress = 0.0
            liveLibraryScreenRect = .zero
        }
        stageRootView.interactiveHitFrames = [targetLayout.playerFrame]
        isLaunchSequencePendingDockAppear = true

        playerCtrl.playScrollIntroIfEligible { [weak self] committed in
            guard let self else { return }
            let pending = self.isLaunchSequencePendingDockAppear
            self.isLaunchSequencePendingDockAppear = false
            if committed {
                self.playPostMainDockAppear()
            } else if pending {
                // Interrupted by user input directly on Main during Stage 1 open
                self.cancelStageGeometryAnimation()
                self.relayoutStage()
            }
        }
    }

    /// Stage 2 of launch (after Main finishes expanding):
    /// - Lyrics: two glass bars slide down out of Main's bottom edge, then bottom bar unrolls downward.
    /// - Library: collapsed two glass bars slide left-to-right out of Main's right edge, then bottom bar unrolls downward.
    private func playPostMainDockAppear() {
        let showLyrics = isLyricsVisible
        let showLibrary = isLibraryVisible
        let s = GlassInteractionCoordinator.shared.uiScale
        let targetLayout = computeTargetLayout(scale: s)

        guard showLyrics || showLibrary else {
            commitFinalLayout(targetLayout, targetMini: playerCtrl.isMiniMode)
            return
        }
        guard !MotionCoordinator.shared.isReduceMotionEnabled else {
            commitFinalLayout(targetLayout, targetMini: playerCtrl.isMiniMode)
            return
        }

        cancelAllStageAnimations()
        let key = TransitionKey(owner: stageOwnerID, channel: "geometry")
        let ticket = MotionCoordinator.shared.beginTransition(for: key, category: .stageGeometry) { [weak self] in
            self?.stopStageDriver()
        }
        stageTicket = ticket

        let host = targetLayout.hostFrame
        isAdjustingFrame = true
        if hostWindow.frame != host {
            hostWindow.setFrame(host, display: false, animate: false)
        }
        stageRootView.frame = NSRect(origin: .zero, size: host.size)
        isAdjustingFrame = false

        let playerLocal = targetLayout.playerFrame
        playerCtrl.finalizeMorphState(isMini: playerCtrl.isMiniMode, slotFrame: playerLocal)
        livePlayerScreenRect = playerLocal.offsetBy(dx: host.minX, dy: host.minY)

        let capH = OriginalDesignTokens.BaseMetrics.glassCapHeight * s
        if showLyrics {
            lyricsView.isHidden = false
            lyricsView.frame = targetLayout.lyricsFrame
            lyricsView.layoutSubtreeIfNeeded()
            lyricsView.refreshGlass()
            lyricsDragHandle.frame = lyricsDragHandleFrame(for: targetLayout.lyricsFrame.size, capHeight: capH)
        }
        if showLibrary {
            libraryCtrl.moduleView.isHidden = false
            libraryCtrl.moduleView.frame = targetLayout.libraryFrame
            libraryCtrl.moduleView.layoutSubtreeIfNeeded()
            libraryCtrl.moduleView.refreshGlassSurface()
            libraryDragHandle.frame = NSRect(x: 0, y: targetLayout.libraryFrame.height - capH, width: targetLayout.libraryFrame.width, height: capH)
        }

        let lyricsDur = MotionTokens.Duration.lyricsResize
        let libraryStagger: TimeInterval = showLyrics ? 0.04 : 0.0
        let libraryDur = MotionTokens.Duration.libraryReveal
        let totalDur = max(showLyrics ? lyricsDur : 0.0, showLibrary ? (libraryStagger + libraryDur) : 0.0)

        let applyStep: (TimeInterval) -> Void = { [weak self] elapsed in
            guard let self else { return }
            var hits: [NSRect] = [playerLocal]

            if showLyrics {
                let pLyr = CGFloat(min(1.0, max(0.0, elapsed / max(0.01, lyricsDur))))
                self.liveLyricsRevealProgress = pLyr
                let exposed = Self.applyScrollRevealStep(
                    kind: .lyrics,
                    moduleView: self.lyricsView,
                    contentAlphaView: self.lyricsView.contentContainerView,
                    dragHandle: self.lyricsDragHandle,
                    applyScroll: { top, bot, alpha, outer in
                        self.lyricsView.applyScrollPresentation(topBarFrame: top, bottomBarFrame: bot, barAlpha: alpha, outerClipRect: outer)
                    },
                    localFullFrame: targetLayout.lyricsFrame,
                    localPlayerFrame: playerLocal,
                    placement: self.lyricsPlacement,
                    progress: pLyr,
                    uiScale: s
                )
                self.liveLyricsScreenRect = exposed.offsetBy(dx: host.minX, dy: host.minY)
                if pLyr > 0.02 { hits.append(exposed) }
            }

            if showLibrary {
                let libElapsed = max(0.0, elapsed - libraryStagger)
                let pLib = CGFloat(min(1.0, max(0.0, libElapsed / max(0.01, libraryDur))))
                self.liveLibraryRevealProgress = pLib
                let exposed = Self.applyScrollRevealStep(
                    kind: .library,
                    moduleView: self.libraryCtrl.moduleView,
                    contentAlphaView: self.libraryCtrl.contentContainerView,
                    dragHandle: self.libraryDragHandle,
                    applyScroll: { top, bot, alpha, outer in
                        self.libraryCtrl.moduleView.applyScrollPresentation(topBarFrame: top, bottomBarFrame: bot, barAlpha: alpha, outerClipRect: outer)
                    },
                    localFullFrame: targetLayout.libraryFrame,
                    localPlayerFrame: playerLocal,
                    placement: self.libraryPlacement,
                    progress: pLib,
                    uiScale: s
                )
                self.liveLibraryScreenRect = exposed.offsetBy(dx: host.minX, dy: host.minY)
                if pLib > 0.02 { hits.append(exposed) }
            }

            self.stageRootView.interactiveHitFrames = hits
        }

        applyStep(0.0)

        var elapsed: TimeInterval = 0
        stageDriverSubID = MotionCoordinator.shared.displayDriver.start { [weak self] dt, _ in
            guard let self, MotionCoordinator.shared.isCurrent(ticket) else { return false }
            elapsed += dt
            applyStep(elapsed)

            if elapsed >= totalDur {
                if MotionCoordinator.shared.complete(ticket) {
                    self.stageTicket = nil
                    self.stageDriverSubID = nil
                    self.lyricsView.clearScrollPresentation()
                    self.libraryCtrl.moduleView.clearScrollPresentation()
                    self.commitFinalLayout(targetLayout, targetMini: self.playerCtrl.isMiniMode)
                }
                return false
            }
            return true
        }
    }

    private func collapseStageAndMiniaturize() {
        collapseVisibleModulesThenPlayer { [weak self] in
            self?.hostWindow.miniaturize(nil)
        }
    }

    private func collapseStageAndTerminate() {
        if isCollapsingForAction {
            NSApp.terminate(nil)
            return
        }
        collapseVisibleModulesThenPlayer {
            NSApp.terminate(nil)
        }
    }

    private func collapseVisibleModulesThenPlayer(completion: @escaping @MainActor () -> Void) {
        if isCollapsingForAction || MotionCoordinator.shared.isReduceMotionEnabled || playerCtrl.isMiniMode {
            completion()
            return
        }
        isCollapsingForAction = true
        playerCtrl.playerView.cancelScrollIntro()

        let hadLyrics = isLyricsVisible
        let hadLibrary = isLibraryVisible
        guard hadLyrics || hadLibrary else {
            playerCtrl.playScrollCollapseIfEligible { [weak self] _ in
                self?.isCollapsingForAction = false
                completion()
            }
            return
        }

        let s = GlassInteractionCoordinator.shared.uiScale
        let fullLayout = computeTargetLayout(scale: s)
        let host = fullLayout.hostFrame
        let playerLocal = fullLayout.playerFrame

        cancelAllStageAnimations()
        let key = TransitionKey(owner: stageOwnerID, channel: "geometry")
        let ticket = MotionCoordinator.shared.beginTransition(for: key, category: .stageGeometry) { [weak self] in
            self?.stopStageDriver()
        }
        stageTicket = ticket

        let dur: TimeInterval = 0.24
        var elapsed: TimeInterval = 0
        stageDriverSubID = MotionCoordinator.shared.displayDriver.start { [weak self] dt, _ in
            guard let self, MotionCoordinator.shared.isCurrent(ticket) else { return false }
            elapsed += dt
            let raw = min(1.0, elapsed / dur)
            let p = CGFloat(1.0 - raw)
            if hadLyrics {
                _ = Self.applyScrollRevealStep(
                    kind: .lyrics,
                    moduleView: self.lyricsView,
                    contentAlphaView: self.lyricsView.contentContainerView,
                    dragHandle: self.lyricsDragHandle,
                    applyScroll: { top, bot, alpha, outer in
                        self.lyricsView.applyScrollPresentation(topBarFrame: top, bottomBarFrame: bot, barAlpha: alpha, outerClipRect: outer)
                    },
                    localFullFrame: fullLayout.lyricsFrame,
                    localPlayerFrame: playerLocal,
                    placement: self.lyricsPlacement,
                    progress: p,
                    uiScale: s
                )
            }
            if hadLibrary {
                _ = Self.applyScrollRevealStep(
                    kind: .library,
                    moduleView: self.libraryCtrl.moduleView,
                    contentAlphaView: self.libraryCtrl.contentContainerView,
                    dragHandle: self.libraryDragHandle,
                    applyScroll: { top, bot, alpha, outer in
                        self.libraryCtrl.moduleView.applyScrollPresentation(topBarFrame: top, bottomBarFrame: bot, barAlpha: alpha, outerClipRect: outer)
                    },
                    localFullFrame: fullLayout.libraryFrame,
                    localPlayerFrame: playerLocal,
                    placement: self.libraryPlacement,
                    progress: p,
                    uiScale: s
                )
            }
            _ = host
            if raw >= 1.0 {
                if MotionCoordinator.shared.complete(ticket) {
                    self.stageTicket = nil
                    self.stageDriverSubID = nil
                    self.lyricsView.isHidden = true
                    self.lyricsView.clearScrollPresentation()
                    self.libraryCtrl.moduleView.isHidden = true
                    self.libraryCtrl.moduleView.clearScrollPresentation()
                    self.playerCtrl.playScrollCollapseIfEligible { [weak self] _ in
                        self?.isCollapsingForAction = false
                        completion()
                    }
                }
                return false
            }
            return true
        }
    }

    // MARK: - Choreographed 3-Step Mini Mode Sequence

    /// Toggles Normal <-> Mini using the 3-step choreographed sequence:
    /// - Entering Mini: (1) Collapse Library -> (2) Miniaturize Main -> (3) Shrink Lyrics to Mini.
    /// - Exiting Mini: (1) Expand Main -> (2) Expand Lyrics to Full -> (3) Expand Library.
    public func toggleChoreographedMiniMode() {
        let nextMini = isRunningMiniSequence ? !targetMiniSequenceState : !playerCtrl.isMiniMode
        if nextMini {
            enterMiniModeChoreographed()
        } else {
            exitMiniModeChoreographed()
        }
    }

    public func enterMiniModeChoreographed() {
        modeSequenceGeneration &+= 1
        let expectedGen = modeSequenceGeneration
        isLaunchSequencePendingDockAppear = false
        playerCtrl.playerView.cancelScrollIntro()
        targetMiniSequenceState = true
        isRunningMiniSequence = true

        let shouldHideLib = isLibraryVisible
        let shouldShrinkLyrics = isLyricsVisible && !lyricsView.isMiniLyricsMode
        if shouldHideLib { restoreLibraryOnExpand = true }
        if shouldShrinkLyrics { restoreLyricsFullOnExpand = true }

        if MotionCoordinator.shared.isReduceMotionEnabled {
            cancelAllStageAnimations()
            if shouldHideLib {
                isLibraryVisible = false
                customLibraryOffset = nil
            }
            playerCtrl.setMiniModeStateForChoreography(true)
            if shouldShrinkLyrics {
                lyricsView.setMiniLyricsModeState(true)
            }
            isRunningMiniSequence = false
            relayoutStage()
            return
        }

        let stepDur = GlassInteractionCoordinator.shared.modeSequenceTotalDuration / 3.0

        let step3ShrinkLyrics: @MainActor () -> Void = { [weak self] in
            guard let self, self.modeSequenceGeneration == expectedGen else { return }
            if self.isLyricsVisible && !self.lyricsView.isMiniLyricsMode {
                self.lyricsView.setMiniLyricsModeState(true)
                self.performLyricsResizeTransition(duration: stepDur) { [weak self] committed in
                    guard let self, self.modeSequenceGeneration == expectedGen, committed else { return }
                    self.isRunningMiniSequence = false
                }
            } else {
                self.isRunningMiniSequence = false
            }
        }

        let step2MorphMain: @MainActor () -> Void = { [weak self] in
            guard let self, self.modeSequenceGeneration == expectedGen else { return }
            if !self.playerCtrl.isMiniMode {
                self.playerCtrl.setMiniModeStateForChoreography(true)
                self.performModeMorphTransition(toMini: true, duration: stepDur) { [weak self] committed in
                    guard let self, self.modeSequenceGeneration == expectedGen, committed else { return }
                    step3ShrinkLyrics()
                }
            } else {
                step3ShrinkLyrics()
            }
        }

        if shouldHideLib {
            setLibraryVisibleInternal(false, duration: stepDur, invalidateSequence: false) { [weak self] committed in
                guard let self, self.modeSequenceGeneration == expectedGen, committed else { return }
                step2MorphMain()
            }
        } else {
            step2MorphMain()
        }
    }

    public func exitMiniModeChoreographed() {
        modeSequenceGeneration &+= 1
        let expectedGen = modeSequenceGeneration
        isLaunchSequencePendingDockAppear = false
        playerCtrl.playerView.cancelScrollIntro()
        targetMiniSequenceState = false
        isRunningMiniSequence = true

        let shouldExpandLyrics = isLyricsVisible && restoreLyricsFullOnExpand && lyricsView.isMiniLyricsMode
        let shouldShowLib = restoreLibraryOnExpand && !isLibraryVisible
        restoreLyricsFullOnExpand = false
        restoreLibraryOnExpand = false

        if MotionCoordinator.shared.isReduceMotionEnabled {
            cancelAllStageAnimations()
            if shouldExpandLyrics {
                lyricsView.setMiniLyricsModeState(false)
            }
            playerCtrl.setMiniModeStateForChoreography(false)
            if shouldShowLib {
                isLibraryVisible = true
                libraryPlacement = .right
            }
            isRunningMiniSequence = false
            relayoutStage()
            return
        }

        let stepDur = GlassInteractionCoordinator.shared.modeSequenceTotalDuration / 3.0

        let step3ExpandLibrary: @MainActor () -> Void = { [weak self] in
            guard let self, self.modeSequenceGeneration == expectedGen else { return }
            if shouldShowLib && !self.isLibraryVisible {
                self.setLibraryVisibleInternal(true, duration: stepDur, invalidateSequence: false) { [weak self] committed in
                    guard let self, self.modeSequenceGeneration == expectedGen, committed else { return }
                    self.isRunningMiniSequence = false
                }
            } else {
                self.isRunningMiniSequence = false
            }
        }

        let step2ExpandLyrics: @MainActor () -> Void = { [weak self] in
            guard let self, self.modeSequenceGeneration == expectedGen else { return }
            if shouldExpandLyrics {
                self.lyricsView.setMiniLyricsModeState(false)
                self.performLyricsResizeTransition(duration: stepDur) { [weak self] committed in
                    guard let self, self.modeSequenceGeneration == expectedGen, committed else { return }
                    step3ExpandLibrary()
                }
            } else {
                step3ExpandLibrary()
            }
        }

        if playerCtrl.isMiniMode {
            playerCtrl.setMiniModeStateForChoreography(false)
            performModeMorphTransition(toMini: false, duration: stepDur) { [weak self] committed in
                guard let self, self.modeSequenceGeneration == expectedGen, committed else { return }
                step2ExpandLyrics()
            }
        } else {
            step2ExpandLyrics()
        }
    }

    public func toggleLyrics() {
        setLyricsVisible(!isLyricsVisible)
    }

    public func setLyricsVisible(_ visible: Bool) {
        modeSequenceGeneration &+= 1
        isRunningMiniSequence = false
        guard isLyricsVisible != visible else { return }
        isLaunchSequencePendingDockAppear = false
        playerCtrl.playerView.cancelScrollIntro()
        let s = GlassInteractionCoordinator.shared.uiScale
        let startLayout = currentPresentationLayout(scale: s)
        let unmaskedPreviousLayout = computeTargetLayout(scale: s)
        let wasVisible = isLyricsVisible

        isLyricsVisible = visible
        if !visible { customLyricsOffset = nil }
        let targetLayout = computeTargetLayout(scale: s)
        runModuleRevealTransition(
            kind: .lyrics,
            showing: visible,
            wasVisible: wasVisible,
            startLayout: startLayout,
            unmaskedStartLayout: unmaskedPreviousLayout,
            targetLayout: targetLayout,
            duration: MotionTokens.Duration.lyricsResize
        )
    }

    public func toggleLibrary() {
        setLibraryVisible(!isLibraryVisible)
    }

    public func setLibraryVisible(_ visible: Bool) {
        setLibraryVisibleInternal(visible, duration: MotionTokens.Duration.libraryReveal, invalidateSequence: true)
    }

    private func setLibraryVisibleInternal(
        _ visible: Bool,
        duration: TimeInterval,
        invalidateSequence: Bool,
        completion: (@MainActor (Bool) -> Void)? = nil
    ) {
        if invalidateSequence {
            modeSequenceGeneration &+= 1
            isRunningMiniSequence = false
            restoreLibraryOnExpand = false
        }
        guard isLibraryVisible != visible else {
            completion?(true)
            return
        }
        isLaunchSequencePendingDockAppear = false
        playerCtrl.playerView.cancelScrollIntro()
        let s = GlassInteractionCoordinator.shared.uiScale
        let startLayout = currentPresentationLayout(scale: s)
        let unmaskedPreviousLayout = computeTargetLayout(scale: s)
        let wasVisible = isLibraryVisible

        isLibraryVisible = visible
        if !visible { customLibraryOffset = nil }
        if visible && playerCtrl.isMiniMode {
            chooseAdaptiveLibraryPlacementForMiniMode()
        } else if visible && !playerCtrl.isMiniMode && customLibraryOffset == nil {
            libraryPlacement = .right
        }
        let targetLayout = computeTargetLayout(scale: s)
        runModuleRevealTransition(
            kind: .library,
            showing: visible,
            wasVisible: wasVisible,
            startLayout: startLayout,
            unmaskedStartLayout: unmaskedPreviousLayout,
            targetLayout: targetLayout,
            duration: duration,
            completion: completion
        )
    }

    private func applyTopMostLevel() {
        hostWindow.level = playerCtrl.isTopMost ? .floating : .normal
        hostWindow.refreshMenuStates()
    }

    private func screenRect(for kind: ModuleKind) -> NSRect {
        if stageTicket != nil {
            return (kind == .lyrics) ? liveLyricsScreenRect : liveLibraryScreenRect
        }
        let view: NSView = (kind == .lyrics) ? lyricsView : libraryCtrl.moduleView
        let f = view.frame
        return NSRect(
            x: hostWindow.frame.minX + f.minX,
            y: hostWindow.frame.minY + f.minY,
            width: f.width,
            height: f.height
        )
    }

    // MARK: - M02 Normal ↔ Mini Continuous Morph

    private func performModeMorphTransition(
        toMini targetMini: Bool,
        duration: TimeInterval = MotionTokens.Duration.miniToggle,
        completion: (@MainActor (Bool) -> Void)? = nil
    ) {
        isLaunchSequencePendingDockAppear = false
        playerCtrl.playerView.cancelScrollIntro()
        let s = GlassInteractionCoordinator.shared.uiScale
        let startLayout = currentPresentationLayout(scale: s)
        let oldSize = startLayout.playerFrame.size
        let newSize = playerCtrl.preferredPlayerSize(for: s, mini: targetMini)

        playerScreenOrigin = StageLayoutEngine.anchoredOriginForHeightChange(
            currentOrigin: livePlayerScreenRect != .zero && stageTicket != nil
                ? livePlayerScreenRect.origin
                : playerScreenOrigin,
            oldSize: oldSize,
            newSize: newSize,
            visibleFrames: Self.screenVisibleFrames()
        )
        lastPlayerHeight = newSize.height
        customLyricsOffset = nil
        customLibraryOffset = nil

        if targetMini && isLibraryVisible {
            chooseAdaptiveLibraryPlacementForMiniMode()
        } else if !targetMini {
            libraryPlacement = .right
        }

        let targetLayout = computeTargetLayout(scale: s)
        hostWindow.refreshMenuStates()

        if MotionCoordinator.shared.isReduceMotionEnabled {
            cancelAllStageAnimations()
            commitFinalLayout(targetLayout, targetMini: targetMini)
            completion?(true)
            return
        }

        cancelAllStageAnimations()
        let key = TransitionKey(owner: stageOwnerID, channel: "geometry")
        let ticket = MotionCoordinator.shared.beginTransition(for: key, category: .stageGeometry) { [weak self] in
            self?.stopStageDriver()
            completion?(false)
        }
        stageTicket = ticket

        let startHost = startLayout.hostFrame
        let targetHost = targetLayout.hostFrame
        let startPlayerScreen = startLayout.playerFrame.offsetBy(dx: startHost.minX, dy: startHost.minY)
        let targetPlayerScreen = targetLayout.playerFrame.offsetBy(dx: targetHost.minX, dy: targetHost.minY)
        let startLyricsScreen = startLayout.lyricsFrame.offsetBy(dx: startHost.minX, dy: startHost.minY)
        let targetLyricsScreen = targetLayout.lyricsFrame.offsetBy(dx: targetHost.minX, dy: targetHost.minY)
        let startLibraryScreen = startLayout.libraryFrame.offsetBy(dx: startHost.minX, dy: startHost.minY)
        let targetLibraryScreen = targetLayout.libraryFrame.offsetBy(dx: targetHost.minX, dy: targetHost.minY)

        let envelope = startHost.union(targetHost)
        isAdjustingFrame = true
        if hostWindow.frame != envelope {
            hostWindow.setFrame(envelope, display: false, animate: false)
        }
        stageRootView.frame = NSRect(origin: .zero, size: envelope.size)
        isAdjustingFrame = false

        let applyMorphStep: (CGFloat) -> Void = { [weak self] t in
            guard let self else { return }
            let curPlayer = Self.lerpRect(startPlayerScreen, targetPlayerScreen, t: t)
            let curLyrics = self.isLyricsVisible ? Self.lerpRect(startLyricsScreen, targetLyricsScreen, t: t) : .zero
            let curLibrary = self.isLibraryVisible ? Self.lerpRect(startLibraryScreen, targetLibraryScreen, t: t) : .zero

            self.livePlayerScreenRect = curPlayer
            self.liveLyricsScreenRect = curLyrics
            self.liveLibraryScreenRect = curLibrary
            self.liveModeProgress = t

            let localPlayer = curPlayer.offsetBy(dx: -envelope.minX, dy: -envelope.minY)
            self.playerCtrl.applyMorphFrame(slotFrame: localPlayer, targetMini: targetMini, progress: t, scale: s)

            var hitFrames: [NSRect] = [localPlayer]
            if self.isLyricsVisible {
                let localLyrics = curLyrics.offsetBy(dx: -envelope.minX, dy: -envelope.minY)
                self.lyricsView.isHidden = false
                let sizeChanged = self.lyricsView.frame.size != localLyrics.size
                self.lyricsView.frame = localLyrics
                if sizeChanged { self.lyricsView.needsLayout = true }
                let capH = OriginalDesignTokens.BaseMetrics.glassCapHeight * s
                self.lyricsDragHandle.frame = self.lyricsDragHandleFrame(for: localLyrics.size, capHeight: capH)
                hitFrames.append(localLyrics)
            }
            if self.isLibraryVisible {
                let localLib = curLibrary.offsetBy(dx: -envelope.minX, dy: -envelope.minY)
                self.libraryCtrl.moduleView.isHidden = false
                let sizeChanged = self.libraryCtrl.moduleView.frame.size != localLib.size
                self.libraryCtrl.moduleView.frame = localLib
                if sizeChanged { self.libraryCtrl.moduleView.needsLayout = true }
                let capH = OriginalDesignTokens.BaseMetrics.glassCapHeight * s
                self.libraryDragHandle.frame = NSRect(x: 0, y: localLib.height - capH, width: localLib.width, height: capH)
                hitFrames.append(localLib)
            }
            self.stageRootView.interactiveHitFrames = hitFrames
        }

        // Apply Frame 0 immediately to eliminate single-frame flash after hostWindow resize
        applyMorphStep(0.0)

        var elapsed: TimeInterval = 0
        let total = duration
        stageDriverSubID = MotionCoordinator.shared.displayDriver.start { [weak self] dt, _ in
            guard let self, MotionCoordinator.shared.isCurrent(ticket) else { return false }
            elapsed += dt
            let raw = min(1.0, elapsed / max(0.01, total))
            // Smooth ease-out curve for crisp, zero-overshoot crystal morph
            let t = CGFloat(1.0 - pow(1.0 - raw, 3.0))
            applyMorphStep(t)

            if raw >= 1.0 {
                if MotionCoordinator.shared.complete(ticket) {
                    self.stageTicket = nil
                    self.stageDriverSubID = nil
                    self.commitFinalLayout(targetLayout, targetMini: targetMini)
                    completion?(true)
                }
                return false
            }
            return true
        }
    }

    // MARK: - M13 / M14 Module Reveal & Lyrics Resize

    private func runModuleRevealTransition(
        kind: ModuleKind,
        showing: Bool,
        wasVisible: Bool,
        startLayout: StageLayoutOutput,
        unmaskedStartLayout: StageLayoutOutput,
        targetLayout: StageLayoutOutput,
        duration: TimeInterval,
        completion: (@MainActor (Bool) -> Void)? = nil
    ) {
        let s = GlassInteractionCoordinator.shared.uiScale

        if MotionCoordinator.shared.isReduceMotionEnabled {
            cancelAllStageAnimations()
            commitFinalLayout(targetLayout, targetMini: playerCtrl.isMiniMode)
            completion?(true)
            return
        }

        cancelAllStageAnimations()
        let key = TransitionKey(owner: stageOwnerID, channel: "geometry")
        let ticket = MotionCoordinator.shared.beginTransition(for: key, category: .stageGeometry) { [weak self] in
            self?.stopStageDriver()
            completion?(false)
        }
        stageTicket = ticket

        let targetHost = targetLayout.hostFrame
        let startHost = unmaskedStartLayout.hostFrame
        let envelope = startHost.union(targetHost).union(startLayout.hostFrame)

        isAdjustingFrame = true
        if hostWindow.frame != envelope {
            hostWindow.setFrame(envelope, display: false, animate: false)
        }
        stageRootView.frame = NSRect(origin: .zero, size: envelope.size)
        isAdjustingFrame = false

        let targetModuleScreen = (kind == .lyrics ? targetLayout.lyricsFrame : targetLayout.libraryFrame)
            .offsetBy(dx: targetHost.minX, dy: targetHost.minY)
        let startModuleScreen = (kind == .lyrics ? unmaskedStartLayout.lyricsFrame : unmaskedStartLayout.libraryFrame)
            .offsetBy(dx: startHost.minX, dy: startHost.minY)

        let fullScreenRect = showing ? targetModuleScreen : startModuleScreen
        let revealSide: Placement = (kind == .lyrics) ? lyricsPlacement : libraryPlacement
        let startProgress: CGFloat = (kind == .lyrics) ? liveLyricsRevealProgress : liveLibraryRevealProgress
        let endProgress: CGFloat = showing ? 1.0 : 0.0

        let moduleView: NSView = (kind == .lyrics) ? lyricsView : libraryCtrl.moduleView
        let contentAlphaView: NSView = (kind == .lyrics) ? lyricsView.contentContainerView : libraryCtrl.contentContainerView

        // Keep moduleView at full target size during reveal so 150 library cards never re-layout per frame
        let localFullFrame = fullScreenRect.offsetBy(dx: -envelope.minX, dy: -envelope.minY)
        moduleView.isHidden = false
        moduleView.frame = localFullFrame
        moduleView.needsLayout = true
        let capH = OriginalDesignTokens.BaseMetrics.glassCapHeight * s
        if kind == .lyrics {
            lyricsView.isHidden = false
            lyricsView.frame = localFullFrame
            lyricsView.layoutSubtreeIfNeeded()
            lyricsView.refreshGlass()
            lyricsDragHandle.frame = lyricsDragHandleFrame(for: localFullFrame.size, capHeight: capH)
        } else {
            libraryCtrl.moduleView.isHidden = false
            libraryCtrl.moduleView.frame = localFullFrame
            libraryCtrl.moduleView.layoutSubtreeIfNeeded()
            libraryCtrl.moduleView.refreshGlassSurface()
            libraryDragHandle.frame = NSRect(x: 0, y: localFullFrame.height - capH, width: localFullFrame.width, height: capH)
        }

        // Position & settle player + other static module cleanly inside envelope (clears any interrupted M02 morph)
        let targetPlayerLocal = targetLayout.playerFrame.offsetBy(dx: targetHost.minX - envelope.minX, dy: targetHost.minY - envelope.minY)
        playerCtrl.finalizeMorphState(isMini: playerCtrl.isMiniMode, slotFrame: targetPlayerLocal)
        livePlayerScreenRect = targetLayout.playerFrame.offsetBy(dx: targetHost.minX, dy: targetHost.minY)

        if kind == .library && isLyricsVisible {
            let lyrLocal = targetLayout.lyricsFrame.offsetBy(dx: targetHost.minX - envelope.minX, dy: targetHost.minY - envelope.minY)
            lyricsView.isHidden = false
            lyricsView.clearScrollPresentation()
            lyricsView.contentContainerView.alphaValue = 1.0
            lyricsView.frame = lyrLocal
            lyricsDragHandle.frame = lyricsDragHandleFrame(for: lyrLocal.size, capHeight: capH)
            liveLyricsScreenRect = targetLayout.lyricsFrame.offsetBy(dx: targetHost.minX, dy: targetHost.minY)
            liveLyricsRevealProgress = 1.0
        } else if kind == .lyrics && isLibraryVisible {
            let libLocal = targetLayout.libraryFrame.offsetBy(dx: targetHost.minX - envelope.minX, dy: targetHost.minY - envelope.minY)
            libraryCtrl.moduleView.isHidden = false
            libraryCtrl.moduleView.clearScrollPresentation()
            libraryCtrl.contentContainerView.alphaValue = 1.0
            libraryCtrl.moduleView.frame = libLocal
            libraryDragHandle.frame = NSRect(x: 0, y: libLocal.height - capH, width: libLocal.width, height: capH)
            liveLibraryScreenRect = targetLayout.libraryFrame.offsetBy(dx: targetHost.minX, dy: targetHost.minY)
            liveLibraryRevealProgress = 1.0
        }

        let applyRevealStep: (CGFloat) -> Void = { [weak self] p in
            guard let self else { return }
            if kind == .lyrics {
                self.liveLyricsRevealProgress = p
            } else {
                self.liveLibraryRevealProgress = p
            }

            let exposedLocal = Self.applyScrollRevealStep(
                kind: kind,
                moduleView: moduleView,
                contentAlphaView: contentAlphaView,
                dragHandle: (kind == .lyrics) ? self.lyricsDragHandle : self.libraryDragHandle,
                applyScroll: { top, bot, alpha, outer in
                    if kind == .lyrics {
                        self.lyricsView.applyScrollPresentation(topBarFrame: top, bottomBarFrame: bot, barAlpha: alpha, outerClipRect: outer)
                    } else {
                        self.libraryCtrl.moduleView.applyScrollPresentation(topBarFrame: top, bottomBarFrame: bot, barAlpha: alpha, outerClipRect: outer)
                    }
                },
                localFullFrame: localFullFrame,
                localPlayerFrame: targetPlayerLocal,
                placement: revealSide,
                progress: p,
                uiScale: s
            )

            let revealedScreen = exposedLocal.offsetBy(dx: envelope.minX, dy: envelope.minY)
            if kind == .lyrics {
                self.liveLyricsScreenRect = revealedScreen
            } else {
                self.liveLibraryScreenRect = revealedScreen
            }

            var hits: [NSRect] = [targetPlayerLocal]
            if kind == .lyrics {
                if p > 0.02 { hits.append(exposedLocal) }
                if self.isLibraryVisible {
                    hits.append(targetLayout.libraryFrame.offsetBy(dx: targetHost.minX - envelope.minX, dy: targetHost.minY - envelope.minY))
                }
            } else {
                if p > 0.02 { hits.append(exposedLocal) }
                if self.isLyricsVisible {
                    hits.append(targetLayout.lyricsFrame.offsetBy(dx: targetHost.minX - envelope.minX, dy: targetHost.minY - envelope.minY))
                }
            }
            self.stageRootView.interactiveHitFrames = hits
        }

        applyRevealStep(startProgress)

        var elapsed: TimeInterval = 0
        stageDriverSubID = MotionCoordinator.shared.displayDriver.start { [weak self] dt, _ in
            guard let self, MotionCoordinator.shared.isCurrent(ticket) else { return false }
            elapsed += dt
            let raw = min(1.0, elapsed / max(0.01, duration))
            let p = startProgress + (endProgress - startProgress) * CGFloat(raw)
            applyRevealStep(p)

            if raw >= 1.0 {
                if MotionCoordinator.shared.complete(ticket) {
                    self.stageTicket = nil
                    self.stageDriverSubID = nil
                    self.lyricsView.clearScrollPresentation()
                    self.libraryCtrl.moduleView.clearScrollPresentation()
                    contentAlphaView.alphaValue = 1.0
                    self.commitFinalLayout(targetLayout, targetMini: self.playerCtrl.isMiniMode)
                    completion?(true)
                }
                return false
            }
            return true
        }
    }

    private func performLyricsResizeTransition(
        duration: TimeInterval = MotionTokens.Duration.lyricsResize,
        completion: (@MainActor (Bool) -> Void)? = nil
    ) {
        let s = GlassInteractionCoordinator.shared.uiScale
        let startLayout = currentPresentationLayout(scale: s)
        let targetLayout = computeTargetLayout(scale: s)

        if MotionCoordinator.shared.isReduceMotionEnabled || !isLyricsVisible {
            cancelAllStageAnimations()
            relayoutStage()
            if customLyricsOffset != nil { resnapModuleIfNeeded(.lyrics) }
            if customLibraryOffset != nil { resnapModuleIfNeeded(.library) }
            completion?(true)
            return
        }

        cancelAllStageAnimations()
        let key = TransitionKey(owner: stageOwnerID, channel: "geometry")
        let ticket = MotionCoordinator.shared.beginTransition(for: key, category: .stageGeometry) { [weak self] in
            self?.stopStageDriver()
            completion?(false)
        }
        stageTicket = ticket

        let startHost = startLayout.hostFrame
        let targetHost = targetLayout.hostFrame
        let startLyricsScreen = startLayout.lyricsFrame.offsetBy(dx: startHost.minX, dy: startHost.minY)
        let targetLyricsScreen = targetLayout.lyricsFrame.offsetBy(dx: targetHost.minX, dy: targetHost.minY)
        let envelope = startHost.union(targetHost)

        isAdjustingFrame = true
        if hostWindow.frame != envelope {
            hostWindow.setFrame(envelope, display: false, animate: false)
        }
        stageRootView.frame = NSRect(origin: .zero, size: envelope.size)
        isAdjustingFrame = false

        let playerLocal = targetLayout.playerFrame.offsetBy(dx: targetHost.minX - envelope.minX, dy: targetHost.minY - envelope.minY)
        playerCtrl.finalizeMorphState(isMini: playerCtrl.isMiniMode, slotFrame: playerLocal)
        let capH = OriginalDesignTokens.BaseMetrics.glassCapHeight * s

        let applyResizeStep: (CGFloat) -> Void = { [weak self] t in
            guard let self else { return }
            let curLyrics = Self.lerpRect(startLyricsScreen, targetLyricsScreen, t: t)
            self.liveLyricsScreenRect = curLyrics
            let localLyrics = curLyrics.offsetBy(dx: -envelope.minX, dy: -envelope.minY)
            self.lyricsView.isHidden = false
            self.lyricsView.frame = localLyrics
            self.lyricsView.needsLayout = true
            self.lyricsDragHandle.frame = self.lyricsDragHandleFrame(for: localLyrics.size, capHeight: capH)

            var hits: [NSRect] = [playerLocal, localLyrics]
            if self.isLibraryVisible {
                let libLocal = targetLayout.libraryFrame.offsetBy(dx: targetHost.minX - envelope.minX, dy: targetHost.minY - envelope.minY)
                self.libraryCtrl.moduleView.frame = libLocal
                self.libraryDragHandle.frame = NSRect(x: 0, y: libLocal.height - capH, width: libLocal.width, height: capH)
                hits.append(libLocal)
            }
            self.stageRootView.interactiveHitFrames = hits
        }

        applyResizeStep(0.0)

        var elapsed: TimeInterval = 0
        let total = duration
        stageDriverSubID = MotionCoordinator.shared.displayDriver.start { [weak self] dt, _ in
            guard let self, MotionCoordinator.shared.isCurrent(ticket) else { return false }
            elapsed += dt
            let raw = min(1.0, elapsed / max(0.01, total))
            let t = CGFloat(1.0 - pow(1.0 - raw, 3.0))
            applyResizeStep(t)

            if raw >= 1.0 {
                if MotionCoordinator.shared.complete(ticket) {
                    self.stageTicket = nil
                    self.stageDriverSubID = nil
                    self.commitFinalLayout(targetLayout, targetMini: self.playerCtrl.isMiniMode)
                    if self.customLyricsOffset != nil { self.resnapModuleIfNeeded(.lyrics) }
                    if self.customLibraryOffset != nil { self.resnapModuleIfNeeded(.library) }
                    completion?(true)
                }
                return false
            }
            return true
        }
    }

    // MARK: - M12 Magnetic Snap with Hysteresis & Haptic

    /// Snaps the dragged module to the nearest valid edge of the remaining visible modules (gap = 0, no overlap).
    private func snapDroppedModule(_ kind: ModuleKind, droppedOrigin: NSPoint, precomputedSnap: StageSnapResult? = nil) {
        let s = GlassInteractionCoordinator.shared.uiScale
        let (playerSize, lyricsSize, librarySize) = currentModuleSizes(scale: s)
        let movedSize = (kind == .lyrics) ? lyricsSize : librarySize
        let playerScreenRect = NSRect(origin: playerScreenOrigin, size: playerSize)
        let otherRect: CGRect? = {
            if kind == .lyrics && isLibraryVisible { return screenRect(for: .library) }
            if kind == .library && isLyricsVisible { return screenRect(for: .lyrics) }
            return nil
        }()

        let snap = precomputedSnap ?? StageLayoutEngine.computeSnap(
            movedSize: movedSize,
            droppedOrigin: droppedOrigin,
            playerScreenRect: playerScreenRect,
            otherModuleScreenRect: otherRect,
            uiScale: s,
            wasAlreadySnapped: false,
            visibleFrames: Self.screenVisibleFrames()
        )

        if snap.didSnap, let offset = snap.snappedOffset {
            if kind == .lyrics {
                customLyricsOffset = offset
            } else {
                customLibraryOffset = offset
            }
            // M12: Trigger alignment haptic at most once per completed snap
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        }

        let targetLayout = computeTargetLayout(scale: s)
        let targetScreenOrigin = CGPoint(
            x: targetLayout.hostFrame.minX + (kind == .lyrics ? targetLayout.lyricsFrame.minX : targetLayout.libraryFrame.minX),
            y: targetLayout.hostFrame.minY + (kind == .lyrics ? targetLayout.lyricsFrame.minY : targetLayout.libraryFrame.minY)
        )

        if MotionCoordinator.shared.isReduceMotionEnabled || hypot(targetScreenOrigin.x - droppedOrigin.x, targetScreenOrigin.y - droppedOrigin.y) < 1.0 {
            relayoutStage()
            return
        }

        // M12: 180–240ms spring settle from dropped origin to snapped position
        cancelSnapAnimation()
        let key = TransitionKey(owner: stageOwnerID, channel: "snap")
        let ticket = MotionCoordinator.shared.beginTransition(for: key, category: .stageGeometry) { [weak self] in
            self?.stopSnapDriver()
        }
        snapTicket = ticket

        var elapsed: TimeInterval = 0
        let total = MotionTokens.Duration.dockSnap
        let startOrigin = droppedOrigin
        snapDriverSubID = MotionCoordinator.shared.displayDriver.start { [weak self] dt, _ in
            guard let self, MotionCoordinator.shared.isCurrent(ticket) else { return false }
            elapsed += dt
            let raw = min(1.0, elapsed / max(0.01, total))
            let t = CGFloat(1.0 - pow(1.0 - raw, 3.0))

            let curOrigin = CGPoint(
                x: startOrigin.x + (targetScreenOrigin.x - startOrigin.x) * t,
                y: startOrigin.y + (targetScreenOrigin.y - startOrigin.y) * t
            )
            self.activeSnapModule = kind
            self.liveSnapScreenOrigin = curOrigin
            self.relayoutStage()

            if raw >= 1.0 {
                self.activeSnapModule = nil
                if MotionCoordinator.shared.complete(ticket) {
                    self.snapTicket = nil
                    self.snapDriverSubID = nil
                    self.relayoutStage()
                }
                return false
            }
            return true
        }
    }

    private func resnapModuleIfNeeded(_ kind: ModuleKind) {
        let cur = screenRect(for: kind)
        snapDroppedModule(kind, droppedOrigin: cur.origin)
    }

    private func chooseAdaptiveLibraryPlacementForMiniMode() {
        let s = GlassInteractionCoordinator.shared.uiScale
        let (playerSize, _, libSize) = currentModuleSizes(scale: s)
        let vf = (hostWindow.screen ?? NSScreen.main)?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let pRect = NSRect(origin: playerScreenOrigin, size: playerSize)
        libraryPlacement = StageLayoutEngine.adaptiveLibraryPlacementForMiniMode(
            playerRect: pRect,
            librarySize: libSize,
            visibleFrame: vf
        )
    }

    private func currentModuleSizes(scale s: CGFloat) -> (player: NSSize, lyrics: NSSize, library: NSSize) {
        let playerSize = playerCtrl.preferredPlayerSize(for: s)
        let lyricsSize = lyricsView.preferredSize(for: s)
        var librarySize = libraryCtrl.preferredSize(for: s)
        librarySize.width = playerSize.width
        return (playerSize, lyricsSize, librarySize)
    }

    private func computeTargetLayout(scale s: CGFloat) -> StageLayoutOutput {
        let (playerSize, lyricsSize, librarySize) = currentModuleSizes(scale: s)
        let dragLyricsOrigin = (activeDragModule == .lyrics)
            ? liveDragScreenOrigin
            : (activeSnapModule == .lyrics ? liveSnapScreenOrigin : nil)
        let dragLibraryOrigin = (activeDragModule == .library)
            ? liveDragScreenOrigin
            : (activeSnapModule == .library ? liveSnapScreenOrigin : nil)
        let input = StageLayoutInput(
            uiScale: s,
            playerScreenOrigin: playerScreenOrigin,
            playerSize: playerSize,
            lyricsSize: lyricsSize,
            librarySize: librarySize,
            isMiniMode: playerCtrl.isMiniMode,
            isLyricsVisible: isLyricsVisible,
            isLibraryVisible: isLibraryVisible,
            lyricsPlacement: lyricsPlacement,
            libraryPlacement: libraryPlacement,
            customLyricsOffset: customLyricsOffset,
            customLibraryOffset: customLibraryOffset,
            activeDragLyricsOrigin: dragLyricsOrigin,
            activeDragLibraryOrigin: dragLibraryOrigin
        )
        return StageLayoutEngine.solve(input)
    }

    private func currentPresentationLayout(scale s: CGFloat) -> StageLayoutOutput {
        if stageTicket != nil {
            let includeLyrics = (isLyricsVisible || liveLyricsRevealProgress > 0.005) && liveLyricsScreenRect != .zero
            let includeLibrary = (isLibraryVisible || liveLibraryRevealProgress > 0.005) && liveLibraryScreenRect != .zero
            let host = livePlayerScreenRect
                .union(includeLyrics ? liveLyricsScreenRect : livePlayerScreenRect)
                .union(includeLibrary ? liveLibraryScreenRect : livePlayerScreenRect)
            let pLocal = livePlayerScreenRect.offsetBy(dx: -host.minX, dy: -host.minY)
            let lLocal = includeLyrics ? liveLyricsScreenRect.offsetBy(dx: -host.minX, dy: -host.minY) : .zero
            let libLocal = includeLibrary ? liveLibraryScreenRect.offsetBy(dx: -host.minX, dy: -host.minY) : .zero
            var hits: [CGRect] = [pLocal]
            if lLocal != .zero { hits.append(lLocal) }
            if libLocal != .zero { hits.append(libLocal) }
            return StageLayoutOutput(
                hostFrame: host,
                playerFrame: pLocal,
                lyricsFrame: lLocal,
                libraryFrame: libLocal,
                interactiveHitFrames: hits
            )
        }
        let pLocal = playerCtrl.playerSlotView.frame
        if pLocal.width > 1.0 && pLocal.height > 1.0 {
            let host = hostWindow.frame
            let lLocal = (isLyricsVisible && !lyricsView.isHidden && lyricsView.frame.width > 1.0) ? lyricsView.frame : .zero
            let libLocal = (isLibraryVisible && !libraryCtrl.moduleView.isHidden && libraryCtrl.moduleView.frame.width > 1.0) ? libraryCtrl.moduleView.frame : .zero
            var hits: [CGRect] = [pLocal]
            if lLocal != .zero { hits.append(lLocal) }
            if libLocal != .zero { hits.append(libLocal) }
            return StageLayoutOutput(
                hostFrame: host,
                playerFrame: pLocal,
                lyricsFrame: lLocal,
                libraryFrame: libLocal,
                interactiveHitFrames: hits
            )
        }
        return computeTargetLayout(scale: s)
    }

    public func currentStageLayoutSnapshot() -> StageLayoutOutput {
        let s = GlassInteractionCoordinator.shared.uiScale
        return currentPresentationLayout(scale: s)
    }

    /// Recomputes module frames relative to `playerScreenOrigin` and resizes `hostWindow`
    /// while keeping the player module pinned at `playerScreenOrigin`.
    public func relayoutStage() {
        let s = GlassInteractionCoordinator.shared.uiScale
        let output = computeTargetLayout(scale: s)
        commitFinalLayout(output, targetMini: playerCtrl.isMiniMode)
    }

    private func commitFinalLayout(_ output: StageLayoutOutput, targetMini: Bool) {
        let s = GlassInteractionCoordinator.shared.uiScale
        let capH = OriginalDesignTokens.BaseMetrics.glassCapHeight * s

        isAdjustingFrame = true
        let prevHostSize = hostWindow.frame.size
        if hostWindow.frame != output.hostFrame {
            hostWindow.setFrame(output.hostFrame, display: false, animate: false)
        }
        stageRootView.frame = NSRect(origin: .zero, size: output.hostFrame.size)
        stageRootView.interactiveHitFrames = output.interactiveHitFrames

        playerCtrl.finalizeMorphState(isMini: targetMini, slotFrame: output.playerFrame)

        let wasLyricsHidden = lyricsView.isHidden
        lyricsView.isHidden = !isLyricsVisible
        lyricsView.layer?.mask = nil
        lyricsView.contentContainerView.alphaValue = 1.0
        if isLyricsVisible {
            let sizeChanged = lyricsView.frame.size != output.lyricsFrame.size
            lyricsView.frame = output.lyricsFrame
            if sizeChanged || wasLyricsHidden {
                lyricsView.needsLayout = true
            }
            Self.applyModuleShadow(to: lyricsView, bounds: NSRect(origin: .zero, size: output.lyricsFrame.size), cornerRadius: OriginalDesignTokens.BaseMetrics.glassCornerRadius * s)
            lyricsDragHandle.frame = lyricsDragHandleFrame(for: output.lyricsFrame.size, capHeight: capH)
        }

        let wasLibraryHidden = libraryCtrl.moduleView.isHidden
        libraryCtrl.moduleView.isHidden = !isLibraryVisible
        libraryCtrl.moduleView.layer?.mask = nil
        libraryCtrl.contentContainerView.alphaValue = 1.0
        if isLibraryVisible {
            let sizeChanged = libraryCtrl.moduleView.frame.size != output.libraryFrame.size
            libraryCtrl.moduleView.frame = output.libraryFrame
            if sizeChanged || wasLibraryHidden {
                libraryCtrl.moduleView.needsLayout = true
            }
            Self.applyModuleShadow(to: libraryCtrl.moduleView, bounds: NSRect(origin: .zero, size: output.libraryFrame.size), cornerRadius: OriginalDesignTokens.BaseMetrics.glassCornerRadius * s)
            libraryDragHandle.frame = NSRect(x: 0, y: output.libraryFrame.height - capH, width: output.libraryFrame.width, height: capH)
        }

        let pCorner = targetMini
            ? min(OriginalDesignTokens.BaseMetrics.miniBarStandardHeight * s * 0.5, OriginalDesignTokens.BaseMetrics.glassCornerRadius * s)
            : OriginalDesignTokens.BaseMetrics.glassCornerRadius * s
        Self.applyModuleShadow(to: playerCtrl.playerSlotView, bounds: NSRect(origin: .zero, size: output.playerFrame.size), cornerRadius: pCorner)

        livePlayerScreenRect = output.playerFrame.offsetBy(dx: output.hostFrame.minX, dy: output.hostFrame.minY)
        liveLyricsScreenRect = isLyricsVisible ? output.lyricsFrame.offsetBy(dx: output.hostFrame.minX, dy: output.hostFrame.minY) : .zero
        liveLibraryScreenRect = isLibraryVisible ? output.libraryFrame.offsetBy(dx: output.hostFrame.minX, dy: output.hostFrame.minY) : .zero
        liveLyricsRevealProgress = isLyricsVisible ? 1.0 : 0.0
        liveLibraryRevealProgress = isLibraryVisible ? 1.0 : 0.0
        liveModeProgress = 1.0

        _ = prevHostSize
        hostWindow.refreshMenuStates()
        isAdjustingFrame = false
    }

    private func lyricsDragHandleFrame(for lyricsSize: NSSize, capHeight: CGFloat) -> NSRect {
        let h = lyricsView.isMiniLyricsMode ? lyricsSize.height : capHeight
        return NSRect(x: 0, y: lyricsSize.height - h, width: lyricsSize.width, height: h)
    }

    private static func applyModuleShadow(to view: NSView, bounds: CGRect, cornerRadius: CGFloat) {
        view.wantsLayer = true
        guard let layer = view.layer else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.shadowColor = NSColor.black.cgColor
        layer.shadowOpacity = 0.28
        layer.shadowRadius = 9.0
        layer.shadowOffset = CGSize(width: 0, height: -3.0)
        layer.shadowPath = CGPath(roundedRect: bounds, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)
        CATransaction.commit()
    }

    // MARK: - Cancellation & Cleanup

    private func cancelStageGeometryAnimation() {
        MotionCoordinator.shared.cancel(key: TransitionKey(owner: stageOwnerID, channel: "geometry"))
        stopStageDriver()
        lyricsView.clearScrollPresentation()
        libraryCtrl.moduleView.clearScrollPresentation()
        lyricsView.contentContainerView.alphaValue = 1.0
        libraryCtrl.contentContainerView.alphaValue = 1.0
    }

    private func stopStageDriver() {
        if let subID = stageDriverSubID {
            MotionCoordinator.shared.displayDriver.stop(id: subID)
            stageDriverSubID = nil
        }
        stageTicket = nil
    }

    private func cancelSnapAnimation() {
        MotionCoordinator.shared.cancel(key: TransitionKey(owner: stageOwnerID, channel: "snap"))
        stopSnapDriver()
        activeSnapModule = nil
    }

    private func stopSnapDriver() {
        if let subID = snapDriverSubID {
            MotionCoordinator.shared.displayDriver.stop(id: subID)
            snapDriverSubID = nil
        }
        snapTicket = nil
    }

    private func cancelAllStageAnimations() {
        cancelStageGeometryAnimation()
        cancelSnapAnimation()
    }

    // MARK: - Notifications

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

    @objc private func handleWindowDidDeminiaturize() {
        relayoutStage()
        playChoreographedStageOpen()
    }

    @objc private func handleScaleOrModeChange() {
        cancelAllStageAnimations()
        let s = GlassInteractionCoordinator.shared.uiScale
        let newSize = playerCtrl.preferredPlayerSize(for: s)
        playerScreenOrigin = StageLayoutEngine.anchoredOriginForHeightChange(
            currentOrigin: playerScreenOrigin,
            oldSize: NSSize(width: newSize.width, height: lastPlayerHeight),
            newSize: newSize,
            visibleFrames: Self.screenVisibleFrames()
        )
        lastPlayerHeight = newSize.height
        customLyricsOffset = nil
        customLibraryOffset = nil
        relayoutStage()
        hostWindow.refreshMenuStates()
    }

    @objc private func handleScreenParametersChanged() {
        cancelAllStageAnimations()
        let s = GlassInteractionCoordinator.shared.uiScale
        let visibleFrames = Self.screenVisibleFrames()
        let fullLayout = computeTargetLayout(scale: s)
        let clampedHostOrigin = StageLayoutEngine.clampOrigin(
            fullLayout.hostFrame.origin,
            size: fullLayout.hostFrame.size,
            visibleFrames: visibleFrames
        )
        let deltaX = clampedHostOrigin.x - fullLayout.hostFrame.minX
        let deltaY = clampedHostOrigin.y - fullLayout.hostFrame.minY
        let candidatePlayerOrigin = NSPoint(x: playerScreenOrigin.x + deltaX, y: playerScreenOrigin.y + deltaY)
        let playerSize = playerCtrl.preferredPlayerSize(for: s)
        playerScreenOrigin = StageLayoutEngine.clampOrigin(
            candidatePlayerOrigin,
            size: playerSize,
            visibleFrames: visibleFrames
        )
        RenderCache.shared.invalidateAll()
        relayoutStage()
    }

    @objc private func handleAccessibilityChanged() {
        if MotionCoordinator.shared.isReduceMotionEnabled && isStageTransitioning {
            cancelAllStageAnimations()
            relayoutStage()
        }
    }

    // MARK: - Geometry Helpers

    private static func screenVisibleFrames() -> [CGRect] {
        let screens = NSScreen.screens.map(\.visibleFrame)
        if !screens.isEmpty { return screens }
        return [NSScreen.main?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)]
    }

    private static func lerpRect(_ a: CGRect, _ b: CGRect, t: CGFloat) -> CGRect {
        CGRect(
            x: a.minX + (b.minX - a.minX) * t,
            y: a.minY + (b.minY - a.minY) * t,
            width: a.width + (b.width - a.width) * t,
            height: a.height + (b.height - a.height) * t
        )
    }

    /// Shared 2-phase glass-bar scroll geometry for Lyrics & Library panels.
    /// - Lyrics (`.bottom`): Phase 1 slides the 2 joined glass bars down from Main's bottom edge; Phase 2 moves the bottom bar down to unroll the panel.
    /// - Library (`.right`): Phase 1 slides the 2 joined glass bars left-to-right out of Main's right edge; Phase 2 moves the bottom bar down to unroll the panel.
    /// Collapse is the exact reverse (`progress: 1 -> 0`).
    /// Returns the currently exposed screen-aligned frame in host coordinates.
    private static func applyScrollRevealStep(
        kind: ModuleKind,
        moduleView: NSView,
        contentAlphaView: NSView,
        dragHandle: NSView,
        applyScroll: (NSRect, NSRect, CGFloat, NSRect) -> Void,
        localFullFrame: NSRect,
        localPlayerFrame: NSRect,
        placement: Placement,
        progress rawP: CGFloat,
        uiScale s: CGFloat
    ) -> NSRect {
        let p = min(max(rawP, 0.0), 1.0)
        let w = localFullFrame.width
        let h = localFullFrame.height
        let capH = OriginalDesignTokens.BaseMetrics.glassCapHeight * s
        let collapsedH = min(h, capH * 2.0)
        let split: CGFloat = 0.36

        let easeOut: (CGFloat) -> CGFloat = { t in
            let c = min(max(t, 0.0), 1.0)
            return 1.0 - pow(1.0 - c, 3.0)
        }

        if p <= split {
            let q1 = easeOut(p / split)
            contentAlphaView.alphaValue = 0.0
            moduleView.isHidden = (p <= 0.002)

            switch (kind, placement) {
            case (.library, .right):
                // Phase 1: collapsed 2-bar header slides left-to-right out from behind Main Player
                let offsetX = w * (1.0 - q1)
                let curX = (localPlayerFrame.maxX - w) + (localFullFrame.minX - (localPlayerFrame.maxX - w)) * q1
                moduleView.frame = NSRect(x: curX, y: localFullFrame.minY, width: w, height: h)
                let topBar = NSRect(x: 0, y: h - capH, width: w, height: capH)
                let botBar = NSRect(x: 0, y: h - collapsedH, width: w, height: capH)
                let visibleW = max(1.0, w - offsetX)
                let outerClip = NSRect(x: offsetX, y: h - collapsedH, width: visibleW, height: collapsedH)
                applyScroll(topBar, botBar, max(0.05, q1), outerClip)
                dragHandle.frame = topBar
                return outerClip.offsetBy(dx: moduleView.frame.minX, dy: moduleView.frame.minY)

            case (.library, .left):
                // Mirror for left placement: slide right-to-left out of Main's left edge
                let curX = localPlayerFrame.minX - w * q1
                moduleView.frame = NSRect(x: curX, y: localFullFrame.minY, width: w, height: h)
                let topBar = NSRect(x: 0, y: h - capH, width: w, height: capH)
                let botBar = NSRect(x: 0, y: h - collapsedH, width: w, height: capH)
                let visibleW = max(1.0, w * q1)
                let outerClip = NSRect(x: 0, y: h - collapsedH, width: visibleW, height: collapsedH)
                applyScroll(topBar, botBar, max(0.05, q1), outerClip)
                dragHandle.frame = topBar
                return outerClip.offsetBy(dx: moduleView.frame.minX, dy: moduleView.frame.minY)

            case (_, .top):
                // Emerge upward out of Main's top edge
                let offsetY = collapsedH * (1.0 - q1)
                moduleView.frame = NSRect(x: localFullFrame.minX, y: localFullFrame.minY - offsetY, width: w, height: h)
                let topBar = NSRect(x: 0, y: collapsedH - capH, width: w, height: capH)
                let botBar = NSRect(x: 0, y: 0, width: w, height: capH)
                let visibleH = max(1.0, collapsedH * q1)
                let outerClip = NSRect(x: 0, y: offsetY, width: w, height: visibleH)
                applyScroll(topBar, botBar, max(0.05, q1), outerClip)
                dragHandle.frame = topBar
                return outerClip.offsetBy(dx: moduleView.frame.minX, dy: moduleView.frame.minY)

            default:
                // Canonical Lyrics `.bottom` (or fallback): two glass bars slide top-to-bottom out of Main's bottom edge
                let offsetY = collapsedH * (1.0 - q1)
                moduleView.frame = NSRect(x: localFullFrame.minX, y: localFullFrame.minY + offsetY, width: w, height: h)
                let topBar = NSRect(x: 0, y: h - capH, width: w, height: capH)
                let botBar = NSRect(x: 0, y: h - collapsedH, width: w, height: capH)
                let visibleH = max(1.0, collapsedH * q1)
                let outerClip = NSRect(x: 0, y: h - collapsedH, width: w, height: visibleH)
                applyScroll(topBar, botBar, max(0.05, q1), outerClip)
                dragHandle.frame = topBar
                return outerClip.offsetBy(dx: moduleView.frame.minX, dy: moduleView.frame.minY)
            }
        } else {
            // Phase 2 (0.36 .. 1.00): Top bar is anchored, bottom bar sweeps downward from top to bottom (mirror for `.top`)
            let q2 = easeOut((p - split) / (1.0 - split))
            moduleView.isHidden = false
            moduleView.frame = localFullFrame

            if placement == .top {
                let botBar = NSRect(x: 0, y: 0, width: w, height: capH)
                let topY = (collapsedH - capH) + ((h - capH) - (collapsedH - capH)) * q2
                let topBar = NSRect(x: 0, y: topY, width: w, height: capH)
                let outerClip = NSRect(x: 0, y: 0, width: w, height: topY + capH)
                applyScroll(topBar, botBar, 1.0, outerClip)
                dragHandle.frame = topBar
                contentAlphaView.alphaValue = q2 <= 0.20 ? 0.0 : min(1.0, (q2 - 0.20) / 0.72)
                return outerClip.offsetBy(dx: localFullFrame.minX, dy: localFullFrame.minY)
            } else {
                let topBar = NSRect(x: 0, y: h - capH, width: w, height: capH)
                let botY = (h - collapsedH) * (1.0 - q2)
                let botBar = NSRect(x: 0, y: botY, width: w, height: capH)
                let outerClip = NSRect(x: 0, y: botY, width: w, height: h - botY)
                applyScroll(topBar, botBar, 1.0, outerClip)
                dragHandle.frame = topBar
                contentAlphaView.alphaValue = q2 <= 0.20 ? 0.0 : min(1.0, (q2 - 0.20) / 0.72)
                return outerClip.offsetBy(dx: localFullFrame.minX, dy: localFullFrame.minY)
            }
        }
    }
}
