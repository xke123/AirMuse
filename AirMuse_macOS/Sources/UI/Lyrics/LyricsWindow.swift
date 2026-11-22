import AppKit
import Domain
import DesignSystem
import Playback
import Lyrics

// MARK: - LyricsWindow

/// Floating AIRPLAY crystal glass window for synced lyrics overlay.
/// Top glass bar hosts the close & mini-lyrics toggle buttons using original `WINDOWBUTTON` sprites.
open class LyricsWindow: NSPanel {

    public let lyricsView = LyricsView()
    private let panel = GlassPanel()
    private let closeButton = GlassButton(sprite: nil, size: CGSize(width: 13, height: 13))
    private let miniToggleButton = GlassButton(sprite: nil, size: CGSize(width: 13, height: 13))

    public private(set) var isMiniLyricsMode: Bool = false

    public init(frame: NSRect) {
        super.init(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        isFloatingPanel = true
        level = .floating
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isMovableByWindowBackground = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        animationBehavior = .none

        setupContent()
    }

    private func setupContent() {
        contentView = panel

        lyricsView.autoresizingMask = [.width, .height]
        panel.contentView.addSubview(lyricsView)

        closeButton.toolTip = "关闭歌词"
        closeButton.onClick = { [weak self] in
            self?.orderOut(nil)
        }
        panel.addSubview(closeButton)

        miniToggleButton.toolTip = "切换迷你歌词条"
        miniToggleButton.onClick = { [weak self] in
            self?.toggleMiniLyricsMode()
        }
        panel.addSubview(miniToggleButton)

        panel.onLayout = { [weak self] bounds in
            guard let self else { return }
            self.lyricsView.frame = bounds
            self.layoutTopBarButtons()
        }

        reloadSprites()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleSkinChange),
            name: GlassInteractionCoordinator.modeDidChangeNotification,
            object: nil
        )
    }

    @objc private func handleSkinChange() {
        reloadSprites()
        layoutTopBarButtons()
        panel.refreshGlassSurface()
    }

    private func reloadSprites() {
        let res = GlassInteractionCoordinator.shared.resolutionMode
        closeButton.spriteImage = SkinAtlas.shared.windowButton(.close, resolution: res)
        miniToggleButton.spriteImage = SkinAtlas.shared.windowButton(.miniToggle, resolution: res)
    }

    private func layoutTopBarButtons() {
        let s = GlassInteractionCoordinator.shared.uiScale
        let wb = 13.0 * s
        let topY = isMiniLyricsMode ? (panel.bounds.height - wb) * 0.5 : (panel.bounds.height - 4.0 * s - wb)
        closeButton.frame = NSRect(x: panel.bounds.width - 45.0 * s, y: topY, width: wb, height: wb)
        miniToggleButton.frame = NSRect(x: panel.bounds.width - 63.0 * s, y: topY, width: wb, height: wb)
    }

    public func toggleMiniLyricsMode() {
        isMiniLyricsMode.toggle()
        lyricsView.setMiniMode(isMiniLyricsMode)
        let s = GlassInteractionCoordinator.shared.uiScale
        let targetH = (isMiniLyricsMode ? OriginalDesignTokens.BaseMetrics.miniBarStandardHeight : OriginalDesignTokens.BaseMetrics.lyricsWindowHeight) * s
        let f = frame
        let newFrame = NSRect(x: f.minX, y: f.maxY - targetH, width: f.width, height: targetH)
        MotionCoordinator.shared.animate(duration: MotionTokens.Duration.miniToggle) {
            self.setFrame(newFrame, display: true, animate: false)
        }
    }

    open override func layoutIfNeeded() {
        super.layoutIfNeeded()
        layoutTopBarButtons()
    }
}
