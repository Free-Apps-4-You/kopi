import Foundation

/// Content that stops Kopi from editing a note as plain text.
public enum NotesRichContent: Sendable, Hashable, CustomStringConvertible {
    case attachments(Int)
    case tables
    case lists
    case links
    case media
    case formatting(String)
    case unknownMarkup(String)
    /// The note's markup does not reproduce its plain text, so editing the text would
    /// change content Kopi cannot see.
    case textMismatch

    public var description: String {
        switch self {
        case .attachments(let count): "\(count) attachment\(count == 1 ? "" : "s")"
        case .tables: "a table"
        case .lists: "a list or checklist"
        case .links: "a link"
        case .media: "media"
        case .formatting(let name): "formatting (\(name))"
        case .unknownMarkup(let name): "markup Kopi does not keep (\(name))"
        case .textMismatch: "text Kopi cannot reproduce exactly"
        }
    }

    /// Sentence shown next to a note that has to be edited in Apple Notes.
    public var displayName: String {
        "This note contains \(description), so it opens in Apple Notes for editing."
    }
}

/// Result of the conservative text-only check of a note body.
public enum NotesBodyCompatibility: Sendable, Hashable {
    case textOnly
    case rich(NotesRichContent)

    public var isTextOnly: Bool {
        if case .textOnly = self { return true }
        return false
    }

    public var reason: NotesRichContent? {
        if case .rich(let reason) = self { return reason }
        return nil
    }
}

/// What a note body holds.
public struct NotesBodyInspection: Sendable, Hashable {
    public var compatibility: NotesBodyCompatibility
    public var attachmentCount: Int

    public var hasRichContent: Bool { !compatibility.isTextOnly }

    public init(compatibility: NotesBodyCompatibility, attachmentCount: Int) {
        self.compatibility = compatibility
        self.attachmentCount = attachmentCount
    }
}

/// The conservative text-only compatibility check.
///
/// Kopi replaces the whole body when it saves an edit, so a note is only edited here
/// when its markup is something plain text reproduces exactly: paragraphs, line
/// breaks, spans and emphasis, and no formatting attributes at all. Anything else —
/// attachments, tables, lists, links, media, styling Kopi would drop, or markup whose
/// text does not match the note's plain text — opens in Apple Notes instead.
public enum NotesTextCompatibility {
    /// Elements that only wrap the document and carry no note content.
    private static let documentElements: Set<String> = ["html", "head", "meta", "style", "title", "link", "body", "base"]
    private static let plainElements: Set<String> = ["div", "p", "br", "span", "b", "i", "u", "strong", "em", "h1", "h2", "h3", "h4", "h5", "h6"]
    private static let tableElements: Set<String> = ["table", "thead", "tbody", "tfoot", "tr", "td", "th", "caption", "colgroup", "col"]
    private static let listElements: Set<String> = ["ul", "ol", "li", "dl", "dt", "dd"]
    private static let mediaElements: Set<String> = ["img", "object", "embed", "video", "audio", "iframe", "picture", "source", "svg", "canvas", "input"]
    /// Apple's own marker for a non-breaking space, which carries no formatting.
    private static let ignorableClassNames: Set<String> = ["Apple-converted-space"]
    private static let blockElements: Set<String> = ["div", "p", "br", "h1", "h2", "h3", "h4", "h5", "h6", "table", "tr", "ul", "ol", "li"]

    /// Inspects a note body: whether it can be edited as plain text, and how many
    /// attachments it carries.
    public static func inspect(bodyHTML: String) -> NotesBodyInspection {
        var attachmentCount = 0
        var sawTable = false
        var sawList = false
        var sawLink = false
        var sawMedia = false
        var attribute: String?
        var unknownElement: String?

        for element in elements(in: bodyHTML) {
            let name = element.name.lowercased()
            if documentElements.contains(name) { continue }
            if mediaElements.contains(name) {
                attachmentCount += 1
                sawMedia = true
                continue
            }
            if tableElements.contains(name) {
                sawTable = true
                continue
            }
            if listElements.contains(name) {
                sawList = true
                continue
            }
            if name == "a" {
                sawLink = true
                continue
            }
            if !plainElements.contains(name) {
                unknownElement = unknownElement ?? name
                continue
            }
            if attribute == nil, let offending = offendingAttribute(of: element.attributes) {
                attribute = offending
            }
        }

        let compatibility: NotesBodyCompatibility
        if attachmentCount > 0 {
            compatibility = .rich(.attachments(attachmentCount))
        } else if sawTable {
            compatibility = .rich(.tables)
        } else if sawList {
            compatibility = .rich(.lists)
        } else if sawLink {
            compatibility = .rich(.links)
        } else if sawMedia {
            compatibility = .rich(.media)
        } else if let attribute {
            compatibility = .rich(.formatting(attribute))
        } else if let unknownElement {
            compatibility = .rich(.unknownMarkup(unknownElement))
        } else {
            compatibility = .textOnly
        }

        return NotesBodyInspection(
            compatibility: compatibility,
            attachmentCount: attachmentCount
        )
    }

    /// The check Kopi makes before an edit: the same inspection, plus the cross-check
    /// that the markup actually spells out the note's plain text.
    public static func check(bodyHTML: String, plainText: String) -> NotesBodyCompatibility {
        let inspection = inspect(bodyHTML: bodyHTML)
        guard inspection.compatibility.isTextOnly else { return inspection.compatibility }
        let markupText = normalizedText(visibleText(of: bodyHTML))
        let noteText = normalizedText(NotesNoteText.normalized(plainText))
        guard markupText == noteText else { return .rich(.textMismatch) }
        return .textOnly
    }

    // MARK: - Markup

    struct Element {
        var name: String
        var attributes: [String: String]
    }

    /// Scans the tags of a note body. The scan is deliberately tolerant: it only has
    /// to be good enough to see what content a body holds.
    static func elements(in html: String) -> [Element] {
        var elements: [Element] = []
        let characters = Array(html)
        var index = 0
        while index < characters.count {
            guard characters[index] == "<" else {
                index += 1
                continue
            }
            var cursor = index + 1
            var isClosing = false
            if cursor < characters.count, characters[cursor] == "/" {
                isClosing = true
                cursor += 1
            }
            if cursor < characters.count, characters[cursor] == "!" || characters[cursor] == "?" {
                while cursor < characters.count, characters[cursor] != ">" { cursor += 1 }
                index = cursor + 1
                continue
            }
            var name = ""
            while cursor < characters.count, !characters[cursor].isWhitespace, characters[cursor] != ">", characters[cursor] != "/" {
                name.append(characters[cursor])
                cursor += 1
            }
            var attributes: [String: String] = [:]
            while cursor < characters.count, characters[cursor] != ">" {
                while cursor < characters.count, characters[cursor].isWhitespace { cursor += 1 }
                if cursor < characters.count, characters[cursor] == "/" || characters[cursor] == ">" { break }
                var attributeName = ""
                while cursor < characters.count, !characters[cursor].isWhitespace, characters[cursor] != "=", characters[cursor] != ">", characters[cursor] != "/" {
                    attributeName.append(characters[cursor])
                    cursor += 1
                }
                while cursor < characters.count, characters[cursor].isWhitespace { cursor += 1 }
                var value = ""
                if cursor < characters.count, characters[cursor] == "=" {
                    cursor += 1
                    while cursor < characters.count, characters[cursor].isWhitespace { cursor += 1 }
                    if cursor < characters.count, characters[cursor] == "\"" || characters[cursor] == "'" {
                        let quote = characters[cursor]
                        cursor += 1
                        while cursor < characters.count, characters[cursor] != quote {
                            value.append(characters[cursor])
                            cursor += 1
                        }
                        cursor += 1
                    } else {
                        while cursor < characters.count, !characters[cursor].isWhitespace, characters[cursor] != ">" {
                            value.append(characters[cursor])
                            cursor += 1
                        }
                    }
                }
                if !attributeName.isEmpty {
                    attributes[attributeName.lowercased()] = value
                }
            }
            if !isClosing, !name.isEmpty {
                elements.append(Element(name: name, attributes: attributes))
            }
            index = cursor + 1
        }
        return elements
    }

    private static func offendingAttribute(of attributes: [String: String]) -> String? {
        for (name, value) in attributes.sorted(by: { $0.key < $1.key }) {
            if name == "class",
               value.split(whereSeparator: \.isWhitespace).allSatisfy({ ignorableClassNames.contains(String($0)) }) {
                continue
            }
            return name
        }
        return nil
    }

    /// The text the markup shows, with block boundaries read as whitespace.
    static func visibleText(of html: String) -> String {
        var text = ""
        let characters = Array(html)
        var index = 0
        while index < characters.count {
            if characters[index] == "<" {
                var cursor = index + 1
                var name = ""
                if cursor < characters.count, characters[cursor] == "/" { cursor += 1 }
                while cursor < characters.count, !characters[cursor].isWhitespace, characters[cursor] != ">", characters[cursor] != "/" {
                    name.append(characters[cursor])
                    cursor += 1
                }
                if blockElements.contains(name.lowercased()) {
                    text.append(" ")
                }
                while cursor < characters.count, characters[cursor] != ">" { cursor += 1 }
                index = cursor + 1
            } else if characters[index] == "&" {
                var entity = ""
                var cursor = index + 1
                while cursor < characters.count, characters[cursor] != ";", entity.count < 8 {
                    entity.append(characters[cursor])
                    cursor += 1
                }
                if cursor < characters.count, characters[cursor] == ";", let decoded = decodedEntity(entity) {
                    text.append(decoded)
                    index = cursor + 1
                } else {
                    text.append(characters[index])
                    index += 1
                }
            } else {
                text.append(characters[index])
                index += 1
            }
        }
        return text
    }

    private static func decodedEntity(_ entity: String) -> Character? {
        switch entity.lowercased() {
        case "amp": return "&"
        case "lt": return "<"
        case "gt": return ">"
        case "quot": return "\""
        case "apos", "#39": return "'"
        case "nbsp": return " "
        default:
            break
        }
        if entity.hasPrefix("#") {
            let digits = entity.dropFirst()
            let value = digits.hasPrefix("x") || digits.hasPrefix("X")
                ? UInt32(digits.dropFirst(), radix: 16)
                : UInt32(digits, radix: 10)
            guard let value, let scalar = Unicode.Scalar(value) else { return nil }
            return Character(scalar)
        }
        return nil
    }

    /// Whitespace differences are not content: runs are collapsed and the ends trimmed.
    static func normalizedText(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}
