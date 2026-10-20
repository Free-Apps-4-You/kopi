import AppKit
import Combine
import SwiftUI
import KopiCore

/// The live backdrop is a stationary AppKit sibling of the animated SwiftUI
/// content, so scaling the wheel never scales/composites the live blur itself.
@MainActor
final class RadialWindowContent: NSView {
    private let blur = NSVisualEffectView()
    private let backdropMask = CAShapeLayer()
    private var focusSubscription: AnyCancellable?
    private var focused: Int?
    private var itemCount = 0
    private let host: NSHostingView<RadialView>
    private let notifications = NSWorkspace.shared.notificationCenter
    private nonisolated(unsafe) var observer: (any NSObjectProtocol)?

    init(rootView: RadialView) {
        host = NSHostingView(rootView: rootView)
        super.init(frame: NSRect(x: 0, y: 0, width: RadialGeometry.windowWidth, height: RadialGeometry.windowHeight))
        blur.material = .hudWindow
        blur.blendingMode = .behindWindow
        blur.state = .active
        blur.alphaValue = 0
        blur.wantsLayer = true
        blur.layer?.mask = backdropMask
        backdropMask.fillRule = .nonZero
        addSubview(blur)
        addSubview(host)
        host.frame = bounds
        host.autoresizingMask = [.width, .height]
        updateAccessibility()
        focusSubscription = rootView.state.$selected
            .combineLatest(rootView.state.$items.map(\.count), rootView.state.$loading)
            .sink { [weak self] selected, count, loading in
                self?.setFocus(loading ? nil : selected, count: count)
            }
        observer = notifications.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.updateAccessibility() } }
    }

    required init?(coder: NSCoder) { nil }

    func setPresented(_ presented: Bool) {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.11
            blur.animator().alphaValue = presented ? 0.816 : 0
        }
    }

    override func layout() {
        super.layout()
        if blur.frame != bounds {
            blur.frame = bounds
            backdropMask.frame = bounds
            updateBackdrop(animated: false)
        }
    }

    private func setFocus(_ selected: Int?, count: Int) {
        guard selected != focused || count != itemCount else { return }
        let canAnimate = count == itemCount
        focused = selected
        itemCount = count
        updateBackdrop(animated: canAnimate)
    }

    /// Extend only the backdrop's mask under the outward zoom. The live effect
    /// itself remains stationary; shared boundary rays keep the blur inside the
    /// focused wedge, with no halo around its unchanged neighbors.
    private func updateBackdrop(animated: Bool) {
        let radius = CGFloat(RadialGeometry.outerRadius)
        let center = CGPoint(x: RadialGeometry.wheelCenterX,
                             y: bounds.height - CGFloat(RadialGeometry.wheelCenterY))
        let path = CGMutablePath()
        path.addArc(center: center, radius: radius, startAngle: 0, endAngle: 2 * .pi, clockwise: true)
        path.closeSubpath()
        let reduced = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let count = max(0, min(8, itemCount))
        for index in 0..<count {
            let scale: CGFloat = index == focused && !reduced
                ? CGFloat(count == 1 ? RadialGeometry.singleItemHoverScale : RadialGeometry.hoverScale) : 1
            var transform = CGAffineTransform(a: scale, b: 0, c: 0, d: -scale,
                                              tx: center.x - radius * scale, ty: center.y + radius * scale)
            let wedge = RadialSegment(index: index, count: count)
                .path(in: CGRect(x: 0, y: 0, width: radius * 2, height: radius * 2)).cgPath
            if let mapped = wedge.copy(using: &transform) { path.addPath(mapped) }
        }
        let previous = backdropMask.presentation()?.path ?? backdropMask.path
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        backdropMask.path = path
        CATransaction.commit()
        if animated && !reduced, let previous {
            let animation = CASpringAnimation(keyPath: "path")
            let frequency = 2 * Double.pi / 0.22
            animation.mass = 1
            animation.stiffness = frequency * frequency
            animation.damping = 2 * 0.82 * frequency
            animation.fromValue = previous
            animation.toValue = path
            animation.duration = animation.settlingDuration
            backdropMask.add(animation, forKey: "focus")
        } else {
            backdropMask.removeAnimation(forKey: "focus")
        }
    }

    private func updateAccessibility() {
        blur.isHidden = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
        updateBackdrop(animated: false)
    }

    deinit {
        if let observer { notifications.removeObserver(observer) }
    }
}
