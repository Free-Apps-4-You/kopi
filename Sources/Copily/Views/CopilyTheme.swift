import AppKit
import SwiftUI
import CopilyCore

/// Copily's surfaces: graphite panels and cards, one restrained teal accent, rounded
/// corners and visible selection borders.
enum CopilyTheme {
    /// Accent used for selection, pins and the primary action.
    static let accent = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.isDark
            ? NSColor(srgbRed: 0.38, green: 0.82, blue: 0.77, alpha: 1)
            : NSColor(srgbRed: 0.025, green: 0.43, blue: 0.41, alpha: 1)
    })

    /// Background of the panel itself.
    static let surface = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.isDark
            ? NSColor(srgbRed: 0.095, green: 0.105, blue: 0.12, alpha: 1)
            : NSColor(srgbRed: 0.955, green: 0.96, blue: 0.97, alpha: 1)
    })

    /// Background of a card, one step above the panel.
    static let cardSurface = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.isDark
            ? NSColor(srgbRed: 0.145, green: 0.16, blue: 0.18, alpha: 1)
            : NSColor(white: 1, alpha: 1)
    })

    /// Background of a card under the pointer.
    static let hoverCardSurface = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.isDark
            ? NSColor(srgbRed: 0.175, green: 0.195, blue: 0.22, alpha: 1)
            : NSColor(srgbRed: 0.975, green: 0.995, blue: 0.99, alpha: 1)
    })

    /// Background of the selected card.
    static let selectedCardSurface = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.isDark
            ? NSColor(srgbRed: 0.145, green: 0.205, blue: 0.22, alpha: 1)
            : NSColor(srgbRed: 0.915, green: 0.965, blue: 0.955, alpha: 1)
    })

    /// Quiet chrome for controls, with a darker well for editable content.
    static let controlSurface = Color.copilyDynamic(
        light: NSColor(white: 1, alpha: 0.78),
        dark: NSColor(white: 1, alpha: 0.045)
    )
    static let insetSurface = Color.copilyDynamic(
        light: NSColor(white: 1, alpha: 0.92),
        dark: NSColor(white: 0, alpha: 0.18)
    )
    static let surfaceHighlight = Color.copilyDynamic(
        light: NSColor(white: 1, alpha: 0.65),
        dark: NSColor(white: 1, alpha: 0.045)
    )
    static let accentWash = accent.opacity(0.10)
    static let onAccent = Color.copilyDynamic(
        light: .white,
        dark: NSColor(srgbRed: 0.055, green: 0.12, blue: 0.12, alpha: 1)
    )

    /// Solid chip behind the quick-paste index, legible over a thumbnail.
    static let chipSurface = Color.copilyDynamic(
        light: NSColor(white: 1, alpha: 0.86),
        dark: NSColor(white: 0.09, alpha: 0.78)
    )

    /// Dim under the previews and editors when the material is switched off.
    static let scrim = Color.black

    static let panelCornerRadius: CGFloat = 16
    static let cardCornerRadius: CGFloat = 12
    /// Room around the card inside the panel window, for its shadow.
    static let shadowInset: CGFloat = 22
    static let contentPadding: CGFloat = 16
    static let cardSpacing: CGFloat = 12
    static let cardHeight: CGFloat = 176
    static let cardFooterHeight: CGFloat = 34
    /// Height of an expanded card: room for more content and the metadata line.
    static let expandedCardHeight: CGFloat = 330
    /// Room between a card's content and its edge.
    static let cardPadding: CGFloat = 12
    static let overlayCornerRadius: CGFloat = 14
    static let overlayPadding: CGFloat = 16
    /// Corner of the panel's small controls: tabs, chips, the search field.
    static let controlCornerRadius: CGFloat = 9

    /// Ordinary divider between the panel's sections.
    static func border(contrast: ColorSchemeContrast) -> Color {
        Color.primary.opacity(contrast == .increased ? 0.35 : 0.085)
    }

    /// Border of a card under the pointer, one step stronger than an ordinary border.
    static func hoverBorder(contrast: ColorSchemeContrast) -> Color {
        Color.primary.opacity(contrast == .increased ? 0.50 : 0.19)
    }

    /// Border of a card: the accent when selected, one step stronger under the pointer.
    static func cardBorder(isSelected: Bool, isHovering: Bool = false, contrast: ColorSchemeContrast) -> Color {
        if isSelected { return accent }
        return isHovering ? hoverBorder(contrast: contrast) : border(contrast: contrast)
    }

    /// Fill of a loading skeleton block.
    static func skeletonSurface(contrast: ColorSchemeContrast) -> Color {
        Color.primary.opacity(contrast == .increased ? 0.18 : 0.10)
    }

    /// Colours of detected code. Restrained on purpose: the accent carries keywords,
    /// and strings, numbers, types and comments are one muted step each, with stronger
    /// variants when the user has asked for increased contrast.
    enum Code {
        static func tokenColor(_ tokenClass: CodeTokenClass, contrast: ColorSchemeContrast) -> Color? {
            switch tokenClass {
            case .plain: nil
            case .keyword: accent
            case .string: color(stringLight, stringDark, increased: contrast == .increased, stringLightIncreased, stringDarkIncreased)
            case .number: color(numberLight, numberDark, increased: contrast == .increased, numberLightIncreased, numberDarkIncreased)
            case .type: color(typeLight, typeDark, increased: contrast == .increased, typeLightIncreased, typeDarkIncreased)
            case .comment: color(commentLight, commentDark, increased: contrast == .increased, commentLightIncreased, commentDarkIncreased)
            }
        }

        private static func color(
            _ light: NSColor,
            _ dark: NSColor,
            increased: Bool,
            _ lightIncreased: NSColor,
            _ darkIncreased: NSColor
        ) -> Color {
            Color.copilyDynamic(light: increased ? lightIncreased : light, dark: increased ? darkIncreased : dark)
        }

        private static let stringLight = NSColor(srgbRed: 0.62, green: 0.28, blue: 0.10, alpha: 1)
        private static let stringDark = NSColor(srgbRed: 0.94, green: 0.63, blue: 0.42, alpha: 1)
        private static let stringLightIncreased = NSColor(srgbRed: 0.50, green: 0.20, blue: 0.05, alpha: 1)
        private static let stringDarkIncreased = NSColor(srgbRed: 1.00, green: 0.72, blue: 0.52, alpha: 1)

        private static let numberLight = NSColor(srgbRed: 0.16, green: 0.35, blue: 0.72, alpha: 1)
        private static let numberDark = NSColor(srgbRed: 0.58, green: 0.74, blue: 1.00, alpha: 1)
        private static let numberLightIncreased = NSColor(srgbRed: 0.10, green: 0.26, blue: 0.62, alpha: 1)
        private static let numberDarkIncreased = NSColor(srgbRed: 0.68, green: 0.82, blue: 1.00, alpha: 1)

        private static let typeLight = NSColor(srgbRed: 0.45, green: 0.26, blue: 0.64, alpha: 1)
        private static let typeDark = NSColor(srgbRed: 0.80, green: 0.64, blue: 0.98, alpha: 1)
        private static let typeLightIncreased = NSColor(srgbRed: 0.35, green: 0.16, blue: 0.54, alpha: 1)
        private static let typeDarkIncreased = NSColor(srgbRed: 0.88, green: 0.74, blue: 1.00, alpha: 1)

        private static let commentLight = NSColor(srgbRed: 0.42, green: 0.44, blue: 0.47, alpha: 1)
        private static let commentDark = NSColor(srgbRed: 0.60, green: 0.62, blue: 0.66, alpha: 1)
        private static let commentLightIncreased = NSColor(srgbRed: 0.31, green: 0.33, blue: 0.36, alpha: 1)
        private static let commentDarkIncreased = NSColor(srgbRed: 0.70, green: 0.72, blue: 0.76, alpha: 1)
    }

    /// Lifts of the panel, its cards and its overlays, in one place so every surface
    /// sits on the same small set of shadows.
    enum Elevation {
        /// A hovered card: barely enough to read as lifted.
        static let cardRadius: CGFloat = 7
        static let cardY: CGFloat = 2
        static func cardColor(contrast: ColorSchemeContrast) -> Color {
            .black.opacity(contrast == .increased ? 0.34 : 0.24)
        }

        /// A selected card: the accent ring, and a soft accent glow behind it.
        static let selectionRadius: CGFloat = 7
        static let selectionY: CGFloat = 2
        static func selectionColor(contrast: ColorSchemeContrast) -> Color {
            accent.opacity(contrast == .increased ? 0.28 : 0.13)
        }

        /// Previews, editors and the composer.
        static let overlayRadius: CGFloat = 24
        static let overlayY: CGFloat = 12
        static let overlayColor = Color.black.opacity(0.42)

        /// The panel itself, on its transparent window.
        static let panelRadius: CGFloat = 22
        static let panelY: CGFloat = 10
        static let panelColor = Color.black.opacity(0.38)
    }
}

extension NSAppearance {
    /// Whether this appearance resolves to a dark interface.
    var isDark: Bool {
        bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }
}

extension Color {
    /// Colour that follows the system appearance, which is what the panel needs because
    /// it draws its own background rather than using a material.
    static func copilyDynamic(light: NSColor, dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.isDark ? dark : light
        })
    }
}

private struct CompactCardsKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var copilyCompactCards: Bool {
        get { self[CompactCardsKey.self] }
        set { self[CompactCardsKey.self] = newValue }
    }
    var copilyCardHeight: CGFloat { copilyCompactCards ? 148 : CopilyTheme.cardHeight }
}
