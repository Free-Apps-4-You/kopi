import CoreGraphics
import Foundation

/// One display, described in the terms panel placement needs.
///
/// The values come straight from `NSScreen` (frames are in the global, bottom-left
/// origin space), so placement can be checked without a display attached.
public struct PanelDisplayGeometry: Sendable, Hashable {
    /// Full frame of the display.
    public var frame: CGRect
    /// Frame of the display without the menu bar and the Dock.
    public var visibleFrame: CGRect
    /// Width of the camera housing, or `nil` on a display without a notch.
    public var notchWidth: CGFloat?
    public var notchBounds: CGRect?

    public init(frame: CGRect, visibleFrame: CGRect, notchWidth: CGFloat? = nil, notchBounds: CGRect? = nil) {
        self.frame = frame
        self.visibleFrame = visibleFrame
        self.notchWidth = notchBounds?.width ?? notchWidth.flatMap { $0 > 0 ? $0 : nil }
        self.notchBounds = notchBounds ?? self.notchWidth.map {
            CGRect(x: frame.midX - $0 / 2, y: visibleFrame.maxY, width: $0, height: max(0, frame.maxY - visibleFrame.maxY))
        }
    }

    public var hasNotch: Bool { notchBounds.map { !$0.isEmpty } ?? false }

    /// Height of the menu bar strip at the top of the display. On a notched display
    /// this is the housing area.
    public var topInset: CGFloat { max(0, frame.maxY - visibleFrame.maxY) }

    /// Y coordinate the top edge of the panel sits at: directly beneath the notch, or
    /// beneath the menu bar on a display without one.
    public var panelTopY: CGFloat { min(visibleFrame.maxY, notchBounds?.minY ?? visibleFrame.maxY) }
}

/// The strip that plugs the panel into a display's camera housing.
///
/// The neck is exactly the housing's width and runs from the top edge of the panel's
/// body up to the display's top edge, so the panel meets the housing without a gap.
public struct PanelAttachment: Sendable, Hashable {
    /// Width of the neck: the housing's, or the panel's when that is narrower.
    public let neckWidth: CGFloat
    /// Height of the strip between the body's top edge and the display's top edge.
    public let neckHeight: CGFloat
    /// Horizontal distance of the neck's centre from the panel's centre, zero when
    /// the panel sits centred under the housing.
    public let neckOffset: CGFloat

    public init(neckWidth: CGFloat, neckHeight: CGFloat, neckOffset: CGFloat = 0) {
        self.neckWidth = neckWidth
        self.neckHeight = neckHeight
        self.neckOffset = neckOffset
    }
}

/// Where the panel goes, and the strip of screen that reveals it on hover.
public struct PanelPlacement: Sendable, Hashable {
    /// Full frame of the panel window: the body, plus the strip up to the display's
    /// top edge on a display with a housing.
    public let frame: CGRect
    /// The rounded body of the panel, below the menu bar on every display.
    public let bodyRect: CGRect
    /// The neck to the camera housing, or `nil` on a display without one.
    public let attachment: PanelAttachment?
    public let triggerRect: CGRect

    public init(frame: CGRect, bodyRect: CGRect, attachment: PanelAttachment?, triggerRect: CGRect) {
        self.frame = frame
        self.bodyRect = bodyRect
        self.attachment = attachment
        self.triggerRect = triggerRect
    }

    /// Includes the physical screen's top edge, where macOS pins the pointer.
    /// CGRect.contains excludes that edge and would disagree with hover detection.
    public func containsRevealTarget(_ point: CGPoint) -> Bool {
        NotchHoverState.contains(point, in: triggerRect)
    }

    /// Rectangle of the neck in screen coordinates.
    public var neckRect: CGRect? {
        guard let attachment else { return nil }
        return CGRect(
            x: bodyRect.midX + attachment.neckOffset - attachment.neckWidth / 2,
            y: bodyRect.maxY,
            width: attachment.neckWidth,
            height: attachment.neckHeight
        )
    }

    /// Whether a point in screen coordinates lands on the panel's surface: the body,
    /// or the neck reaching up to the housing.
    public func containsSurface(_ point: CGPoint) -> Bool {
        if bodyRect.contains(point) { return true }
        return neckRect?.contains(point) ?? false
    }
}

/// The exact housing target. Both rectangles match; dwell never survives outside it.
public struct HoverTarget: Sendable, Hashable {
    /// The zone the pointer has to enter to start a dwell.
    public let triggerRect: CGRect
    /// Matches the trigger; retained for clients displaying hover geometry.
    public let comfortRect: CGRect

    public init(triggerRect: CGRect, comfortRect: CGRect) {
        self.triggerRect = triggerRect
        self.comfortRect = comfortRect
    }
}

/// Placement of the panel, as pure arithmetic so notched, notchless and multi-display
/// layouts can be checked without a window server.
public enum PanelGeometry {
    /// Size of the design, used when the display has room for it.
    public static let preferredSize = CGSize(width: 880, height: 560)
    /// Smallest size the grid stays usable at, on a small display.
    public static let minimumSize = CGSize(width: 640, height: 420)
    public static let horizontalMargin: CGFloat = 24
    public static let verticalMargin: CGFloat = 16
    /// Above this panel width the grid uses four columns instead of three.
    public static let fourColumnWidth: CGFloat = 760

    /// Display holding `point`, or the nearest one when the pointer sits between
    /// displays of different heights.
    public static func displayIndex(containing point: CGPoint, in displays: [PanelDisplayGeometry]) -> Int? {
        guard !displays.isEmpty else { return nil }
        if let index = displays.firstIndex(where: { $0.frame.contains(point) }) {
            return index
        }
        return displays.indices.min { left, right in
            squaredDistance(from: point, to: displays[left].frame)
                < squaredDistance(from: point, to: displays[right].frame)
        }
    }

    /// Panel size for a display: the design size, shrunk to fit a smaller screen.
    public static func size(for display: PanelDisplayGeometry) -> CGSize {
        let width = min(preferredSize.width, max(minimumSize.width, display.visibleFrame.width - horizontalMargin * 2))
        let height = min(preferredSize.height, max(minimumSize.height, display.visibleFrame.height - verticalMargin * 2))
        return CGSize(width: width.rounded(), height: height.rounded())
    }

    /// Columns of the adaptive grid: three on a narrow panel, four once it is wide.
    public static func columnCount(forPanelWidth width: CGFloat, compact: Bool = false) -> Int {
        let regular = width >= fourColumnWidth ? 4 : 3
        return compact ? regular + 1 : regular
    }

    /// Frame of the panel on `display`: the body, centred horizontally beneath the
    /// notch or the menu bar and kept inside the usable area, and the window grown to
    /// the display's top edge when the display has a camera housing.
    public static func placement(for display: PanelDisplayGeometry, size panelSize: CGSize? = nil) -> PanelPlacement {
        let resolved = panelSize ?? size(for: display)
        let leftLimit = display.visibleFrame.minX + horizontalMargin
        let rightLimit = display.visibleFrame.maxX - horizontalMargin - resolved.width
        let centred = (display.notchBounds?.midX ?? display.frame.midX) - resolved.width / 2
        let x = min(max(centred, leftLimit), max(leftLimit, rightLimit))
        let y = max(display.panelTopY - resolved.height, display.visibleFrame.minY + verticalMargin)
        let body = CGRect(x: x.rounded(), y: y.rounded(), width: resolved.width, height: resolved.height)
        let attachment = attachment(for: display, bodyRect: body)
        let frame = attachment.map {
            CGRect(x: body.minX, y: body.minY, width: body.width, height: body.height + $0.neckHeight)
        } ?? body
        return PanelPlacement(
            frame: frame,
            bodyRect: body,
            attachment: attachment,
            triggerRect: triggerRect(for: display)
        )
    }

    /// A captured app window contains only its body; the camera housing is hardware,
    /// not an artificial extension to include in window screenshots.
    public static func bodyOnlyPlacement(for display: PanelDisplayGeometry) -> PanelPlacement {
        let placement = placement(for: display)
        return PanelPlacement(frame: placement.bodyRect, bodyRect: placement.bodyRect,
                              attachment: nil, triggerRect: placement.triggerRect)
    }

    /// The neck to `display`'s camera housing, or `nil` when it has none or the body
    /// already reaches the display's top edge.
    private static func attachment(for display: PanelDisplayGeometry, bodyRect: CGRect) -> PanelAttachment? {
        guard display.hasNotch, let notch = display.notchBounds else { return nil }
        let neckHeight = display.frame.maxY - bodyRect.maxY
        guard neckHeight > 0 else { return nil }
        let width = min(notch.width, bodyRect.width)
        let centred = notch.midX - width / 2
        let x = min(max(centred, bodyRect.minX), bodyRect.maxX - width)
        return PanelAttachment(neckWidth: width, neckHeight: neckHeight, neckOffset: x + width / 2 - bodyRect.midX)
    }

    /// Only the physical camera housing activates hover. No target on notchless screens.
    public static func hoverTarget(for display: PanelDisplayGeometry) -> HoverTarget {
        let rect = display.hasNotch ? display.notchBounds!.intersection(display.frame) : .zero
        return HoverTarget(triggerRect: rect, comfortRect: rect)
    }

    public static func triggerRect(for display: PanelDisplayGeometry) -> CGRect {
        hoverTarget(for: display).triggerRect
    }

    /// AppKit supplies global logical coordinates, independent of pixel density and menu visibility.
    public static func measuredNotch(frame: CGRect, safeTop: CGFloat, left: CGRect?, right: CGRect?) -> CGRect? {
        guard let left, let right, safeTop.isFinite, safeTop > 0, safeTop < frame.height,
              left.maxX.isFinite, right.minX.isFinite,
              left.maxX >= frame.minX, right.minX <= frame.maxX,
              right.minX > left.maxX else { return nil }
        return CGRect(x: left.maxX, y: frame.maxY - safeTop,
                      width: right.minX - left.maxX, height: safeTop)
    }

    private static func squaredDistance(from point: CGPoint, to rect: CGRect) -> CGFloat {
        let dx = max(rect.minX - point.x, 0, point.x - rect.maxX)
        let dy = max(rect.minY - point.y, 0, point.y - rect.maxY)
        return dx * dx + dy * dy
    }
}
