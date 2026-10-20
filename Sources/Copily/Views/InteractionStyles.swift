import SwiftUI

/// Tactile feedback without changing a button's layout, action or keyboard behavior.
struct CopilyPressStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(isEnabled ? (configuration.isPressed ? 0.78 : 1) : 0.45)
            .scaleEffect(reduceMotion ? 1 : (configuration.isPressed ? 0.96 : 1))
            .animation(CopilyMotion.animation(CopilyMotion.press, reduceMotion: reduceMotion), value: configuration.isPressed)
    }
}

/// Consistent chrome for the small toolbar and preview actions.
struct CopilyIconButtonStyle: ButtonStyle {
    var size: CGFloat = 28

    func makeBody(configuration: Configuration) -> some View {
        IconButtonBody(configuration: configuration, size: size)
    }

    private struct IconButtonBody: View {
        let configuration: ButtonStyleConfiguration
        let size: CGFloat
        @StateObject private var hovering = PanelState(false)
        @Environment(\.isEnabled) private var isEnabled
        @Environment(\.isFocused) private var isFocused
        @Environment(\.colorSchemeContrast) private var contrast
        @Environment(\.accessibilityReduceMotion) private var reduceMotion

        var body: some View {
            configuration.label
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(hovering.value || isFocused ? Color.primary : Color.secondary)
                .frame(width: size, height: size)
                .background {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(hovering.value || configuration.isPressed ? Color.primary.opacity(0.09) : CopilyTheme.controlSurface)
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(isFocused ? CopilyTheme.accent : CopilyTheme.border(contrast: contrast), lineWidth: 1)
                }
                .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .opacity(isEnabled ? 1 : 0.4)
                .scaleEffect(reduceMotion ? 1 : (configuration.isPressed ? 0.92 : 1))
                .onHover { hovering.value = $0 }
                .animation(CopilyMotion.animation(CopilyMotion.hover, reduceMotion: reduceMotion), value: hovering.value)
                .animation(CopilyMotion.animation(CopilyMotion.press, reduceMotion: reduceMotion), value: configuration.isPressed)
        }
    }
}

/// Shared action treatment for sheets; primary actions use the same teal as selection.
struct CopilyActionButtonStyle: ButtonStyle {
    var isPrimary = false

    func makeBody(configuration: Configuration) -> some View {
        ActionButtonBody(configuration: configuration, isPrimary: isPrimary)
    }

    private struct ActionButtonBody: View {
        let configuration: ButtonStyleConfiguration
        let isPrimary: Bool
        @StateObject private var hovering = PanelState(false)
        @Environment(\.isEnabled) private var isEnabled
        @Environment(\.isFocused) private var isFocused
        @Environment(\.colorSchemeContrast) private var contrast
        @Environment(\.accessibilityReduceMotion) private var reduceMotion

        var body: some View {
            configuration.label
                .font(.system(size: 11.5, weight: .semibold))
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .foregroundStyle(isPrimary ? CopilyTheme.onAccent : Color.primary)
                .background {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(isPrimary ? CopilyTheme.accent : CopilyTheme.controlSurface)
                        .overlay {
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(Color.primary.opacity(configuration.isPressed ? 0.10 : (hovering.value ? 0.045 : 0)))
                        }
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(isFocused ? CopilyTheme.accent : CopilyTheme.border(contrast: contrast), lineWidth: 1)
                }
                .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .opacity(isEnabled ? 1 : 0.42)
                .scaleEffect(reduceMotion ? 1 : (configuration.isPressed ? 0.97 : 1))
                .onHover { hovering.value = $0 }
                .animation(CopilyMotion.animation(CopilyMotion.hover, reduceMotion: reduceMotion), value: hovering.value)
                .animation(CopilyMotion.animation(CopilyMotion.press, reduceMotion: reduceMotion), value: configuration.isPressed)
        }
    }
}

private struct CopilyInputSurface: ViewModifier {
    var isFocused: Bool
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(CopilyTheme.insetSurface))
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(isFocused ? CopilyTheme.accent.opacity(0.8) : CopilyTheme.border(contrast: contrast), lineWidth: 1)
                    .allowsHitTesting(false)
            }
            .animation(CopilyMotion.animation(CopilyMotion.hover, reduceMotion: reduceMotion), value: isFocused)
    }
}

extension View {
    func copilyInputSurface(isFocused: Bool = false) -> some View {
        modifier(CopilyInputSurface(isFocused: isFocused))
    }
}
