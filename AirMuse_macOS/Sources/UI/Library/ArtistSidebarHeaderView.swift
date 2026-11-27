import AppKit
import DesignSystem

// MARK: - ArtistSidebarHeaderView

/// Floating Liquid Glass artist profile stack placed above the left sidebar:
/// 1. Aspect-matched Liquid Glass card displaying the artist cover/portrait.
/// 2. Three separate circular Liquid Glass buttons (`!`, `★`, `···`) below the cover.
@MainActor
public final class ArtistSidebarHeaderView: NSView {

    public override var isFlipped: Bool { true }

    public var onInfoClicked: ((NSView) -> Void)?
    public var onFavoriteClicked: (() -> Void)?
    public var onMoreClicked: ((NSView) -> Void)?
    public var onPreferredHeightChanged: (() -> Void)?

    private let glassContainer = NSGlassEffectContainerView(frame: .zero)
    private let coverGlass = NSGlassEffectView(frame: .zero)
    private let infoGlass = NSGlassEffectView(frame: .zero)
    private let favoriteGlass = NSGlassEffectView(frame: .zero)
    private let moreGlass = NSGlassEffectView(frame: .zero)

    private let coverFallbackLayer = CALayer()
    private let avatarView = NSImageView()
    private let infoButton = NSButton()
    private let favoriteButton = NSButton()
    private let moreButton = NSButton()

    private var imageTask: Task<Void, Never>?
    private var currentArtworkURL: URL?
    private var isFavorited: Bool = false
    private var coverAspectRatio: CGFloat = 1.0 // height / width

    public static let defaultWidth: CGFloat = 126
    public static let buttonSize: CGFloat = 30
    public static let verticalGap: CGFloat = 8

    public static let preferredHeight: CGFloat = 126 + verticalGap + buttonSize

    public var currentPreferredHeight: CGFloat {
        let w = bounds.width > 10 ? bounds.width : Self.defaultWidth
        let coverH = round(w * min(max(coverAspectRatio, 0.65), 1.35))
        return coverH + Self.verticalGap + Self.buttonSize
    }

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    isolated deinit {
        NotificationCenter.default.removeObserver(self)
        imageTask?.cancel()
    }

    private func setup() {
        wantsLayer = true

        glassContainer.spacing = 6
        addSubview(glassContainer)

        coverGlass.style = .regular
        coverGlass.cornerRadius = 12
        glassContainer.addSubview(coverGlass)

        for glassBtn in [infoGlass, favoriteGlass, moreGlass] {
            glassBtn.style = .regular
            glassBtn.cornerRadius = Self.buttonSize * 0.5
            glassContainer.addSubview(glassBtn)
        }

        coverFallbackLayer.backgroundColor = NSColor(srgbRed: 24 / 255.0, green: 26 / 255.0, blue: 30 / 255.0, alpha: 0.94).cgColor
        coverFallbackLayer.borderColor = NSColor(white: 1.0, alpha: 0.14).cgColor
        coverFallbackLayer.borderWidth = 0.75
        coverFallbackLayer.cornerRadius = 12
        layer?.addSublayer(coverFallbackLayer)

        avatarView.wantsLayer = true
        avatarView.imageScaling = .scaleAxesIndependently
        avatarView.layer?.cornerRadius = 12
        avatarView.layer?.masksToBounds = true
        avatarView.layer?.backgroundColor = NSColor(white: 1.0, alpha: 0.06).cgColor
        avatarView.image = NSImage(systemSymbolName: "music.mic", accessibilityDescription: nil)
        avatarView.contentTintColor = NSColor(white: 0.65, alpha: 1.0)
        coverGlass.contentView = avatarView

        configureActionButton(infoButton, in: infoGlass, symbolName: "exclamationmark", tooltip: "艺人基本信息", action: #selector(infoTapped))
        configureActionButton(favoriteButton, in: favoriteGlass, symbolName: "star", tooltip: "收藏艺人", action: #selector(favoriteTapped))
        configureActionButton(moreButton, in: moreGlass, symbolName: "ellipsis", tooltip: "更多选项", action: #selector(moreTapped))

        updateMaterialMode()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(updateMaterialMode),
            name: GlassInteractionCoordinator.modeDidChangeNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(updateMaterialMode),
            name: MotionAccessibility.preferencesDidChangeNotification,
            object: nil
        )
    }

    @objc private func updateMaterialMode() {
        let useGlass = GlassInteractionCoordinator.shared.isEnhancedMode && !MotionCoordinator.shared.isReduceTransparencyEnabled
        coverFallbackLayer.isHidden = useGlass
    }

    private func configureActionButton(_ btn: NSButton, in glass: NSGlassEffectView, symbolName: String, tooltip: String, action: Selector) {
        btn.bezelStyle = .regularSquare
        btn.isBordered = false
        btn.toolTip = tooltip
        btn.target = self
        btn.action = action
        let cfg = NSImage.SymbolConfiguration(pointSize: 13.0, weight: .semibold)
        btn.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: tooltip)?.withSymbolConfiguration(cfg)
        btn.contentTintColor = NSColor(white: 0.92, alpha: 1.0)
        glass.contentView = btn
    }

    public func configure(artworkURL: URL?, isFavorited: Bool) {
        setFavorited(isFavorited)
        guard currentArtworkURL != artworkURL else { return }
        currentArtworkURL = artworkURL
        imageTask?.cancel()

        guard let url = artworkURL else {
            coverAspectRatio = 1.0
            avatarView.image = NSImage(systemSymbolName: "music.mic", accessibilityDescription: nil)
            needsLayout = true
            onPreferredHeightChanged?()
            return
        }

        imageTask = Task { @MainActor [weak self] in
            do {
                let (data, _) = try await URLSession.shared.data(from: url)
                guard !Task.isCancelled, let self, self.currentArtworkURL == url else { return }
                if let img = NSImage(data: data) {
                    if img.size.width > 1, img.size.height > 1 {
                        self.coverAspectRatio = img.size.height / img.size.width
                    } else {
                        self.coverAspectRatio = 1.0
                    }
                    self.avatarView.image = img
                    self.needsLayout = true
                    self.onPreferredHeightChanged?()
                }
            } catch {}
        }
    }

    public func setFavorited(_ favorited: Bool) {
        isFavorited = favorited
        let symbol = favorited ? "star.fill" : "star"
        let cfg = NSImage.SymbolConfiguration(pointSize: 13.0, weight: .semibold)
        favoriteButton.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "收藏艺人")?.withSymbolConfiguration(cfg)
        favoriteButton.contentTintColor = favorited
            ? NSColor(red: 0.98, green: 0.25, blue: 0.38, alpha: 1.0)
            : NSColor(white: 0.92, alpha: 1.0)
        favoriteButton.toolTip = favorited ? "已收藏艺人（点击取消）" : "收藏艺人"
    }

    public override func layout() {
        super.layout()
        let w = bounds.width
        let h = bounds.height
        let btnSize = Self.buttonSize
        let gap = Self.verticalGap
        let coverH = max(40, h - btnSize - gap)

        // Note: NSGlassEffectContainerView is non-flipped (y = 0 is bottom)!
        // Cover goes on TOP (y = btnSize + gap), 3 circular glass buttons go on BOTTOM (y = 0).
        glassContainer.frame = bounds
        let coverRect = NSRect(x: 0, y: btnSize + gap, width: w, height: coverH)
        coverGlass.frame = coverRect
        coverGlass.cornerRadius = 12

        let btnSpacing: CGFloat = 12
        let totalW = btnSize * 3 + btnSpacing * 2
        let startX = (w - totalW) * 0.5
        infoGlass.frame = NSRect(x: startX, y: 0, width: btnSize, height: btnSize)
        favoriteGlass.frame = NSRect(x: startX + btnSize + btnSpacing, y: 0, width: btnSize, height: btnSize)
        moreGlass.frame = NSRect(x: startX + (btnSize + btnSpacing) * 2, y: 0, width: btnSize, height: btnSize)

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // coverFallbackLayer lives in self (flipped), so y = 0 is top
        coverFallbackLayer.frame = NSRect(x: 0, y: 0, width: w, height: coverH)
        CATransaction.commit()
    }

    @objc private func infoTapped() { onInfoClicked?(infoGlass) }
    @objc private func favoriteTapped() { onFavoriteClicked?() }
    @objc private func moreTapped() { onMoreClicked?(moreGlass) }

    // MARK: - Z-Axis Pass-Through Protection

    public override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden, alphaValue > 0.01 else { return nil }
        let local = convert(point, from: superview)
        guard bounds.contains(local) else { return nil }
        return super.hitTest(point) ?? self
    }

    public override func mouseDown(with event: NSEvent) {}
    public override func mouseUp(with event: NSEvent) {}
    public override func rightMouseDown(with event: NSEvent) {}
    public override func otherMouseDown(with event: NSEvent) {}
    public override func scrollWheel(with event: NSEvent) {}
}
