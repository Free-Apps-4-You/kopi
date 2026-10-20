import AppKit
import Foundation
import KopiCore

/// Conversion between the stored rich-text flavours and AppKit attributed strings, so
/// card previews, the large preview and the editor all show and save the same thing.
enum RichTextCoding {
    /// Rich text as stored in the database.
    static func document(fromRTF data: Data) -> RichTextDocument? {
        guard let attributed = try? NSAttributedString(
            data: data,
            options: [.documentType: NSAttributedString.DocumentType.rtf],
            documentAttributes: nil
        ) else { return nil }
        return document(from: attributed)
    }

    /// HTML as stored in the database. HTML conversion belongs to the main thread.
    static func document(fromHTML html: String) -> RichTextDocument? {
        guard let data = html.data(using: .utf8) else { return nil }
        guard let attributed = try? NSAttributedString(
            data: data,
            options: [
                .documentType: NSAttributedString.DocumentType.html,
                .characterEncoding: String.Encoding.utf8.rawValue
            ],
            documentAttributes: nil
        ) else { return nil }
        return document(from: attributed)
    }

    /// Runs of text with the formatting the editor understands.
    static func document(from attributed: NSAttributedString) -> RichTextDocument {
        guard attributed.length > 0 else { return RichTextDocument(plainText: "") }
        let string = attributed.string as NSString
        var runs: [RichTextDocument.Run] = []
        attributed.enumerateAttributes(in: NSRange(location: 0, length: attributed.length), options: []) { attributes, range, _ in
            let text = string.substring(with: range)
            guard !text.isEmpty || runs.isEmpty else { return }
            var traits: RichTextDocument.Traits = []
            if let font = attributes[.font] as? NSFont {
                let symbolic = font.fontDescriptor.symbolicTraits
                if symbolic.contains(.bold) { traits.insert(.bold) }
                if symbolic.contains(.italic) { traits.insert(.italic) }
            }
            if let underline = attributes[.underlineStyle] as? NSNumber, underline.intValue != 0 {
                traits.insert(.underline)
            }
            let link = (attributes[.link] as? URL) ?? (attributes[.link] as? String).flatMap(URL.init(string:))
            runs.append(RichTextDocument.Run(text: text, traits: traits, linkURL: link))
        }
        return RichTextDocument(runs: runs)
    }

    /// Attributed string the editor edits and the preview draws.
    static func attributedString(from document: RichTextDocument) -> NSAttributedString {
        let result = NSMutableAttributedString()
        for run in document.runs {
            var attributes: [NSAttributedString.Key: Any] = [
                .font: font(traits: run.traits),
                .foregroundColor: NSColor.labelColor
            ]
            if run.traits.contains(.underline) {
                attributes[.underlineStyle] = NSNumber(value: NSUnderlineStyle.single.rawValue)
            }
            if let url = run.linkURL {
                attributes[.link] = url
                attributes[.foregroundColor] = NSColor.linkColor
            }
            result.append(NSAttributedString(string: run.text, attributes: attributes))
        }
        return result
    }

    /// Bold and italic are applied to the system font, so edited text keeps the
    /// metrics of the rest of the interface.
    static func font(traits: RichTextDocument.Traits, size: CGFloat = NSFont.systemFontSize) -> NSFont {
        let base = NSFont.systemFont(ofSize: size)
        guard !traits.isEmpty else { return base }
        var symbolic: NSFontDescriptor.SymbolicTraits = []
        if traits.contains(.bold) { symbolic.insert(.bold) }
        if traits.contains(.italic) { symbolic.insert(.italic) }
        let descriptor = base.fontDescriptor.withSymbolicTraits(symbolic)
        return NSFont(descriptor: descriptor, size: size) ?? base
    }
}
