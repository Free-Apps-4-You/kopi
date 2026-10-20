import SwiftUI
import KopiCore

/// Larger preview of one card, opened with Space.
struct PreviewOverlay: View {
    @ObservedObject var model: PanelViewModel
    let commands: PanelCommands
    @Environment(\.colorSchemeContrast) private var contrast
    @StateObject private var zoom = PanelState<CGFloat>(1)

    var body: some View {
        if let preview = model.preview {
            GeometryReader { proxy in
                let size = focusSize(preview, available: proxy.size)
                ZStack {
                    OverlayBackdrop { model.closePreview() }
                    OverlaySurface {
                        VStack(alignment: .leading, spacing: 10) {
                            PreviewCloseBar { model.closePreview() }
                            if preview.detail?.summary.kind == .image, !preview.isLoading, preview.error == nil {
                                image(preview)
                                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                            } else {
                                ScrollView {
                                    content(preview)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                            }
                            Divider().overlay(KopiTheme.border(contrast: contrast))
                            actions(preview)
                        }
                    }
                    .frame(width: size.width, height: size.height)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private func focusSize(_ preview: PanelViewModel.PreviewState, available: CGSize) -> CGSize {
        if let image = preview.image {
            return FocusPreviewSizing.image(CGSize(width: image.width, height: image.height), available: available)
        }
        let detail = preview.detail
        let summary = detail?.summary ?? model.summary(for: preview.itemID)
        if let detail, (detail.summary.kind == .text || detail.summary.kind == .richText),
           ClipboardColor.parse(detail.plainText ?? "") != nil {
            return CGSize(width: min(360, max(180, available.width - 48)),
                          height: min(270, max(122, available.height - 48)))
        }
        if detail?.summary.kind == .richText, let document = model.previews.richText(for: preview.itemID) {
            return FocusPreviewSizing.richText(document, available: available)
        }
        let text = preview.error ?? detail?.plainText ?? summary?.excerpt ?? "Loading…"
        return FocusPreviewSizing.text(text, available: available)
    }

    @ViewBuilder
    private func content(_ preview: PanelViewModel.PreviewState) -> some View {
        if preview.isLoading {
            ProgressView().controlSize(.small)
        } else if let error = preview.error {
            Text(error)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
        } else if let detail = preview.detail {
            if (detail.summary.kind == .text || detail.summary.kind == .richText),
               let color = ClipboardColor.parse(detail.plainText ?? "") {
                ColorInspector(color: color) { await model.copyColorValue($0) }
            } else {
                switch detail.summary.kind {
                case .text:
                    if let code = preview.code {
                        CodeText(text: detail.plainText ?? detail.summary.excerpt, highlight: code, size: 12)
                            .textSelection(.enabled)
                    } else {
                        Text(detail.plainText ?? detail.summary.excerpt)
                            .font(.system(size: 13))
                            .lineSpacing(2)
                            .textSelection(.enabled)
                    }
                case .richText:
                    richText(detail)
                case .link:
                    link(detail)
                case .image:
                    image(preview)
                case .files:
                    files(detail)
                }
            }
        }
    }

    @ViewBuilder
    private func richText(_ detail: ClipboardItemDetail) -> some View {
        let document = model.previews.richText(for: detail.id) ?? RichTextDocument(plainText: detail.plainText ?? "")
        if document.isEmpty {
            Text(detail.summary.excerpt)
                .font(.system(size: 13))
                .lineSpacing(2)
        } else {
            RichTextPreviewView(document: document)
                .font(.system(size: 13))
                .lineSpacing(2)
                .textSelection(.enabled)
        }
    }

    private func link(_ detail: ClipboardItemDetail) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(detail.summary.domain ?? detail.summary.displayTitle)
                .font(.system(size: 13, weight: .semibold))
            if let url = detail.summary.primaryURL {
                Text(url.absoluteString)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            if let label = detail.summary.label, !label.isEmpty {
                Text("Label: \(label)")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func image(_ preview: PanelViewModel.PreviewState) -> some View {
        if let cgImage = preview.image {
            FittedImagePreview(image: cgImage, zoom: $zoom.value)
        } else {
            ProgressView().controlSize(.small)
        }
    }

    private func files(_ detail: ClipboardItemDetail) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(detail.fileReferences.enumerated()), id: \.offset) { _, reference in
                HStack(spacing: 7) {
                    Image(nsImage: FileIcons.icon(for: reference))
                        .resizable()
                        .frame(width: 16, height: 16)
                    Text(reference.displayName)
                        .font(.system(size: 11.5))
                        .lineLimit(3)
                    if !reference.isOriginalAvailable {
                        Text(reference.isPreserved ? "preserved copy" : "missing")
                            .font(.system(size: 10))
                            .foregroundStyle(reference.isPreserved ? Color.secondary : Color.orange)
                    }
                    Spacer(minLength: 4)
                }
            }
            Text("\(detail.fileReferences.count) item\(detail.fileReferences.count == 1 ? "" : "s")")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
    }

    private func actions(_ preview: PanelViewModel.PreviewState) -> some View {
        let summary = preview.detail?.summary ?? model.summary(for: preview.itemID)
        return HStack(spacing: 4) {
            Button { commands.copy(preview.itemID) } label: { Label("Copy", systemImage: "doc.on.doc") }
                .kopiTooltip("Copy")
            Button { Task { await model.beginEditing(preview.itemID) } } label: { Label("Edit", systemImage: "pencil") }
                .kopiTooltip("Edit")
            if let summary {
                Button { Task { await model.togglePin(summary.id) } } label: {
                    Label(summary.isPinned ? "Unpin" : "Pin", systemImage: summary.isPinned ? "pin.slash" : "pin")
                }.kopiTooltip(summary.isPinned ? "Unpin" : "Pin")
            }
            Spacer(minLength: 4)
            if preview.detail?.summary.kind == .image {
                Button("Fit") { zoom.value = 1 }.disabled(zoom.value == 1).kopiTooltip("Fit image")
                Button { zoom.value = max(1, zoom.value / 1.5) } label: { Label("Zoom out", systemImage: "minus.magnifyingglass") }
                    .disabled(zoom.value == 1).kopiTooltip("Zoom out")
                Button { zoom.value = min(4, zoom.value * 1.5) } label: { Label("Zoom in", systemImage: "plus.magnifyingglass") }
                    .disabled(zoom.value == 4).kopiTooltip("Zoom in")
            }
        }
        .labelStyle(.iconOnly)
        .buttonStyle(KopiIconButtonStyle(size: 22))
        .font(.system(size: 12))
        .frame(height: 28)
    }

}

/// Fit the whole image inside the available viewport; zoom scrolls in both directions.
struct FittedImagePreview: View {
    let image: CGImage
    @Binding var zoom: CGFloat
    @Environment(\.colorSchemeContrast) private var contrast
    var body: some View {
        VStack(spacing: 8) {
            GeometryReader { proxy in
                let scale = min(proxy.size.width / CGFloat(image.width), proxy.size.height / CGFloat(image.height))
                let width = max(1, CGFloat(image.width) * scale * zoom)
                let height = max(1, CGFloat(image.height) * scale * zoom)
                ScrollView([.horizontal, .vertical]) {
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: width, height: height)
                        .frame(minWidth: proxy.size.width, minHeight: proxy.size.height)
                }
                .background(KopiTheme.insetSurface)
                .clipShape(RoundedRectangle(cornerRadius: KopiTheme.controlCornerRadius))
                .overlay {
                    RoundedRectangle(cornerRadius: KopiTheme.controlCornerRadius)
                        .strokeBorder(KopiTheme.border(contrast: contrast), lineWidth: 1)
                        .allowsHitTesting(false)
                }
            }

        }
    }
}
