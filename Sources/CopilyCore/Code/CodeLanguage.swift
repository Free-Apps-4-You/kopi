import Foundation

/// Language a clipboard text was recognised as. The label names the card's badge and
/// selects the tokeniser rules; ``generic`` is code whose language is not certain.
public enum CodeLanguage: String, Sendable, Codable, CaseIterable, Hashable {
    case swift
    case javascript
    case typescript
    case python
    case json
    case shell
    case html
    case xml
    case generic

    public var displayName: String {
        switch self {
        case .swift: "Swift"
        case .javascript: "JavaScript"
        case .typescript: "TypeScript"
        case .python: "Python"
        case .json: "JSON"
        case .shell: "Shell"
        case .html: "HTML"
        case .xml: "XML"
        case .generic: "Code"
        }
    }
}

/// Class of one highlighted range of a text.
public enum CodeTokenClass: String, Sendable, Codable, CaseIterable, Hashable {
    case keyword
    case string
    case comment
    case number
    case type
    case plain
}

/// One classified range of a text.
///
/// Ranges are UTF-16 offsets into the analysed prefix, which is what an
/// `AttributedString` is built from. Tokens cover the prefix without gaps and never
/// overlap, in ascending order; the class ``CodeTokenClass/plain`` is carried by the
/// ranges between the interesting ones.
public struct CodeToken: Sendable, Hashable {
    public let range: Range<Int>
    public let tokenClass: CodeTokenClass

    public init(range: Range<Int>, tokenClass: CodeTokenClass) {
        self.range = range
        self.tokenClass = tokenClass
    }
}

/// Result of highlighting one text: the language to label and the classified ranges.
public struct CodeHighlight: Sendable, Hashable {
    public let language: CodeLanguage
    public let tokens: [CodeToken]
    /// UTF-16 length of the text the tokens were produced from.
    public let length: Int

    public init(language: CodeLanguage, tokens: [CodeToken], length: Int) {
        self.language = language
        self.tokens = tokens
        self.length = length
    }
}
