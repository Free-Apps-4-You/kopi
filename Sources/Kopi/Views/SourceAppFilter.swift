import SwiftUI
import KopiCore

struct SourceAppFilter: View {
    @ObservedObject var model: PanelViewModel
    @Environment(\.colorSchemeContrast) private var contrast

    private var selectedName: String {
        guard let identifier = model.sourceAppBundleIdentifier else { return "All Apps" }
        return model.sourceApplications.first { $0.bundleIdentifier == identifier }?.kopiDisplayName ?? identifier
    }

    var body: some View {
        Menu {
            Button { model.setSourceApp(nil) } label: {
                Label("All Apps", systemImage: model.sourceAppBundleIdentifier == nil ? "checkmark" : "square.grid.2x2")
            }
            if !model.sourceApplications.isEmpty { Divider() }
            ForEach(model.sourceApplications, id: \.bundleIdentifier) { app in
                if let identifier = app.bundleIdentifier {
                    Button { model.setSourceApp(identifier) } label: {
                        Label(app.kopiDisplayName ?? identifier,
                              systemImage: model.sourceAppBundleIdentifier == identifier ? "checkmark" : "app")
                    }
                }
            }
        } label: {
            Label(selectedName, systemImage: "app")
                .lineLimit(1).truncationMode(.tail)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.visible)
        .controlSize(.small)
        .font(.system(size: 11, weight: .medium))
        .padding(.horizontal, 8)
        .frame(width: 118, height: 26)
        .background(KopiTheme.controlSurface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(model.sourceAppBundleIdentifier == nil
                    ? KopiTheme.border(contrast: contrast) : KopiTheme.accent.opacity(0.55), lineWidth: 1)
                .allowsHitTesting(false)
        }
        .accessibilityLabel("Filter by source app: \(selectedName)")
        .kopiTooltip("Filter by source app: \(selectedName)")
    }
}
