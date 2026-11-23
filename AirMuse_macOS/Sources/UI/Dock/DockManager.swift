import AppKit
import DesignSystem

// MARK: - DockManager

/// Coordinates multi-window magnetic snapping and synchronous movement across
/// independent Main/Mini player windows, Lyrics window, and Library window.
@MainActor
public final class DockManager {

    public enum DockSide {
        case none
        case top
        case bottom
        case left
        case right
    }

    private weak var mainWindow: NSWindow?
    private weak var miniWindow: NSWindow?
    private weak var lyricsWindow: NSWindow?
    private weak var libraryWindow: NSWindow?

    public var isLyricsDocked: Bool = true
    public var lyricsDockSide: DockSide = .bottom

    public var isLibraryDocked: Bool = true
    public var libraryDockSide: DockSide = .right

    private var isSyncing: Bool = false

    private var snapThreshold: CGFloat {
        OriginalDesignTokens.BaseMetrics.dockSnapDistance * GlassInteractionCoordinator.shared.uiScale
    }

    private var overlap: CGFloat {
        let s = GlassInteractionCoordinator.shared.uiScale
        let miniActive = (miniWindow?.isVisible == true) || ((lyricsWindow?.frame.height ?? 999) <= 70)
        return miniActive ? 0.0 : (OriginalDesignTokens.BaseMetrics.dockOverlap * s)
    }

    private var activeAnchorWindow: NSWindow? {
        if let mini = miniWindow, mini.isVisible {
            return mini
        }
        return mainWindow
    }

    public init() {}

    public func attachWindows(main: NSWindow, mini: NSWindow? = nil, lyrics: NSWindow?, library: NSWindow?) {
        self.mainWindow = main
        self.miniWindow = mini
        self.lyricsWindow = lyrics
        self.libraryWindow = library

        NotificationCenter.default.addObserver(self, selector: #selector(windowDidMove(_:)), name: NSWindow.didMoveNotification, object: main)
        if let mini {
            NotificationCenter.default.addObserver(self, selector: #selector(windowDidMove(_:)), name: NSWindow.didMoveNotification, object: mini)
        }
        NotificationCenter.default.addObserver(self, selector: #selector(childWindowDidMove(_:)), name: NSWindow.didMoveNotification, object: lyrics)
        NotificationCenter.default.addObserver(self, selector: #selector(childWindowDidMove(_:)), name: NSWindow.didMoveNotification, object: library)

        syncAllDocked()
    }

    public func syncAllDocked() {
        guard let main = activeAnchorWindow, !isSyncing else { return }
        isSyncing = true
        defer { isSyncing = false }

        let mainFrame = main.frame
        let ov = overlap

        // Sync Lyrics Window
        if let lyrics = lyricsWindow, isLyricsDocked {
            var lyricsFrame = lyrics.frame
            lyricsFrame.origin.x = mainFrame.origin.x

            if lyricsDockSide == .bottom {
                lyricsFrame.origin.y = mainFrame.minY - lyricsFrame.height + ov
            } else if lyricsDockSide == .top {
                lyricsFrame.origin.y = mainFrame.maxY - ov
            } else if lyricsDockSide == .left {
                lyricsFrame.origin.x = mainFrame.minX - lyricsFrame.width + ov
                lyricsFrame.origin.y = mainFrame.maxY - lyricsFrame.height
            } else if lyricsDockSide == .right {
                lyricsFrame.origin.x = mainFrame.maxX - ov
                lyricsFrame.origin.y = mainFrame.maxY - lyricsFrame.height
            }
            lyrics.setFrame(lyricsFrame, display: true, animate: false)
        }

        // Sync Library Window
        if let library = libraryWindow, isLibraryDocked {
            var libFrame = library.frame
            libFrame.origin.y = mainFrame.maxY - libFrame.height

            if libraryDockSide == .right {
                libFrame.origin.x = mainFrame.maxX - ov
            } else if libraryDockSide == .left {
                libFrame.origin.x = mainFrame.minX - libFrame.width + ov
            }
            library.setFrame(libFrame, display: true, animate: false)
        }
    }

    @objc private func windowDidMove(_ notification: Notification) {
        guard !isSyncing, let sender = notification.object as? NSWindow, sender === activeAnchorWindow else { return }
        syncAllDocked()
    }

    @objc private func childWindowDidMove(_ notification: Notification) {
        guard !isSyncing, let main = activeAnchorWindow, let child = notification.object as? NSWindow else { return }

        let mainFrame = main.frame
        let childFrame = child.frame
        let threshold = snapThreshold
        let ov = overlap

        if child === lyricsWindow {
            let bottomDist = abs(childFrame.maxY - (mainFrame.minY + ov))
            let topDist = abs(childFrame.minY - (mainFrame.maxY - ov))
            let xAlign = abs(childFrame.minX - mainFrame.minX)

            if xAlign < threshold * 2 {
                if bottomDist < threshold {
                    isLyricsDocked = true
                    lyricsDockSide = .bottom
                    syncAllDocked()
                    return
                } else if topDist < threshold {
                    isLyricsDocked = true
                    lyricsDockSide = .top
                    syncAllDocked()
                    return
                }
            }
            isLyricsDocked = false
        } else if child === libraryWindow {
            let rightDist = abs(childFrame.minX - (mainFrame.maxX - ov))
            let leftDist = abs(childFrame.maxX - (mainFrame.minX + ov))

            if rightDist < threshold {
                isLibraryDocked = true
                libraryDockSide = .right
                syncAllDocked()
            } else if leftDist < threshold {
                isLibraryDocked = true
                libraryDockSide = .left
                syncAllDocked()
            } else {
                isLibraryDocked = false
            }
        }
    }
}
