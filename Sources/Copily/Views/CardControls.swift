import SwiftUI

struct MaximiseCardButton: View {
    let action: () -> Void
    var isFocused = false
    @StateObject private var hovered = PanelState(false)
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast
    var body: some View {
        Button(action: action) {
            Image(systemName: "arrow.up.left.and.arrow.down.right")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(isFocused || hovered.value ? CopilyTheme.accent : .primary)
                .frame(width: 22, height: 22)
                .background {
                    Circle()
                        .fill(CopilyTheme.chipSurface)
                        .overlay {
                            Circle().strokeBorder(CopilyTheme.border(contrast: contrast).opacity(0.7), lineWidth: 0.5)
                        }
                }
        }
        .buttonStyle(CopilyPressStyle())
        .opacity(isFocused || hovered.value ? 1 : (contrast == .increased ? 0.85 : 0.6))
        .onHover { hovered.value = $0 }
        .animation(CopilyMotion.animation(CopilyMotion.hover, reduceMotion: reduceMotion), value: hovered.value)
        .accessibilityLabel("Maximise card")
        .copilyTooltip("Maximise card")
    }
}

/// The same discoverable action affordance on every kind of card.
struct CardActionsMenu<Actions: View>: View {
    var title = "Card actions"
    @ViewBuilder let actions: () -> Actions

    var body: some View {
        Menu(content: actions) {
            Image(systemName: "ellipsis")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 20, height: 20)
                .background(Circle().fill(CopilyTheme.controlSurface.opacity(0.6)))
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel(title)
        .copilyTooltip(title)
    }
}

/// Every focused card uses the macOS close affordance in the same top-left position.
struct PreviewCloseBar: View {
    let close: () -> Void
    var body: some View {
        HStack {
            Button(action: close) {
                ZStack {
                    Circle().fill(Color(red: 1, green: 0.37, blue: 0.34))
                        .overlay {
                            Circle().strokeBorder(.black.opacity(0.12), lineWidth: 0.5)
                        }
                    Image(systemName: "xmark")
                        .font(.system(size: 6, weight: .bold))
                        .foregroundStyle(.black.opacity(0.7))
                }.frame(width: 12, height: 12)
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(CopilyPressStyle())
            .accessibilityLabel("Close preview")
            .copilyTooltip("Close preview (Esc)")
            Spacer()
        }.frame(height: 20)
    }
}
