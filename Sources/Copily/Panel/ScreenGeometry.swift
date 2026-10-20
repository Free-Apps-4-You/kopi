import AppKit
import Foundation
import CopilyCore

/// Bridges `NSScreen` to the geometry the core reasons about.
enum ScreenGeometry {
    /// Display the pointer is over, falling back to the main display and then to a
    /// sensible default when the system reports no screens.
    static func displayUnderPointer() -> PanelDisplayGeometry {
        let displays = NSScreen.screens.map(geometry(for:))
        let index = PanelGeometry.displayIndex(containing: NSEvent.mouseLocation, in: displays)
        if let index {
            return displays[index]
        }
        if let main = NSScreen.main {
            return geometry(for: main)
        }
        return fallback
    }

    static let fallback = PanelDisplayGeometry(
        frame: CGRect(x: 0, y: 0, width: 1440, height: 900),
        visibleFrame: CGRect(x: 0, y: 0, width: 1440, height: 875)
    )

    /// Camera housing width, measured from the areas macOS leaves beside it.
    static func geometry(for screen: NSScreen) -> PanelDisplayGeometry {
        let notch = PanelGeometry.measuredNotch(
            frame: screen.frame, safeTop: screen.safeAreaInsets.top,
            left: screen.auxiliaryTopLeftArea, right: screen.auxiliaryTopRightArea
        )
        return PanelDisplayGeometry(frame: screen.frame, visibleFrame: screen.visibleFrame, notchBounds: notch)
    }
}
