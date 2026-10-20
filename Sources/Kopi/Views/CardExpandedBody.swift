import Foundation
import SwiftUI
import KopiCore

/// Expanded content of a card: more of the content itself, and the metadata line the
/// compact card has no room for. Long content scrolls inside the card.
struct CardExpandedBody: View {
    let item: ClipboardItemSummary
    let detail: ClipboardItemDetail?
    let image: CGImage?
    let code: CodeHighlight?
    @ObservedObject var preview: PreviewStore.Entry
    @Environment(\.colorSchemeContrast) private var contrast

    init(item: ClipboardItemSummary, detail: ClipboardItemDetail?, image: CGImage?, code: CodeHighlight?, previews: PreviewStore) {
        self.item = item
        self.detail = detail
        self.image = image
        self.code = code
        self.preview = previews.entry(for: item.id)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            if let metadata {
                Text(metadata)
                    .font(.system(size: 9.5))
                    .lineSpacing(1)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch item.kind {
        case .text: textContent
        case .richText: richTextContent
        case .link: linkContent
        case .image: imageContent
        case .files: filesContent
        }
    }

    @ViewBuilder
    private var textContent: some View {
        ScrollView {
            if let code {
                CodeText(text: detail?.plainText ?? item.excerpt, highlight: code)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Text(detail?.plainText ?? item.excerpt)
                    .font(.system(size: 12))
                    .lineSpacing(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var richTextContent: some View {
        let document = preview.richText
            ?? RichTextDocument(plainText: detail?.plainText ?? item.excerpt)
        return ScrollView {
            if document.isEmpty {
                Text(item.excerpt)
                    .font(.system(size: 12))
                    .lineSpacing(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Text(document.displayText)
                    .font(.system(size: 12))
                    .lineSpacing(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var linkContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 7) {
                Text(item.domain ?? item.displayTitle)
                    .font(.system(size: 12.5, weight: .semibold))
                    .fixedSize(horizontal: false, vertical: true)
                if let url = item.primaryURL {
                    Text(url.absoluteString)
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let label = item.label, !label.isEmpty {
                    Text("Label: \(label)")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private var imageContent: some View {
        if let cgImage = image ?? preview.image {
            Image(decorative: cgImage, scale: 1)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(KopiTheme.insetSurface)
                .clipShape(shapes)
                .overlay(shapes.strokeBorder(KopiTheme.border(contrast: contrast), lineWidth: 0.5))
        } else {
            ZStack {
                KopiTheme.insetSurface
                ProgressView().controlSize(.small)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipShape(shapes)
            .overlay(shapes.strokeBorder(KopiTheme.border(contrast: contrast), lineWidth: 0.5))
        }
    }

    @ViewBuilder
    private var filesContent: some View {
        if detail == nil {
            ProgressView()
                .controlSize(.small)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 5) {
                    ForEach(Array(fileReferences.enumerated()), id: \.offset) { _, reference in
                        HStack(spacing: 6) {
                            Image(nsImage: FileIcons.icon(for: reference))
                                .resizable()
                                .frame(width: 14, height: 14)
                            Text(reference.displayName)
                                .font(.system(size: 10.5))
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer(minLength: 4)
                            if let size = sizeDescription(of: reference) {
                                Text(size)
                                    .font(.system(size: 9.5))
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.horizontal, 6)
                        .padding(.vertical, 4)
                        .background {
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(KopiTheme.controlSurface.opacity(0.6))
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var fileReferences: [FileReference] {
        detail?.fileReferences ?? []
    }

    private var shapes: RoundedRectangle {
        RoundedRectangle(cornerRadius: KopiTheme.controlCornerRadius, style: .continuous)
    }

    // MARK: - Metadata

    private var metadata: String? {
        var parts: [String] = []
        if let source = item.sourceApp?.kopiDisplayName {
            parts.append(source)
        }
        parts.append("Created \(CardTimestamp.detailed(item.createdAt))")
        parts.append("Copied \(CardTimestamp.detailed(item.lastCopiedAt))")
        if item.updatedAt != item.createdAt {
            parts.append("Updated \(CardTimestamp.detailed(item.updatedAt))")
        }
        if let size = totalSizeDescription {
            parts.append(size)
        }
        if item.isEdited {
            parts.append("Edited")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private var totalSizeDescription: String? {
        guard let detail else { return nil }
        let representationBytes = detail.representations.reduce(Int64(0)) { $0 + Int64($1.byteCount) }
        if representationBytes > 0 {
            return byteCountDescription(representationBytes)
        }
        let fileBytes = detail.fileReferences.reduce(Int64(0)) { total, reference in
            total + (reference.byteSize ?? reference.snapshot.map { Int64($0.byteCount) } ?? 0)
        }
        return fileBytes > 0 ? byteCountDescription(fileBytes) : nil
    }

    private func sizeDescription(of reference: FileReference) -> String? {
        guard let bytes = reference.byteSize ?? reference.snapshot.map({ Int64($0.byteCount) }), bytes > 0
        else { return nil }
        return byteCountDescription(bytes)
    }

    private func byteCountDescription(_ bytes: Int64) -> String {
        bytes.formatted(.byteCount(style: .file))
    }
}
