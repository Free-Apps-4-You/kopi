import AppKit
import KopiCore

/// A focused item uses its natural content size, bounded by the panel and readable limits.
@MainActor
enum FocusPreviewSizing {
    static func text(_ text: String, available: CGSize) -> CGSize {
        let maxWidth = max(180, min(620, available.width - 96))
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 2
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 13), .paragraphStyle: paragraph]
        let attributed = NSAttributedString(string: text.isEmpty ? " " : text, attributes: attributes)
        let width = min(maxWidth, max(280, ceil(attributed.size().width) + 32))
        let bounds = attributed.boundingRect(with: CGSize(width: width - 32, height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin, .usesFontLeading])
        let maxHeight = max(96, min(430, available.height - 96))
        return CGSize(width: width, height: min(maxHeight, max(122, ceil(bounds.height) + 106)))
    }

    static func richText(_ document: RichTextDocument, available: CGSize) -> CGSize {
        let width = max(180, min(620, available.width - 96))
        let storage = NSTextStorage(attributedString: RichTextCoding.attributedString(from: document))
        let layout = NSLayoutManager()
        let container = NSTextContainer(containerSize: CGSize(width: width - 40, height: .greatestFiniteMagnitude))
        storage.addLayoutManager(layout)
        layout.addTextContainer(container)
        layout.ensureLayout(for: container)
        let height = ceil(layout.usedRect(for: container).height) + 110
        return CGSize(width: width, height: min(max(122, height), max(122, min(430, available.height - 96))))
    }

    static func image(_ pixels: CGSize, available: CGSize) -> CGSize {
        let maxWidth = max(180, min(720, available.width - 96))
        let maxHeight = max(140, min(460, available.height - 96))
        guard pixels.width > 0, pixels.height > 0 else { return CGSize(width: min(320, maxWidth), height: min(220, maxHeight)) }
        let scale = min(1, max(32, maxWidth - 32) / pixels.width, max(32, maxHeight - 108) / pixels.height)
        return CGSize(width: min(maxWidth, max(220, ceil(pixels.width * scale) + 32)),
                      height: min(maxHeight, ceil(pixels.height * scale) + 108))
    }
}
