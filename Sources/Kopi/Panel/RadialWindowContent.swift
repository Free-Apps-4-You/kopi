import AppKit
import SwiftUI
import KopiCore

/// The live backdrop is a stationary AppKit sibling of the animated SwiftUI
/// content, so scaling the wheel never scales/composites the live blur itself.
@MainActor
final class RadialWindowContent: NSView {
    private let blur = NSVisualEffectView()
    private let host: NSHostingView<RadialView>
    private let notifications = NSWorkspace.shared.notificationCenter
    private nonisolated(unsafe) var observer: (any NSObjectProtocol)?

    init(rootView: RadialView) {
        host = NSHostingView(rootView: rootView)
        super.init(frame: NSRect(x: 0, y: 0, width: 600, height: 600))
        blur.material = .hudWindow
        blur.blendingMode = .behindWindow
        blur.state = .active
        blur.alphaValue = 0
        blur.wantsLayer = true
        blur.layer?.cornerRadius = RadialGeometry.outerRadius
        blur.layer?.masksToBounds = true
        addSubview(blur)
        addSubview(host)
        host.frame = bounds
        host.autoresizingMask = [.width, .height]
        updateAccessibility()
        observer = notifications.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.updateAccessibility() } }
    }

    required init?(coder: NSCoder) { nil }

    func setPresented(_ presented: Bool) {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.11
            blur.animator().alphaValue = presented ? 0.68 : 0
        }
    }

    override func layout() {
        super.layout()
        let radius = RadialGeometry.outerRadius
        blur.frame = NSRect(x: bounds.midX - radius, y: bounds.midY - radius, width: radius * 2, height: radius * 2)
    }

    private func updateAccessibility() {
        blur.isHidden = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
    }

    deinit {
        if let observer { notifications.removeObserver(observer) }
    }
}
