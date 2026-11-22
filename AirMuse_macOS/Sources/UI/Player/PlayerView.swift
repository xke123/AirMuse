import AppKit
import Domain
import DesignSystem
import Playback
import Infrastructure

// MARK: - ScrubbableSlider

final class ScrubbableSlider: NSSlider {
    var onScrubbingChanged: ((Bool) -> Void)?

    override func mouseDown(with event: NSEvent) {
        onScrubbingChanged?(true)
        super.mouseDown(with: event)
        onScrubbingChanged?(false)
    }
}

// MARK: - PlayerView

/// The main floating music controller view (330×106 DIP).
/// Houses cover artwork, metadata, progress slider, and playback controls.
open class PlayerView: GlassSurface {

    public var onPlayPause: (() -> Void)?
    public var onNext: (() -> Void)?
    public var onPrevious: (() -> Void)?
    public var onSeek: ((Int64) -> Void)?
    public var onVolumeChanged: ((Float) -> Void)?
    public var onToggleMiniMode: (() -> Void)?
    public var onToggleLyrics: (() -> Void)?
    public var onToggleLibrary: (() -> Void)?
    public var onQuit: (() -> Void)?

    // Subviews
    private let artworkView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "AirMuse Ready")
    private let artistLabel = NSTextField(labelWithString: "Waiting for playback…")
    private let timeLabel = NSTextField(labelWithString: "00:00 / 00:00")
    private let progressSlider = ScrubbableSlider()

    private let prevButton = GlassButton(image: NSImage(systemSymbolName: "backward.fill", accessibilityDescription: "Previous"), size: CGSize(width: 33, height: 33))
    private let playPauseButton = GlassButton(image: NSImage(systemSymbolName: "play.fill", accessibilityDescription: "Play/Pause"), size: CGSize(width: 42, height: 42))
    private let nextButton = GlassButton(image: NSImage(systemSymbolName: "forward.fill", accessibilityDescription: "Next"), size: CGSize(width: 33, height: 33))

    private let lyricsButton = GlassButton(image: NSImage(systemSymbolName: "quote.bubble", accessibilityDescription: "Lyrics"), size: CGSize(width: 27, height: 27))
    private let libraryButton = GlassButton(image: NSImage(systemSymbolName: "music.note.list", accessibilityDescription: "Library"), size: CGSize(width: 27, height: 27))
    private let miniModeButton = GlassButton(image: NSImage(systemSymbolName: "arrow.down.right.and.arrow.up.left", accessibilityDescription: "Mini Mode"), size: CGSize(width: 24, height: 24))
    private let quitButton = GlassButton(image: NSImage(systemSymbolName: "xmark", accessibilityDescription: "Quit AirMuse"), size: CGSize(width: 21, height: 21))

    private var currentDurationMs: Int64 = 0
    private var isScrubbing: Bool = false
    private var currentArtworkTrackKey: String?
    private var artworkLoadTask: Task<Void, Never>?

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupViews()
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupViews()
    }

    private func setupViews() {
        cornerRadius = DesignTokens.CornerRadius.window

        // Artwork
        artworkView.wantsLayer = true
        artworkView.layer?.cornerRadius = DesignTokens.CornerRadius.artwork
        artworkView.layer?.masksToBounds = true
        artworkView.imageScaling = .scaleProportionallyUpOrDown
        artworkView.image = NSImage(systemSymbolName: "music.note", accessibilityDescription: "Album Art")
        addSubview(artworkView)

        // Title with Zion tight halo shadow
        titleLabel.font = DesignTokens.Typography.titleFont
        titleLabel.textColor = DesignTokens.Colors.primaryText
        titleLabel.lineBreakMode = .byTruncatingTail
        let shadow = NSShadow()
        shadow.shadowColor = DesignTokens.Colors.haloShadow
        shadow.shadowOffset = NSSize(width: 0, height: -1)
        shadow.shadowBlurRadius = 1.0
        titleLabel.shadow = shadow
        addSubview(titleLabel)

        // Artist
        artistLabel.font = DesignTokens.Typography.artistFont
        artistLabel.textColor = DesignTokens.Colors.secondaryText
        artistLabel.lineBreakMode = .byTruncatingTail
        addSubview(artistLabel)

        // Progress Slider
        progressSlider.minValue = 0
        progressSlider.maxValue = 100
        progressSlider.doubleValue = 0
        progressSlider.isContinuous = true
        progressSlider.target = self
        progressSlider.action = #selector(sliderValueChanged(_:))
        progressSlider.onScrubbingChanged = { [weak self] scrubbing in
            guard let self else { return }
            self.isScrubbing = scrubbing
            if !scrubbing && self.currentDurationMs > 0 {
                let targetMs = Int64((self.progressSlider.doubleValue / 100.0) * Double(self.currentDurationMs))
                self.onSeek?(targetMs)
            }
        }
        addSubview(progressSlider)

        // Time Label
        timeLabel.font = DesignTokens.Typography.timeFont
        timeLabel.textColor = DesignTokens.Colors.tertiaryText
        timeLabel.alignment = .right
        addSubview(timeLabel)

        // Wire buttons
        prevButton.onClick = { [weak self] in self?.onPrevious?() }
        playPauseButton.onClick = { [weak self] in self?.onPlayPause?() }
        nextButton.onClick = { [weak self] in self?.onNext?() }
        lyricsButton.onClick = { [weak self] in self?.onToggleLyrics?() }
        libraryButton.onClick = { [weak self] in self?.onToggleLibrary?() }
        miniModeButton.onClick = { [weak self] in self?.onToggleMiniMode?() }
        quitButton.toolTip = "退出 AirMuse"
        quitButton.onClick = { [weak self] in
            if let onQuit = self?.onQuit {
                onQuit()
            } else {
                NSApp.terminate(nil)
            }
        }

        addSubview(prevButton)
        addSubview(playPauseButton)
        addSubview(nextButton)
        addSubview(lyricsButton)
        addSubview(libraryButton)
        addSubview(miniModeButton)
        addSubview(quitButton)
    }

    open override func layout() {
        super.layout()
        let pad: CGFloat = DesignTokens.Spacing.md
        let artSize: CGFloat = 111

        // Left artwork
        artworkView.frame = NSRect(x: pad, y: (bounds.height - artSize) / 2, width: artSize, height: artSize)

        let contentLeft = artworkView.frame.maxX + pad
        let contentRight = bounds.width - pad
        let contentW = contentRight - contentLeft

        // Window controls at top-right: Quit (xmark) and Mini mode
        quitButton.frame = NSRect(x: bounds.width - 33, y: bounds.height - 33, width: 21, height: 21)
        miniModeButton.frame = NSRect(x: quitButton.frame.minX - 30, y: bounds.height - 34.5, width: 24, height: 24)

        // Title & Artist
        titleLabel.frame = NSRect(x: contentLeft, y: bounds.height - 45, width: contentW - 66, height: 24)
        artistLabel.frame = NSRect(x: contentLeft, y: bounds.height - 69, width: contentW - 66, height: 21)

        // Progress slider
        progressSlider.frame = NSRect(x: contentLeft, y: bounds.height - 99, width: contentW - 110, height: 20)
        timeLabel.frame = NSRect(x: progressSlider.frame.maxX + 6, y: bounds.height - 99, width: 105, height: 20)

        // Transport buttons
        let btnY: CGFloat = 18
        prevButton.frame = NSRect(x: contentLeft, y: btnY + 4.5, width: 33, height: 33)
        playPauseButton.frame = NSRect(x: prevButton.frame.maxX + 15, y: btnY, width: 42, height: 42)
        nextButton.frame = NSRect(x: playPauseButton.frame.maxX + 15, y: btnY + 4.5, width: 33, height: 33)

        // Right side utility buttons
        libraryButton.frame = NSRect(x: bounds.width - pad - 30, y: btnY + 6, width: 27, height: 27)
        lyricsButton.frame = NSRect(x: libraryButton.frame.minX - 36, y: btnY + 6, width: 27, height: 27)
    }

    public func updateState(_ state: PlaybackState) {
        currentDurationMs = state.durationMs

        if let track = state.currentTrack {
            titleLabel.stringValue = track.title
            if state.status == .failed, let err = state.errorMessage, !err.isEmpty {
                artistLabel.stringValue = err
                artistLabel.textColor = .systemRed
            } else {
                artistLabel.stringValue = track.artistName
                artistLabel.textColor = DesignTokens.Colors.secondaryText
            }
        } else {
            titleLabel.stringValue = "AirMuse Ready"
            artistLabel.stringValue = state.sourceName
            artistLabel.textColor = DesignTokens.Colors.secondaryText
        }

        // Play/Pause icon
        let iconName = state.isPlaying ? "pause.fill" : "play.fill"
        playPauseButton.image = NSImage(systemSymbolName: iconName, accessibilityDescription: "Play/Pause")

        // Progress
        if !isScrubbing && state.durationMs > 0 {
            let progress = Double(state.estimatedPositionMs) / Double(state.durationMs) * 100.0
            progressSlider.doubleValue = min(max(progress, 0), 100)
            timeLabel.stringValue = "\(formatTime(ms: state.estimatedPositionMs)) / \(formatTime(ms: state.durationMs))"
        }

        // Artwork: prefer in-state bytes, otherwise fetch asynchronously via ImageCache with trackKey guard
        let trackKey = state.currentTrack?.trackKey
        if let data = state.artworkData, let img = NSImage(data: data) {
            artworkLoadTask?.cancel()
            currentArtworkTrackKey = trackKey
            artworkView.image = img
        } else if let track = state.currentTrack, let url = track.artworkURL {
            if currentArtworkTrackKey != track.trackKey {
                currentArtworkTrackKey = track.trackKey
                artworkLoadTask?.cancel()
                artworkView.image = NSImage(systemSymbolName: "music.note", accessibilityDescription: "Album Art")
                let expectedKey = track.trackKey
                artworkLoadTask = Task { [weak self] in
                    let img = await ImageCache.shared.image(for: url, size: CGSize(width: 222, height: 222))
                    guard !Task.isCancelled, let self, self.currentArtworkTrackKey == expectedKey else { return }
                    if let img {
                        self.artworkView.image = img
                    }
                }
            }
        } else {
            artworkLoadTask?.cancel()
            currentArtworkTrackKey = nil
            artworkView.image = NSImage(systemSymbolName: "music.note", accessibilityDescription: "Album Art")
        }
    }

    @objc private func sliderValueChanged(_ sender: NSSlider) {
        if currentDurationMs > 0 {
            let targetMs = Int64((sender.doubleValue / 100.0) * Double(currentDurationMs))
            timeLabel.stringValue = "\(formatTime(ms: targetMs)) / \(formatTime(ms: currentDurationMs))"
            if !isScrubbing {
                onSeek?(targetMs)
            }
        }
    }

    private func formatTime(ms: Int64) -> String {
        let totalSec = max(0, ms / 1000)
        let m = totalSec / 60
        let s = totalSec % 60
        return String(format: "%02lld:%02lld", m, s)
    }
}

