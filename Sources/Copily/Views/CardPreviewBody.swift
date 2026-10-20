import SwiftUI
import CopilyCore

/// Content preview of a card, one shape per kind.
struct CardPreviewBody: View {
    let item: ClipboardItemSummary
    @ObservedObject var preview: PreviewStore.Entry
    @Environment(\.colorSchemeContrast) private var contrast

    init(item: ClipboardItemSummary, previews: PreviewStore) {
        self.item = item
        self.preview = previews.entry(for: item.id)
    }

    var body: some View {
        switch item.kind {
        case .text:
            text
        case .richText:
            richText
        case .link:
            link
        case .image:
            image
        case .files:
            files
        }
    }

    /// A card whose text reads as code keeps the excerpt, monospaced and coloured by
    /// the cached highlight; every other text card is the ordinary readable excerpt.
    @ViewBuilder
    private var text: some View {
        if let color = ClipboardColor.parse(item.excerpt) {
            ColorClipView(color: color)
        } else if let highlight = preview.code {
            CodeText(text: item.excerpt, highlight: highlight, lineLimit: 6)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else {
            excerpt(item.excerpt)
        }
    }

    /// Readable excerpt: a little more room between the lines and a limit that fits the
    /// media area without crowding the meta row.
    private func excerpt(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12))
            .lineSpacing(2.5)
            .lineLimit(6)
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    @ViewBuilder
    private var richText: some View {
        if let color = ClipboardColor.parse(item.excerpt) {
            ColorClipView(color: color)
        } else if let document = preview.richText, !document.isEmpty {
            Text(document.displayText)
                .font(.system(size: 12))
                .lineSpacing(2.5)
                .lineLimit(6)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else {
            excerpt(item.excerpt)
        }
    }

    private var link: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 7) {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(CopilyTheme.accentWash)
                    .frame(width: 26, height: 26)
                    .overlay(
                        Image(systemName: "globe").copilyTooltip("Web link")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(CopilyTheme.accent)
                    )
                Text(item.domain ?? item.displayTitle)
                    .font(.system(size: 11.5, weight: .semibold))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
            }
            if let url = item.primaryURL?.absoluteString, url != item.domain {
                Text(url)
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .truncationMode(.middle)
            }
            if let label = item.label, !label.isEmpty {
                Text(label)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The thumbnail fills the media area edge to edge; the card clips it to its own
    /// radius, so there is no floating picture with a gap around it.
    @ViewBuilder
    private var image: some View {
        if let cgImage = preview.image {
            GeometryReader { geometry in
                Image(decorative: cgImage, scale: 1)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: geometry.size.width, height: geometry.size.height)
                    .clipped()
                    .overlay(alignment: .bottom) {
                        LinearGradient(
                            colors: [.clear, .black.opacity(0.12)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                        .frame(height: 28)
                        .allowsHitTesting(false)
                    }
            }
        } else {
            ZStack {
                CopilyTheme.insetSurface
                Image(systemName: "photo").copilyTooltip("Image")
                    .font(.system(size: 20, weight: .light))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var files: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 5) {
                ForEach(Array(item.fileNames.prefix(4).enumerated()), id: \.offset) { _, name in
                    fileIcon(name)
                }
                if item.fileCount > 4 {
                    Text("+\(item.fileCount - 4)")
                        .font(.system(size: 9, weight: .semibold, design: .rounded))
                        .foregroundStyle(.secondary)
                        .frame(width: 28, height: 28)
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(CopilyTheme.controlSurface)
                        )
                }
            }
            Spacer(minLength: 0)
            Text(item.fileNames.first ?? item.displayTitle)
                .font(.system(size: 11.5, weight: .medium))
                .lineLimit(1)
                .truncationMode(.middle)
            if item.fileCount > 1 {
                Text("\(item.fileCount) items")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func fileIcon(_ name: String) -> some View {
        RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(CopilyTheme.accentWash)
            .frame(width: 28, height: 28)
            .overlay(
                Image(systemName: FileIcons.symbolName(forFileName: name)).copilyTooltip("File")
                    .font(.system(size: 12, weight: .regular))
                    .foregroundStyle(CopilyTheme.accent)
            )
    }
}

extension RichTextDocument {
    /// Runs ready for SwiftUI, with bold, italic, underline and links preserved.
    var displayText: AttributedString {
        var result = AttributedString()
        for run in runs {
            var fragment = AttributedString(run.text)
            var font = Font.system(size: 11.5)
            if run.traits.contains(.bold) { font = font.bold() }
            if run.traits.contains(.italic) { font = font.italic() }
            if run.traits.contains(.bold) || run.traits.contains(.italic) {
                fragment.font = font
            }
            if run.traits.contains(.underline) {
                fragment.underlineStyle = .single
            }
            if let url = run.linkURL {
                fragment.link = url
                fragment.foregroundColor = CopilyTheme.accent
            }
            result.append(fragment)
        }
        return result
    }
}
