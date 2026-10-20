import CoreGraphics
import Foundation
import Testing

@testable import CopilyCore

@Suite("Panel geometry")
struct PanelGeometryTests {
    /// 14-inch MacBook Pro: menu bar and camera housing occupy the top 38 points.
    static let notched = PanelDisplayGeometry(
        frame: CGRect(x: 0, y: 0, width: 1512, height: 982),
        visibleFrame: CGRect(x: 0, y: 0, width: 1512, height: 944),
        notchWidth: 200
    )

    /// 27-inch display without a housing.
    static let notchless = PanelDisplayGeometry(
        frame: CGRect(x: 0, y: 0, width: 2560, height: 1440),
        visibleFrame: CGRect(x: 0, y: 0, width: 2560, height: 1416)
    )

    /// Second display to the right of the notched one, taller and with its own origin.
    static let external = PanelDisplayGeometry(
        frame: CGRect(x: 1512, y: 120, width: 1920, height: 1080),
        visibleFrame: CGRect(x: 1512, y: 120, width: 1920, height: 1056)
    )

    @Test("Window screenshots contain no artificial camera housing while hover stays exact")
    func capturedWindowExcludesHousing() {
        let placement = PanelGeometry.bodyOnlyPlacement(for: Self.notched)
        #expect(placement.frame == placement.bodyRect)
        #expect(placement.frame.maxY == Self.notched.panelTopY)
        #expect(placement.attachment == nil)
        #expect(placement.neckRect == nil)
        #expect(placement.triggerRect == Self.notched.notchBounds)
    }

    @Test("A notched display puts the panel beneath the housing, its window reaching the housing")
    func notchedPlacement() {
        let display = Self.notched
        #expect(display.hasNotch)
        #expect(display.topInset == 38)

        let size = PanelGeometry.size(for: display)
        #expect(size == CanvasSize.preferred)

        let placement = PanelGeometry.placement(for: display)
        #expect(placement.bodyRect == CGRect(x: 316, y: 384, width: 880, height: 560))
        #expect(placement.bodyRect.maxY == display.panelTopY)
        #expect(placement.bodyRect.midX == display.frame.midX)

        // The window adds the menu-bar strip, so the body keeps the place it has today.
        #expect(placement.frame == CGRect(x: 316, y: 384, width: 880, height: 598))
        #expect(placement.frame.maxY == display.frame.maxY)
        #expect(placement.frame.midX == display.frame.midX)

        // The neck is exactly the housing, centred on the display.
        #expect(placement.neckRect == CGRect(x: 656, y: 944, width: 200, height: 38))
        #expect(placement.attachment?.neckWidth == display.notchWidth)
        #expect(placement.attachment?.neckHeight == display.topInset)
        #expect(placement.attachment?.neckOffset == 0)

        // The hover target covers only the housing.
        #expect(placement.triggerRect == CGRect(x: 656, y: 944, width: 200, height: 38))
    }

    @Test("A display without a notch has no hover target")
    func notchlessPlacement() {
        let display = Self.notchless
        #expect(display.hasNotch == false)
        #expect(display.topInset == 24)

        let placement = PanelGeometry.placement(for: display)
        #expect(placement.frame == CGRect(x: 840, y: 856, width: 880, height: 560))
        #expect(placement.frame.maxY == display.visibleFrame.maxY)
        #expect(placement.triggerRect.isEmpty)

        // Unchanged: there is no neck and the body fills the whole window.
        #expect(placement.bodyRect == placement.frame)
        #expect(placement.attachment == nil)
        #expect(placement.neckRect == nil)
    }

    @Test("The neck keeps the housing's width and the window's bounds")
    func neckStaysWithinHousingAndWindow() {
        let wideHousing = PanelDisplayGeometry(
            frame: CGRect(x: 0, y: 0, width: 1512, height: 982),
            visibleFrame: CGRect(x: 0, y: 0, width: 1512, height: 944),
            notchWidth: 240
        )
        let placement = PanelGeometry.placement(for: wideHousing)
        #expect(placement.neckRect?.width == 240)
        #expect(placement.neckRect?.midX == wideHousing.frame.midX)
        #expect(placement.neckRect?.minY == placement.bodyRect.maxY)
        #expect(placement.neckRect?.maxY == wideHousing.frame.maxY)

        // A panel narrower than the housing gets a neck no wider than the panel.
        let oversizedHousing = PanelDisplayGeometry(
            frame: CGRect(x: 0, y: 0, width: 700, height: 500),
            visibleFrame: CGRect(x: 0, y: 0, width: 700, height: 462),
            notchWidth: 760
        )
        let clamped = PanelGeometry.placement(for: oversizedHousing)
        #expect(clamped.neckRect?.width == clamped.bodyRect.width)
        #expect(clamped.neckRect?.minX == clamped.bodyRect.minX)
        #expect(clamped.neckRect?.maxX == clamped.bodyRect.maxX)

        // However the panel is clamped, the neck never reaches beyond the housing or
        // the panel itself.
        for display in [Self.notched, wideHousing, oversizedHousing] {
            let placement = PanelGeometry.placement(for: display)
            guard let neck = placement.neckRect, let notchWidth = display.notchWidth else {
                Issue.record("Expected a neck on \(display)")
                continue
            }
            #expect(neck.width <= notchWidth)
            #expect(neck.minX >= placement.frame.minX)
            #expect(neck.maxX <= placement.frame.maxX)
        }
    }

    @Test("A clamped panel keeps its neck centred on the housing")
    func clampedPanelNeckOffset() {
        let display = PanelDisplayGeometry(
            frame: CGRect(x: 0, y: 0, width: 900, height: 700),
            visibleFrame: CGRect(x: 0, y: 0, width: 860, height: 662),
            notchWidth: 200
        )
        let placement = PanelGeometry.placement(for: display)
        #expect(placement.attachment?.neckOffset == 20)
        #expect(placement.neckRect?.midX == display.frame.midX)
    }

    @Test("Only the body and the neck count as the panel's surface")
    func surfaceContainsBodyAndNeck() {
        let display = Self.notched
        let placement = PanelGeometry.placement(for: display)
        #expect(placement.containsSurface(CGPoint(x: display.frame.midX, y: 700)))
        #expect(placement.containsSurface(CGPoint(x: display.frame.midX, y: 960)))
        // Beside the neck and outside the body are menu bar, shadow and desktop,
        // not panel surface.
        #expect(placement.containsSurface(CGPoint(x: 400, y: 960)) == false)
        #expect(placement.containsSurface(CGPoint(x: 400, y: 920)) == true)
        #expect(placement.containsSurface(CGPoint(x: 200, y: 700)) == false)
    }

    @Test("The hover target matches the housing exactly")
    func notchedHoverTarget() {
        let display = Self.notched
        let target = PanelGeometry.hoverTarget(for: display)
        #expect(target.triggerRect == CGRect(x: 656, y: 944, width: 200, height: 38))
        #expect(target.comfortRect == target.triggerRect)
        #expect(PanelGeometry.triggerRect(for: display) == target.triggerRect)
    }

    @Test("A display without a notch cannot activate hover")
    func notchlessHoverTarget() {
        let display = Self.notchless
        let target = PanelGeometry.hoverTarget(for: display)
        #expect(target.triggerRect.isEmpty)
        #expect(target.comfortRect.isEmpty)
    }

    @Test("Neither hover zone reaches above the display's top edge")
    func hoverTargetStaysOnDisplay() {
        for display in [Self.notched] {
            let target = PanelGeometry.hoverTarget(for: display)
            #expect(target.triggerRect.maxY <= display.frame.maxY)
            #expect(target.triggerRect.minX >= display.frame.minX)
            #expect(target.triggerRect.maxX <= display.frame.maxX)
            #expect(target.comfortRect.maxY <= display.frame.maxY)
            #expect(target.comfortRect.midX == target.triggerRect.midX)
        }
    }

    @Test("A small display shrinks the panel but keeps it usable and on screen")
    func smallDisplayAdaptation() {
        let display = PanelDisplayGeometry(
            frame: CGRect(x: 0, y: 0, width: 1024, height: 640),
            visibleFrame: CGRect(x: 0, y: 0, width: 1024, height: 535)
        )
        let size = PanelGeometry.size(for: display)
        #expect(size.width == 880)
        #expect(size.height == 503)
        #expect(size.height >= PanelGeometry.minimumSize.height)

        let placement = PanelGeometry.placement(for: display, size: size)
        #expect(placement.frame.maxY == display.panelTopY)
        #expect(placement.frame.minY >= display.visibleFrame.minY + PanelGeometry.verticalMargin)
    }

    @Test("A tiny screen keeps the panel inside the margins")
    func tinyDisplayClamps() {
        let display = PanelDisplayGeometry(
            frame: CGRect(x: 0, y: 0, width: 800, height: 600),
            visibleFrame: CGRect(x: 0, y: 0, width: 800, height: 520)
        )
        let size = PanelGeometry.size(for: display)
        #expect(size == CGSize(width: 752, height: 488))
        #expect(size.width >= PanelGeometry.minimumSize.width)

        let placement = PanelGeometry.placement(for: display, size: size)
        #expect(placement.frame.minX == display.visibleFrame.minX + PanelGeometry.horizontalMargin)
        #expect(placement.frame.maxX == display.visibleFrame.maxX - PanelGeometry.horizontalMargin)
        #expect(placement.frame.maxY == display.panelTopY)
    }

    @Test("The panel follows the display under the pointer")
    func displaySelection() {
        let displays = [Self.notched, Self.external]
        #expect(PanelGeometry.displayIndex(containing: CGPoint(x: 700, y: 500), in: displays) == 0)
        #expect(PanelGeometry.displayIndex(containing: CGPoint(x: 2000, y: 500), in: displays) == 1)
        #expect(PanelGeometry.displayIndex(containing: CGPoint(x: 1700, y: 1100), in: displays) == 1)
        // Between the two displays: the pointer belongs to the nearest one.
        #expect(PanelGeometry.displayIndex(containing: CGPoint(x: 200, y: 1200), in: displays) == 0)
        #expect(PanelGeometry.displayIndex(containing: CGPoint(x: 4000, y: 60), in: []) == nil)
    }

    @Test("Placement on a second display is relative to that display")
    func placementOnSecondDisplay() {
        let placement = PanelGeometry.placement(for: Self.external)
        #expect(placement.frame.midX == Self.external.frame.midX)
        #expect(placement.frame.maxY == Self.external.visibleFrame.maxY)
        #expect(placement.frame.minX >= Self.external.frame.minX)
        #expect(placement.triggerRect.isEmpty)
    }

    @Test("The grid uses three or four columns depending on the panel width")
    func columnCount() {
        #expect(PanelGeometry.columnCount(forPanelWidth: PanelGeometry.preferredSize.width) == 4)
        #expect(PanelGeometry.columnCount(forPanelWidth: PanelGeometry.fourColumnWidth) == 4)
        #expect(PanelGeometry.columnCount(forPanelWidth: PanelGeometry.fourColumnWidth - 1) == 3)
        #expect(PanelGeometry.columnCount(forPanelWidth: PanelGeometry.minimumSize.width) == 3)
        #expect(PanelGeometry.columnCount(forPanelWidth: PanelGeometry.preferredSize.width, compact: true) == 5)
        #expect(PanelGeometry.columnCount(forPanelWidth: PanelGeometry.minimumSize.width, compact: true) == 4)
    }

    private enum CanvasSize {
        static let preferred = CGSize(width: 880, height: 560)
    }
}
