import AppKit
import Domain
import DesignSystem
import Playback
import Lyrics

// MARK: - LyricsWindow

/// Floating transparent glass window for synced lyrics overlay.
open class LyricsWindow: NSPanel {

    public let lyricsView = LyricsView()
    private let panel = GlassPanel()
    private let closeButton = GlassButton(image: NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close"), size: CGSize(width: 21, height: 21))

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
        hasShadow = true
        isMovableByWindowBackground = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        setupContent()
    }

    private func setupContent() {
        contentView = panel

        lyricsView.autoresizingMask = [.width, .height]
        panel.contentView.addSubview(lyricsView)

        panel.onLayout = { [weak self] bounds in
            guard let self else { return }
            self.lyricsView.frame = bounds
            self.closeButton.frame = NSRect(x: self.panel.bounds.width - 33, y: self.panel.bounds.height - 33, width: 21, height: 21)
        }

        closeButton.onClick = { [weak self] in
            self?.orderOut(nil)
        }
        panel.addSubview(closeButton)
    }

    open override func layoutIfNeeded() {
        super.layoutIfNeeded()
        closeButton.frame = NSRect(x: panel.bounds.width - 33, y: panel.bounds.height - 33, width: 21, height: 21)
    }
}

