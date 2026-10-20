import CoreGraphics
import Testing
@testable import KopiCore

@Suite("Exact notch hover")
struct NotchHoverTests {
    let rect = CGRect(x: 650, y: 944, width: 210, height: 38)

    @Test func movementInsidePreservesFastEntryDeadline() {
        var state = NotchHoverState()
        #expect(state.update(point: CGPoint(x: 651, y: 950), targets: [rect], now: 10, delay: 0.35) == 10.35)
        #expect(state.update(point: CGPoint(x: 850, y: 982), targets: [rect], now: 10.1, delay: 0.35) == 10.35)
        #expect(state.update(point: CGPoint(x: 700, y: 960), targets: [rect], now: 10.4, delay: 0.35) == 10.35)
    }

    @Test func fastExitAndReentryReleaseSuppression() {
        var state = NotchHoverState()
        let inside = CGPoint(x: 700, y: 960)
        state.suppress(at: inside, targets: [rect])
        #expect(state.update(point: inside, targets: [rect], now: 10, delay: 0.1) == nil)
        #expect(state.update(point: CGPoint(x: 649, y: 960), targets: [rect], now: 10.01, delay: 0.1) == nil)
        #expect(state.update(point: inside, targets: [rect], now: 10.02, delay: 0.1) == 10.12)
    }

    @Test func outsideCancelsDwellAndCannotComplete() {
        for point in [CGPoint(x: 649.99, y: 950), CGPoint(x: 860, y: 950), CGPoint(x: 700, y: 943.99), CGPoint(x: 700, y: 982.01)] {
            var state = NotchHoverState()
            _ = state.update(point: CGPoint(x: 700, y: 950), targets: [rect], now: 0, delay: 0.3)
            #expect(state.update(point: point, targets: [rect], now: 1, delay: 0.3) == nil)
            #expect(state.update(point: CGPoint(x: 700, y: 950), targets: [rect], now: 2, delay: 0.3) == 2.3)
        }
    }

    @Test func displayChangeAndResetRestartDwell() {
        var state = NotchHoverState()
        let point = CGPoint(x: 700, y: 950)
        _ = state.update(point: point, targets: [rect], now: 1, delay: 0.3)
        #expect(state.update(point: point, targets: [rect.insetBy(dx: -1, dy: 0)], now: 2, delay: 0.3) == 2.3)
        state.reset()
        #expect(state.update(point: point, targets: [rect], now: 3, delay: 0.3) == 3.3)
        #expect(state.update(point: point, targets: [], now: 4, delay: 0.3) == nil)
    }

    @Test(arguments: [CGRect(x: 0, y: 0, width: 1512, height: 982), CGRect(x: -1800, y: 400, width: 1728, height: 1117), CGRect(x: 2048, y: -1200, width: 1470, height: 956)])
    func measuredHousingUsesGlobalLogicalCoordinates(frame: CGRect) throws {
        let left = CGRect(x: frame.minX, y: frame.maxY - 37.5, width: frame.width * 0.42, height: 37.5)
        let right = CGRect(x: left.maxX + 190.5, y: left.minY, width: frame.maxX - left.maxX - 190.5, height: 37.5)
        let notch = PanelGeometry.measuredNotch(frame: frame, safeTop: 37.5, left: left, right: right)
        #expect(notch == CGRect(x: left.maxX, y: frame.maxY - 37.5, width: 190.5, height: 37.5))
        let display = PanelDisplayGeometry(frame: frame, visibleFrame: frame, notchBounds: notch)
        #expect(PanelGeometry.triggerRect(for: display) == notch)
        #expect(display.panelTopY == notch?.minY)
        #expect(PanelGeometry.placement(for: display).neckRect?.midX == notch?.midX)
        let placement = PanelGeometry.bodyOnlyPlacement(for: display)
        let housing = try #require(notch)
        // Move all the way into the housing, including the screen's top boundary.
        // The body-only window doesn't contain it, but dismissal must honor reveal.
        for y in [housing.minY, housing.midY, frame.maxY] {
            let point = CGPoint(x: housing.midX, y: y)
            #expect(placement.containsRevealTarget(point))
            if y == frame.maxY { #expect(!placement.bodyRect.contains(point)) }
        }
        #expect(!placement.containsRevealTarget(CGPoint(x: housing.minX - 0.01, y: frame.maxY)))
        #expect(!placement.containsRevealTarget(CGPoint(x: housing.maxX, y: frame.maxY)))
        #expect(!placement.containsRevealTarget(CGPoint(x: housing.midX, y: frame.maxY + 0.01)))
    }

    @Test func missingOrInvalidHardwareDataNeverInventsNotch() {
        let frame = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        #expect(PanelGeometry.measuredNotch(frame: frame, safeTop: 38, left: nil, right: nil) == nil)
        #expect(PanelGeometry.measuredNotch(frame: frame, safeTop: 0, left: frame, right: frame) == nil)
        #expect(PanelGeometry.measuredNotch(frame: frame, safeTop: 38, left: frame, right: frame) == nil)
    }
}
