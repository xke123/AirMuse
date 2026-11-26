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
    public let browseCategoryID: String?

    public init(
        id: String,
        title: String,
        subtitle: String,
        type: MediaItemType,
        artworkURL: URL? = nil,
        duration: String? = nil,
        track: MusicTrack? = nil,
        albumID: String? = nil,
        playlistID: String? = nil,
        browseCategoryID: String? = nil
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
        self.browseCategoryID = browseCategoryID
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
        let path = NSBezierPath(roundedRect: bounds, xRadius: 3.5, yRadius: 3.5)
        bgColor.setFill()
        path.fill()

        NSColor(white: 1.0, alpha: 0.18).setStroke()
        path.lineWidth = 0.5
        path.stroke()

        let font = NSFont.systemFont(ofSize: 10, weight: .bold)
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

// MARK: - MediaCardRowView (1-Column: 66px height)

final class MediaCardRowView: NSView {
    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: 66)
    }

    public var onClick: (() -> Void)?
    public var onContextMenuRequested: (() -> NSMenu?)?

    override func menu(for event: NSEvent) -> NSMenu? {
        onContextMenuRequested?()
    }

    private let cardMotionID = "MediaCardRow-\(UUID().uuidString)"
    private var trackingArea: NSTrackingArea?
    private var artworkTask: Task<Void, Never>?
    private var isHovered: Bool = false {
        didSet {
            guard oldValue != isHovered else { return }
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
        super.init(frame: NSRect(x: 0, y: 0, width: 200, height: 66))
        setupCard()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupCard() {
        wantsLayer = true

        // Thumbnail Wrap (57x57)
        thumbWrap.wantsLayer = true
        thumbWrap.layer?.cornerRadius = 6
        thumbWrap.layer?.masksToBounds = true
        addSubview(thumbWrap)

        artView.imageScaling = .scaleProportionallyUpOrDown
        artView.image = NSImage(systemSymbolName: "music.note", accessibilityDescription: item.title)
        artView.wantsLayer = true
        artView.layer?.cornerRadius = 6
        artView.layer?.masksToBounds = true
        thumbWrap.addSubview(artView)

        // Corner badge
        let badgeW: CGFloat = CGFloat(item.type.rawValue.count * 11 + 8)
        let badge = ItemBadgeView(text: item.type.rawValue, bgColor: item.type.badgeColor)
        badge.frame = NSRect(x: 57 - badgeW - 3, y: 3, width: badgeW, height: 16)
        thumbWrap.addSubview(badge)

        // Load artwork asynchronously via ImageCacheV2
        if let artURL = item.artworkURL {
            artworkTask = Task { [weak artView] in
                let img = await ImageCacheV2.shared.image(for: artURL, targetPixelSize: 120)
                guard !Task.isCancelled else { return }
                if let img {
                    await MainActor.run {
                        artView?.image = img
                    }
                }
            }
        }

        // Labels
        titleLabel.stringValue = item.title
        titleLabel.font = NSFont.systemFont(ofSize: 14.5, weight: .semibold)
        titleLabel.textColor = NSColor(calibratedRed: 0.96, green: 0.96, blue: 0.96, alpha: 1.0)
        titleLabel.lineBreakMode = .byTruncatingTail
        addSubview(titleLabel)

        subtitleLabel.stringValue = item.subtitle
        subtitleLabel.font = NSFont.systemFont(ofSize: 13, weight: .regular)
        subtitleLabel.textColor = NSColor(calibratedRed: 0.63, green: 0.63, blue: 0.67, alpha: 1.0)
        subtitleLabel.lineBreakMode = .byTruncatingTail
        addSubview(subtitleLabel)

        durationLabel.stringValue = item.duration ?? ""
        durationLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 12.5, weight: .regular)
        durationLabel.textColor = NSColor(white: 0.45, alpha: 1.0)
        durationLabel.alignment = .right
        addSubview(durationLabel)
    }

    override func layout() {
        super.layout()
        let w = bounds.width
        thumbWrap.frame = NSRect(x: 4.5, y: 4.5, width: 57, height: 57)
        artView.frame = NSRect(x: 0, y: 0, width: 57, height: 57)

        let durW: CGFloat = (item.duration?.isEmpty == false) ? 55 : 0
        let textW = max(10, w - 69 - durW - 6)

        titleLabel.frame = NSRect(x: 69, y: 8, width: textW, height: 22)
        subtitleLabel.frame = NSRect(x: 69, y: 34, width: textW, height: 20)

        if durW > 0 {
            durationLabel.frame = NSRect(x: w - durW - 6, y: 22, width: durW, height: 20)
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

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        if superview == nil {
            artworkTask?.cancel()
            isHovered = false
            MotionCoordinator.shared.cancelAll(owner: cardMotionID)
        }
    }

    override func viewDidHide() {
        super.viewDidHide()
        isHovered = false
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) { isHovered = false }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }

    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) {
            let key = TransitionKey(owner: cardMotionID, channel: "select")
            let ticket = MotionCoordinator.shared.beginTransition(for: key, category: .controlInteraction)
            if !MotionCoordinator.shared.isReduceMotionEnabled {
                MotionCoordinator.shared.animate(duration: MotionTokens.Duration.cardSelect, ticket: ticket, action: {
                    self.animator().alphaValue = 0.85
                }) { [weak self] _ in
                    self?.alphaValue = 1.0
                }
            } else {
                _ = MotionCoordinator.shared.complete(ticket)
            }
            onClick?()
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let rect = bounds.insetBy(dx: 1, dy: 1)
        let path = NSBezierPath(roundedRect: rect, xRadius: 7.5, yRadius: 7.5)

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
    public var onContextMenuRequested: (() -> NSMenu?)?

    override func menu(for event: NSEvent) -> NSMenu? {
        onContextMenuRequested?()
    }

    private let cardMotionID = "MediaGridCard-\(UUID().uuidString)"
    private var trackingArea: NSTrackingArea?
    private var artworkTask: Task<Void, Never>?
    private var isHovered: Bool = false {
        didSet {
            guard oldValue != isHovered else { return }
            updateHoverOverlay(animated: true)
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
        super.init(frame: NSRect(x: 0, y: 0, width: 150, height: 210))
        setupGridCard()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupGridCard() {
        wantsLayer = true

        thumbWrap.wantsLayer = true
        thumbWrap.layer?.cornerRadius = 9
        thumbWrap.layer?.masksToBounds = true
        addSubview(thumbWrap)

        artView.imageScaling = .scaleProportionallyUpOrDown
        artView.image = NSImage(systemSymbolName: "music.note", accessibilityDescription: item.title)
        artView.wantsLayer = true
        thumbWrap.addSubview(artView)

        // Play hover overlay (M21: 120ms fade-in, zero per-card NSGlassEffectView creation)
        playHoverOverlay.image = NSImage(systemSymbolName: "play.circle.fill", accessibilityDescription: "Play")
        playHoverOverlay.contentTintColor = NSColor(white: 1.0, alpha: 0.92)
        playHoverOverlay.wantsLayer = true
        playHoverOverlay.alphaValue = 0.0
        playHoverOverlay.isHidden = true
        thumbWrap.addSubview(playHoverOverlay)

        // Corner Badge
        let badgeW: CGFloat = CGFloat(item.type.rawValue.count * 11 + 8)
        let badge = ItemBadgeView(text: item.type.rawValue, bgColor: item.type.badgeColor)
        badge.frame = NSRect(x: 6, y: 6, width: badgeW, height: 16)
        thumbWrap.addSubview(badge)

        // Load artwork asynchronously via ImageCacheV2
        if let artURL = item.artworkURL {
            artworkTask = Task { [weak artView] in
                let img = await ImageCacheV2.shared.image(for: artURL, targetPixelSize: 320)
                guard !Task.isCancelled else { return }
                if let img {
                    await MainActor.run {
                        artView?.image = img
                    }
                }
            }
        }

        // Labels
        titleLabel.stringValue = item.title
        titleLabel.font = NSFont.systemFont(ofSize: 14, weight: .semibold)
        titleLabel.textColor = NSColor(calibratedRed: 0.95, green: 0.95, blue: 0.95, alpha: 1.0)
        titleLabel.lineBreakMode = .byTruncatingTail
        addSubview(titleLabel)

        subtitleLabel.stringValue = item.subtitle
        subtitleLabel.font = NSFont.systemFont(ofSize: 12.5, weight: .regular)
        subtitleLabel.textColor = NSColor(calibratedRed: 0.60, green: 0.60, blue: 0.65, alpha: 1.0)
        subtitleLabel.lineBreakMode = .byTruncatingTail
        addSubview(subtitleLabel)
    }

    override func layout() {
        super.layout()
        let w = bounds.width
        let artSize = max(50, w - 12)

        thumbWrap.frame = NSRect(x: 6, y: 6, width: artSize, height: artSize)
        artView.frame = NSRect(x: 0, y: 0, width: artSize, height: artSize)
        playHoverOverlay.frame = NSRect(x: (artSize - 42) / 2, y: (artSize - 42) / 2, width: 42, height: 42)

        let textY = 6 + artSize + 4
        titleLabel.frame = NSRect(x: 6, y: textY, width: artSize, height: 20)
        subtitleLabel.frame = NSRect(x: 6, y: textY + 20, width: artSize, height: 18)
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

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        if superview == nil {
            artworkTask?.cancel()
            isHovered = false
            MotionCoordinator.shared.cancelAll(owner: cardMotionID)
        }
    }

    override func viewDidHide() {
        super.viewDidHide()
        isHovered = false
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) { isHovered = false }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }

    private func updateHoverOverlay(animated: Bool) {
        let key = TransitionKey(owner: cardMotionID, channel: "hover")
        let ticket = MotionCoordinator.shared.beginTransition(for: key, category: .controlInteraction)
        let show = isHovered
        if show { playHoverOverlay.isHidden = false }

        if !animated || MotionCoordinator.shared.isReduceMotionEnabled {
            playHoverOverlay.alphaValue = show ? 1.0 : 0.0
            playHoverOverlay.isHidden = !show
            _ = MotionCoordinator.shared.complete(ticket)
            return
        }

        MotionCoordinator.shared.animate(
            duration: MotionTokens.Duration.cardHover,
            timingFunction: .easeOut,
            ticket: ticket,
            action: {
                self.playHoverOverlay.animator().alphaValue = show ? 1.0 : 0.0
            },
            completion: { [weak self] committed in
                guard committed, let self, !self.isHovered else { return }
                self.playHoverOverlay.isHidden = true
            }
        )
    }

    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) {
            let key = TransitionKey(owner: cardMotionID, channel: "select")
            let ticket = MotionCoordinator.shared.beginTransition(for: key, category: .controlInteraction)
            if !MotionCoordinator.shared.isReduceMotionEnabled {
                MotionCoordinator.shared.animate(duration: MotionTokens.Duration.cardSelect, ticket: ticket, action: {
                    self.animator().alphaValue = 0.85
                }) { [weak self] _ in
                    self?.alphaValue = 1.0
                }
            } else {
                _ = MotionCoordinator.shared.complete(ticket)
            }
            onClick?()
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let rect = bounds.insetBy(dx: 1, dy: 1)
        let path = NSBezierPath(roundedRect: rect, xRadius: 9, yRadius: 9)

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
        NSSize(width: NSView.noIntrinsicMetric, height: 42)
    }

    public var onClick: (() -> Void)?
    public var onContextMenuRequested: (() -> NSMenu?)?

    override func menu(for event: NSEvent) -> NSMenu? {
        onContextMenuRequested?()
    }

    private let cardMotionID = "MediaCardRow-\(UUID().uuidString)"
    private var trackingArea: NSTrackingArea?
    private var artworkTask: Task<Void, Never>?
    private var isHovered: Bool = false {
        didSet {
            guard oldValue != isHovered else { return }
            needsDisplay = true
        }
    }

    private let indexLabel = NSTextField(labelWithString: "")
    private let titleLabel = NSTextField(labelWithString: "")
    private let artistLabel = NSTextField(labelWithString: "")
    private let durLabel = NSTextField(labelWithString: "")

    init(index: Int, track: MusicTrack) {
        super.init(frame: NSRect(x: 0, y: 0, width: 200, height: 42))
        wantsLayer = true

        indexLabel.stringValue = "\(index)"
        indexLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 13.5, weight: .regular)
        indexLabel.textColor = NSColor(white: 0.45, alpha: 1.0)
        indexLabel.alignment = .center
        addSubview(indexLabel)

        titleLabel.stringValue = track.title
        titleLabel.font = NSFont.systemFont(ofSize: 14.5, weight: .medium)
        titleLabel.textColor = NSColor(calibratedWhite: 0.90, alpha: 1.0)
        titleLabel.lineBreakMode = .byTruncatingTail
        addSubview(titleLabel)

        artistLabel.stringValue = track.artistName
        artistLabel.font = NSFont.systemFont(ofSize: 12.5, weight: .regular)
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
        durLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 12.5, weight: .regular)
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
        indexLabel.frame = NSRect(x: 3, y: 9, width: 30, height: 24)
        durLabel.frame = NSRect(x: w - 57, y: 9, width: 51, height: 24)

        let bodyW = max(10, w - 36 - 60)
        titleLabel.frame = NSRect(x: 36, y: 3, width: bodyW, height: 20)
        artistLabel.frame = NSRect(x: 36, y: 22, width: bodyW, height: 18)
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

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        if superview == nil {
            isHovered = false
        }
    }

    override func viewDidHide() {
        super.viewDidHide()
        isHovered = false
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
            let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 6, yRadius: 6)
            NSColor(calibratedRed: 0.79, green: 0.79, blue: 0.79, alpha: 0.08).setFill()
            path.fill()
        }
    }
}

// MARK: - DetailOverlayView (Slide-over drawer for Album/Playlist tracks)

final class DetailOverlayView: NSView {
    override var isFlipped: Bool { true }

    public var onBack: (() -> Void)?
    public var onPlayIntent: ((MediaPlayIntent) -> Void)?
    public var playMenuDescriptorProvider: (() -> MediaActionMenuDescriptor)?
    public var onDetailContextMenuRequested: (() -> NSMenu?)?
    public var onTrackSelected: ((MusicTrack) -> Void)?
    public var onTrackIndexSelected: ((Int, MusicTrack) -> Void)?
    public var onTrackContextMenuRequested: ((MusicTrack) -> NSMenu?)?

    public var topContentInset: CGFloat = 0 {
        didSet {
            guard oldValue != topContentInset else { return }
            updateTrackStackInsets()
            needsLayout = true
        }
    }

    private let headerHeight: CGFloat = 36
    private let headerTopGap: CGFloat = 4
    private let headerView = NSView()
    private let headerGlassView = NSGlassEffectView(frame: .zero)
    private let backButton = NSButton()
    private let titleLabel = NSTextField(labelWithString: "")
    private let playMenuButton = MediaPlayCapsuleButton()
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

        // Track List Scroll with FlippedClipView (added first so scrolled tracks pass underneath the pinned Liquid Glass header)
        let clip = FlippedClipView()
        clip.drawsBackground = false
        scrollView.contentView = clip
        scrollView.drawsBackground = false
        scrollView.applySubtleOverlayScrollbar()

        trackStack.orientation = .vertical
        trackStack.alignment = .leading
        trackStack.spacing = 2
        updateTrackStackInsets()
        trackStack.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = trackStack
        addSubview(scrollView)

        NSLayoutConstraint.activate([
            trackStack.leadingAnchor.constraint(equalTo: scrollView.contentView.leadingAnchor),
            trackStack.trailingAnchor.constraint(equalTo: scrollView.contentView.trailingAnchor),
            trackStack.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor)
        ])

        // Pinned Liquid Glass Header floating above scrollView
        headerView.wantsLayer = true
        headerGlassView.style = .regular
        headerGlassView.cornerRadius = headerHeight * 0.5
        headerGlassView.autoresizingMask = [.width, .height]
        headerView.addSubview(headerGlassView, positioned: .below, relativeTo: nil)
        addSubview(headerView)

        backButton.title = "← 返回"
        backButton.font = NSFont.systemFont(ofSize: 13.5, weight: .medium)
        backButton.bezelStyle = .recessed
        backButton.isBordered = false
        backButton.contentTintColor = NSColor(calibratedWhite: 0.90, alpha: 1.0)
        backButton.target = self
        backButton.action = #selector(backClicked)
        headerView.addSubview(backButton)

        titleLabel.font = NSFont.systemFont(ofSize: 14.5, weight: .semibold)
        titleLabel.textColor = NSColor(calibratedWhite: 0.94, alpha: 1.0)
        titleLabel.lineBreakMode = .byTruncatingTail
        headerView.addSubview(titleLabel)

        playMenuButton.titleText = "播放"
        playMenuButton.menuDescriptorProvider = { [weak self] in
            self?.playMenuDescriptorProvider?() ?? MediaActionMenuDescriptor(sections: [])
        }
        playMenuButton.onSelectIntent = { [weak self] intent in
            self?.onPlayIntent?(intent)
        }
        headerView.addSubview(playMenuButton)

        loadingIndicator.style = .spinning
        loadingIndicator.controlSize = .small
        loadingIndicator.isDisplayedWhenStopped = false
        addSubview(loadingIndicator)

        emptyLabel.font = NSFont.systemFont(ofSize: 14, weight: .regular)
        emptyLabel.textColor = NSColor(white: 0.5, alpha: 1.0)
        emptyLabel.alignment = .center
        emptyLabel.isHidden = true
        addSubview(emptyLabel)
    }

    private func updateTrackStackInsets() {
        let topOffset = topContentInset + headerTopGap + headerHeight + 6
        trackStack.edgeInsets = NSEdgeInsets(top: topOffset, left: 3, bottom: 12, right: 3)
    }

    override func layout() {
        super.layout()
        let w = bounds.width
        let h = bounds.height
        let headerY = topContentInset + headerTopGap

        scrollView.frame = bounds

        headerView.frame = NSRect(x: 4, y: headerY, width: max(40, w - 8), height: headerHeight)
        headerGlassView.frame = headerView.bounds
        headerGlassView.cornerRadius = headerHeight * 0.5

        let hw = headerView.bounds.width
        backButton.frame = NSRect(x: 8, y: (headerHeight - 26) / 2, width: 66, height: 26)
        playMenuButton.frame = NSRect(x: hw - 96 - 5, y: (headerHeight - 28) / 2, width: 96, height: 28)
        titleLabel.frame = NSRect(x: 76, y: (headerHeight - 20) / 2, width: max(10, hw - 76 - 106), height: 20)

        let contentTop = headerY + headerHeight
        let contentH = max(10, h - contentTop)
        loadingIndicator.frame = NSRect(x: (w - 28) / 2, y: contentTop + (contentH - 28) / 2, width: 28, height: 28)
        emptyLabel.frame = NSRect(x: 0, y: contentTop + (contentH - 28) / 2, width: w, height: 28)

        for sub in trackStack.arrangedSubviews {
            sub.widthAnchor.constraint(equalToConstant: max(100, w - 12)).isActive = true
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
                row.heightAnchor.constraint(equalToConstant: 42).isActive = true
                row.widthAnchor.constraint(equalToConstant: max(100, bounds.width - 12)).isActive = true
                row.onClick = { [weak self] in
                    self?.onTrackIndexSelected?(idx, track)
                    self?.onTrackSelected?(track)
                }
                row.onContextMenuRequested = { [weak self] in
                    self?.onTrackContextMenuRequested?(track)
                }
                trackStack.addArrangedSubview(row)
            }
        }
    }

    @objc private func backClicked() {
        AppLogger.shared.log(category: .userAction, level: .info, message: "用户点击详情抽屉 [← 返回] 按钮")
        onBack?()
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard !currentTracks.isEmpty else { return nil }
        return onDetailContextMenuRequested?()
    }
}

// MARK: - LibraryContentView

/// Right content view presenting media cards (1-col rows or 2-col grid) and slide-over DetailView.
@MainActor
open class LibraryContentView: NSView {

    open override var isFlipped: Bool { true }

    public var onItemClicked: ((MediaCardItem) -> Void)?
    public var onItemContextMenuRequested: ((MediaCardItem) -> NSMenu?)?
    public var onTrackSelected: ((MusicTrack) -> Void)?
    public var onTrackIndexSelected: ((Int, MusicTrack) -> Void)?
    public var onTrackContextMenuRequested: ((MusicTrack) -> NSMenu?)?
    public var onDetailPlayIntent: (([MusicTrack], MediaPlayIntent) -> Void)?
    public var detailPlayMenuDescriptorProvider: (() -> MediaActionMenuDescriptor)?
    public var onDetailContextMenuRequested: (([MusicTrack]) -> NSMenu?)?
    public var onReachedBottom: (() -> Void)?

    public private(set) var is2Col: Bool = true
    public private(set) var columnCountOverride: Int? = nil
    public var topContentInset: CGFloat = 0 {
        didSet {
            guard oldValue != topContentInset else { return }
            stackView.edgeInsets = NSEdgeInsets(top: topContentInset + 4, left: 3, bottom: 12, right: 3)
            detailOverlay.topContentInset = topContentInset
            needsLayout = true
        }
    }

    private let titleLabel = NSTextField(labelWithString: "为你推荐")
    private let scrollView = NSScrollView()
    private let stackView = FlippedStackView()
    private let loadingIndicator = NSProgressIndicator()
    private let emptyLabel = NSTextField(labelWithString: "没有找到相关项目")
    private let detailOverlay = DetailOverlayView()

    private let contentMotionID = "LibraryContentView-\(UUID().uuidString)"
    private var titleWidthConstraint: NSLayoutConstraint?
    private var titleHeightConstraint: NSLayoutConstraint?
    private var currentItems: [MediaCardItem] = []
    private var currentDetailTracks: [MusicTrack] = []

    public var currentDetailTracksList: [MusicTrack] { currentDetailTracks }
    public var displayedItems: [MediaCardItem] { currentItems }
    public var currentTitleText: String { titleLabel.stringValue }
    public var currentScrollOrigin: NSPoint { scrollView.contentView.bounds.origin }

    public func restoreScrollOrigin(_ origin: NSPoint) {
        layoutSubtreeIfNeeded()
        scrollView.contentView.scroll(to: origin)
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

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

        titleLabel.font = NSFont.systemFont(ofSize: 16.5, weight: .bold)
        titleLabel.textColor = DesignTokens.Colors.primaryText
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        // Use FlippedClipView so content always pins to top!
        let clip = FlippedClipView()
        clip.drawsBackground = false
        clip.postsBoundsChangedNotifications = true
        scrollView.contentView = clip
        scrollView.drawsBackground = false
        scrollView.applySubtleOverlayScrollbar()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleScrollBoundsChanged),
            name: NSView.boundsDidChangeNotification,
            object: clip
        )

        stackView.orientation = .vertical
        stackView.alignment = .leading
        stackView.spacing = 6
        stackView.edgeInsets = NSEdgeInsets(top: topContentInset + 4, left: 3, bottom: 12, right: 3)
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

        emptyLabel.font = NSFont.systemFont(ofSize: 14, weight: .regular)
        emptyLabel.textColor = DesignTokens.Colors.tertiaryText
        emptyLabel.alignment = .center
        emptyLabel.isHidden = true
        addSubview(emptyLabel)

        // Detail overlay starts hidden
        detailOverlay.topContentInset = topContentInset
        detailOverlay.isHidden = true
        detailOverlay.onBack = { [weak self] in
            self?.hideDetail()
        }
        detailOverlay.playMenuDescriptorProvider = { [weak self] in
            self?.detailPlayMenuDescriptorProvider?() ?? MediaActionMenuDescriptor(sections: [])
        }
        detailOverlay.onPlayIntent = { [weak self] intent in
            guard let self else { return }
            self.onDetailPlayIntent?(self.currentDetailTracks, intent)
        }
        detailOverlay.onDetailContextMenuRequested = { [weak self] in
            guard let self else { return nil }
            return self.onDetailContextMenuRequested?(self.currentDetailTracks)
        }
        detailOverlay.onTrackIndexSelected = { [weak self] idx, track in
            self?.onTrackIndexSelected?(idx, track)
        }
        detailOverlay.onTrackSelected = { [weak self] track in
            self?.onTrackSelected?(track)
        }
        detailOverlay.onTrackContextMenuRequested = { [weak self] track in
            self?.onTrackContextMenuRequested?(track)
        }
        addSubview(detailOverlay)
    }

    open override func layout() {
        super.layout()
        scrollView.frame = bounds
        let contentH = max(10, bounds.height - topContentInset)
        loadingIndicator.frame = NSRect(x: (bounds.width - 28) / 2, y: topContentInset + (contentH - 28) / 2, width: 28, height: 28)
        emptyLabel.frame = NSRect(x: 0, y: topContentInset + (contentH - 28) / 2, width: bounds.width, height: 28)
        detailOverlay.topContentInset = topContentInset
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

    public func setColumnCountOverride(_ count: Int?) {
        guard columnCountOverride != count else { return }
        columnCountOverride = count
    }

    public func appendItems(_ moreItems: [MediaCardItem]) {
        guard !moreItems.isEmpty else { return }
        let savedOrigin = scrollView.contentView.bounds.origin
        let merged = currentItems + moreItems
        displayItems(merged, animated: false)
        scrollView.contentView.scroll(to: savedOrigin)
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    @objc private func handleScrollBoundsChanged() {
        guard let docView = scrollView.documentView, !currentItems.isEmpty, detailOverlay.isHidden else { return }
        let visibleMaxY = scrollView.contentView.bounds.maxY
        let docH = docView.bounds.height
        if docH > 0, visibleMaxY >= docH - 120 {
            onReachedBottom?()
        }
    }

    public func displayItems(_ items: [MediaCardItem], animated: Bool = false) {
        self.currentItems = items
        detailOverlay.isHidden = true
        stackView.arrangedSubviews.forEach { $0.removeFromSuperview() }
        emptyLabel.isHidden = !items.isEmpty

        let key = TransitionKey(owner: contentMotionID, channel: "crossfade")
        let ticket = MotionCoordinator.shared.beginTransition(for: key, category: .content)
        if animated && !MotionCoordinator.shared.isReduceMotionEnabled && window != nil && !isHidden {
            scrollView.alphaValue = 0.25
            MotionCoordinator.shared.animate(
                duration: MotionTokens.Duration.categoryCrossfade,
                timingFunction: .easeOut,
                ticket: ticket,
                action: {
                    self.scrollView.animator().alphaValue = 1.0
                }
            )
        } else {
            scrollView.alphaValue = 1.0
            _ = MotionCoordinator.shared.complete(ticket)
        }

        let headerWidth = max(100, bounds.width - 14)
        if let titleWidthConstraint {
            titleWidthConstraint.constant = headerWidth
        } else {
            let w = titleLabel.widthAnchor.constraint(equalToConstant: headerWidth)
            w.isActive = true
            titleWidthConstraint = w
        }
        if titleHeightConstraint == nil {
            let h = titleLabel.heightAnchor.constraint(equalToConstant: 24)
            h.isActive = true
            titleHeightConstraint = h
        }
        stackView.addArrangedSubview(titleLabel)

        AppLogger.shared.log(
            category: .render,
            level: .info,
            message: "LibraryContentView 渲染 \(items.count) 个卡片项目 (模式: \(is2Col ? "双栏卡片" : "单栏列表"), 宽: \(Int(bounds.width)))",
            details: items.first.map { "首项: [\($0.type.rawValue)] \($0.title) - \($0.subtitle)" }
        )

        let availableWidth = max(100, bounds.width - 14)

        let cols = columnCountOverride ?? (is2Col ? 2 : 1)
        if cols >= 2 {
            let spacing: CGFloat = 9
            let cardWidth = max(40, (availableWidth - spacing * CGFloat(cols - 1)) / CGFloat(cols))
            let cardHeight = cardWidth + (cols >= 3 ? 46 : 54)

            var i = 0
            while i < items.count {
                let rowStack = NSStackView()
                rowStack.orientation = .horizontal
                rowStack.spacing = spacing
                rowStack.distribution = .fillEqually
                rowStack.translatesAutoresizingMaskIntoConstraints = false
                rowStack.heightAnchor.constraint(equalToConstant: cardHeight).isActive = true
                rowStack.widthAnchor.constraint(equalToConstant: availableWidth).isActive = true

                for col in 0..<cols {
                    if i + col < items.count {
                        let item = items[i + col]
                        let card = MediaGridCardView(item: item)
                        card.onClick = { [weak self] in
                            self?.onItemClicked?(item)
                        }
                        card.onContextMenuRequested = { [weak self] in
                            self?.onItemContextMenuRequested?(item)
                        }
                        rowStack.addArrangedSubview(card)
                    } else {
                        let spacer = NSView()
                        spacer.translatesAutoresizingMaskIntoConstraints = false
                        rowStack.addArrangedSubview(spacer)
                    }
                }

                stackView.addArrangedSubview(rowStack)
                i += cols
            }
        } else {
            // 1-Column Row Layout (66px)
            for item in items {
                let row = MediaCardRowView(item: item)
                row.translatesAutoresizingMaskIntoConstraints = false
                row.heightAnchor.constraint(equalToConstant: 66).isActive = true
                row.widthAnchor.constraint(equalToConstant: availableWidth).isActive = true
                row.onClick = { [weak self] in
                    self?.onItemClicked?(item)
                }
                row.onContextMenuRequested = { [weak self] in
                    self?.onItemContextMenuRequested?(item)
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
        detailOverlay.topContentInset = topContentInset
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
