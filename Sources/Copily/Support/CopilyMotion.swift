import SwiftUI

/// Every animation of the panel in one place: short, spring based, and switched off as
/// a group when the system asks for reduced motion.
enum CopilyMotion {
    /// A quick compression and soft release, driven only by native button state.
    static let press = Animation.spring(response: 0.20, dampingFraction: 0.78)
    /// Panel selection rings and the lift of a hovered card.
    static let selection = Animation.spring(response: 0.28, dampingFraction: 0.80)
    /// Tab and filter indicators, which should feel snappier than a card.
    static let indicator = Animation.spring(response: 0.25, dampingFraction: 0.88)
    /// Appearance of the content under the tabs.
    static let content = Animation.easeOut(duration: 0.16)
    /// Hover fills, which must not lag behind the pointer.
    static let hover = Animation.easeOut(duration: 0.12)
    /// A card growing in place: the grid reflows around it.
    static let expansion = Animation.spring(response: 0.34, dampingFraction: 0.82)
    /// The panel content as the panel opens: a short settle, quiet enough to read as
    /// the content simply taking its place.
    static let entrance = Animation.spring(response: 0.30, dampingFraction: 0.86)
    /// Previews, editors and the composer.
    static let overlay = Animation.spring(response: 0.30, dampingFraction: 0.88)
    /// The status message in the footer.
    static let status = Animation.spring(response: 0.26, dampingFraction: 0.90)
    /// The pulse of the loading skeletons, bounded so nothing keeps animating in a
    /// panel that stays open without ever finishing a load.
    static let skeletonPulse = Animation.easeInOut(duration: 1.1).repeatCount(8, autoreverses: true)

    /// The animation to use, or `nil` when motion should be left out entirely.
    static func animation(_ animation: Animation, reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : animation
    }

    /// The transition to use, or no transition at all under reduced motion.
    static func transition(_ transition: AnyTransition, reduceMotion: Bool) -> AnyTransition {
        reduceMotion ? .identity : transition
    }
}

extension AnyTransition {
    /// A short fade with a slight scale, for something that appears in place.
    static var copilySurface: AnyTransition {
        .asymmetric(
            insertion: .opacity.combined(with: .scale(scale: 0.985, anchor: .top)).combined(with: .offset(y: 4)),
            removal: .opacity.combined(with: .scale(scale: 0.995, anchor: .top))
        )
    }
}
