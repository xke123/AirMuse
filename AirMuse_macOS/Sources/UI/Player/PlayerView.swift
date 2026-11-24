import AppKit
import QuartzCore
import ImageIO
import Domain
import DesignSystem
import Playback
import Infrastructure

// MARK: - ArtworkAmbientAnalyzer (M16 / M17 Off-MainActor Cache)

/// Decodes album artwork bytes and extracts a localized ambient color strictly off-MainActor,
/// caching results by `trackKey` so rapid track changes never block UI or commit stale colors.
private actor ArtworkAmbientAnalyzer {
    static let shared = ArtworkAmbientAnalyzer()

    private var colorCache: [String: NSColor] = [:]
    private var colorOrder: [String] = []
    private let maxColorEntries = 64

    func cachedColor(for trackKey: String) -> NSColor? {
        colorCache[trackKey]
    }

    func decodeAndExtractColor(data: Data, trackKey: String, maxPixelSize: Int) -> (NSImage?, NSColor?) {
        let cfData = data as CFData
        guard let source = CGImageSourceCreateWithData(cfData, nil) else {
            return (nil, colorCache[trackKey])
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(48, maxPixelSize)
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return (NSImage(data: data), colorCache[trackKey])
        }
        let nsImage = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        let color = extractAndCacheColor(from: cgImage, trackKey: trackKey)
        return (nsImage, color)
    }

    func extractAndCacheColor(from cgImage: CGImage, trackKey: String) -> NSColor? {
        if let hit = colorCache[trackKey] {
            return hit
        }
        let sampleW = 12
        let sampleH = 12
        let cs = CGColorSpaceCreateDeviceRGB()
        var bytes = [UInt8](repeating: 0, count: sampleW * sampleH * 4)
        guard let ctx = CGContext(
            data: &bytes,
            width: sampleW,
            height: sampleH,
            bitsPerComponent: 8,
            bytesPerRow: sampleW * 4,
            space: cs,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        ctx.interpolationQuality = .low
        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: sampleW, height: sampleH))

        var sumR: Double = 0
        var sumG: Double = 0
        var sumB: Double = 0
        var weightSum: Double = 0

        for i in stride(from: 0, to: bytes.count, by: 4) {
            let r = Double(bytes[i]) / 255.0
            let g = Double(bytes[i + 1]) / 255.0
            let b = Double(bytes[i + 2]) / 255.0
            let maxC = max(r, max(g, b))
            let minC = min(r, min(g, b))
            let sat = maxC > 0 ? (maxC - minC) / maxC : 0
            let w = 0.25 + sat * 1.5
            sumR += r * w
            sumG += g * w
            sumB += b * w
            weightSum += w
        }
        guard weightSum > 0 else { return nil }
        let color = NSColor(
            srgbRed: CGFloat(sumR / weightSum),
            green: CGFloat(sumG / weightSum),
            blue: CGFloat(sumB / weightSum),
            alpha: 1.0
        )

        if colorCache[trackKey] == nil {
            if colorOrder.count >= maxColorEntries, let oldest = colorOrder.first {
                colorOrder.removeFirst()
                colorCache.removeValue(forKey: oldest)
            }
            colorOrder.append(trackKey)
        }
        colorCache[trackKey] = color
        return color
    }
}

// MARK: - ScrubTimePreviewPill (M09)

@MainActor
private final class ScrubTimePreviewPill: NSView {
    private let glassView = NSGlassEffectView(frame: .zero)
    private let fallbackLayer = CALayer()
    private let label = NSTextField(labelWithString: "00:00")

    override var mouseDownCanMoveWindow: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    var text: String = "00:00" {
        didSet {
            if oldValue != text {
                label.stringValue = text
            }
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.masksToBounds = true

        fallbackLayer.backgroundColor = NSColor(srgbRed: 22/255.0, green: 24/255.0, blue: 28/255.0, alpha: 0.92).cgColor
        fallbackLayer.borderColor = NSColor(white: 1.0, alpha: 0.26).cgColor
        fallbackLayer.borderWidth = 0.75
        fallbackLayer.cornerRadius = 8
        layer?.addSublayer(fallbackLayer)

        glassView.style = .clear
        glassView.cornerRadius = 8
        glassView.autoresizingMask = [.width, .height]
        addSubview(glassView)

        label.font = NSFont.monospacedDigitSystemFont(ofSize: 9.5, weight: .semibold)
        label.textColor = OriginalDesignTokens.Colors.titleSilver
        label.alignment = .center
        addSubview(label)

        refreshMode()
    }

    func refreshMode() {
        let useGlass = GlassInteractionCoordinator.shared.isEnhancedMode && !MotionCoordinator.shared.isReduceTransparencyEnabled
        glassView.isHidden = !useGlass
        fallbackLayer.isHidden = useGlass
    }

    override func layout() {
        super.layout()
        glassView.frame = bounds
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        fallbackLayer.frame = bounds
        CATransaction.commit()
        label.frame = NSRect(x: 2, y: (bounds.height - 13) * 0.5, width: max(10, bounds.width - 4), height: 13)
    }
}

// MARK: - CapsuleProgressView (M09 + M24)

/// Custom-drawn AIRPLAY capsule progress bar with hover/scrub liquid expansion,
/// floating preview time pill, track-change cancellation, and bounded single-seek commit.
@MainActor
final class CapsuleProgressView: NSView {
    private let ownerID = "CapsuleProgress-\(UUID().uuidString)"

    var ratio: CGFloat = 0 {
        didSet {
            if abs(oldValue - ratio) > 0.0005 {
                needsDisplay = true
                updatePreviewPillPosition()
            }
        }
    }
    var durationMs: Int64 = 0 {
        didSet { updatePreviewPillText() }
    }
    var isHighlighted: Bool = false {
        didSet {
            guard oldValue != isHighlighted else { return }
            updateInteractionAppearance()
        }
    }
    var isScrubbing: Bool = false {
        didSet {
            guard oldValue != isScrubbing else { return }
            updateInteractionAppearance()
        }
    }

    var onSeek: ((CGFloat) -> Void)?
    var onScrubbingChanged: ((Bool, CGFloat) -> Void)?

    private let liquidHover = LiquidGlassControl()
    private let previewPill = ScrubTimePreviewPill()
    private var trackingArea: NSTrackingArea?
    private var expandFactor: CGFloat = 0.0
    private var expandDriverID: UUID?
    private var expandTicket: MotionTicket?

    override var mouseDownCanMoveWindow: Bool { false }
    override var acceptsFirstResponder: Bool { true }

    var isPreviewVisible: Bool { !previewPill.isHidden && previewPill.alphaValue > 0.01 }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = false
        liquidHover.cornerRadius = 5.0
        addSubview(liquidHover)

        previewPill.isHidden = true
        previewPill.alphaValue = 0.0
        addSubview(previewPill)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    isolated deinit {
        stopExpandDriver()
        MotionCoordinator.shared.cancelAll(owner: ownerID)
    }

    func cancelScrubbing() {
        let wasScrubbing = isScrubbing
        isScrubbing = false
        isHighlighted = false
        if wasScrubbing {
            onScrubbingChanged?(false, ratio)
        }
        updateInteractionAppearance()
    }

    override func viewDidHide() {
        super.viewDidHide()
        cancelScrubbing()
    }

    override func layout() {
        super.layout()
        let barH = max(5.0, bounds.height * 0.45)
        liquidHover.frame = NSRect(x: 0, y: (bounds.height - barH) * 0.5 - 2, width: bounds.width, height: barH + 4)
        liquidHover.cornerRadius = liquidHover.bounds.height * 0.5
        updatePreviewPillPosition()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = trackingArea { removeTrackingArea(existing) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        isHighlighted = true
    }

    override func mouseExited(with event: NSEvent) {
        if !isScrubbing { isHighlighted = false }
    }

    override func mouseDown(with event: NSEvent) {
        isScrubbing = true
        let r = ratioFrom(event: event)
        ratio = r
        updatePreviewPillText()
        updatePreviewPillPosition()
        onScrubbingChanged?(true, r)
    }

    override func mouseDragged(with event: NSEvent) {
        guard isScrubbing else { return }
        let r = ratioFrom(event: event)
        ratio = r
        updatePreviewPillText()
        updatePreviewPillPosition()
        onScrubbingChanged?(true, r)
    }

    override func mouseUp(with event: NSEvent) {
        guard isScrubbing else { return }
        let r = ratioFrom(event: event)
        ratio = r
        isScrubbing = false
        onScrubbingChanged?(false, r)
        onSeek?(r)
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 && isScrubbing { // Esc cancels scrub without seeking
            cancelScrubbing()
            return
        }
        if (event.keyCode == 123 || event.keyCode == 124), durationMs > 0 { // Left / Right 5s step
            let stepRatio = CGFloat(5000.0 / Double(durationMs))
            let next = min(max(ratio + (event.keyCode == 124 ? stepRatio : -stepRatio), 0), 1)
            ratio = next
            onSeek?(next)
            return
        }
        super.keyDown(with: event)
    }

    override func scrollWheel(with event: NSEvent) {
        guard GlassInteractionCoordinator.shared.enableTrackpadGestures,
              durationMs > 0,
              abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) * 1.5,
              abs(event.scrollingDeltaX) > 0.5 else {
            super.scrollWheel(with: event)
            return
        }
        let deltaRatio = (-event.scrollingDeltaX) / max(bounds.width, 120.0) * 0.5
        let next = min(max(ratio + deltaRatio, 0), 1)
        ratio = next
        if event.phase == .ended || event.momentumPhase == .ended || event.phase == [] {
            isScrubbing = false
            onScrubbingChanged?(false, next)
            onSeek?(next)
        } else {
            isScrubbing = true
            updatePreviewPillText()
            updatePreviewPillPosition()
            onScrubbingChanged?(true, next)
        }
    }

    private func ratioFrom(event: NSEvent) -> CGFloat {
        let pt = convert(event.locationInWindow, from: nil)
        guard bounds.width > 0 else { return 0 }
        return min(max(pt.x / bounds.width, 0), 1)
    }

    private func updateInteractionAppearance() {
        let active = isHighlighted || isScrubbing
        liquidHover.isActive = active
        previewPill.refreshMode()

        let showPill = isScrubbing && durationMs > 0
        if showPill {
            previewPill.isHidden = false
            updatePreviewPillText()
            updatePreviewPillPosition()
        }

        let targetExpand: CGFloat = isScrubbing ? 1.0 : (isHighlighted ? 0.55 : 0.0)
        let targetPillAlpha: CGFloat = showPill ? 1.0 : 0.0
        let dur = active ? MotionTokens.Duration.scrubExpand : MotionTokens.Duration.scrubRelease

        stopExpandDriver()
        let key = TransitionKey(owner: ownerID, channel: "expand")
        let ticket = MotionCoordinator.shared.beginTransition(for: key, category: .controlInteraction) { [weak self] in
            self?.stopExpandDriver()
        }
        expandTicket = ticket

        if MotionCoordinator.shared.isReduceMotionEnabled {
            expandFactor = targetExpand
            previewPill.alphaValue = targetPillAlpha
            previewPill.isHidden = !showPill
            _ = MotionCoordinator.shared.complete(ticket)
            expandTicket = nil
            needsDisplay = true
            return
        }

        let startExpand = expandFactor
        let startPillAlpha = previewPill.alphaValue
        var elapsed: TimeInterval = 0
        expandDriverID = MotionCoordinator.shared.displayDriver.start { [weak self] dt, _ in
            guard let self, MotionCoordinator.shared.isCurrent(ticket) else { return false }
            elapsed += dt
            let raw = min(1.0, elapsed / max(0.01, dur))
            let t = CGFloat(1.0 - pow(1.0 - raw, 3.0))
            self.expandFactor = startExpand + (targetExpand - startExpand) * t
            self.previewPill.alphaValue = startPillAlpha + (targetPillAlpha - startPillAlpha) * t
            self.needsDisplay = true
            if raw >= 1.0 {
                if MotionCoordinator.shared.complete(ticket) {
                    self.expandFactor = targetExpand
                    self.previewPill.alphaValue = targetPillAlpha
                    if !showPill { self.previewPill.isHidden = true }
                    self.expandDriverID = nil
                    self.expandTicket = nil
                    self.needsDisplay = true
                }
                return false
            }
            return true
        }
    }

    private func stopExpandDriver() {
        if let id = expandDriverID {
            MotionCoordinator.shared.displayDriver.stop(id: id)
            expandDriverID = nil
        }
        expandTicket = nil
    }

    private func updatePreviewPillText() {
        let ms = Int64(Double(ratio) * Double(max(0, durationMs)))
        let totalSec = max(0, ms / 1000)
        previewPill.text = String(format: "%02lld:%02lld", totalSec / 60, totalSec % 60)
    }

    private func updatePreviewPillPosition() {
        let pillW: CGFloat = 42
        let pillH: CGFloat = 17
        let thumbX = bounds.width * min(max(ratio, 0), 1)
        let x = min(max(thumbX - pillW * 0.5, 0), max(0, bounds.width - pillW))
        previewPill.frame = NSRect(x: x, y: bounds.height + 2, width: pillW, height: pillH)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let baseH = max(5.0, bounds.height * 0.43)
        let barH = baseH + expandFactor * 2.2
        let barRect = CGRect(x: 0, y: (bounds.height - barH) * 0.5, width: bounds.width, height: barH)
        OriginalControlRenderer.drawCapsuleProgress(in: ctx, rect: barRect, ratio: ratio, isHighlighted: isHighlighted, isScrubbing: isScrubbing)
    }
}

// MARK: - VolumeHUDView (M10)

@MainActor
private final class VolumeHUDView: NSView {
    private let glassView = NSGlassEffectView(frame: .zero)
    private let fallbackLayer = CALayer()
    private let label = NSTextField(labelWithString: "100%")

    override var mouseDownCanMoveWindow: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    var volumePercent: Int = 100 {
        didSet {
            label.stringValue = "\(volumePercent)%"
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        wantsLayer = true
        layer?.cornerRadius = 7
        layer?.masksToBounds = true

        fallbackLayer.backgroundColor = NSColor(srgbRed: 22/255.0, green: 24/255.0, blue: 28/255.0, alpha: 0.92).cgColor
        fallbackLayer.borderColor = NSColor(white: 1.0, alpha: 0.28).cgColor
        fallbackLayer.borderWidth = 0.75
        fallbackLayer.cornerRadius = 7
        layer?.addSublayer(fallbackLayer)

        glassView.style = .clear
        glassView.cornerRadius = 7
        glassView.autoresizingMask = [.width, .height]
        addSubview(glassView)

        label.font = NSFont.monospacedDigitSystemFont(ofSize: 9.5, weight: .semibold)
        label.textColor = OriginalDesignTokens.Colors.titleSilver
        label.alignment = .center
        addSubview(label)
        refreshMode()
    }

    func refreshMode() {
        let useGlass = GlassInteractionCoordinator.shared.isEnhancedMode && !MotionCoordinator.shared.isReduceTransparencyEnabled
        glassView.isHidden = !useGlass
        fallbackLayer.isHidden = useGlass
    }

    override func layout() {
        super.layout()
        glassView.frame = bounds
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        fallbackLayer.frame = bounds
        CATransaction.commit()
        label.frame = NSRect(x: 2, y: (bounds.height - 13) * 0.5, width: max(10, bounds.width - 4), height: 13)
    }
}

// MARK: - VolumeSegmentsView (M10 + M24)

/// 8-segment vertical volume meter matching AIRPLAY's right-edge volume control,
/// paired with a localized 180ms/900ms Glass Volume HUD.
@MainActor
final class VolumeSegmentsView: NSView {
    private let ownerID = "VolumeSegments-\(UUID().uuidString)"
    var volume: Float = 1.0 { didSet { needsDisplay = true } }
    var onVolumeChanged: ((Float) -> Void)?
    var onHUDVisibilityChanged: ((Bool, Int) -> Void)?

    private let liquidHover = LiquidGlassControl()
    private var trackingArea: NSTrackingArea?
    private var dismissTask: Task<Void, Never>?

    override var mouseDownCanMoveWindow: Bool { false }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        liquidHover.cornerRadius = 4.0
        addSubview(liquidHover)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    isolated deinit {
        dismissTask?.cancel()
        MotionCoordinator.shared.cancelAll(owner: ownerID)
    }

    override func layout() {
        super.layout()
        liquidHover.frame = bounds
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = trackingArea { removeTrackingArea(existing) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func viewDidHide() {
        super.viewDidHide()
        cancelHUD()
    }

    override func mouseEntered(with event: NSEvent) {
        liquidHover.isActive = true
        presentHUDAndScheduleDismiss()
    }

    override func mouseExited(with event: NSEvent) {
        liquidHover.isActive = false
        scheduleHUDDismiss()
    }

    override func mouseDown(with event: NSEvent) {
        updateVolume(from: event)
    }

    override func mouseDragged(with event: NSEvent) {
        updateVolume(from: event)
    }

    override func scrollWheel(with event: NSEvent) {
        guard GlassInteractionCoordinator.shared.enableTrackpadGestures,
              abs(event.scrollingDeltaY) >= abs(event.scrollingDeltaX) else {
            super.scrollWheel(with: event)
            return
        }
        let delta: Float = event.scrollingDeltaY > 0 ? 0.05 : -0.05
        let next = min(max(volume + delta, 0), 1)
        volume = next
        onVolumeChanged?(next)
        presentHUDAndScheduleDismiss()
    }

    private func updateVolume(from event: NSEvent) {
        let pt = convert(event.locationInWindow, from: nil)
        guard bounds.height > 0 else { return }
        let next = Float(min(max(pt.y / bounds.height, 0), 1))
        volume = next
        onVolumeChanged?(next)
        presentHUDAndScheduleDismiss()
    }

    func presentHUDAndScheduleDismiss() {
        let pct = Int(round(min(max(volume, 0), 1) * 100.0))
        onHUDVisibilityChanged?(true, pct)
        scheduleHUDDismiss()
    }

    private func scheduleHUDDismiss() {
        dismissTask?.cancel()
        dismissTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(Int(MotionTokens.Duration.volumeHUDHold * 1000)))
            guard !Task.isCancelled, let self else { return }
            self.onHUDVisibilityChanged?(false, Int(round(self.volume * 100.0)))
        }
    }

    func cancelHUD() {
        dismissTask?.cancel()
        dismissTask = nil
        liquidHover.isActive = false
        onHUDVisibilityChanged?(false, Int(round(volume * 100.0)))
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let s = GlassInteractionCoordinator.shared.uiScale
        let origin = CGPoint(x: (bounds.width - 7.0 * s) * 0.5, y: 3.0 * s)
        OriginalControlRenderer.drawVolumeSegments(in: ctx, origin: origin, uiScale: s, volume: volume, alpha: alphaValue)
    }
}

// MARK: - TimeFontDisplayView

/// Renders MM:SS using original `TIMEFONT` bitmap digits (6×7 @ 1×, 7px step).
@MainActor
final class TimeFontDisplayView: NSView {
    override var mouseDownCanMoveWindow: Bool { false }
    var timeString: String = "00:00" {
        didSet {
            if oldValue != timeString { needsDisplay = true }
        }
    }
    var alignment: NSTextAlignment = .left

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let s = GlassInteractionCoordinator.shared.uiScale
        let totalW = CGFloat(timeString.count) * OriginalDesignTokens.BaseMetrics.timeFontCharStep * s
        let startX: CGFloat = alignment == .right ? max(0, bounds.width - totalW) : 0
        let y = (bounds.height - OriginalDesignTokens.BaseMetrics.timeFontCharHeight * s) * 0.5
        PixelFontRenderer.drawTimeFont(in: ctx, text: timeString, origin: CGPoint(x: startX, y: y), uiScale: s, alpha: 0.86)
    }
}

// MARK: - StreamLoadingBarView (M23)

/// Animated capsule loading indicator shown in the progress-bar slot ONLY while awaiting
/// audio stream (`loading` / `buffering` / `seeking`), driven by on-demand `MotionDisplayDriver`.
@MainActor
final class StreamLoadingBarView: NSView {
    override var mouseDownCanMoveWindow: Bool { false }
    var statusText: String = "正在加载歌曲…" {
        didSet {
            if oldValue != statusText { needsDisplay = true }
        }
    }
    private var phase: CGFloat = 0
    private var driverSubID: UUID?
    private(set) var isAnimating: Bool = false

    isolated deinit {
        stopAnimating()
    }

    override func viewDidHide() {
        super.viewDidHide()
        stopAnimating()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            stopAnimating()
        }
    }

    func startAnimating() {
        guard !isAnimating else { return }
        guard !isHidden, window != nil else {
            isAnimating = false
            return
        }
        isAnimating = true
        if MotionCoordinator.shared.isReduceMotionEnabled {
            phase = 0.5
            needsDisplay = true
            return
        }
        stopDriver()
        driverSubID = MotionCoordinator.shared.displayDriver.start { [weak self] dt, _ in
            guard let self, self.isAnimating, !self.isHidden, self.window != nil, !MotionCoordinator.shared.isReduceMotionEnabled else {
                self?.isAnimating = false
                self?.driverSubID = nil
                return false
            }
            self.phase += CGFloat(dt) * 0.95
            if self.phase > 1.35 { self.phase = -0.35 }
            self.needsDisplay = true
            return true
        }
    }

    func stopAnimating() {
        isAnimating = false
        stopDriver()
    }

    private func stopDriver() {
        if let id = driverSubID {
            MotionCoordinator.shared.displayDriver.stop(id: id)
            driverSubID = nil
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let s = GlassInteractionCoordinator.shared.uiScale
        let w = bounds.width
        let h = bounds.height
        guard w > 12, h > 4 else { return }

        let barH = max(5.0, h * 0.43)
        let barRect = CGRect(x: 0, y: (h - barH) * 0.5, width: w, height: barH)
        let radius = barH * 0.5
        let path = CGPath(roundedRect: barRect, cornerWidth: radius, cornerHeight: radius, transform: nil)

        ctx.saveGState()
        ctx.addPath(path)
        ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.11))
        ctx.fillPath()

        ctx.addPath(path)
        ctx.clip()

        let segW = max(36.0 * s, w * 0.34)
        let centerX = phase * w
        let gradStart = CGPoint(x: centerX - segW * 0.5, y: barRect.midY)
        let gradEnd = CGPoint(x: centerX + segW * 0.5, y: barRect.midY)
        let cs = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let colors = [
            CGColor(srgbRed: 130/255.0, green: 215/255.0, blue: 255/255.0, alpha: 0.0),
            CGColor(srgbRed: 130/255.0, green: 215/255.0, blue: 255/255.0, alpha: 0.55),
            CGColor(srgbRed: 245/255.0, green: 250/255.0, blue: 255/255.0, alpha: 0.85),
            CGColor(srgbRed: 130/255.0, green: 215/255.0, blue: 255/255.0, alpha: 0.55),
            CGColor(srgbRed: 130/255.0, green: 215/255.0, blue: 255/255.0, alpha: 0.0)
        ] as CFArray
        let locs: [CGFloat] = [0.0, 0.25, 0.5, 0.75, 1.0]
        if let grad = CGGradient(colorsSpace: cs, colors: colors, locations: locs) {
            ctx.drawLinearGradient(grad, start: gradStart, end: gradEnd, options: [])
        }
        ctx.restoreGState()

        ctx.saveGState()
        ctx.addPath(path)
        ctx.setStrokeColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.20))
        ctx.setLineWidth(0.6)
        ctx.strokePath()
        ctx.restoreGState()

        let label = statusText
        let font = NSFont.systemFont(ofSize: 9.0 * s, weight: .medium)
        let attr = PixelFontRenderer.makeHaloAttributedString(
            label,
            font: font,
            color: OriginalDesignTokens.Colors.highlightSilver,
            alignment: .center,
            alpha: 0.92
        )
        let strSize = attr.size()
        let textRect = NSRect(x: (w - strSize.width) * 0.5, y: (h - strSize.height) * 0.5, width: strSize.width, height: strSize.height)
        attr.draw(in: textRect)
    }
}

// MARK: - PlayerHoverControlsContainer (M03)

@MainActor
private final class PlayerHoverControlsContainer: NSView {
    var allowsHitTesting: Bool = false

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard allowsHitTesting, !isHidden, alphaValue > 0.05 else { return nil }
        let localPt = convert(point, from: superview)
        guard bounds.contains(localPt) else { return nil }
        for sub in subviews.reversed() where !sub.isHidden {
            if let hit = sub.hitTest(localPt) {
                return hit
            }
        }
        return nil
    }
}

// MARK: - PlayerView

/// 1:1 restoration of the AIRPLAY-zion floating main player (330×106 @ 1×, 495×159 @ 1.5×).
/// Implements Motion V2 M01, M03, M05, M06, M07, M08, M09, M10, M11, M16, M17, M19, M20, M23, M24, M26.
open class PlayerView: GlassSurface {

    public var onPlayPause: (() -> Void)?
    public var onStop: (() -> Void)?
    public var onNext: (() -> Void)?
    public var onPrevious: (() -> Void)?
    public var onSeek: ((Int64) -> Void)?
    public var onVolumeChanged: ((Float) -> Void)?
    public var onToggleMiniMode: (() -> Void)?
    public var onToggleTopMost: (() -> Void)?
    public var onToggleLyrics: (() -> Void)?
    public var onToggleLibrary: (() -> Void)?
    public var onMinimize: (() -> Void)?
    public var onQuit: (() -> Void)?
    public var onSelectAppleMusic: (() -> Void)?
    public var onSelectSpotify: (() -> Void)?
    public var onSelectQQMusic: (() -> Void)?

    public var currentPlatform: Int = 0 {
        didSet {
            updatePlatformHighlight()
        }
    }

    public var isTopMost: Bool = true {
        didSet {
            let s = GlassInteractionCoordinator.shared.uiScale
            topMostButton.setSymbol(name: isTopMost ? "pin.fill" : "pin", pointSize: 9.0 * s, weight: .semibold)
        }
    }

    public var isHoverControlsInteractive: Bool {
        controlsContainer.allowsHitTesting
    }

    public var isStreamLoadingAnimating: Bool {
        streamLoadingView.isAnimating
    }

    // Left Column (Always-visible Album Artwork + M16 crossfade)
    private let artworkContainer = NSView()
    private let artworkView = NSImageView()
    private let artworkFadeOverlay = NSImageView()
    private let artworkHoverGlass = LiquidGlassControl()

    // Right Column Upper (Idle): Track info
    private let idleContainer = NSView()
    private let titleLabel = NSTextField(labelWithString: "AirMuse Ready")
    private let artistLabel = NSTextField(labelWithString: "Waiting for playback…")

    // Hover control views (M03)
    private let controlsContainer = PlayerHoverControlsContainer()
    private let topAuroraFogView = AuroraGlassFogView()
    private let bottomAuroraFogView = AuroraGlassFogView()
    private let playbackButtonsHost = NSView()
    private let stopButton = GlassButton(image: nil, size: CGSize(width: 28, height: 28), enableLiquidGlassHover: false)
    private let prevButton = GlassButton(image: nil, size: CGSize(width: 28, height: 28), enableLiquidGlassHover: false)
    private let playPauseButton = GlassButton(image: nil, size: CGSize(width: 28, height: 28), enableLiquidGlassHover: false)
    private let nextButton = GlassButton(image: nil, size: CGSize(width: 28, height: 28), enableLiquidGlassHover: false)
    private let ejectButton = GlassButton(image: nil, size: CGSize(width: 28, height: 28), enableLiquidGlassHover: false)

    // Window buttons (Top Glass Bar)
    private let motionSpeedButton = GlassButton(image: nil, size: CGSize(width: 13, height: 13), buttonStyle: .glassBar)
    private let glassStyleButton = GlassButton(image: nil, size: CGSize(width: 13, height: 13), buttonStyle: .glassBar)
    private let minimizeButton = GlassButton(image: nil, size: CGSize(width: 13, height: 13), buttonStyle: .glassBar)
    private let miniModeButton = GlassButton(image: nil, size: CGSize(width: 13, height: 13), buttonStyle: .glassBar)
    private let topMostButton = GlassButton(image: nil, size: CGSize(width: 13, height: 13), buttonStyle: .glassBar)
    private let quitButton = GlassButton(image: nil, size: CGSize(width: 13, height: 13), buttonStyle: .glassBar)

    // Panel & Source buttons (Bottom Glass Bar)
    private let appleMusicButton = GlassButton(image: nil, size: CGSize(width: 13, height: 13), buttonStyle: .glassBar)
    private let spotifyButton = GlassButton(image: nil, size: CGSize(width: 13, height: 13), buttonStyle: .glassBar)
    private let qqMusicButton = GlassButton(image: nil, size: CGSize(width: 13, height: 13), buttonStyle: .glassBar)
    private let libraryButton = GlassButton(image: nil, size: CGSize(width: 13, height: 13), buttonStyle: .glassBar)
    private let lyricsButton = GlassButton(image: nil, size: CGSize(width: 13, height: 13), buttonStyle: .glassBar)

    // Always-visible body progress & time + Volume HUD (M09/M10/M23)
    private let streamLoadingView = StreamLoadingBarView()
    private let progressView = CapsuleProgressView()
    private let currentTimeView = TimeFontDisplayView()
    private let durationTimeView = TimeFontDisplayView()
    private let volumeView = VolumeSegmentsView()
    private let volumeHUDView = VolumeHUDView()

    // State
    private var currentDurationMs: Int64 = 0
    private var isScrubbing: Bool = false
    private var isPlayingState: Bool = false
    private var isHoveringPanel: Bool = false
    private var isKeyboardControlsActive: Bool = false
    private var currentArtworkTrackKey: String?
    private var activePlaybackTrackKey: String?
    private var artworkLoadTask: Task<Void, Never>?
    private var trackingArea: NSTrackingArea?

    // Specular sweep tracking (M08)
    private var lastMouseY: CGFloat?
    private var lastMouseMoveTime: TimeInterval = 0
    private var lastMidCrossDir: Int = 0
    private var topBoundaryTriggered: Bool = false
    private var botBoundaryTriggered: Bool = false

    // M01 Non-blocking startup scroll-unroll state
    private let playerMotionID = "PlayerView-\(UUID().uuidString)"
    private var introDriverSubID: UUID?
    private var introTicket: MotionTicket?
    private var introCompletion: (@MainActor (Bool) -> Void)?
    public private(set) var isScrollIntroActive: Bool = false

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupViews()
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupViews()
    }

    isolated deinit {
        artworkLoadTask?.cancel()
        if let obs = resignKeyObserver {
            NotificationCenter.default.removeObserver(obs)
            resignKeyObserver = nil
        }
        MotionCoordinator.shared.cancelAll(owner: playerMotionID)
        NotificationCenter.default.removeObserver(self)
    }

    private func setupViews() {
        hasMainGloss = true
        cornerRadius = OriginalDesignTokens.BaseMetrics.glassCornerRadius

        // Left Column: Always-visible Album Artwork
        artworkContainer.wantsLayer = true
        artworkContainer.layer?.masksToBounds = false
        addSubview(artworkContainer)

        artworkHoverGlass.cornerRadius = 5.0
        artworkContainer.addSubview(artworkHoverGlass)

        artworkView.wantsLayer = true
        artworkView.layer?.cornerRadius = 5.0
        artworkView.layer?.masksToBounds = true
        artworkView.layer?.backgroundColor = NSColor(white: 1.0, alpha: 0.06).cgColor
        artworkView.layer?.borderWidth = 0.5
        artworkView.layer?.borderColor = NSColor(white: 1.0, alpha: 0.16).cgColor
        artworkView.imageScaling = .scaleProportionallyUpOrDown
        artworkView.image = NSImage(systemSymbolName: "music.note", accessibilityDescription: "Album Art")
        artworkView.contentTintColor = OriginalDesignTokens.Colors.subSilver
        artworkContainer.addSubview(artworkView)

        artworkFadeOverlay.wantsLayer = true
        artworkFadeOverlay.layer?.cornerRadius = 5.0
        artworkFadeOverlay.layer?.masksToBounds = true
        artworkFadeOverlay.imageScaling = .scaleProportionallyUpOrDown
        artworkFadeOverlay.isHidden = true
        artworkContainer.addSubview(artworkFadeOverlay)

        // Right Column Upper (Idle): Track info
        idleContainer.wantsLayer = true
        idleContainer.alphaValue = 1.0
        addSubview(idleContainer)

        titleLabel.textColor = OriginalDesignTokens.Colors.titleSilver
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.alignment = .center
        idleContainer.addSubview(titleLabel)

        artistLabel.textColor = OriginalDesignTokens.Colors.subSilver
        artistLabel.lineBreakMode = .byTruncatingTail
        artistLabel.alignment = .center
        idleContainer.addSubview(artistLabel)

        // Hover controls container
        controlsContainer.wantsLayer = true
        controlsContainer.alphaValue = 0.0
        controlsContainer.allowsHitTesting = false
        addSubview(controlsContainer)

        topAuroraFogView.seamEdge = .bottom
        bottomAuroraFogView.seamEdge = .top
        controlsContainer.addSubview(topAuroraFogView)
        controlsContainer.addSubview(bottomAuroraFogView)

        playbackButtonsHost.wantsLayer = true
        controlsContainer.addSubview(playbackButtonsHost)

        for btn in [stopButton, prevButton, playPauseButton, nextButton, ejectButton] {
            btn.enableDarkHalo = true
            btn.enablePersistentLiquidGlass = false
        }

        stopButton.toolTip = "停止"
        prevButton.toolTip = "上一首"
        playPauseButton.toolTip = "播放 / 暂停"
        nextButton.toolTip = "下一首"
        ejectButton.toolTip = "打开 / 隐藏资料库"

        stopButton.onClick = { [weak self] in self?.onStop?() }
        prevButton.onClick = { [weak self] in self?.onPrevious?() }
        playPauseButton.onClick = { [weak self] in self?.onPlayPause?() }
        nextButton.onClick = { [weak self] in self?.onNext?() }
        ejectButton.onClick = { [weak self] in self?.onToggleLibrary?() }

        playbackButtonsHost.addSubview(stopButton)
        playbackButtonsHost.addSubview(prevButton)
        playbackButtonsHost.addSubview(playPauseButton)
        playbackButtonsHost.addSubview(nextButton)
        playbackButtonsHost.addSubview(ejectButton)

        volumeView.onVolumeChanged = { [weak self] vol in self?.onVolumeChanged?(vol) }
        volumeView.onHUDVisibilityChanged = { [weak self] visible, pct in
            self?.setVolumeHUDVisible(visible, percent: pct)
        }
        controlsContainer.addSubview(volumeView)

        volumeHUDView.isHidden = true
        volumeHUDView.alphaValue = 0.0
        addSubview(volumeHUDView)

        // Top glass bar buttons
        motionSpeedButton.enableDarkHalo = false
        motionSpeedButton.onClick = { [weak self] in
            self?.presentMotionSpeedPopover()
        }
        controlsContainer.addSubview(motionSpeedButton)

        glassStyleButton.enableDarkHalo = false
        glassStyleButton.onClick = { [weak self] in
            self?.presentRenderOptionsPopover()
        }
        controlsContainer.addSubview(glassStyleButton)

        minimizeButton.enableDarkHalo = false
        minimizeButton.toolTip = "最小化"
        minimizeButton.onClick = { [weak self] in
            if let onMinimize = self?.onMinimize { onMinimize() } else { self?.window?.miniaturize(nil) }
        }
        miniModeButton.enableDarkHalo = false
        miniModeButton.toolTip = "切换迷你模式"
        miniModeButton.onClick = { [weak self] in self?.onToggleMiniMode?() }
        topMostButton.enableDarkHalo = false
        topMostButton.toolTip = "总在最前"
        topMostButton.onClick = { [weak self] in self?.onToggleTopMost?() }
        quitButton.enableDarkHalo = false
        quitButton.toolTip = "退出 AirMuse"
        quitButton.onClick = { [weak self] in
            if let onQuit = self?.onQuit { onQuit() } else { NSApp.terminate(nil) }
        }

        controlsContainer.addSubview(minimizeButton)
        controlsContainer.addSubview(miniModeButton)
        controlsContainer.addSubview(topMostButton)
        controlsContainer.addSubview(quitButton)

        // Bottom glass bar buttons
        appleMusicButton.enableDarkHalo = false
        appleMusicButton.toolTip = "Apple Music"
        appleMusicButton.onClick = { [weak self] in
            self?.currentPlatform = 0
            self?.onSelectAppleMusic?()
        }
        controlsContainer.addSubview(appleMusicButton)

        spotifyButton.enableDarkHalo = false
        spotifyButton.toolTip = "Spotify"
        spotifyButton.onClick = { [weak self] in
            self?.currentPlatform = 1
            self?.onSelectSpotify?()
        }
        controlsContainer.addSubview(spotifyButton)

        qqMusicButton.enableDarkHalo = false
        qqMusicButton.toolTip = "QQ 音乐"
        qqMusicButton.onClick = { [weak self] in
            self?.currentPlatform = 2
            self?.onSelectQQMusic?()
        }
        controlsContainer.addSubview(qqMusicButton)

        libraryButton.enableDarkHalo = false
        libraryButton.toolTip = "音乐资料库"
        libraryButton.onClick = { [weak self] in self?.onToggleLibrary?() }
        lyricsButton.enableDarkHalo = false
        lyricsButton.toolTip = "桌面歌词"
        lyricsButton.onClick = { [weak self] in self?.onToggleLyrics?() }
        controlsContainer.addSubview(libraryButton)
        controlsContainer.addSubview(lyricsButton)

        // Progress & Time
        progressView.onScrubbingChanged = { [weak self] scrubbing, ratio in
            guard let self else { return }
            self.isScrubbing = scrubbing
            if self.currentDurationMs > 0 {
                let ms = Int64(Double(ratio) * Double(self.currentDurationMs))
                self.currentTimeView.timeString = self.formatTime(ms: ms)
            }
        }
        progressView.onSeek = { [weak self] ratio in
            guard let self, self.currentDurationMs > 0 else { return }
            let targetMs = Int64(Double(ratio) * Double(self.currentDurationMs))
            self.onSeek?(targetMs)
        }
        streamLoadingView.isHidden = true
        addSubview(streamLoadingView)
        addSubview(progressView)

        currentTimeView.alignment = .right
        durationTimeView.alignment = .left
        addSubview(currentTimeView)
        addSubview(durationTimeView)

        reloadSprites()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(skinSettingsChanged),
            name: GlassInteractionCoordinator.modeDidChangeNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(skinSettingsChanged),
            name: MotionAccessibility.preferencesDidChangeNotification,
            object: nil
        )
    }

    @objc private func skinSettingsChanged() {
        reloadSprites()
        volumeHUDView.refreshMode()
        needsLayout = true
        refreshGlassSurface(animateFocus: false)
    }

    private func presentMotionSpeedPopover() {
        let coord = GlassInteractionCoordinator.shared
        let presets: [(TimeInterval, String)] = [
            (1.0, "模式切换总时长：1.0s"),
            (1.2, "模式切换总时长：1.2s"),
            (1.5, "模式切换总时长：1.5s")
        ]
        guard let win = window else {
            let idx = presets.firstIndex { abs($0.0 - coord.modeSequenceTotalDuration) < 0.05 } ?? 0
            coord.modeSequenceTotalDuration = presets[(idx + 1) % presets.count].0
            reloadSprites()
            return
        }
        let items = presets.map { dur, label in
            GlassPopoverMenuItem(
                id: "speed_\(dur)",
                title: label,
                isSelected: abs(coord.modeSequenceTotalDuration - dur) < 0.05,
                action: { [weak self] in
                    coord.modeSequenceTotalDuration = dur
                    self?.reloadSprites()
                }
            )
        }
        let rectInWin = motionSpeedButton.convert(motionSpeedButton.bounds, to: nil)
        let screenRect = win.convertToScreen(rectInWin)
        GlassPopoverMenu.shared.present(items: items, relativeTo: screenRect, parentWindow: win)
    }

    private func presentRenderOptionsPopover() {
        guard let win = window else {
            GlassInteractionCoordinator.shared.useFrostedBarsInNormalMode.toggle()
            return
        }
        let coord = GlassInteractionCoordinator.shared
        let items = [
            GlassPopoverMenuItem(
                id: "mode_original",
                title: "Original（原版水晶皮肤）",
                isSelected: coord.renderMode == .original,
                action: { coord.renderMode = .original }
            ),
            GlassPopoverMenuItem(
                id: "mode_enhanced",
                title: "Enhanced（局部 Liquid Glass）",
                isSelected: coord.renderMode == .enhanced,
                action: { coord.renderMode = .enhanced }
            ),
            GlassPopoverMenuItem(
                id: "frosted_bars",
                title: coord.useFrostedBarsInNormalMode ? "玻璃条：磨砂玻璃" : "玻璃条：原版切片",
                isSelected: coord.useFrostedBarsInNormalMode,
                action: { coord.useFrostedBarsInNormalMode.toggle() }
            ),
            GlassPopoverMenuItem(
                id: "gestures",
                title: "触控板区域手势",
                isSelected: coord.enableTrackpadGestures,
                action: { coord.enableTrackpadGestures.toggle() }
            )
        ]
        let rectInWin = glassStyleButton.convert(glassStyleButton.bounds, to: nil)
        let screenRect = win.convertToScreen(rectInWin)
        GlassPopoverMenu.shared.present(items: items, relativeTo: screenRect, parentWindow: win)
    }

    private func reloadSprites() {
        let s = GlassInteractionCoordinator.shared.uiScale

        stopButton.setSymbol(name: "square.fill", pointSize: 13.0 * s, weight: .bold)
        prevButton.setSymbol(name: "backward.fill", pointSize: 13.5 * s, weight: .bold)
        playPauseButton.setSymbol(name: isPlayingState ? "pause.fill" : "play.fill", pointSize: 16.5 * s, weight: .bold)
        nextButton.setSymbol(name: "forward.fill", pointSize: 13.5 * s, weight: .bold)
        ejectButton.setSymbol(name: "eject.fill", pointSize: 12.0 * s, weight: .bold)

        let speedSec = String(format: "%.1fs", GlassInteractionCoordinator.shared.modeSequenceTotalDuration)
        motionSpeedButton.setSymbol(name: "timer", pointSize: 9.0 * s, weight: .medium)
        motionSpeedButton.toolTip = "模式动画速度 (\(speedSec))"

        let frosted = GlassInteractionCoordinator.shared.useFrostedBarsInNormalMode
        let styleSymbol = frosted ? "sparkles.rectangle.stack" : "square.on.square"
        glassStyleButton.setSymbol(name: styleSymbol, pointSize: 9.0 * s, weight: .medium)
        glassStyleButton.toolTip = frosted ? "渲染模式与玻璃条选项" : "渲染模式与玻璃条选项"

        minimizeButton.setSymbol(name: "minus", pointSize: 9.0 * s, weight: .bold)
        miniModeButton.setSymbol(name: "rectangle.compress.vertical", pointSize: 8.5 * s, weight: .bold)
        topMostButton.setSymbol(name: isTopMost ? "pin.fill" : "pin", pointSize: 9.0 * s, weight: .semibold)
        quitButton.setSymbol(name: "xmark", pointSize: 8.5 * s, weight: .bold)

        appleMusicButton.setSymbol(name: "apple.logo", pointSize: 10.0 * s, weight: .bold)
        spotifyButton.setSymbol(name: "dot.radiowaves.left.and.right", pointSize: 9.0 * s, weight: .semibold)
        qqMusicButton.setSymbol(name: "waveform", pointSize: 9.0 * s, weight: .semibold)

        libraryButton.setSymbol(name: "books.vertical.fill", pointSize: 9.0 * s, weight: .semibold)
        lyricsButton.setSymbol(name: "text.quote", pointSize: 9.0 * s, weight: .bold)

        updatePlatformHighlight()
    }

    private func updatePlatformHighlight() {
        appleMusicButton.isHighlightedState = (currentPlatform == 0)
        spotifyButton.isHighlightedState = (currentPlatform == 1)
        qqMusicButton.isHighlightedState = (currentPlatform == 2)
    }

    open override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = trackingArea { removeTrackingArea(existing) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    open override func mouseEntered(with event: NSEvent) {
        setHovering(true)
    }

    open override func mouseDown(with event: NSEvent) {
        cancelScrollIntro()
        super.mouseDown(with: event)
    }

    open override func rightMouseDown(with event: NSEvent) {
        cancelScrollIntro()
        super.rightMouseDown(with: event)
    }

    private var resignKeyObserver: NSObjectProtocol?

    open override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let obs = resignKeyObserver {
            NotificationCenter.default.removeObserver(obs)
            resignKeyObserver = nil
        }
        if let win = window {
            resignKeyObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didResignKeyNotification,
                object: win,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.setKeyboardControlsFocused(false)
                }
            }
        }
    }

    open override var acceptsFirstResponder: Bool { true }

    open override func keyDown(with event: NSEvent) {
        cancelScrollIntro()
        guard !event.isARepeat else { return }
        switch event.keyCode {
        case 48, 125, 126: // Tab / Down / Up -> enter keyboard control focus
            setKeyboardControlsFocused(true)
            window?.makeFirstResponder(playPauseButton)
        case 49: // Space -> Play/Pause
            onPlayPause?()
        case 53: // Esc -> release keyboard focus lock
            setKeyboardControlsFocused(false)
        case 123: // Left arrow
            onPrevious?()
        case 124: // Right arrow
            onNext?()
        default:
            super.keyDown(with: event)
        }
    }

    open override func magnify(with event: NSEvent) {
        guard GlassInteractionCoordinator.shared.enablePinchToToggleMiniMode else {
            super.magnify(with: event)
            return
        }
        if event.phase == .ended && event.magnification < -0.18 {
            onToggleMiniMode?()
        }
    }

    open override func viewDidHide() {
        super.viewDidHide()
        cancelScrollIntro()
        setHovering(false, immediate: true)
        setKeyboardControlsFocused(false)
        progressView.cancelScrubbing()
        volumeView.cancelHUD()
    }

    // MARK: - M01 Glass-Bar Scroll Open & Reverse Collapse

    /// Opens the Main Player using two glass bars appearing together at center,
    /// then unrolling like a scroll to reveal the dark middle UI.
    public func playScrollIntro(completion: (@MainActor (Bool) -> Void)? = nil) {
        runScrollBarsTransition(
            isCollapsing: false,
            duration: MotionTokens.Duration.scrollIntro,
            completion: completion
        )
    }

    /// Reverses the Main Player scroll-unroll: top & bottom glass bars glide back together
    /// to cover the UI, then fade out cleanly before hiding or quitting.
    public func playScrollCollapse(completion: @escaping @MainActor (Bool) -> Void) {
        runScrollBarsTransition(
            isCollapsing: true,
            duration: MotionTokens.Duration.scrollCollapse,
            completion: completion
        )
    }

    private func runScrollBarsTransition(
        isCollapsing: Bool,
        duration: TimeInterval,
        completion: (@MainActor (Bool) -> Void)?
    ) {
        cancelScrollIntro()
        guard !MotionCoordinator.shared.isReduceMotionEnabled else {
            completion?(true)
            return
        }
        let s = GlassInteractionCoordinator.shared.uiScale
        let h = bounds.height
        let w = bounds.width
        let capH = OriginalDesignTokens.BaseMetrics.glassCapHeight * s
        guard w > 20, h > capH * 2.0 + 4.0 else {
            completion?(true)
            return
        }

        let key = TransitionKey(owner: playerMotionID, channel: "scrollIntro")
        let ticket = MotionCoordinator.shared.beginTransition(for: key, category: .decorative) { [weak self] in
            self?.teardownScrollIntroVisuals(committed: false)
        }
        introTicket = ticket
        introCompletion = completion
        isScrollIntroActive = true

        applyScrollBarsProgress(isCollapsing ? 1.0 : 0.0)

        var elapsed: TimeInterval = 0
        introDriverSubID = MotionCoordinator.shared.displayDriver.start { [weak self] dt, _ in
            guard let self, MotionCoordinator.shared.isCurrent(ticket) else {
                return false
            }
            elapsed += dt
            let raw = min(1.0, elapsed / max(0.01, duration))
            let progress = isCollapsing ? CGFloat(1.0 - raw) : CGFloat(raw)
            self.applyScrollBarsProgress(progress)
            if raw >= 1.0 {
                if MotionCoordinator.shared.complete(ticket) {
                    self.teardownScrollIntroVisuals(committed: true, keepCollapsedHidden: isCollapsing)
                }
                return false
            }
            return true
        }
    }

    public func cancelScrollIntro() {
        guard isScrollIntroActive || introTicket != nil || introDriverSubID != nil else { return }
        let key = TransitionKey(owner: playerMotionID, channel: "scrollIntro")
        MotionCoordinator.shared.cancel(key: key)
        teardownScrollIntroVisuals(committed: false)
    }

    private func applyScrollBarsProgress(_ raw: CGFloat) {
        let p = min(max(raw, 0), 1)
        let s = GlassInteractionCoordinator.shared.uiScale
        let capH = OriginalDesignTokens.BaseMetrics.glassCapHeight * s
        let w = bounds.width
        let h = bounds.height
        let cy = h * 0.5

        // Phase A (0.0 .. 0.24): Two glass bars appear back-to-back in center with 0 middle body
        // Phase B (0.24 .. 1.00): Top bar moves up (cy -> h - capH), Bottom bar moves down (cy - capH -> 0)
        let phaseSplit: CGFloat = 0.24
        let barAlpha: CGFloat
        let unrollT: CGFloat
        if p < phaseSplit {
            let a = p / phaseSplit
            barAlpha = a * a * (3.0 - 2.0 * a)
            unrollT = 0.0
        } else {
            barAlpha = 1.0
            let u = (p - phaseSplit) / (1.0 - phaseSplit)
            unrollT = 1.0 - pow(1.0 - u, 3.0)
        }

        let insetX: CGFloat = p < phaseSplit ? (1.0 - barAlpha) * 6.0 * s : 0.0
        let barW = max(20.0, w - insetX * 2.0)
        let topY = cy + ((h - capH) - cy) * unrollT
        let botStartY = cy - capH
        let botY = botStartY * (1.0 - unrollT)

        let topFrame = NSRect(x: insetX, y: topY, width: barW, height: capH)
        let botFrame = NSRect(x: insetX, y: botY, width: barW, height: capH)

        applyScrollPresentation(
            topBarFrame: topFrame,
            bottomBarFrame: botFrame,
            barAlpha: barAlpha
        )

        let contentAlpha = unrollT <= 0.25 ? 0.0 : min(1.0, (unrollT - 0.25) / 0.75)
        artworkContainer.alphaValue = contentAlpha
        idleContainer.alphaValue = isHoveringPanel ? 0.0 : contentAlpha
        progressView.alphaValue = contentAlpha
        streamLoadingView.alphaValue = contentAlpha
        currentTimeView.alphaValue = contentAlpha
        durationTimeView.alphaValue = contentAlpha
        controlsContainer.alphaValue = (isHoveringPanel || isKeyboardControlsActive) ? contentAlpha : 0.0
    }

    private func teardownScrollIntroVisuals(committed: Bool, keepCollapsedHidden: Bool = false) {
        if let subID = introDriverSubID {
            MotionCoordinator.shared.displayDriver.stop(id: subID)
            introDriverSubID = nil
        }
        introTicket = nil
        isScrollIntroActive = false
        let pending = introCompletion
        introCompletion = nil

        if keepCollapsedHidden {
            clearScrollPresentation()
            alphaValue = 0.0
        } else {
            clearScrollPresentation()
            alphaValue = 1.0
            artworkContainer.alphaValue = 1.0
            idleContainer.alphaValue = isHoveringPanel ? 0.0 : 1.0
            progressView.alphaValue = 1.0
            streamLoadingView.alphaValue = 1.0
            currentTimeView.alphaValue = 1.0
            durationTimeView.alphaValue = 1.0
            controlsContainer.alphaValue = (isHoveringPanel || isKeyboardControlsActive) ? 1.0 : 0.0
        }
        pending?(committed)
    }

    open override func mouseExited(with event: NSEvent) {
        setHovering(false)
        lastMouseY = nil
        lastMouseMoveTime = 0
        lastMidCrossDir = 0
        topBoundaryTriggered = false
        botBoundaryTriggered = false
    }

    open override func mouseMoved(with event: NSEvent) {
        let pt = convert(event.locationInWindow, from: nil)
        let s = GlassInteractionCoordinator.shared.uiScale
        let h = bounds.height
        let midY = h * 0.5
        let capH = OriginalDesignTokens.BaseMetrics.glassCapHeight * s
        let botGlassBoundary = capH
        let topGlassBoundary = h - capH

        let now = MotionCoordinator.shared.clock.now
        let dt = lastMouseMoveTime > 0 ? max(0.001, min(0.1, now - lastMouseMoveTime)) : 0.016
        lastMouseMoveTime = now

        if let prevY = lastMouseY, h > 40 * s {
            let dy = pt.y - prevY
            let speedY = abs(dy) / CGFloat(dt)
            let isFast = speedY > MotionTokens.Thresholds.fastMoveVelocity * s || abs(dy) >= 14.0 * s

            if prevY > midY && pt.y <= midY {
                if lastMidCrossDir != 1 {
                    if !isFast { triggerSpecularSweep(from: 0.5, to: 1.0) }
                    lastMidCrossDir = 1
                }
            } else if prevY < midY && pt.y >= midY {
                if lastMidCrossDir != -1 {
                    if !isFast { triggerSpecularSweep(from: 0.5, to: 0.0) }
                    lastMidCrossDir = -1
                }
            }

            if !botBoundaryTriggered && dy < 0 && pt.y <= botGlassBoundary {
                triggerSpecularSweep(from: 1.0, to: 0.0)
                botBoundaryTriggered = true
            } else if !topBoundaryTriggered && dy > 0 && pt.y >= topGlassBoundary {
                triggerSpecularSweep(from: 0.0, to: 1.0)
                topBoundaryTriggered = true
            }

            if botBoundaryTriggered && pt.y > botGlassBoundary + MotionTokens.Thresholds.boundaryResetMargin * s {
                botBoundaryTriggered = false
            }
            if topBoundaryTriggered && pt.y < topGlassBoundary - MotionTokens.Thresholds.boundaryResetMargin * s {
                topBoundaryTriggered = false
            }
        }
        lastMouseY = pt.y
    }

    public func setKeyboardControlsFocused(_ focused: Bool) {
        guard isKeyboardControlsActive != focused else { return }
        isKeyboardControlsActive = focused
        refreshHoverPresentation(immediate: false)
    }

    public func setHovering(_ hovering: Bool, immediate: Bool = false) {
        guard isHoveringPanel != hovering else { return }
        isHoveringPanel = hovering
        refreshHoverPresentation(immediate: immediate)
    }

    private func refreshHoverPresentation(immediate: Bool) {
        let active = isHoveringPanel || isKeyboardControlsActive
        let targetIdle: CGFloat = active ? 0.0 : 1.0
        let targetCtrl: CGFloat = active ? 1.0 : 0.0
        artworkHoverGlass.isActive = active
        controlsContainer.allowsHitTesting = active

        let key = TransitionKey(owner: playerMotionID, channel: "hover")
        let ticket = MotionCoordinator.shared.beginTransition(for: key, category: .controlInteraction)

        let targetTransform = CATransform3DMakeTranslation(
            0,
            active ? 0 : -MotionTokens.Geometry.hoverDisplacementPt,
            0
        )

        if immediate || MotionCoordinator.shared.isReduceMotionEnabled {
            idleContainer.alphaValue = targetIdle
            controlsContainer.alphaValue = targetCtrl
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            controlsContainer.layer?.removeAnimation(forKey: "hoverSlide")
            controlsContainer.layer?.transform = CATransform3DIdentity
            artworkView.layer?.borderColor = NSColor(white: 1.0, alpha: active ? 0.36 : 0.16).cgColor
            CATransaction.commit()
            _ = MotionCoordinator.shared.complete(ticket)
            return
        }

        if let ctrlLayer = controlsContainer.layer {
            let startY = (ctrlLayer.presentation()?.value(forKeyPath: "transform.translation.y") as? NSNumber).map { CGFloat($0.doubleValue) } ?? (active ? -MotionTokens.Geometry.hoverDisplacementPt : 0)
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            ctrlLayer.transform = targetTransform
            artworkView.layer?.borderColor = NSColor(white: 1.0, alpha: active ? 0.36 : 0.16).cgColor
            CATransaction.commit()

            let slideAnim = CABasicAnimation(keyPath: "transform.translation.y")
            slideAnim.fromValue = startY
            slideAnim.toValue = active ? 0.0 : -MotionTokens.Geometry.hoverDisplacementPt
            slideAnim.duration = MotionTokens.Duration.hoverFade
            slideAnim.timingFunction = CAMediaTimingFunction(name: .easeOut)
            slideAnim.isRemovedOnCompletion = true
            ctrlLayer.add(slideAnim, forKey: "hoverSlide")
        }

        MotionCoordinator.shared.animate(
            duration: MotionTokens.Duration.hoverFade,
            timingFunction: .easeInEaseOut,
            ticket: ticket,
            action: {
                self.idleContainer.animator().alphaValue = targetIdle
                self.controlsContainer.animator().alphaValue = targetCtrl
            }
        )
    }

    private func setVolumeHUDVisible(_ visible: Bool, percent: Int) {
        volumeHUDView.volumePercent = percent
        volumeHUDView.refreshMode()
        let key = TransitionKey(owner: playerMotionID, channel: "volumeHUD")
        let ticket = MotionCoordinator.shared.beginTransition(for: key, category: .controlInteraction)

        if visible {
            volumeHUDView.isHidden = false
        }
        let targetAlpha: CGFloat = visible ? 1.0 : 0.0
        let dur = visible ? MotionTokens.Duration.volumeHUDIn : MotionTokens.Duration.volumeHUDOut

        MotionCoordinator.shared.animate(
            duration: dur,
            timingFunction: visible ? .easeOut : .easeIn,
            ticket: ticket,
            action: {
                self.volumeHUDView.animator().alphaValue = targetAlpha
            },
            completion: { [weak self] committed in
                guard committed, let self, !visible else { return }
                self.volumeHUDView.isHidden = true
            }
        )
    }

    open override func layout() {
        super.layout()
        let s = GlassInteractionCoordinator.shared.uiScale
        let w = bounds.width
        let h = bounds.height

        idleContainer.frame = bounds
        controlsContainer.frame = bounds

        func appKitY(topY: CGFloat, height: CGFloat) -> CGFloat {
            return h - topY - height
        }

        // 1. Left Column: Always-visible Album Artwork (54×54 @ 1x)
        let artSize = 54.0 * s
        let artX = 12.0 * s
        let artY = appKitY(topY: 26.0 * s, height: artSize)
        artworkContainer.frame = NSRect(x: artX, y: artY, width: artSize, height: artSize)
        artworkView.frame = artworkContainer.bounds
        artworkView.layer?.cornerRadius = 5.0 * s
        artworkFadeOverlay.frame = artworkContainer.bounds
        artworkFadeOverlay.layer?.cornerRadius = 5.0 * s
        artworkHoverGlass.frame = artworkContainer.bounds.insetBy(dx: -2.0 * s, dy: -2.0 * s)
        artworkHoverGlass.cornerRadius = 6.5 * s

        // 2. Right Column geometry
        let rightColLeft = artX + artSize + 10.0 * s
        let rightColRight = w - 28.0 * s
        let rightColW = max(80.0 * s, rightColRight - rightColLeft)

        titleLabel.font = NSFont.systemFont(ofSize: 13.0 * s, weight: .bold)
        artistLabel.font = NSFont.systemFont(ofSize: 11.0 * s, weight: .regular)
        titleLabel.frame = NSRect(x: rightColLeft, y: appKitY(topY: 26.0 * s, height: 19.0 * s), width: rightColW, height: 19.0 * s)
        artistLabel.frame = NSRect(x: rightColLeft, y: appKitY(topY: 46.0 * s, height: 16.0 * s), width: rightColW, height: 16.0 * s)

        // Right Column Upper (Hover): 5 playback control buttons
        let ctrlSize = 28.0 * s
        let ctrlGap = 6.0 * s
        let groupW = ctrlSize * 5.0 + ctrlGap * 4.0
        let startX = rightColLeft + max(0, (rightColW - groupW) * 0.5)
        let ctrlY = appKitY(topY: 28.0 * s, height: ctrlSize)
        playbackButtonsHost.frame = NSRect(x: startX, y: ctrlY, width: groupW, height: ctrlSize)

        stopButton.frame = NSRect(x: 0, y: 0, width: ctrlSize, height: ctrlSize)
        prevButton.frame = NSRect(x: ctrlSize + ctrlGap, y: 0, width: ctrlSize, height: ctrlSize)
        playPauseButton.frame = NSRect(x: (ctrlSize + ctrlGap) * 2.0, y: 0, width: ctrlSize, height: ctrlSize)
        nextButton.frame = NSRect(x: (ctrlSize + ctrlGap) * 3.0, y: 0, width: ctrlSize, height: ctrlSize)
        ejectButton.frame = NSRect(x: (ctrlSize + ctrlGap) * 4.0, y: 0, width: ctrlSize, height: ctrlSize)

        // 3. Top glass bar window buttons
        let wbSize = 13.0 * s
        let capH = OriginalDesignTokens.BaseMetrics.glassCapHeight * s
        let topBarBtnY = (h - capH) + (capH - wbSize) * 0.5
        let btnSpacing = 5.0 * s

        quitButton.frame = NSRect(x: w - 16.0 * s - wbSize, y: topBarBtnY, width: wbSize, height: wbSize)
        topMostButton.frame = NSRect(x: quitButton.frame.minX - btnSpacing - wbSize, y: topBarBtnY, width: wbSize, height: wbSize)
        miniModeButton.frame = NSRect(x: topMostButton.frame.minX - btnSpacing - wbSize, y: topBarBtnY, width: wbSize, height: wbSize)
        minimizeButton.frame = NSRect(x: miniModeButton.frame.minX - btnSpacing - wbSize, y: topBarBtnY, width: wbSize, height: wbSize)
        glassStyleButton.frame = NSRect(x: minimizeButton.frame.minX - btnSpacing - wbSize, y: topBarBtnY, width: wbSize, height: wbSize)
        motionSpeedButton.frame = NSRect(x: glassStyleButton.frame.minX - btnSpacing - wbSize, y: topBarBtnY, width: wbSize, height: wbSize)

        // 4. Bottom glass bar panel & source buttons
        let botBarBtnY = (capH - wbSize) * 0.5
        appleMusicButton.frame = NSRect(x: 20.0 * s, y: botBarBtnY, width: wbSize, height: wbSize)
        spotifyButton.frame = NSRect(x: appleMusicButton.frame.maxX + 6.0 * s, y: botBarBtnY, width: wbSize, height: wbSize)
        qqMusicButton.frame = NSRect(x: spotifyButton.frame.maxX + 6.0 * s, y: botBarBtnY, width: wbSize, height: wbSize)

        lyricsButton.frame = NSRect(x: w - 16.0 * s - wbSize, y: botBarBtnY, width: wbSize, height: wbSize)
        libraryButton.frame = NSRect(x: lyricsButton.frame.minX - 6.0 * s - wbSize, y: botBarBtnY, width: wbSize, height: wbSize)

        // 4b. Normal-mode glass bar laser fog backings
        let isMiniStrip = h <= (OriginalDesignTokens.BaseMetrics.miniBarStandardHeight * s + 2.0)
        topAuroraFogView.frame = NSRect(x: 0, y: h - capH, width: w, height: capH)
        bottomAuroraFogView.frame = NSRect(x: 0, y: 0, width: w, height: capH)
        topAuroraFogView.isFogEnabled = !isMiniStrip
        bottomAuroraFogView.isFogEnabled = !isMiniStrip

        if !isMiniStrip {
            topAuroraFogView.setPlume(
                for: [motionSpeedButton, glassStyleButton, minimizeButton, miniModeButton, topMostButton, quitButton],
                alignment: .right,
                anchorSpread: 10.0 * s,
                tailLength: 74.0 * s,
                peakAlpha: 1.0
            )
            let leftBotPlume = bottomAuroraFogView.makePlume(
                for: [appleMusicButton, spotifyButton, qqMusicButton],
                alignment: .left,
                anchorSpread: 10.0 * s,
                tailLength: 56.0 * s,
                peakAlpha: 1.0
            )
            let rightBotPlume = bottomAuroraFogView.makePlume(
                for: [libraryButton, lyricsButton],
                alignment: .right,
                anchorSpread: 10.0 * s,
                tailLength: 56.0 * s,
                peakAlpha: 1.0
            )
            bottomAuroraFogView.plumes = [leftBotPlume, rightBotPlume].compactMap { $0 }
        } else {
            topAuroraFogView.plumes = []
            bottomAuroraFogView.plumes = []
        }

        // 5. Volume segments & localized Volume HUD (M10)
        let volFrame = NSRect(x: w - 23.0 * s, y: appKitY(topY: 32.0 * s, height: 38.0 * s), width: 14.0 * s, height: 38.0 * s)
        volumeView.frame = volFrame
        let hudW: CGFloat = 34.0
        let hudH: CGFloat = 18.0
        volumeHUDView.frame = NSRect(x: volFrame.minX - hudW - 4.0, y: volFrame.midY - hudH * 0.5, width: hudW, height: hudH)

        // 6. Right Column Lower: Progress bar & TIMEFONT digital clock (or StreamLoadingBarView)
        let progY = appKitY(topY: 64.0 * s, height: 14.0 * s)
        streamLoadingView.frame = NSRect(x: rightColLeft, y: progY, width: rightColW, height: 14.0 * s)
        let timeW = 36.0 * s
        currentTimeView.frame = NSRect(x: rightColLeft, y: progY, width: timeW, height: 14.0 * s)
        durationTimeView.frame = NSRect(x: rightColRight - timeW, y: progY, width: timeW, height: 14.0 * s)
        let sliderX = currentTimeView.frame.maxX + 4.0 * s
        let sliderW = max(20.0 * s, durationTimeView.frame.minX - 4.0 * s - sliderX)
        progressView.frame = NSRect(x: sliderX, y: progY, width: sliderW, height: 14.0 * s)
    }

    public func updateState(_ state: PlaybackState) {
        let trackKey = state.currentTrack?.trackKey
        if trackKey != activePlaybackTrackKey {
            activePlaybackTrackKey = trackKey
            // M09: Track switch invalidates any in-progress scrub immediately
            progressView.cancelScrubbing()
            isScrubbing = false
        }

        currentDurationMs = state.durationMs
        progressView.durationMs = state.durationMs

        // M06: Only transition play/pause symbol when real playback status changes (buffering never fakes Playing)
        let effectivePlaying = (state.status == .playing)
        let playChanged = (isPlayingState != effectivePlaying)
        isPlayingState = effectivePlaying

        let s = GlassInteractionCoordinator.shared.uiScale
        if playChanged {
            playPauseButton.transitionToSymbol(
                name: effectivePlaying ? "pause.fill" : "play.fill",
                pointSize: 16.5 * s,
                weight: .bold
            )
        }

        let titleFont = NSFont.systemFont(ofSize: 13.0 * s, weight: .bold)
        let subFont = NSFont.systemFont(ofSize: 11.0 * s, weight: .regular)

        if let track = state.currentTrack {
            titleLabel.attributedStringValue = PixelFontRenderer.makeHaloAttributedString(
                track.title, font: titleFont, color: OriginalDesignTokens.Colors.titleSilver, alignment: .center
            )
            if state.status == .failed, let err = state.errorMessage, !err.isEmpty {
                artistLabel.attributedStringValue = PixelFontRenderer.makeHaloAttributedString(
                    err, font: subFont, color: .systemRed, alignment: .center
                )
            } else {
                artistLabel.attributedStringValue = PixelFontRenderer.makeHaloAttributedString(
                    track.artistName, font: subFont, color: OriginalDesignTokens.Colors.subSilver, alignment: .center
                )
            }
        } else {
            titleLabel.attributedStringValue = PixelFontRenderer.makeHaloAttributedString(
                "AirMuse Ready", font: titleFont, color: OriginalDesignTokens.Colors.titleSilver, alignment: .center
            )
            artistLabel.attributedStringValue = PixelFontRenderer.makeHaloAttributedString(
                state.sourceName, font: subFont, color: OriginalDesignTokens.Colors.subSilver, alignment: .center
            )
        }

        // M23: Only active during genuine loading / buffering / seeking; stops immediately otherwise
        let isAwaitingStream = (state.status == .loading || state.status == .buffering || state.status == .seeking) && !effectivePlaying
        if isAwaitingStream {
            streamLoadingView.statusText = (state.status == .buffering || state.status == .seeking) ? "正在缓冲音频…" : "正在请求曲目…"
            streamLoadingView.isHidden = false
            streamLoadingView.startAnimating()
            progressView.isHidden = true
            currentTimeView.isHidden = true
            durationTimeView.isHidden = true
        } else {
            streamLoadingView.stopAnimating()
            streamLoadingView.isHidden = true
            progressView.isHidden = false
            currentTimeView.isHidden = false
            durationTimeView.isHidden = false
        }

        if !isScrubbing {
            if state.durationMs > 0 {
                progressView.ratio = CGFloat(min(max(Double(state.estimatedPositionMs) / Double(state.durationMs), 0), 1))
                currentTimeView.timeString = formatTime(ms: state.estimatedPositionMs)
                durationTimeView.timeString = formatTime(ms: state.durationMs)
            } else {
                progressView.ratio = 0
                currentTimeView.timeString = "00:00"
                durationTimeView.timeString = "00:00"
            }
        }

        volumeView.volume = min(max(state.volume, 0), 1)

        // M16 / M17: Off-MainActor artwork decode & ambient color extraction with trackKey generation guard
        if let data = state.artworkData {
            let expectedKey = trackKey ?? "data-\(data.hashValue)"
            if currentArtworkTrackKey != expectedKey {
                currentArtworkTrackKey = expectedKey
                artworkLoadTask?.cancel()
                let pxSize = Int(round(54.0 * s * 2.0))
                artworkLoadTask = Task { [weak self] in
                    let (img, ambientCol) = await ArtworkAmbientAnalyzer.shared.decodeAndExtractColor(
                        data: data,
                        trackKey: expectedKey,
                        maxPixelSize: pxSize
                    )
                    guard !Task.isCancelled, let self, self.currentArtworkTrackKey == expectedKey else { return }
                    self.applyArtwork(img, key: expectedKey, ambientColor: ambientCol)
                }
            }
        } else if let track = state.currentTrack, let url = track.artworkURL {
            if currentArtworkTrackKey != track.trackKey {
                currentArtworkTrackKey = track.trackKey
                artworkLoadTask?.cancel()
                let expectedKey = track.trackKey
                artworkLoadTask = Task { [weak self] in
                    let img = await ImageCacheV2.shared.image(for: url, targetPixelSize: 222)
                    guard !Task.isCancelled else { return }
                    var extractedColor: NSColor? = nil
                    if let img {
                        var rect = NSRect(origin: .zero, size: img.size)
                        if let cg = img.cgImage(forProposedRect: &rect, context: nil, hints: nil) {
                            extractedColor = await ArtworkAmbientAnalyzer.shared.extractAndCacheColor(from: cg, trackKey: expectedKey)
                        }
                    }
                    guard !Task.isCancelled, let self, self.currentArtworkTrackKey == expectedKey else { return }
                    self.applyArtwork(img, key: expectedKey, ambientColor: extractedColor)
                }
            }
        } else {
            artworkLoadTask?.cancel()
            if currentArtworkTrackKey != nil {
                currentArtworkTrackKey = nil
                applyArtwork(nil, key: "none", ambientColor: nil)
            }
        }
    }

    private func applyArtwork(_ img: NSImage?, key: String, ambientColor: NSColor?) {
        let prevImage = artworkView.image
        let transitionKey = TransitionKey(owner: playerMotionID, channel: "artwork")
        let ticket = MotionCoordinator.shared.beginTransition(for: transitionKey, category: .content)

        if let img {
            if !MotionCoordinator.shared.isReduceMotionEnabled,
               let prevImage,
               artworkCacheKey != "none",
               artworkCacheKey != key {
                artworkFadeOverlay.image = prevImage
                artworkFadeOverlay.alphaValue = 1.0
                artworkFadeOverlay.isHidden = false
            } else {
                artworkFadeOverlay.isHidden = true
            }

            artworkView.image = img
            artworkView.imageScaling = .scaleProportionallyUpOrDown
            var rect = NSRect(origin: .zero, size: img.size)
            artworkCacheKey = key
            ambientArtwork = img.cgImage(forProposedRect: &rect, context: nil, hints: nil)
            composer.updateAmbientColor(ambientColor, animated: true)

            if !artworkFadeOverlay.isHidden {
                if let artLayer = artworkView.layer {
                    let sAnim = CABasicAnimation(keyPath: "transform.scale")
                    sAnim.fromValue = MotionTokens.Geometry.artworkTransitionScale
                    sAnim.toValue = 1.0
                    sAnim.duration = MotionTokens.Duration.artworkCrossfade
                    sAnim.timingFunction = CAMediaTimingFunction(name: .easeOut)
                    sAnim.isRemovedOnCompletion = true
                    artLayer.add(sAnim, forKey: "artScale")
                }
                MotionCoordinator.shared.animate(
                    duration: MotionTokens.Duration.artworkCrossfade,
                    timingFunction: .easeInEaseOut,
                    ticket: ticket,
                    action: {
                        self.artworkFadeOverlay.animator().alphaValue = 0.0
                    },
                    completion: { [weak self] committed in
                        guard committed, let self else { return }
                        self.artworkFadeOverlay.isHidden = true
                        self.artworkFadeOverlay.image = nil
                    }
                )
            } else {
                _ = MotionCoordinator.shared.complete(ticket)
            }
        } else {
            artworkFadeOverlay.isHidden = true
            artworkFadeOverlay.image = nil
            artworkView.image = NSImage(systemSymbolName: "music.note", accessibilityDescription: "Album Art")
            artworkView.imageScaling = .scaleProportionallyDown
            artworkCacheKey = "none"
            ambientArtwork = nil
            composer.updateAmbientColor(nil, animated: true)
            _ = MotionCoordinator.shared.complete(ticket)
        }
        needsLayout = true
    }

    private func formatTime(ms: Int64) -> String {
        let totalSec = max(0, ms / 1000)
        let m = totalSec / 60
        let s = totalSec % 60
        return String(format: "%02lld:%02lld", m, s)
    }
}
