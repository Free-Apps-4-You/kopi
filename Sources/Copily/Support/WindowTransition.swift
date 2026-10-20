import AppKit
import QuartzCore
import SwiftUI

/// A dedicated animated surface keeps SwiftUI and AppKit from replacing the
/// transform of the layer that presents the expansion. The grid always lays out
/// at its final size; only this compositor surface changes during the reveal.
@MainActor
final class WindowTransitionHost: NSView {
    let animatedSurface = FlippedSurface()

    init<Content: View>(rootView: Content) {
        super.init(frame: .zero)
        let hosting = FirstMouseHostingView(rootView: rootView)
        hosting.sizingOptions = []
        wantsLayer = true
        animatedSurface.wantsLayer = true
        addSubview(animatedSurface)
        animatedSurface.addSubview(hosting)
        for (child, parent) in [(animatedSurface as NSView, self), (hosting as NSView, animatedSurface)] {
            child.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                child.leadingAnchor.constraint(equalTo: parent.leadingAnchor),
                child.trailingAnchor.constraint(equalTo: parent.trailingAnchor),
                child.topAnchor.constraint(equalTo: parent.topAnchor),
                child.bottomAnchor.constraint(equalTo: parent.bottomAnchor)
            ])
        }
    }

    required init?(coder: NSCoder) { nil }
    override var isFlipped: Bool { true }

    /// A click that brings the panel forward must also act on the card under the
    /// pointer, instead of being spent on activating the window.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    final class FlippedSurface: NSView {
        override var isFlipped: Bool { true }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    }
}

@MainActor
private final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

@MainActor
enum WindowTransition {
    static let animationKey = "copily.windowTransition"

    /// Collapse to a notch-sized shape at the top centre, independent of resolution.
    /// With no physical notch, the same reveal starts from the top menu-bar centre.
    static func collapsedTransform(size: CGSize, fromTop: Bool, isFlipped: Bool, sourceWidth: CGFloat? = nil) -> CATransform3D {
        guard size.width > 0, size.height > 0 else { return CATransform3DIdentity }
        if !fromTop { return CATransform3DMakeScale(0.94, 0.94, 1) }
        let width = sourceWidth.flatMap { $0.isFinite && $0 > 0 ? $0 : nil } ?? 180
        let scaleX = min(1, max(120, width) / size.width)
        let scaleY = min(1, 32 / size.height)
        return topAnchoredTransform(scaleX: scaleX, scaleY: scaleY, height: size.height, isFlipped: isFlipped)
    }

    private static func topAnchoredTransform(scaleX: CGFloat, scaleY: CGFloat, height: CGFloat, isFlipped: Bool) -> CATransform3D {
        var transform = CATransform3DMakeScale(scaleX, scaleY, 1)
        transform.m42 = (isFlipped ? -1 : 1) * height * (1 - scaleY) / 2
        return transform
    }

    static func animate(_ view: NSView?, opening: Bool, fromTop: Bool, duration: TimeInterval, sourceWidth: CGFloat? = nil, completion: (@MainActor () -> Void)? = nil) {
        guard let view else { completion?(); return }
        view.layoutSubtreeIfNeeded()
        let surface = (view as? WindowTransitionHost)?.animatedSurface ?? view
        surface.wantsLayer = true
        guard let layer = surface.layer else { completion?(); return }
        let interrupted = layer.animation(forKey: animationKey) != nil ? layer.presentation()?.transform : nil
        layer.removeAnimation(forKey: animationKey)
        guard duration > 0 else { completion?(); return }
        let collapsed = collapsedTransform(size: surface.bounds.size, fromTop: fromTop, isFlipped: surface.isFlipped, sourceWidth: sourceWidth)
        let animation: CAPropertyAnimation
        if opening && fromTop {
            let expansion = CAKeyframeAnimation(keyPath: "transform")
            let settle = topAnchoredTransform(scaleX: 1.008, scaleY: 1.008, height: surface.bounds.height, isFlipped: surface.isFlipped)
            expansion.values = [interrupted ?? collapsed, settle, CATransform3DIdentity].map { NSValue(caTransform3D: $0) }
            expansion.keyTimes = [0, 0.8, 1]
            expansion.timingFunctions = [CAMediaTimingFunction(controlPoints: 0.2, 0.8, 0.2, 1), CAMediaTimingFunction(name: .easeOut)]
            animation = expansion
        } else {
            let scale = CABasicAnimation(keyPath: "transform")
            scale.fromValue = NSValue(caTransform3D: interrupted ?? (opening ? collapsed : CATransform3DIdentity))
            scale.toValue = NSValue(caTransform3D: opening ? CATransform3DIdentity : collapsed)
            scale.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.8, 0.2, 1)
            animation = scale
        }
        animation.duration = duration
        animation.isRemovedOnCompletion = opening
        animation.fillMode = .forwards
        CATransaction.begin()
        CATransaction.setCompletionBlock {
            MainActor.assumeIsolated { completion?() }
        }
        layer.add(animation, forKey: animationKey)
        CATransaction.commit()
    }

    static func clear(_ view: NSView?) {
        let surface = (view as? WindowTransitionHost)?.animatedSurface ?? view
        surface?.layer?.removeAnimation(forKey: animationKey)
    }
}
