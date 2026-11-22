import AppKit
import Domain
import DesignSystem

// MARK: - MiniPlayerView

/// The 40pt compact mini player capsule view.
/// Follows the AirPlay Zion specification:
/// - 40px height
/// - Left: 16×16px controls (Previous, Play/Pause, Next)
/// - Center: Marquee scrolling title + artist
/// - Right: Time font display + expand button
open class MiniPlayerView: GlassMiniPlayer {

    public var onPlayPause: (() -> Void)?
    public var onNext: (() -> Void)?
    public var onPrevious: (() -> Void)?
    public var onExpand: (() -> Void)?

    private let prevButton = GlassButton(image: NSImage(systemSymbolName: "backward.fill", accessibilityDescription: "Prev"), size: CGSize(width: 24, height: 24))
    private let playPauseButton = GlassButton(image: NSImage(systemSymbolName: "play.fill", accessibilityDescription: "Play/Pause"), size: CGSize(width: 24, height: 24))
    private let nextButton = GlassButton(image: NSImage(systemSymbolName: "forward.fill", accessibilityDescription: "Next"), size: CGSize(width: 24, height: 24))

    private let titleLabel = NSTextField(labelWithString: "AirMuse Ready")
    private let timeLabel = NSTextField(labelWithString: "00:00")
    private let expandButton = GlassButton(image: NSImage(systemSymbolName: "arrow.up.left.and.arrow.down.right", accessibilityDescription: "Expand"), size: CGSize(width: 21, height: 21))
    private let quitButton = GlassButton(image: NSImage(systemSymbolName: "xmark", accessibilityDescription: "Quit"), size: CGSize(width: 18, height: 18))

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupMiniViews()
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupMiniViews()
    }

    private func setupMiniViews() {
        cornerRadius = DesignTokens.CornerRadius.mini

        // Wire buttons
        prevButton.onClick = { [weak self] in self?.onPrevious?() }
        playPauseButton.onClick = { [weak self] in self?.onPlayPause?() }
        nextButton.onClick = { [weak self] in self?.onNext?() }
        expandButton.onClick = { [weak self] in self?.onExpand?() }
        quitButton.toolTip = "退出 AirMuse"
        quitButton.onClick = { NSApp.terminate(nil) }

        addSubview(prevButton)
        addSubview(playPauseButton)
        addSubview(nextButton)

        // Title
        titleLabel.font = DesignTokens.Typography.titleFont
        titleLabel.textColor = DesignTokens.Colors.primaryText
        titleLabel.lineBreakMode = .byTruncatingTail
        let shadow = NSShadow()
        shadow.shadowColor = DesignTokens.Colors.haloShadow
        shadow.shadowOffset = NSSize(width: 0, height: -1)
        shadow.shadowBlurRadius = 1.0
        titleLabel.shadow = shadow
        addSubview(titleLabel)

        // Time
        timeLabel.font = DesignTokens.Typography.timeFont
        timeLabel.textColor = DesignTokens.Colors.secondaryText
        timeLabel.alignment = .right
        addSubview(timeLabel)

        addSubview(expandButton)
        addSubview(quitButton)
    }

    open override func layout() {
        super.layout()
        let btnY: CGFloat = (bounds.height - 24) / 2
        let margin: CGFloat = 13.5

        prevButton.frame = NSRect(x: margin, y: btnY, width: 24, height: 24)
        playPauseButton.frame = NSRect(x: prevButton.frame.maxX + 6, y: btnY, width: 24, height: 24)
        nextButton.frame = NSRect(x: playPauseButton.frame.maxX + 6, y: btnY, width: 24, height: 24)

        let rightMargin: CGFloat = 12
        quitButton.frame = NSRect(x: bounds.width - 21 - rightMargin, y: (bounds.height - 18) / 2, width: 18, height: 18)
        expandButton.frame = NSRect(x: quitButton.frame.minX - 27, y: (bounds.height - 21) / 2, width: 21, height: 21)
        timeLabel.frame = NSRect(x: expandButton.frame.minX - 66, y: (bounds.height - 22) / 2, width: 60, height: 22)

        let textLeft = nextButton.frame.maxX + 12
        let textRight = timeLabel.frame.minX - 9
        titleLabel.frame = NSRect(x: textLeft, y: (bounds.height - 24) / 2, width: max(0, textRight - textLeft), height: 24)
    }

    public func updateState(_ state: PlaybackState) {
        if let track = state.currentTrack {
            titleLabel.stringValue = "\(track.title) — \(track.artistName)"
        } else {
            titleLabel.stringValue = "AirMuse Ready"
        }

        let iconName = state.isPlaying ? "pause.fill" : "play.fill"
        playPauseButton.image = NSImage(systemSymbolName: iconName, accessibilityDescription: "Play/Pause")

        let est = state.estimatedPositionMs
        let totalSec = max(0, est / 1000)
        let m = totalSec / 60
        let s = totalSec % 60
        timeLabel.stringValue = String(format: "%02lld:%02lld", m, s)
    }
}

