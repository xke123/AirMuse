import CoreGraphics
import Foundation
import DesignSystem

// MARK: - StagePlacement

public enum StagePlacement: String, Sendable, Equatable {
    case top
    case bottom
    case left
    case right
}

// MARK: - StageLayoutInput

public struct StageLayoutInput: Sendable, Equatable {
    public var uiScale: CGFloat
    public var playerScreenOrigin: CGPoint
    public var playerSize: CGSize
    public var lyricsSize: CGSize
    public var librarySize: CGSize
    public var isMiniMode: Bool
    public var isLyricsVisible: Bool
    public var isLibraryVisible: Bool
    public var lyricsPlacement: StagePlacement
    public var libraryPlacement: StagePlacement
    public var customLyricsOffset: CGPoint?
    public var customLibraryOffset: CGPoint?
    public var activeDragLyricsOrigin: CGPoint?
    public var activeDragLibraryOrigin: CGPoint?

    public init(
        uiScale: CGFloat,
        playerScreenOrigin: CGPoint,
        playerSize: CGSize,
        lyricsSize: CGSize,
        librarySize: CGSize,
        isMiniMode: Bool,
        isLyricsVisible: Bool,
        isLibraryVisible: Bool,
        lyricsPlacement: StagePlacement = .bottom,
        libraryPlacement: StagePlacement = .right,
        customLyricsOffset: CGPoint? = nil,
        customLibraryOffset: CGPoint? = nil,
        activeDragLyricsOrigin: CGPoint? = nil,
        activeDragLibraryOrigin: CGPoint? = nil
    ) {
        self.uiScale = uiScale
        self.playerScreenOrigin = playerScreenOrigin
        self.playerSize = playerSize
        self.lyricsSize = lyricsSize
        self.librarySize = librarySize
        self.isMiniMode = isMiniMode
        self.isLyricsVisible = isLyricsVisible
        self.isLibraryVisible = isLibraryVisible
        self.lyricsPlacement = lyricsPlacement
        self.libraryPlacement = libraryPlacement
        self.customLyricsOffset = customLyricsOffset
        self.customLibraryOffset = customLibraryOffset
        self.activeDragLyricsOrigin = activeDragLyricsOrigin
        self.activeDragLibraryOrigin = activeDragLibraryOrigin
    }
}

// MARK: - StageLayoutOutput

public struct StageLayoutOutput: Sendable, Equatable {
    /// Host window frame in screen coordinates.
    public var hostFrame: CGRect
    /// Player slot frame in host-local coordinates.
    public var playerFrame: CGRect
    /// Lyrics module frame in host-local coordinates (`.zero` if hidden).
    public var lyricsFrame: CGRect
    /// Library module frame in host-local coordinates (`.zero` if hidden).
    public var libraryFrame: CGRect
    /// Active hit-testable module frames in host-local coordinates (excludes hidden modules and empty gaps).
    public var interactiveHitFrames: [CGRect]

    public init(
        hostFrame: CGRect,
        playerFrame: CGRect,
        lyricsFrame: CGRect,
        libraryFrame: CGRect,
        interactiveHitFrames: [CGRect]
    ) {
        self.hostFrame = hostFrame
        self.playerFrame = playerFrame
        self.lyricsFrame = lyricsFrame
        self.libraryFrame = libraryFrame
        self.interactiveHitFrames = interactiveHitFrames
    }
}

// MARK: - SnapResult

public struct StageSnapResult: Sendable, Equatable {
    public var snappedOffset: CGPoint?
    public var targetScreenRect: CGRect?
    public var didSnap: Bool
}

// MARK: - StageLayoutEngine

/// Pure geometry solver for UnifiedStageController (A02 / M02 / M11 / M12 / M13 / M14 / M25).
/// Computes stage frames, anchor-preserved mode transitions, multi-screen clamping,
/// magnetic snap targets with hysteresis, and strict hit-test masks.
public enum StageLayoutEngine {

    public static func solve(_ input: StageLayoutInput) -> StageLayoutOutput {
        let playerLocal = CGRect(origin: .zero, size: input.playerSize)
        var rects: [CGRect] = [playerLocal]

        var lyricsLocal = CGRect.zero
        if input.isLyricsVisible {
            if let dragOrigin = input.activeDragLyricsOrigin {
                let rel = CGPoint(
                    x: dragOrigin.x - input.playerScreenOrigin.x,
                    y: dragOrigin.y - input.playerScreenOrigin.y
                )
                lyricsLocal = CGRect(origin: rel, size: input.lyricsSize)
            } else if let custom = input.customLyricsOffset {
                lyricsLocal = CGRect(origin: custom, size: input.lyricsSize)
            } else {
                lyricsLocal = place(size: input.lyricsSize, relativeTo: playerLocal, side: input.lyricsPlacement)
            }
            rects.append(lyricsLocal)
        }

        var libraryLocal = CGRect.zero
        if input.isLibraryVisible {
            if let dragOrigin = input.activeDragLibraryOrigin {
                let rel = CGPoint(
                    x: dragOrigin.x - input.playerScreenOrigin.x,
                    y: dragOrigin.y - input.playerScreenOrigin.y
                )
                libraryLocal = CGRect(origin: rel, size: input.librarySize)
            } else if let custom = input.customLibraryOffset {
                libraryLocal = CGRect(origin: custom, size: input.librarySize)
            } else {
                var anchor = playerLocal
                if input.isLyricsVisible && input.libraryPlacement == input.lyricsPlacement {
                    anchor = lyricsLocal
                }
                libraryLocal = place(size: input.librarySize, relativeTo: anchor, side: input.libraryPlacement)
            }
            rects.append(libraryLocal)
        }

        let unionRect = rects.dropFirst().reduce(rects[0]) { $0.union($1) }
        let shiftX = -unionRect.minX
        let shiftY = -unionRect.minY

        let finalPlayer = playerLocal.offsetBy(dx: shiftX, dy: shiftY)
        let finalLyrics = input.isLyricsVisible ? lyricsLocal.offsetBy(dx: shiftX, dy: shiftY) : .zero
        let finalLibrary = input.isLibraryVisible ? libraryLocal.offsetBy(dx: shiftX, dy: shiftY) : .zero

        let hostOrigin = CGPoint(
            x: input.playerScreenOrigin.x + unionRect.minX,
            y: input.playerScreenOrigin.y + unionRect.minY
        )
        let hostFrame = CGRect(origin: hostOrigin, size: unionRect.size)

        var hitFrames: [CGRect] = [finalPlayer]
        if input.isLyricsVisible { hitFrames.append(finalLyrics) }
        if input.isLibraryVisible { hitFrames.append(finalLibrary) }

        return StageLayoutOutput(
            hostFrame: hostFrame,
            playerFrame: finalPlayer,
            lyricsFrame: finalLyrics,
            libraryFrame: finalLibrary,
            interactiveHitFrames: hitFrames
        )
    }

    public static func place(size: CGSize, relativeTo anchor: CGRect, side: StagePlacement) -> CGRect {
        switch side {
        case .bottom:
            return CGRect(x: anchor.minX, y: anchor.minY - size.height, width: size.width, height: size.height)
        case .top:
            return CGRect(x: anchor.minX, y: anchor.maxY, width: size.width, height: size.height)
        case .right:
            return CGRect(x: anchor.maxX, y: anchor.maxY - size.height, width: size.width, height: size.height)
        case .left:
            return CGRect(x: anchor.minX - size.width, y: anchor.maxY - size.height, width: size.width, height: size.height)
        }
    }

    /// Computes a new player screen origin that preserves the top-center anchor across height transitions
    /// (e.g. Normal ↔ Mini), clamping within the active screen's visible frame if the expanded body
    /// would extend below or past screen edges.
    public static func anchoredOriginForHeightChange(
        currentOrigin: CGPoint,
        oldSize: CGSize,
        newSize: CGSize,
        visibleFrames: [CGRect]
    ) -> CGPoint {
        let topY = currentOrigin.y + oldSize.height
        let midX = currentOrigin.x + oldSize.width * 0.5
        let rawOrigin = CGPoint(
            x: midX - newSize.width * 0.5,
            y: topY - newSize.height
        )
        return clampOrigin(rawOrigin, size: newSize, visibleFrames: visibleFrames)
    }

    /// Clamps `origin` for a rect of `size` to the best-matching screen `visibleFrame`
    /// (supports multi-screen, mixed scales, and negative coordinates).
    public static func clampOrigin(
        _ origin: CGPoint,
        size: CGSize,
        visibleFrames: [CGRect]
    ) -> CGPoint {
        guard !visibleFrames.isEmpty else { return origin }
        let rect = CGRect(origin: origin, size: size)

        // 1. Prefer the screen containing the rect's center or largest intersection area
        var chosenFrame: CGRect?
        let center = CGPoint(x: rect.midX, y: rect.midY)
        if let containing = visibleFrames.first(where: { $0.contains(center) }) {
            chosenFrame = containing
        } else {
            var bestArea: CGFloat = 0
            for vf in visibleFrames {
                let inter = vf.intersection(rect)
                if !inter.isNull {
                    let area = inter.width * inter.height
                    if area > bestArea {
                        bestArea = area
                        chosenFrame = vf
                    }
                }
            }
        }

        // 2. If completely off-screen (e.g. monitor disconnected), choose nearest screen by center distance
        let targetVF: CGRect = chosenFrame ?? visibleFrames.min(by: { a, b in
            hypot(a.midX - center.x, a.midY - center.y) < hypot(b.midX - center.x, b.midY - center.y)
        }) ?? visibleFrames[0]

        let maxX = max(targetVF.minX, targetVF.maxX - size.width)
        let maxY = max(targetVF.minY, targetVF.maxY - size.height)
        return CGPoint(
            x: min(max(origin.x, targetVF.minX), maxX),
            y: min(max(origin.y, targetVF.minY), maxY)
        )
    }

    /// Chooses adaptive placement for Library in Mini mode based on available space around the player.
    public static func adaptiveLibraryPlacementForMiniMode(
        playerRect: CGRect,
        librarySize: CGSize,
        visibleFrame: CGRect
    ) -> StagePlacement {
        let topSpace = visibleFrame.maxY - playerRect.maxY
        let bottomSpace = playerRect.minY - visibleFrame.minY
        let rightSpace = visibleFrame.maxX - playerRect.maxX
        let leftSpace = playerRect.minX - visibleFrame.minX

        if topSpace >= librarySize.height { return .top }
        if bottomSpace >= librarySize.height { return .bottom }
        if rightSpace >= librarySize.width { return .right }
        if leftSpace >= librarySize.width { return .left }

        let candidates: [(StagePlacement, CGFloat)] = [
            (.top, topSpace - librarySize.height),
            (.bottom, bottomSpace - librarySize.height),
            (.right, rightSpace - librarySize.width),
            (.left, leftSpace - librarySize.width),
        ]
        return candidates.max(by: { $0.1 < $1.1 })?.0 ?? .bottom
    }

    /// Computes the magnetic snap candidate for a dragged module with enter/exit hysteresis
    /// and strict non-overlap against the player and any other visible module.
    public static func computeSnap(
        movedSize: CGSize,
        droppedOrigin: CGPoint,
        playerScreenRect: CGRect,
        otherModuleScreenRect: CGRect?,
        uiScale: CGFloat,
        wasAlreadySnapped: Bool,
        visibleFrames: [CGRect] = []
    ) -> StageSnapResult {
        let droppedRect = CGRect(origin: droppedOrigin, size: movedSize)
        var targets: [CGRect] = [playerScreenRect]
        if let other = otherModuleScreenRect {
            targets.append(other)
        }

        let enterThreshold = MotionTokens.Thresholds.snapEnterDistance * uiScale
        let alignThreshold = enterThreshold + (wasAlreadySnapped ? MotionTokens.Thresholds.snapExitHysteresis * uiScale : 0)

        var bestRect: CGRect?
        var bestDist = CGFloat.greatestFiniteMagnitude

        for target in targets {
            let candidates = candidateSnapRects(
                for: movedSize,
                droppedRect: droppedRect,
                against: target,
                alignThreshold: alignThreshold
            )
            for cand in candidates {
                if cand.insetBy(dx: 1.0, dy: 1.0).intersects(playerScreenRect) { continue }
                if let other = otherModuleScreenRect, cand.insetBy(dx: 1.0, dy: 1.0).intersects(other) { continue }

                // Reject candidates that push completely off-screen when screen frames are provided
                if !visibleFrames.isEmpty {
                    let onAnyScreen = visibleFrames.contains { $0.intersects(cand.insetBy(dx: 8.0, dy: 8.0)) }
                    if !onAnyScreen { continue }
                }

                let dist = hypot(cand.midX - droppedRect.midX, cand.midY - droppedRect.midY)
                if dist < bestDist {
                    bestDist = dist
                    bestRect = cand
                }
            }
        }

        guard let snapped = bestRect else {
            return StageSnapResult(snappedOffset: nil, targetScreenRect: nil, didSnap: false)
        }
        let offset = CGPoint(
            x: snapped.minX - playerScreenRect.minX,
            y: snapped.minY - playerScreenRect.minY
        )
        return StageSnapResult(snappedOffset: offset, targetScreenRect: snapped, didSnap: true)
    }

    /// Generates 4 edge-touching candidates (left, right, bottom, top of `target`) with edge alignment.
    public static func candidateSnapRects(
        for size: CGSize,
        droppedRect: CGRect,
        against target: CGRect,
        alignThreshold: CGFloat
    ) -> [CGRect] {
        var results: [CGRect] = []

        // 1. Left & Right of target -> align Y
        let minTouchY = target.minY - size.height + 20.0
        let maxTouchY = target.maxY - 20.0
        var snappedY = min(max(droppedRect.minY, minTouchY), maxTouchY)
        if abs(droppedRect.maxY - target.maxY) <= alignThreshold {
            snappedY = target.maxY - size.height
        } else if abs(droppedRect.minY - target.minY) <= alignThreshold {
            snappedY = target.minY
        }
        results.append(CGRect(x: target.minX - size.width, y: snappedY, width: size.width, height: size.height))
        results.append(CGRect(x: target.maxX, y: snappedY, width: size.width, height: size.height))

        // 2. Bottom & Top of target -> align X
        let minTouchX = target.minX - size.width + 20.0
        let maxTouchX = target.maxX - 20.0
        var snappedX = min(max(droppedRect.minX, minTouchX), maxTouchX)
        if abs(droppedRect.minX - target.minX) <= alignThreshold {
            snappedX = target.minX
        } else if abs(droppedRect.maxX - target.maxX) <= alignThreshold {
            snappedX = target.maxX - size.width
        }
        results.append(CGRect(x: snappedX, y: target.minY - size.height, width: size.width, height: size.height))
        results.append(CGRect(x: snappedX, y: target.maxY, width: size.width, height: size.height))

        return results
    }

    /// Returns true if a host-local point lies within any active interactive module frame.
    public static func isHitPoint(_ localPoint: CGPoint, in output: StageLayoutOutput) -> Bool {
        output.interactiveHitFrames.contains { $0.contains(localPoint) }
    }
}
