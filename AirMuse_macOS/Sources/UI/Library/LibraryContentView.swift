import AppKit
import Domain
import DesignSystem
import Infrastructure

// MARK: - MediaItemType

public enum MediaItemType: String, Sendable {
    case song = "单曲"
    case album = "专辑"
    case playlist = "歌单"
    case radio = "电台"
    case artist = "艺人"
    case chart = "精选"

    public var badgeColor: NSColor {
        switch self {
        case .song:
            return NSColor(calibratedRed: 71/255.0, green: 85/255.0, blue: 105/255.0, alpha: 0.92)
        case .album:
            return NSColor(calibratedRed: 82/255.0, green: 82/255.0, blue: 91/255.0, alpha: 0.92)
        case .playlist:
            return NSColor(calibratedRed: 63/255.0, green: 63/255.0, blue: 70/255.0, alpha: 0.92)
        case .radio:
            return NSColor(calibratedRed: 87/255.0, green: 83/255.0, blue: 78/255.0, alpha: 0.92)
        case .artist:
            return NSColor(calibratedRed: 71/255.0, green: 85/255.0, blue: 105/255.0, alpha: 0.92)
        case .chart:
            return NSColor(calibratedRed: 68/255.0, green: 64/255.0, blue: 60/255.0, alpha: 0.92)
        }
    }
}

// MARK: - MediaCardItem

public struct MediaCardItem: Identifiable, Sendable {
    public let id: String
    public let title: String
    public let subtitle: String
    public let type: MediaItemType
    public let artworkURL: URL?
    public let duration: String?
    public let track: MusicTrack?
    public let albumID: String?
    public let playlistID: String?

    public init(
        id: String,
        title: String,
        subtitle: String,
        type: MediaItemType,
        artworkURL: URL? = nil,
        duration: String? = nil,
        track: MusicTrack? = nil,
        albumID: String? = nil,
        playlistID: String? = nil
    ) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.type = type
        self.artworkURL = artworkURL
        self.duration = duration
        self.track = track
        self.albumID = albumID
        self.playlistID = playlistID
    }
}

// MARK: - ItemBadgeView

final class ItemBadgeView: NSView {
    override var isFlipped: Bool { true }

    private let text: String
    private let bgColor: NSColor

    init(text: String, bgColor: NSColor) {
        self.text = text
        self.bgColor = bgColor
        super.init(frame: .zero)
        wantsLayer = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let path = NSBezierPath(roundedRect: bounds, xRadius: 2.5, yRadius: 2.5)
        bgColor.setFill()
        path.fill()

        NSColor(white: 1.0, alpha: 0.18).setStroke()
        path.lineWidth = 0.5
        path.stroke()

        let font = NSFont.systemFont(ofSize: 7, weight: .bold)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor(calibratedRed: 0.97, green: 0.98, blue: 0.99, alpha: 1.0)
        ]
        let str = NSAttributedString(string: text, attributes: attrs)
        let strSize = str.size()
        let textRect = NSRect(
            x: (bounds.width - strSize.width) / 2,
            y: (bounds.height - strSize.height) / 2,
            width: strSize.width,
            height: strSize.height
        )
        str.draw(in: textRect)
    }
}

// MARK: - MediaCardRowView (1-Column: 44px height)

final class MediaCardRowView: NSView {
    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: 44)
    }

    public var onClick: (() -> Void)?

    private var trackingArea: NSTrackingArea?
    private var isHovered: Bool = false {
        didSet {
            needsDisplay = true
        }
    }

    private let item: MediaCardItem
    private let thumbWrap = NSView()
    private let artView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let subtitleLabel = NSTextField(labelWithString: "")
    private let durationLabel = NSTextField(labelWithString: "")

    init(item: MediaCardItem) {
        self.item = item
        super.init(frame: NSRect(x: 0, y: 0, width: 200, height: 44))
        setupCard()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupCard() {
        wantsLayer = true

        // Thumbnail Wrap (38x38)
        thumbWrap.wantsLayer = true
        thumbWrap.layer?.cornerRadius = 4
        thumbWrap.layer?.masksToBounds = true
        addSubview(thumbWrap)

        artView.imageScaling = .scaleProportionallyUpOrDown
        artView.image = NSImage(systemSymbolName: "music.note", accessibilityDescription: item.title)
        artView.wantsLayer = true
        artView.layer?.cornerRadius = 4
        artView.layer?.masksToBounds = true
        thumbWrap.addSubview(artView)

        // Corner badge
        let badgeW: CGFloat = CGFloat(item.type.rawValue.count * 8 + 6)
        let badge = ItemBadgeView(text: item.type.rawValue, bgColor: item.type.badgeColor)
        badge.frame = NSRect(x: 38 - badgeW - 2, y: 2, width: badgeW, height: 11)
        thumbWrap.addSubview(badge)

        // Load artwork asynchronously
        if let artURL = item.artworkURL {
            Task { [weak artView] in
                if let (data, _) = try? await URLSession.shared.data(from: artURL),
                   let img = NSImage(data: data) {
                    await MainActor.run {
                        artView?.image = img
                    }
                }
            }
        }

        // Labels
        titleLabel.stringValue = item.title
        titleLabel.font = NSFont.systemFont(ofSize: 10.5, weight: .semibold)
        titleLabel.textColor = NSColor(calibratedRed: 0.96, green: 0.96, blue: 0.96, alpha: 1.0)
        titleLabel.lineBreakMode = .byTruncatingTail
        addSubview(titleLabel)

        subtitleLabel.stringValue = item.subtitle
        subtitleLabel.font = NSFont.systemFont(ofSize: 9.5, weight: .regular)
        subtitleLabel.textColor = NSColor(calibratedRed: 0.63, green: 0.63, blue: 0.67, alpha: 1.0)
        subtitleLabel.lineBreakMode = .byTruncatingTail
        addSubview(subtitleLabel)

        durationLabel.stringValue = item.duration ?? ""
        durationLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .regular)
        durationLabel.textColor = NSColor(white: 0.45, alpha: 1.0)
        durationLabel.alignment = .right
        addSubview(durationLabel)
    }

    override func layout() {
        super.layout()
        let w = bounds.width
        thumbWrap.frame = NSRect(x: 3, y: 3, width: 38, height: 38)
        artView.frame = NSRect(x: 0, y: 0, width: 38, height: 38)

        let durW: CGFloat = (item.duration?.isEmpty == false) ? 38 : 0
        let textW = max(10, w - 46 - durW - 4)

        titleLabel.frame = NSRect(x: 46, y: 5, width: textW, height: 16)
        subtitleLabel.frame = NSRect(x: 46, y: 23, width: textW, height: 14)

        if durW > 0 {
            durationLabel.frame = NSRect(x: w - durW - 4, y: 14, width: durW, height: 14)
            durationLabel.isHidden = false
        } else {
            durationLabel.isHidden = true
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = trackingArea {
            removeTrackingArea(existing)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInActiveApp],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) { isHovered = false }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }

    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) {
            onClick?()
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let rect = bounds.insetBy(dx: 1, dy: 1)
        let path = NSBezierPath(roundedRect: rect, xRadius: 5, yRadius: 5)

        if isHovered {
            NSColor(calibratedWhite: 0.16, alpha: 0.70).setFill()
            path.fill()
            NSColor(calibratedRed: 0.79, green: 0.79, blue: 0.79, alpha: 0.25).setStroke()
            path.lineWidth = 1.0
            path.stroke()
        } else {
            NSColor(calibratedWhite: 0.12, alpha: 0.45).setFill()
            path.fill()
            NSColor(white: 1.0, alpha: 0.04).setStroke()
            path.lineWidth = 1.0
            path.stroke()
        }
    }
}

// MARK: - MediaGridCardView (2-Column: Square artwork card per airmuse_ui_core.js)

final class MediaGridCardView: NSView {
    override var isFlipped: Bool { true }

    public var onClick: (() -> Void)?

    private var trackingArea: NSTrackingArea?
    private var isHovered: Bool = false {
        didSet {
            playHoverOverlay.isHidden = !isHovered
            needsDisplay = true
        }
    }

    private let item: MediaCardItem
    private let thumbWrap = NSView()
    private let artView = NSImageView()
    private let playHoverOverlay = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let subtitleLabel = NSTextField(labelWithString: "")

    init(item: MediaCardItem) {
        self.item = item
        super.init(frame: NSRect(x: 0, y: 0, width: 100, height: 140))
        setupGridCard()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupGridCard() {
        wantsLayer = true

        thumbWrap.wantsLayer = true
        thumbWrap.layer?.cornerRadius = 6
        thumbWrap.layer?.masksToBounds = true
        addSubview(thumbWrap)

        artView.imageScaling = .scaleProportionallyUpOrDown
        artView.image = NSImage(systemSymbolName: "music.note", accessibilityDescription: item.title)
        artView.wantsLayer = true
        thumbWrap.addSubview(artView)

        // Play hover overlay
        playHoverOverlay.image = NSImage(systemSymbolName: "play.circle.fill", accessibilityDescription: "Play")
        playHoverOverlay.contentTintColor = NSColor(white: 1.0, alpha: 0.90)
        playHoverOverlay.isHidden = true
        thumbWrap.addSubview(playHoverOverlay)

        // Corner Badge
        let badgeW: CGFloat = CGFloat(item.type.rawValue.count * 8 + 6)
        let badge = ItemBadgeView(text: item.type.rawValue, bgColor: item.type.badgeColor)
        badge.frame = NSRect(x: 4, y: 4, width: badgeW, height: 11)
        thumbWrap.addSubview(badge)

        // Load artwork
        if let artURL = item.artworkURL {
            Task { [weak artView] in
                if let (data, _) = try? await URLSession.shared.data(from: artURL),
                   let img = NSImage(data: data) {
                    await MainActor.run {
                        artView?.image = img
                    }
                }
            }
        }

        // Labels
        titleLabel.stringValue = item.title
        titleLabel.font = NSFont.systemFont(ofSize: 10, weight: .semibold)
        titleLabel.textColor = NSColor(calibratedRed: 0.95, green: 0.95, blue: 0.95, alpha: 1.0)
        titleLabel.lineBreakMode = .byTruncatingTail
        addSubview(titleLabel)

        subtitleLabel.stringValue = item.subtitle
        subtitleLabel.font = NSFont.systemFont(ofSize: 9, weight: .regular)
        subtitleLabel.textColor = NSColor(calibratedRed: 0.60, green: 0.60, blue: 0.65, alpha: 1.0)
        subtitleLabel.lineBreakMode = .byTruncatingTail
        addSubview(subtitleLabel)
    }

    override func layout() {
        super.layout()
        let w = bounds.width
        let artSize = max(40, w - 8)

        thumbWrap.frame = NSRect(x: 4, y: 4, width: artSize, height: artSize)
        artView.frame = NSRect(x: 0, y: 0, width: artSize, height: artSize)
        playHoverOverlay.frame = NSRect(x: (artSize - 28) / 2, y: (artSize - 28) / 2, width: 28, height: 28)

        let textY = 4 + artSize + 3
        titleLabel.frame = NSRect(x: 4, y: textY, width: artSize, height: 14)
        subtitleLabel.frame = NSRect(x: 4, y: textY + 14, width: artSize, height: 13)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = trackingArea {
            removeTrackingArea(existing)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInActiveApp],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) { isHovered = false }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }

    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) {
            onClick?()
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let rect = bounds.insetBy(dx: 1, dy: 1)
        let path = NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6)

        if isHovered {
            NSColor(calibratedWhite: 0.18, alpha: 0.65).setFill()
            path.fill()
            NSColor(calibratedRed: 0.85, green: 0.85, blue: 0.85, alpha: 0.25).setStroke()
            path.lineWidth = 1.0
            path.stroke()
        } else {
            NSColor(calibratedWhite: 0.12, alpha: 0.35).setFill()
            path.fill()
            NSColor(white: 1.0, alpha: 0.04).setStroke()
            path.lineWidth = 0.5
            path.stroke()
        }
    }
}

// MARK: - DetailTrackRowView (Rows inside album/playlist drawer)

final class DetailTrackRowView: NSView {
    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: 28)
    }

    public var onClick: (() -> Void)?

    private var trackingArea: NSTrackingArea?
    private var isHovered: Bool = false {
        didSet {
            needsDisplay = true
        }
    }

    private let indexLabel = NSTextField(labelWithString: "")
    private let titleLabel = NSTextField(labelWithString: "")
    private let artistLabel = NSTextField(labelWithString: "")
    private let durLabel = NSTextField(labelWithString: "")

    init(index: Int, track: MusicTrack) {
        super.init(frame: NSRect(x: 0, y: 0, width: 200, height: 28))
        wantsLayer = true

        indexLabel.stringValue = "\(index)"
        indexLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 9.5, weight: .regular)
        indexLabel.textColor = NSColor(white: 0.45, alpha: 1.0)
        indexLabel.alignment = .center
        addSubview(indexLabel)

        titleLabel.stringValue = track.title
        titleLabel.font = NSFont.systemFont(ofSize: 10.5, weight: .medium)
        titleLabel.textColor = NSColor(calibratedWhite: 0.90, alpha: 1.0)
        titleLabel.lineBreakMode = .byTruncatingTail
        addSubview(titleLabel)

        artistLabel.stringValue = track.artistName
        artistLabel.font = NSFont.systemFont(ofSize: 9, weight: .regular)
        artistLabel.textColor = NSColor(calibratedWhite: 0.56, alpha: 1.0)
        artistLabel.lineBreakMode = .byTruncatingTail
        addSubview(artistLabel)

        let durationSec = Double(track.durationMs) / 1000.0
        if durationSec > 0 {
            let m = Int(durationSec) / 60
            let s = Int(durationSec) % 60
            durLabel.stringValue = String(format: "%02d:%02d", m, s)
        } else {
            durLabel.stringValue = ""
        }
        durLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .regular)
        durLabel.textColor = NSColor(white: 0.45, alpha: 1.0)
        durLabel.alignment = .right
        addSubview(durLabel)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        let w = bounds.width
        indexLabel.frame = NSRect(x: 2, y: 6, width: 20, height: 16)
        durLabel.frame = NSRect(x: w - 38, y: 6, width: 34, height: 16)

        let bodyW = max(10, w - 24 - 40)
        titleLabel.frame = NSRect(x: 24, y: 2, width: bodyW, height: 14)
        artistLabel.frame = NSRect(x: 24, y: 15, width: bodyW, height: 12)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = trackingArea {
            removeTrackingArea(existing)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInActiveApp],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) { isHovered = false }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }

    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) {
            onClick?()
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        if isHovered {
            let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 4, yRadius: 4)
            NSColor(calibratedRed: 0.79, green: 0.79, blue: 0.79, alpha: 0.08).setFill()
            path.fill()
        }
    }
}

// MARK: - DetailOverlayView (Slide-over drawer for Album/Playlist tracks)

final class DetailOverlayView: NSView {
    override var isFlipped: Bool { true }

    public var onBack: (() -> Void)?
    public var onPlayAll: (() -> Void)?
    public var onTrackSelected: ((MusicTrack) -> Void)?

    private let headerView = NSView()
    private let backButton = NSButton()
    private let titleLabel = NSTextField(labelWithString: "")
    private let playAllButton = NSButton()
    private let scrollView = NSScrollView()
    private let trackStack = FlippedStackView()
    private let loadingIndicator = NSProgressIndicator()
    private let emptyLabel = NSTextField(labelWithString: "加载中...")

    private var currentTracks: [MusicTrack] = []

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupViews()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupViews() {
        wantsLayer = true
        layer?.backgroundColor = NSColor(calibratedWhite: 0.09, alpha: 0.96).cgColor

        // Header
        headerView.wantsLayer = true
        addSubview(headerView)

        backButton.title = "← 返回"
        backButton.font = NSFont.systemFont(ofSize: 10, weight: .medium)
        backButton.bezelStyle = .recessed
        backButton.isBordered = false
        backButton.contentTintColor = NSColor(calibratedWhite: 0.70, alpha: 1.0)
        backButton.target = self
        backButton.action = #selector(backClicked)
        headerView.addSubview(backButton)

        titleLabel.font = NSFont.systemFont(ofSize: 11, weight: .semibold)
        titleLabel.textColor = NSColor(calibratedWhite: 0.90, alpha: 1.0)
        titleLabel.lineBreakMode = .byTruncatingTail
        headerView.addSubview(titleLabel)

        playAllButton.bezelStyle = .inline
        playAllButton.isBordered = false
        playAllButton.wantsLayer = true
        playAllButton.layer?.backgroundColor = NSColor(red: 0.98, green: 0.22, blue: 0.35, alpha: 0.95).cgColor
        playAllButton.layer?.cornerRadius = 11
        let pstyle = NSMutableParagraphStyle()
        pstyle.alignment = .center
        let btnAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 10, weight: .bold),
            .foregroundColor: NSColor.white,
            .paragraphStyle: pstyle
        ]
        playAllButton.attributedTitle = NSAttributedString(string: "▶ 播放全部", attributes: btnAttrs)
        playAllButton.target = self
        playAllButton.action = #selector(playAllClicked)
        headerView.addSubview(playAllButton)

        // Track List Scroll with FlippedClipView
        let clip = FlippedClipView()
        clip.drawsBackground = false
        scrollView.contentView = clip
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true

        trackStack.orientation = .vertical
        trackStack.alignment = .leading
        trackStack.spacing = 1
        trackStack.edgeInsets = NSEdgeInsets(top: 2, left: 2, bottom: 4, right: 2)
        trackStack.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = trackStack
        addSubview(scrollView)

        NSLayoutConstraint.activate([
            trackStack.leadingAnchor.constraint(equalTo: scrollView.contentView.leadingAnchor),
            trackStack.trailingAnchor.constraint(equalTo: scrollView.contentView.trailingAnchor),
            trackStack.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor)
        ])

        loadingIndicator.style = .spinning
        loadingIndicator.controlSize = .small
        loadingIndicator.isDisplayedWhenStopped = false
        addSubview(loadingIndicator)

        emptyLabel.font = NSFont.systemFont(ofSize: 10, weight: .regular)
        emptyLabel.textColor = NSColor(white: 0.5, alpha: 1.0)
        emptyLabel.alignment = .center
        emptyLabel.isHidden = true
        addSubview(emptyLabel)
    }

    override func layout() {
        super.layout()
        let w = bounds.width
        let h = bounds.height

        headerView.frame = NSRect(x: 0, y: 0, width: w, height: 30)
        backButton.frame = NSRect(x: 2, y: 3, width: 48, height: 24)
        playAllButton.frame = NSRect(x: w - 86, y: 4, width: 82, height: 22)
        titleLabel.frame = NSRect(x: 52, y: 6, width: max(10, w - 52 - 90), height: 18)

        scrollView.frame = NSRect(x: 0, y: 30, width: w, height: max(10, h - 30))
        loadingIndicator.frame = NSRect(x: (w - 20) / 2, y: (h - 20) / 2, width: 20, height: 20)
        emptyLabel.frame = NSRect(x: 0, y: (h - 20) / 2, width: w, height: 20)

        for sub in trackStack.arrangedSubviews {
            sub.widthAnchor.constraint(equalToConstant: max(100, w - 8)).isActive = true
        }
    }

    public func configure(title: String, tracks: [MusicTrack]) {
        titleLabel.stringValue = title
        updateTracks(tracks)
    }

    public func updateTracks(_ tracks: [MusicTrack]) {
        self.currentTracks = tracks
        trackStack.arrangedSubviews.forEach { $0.removeFromSuperview() }

        if tracks.isEmpty {
            loadingIndicator.startAnimation(nil)
            emptyLabel.stringValue = "加载曲目中..."
            emptyLabel.isHidden = false
        } else {
            loadingIndicator.stopAnimation(nil)
            emptyLabel.isHidden = true

            for (idx, track) in tracks.enumerated() {
                let row = DetailTrackRowView(index: idx + 1, track: track)
                row.translatesAutoresizingMaskIntoConstraints = false
                row.heightAnchor.constraint(equalToConstant: 28).isActive = true
                row.widthAnchor.constraint(equalToConstant: max(100, bounds.width - 8)).isActive = true
                row.onClick = { [weak self] in
                    self?.onTrackSelected?(track)
                }
                trackStack.addArrangedSubview(row)
            }
        }
    }

    @objc private func backClicked() {
        onBack?()
    }

    @objc private func playAllClicked() {
        onPlayAll?()
    }
}

// MARK: - LibraryContentView

/// Right content view presenting media cards (1-col rows or 2-col grid) and slide-over DetailView.
@MainActor
open class LibraryContentView: NSView {

    open override var isFlipped: Bool { true }

    public var onItemClicked: ((MediaCardItem) -> Void)?
    public var onTrackSelected: ((MusicTrack) -> Void)?
    public var onPlayAll: (([MusicTrack]) -> Void)?

    public private(set) var is2Col: Bool = false

    private let titleLabel = NSTextField(labelWithString: "为你推荐")
    private let scrollView = NSScrollView()
    private let stackView = FlippedStackView()
    private let loadingIndicator = NSProgressIndicator()
    private let emptyLabel = NSTextField(labelWithString: "没有找到相关项目")
    private let detailOverlay = DetailOverlayView()

    private var currentItems: [MediaCardItem] = []
    private var currentDetailTracks: [MusicTrack] = []

    public var currentDetailTracksList: [MusicTrack] { currentDetailTracks }
    public var displayedItems: [MediaCardItem] { currentItems }

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupViews()
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupViews()
    }

    private func setupViews() {
        wantsLayer = true

        titleLabel.font = DesignTokens.Typography.titleFont
        titleLabel.textColor = DesignTokens.Colors.primaryText
        addSubview(titleLabel)

        // Use FlippedClipView so content always pins to top!
        let clip = FlippedClipView()
        clip.drawsBackground = false
        scrollView.contentView = clip
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true

        stackView.orientation = .vertical
        stackView.alignment = .leading
        stackView.spacing = 4
        stackView.edgeInsets = NSEdgeInsets(top: 2, left: 2, bottom: 8, right: 2)
        stackView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = stackView
        addSubview(scrollView)

        NSLayoutConstraint.activate([
            stackView.leadingAnchor.constraint(equalTo: scrollView.contentView.leadingAnchor),
            stackView.trailingAnchor.constraint(equalTo: scrollView.contentView.trailingAnchor),
            stackView.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor)
        ])

        loadingIndicator.style = .spinning
        loadingIndicator.controlSize = .small
        loadingIndicator.isDisplayedWhenStopped = false
        addSubview(loadingIndicator)

        emptyLabel.font = DesignTokens.Typography.artistFont
        emptyLabel.textColor = DesignTokens.Colors.tertiaryText
        emptyLabel.alignment = .center
        emptyLabel.isHidden = true
        addSubview(emptyLabel)

        // Detail overlay starts hidden
        detailOverlay.isHidden = true
        detailOverlay.onBack = { [weak self] in
            self?.hideDetail()
        }
        detailOverlay.onPlayAll = { [weak self] in
            guard let self else { return }
            self.onPlayAll?(self.currentDetailTracks)
        }
        detailOverlay.onTrackSelected = { [weak self] track in
            self?.onTrackSelected?(track)
        }
        addSubview(detailOverlay)
    }

    open override func layout() {
        super.layout()
        titleLabel.frame = NSRect(x: 4, y: 2, width: bounds.width - 8, height: 18)
        scrollView.frame = NSRect(x: 0, y: 22, width: bounds.width, height: max(10, bounds.height - 22))
        loadingIndicator.frame = NSRect(x: (bounds.width - 20) / 2, y: (bounds.height - 20) / 2, width: 20, height: 20)
        emptyLabel.frame = NSRect(x: 0, y: (bounds.height - 20) / 2, width: bounds.width, height: 20)
        detailOverlay.frame = bounds
    }

    public func setTitle(_ title: String) {
        titleLabel.stringValue = title
    }

    public func setLoading(_ loading: Bool) {
        if loading {
            loadingIndicator.startAnimation(nil)
            emptyLabel.isHidden = true
        } else {
            loadingIndicator.stopAnimation(nil)
        }
    }

    public func setLayout2Col(_ is2Col: Bool) {
        self.is2Col = is2Col
        displayItems(self.currentItems)
    }

    public func displayItems(_ items: [MediaCardItem]) {
        self.currentItems = items
        detailOverlay.isHidden = true
        stackView.arrangedSubviews.forEach { $0.removeFromSuperview() }
        emptyLabel.isHidden = !items.isEmpty

        AppLogger.shared.log(
            category: .render,
            level: .info,
            message: "LibraryContentView 渲染 \(items.count) 个卡片项目 (模式: \(is2Col ? "双栏卡片" : "单栏列表"), 宽: \(Int(bounds.width)))",
            details: items.first.map { "首项: [\($0.type.rawValue)] \($0.title) - \($0.subtitle)" }
        )

        let availableWidth = max(100, bounds.width - 10)

        if is2Col {
            // 2-Column Grid Layout
            let cardWidth = (availableWidth - 6) / 2
            let cardHeight = cardWidth + 36

            var i = 0
            while i < items.count {
                let rowStack = NSStackView()
                rowStack.orientation = .horizontal
                rowStack.spacing = 6
                rowStack.distribution = .fillEqually
                rowStack.translatesAutoresizingMaskIntoConstraints = false
                rowStack.heightAnchor.constraint(equalToConstant: cardHeight).isActive = true
                rowStack.widthAnchor.constraint(equalToConstant: availableWidth).isActive = true

                let item1 = items[i]
                let card1 = MediaGridCardView(item: item1)
                card1.onClick = { [weak self] in
                    self?.onItemClicked?(item1)
                }
                rowStack.addArrangedSubview(card1)

                if i + 1 < items.count {
                    let item2 = items[i + 1]
                    let card2 = MediaGridCardView(item: item2)
                    card2.onClick = { [weak self] in
                        self?.onItemClicked?(item2)
                    }
                    rowStack.addArrangedSubview(card2)
                } else {
                    // Placeholder spacer view to balance grid
                    let spacer = NSView()
                    spacer.translatesAutoresizingMaskIntoConstraints = false
                    rowStack.addArrangedSubview(spacer)
                }

                stackView.addArrangedSubview(rowStack)
                i += 2
            }
        } else {
            // 1-Column Row Layout (44px)
            for item in items {
                let row = MediaCardRowView(item: item)
                row.translatesAutoresizingMaskIntoConstraints = false
                row.heightAnchor.constraint(equalToConstant: 44).isActive = true
                row.widthAnchor.constraint(equalToConstant: availableWidth).isActive = true
                row.onClick = { [weak self] in
                    self?.onItemClicked?(item)
                }
                stackView.addArrangedSubview(row)
            }
        }
    }

    public func displayTracks(_ tracks: [MusicTrack]) {
        let items = tracks.map { track in
            let durationSec = Double(track.durationMs) / 1000.0
            var durStr: String? = nil
            if durationSec > 0 {
                let m = Int(durationSec) / 60
                let s = Int(durationSec) % 60
                durStr = String(format: "%02d:%02d", m, s)
            }
            return MediaCardItem(
                id: track.id,
                title: track.title,
                subtitle: track.artistName,
                type: .song,
                artworkURL: track.artworkURL,
                duration: durStr,
                track: track
            )
        }
        displayItems(items)
    }

    public func showDetail(title: String, tracks: [MusicTrack] = []) {
        AppLogger.shared.log(category: .render, level: .info, message: "展开详情抽屉: \"\(title)\" (曲目数: \(tracks.count))")
        self.currentDetailTracks = tracks
        detailOverlay.configure(title: title, tracks: tracks)
        detailOverlay.frame = bounds
        detailOverlay.isHidden = false
    }

    public func updateDetailTracks(_ tracks: [MusicTrack]) {
        AppLogger.shared.log(category: .render, level: .info, message: "更新详情抽屉曲目: 共 \(tracks.count) 首")
        self.currentDetailTracks = tracks
        detailOverlay.updateTracks(tracks)
    }

    public func hideDetail() {
        detailOverlay.isHidden = true
    }
}
