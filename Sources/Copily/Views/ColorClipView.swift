import SwiftUI
import CopilyCore

struct ColorClipView: View {
    let color: ClipboardColor
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            ColorSwatch(color: color).frame(height: 32)
            Text(color.hexString).font(.system(size: 13, weight: .semibold, design: .monospaced))
            Text(color.rgbString).font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.secondary).lineLimit(1)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Color \(color.hexString), \(color.rgbString)")
    }
}

struct ColorInspector: View {
    let color: ClipboardColor
    let onCopy: (String) async -> Bool
    @StateObject private var copied = PanelState<String?>(nil)

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ColorSwatch(color: color).frame(height: 64)
            valueRow("HEX", value: color.hexString)
            valueRow("RGB", value: color.rgbString)
        }
    }

    private func valueRow(_ title: String, value: String) -> some View {
        HStack(spacing: 8) {
            Text(title).font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary).frame(width: 25, alignment: .leading)
            Text(value).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                .lineLimit(1).minimumScaleFactor(0.8)
            Spacer(minLength: 0)
            Button {
                Task { if await onCopy(value) { copied.value = value } }
            } label: {
                Image(systemName: copied.value == value ? "checkmark" : "doc.on.doc")
            }
            .buttonStyle(CopilyIconButtonStyle(size: 22))
            .accessibilityLabel("Copy \(title) color")
            .copilyTooltip(copied.value == value ? "Copied" : "Copy \(title) color")
        }
    }
}

private struct ColorSwatch: View {
    let color: ClipboardColor
    @Environment(\.colorSchemeContrast) private var contrast
    var body: some View {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(Color(red: Double(color.red) / 255, green: Double(color.green) / 255,
                        blue: Double(color.blue) / 255).opacity(color.alpha))
            .background(CopilyTheme.insetSurface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(CopilyTheme.border(contrast: contrast), lineWidth: 1)
                    .allowsHitTesting(false)
            }
            .accessibilityHidden(true)
    }
}
