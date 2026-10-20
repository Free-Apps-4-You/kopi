import Foundation

/// Rich text with portable runs and optional native document representations.
///
/// Editing a stored rich-text card rebuilds both an HTML and an RTF flavour from
/// this type, so applications can never paste an outdated version of the content.
public struct RichTextDocument: Sendable, Hashable, Codable {
    public struct Traits: OptionSet, Sendable, Hashable, Codable {
        public let rawValue: Int

        public init(rawValue: Int) {
            self.rawValue = rawValue
        }

        public static let bold = Traits(rawValue: 1 << 0)
        public static let italic = Traits(rawValue: 1 << 1)
        public static let underline = Traits(rawValue: 1 << 2)
    }

    public struct Run: Sendable, Hashable, Codable {
        public var text: String
        public var traits: Traits
        public var linkURL: URL?

        public init(text: String, traits: Traits = [], linkURL: URL? = nil) {
            self.text = text
            self.traits = traits
            self.linkURL = linkURL
        }
    }

    /// Native rich-text representations preserve paragraph styles, tables and lists.
    public var preservedRTF: Data?
    public var preservedHTML: String?
    public var runs: [Run] {
        didSet { preservedRTF = nil; preservedHTML = nil }
    }

    public init(runs: [Run]) {
        self.runs = runs
    }

    /// Unformatted document.
    public init(plainText: String) {
        runs = plainText.isEmpty ? [] : [Run(text: plainText)]
    }

    public var plainText: String {
        runs.map(\.text).joined()
    }

    public var isEmpty: Bool {
        plainText.isEmpty
    }

    public var hasFormatting: Bool {
        preservedRTF != nil || preservedHTML != nil || runs.contains { !$0.traits.isEmpty || $0.linkURL != nil }
    }

    /// HTML flavour pasted into rich-text applications.
    public func html() -> String {
        if let preservedHTML { return preservedHTML }
        var body = String()
        for line in lines() {
            let fragments = line.map(htmlFragment).joined()
            body += fragments.isEmpty ? "<p><br></p>" : "<p>\(fragments)</p>"
        }
        return """
        <!DOCTYPE html><html><head><meta charset="utf-8"></head><body>\(body)</body></html>
        """
    }

    /// RTF flavour pasted into rich-text applications.
    public func rtf() -> Data {
        if let preservedRTF { return preservedRTF }
        var output = #"{\rtf1\ansi\ansicpg1252\deff0{\fonttbl{\f0\fswiss Helvetica;}}\f0\fs24 "#
        for (index, line) in lines().enumerated() {
            if index > 0 { output += "\\par\n" }
            for fragment in line {
                output += rtfFragment(fragment)
            }
        }
        output += "}"
        return Data(output.utf8)
    }

    private struct Fragment {
        var text: String
        var traits: Traits
        var linkURL: URL?
    }

    /// Runs split into lines, so paragraphs can be encoded per line.
    private func lines() -> [[Fragment]] {
        guard !runs.isEmpty else { return [] }
        var result: [[Fragment]] = [[]]
        for run in runs {
            let pieces = run.text.components(separatedBy: "\n")
            for (index, piece) in pieces.enumerated() {
                if index > 0 { result.append([]) }
                guard !piece.isEmpty else { continue }
                result[result.count - 1].append(Fragment(text: piece, traits: run.traits, linkURL: run.linkURL))
            }
        }
        return result
    }

    private func htmlFragment(_ fragment: Fragment) -> String {
        var style: [String] = []
        if fragment.traits.contains(.bold) { style.append("font-weight:600") }
        if fragment.traits.contains(.italic) { style.append("font-style:italic") }
        if fragment.traits.contains(.underline) { style.append("text-decoration:underline") }

        var body = RichTextDocument.escapeHTML(fragment.text)
        if !style.isEmpty {
            body = #"<span style="\#(style.joined(separator: ";"))">\#(body)</span>"#
        }
        if let url = fragment.linkURL {
            body = #"<a href="\#(RichTextDocument.escapeHTML(url.absoluteString))">\#(body)</a>"#
        }
        return body
    }

    private func rtfFragment(_ fragment: Fragment) -> String {
        var openers: [String] = []
        var closers: [String] = []
        if fragment.traits.contains(.bold) {
            openers.append("\\b ")
            closers.append("\\b0 ")
        }
        if fragment.traits.contains(.italic) {
            openers.append("\\i ")
            closers.append("\\i0 ")
        }
        if fragment.traits.contains(.underline) {
            openers.append("\\ul ")
            closers.append("\\ul0 ")
        }
        var body = openers.joined() + RichTextDocument.escapeRTF(fragment.text) + closers.reversed().joined()
        if let url = fragment.linkURL {
            let target = RichTextDocument.escapeRTF(url.absoluteString)
            body = #"{\field{\*\fldinst{HYPERLINK "\#(target)"}}{\fldrslt{\#(body)}}}"#
        }
        return body
    }

    static func escapeHTML(_ text: String) -> String {
        var output = String()
        output.reserveCapacity(text.count)
        for character in text {
            switch character {
            case "&": output += "&amp;"
            case "<": output += "&lt;"
            case ">": output += "&gt;"
            case "\"": output += "&quot;"
            default: output.append(character)
            }
        }
        return output
    }

    static func escapeRTF(_ text: String) -> String {
        var output = String()
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\\": output += #"\\"#
            case "{": output += #"\{"#
            case "}": output += #"\}"#
            case "\n": output += "\\par\n"
            case "\t": output += "\\tab "
            default:
                if scalar.value < 128 {
                    output.unicodeScalars.append(scalar)
                } else if scalar.value <= 0xFFFF {
                    output += "\\u\(RichTextDocument.signedUTF16(Int(scalar.value)))?"
                } else {
                    for unit in String(scalar).utf16 {
                        output += "\\u\(RichTextDocument.signedUTF16(Int(unit)))?"
                    }
                }
            }
        }
        return output
    }

    private static func signedUTF16(_ value: Int) -> Int {
        value > 32767 ? value - 65536 : value
    }
}
