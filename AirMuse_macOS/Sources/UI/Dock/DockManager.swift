import AppKit
import DesignSystem

// MARK: - DockManager

/// Coordinates multi-window magnetic snapping and synchronous movement.
/// Ported and adapted from Windows DockManager.cpp.
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
    private weak var lyricsWindow: NSWindow?
    private weak var libraryWindow: NSWindow?

    public var isLyricsDocked: Bool = true
    public var lyricsDockSide: DockSide = .bottom

    public var isLibraryDocked: Bool = true
    public var libraryDockSide: DockSide = .right

    private var isSyncing: Bool = false
    private let snapThreshold: CGFloat = DesignTokens.Metrics.snapDistance

    public init() {}

    public func attachWindows(main: NSWindow, lyrics: NSWindow?, library: NSWindow?) {
        self.mainWindow = main
        self.lyricsWindow = lyrics
        self.libraryWindow = library

        NotificationCenter.default.addObserver(self, selector: #selector(windowDidMove(_:)), name: NSWindow.didMoveNotification, object: main)
        NotificationCenter.default.addObserver(self, selector: #selector(childWindowDidMove(_:)), name: NSWindow.didMoveNotification, object: lyrics)
        NotificationCenter.default.addObserver(self, selector: #selector(childWindowDidMove(_:)), name: NSWindow.didMoveNotification, object: library)

        syncAllDocked()
    }

    public func syncAllDocked() {
        guard let main = mainWindow, !isSyncing else { return }
        isSyncing = true
        defer { isSyncing = false }

        let mainFrame = main.frame

        // Sync Lyrics Window
        if let lyrics = lyricsWindow, isLyricsDocked, lyrics.isVisible {
            var lyricsFrame = lyrics.frame
            lyricsFrame.origin.x = mainFrame.origin.x

            if lyricsDockSide == .bottom {
                lyricsFrame.origin.y = mainFrame.minY - lyricsFrame.height
            } else if lyricsDockSide == .top {
                lyricsFrame.origin.y = mainFrame.maxY
            }
            lyrics.setFrame(lyricsFrame, display: true, animate: false)
        }

        // Sync Library Window
        if let library = libraryWindow, isLibraryDocked, library.isVisible {
            var libFrame = library.frame
            libFrame.origin.y = mainFrame.maxY - libFrame.height

            if libraryDockSide == .right {
                libFrame.origin.x = mainFrame.maxX
            } else if libraryDockSide == .left {
                libFrame.origin.x = mainFrame.minX - libFrame.width
            }
            library.setFrame(libFrame, display: true, animate: false)
        }
    }

    @objc private func windowDidMove(_ notification: Notification) {
        guard !isSyncing else { return }
        syncAllDocked()
    }

    @objc private func childWindowDidMove(_ notification: Notification) {
        guard !isSyncing, let main = mainWindow, let child = notification.object as? NSWindow else { return }

        let mainFrame = main.frame
        let childFrame = child.frame

        if child === lyricsWindow {
            // Check snap to bottom
            let bottomDist = abs(childFrame.maxY - mainFrame.minY)
            let topDist = abs(childFrame.minY - mainFrame.maxY)
            let xAlign = abs(childFrame.minX - mainFrame.minX)

            if xAlign < snapThreshold * 2 {
                if bottomDist < snapThreshold {
                    isLyricsDocked = true
                    lyricsDockSide = .bottom
                    syncAllDocked()
                } else if topDist < snapThreshold {
                    isLyricsDocked = true
                    lyricsDockSide = .top
                    syncAllDocked()
                } else {
                    isLyricsDocked = false
                }
            } else {
                isLyricsDocked = false
            }
        } else if child === libraryWindow {
            // Check snap to right or left
            let rightDist = abs(childFrame.minX - mainFrame.maxX)
            let leftDist = abs(childFrame.maxX - mainFrame.minX)

            if rightDist < snapThreshold {
                isLibraryDocked = true
                libraryDockSide = .right
                syncAllDocked()
            } else if leftDist < snapThreshold {
                isLibraryDocked = true
                libraryDockSide = .left
                syncAllDocked()
            } else {
                isLibraryDocked = false
            }
        }
    }
}

