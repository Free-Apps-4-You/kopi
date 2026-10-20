import Foundation

/// Classifies the ranges of a text that should be coloured as code.
///
/// The tokeniser is a single deterministic scan, bounded by
/// ``maximumHighlightedCharacterCount``, with a small rule set per language: line and
/// block comments, quoted strings (single, double, backtick and Python triples),
/// numbers, keywords and type names. Everything else stays
/// ``CodeTokenClass/plain``; tokens never overlap and cover the analysed prefix in
/// order, so the UI can walk them once.
public enum CodeTokenizer {
    /// Longest prefix the tokeniser classifies. Cards can hold megabytes of text; the
    /// rendering only ever needs the visible beginning, and the cap keeps the work per
    /// card constant.
    public static let maximumHighlightedCharacterCount = 4000

    /// Full highlight of one text for one language.
    public static func highlight(_ text: String, language: CodeLanguage) -> CodeHighlight {
        let prefix = String(text.prefix(maximumHighlightedCharacterCount))
        return CodeHighlight(
            language: language,
            tokens: tokens(in: prefix, language: language),
            length: prefix.utf16.count
        )
    }

    /// Classified ranges of `text`, which is expected to be the bounded prefix.
    public static func tokens(in text: String, language: CodeLanguage) -> [CodeToken] {
        var scanner = Scanner(text: text, syntax: Syntax.for(language))
        return scanner.run()
    }
}

// MARK: - Syntax

/// The small rule set of one language: how comments and strings open and close, which
/// words are keywords and which identifiers read as types.
private struct Syntax {
    var lineComments: [String] = []
    var blockComments: [(open: String, close: String)] = []
    var stringDelimiters: [String] = []
    /// Delimiters that may run over a newline; the others end an unterminated string
    /// at the line break so one stray quote cannot paint the rest of a card.
    var multilineStrings: Set<String> = []
    var keywords: Set<String> = []
    var typeWords: Set<String> = []
    var marksCapitalisedTypes = false
    var isMarkup = false
    /// Shell variables: `$name` and `${name}` are types.
    var marksDollarIdentifiers = false

    static func `for`(_ language: CodeLanguage) -> Syntax {
        switch language {
        case .swift:
            var syntax = Syntax()
            syntax.lineComments = ["//"]
            syntax.blockComments = [("/*", "*/")]
            syntax.stringDelimiters = ["\"\"\"", "\""]
            syntax.multilineStrings = ["\"\"\""]
            syntax.keywords = swiftKeywords
            syntax.typeWords = swiftTypeWords
            syntax.marksCapitalisedTypes = true
            return syntax
        case .javascript, .typescript:
            var syntax = Syntax()
            syntax.lineComments = ["//"]
            syntax.blockComments = [("/*", "*/")]
            syntax.stringDelimiters = ["`", "\"", "'"]
            syntax.keywords = javascriptKeywords
            syntax.typeWords = javascriptTypeWords
            syntax.marksCapitalisedTypes = true
            return syntax
        case .python:
            var syntax = Syntax()
            syntax.lineComments = ["#"]
            syntax.stringDelimiters = ["\"\"\"", "'''", "\"", "'"]
            syntax.multilineStrings = ["\"\"\"", "'''"]
            syntax.keywords = pythonKeywords
            syntax.typeWords = pythonTypeWords
            syntax.marksCapitalisedTypes = true
            return syntax
        case .json:
            var syntax = Syntax()
            syntax.stringDelimiters = ["\""]
            syntax.keywords = jsonKeywords
            return syntax
        case .shell:
            var syntax = Syntax()
            syntax.lineComments = ["#"]
            syntax.stringDelimiters = ["\"", "'"]
            syntax.keywords = shellKeywords
            syntax.marksDollarIdentifiers = true
            return syntax
        case .html, .xml:
            var syntax = Syntax()
            syntax.blockComments = [("<!--", "-->")]
            syntax.stringDelimiters = ["\"", "'"]
            syntax.isMarkup = true
            return syntax
        case .generic:
            var syntax = Syntax()
            syntax.lineComments = ["//", "#"]
            syntax.blockComments = [("/*", "*/")]
            syntax.stringDelimiters = ["`", "\"", "'"]
            syntax.marksCapitalisedTypes = true
            return syntax
        }
    }

    private static let swiftKeywords: Set<String> = [
        "associatedtype", "class", "deinit", "enum", "extension", "fileprivate", "func", "import", "init", "inout",
        "internal", "let", "open", "operator", "package", "precedencegroup", "private", "protocol", "public",
        "rethrows", "static", "struct", "subscript", "typealias", "var", "break", "case", "catch", "continue",
        "default", "defer", "do", "else", "fallthrough", "for", "guard", "if", "in", "repeat", "return", "switch",
        "throw", "throws", "try", "where", "while", "as", "any", "false", "is", "nil", "self", "some", "super",
        "true", "async", "await", "actor", "convenience", "dynamic", "final", "indirect", "infix", "lazy",
        "mutating", "nonmutating", "optional", "override", "postfix", "prefix", "required", "unowned", "weak",
        "willSet", "didSet", "get", "set", "borrowing", "consuming"
    ]

    private static let swiftTypeWords: Set<String> = [
        "String", "Int", "Double", "Bool", "Array", "Dictionary", "Set", "Optional", "Error", "Result", "Void",
        "Any", "Never", "Character", "Float", "URL", "Date", "Data", "UUID", "CGFloat", "CGImage", "NSColor",
        "NSImage", "NSFont", "NSPasteboard", "Task", "Range", "TimeInterval", "Sequence", "Collection"
    ]

    private static let javascriptKeywords: Set<String> = [
        "break", "case", "catch", "class", "const", "continue", "debugger", "default", "delete", "do", "else",
        "enum", "export", "extends", "false", "finally", "for", "function", "if", "import", "in", "instanceof",
        "new", "null", "return", "super", "switch", "this", "throw", "true", "try", "typeof", "var", "void",
        "while", "with", "yield", "async", "await", "let", "static", "get", "set", "of", "interface", "type",
        "implements", "declare", "namespace", "readonly", "public", "private", "protected", "abstract", "as",
        "from", "undefined", "any", "unknown", "never", "string", "number", "boolean", "symbol", "bigint",
        "object", "keyof", "infer", "is", "satisfies"
    ]

    private static let javascriptTypeWords: Set<String> = [
        "String", "Number", "Boolean", "Object", "Array", "Function", "Promise", "Map", "Set", "Date", "RegExp",
        "JSON", "Math", "Error", "Symbol"
    ]

    private static let pythonKeywords: Set<String> = [
        "def", "class", "if", "elif", "else", "for", "while", "return", "import", "from", "as", "pass", "break",
        "continue", "try", "except", "finally", "raise", "with", "lambda", "yield", "global", "nonlocal",
        "assert", "del", "in", "is", "not", "and", "or", "none", "true", "false", "self", "async", "await",
        "match", "case"
    ]

    private static let pythonTypeWords: Set<String> = [
        "int", "str", "float", "bool", "list", "dict", "set", "tuple", "bytes", "object", "Exception",
        "ValueError", "TypeError", "KeyError", "RuntimeError"
    ]

    private static let jsonKeywords: Set<String> = ["true", "false", "null"]

    private static let shellKeywords: Set<String> = [
        "if", "then", "else", "elif", "fi", "for", "while", "until", "do", "done", "case", "esac", "function",
        "in", "select", "time", "coproc", "return", "exit", "break", "continue", "local", "export", "readonly",
        "declare", "typeset", "unset", "shift", "set", "source", "alias", "unalias", "eval", "exec", "trap",
        "wait", "read", "echo", "printf", "sudo", "cd", "ls", "mkdir", "rmdir", "rm", "cp", "mv", "cat",
        "grep", "awk", "sed", "chmod", "chown", "curl", "wget", "git", "make", "pip", "npm", "node", "brew",
        "kill", "pkill", "ps", "df", "du", "tar", "zip", "unzip", "ssh", "scp", "rsync", "find", "xargs",
        "head", "tail", "wc", "sort", "uniq", "cut", "tr", "tee", "touch", "ln", "stat", "man", "which",
        "whoami", "env", "pwd", "true", "false"
    ]
}

// MARK: - Scanning

private struct Scanner {
    let characters: [Character]
    let syntax: Syntax

    /// UTF-16 offset of every character index, plus the total at the end.
    private let offsets: [Int]
    /// Longest delimiters first, so `"""` wins over `"`.
    private let sortedStringDelimiters: [String]
    private var tokens: [CodeToken] = []
    private var plainStart = 0
    private var index = 0

    init(text: String, syntax: Syntax) {
        self.syntax = syntax
        let characters = Array(text)
        self.characters = characters
        self.sortedStringDelimiters = syntax.stringDelimiters.sorted { $0.count > $1.count }
        var offsets = [0]
        offsets.reserveCapacity(characters.count + 1)
        for character in characters {
            let length = character.unicodeScalars.reduce(0) { $0 + ($1.value > 0xFFFF ? 2 : 1) }
            offsets.append(offsets[offsets.count - 1] + length)
        }
        self.offsets = offsets
    }

    mutating func run() -> [CodeToken] {
        while index < characters.count {
            step()
        }
        append(.plain, plainStart, characters.count)
        return tokens
    }

    private mutating func step() {
        let character = characters[index]

        if let end = blockCommentEnd(at: index) {
            classify(.comment, from: index, to: end)
            return
        }
        if let end = lineCommentEnd(at: index) {
            classify(.comment, from: index, to: end)
            return
        }
        if let delimiter = stringDelimiter(at: index), let end = stringEnd(from: index, delimiter: delimiter) {
            classify(.string, from: index, to: end)
            return
        }
        if syntax.isMarkup, character == "<", markupStarts(at: index) {
            scanMarkup()
            return
        }
        if syntax.marksDollarIdentifiers, character == "$", let end = dollarIdentifierEnd(at: index) {
            classify(.type, from: index, to: end)
            return
        }
        if character.isNumber {
            let end = numberEnd(from: index)
            if end > index {
                classify(.number, from: index, to: end)
                return
            }
        }
        if Syntax.isIdentifierStart(character) {
            let end = identifierEnd(from: index)
            if let tokenClass = classification(of: String(characters[index..<end])) {
                classify(tokenClass, from: index, to: end)
            } else {
                index = end
            }
            return
        }
        index += 1
    }

    // MARK: - Token emission

    /// Closes the plain run at `start`, appends the classified run and continues plain
    /// after it.
    private mutating func classify(_ tokenClass: CodeTokenClass, from start: Int, to end: Int) {
        append(.plain, plainStart, start)
        append(tokenClass, start, end)
        plainStart = end
        index = end
    }

    private mutating func append(_ tokenClass: CodeTokenClass, _ start: Int, _ end: Int) {
        guard start < end else { return }
        tokens.append(CodeToken(range: offsets[start]..<offsets[end], tokenClass: tokenClass))
    }

    // MARK: - Comments

    private func blockCommentEnd(at index: Int) -> Int? {
        for comment in syntax.blockComments where matches(at: index, literal: comment.open) {
            var cursor = index + comment.open.count
            while cursor < characters.count {
                if matches(at: cursor, literal: comment.close) {
                    return cursor + comment.close.count
                }
                cursor += 1
            }
            return characters.count
        }
        return nil
    }

    private func lineCommentEnd(at index: Int) -> Int? {
        for comment in syntax.lineComments where matches(at: index, literal: comment) {
            var cursor = index + comment.count
            while cursor < characters.count, characters[cursor] != "\n" {
                cursor += 1
            }
            return cursor
        }
        return nil
    }

    // MARK: - Strings

    private func stringDelimiter(at index: Int) -> String? {
        sortedStringDelimiters.first { matches(at: index, literal: $0) }
    }

    private func stringEnd(from index: Int, delimiter: String) -> Int? {
        let multiline = syntax.multilineStrings.contains(delimiter)
        var cursor = index + delimiter.count
        while cursor < characters.count {
            if characters[cursor] == "\\", cursor + 1 < characters.count {
                cursor += 2
                continue
            }
            if matches(at: cursor, literal: delimiter) {
                return cursor + delimiter.count
            }
            if !multiline, characters[cursor] == "\n" {
                return cursor
            }
            cursor += 1
        }
        return characters.count
    }

    // MARK: - Markup

    /// Whether `<` opens a tag, a closing tag, a doctype or an XML declaration. Text
    /// content is written with entities in real markup, so no word-boundary check is
    /// needed here.
    private func markupStarts(at index: Int) -> Bool {
        guard let next = character(after: index) else { return false }
        if next == "!" || next == "?" { return true }
        if next == "/" {
            guard let afterSlash = index + 2 < characters.count ? characters[index + 2] : nil else { return false }
            return afterSlash.isLetter
        }
        return next.isLetter
    }

    /// Consumes one markup construct starting at `<`. Tag names read as types, quoted
    /// attribute values as strings, doctypes and XML declarations as comments.
    private mutating func scanMarkup() {
        let start = index
        if matches(at: start, literal: "<!--") {
            var cursor = start + 4
            while cursor < characters.count, !matches(at: cursor, literal: "-->") {
                cursor += 1
            }
            classify(.comment, from: start, to: min(characters.count, cursor + 3))
            return
        }
        if let next = character(after: start), next == "!" || next == "?" {
            var cursor = start
            while cursor < characters.count, characters[cursor] != ">" {
                cursor += 1
            }
            classify(.comment, from: start, to: min(characters.count, cursor + 1))
            return
        }

        var cursor = start + 1
        if cursor < characters.count, characters[cursor] == "/" { cursor += 1 }
        let nameStart = cursor
        while cursor < characters.count, isTagNameCharacter(characters[cursor]) {
            cursor += 1
        }
        guard cursor > nameStart else {
            index = start + 1
            return
        }

        append(.plain, plainStart, nameStart)
        append(.type, nameStart, cursor)
        var attributeStart = cursor

        while cursor < characters.count, characters[cursor] != ">" {
            if characters[cursor] == "\"" || characters[cursor] == "'" {
                let quote = characters[cursor]
                let stringStart = cursor
                cursor += 1
                while cursor < characters.count, characters[cursor] != quote, characters[cursor] != "\n" {
                    cursor += 1
                }
                let stringEnd = min(characters.count, cursor + 1)
                append(.plain, attributeStart, stringStart)
                append(.string, stringStart, stringEnd)
                attributeStart = stringEnd
                if cursor < characters.count, characters[cursor] == quote { cursor += 1 }
                continue
            }
            cursor += 1
        }
        let end = min(characters.count, cursor + 1)
        append(.plain, attributeStart, end)
        plainStart = end
        index = end
    }

    private func isTagNameCharacter(_ character: Character) -> Bool {
        character.isLetter || character.isNumber || character == "-" || character == ":" || character == "."
    }

    // MARK: - Identifiers and numbers

    private func classification(of word: String) -> CodeTokenClass? {
        let lower = word.lowercased()
        if syntax.keywords.contains(lower) {
            return .keyword
        }
        if syntax.typeWords.contains(word) {
            return .type
        }
        if syntax.marksCapitalisedTypes, let first = word.first, first.isUppercase, word.count > 1 {
            return .type
        }
        return nil
    }

    private func identifierEnd(from index: Int) -> Int {
        var cursor = index + 1
        while cursor < characters.count, Syntax.isIdentifierCharacter(characters[cursor]) {
            cursor += 1
        }
        return cursor
    }

    private func numberEnd(from index: Int) -> Int {
        var cursor = index
        if characters[cursor] == "0", cursor + 1 < characters.count,
           characters[cursor + 1] == "x" || characters[cursor + 1] == "X"
            || characters[cursor + 1] == "b" || characters[cursor + 1] == "B"
            || characters[cursor + 1] == "o" || characters[cursor + 1] == "O" {
            cursor += 2
            while cursor < characters.count, characters[cursor].isHexDigit || characters[cursor] == "_" {
                cursor += 1
            }
            return cursor
        }
        while cursor < characters.count, characters[cursor].isNumber || characters[cursor] == "_" {
            cursor += 1
        }
        if cursor + 1 < characters.count, characters[cursor] == ".", characters[cursor + 1].isNumber {
            cursor += 1
            while cursor < characters.count, characters[cursor].isNumber || characters[cursor] == "_" {
                cursor += 1
            }
        }
        if cursor < characters.count, characters[cursor] == "e" || characters[cursor] == "E" {
            var exponent = cursor + 1
            if exponent < characters.count, characters[exponent] == "+" || characters[exponent] == "-" {
                exponent += 1
            }
            if exponent < characters.count, characters[exponent].isNumber {
                cursor = exponent
                while cursor < characters.count, characters[cursor].isNumber {
                    cursor += 1
                }
            }
        }
        return cursor
    }

    private func dollarIdentifierEnd(at index: Int) -> Int? {
        guard index + 1 < characters.count else { return nil }
        if characters[index + 1] == "{" {
            var cursor = index + 2
            while cursor < characters.count, characters[cursor] != "}" {
                cursor += 1
            }
            return min(characters.count, cursor + 1)
        }
        guard Syntax.isIdentifierStart(characters[index + 1]) else { return nil }
        var cursor = index + 2
        while cursor < characters.count, Syntax.isIdentifierCharacter(characters[cursor]) {
            cursor += 1
        }
        return cursor
    }

    // MARK: - Small helpers

    private func character(after index: Int) -> Character? {
        index + 1 < characters.count ? characters[index + 1] : nil
    }

    private func matches(at index: Int, literal: String) -> Bool {
        var cursor = index
        for expected in literal {
            guard cursor < characters.count, characters[cursor] == expected else { return false }
            cursor += 1
        }
        return true
    }
}

private extension Syntax {
    static func isIdentifierStart(_ character: Character) -> Bool {
        character.isLetter || character == "_" || character == "$"
    }

    static func isIdentifierCharacter(_ character: Character) -> Bool {
        character.isLetter || character.isNumber || character == "_" || character == "$"
    }
}
