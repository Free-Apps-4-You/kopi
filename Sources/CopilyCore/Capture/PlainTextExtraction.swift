import Foundation

/// Derives plain text from the rich flavours of a copy.
///
/// A card must be searchable and its excerpt readable even when the pasteboard only
/// carries HTML or RTF, so Copily extracts the plain text itself. The extraction is
/// deliberately small: it needs the text of what was copied, never a document model,
/// which is why it stays in the core next to the capture pipeline instead of pulling
/// a text system into it.
enum PlainTextExtraction {
    static func plainText(fromHTML html: String) -> String {
        var output = String()
        var index = html.startIndex
        while index < html.endIndex {
            let character = html[index]
            if character == "<" {
                let (tag, next) = tag(in: html, from: index)
                index = next
                let name = tagName(of: tag)
                if name == "script" || name == "style" {
                    index = skipBlock(named: name, in: html, from: index)
                    continue
                }
                if breaksLine(tag: tag, name: name) {
                    output.append("\n")
                }
                continue
            }
            if character == "&" {
                let (decoded, next) = entity(in: html, from: index)
                if let decoded {
                    output.append(decoded)
                    index = next
                    continue
                }
            }
            output.append(character)
            index = html.index(after: index)
        }
        return normalize(output)
    }

    static func plainText(fromRTF rtf: Data) -> String {
        guard let source = String(data: rtf, encoding: .utf8)
            ?? String(data: rtf, encoding: .isoLatin1) else { return "" }
        var scanner = RTFTextScanner(source)
        return normalize(scanner.text())
    }

    // MARK: - HTML

    private static let lineBreakingElements: Set<String> = [
        "address", "article", "aside", "blockquote", "br", "dd", "div", "dl", "dt", "fieldset", "figcaption",
        "figure", "footer", "form", "h1", "h2", "h3", "h4", "h5", "h6", "header", "hr", "li", "main",
        "nav", "ol", "p", "pre", "section", "table", "tr", "ul"
    ]

    /// Body of the tag starting at `start`, and the index after it closes. Comments end
    /// at the first `-->`, so markup they mention never becomes text.
    private static func tag(in html: String, from start: String.Index) -> (String, String.Index) {
        var index = html.index(after: start)
        if index < html.endIndex, html[index...].hasPrefix("!--"),
           let end = html.range(of: "-->", range: index..<html.endIndex) {
            return ("!--", end.upperBound)
        }
        var body = String()
        while index < html.endIndex, html[index] != ">" {
            body.append(html[index])
            index = html.index(after: index)
        }
        if index < html.endIndex { index = html.index(after: index) }
        return (body, index)
    }

    private static func tagName(of tag: String) -> String {
        var name = String()
        for character in tag {
            if character == "/" || character == "!" {
                if name.isEmpty { continue }
                break
            }
            if character.isLetter || character.isNumber {
                name.append(character)
            } else {
                break
            }
        }
        return name.lowercased()
    }

    private static func breaksLine(tag: String, name: String) -> Bool {
        guard lineBreakingElements.contains(name) else { return false }
        return tag.hasPrefix("/") || name == "br" || name == "hr"
    }

    private static func skipBlock(named name: String, in html: String, from start: String.Index) -> String.Index {
        guard let range = html.range(of: "</\(name)", options: .caseInsensitive, range: start..<html.endIndex) else {
            return html.endIndex
        }
        let closingTagStart = html.index(before: range.lowerBound)
        return tag(in: html, from: closingTagStart).1
    }

    private static func entity(in html: String, from start: String.Index) -> (String?, String.Index) {
        var index = html.index(after: start)
        var body = String()
        while index < html.endIndex, html[index] != ";", body.count < 32 {
            let character = html[index]
            if character == "&" || character == "<" || character.isWhitespace { return (nil, start) }
            body.append(character)
            index = html.index(after: index)
        }
        guard index < html.endIndex, html[index] == ";" else { return (nil, start) }
        let next = html.index(after: index)
        guard let decoded = decode(entity: body) else { return (nil, start) }
        return (decoded, next)
    }

    private static func decode(entity body: String) -> String? {
        switch body.lowercased() {
        case "amp": return "&"
        case "lt": return "<"
        case "gt": return ">"
        case "quot": return "\""
        case "apos": return "'"
        case "nbsp", "ensp", "emsp", "thinsp": return " "
        case "hellip": return "\u{2026}"
        case "mdash": return "\u{2014}"
        case "ndash": return "\u{2013}"
        case "lsquo": return "\u{2018}"
        case "rsquo": return "\u{2019}"
        case "ldquo": return "\u{201C}"
        case "rdquo": return "\u{201D}"
        case "bull": return "\u{2022}"
        default: break
        }
        guard body.hasPrefix("#") else { return nil }
        let digits = body.dropFirst()
        let value: UInt32? = if digits.hasPrefix("x") || digits.hasPrefix("X") {
            UInt32(digits.dropFirst(), radix: 16)
        } else {
            UInt32(digits)
        }
        guard let value, let scalar = Unicode.Scalar(value) else { return nil }
        return String(Character(scalar))
    }

    // MARK: - Text cleanup

    /// Trailing whitespace is dropped per line and blank lines collapse, so derived
    /// text reads like the copied text rather than like markup. Leading whitespace is
    /// kept: it can be meaningful in code.
    private static func normalize(_ text: String) -> String {
        var lines: [String] = []
        for line in text.components(separatedBy: "\n") {
            var stripped = line
            while let last = stripped.last, last == " " || last == "\t" || last == "\r" {
                stripped.removeLast()
            }
            if stripped.isEmpty, lines.last?.isEmpty ?? true { continue }
            lines.append(stripped)
        }
        while let last = lines.last, last.isEmpty {
            lines.removeLast()
        }
        return lines.joined(separator: "\n")
    }
}

/// Minimal RTF reader: enough of the format to recover the text of a copied document
/// without pulling AppKit into the core.
private struct RTFTextScanner {
    private let characters: [Character]
    private var index = 0
    private var output = String()
    private var depth = 0
    private var skipFromDepth: Int?
    private var pendingSurrogate: UInt16?

    init(_ source: String) {
        self.characters = Array(source)
    }

    mutating func text() -> String {
        while index < characters.count {
            let character = characters[index]
            index += 1
            switch character {
            case "{":
                depth += 1
                if skipFromDepth == nil, startsIgnoredDestination() {
                    skipFromDepth = depth
                }
            case "}":
                if let start = skipFromDepth, depth <= start {
                    skipFromDepth = nil
                }
                depth = max(0, depth - 1)
            case "\\":
                guard skipFromDepth == nil else { continue }
                readControlSequence()
            default:
                guard skipFromDepth == nil else { continue }
                output.append(character)
            }
        }
        return output
    }

    // MARK: - Control sequences

    private mutating func readControlSequence() {
        guard let next = peek() else { return }
        switch next {
        case "*":
            index += 1
            skipFromDepth = max(1, depth)
        case "\\", "{", "}":
            output.append(next)
            index += 1
        case "'":
            index += 1
            readHexEscape()
        case "~":
            output.append(" ")
            index += 1
        case "-", "_":
            output.append("-")
            index += 1
        default:
            readControlWord()
        }
    }

    private mutating func readControlWord() {
        var word = String()
        while let character = peek(), character.isLetter {
            word.append(character)
            index += 1
        }
        var number = String()
        if let character = peek(), character == "-" {
            number.append(character)
            index += 1
        }
        while let character = peek(), character.isNumber {
            number.append(character)
            index += 1
        }
        consumeDelimiter()
        guard !word.isEmpty else { return }

        switch word {
        case "par", "line", "page", "sect", "row":
            output.append("\n")
            consumeSourceLineBreak()
        case "tab", "cell":
            output.append("\t")
        case "u":
            appendUnicodeScalar(Int(number) ?? 0)
            if peek() == "?" {
                index += 1
            }
        default:
            break
        }
    }

    private mutating func readHexEscape() {
        var digits = String()
        while digits.count < 2, let character = peek(), character.isHexDigit {
            digits.append(character)
            index += 1
        }
        guard let value = UInt32(digits, radix: 16), let scalar = Unicode.Scalar(value) else { return }
        output.append(Character(scalar))
    }

    /// Non-BMP characters arrive as two `\u` escapes, so a high surrogate is held until
    /// the escape that completes it.
    private mutating func appendUnicodeScalar(_ value: Int) {
        let code = value < 0 ? value + 65536 : value
        guard (0...0xFFFF).contains(code) else { return }
        let unit = UInt16(code)

        if let high = pendingSurrogate {
            pendingSurrogate = nil
            if (0xDC00...0xDFFF).contains(unit) {
                let value = 0x10000 + (UInt32(high - 0xD800) << 10) + UInt32(unit - 0xDC00)
                if let scalar = Unicode.Scalar(value) {
                    output.append(Character(scalar))
                    return
                }
            }
        }
        if (0xD800...0xDBFF).contains(unit) {
            pendingSurrogate = unit
            return
        }
        guard let scalar = Unicode.Scalar(unit) else { return }
        output.append(Character(scalar))
    }

    /// A space after a control word only delimits it and is not part of the text.
    private mutating func consumeDelimiter() {
        if peek() == " " {
            index += 1
        }
    }

    /// Line breaks in the RTF source are formatting of the file itself. Only the
    /// control word introduces a paragraph break in the text.
    private mutating func consumeSourceLineBreak() {
        if peek() == "\r" {
            index += 1
        }
        if peek() == "\n" {
            index += 1
        }
    }

    // MARK: - Ignored destinations

    private static let ignoredDestinations: Set<String> = [
        "annotation", "background", "colorschememapping", "colortbl", "dat", "expandedcolortbl", "filetbl",
        "fonttbl", "footer", "footerf", "footerl", "footerr", "footnote", "generator", "header", "headerf",
        "headerl", "headerr", "info", "latentstyles", "listtable", "listoverridetable", "nonshppict", "object",
        "pict", "revtbl", "rsidtbl", "shppict", "stylesheet", "themedata", "xml"
    ]

    /// Whether the group that is about to start is one whose content is not text.
    private func startsIgnoredDestination() -> Bool {
        var cursor = index
        while cursor < characters.count, characters[cursor].isWhitespace {
            cursor += 1
        }
        guard cursor < characters.count, characters[cursor] == "\\" else { return false }
        cursor += 1
        guard cursor < characters.count, characters[cursor] != "*" else { return true }
        var word = String()
        while cursor < characters.count, characters[cursor].isLetter {
            word.append(characters[cursor])
            cursor += 1
        }
        return RTFTextScanner.ignoredDestinations.contains(word.lowercased())
    }

    private func peek() -> Character? {
        index < characters.count ? characters[index] : nil
    }
}
