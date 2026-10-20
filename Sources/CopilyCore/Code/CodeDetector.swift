import Foundation

/// Decides whether clipboard text is source code.
///
/// The detector is deliberately conservative, because a card that is styled as code
/// when it is not is worse than a code fragment that stays plain: prose, notes, lists
/// and URL fragments must never be detected. Detection needs a code-specific signal —
/// a distinctive keyword, a brace pair, several operators, a code comment, a shell
/// variable, markup tags or an import line — plus enough evidence overall. A known
/// editor or terminal as the card's source app lowers the amount of evidence required,
/// but never removes the signal itself.
public struct CodeDetector: Sendable {
    /// Longest prefix of a text the detector looks at. The analysis is deterministic
    /// and bounded, so a pasted log or document costs the same as a snippet.
    public static let maximumAnalyzedLength = 2000
    public static let minimumLength = 6

    public init() {}

    /// The language `text` looks like, or `nil` when it should stay plain.
    public func detect(_ text: String, sourceApp: SourceAppInfo? = nil) -> CodeLanguage? {
        let sample = String(text.prefix(Self.maximumAnalyzedLength))
        guard sample.count >= 2 else { return nil }
        if let language = Self.shebangLanguage(in: sample) { return language }
        if let language = Self.jsonLanguage(in: sample) { return language }

        let signals = Signals(sample)
        if let language = signals.markupLanguage { return language }
        guard sample.count >= Self.minimumLength else { return nil }

        let hasHint = Self.hasSourceHint(sourceApp)
        let total = signals.strong + signals.shaped + signals.neutral
        let enoughEvidence = hasHint ? total >= 2 : total >= 3
        let anchored = signals.strong >= 1 || signals.shaped >= 2
        guard enoughEvidence, anchored else { return nil }
        return Self.classify(signals)
    }

    /// Strongest signal first: a shebang names the interpreter, and a valid JSON
    /// document is not prose by any reading.
    private static func shebangLanguage(in sample: String) -> CodeLanguage? {
        guard let firstLine = sample.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).first,
              firstLine.hasPrefix("#!")
        else { return nil }
        let interpreter = firstLine.lowercased()
        if interpreter.contains("python") { return .python }
        if interpreter.contains("swift") { return .swift }
        if interpreter.contains("node") || interpreter.contains("deno") { return .javascript }
        return .shell
    }

    private static func jsonLanguage(in sample: String) -> CodeLanguage? {
        let trimmed = sample.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = trimmed.first, first == "{" || first == "[" else { return nil }
        guard trimmed.last == (first == "{" ? "}" : "]"), trimmed.count >= 2 else { return nil }
        guard let data = trimmed.data(using: .utf8) else { return nil }
        guard (try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])) != nil else {
            return nil
        }
        return .json
    }

    /// Editor and terminal bundle identifiers, exact or by prefix, that let weak
    /// evidence pass.
    static func hasSourceHint(_ sourceApp: SourceAppInfo?) -> Bool {
        guard let identifier = sourceApp?.bundleIdentifier else { return false }
        if editorBundleIdentifiers.contains(identifier) { return true }
        return editorBundleIdentifierPrefixes.contains { identifier.hasPrefix($0) }
    }

    private static let editorBundleIdentifiers: Set<String> = [
        "com.apple.dt.Xcode",
        "com.apple.Terminal",
        "com.apple.ScriptEditor2",
        "com.microsoft.VSCode",
        "com.microsoft.VSCodeInsiders",
        "com.google.android.studio",
        "com.sublimetext.4",
        "com.sublimetext.3",
        "com.panic.Nova",
        "com.macromates.TextMate",
        "com.github.atom",
        "dev.zed.Zed",
        "com.googlecode.iterm2",
        "dev.warp.Warp-Stable",
        "com.mitchellh.ghostty",
        "net.kovidgoyal.kitty",
        "org.alacritty",
        "com.github.wez.wezterm",
        "org.gnu.Emacs"
    ]

    private static let editorBundleIdentifierPrefixes = [
        "com.jetbrains.",
        "com.todesktop."
    ]

    // MARK: - Classifying

    private static func classify(_ signals: Signals) -> CodeLanguage {
        let swift = signals.score(
            strong: ["func", "guard", "protocol", "extension", "throws", "mutating", "deinit", "typealias", "associatedtype"],
            common: ["struct", "enum", "self", "nil", "some", "any", "override", "convenience", "required", "lazy", "unowned", "indirect"]
        ) + (signals.uppercaseImportLines > 0 ? 2 : 0) + (signals.attributeCount > 0 ? 2 : 0) + (signals.arrowCount > 0 ? 2 : 0)
        let python = signals.score(
            strong: ["def", "elif", "lambda", "except", "nonlocal", "none"],
            common: ["self", "pass", "raise", "assert", "yield", "with", "print", "range", "len", "global", "async", "await", "true", "false"]
        ) + (signals.hashCommentLines > 0 ? 1 : 0) + (signals.indentedAfterColon ? 1 : 0)
        let shell = signals.score(
            strong: ["fi", "esac", "done", "then", "echo", "sudo", "chmod", "grep", "awk", "sed", "curl", "mkdir", "export", "local", "readonly", "unset", "source"],
            common: ["do", "case", "while", "if", "for", "exit", "function"]
        ) + (signals.dollarVariables > 0 ? 3 : 0)
        let typescript = signals.score(
            strong: ["interface", "implements", "declare", "namespace", "readonly"],
            common: ["type", "enum", "public", "private", "protected", "abstract"]
        ) + (signals.typeAnnotationCount > 0 ? 2 : 0)
        let javascript = signals.score(
            strong: ["function", "const", "async", "await", "typeof", "instanceof", "console", "require", "module", "exports", "undefined", "document", "window", "super", "extends"],
            common: ["let", "var", "return", "if", "else", "for", "while", "do", "switch", "case", "break", "continue", "try", "catch", "finally", "throw", "import", "export", "from", "of", "in", "true", "false", "null", "this", "class", "new", "delete", "void", "yield"]
        )

        var best: (language: CodeLanguage, score: Int, priority: Int) = (.generic, 0, 0)
        let candidates: [(CodeLanguage, Int, Int)] = [
            (.shell, shell, 5),
            (.python, python, 4),
            (.swift, swift, 3),
            (.typescript, typescript, 2),
            (.javascript, javascript, 1)
        ]
        for candidate in candidates {
            if candidate.1 > best.score || (candidate.1 == best.score && candidate.1 > 0 && candidate.2 > best.priority) {
                best = (candidate.0, candidate.1, candidate.2)
            }
        }
        return best.score > 0 ? best.language : .generic
    }
}

// MARK: - Signals

/// The counters one sample is judged by: code-specific signals ("strong"), signals
/// that only code shapes use ("shaped") and neutral layout signals ("neutral").
private struct Signals {
    let sample: String
    let wordCounts: [String: Int]
    let bracePairs: Int
    let semicolonLines: Int
    let indentationRuns: Int
    let indentedAfterColon: Bool
    let operatorKinds: Int
    let arrowCount: Int
    let attributeCount: Int
    let distinctiveKeywords: Int
    let codeCommentLines: Int
    let hashCommentLines: Int
    let dollarVariables: Int
    let assignmentLines: Int
    let tagCount: Int
    let closingTagCount: Int
    let tagNames: Set<String>
    let importLines: Int
    let uppercaseImportLines: Int
    let statementLines: Int
    let typeAnnotationCount: Int

    init(_ sample: String) {
        self.sample = sample
        let lines = sample.split(separator: "\n", omittingEmptySubsequences: false)
        let characters = Array(sample)

        var braceOpen = 0, braceClose = 0
        var dollarVariables = 0, tagCount = 0, closingTagCount = 0
        var arrowCount = 0, attributeCount = 0, typeAnnotations = 0
        var operatorKinds = Set<String>()
        var tagNames = Set<String>()
        var index = 0

        // One pass over the characters collects the symbol counters; the line pass
        // below collects the layout counters and the words.
        while index < characters.count {
            let character = characters[index]
            let characterBeforeIsWord = index > 0 && Self.isWordCharacter(characters[index - 1])
            switch character {
            case "{":
                braceOpen += 1
            case "}":
                braceClose += 1
            case "$":
                if let next = Self.character(after: index, in: characters),
                   Self.isIdentifierStart(next) || next == "{" || next.isNumber {
                    dollarVariables += 1
                }
            case "<":
                if !characterBeforeIsWord,
                   let next = Self.character(after: index, in: characters), next.isLetter,
                   let tag = Self.readTag(characters, at: index) {
                    tagCount += 1
                    if tag.isClosing { closingTagCount += 1 }
                    if let name = tag.name { tagNames.insert(name.lowercased()) }
                    index = tag.end - 1
                }
            case "@":
                if Self.isIdentifierStart(Self.character(after: index, in: characters)) {
                    attributeCount += 1
                }
            case ":":
                if Self.typeAnnotation(after: index, in: characters) { typeAnnotations += 1 }
            default:
                break
            }
            for literal in Self.operatorLiterals where Self.matches(characters, at: index, literal: literal) {
                operatorKinds.insert(literal)
                if literal == "->" || literal == "=>" { arrowCount += 1 }
            }
            index += 1
        }

        var words: [String] = []
        var semicolonLines = 0, indentationRuns = 0, codeCommentLines = 0
        var hashCommentLines = 0, importLines = 0, uppercaseImportLines = 0
        var statementLines = 0, assignmentLines = 0
        var indentedAfterColon = false
        for (offset, line) in lines.enumerated() {
            let trimmed = line.drop(while: { $0 == " " || $0 == "\t" })
            guard !trimmed.isEmpty else { continue }
            words.append(contentsOf: Self.words(in: line))
            if trimmed.contains(";") { semicolonLines += 1 }
            let isIndented = line.hasPrefix("\t") || line.hasPrefix("  ")
            if isIndented, offset > 0 { indentationRuns += 1 }
            if trimmed.hasPrefix("//") || trimmed.hasPrefix("/*") || trimmed.hasPrefix("<!--") {
                codeCommentLines += 1
            } else if trimmed.hasPrefix("#"), !Self.isPreprocessorLine(trimmed) {
                hashCommentLines += 1
            }
            if Self.isImportLine(trimmed) {
                importLines += 1
                if Self.isUppercaseImportLine(trimmed) { uppercaseImportLines += 1 }
            }
            if Self.containsAssignment(line) { assignmentLines += 1 }
            if trimmed.hasSuffix(":") {
                let next = lines.dropFirst(offset + 1).first { line in
                    !line.allSatisfy { $0 == " " || $0 == "\t" }
                }
                if let next, next.hasPrefix("\t") || next.hasPrefix("  ") { indentedAfterColon = true }
            }
            if Self.looksLikeStatement(trimmed, isIndented: isIndented) { statementLines += 1 }
        }

        self.wordCounts = words.reduce(into: [:]) { counts, word in counts[word, default: 0] += 1 }
        self.bracePairs = min(braceOpen, braceClose)
        self.operatorKinds = operatorKinds.count
        self.arrowCount = arrowCount
        self.attributeCount = attributeCount
        self.dollarVariables = dollarVariables
        self.tagCount = tagCount
        self.closingTagCount = closingTagCount
        self.tagNames = tagNames
        self.semicolonLines = semicolonLines
        self.indentationRuns = indentationRuns
        self.indentedAfterColon = indentedAfterColon
        self.codeCommentLines = codeCommentLines
        self.hashCommentLines = hashCommentLines
        self.importLines = importLines
        self.uppercaseImportLines = uppercaseImportLines
        self.statementLines = statementLines
        self.assignmentLines = assignmentLines
        self.typeAnnotationCount = typeAnnotations
        self.distinctiveKeywords = Set(words.filter(Self.distinctiveKeywordSet.contains)).count
    }

    var strong: Int {
        var score = 0
        switch distinctiveKeywords {
        case 0: break
        case 1: score += 1
        case 2: score += 2
        default: score += 3
        }
        switch bracePairs {
        case 0: break
        case 1: score += 1
        default: score += 2
        }
        switch operatorKinds {
        case 0: break
        case 1: score += 1
        case 2: score += 2
        default: score += 3
        }
        if codeCommentLines >= 1 { score += 2 }
        switch dollarVariables {
        case 0: break
        case 1: score += 2
        default: score += 3
        }
        switch tagCount {
        case 0, 1: break
        case 2, 3: score += 2
        default: score += 3
        }
        if importLines >= 1 { score += 2 }
        return score
    }

    var shaped: Int {
        var score = 0
        switch statementLines {
        case 0: break
        case 1: score += 2
        default: score += 3
        }
        if indentedAfterColon { score += 1 }
        if hashCommentLines >= 1 { score += 1 }
        if assignmentLines >= 1 { score += 1 }
        return score
    }

    var neutral: Int {
        var score = 0
        switch semicolonLines {
        case 0: break
        case 1: score += 1
        default: score += 2
        }
        switch indentationRuns {
        case 0: break
        case 1: score += 1
        default: score += 2
        }
        return score
    }

    /// Markup, when the sample reads as a document rather than a comparison: at least
    /// two tags, with a closing tag, a known element or a doctype to anchor them.
    var markupLanguage: CodeLanguage? {
        guard tagCount >= 2 else { return nil }
        if sample.contains("<?xml") { return .xml }
        let known = tagNames.contains { Self.htmlElements.contains($0) }
        guard closingTagCount >= 1 || known || sample.contains("<!DOCTYPE") else { return nil }
        return known || sample.contains("<!DOCTYPE") ? .html : .xml
    }

    func score(strong: Set<String>, common: Set<String>) -> Int {
        var score = 0
        for word in strong {
            let count = wordCounts[word] ?? 0
            if count > 0 { score += 3 + min(count - 1, 2) }
        }
        for word in common {
            let count = wordCounts[word] ?? 0
            if count > 0 { score += min(count, 2) }
        }
        return score
    }

    // MARK: - Character helpers

    private static let operatorLiterals = ["->", "=>", "==", "!=", "<=", ">=", "&&", "||", "+=", "-=", "*=", "/=", "%=", "??", "?.", "::", "++", "--", "|=", "|"]

    /// Keywords that essentially never appear in running prose, per language family.
    /// Words English uses too — "guard", "protocol", "source", "local", "done", "pub" —
    /// are deliberately absent: they still count when classifying a text the detector
    /// has already accepted, but never what makes it code.
    private static let distinctiveKeywordSet: Set<String> = [
        "func", "mutating", "deinit", "typealias", "associatedtype", "fileprivate", "rethrows",
        "struct", "enum",
        "def", "elif", "nonlocal", "lambda",
        "fi", "esac", "chmod", "grep", "awk", "sed", "mkdir", "readonly", "unset", "sudo", "echo",
        "const", "typeof", "instanceof", "namespace", "undefined", "async", "await",
        "typedef", "sizeof", "goto", "fn", "impl", "mut"
    ]

    /// Words that are keywords as the first token of a statement; the line shape then
    /// decides whether the line is code. Prose sentences keep their capitalised first
    /// word, which is what keeps "If you can, please" out of the code lines.
    private static let statementKeywords: Set<String> = [
        "if", "else", "elif", "for", "while", "repeat", "switch", "case", "default", "return", "break", "continue",
        "func", "def", "function", "class", "struct", "enum", "protocol", "extension", "interface", "impl",
        "import", "from", "use", "package", "using", "require",
        "let", "var", "const", "static", "final", "public", "private", "protected", "internal",
        "async", "await", "try", "catch", "finally", "throw", "throws", "defer", "guard", "yield",
        "lambda", "with", "raise", "assert", "pass", "global", "nonlocal",
        "print", "range", "len", "echo", "sudo", "export", "local", "source", "printf",
        "do", "then", "fi", "done", "esac"
    ]

    /// Elements that read as HTML rather than XML or a generic tag.
    private static let htmlElements: Set<String> = [
        "html", "head", "body", "div", "span", "p", "a", "img", "br", "ul", "ol", "li", "table", "tr", "td", "th",
        "h1", "h2", "h3", "h4", "h5", "h6", "button", "form", "input", "script", "style", "section", "article",
        "nav", "footer", "header", "meta", "link", "title", "strong", "em", "code", "pre", "blockquote", "main", "aside"
    ]

    private static let tsTypeWords: Set<String> = [
        "string", "number", "boolean", "void", "any", "unknown", "never", "object", "int", "double", "float", "bool"
    ]

    static func isIdentifierStart(_ character: Character?) -> Bool {
        guard let character else { return false }
        return character.isLetter || character == "_" || character == "$"
    }

    static func isWordCharacter(_ character: Character) -> Bool {
        character.isLetter || character.isNumber || character == "_"
    }

    static func character(after index: Int, in characters: [Character]) -> Character? {
        index + 1 < characters.count ? characters[index + 1] : nil
    }

    static func readWord(_ characters: [Character], at start: Int) -> String {
        var word = String()
        var index = start
        while index < characters.count, isWordCharacter(characters[index]) {
            word.append(characters[index])
            index += 1
        }
        return word
    }

    static func matches(_ characters: [Character], at index: Int, literal: String) -> Bool {
        var cursor = index
        for expected in literal {
            guard cursor < characters.count, characters[cursor] == expected else { return false }
            cursor += 1
        }
        return true
    }

    /// `target: Type` annotations with a lowercase target, the shape that tells
    /// TypeScript from JavaScript without tripping over "Note: The …".
    static func typeAnnotation(after index: Int, in characters: [Character]) -> Bool {
        var cursor = index + 1
        while cursor < characters.count, characters[cursor] == " " { cursor += 1 }
        guard let first = character(after: cursor, in: characters), first.isLetter else { return false }
        let raw = readWord(characters, at: cursor)
        guard tsTypeWords.contains(raw.lowercased()) || raw.first?.isUppercase == true else { return false }
        var target = index - 1
        while target >= 0, characters[target] == " " { target -= 1 }
        guard target >= 0, isWordCharacter(characters[target]) else { return false }
        while target >= 0, isWordCharacter(characters[target - 1]) { target -= 1 }
        return characters[target].isLowercase || characters[target] == "_"
    }

    /// One tag, from `<` to the closing `>`, with its name and whether it closes another.
    static func readTag(_ characters: [Character], at start: Int) -> (end: Int, name: String?, isClosing: Bool)? {
        var cursor = start + 1
        var isClosing = false
        if cursor < characters.count, characters[cursor] == "/" {
            isClosing = true
            cursor += 1
        }
        var name = String()
        while cursor < characters.count, characters[cursor].isLetter || characters[cursor].isNumber || characters[cursor] == "-" || characters[cursor] == ":" || characters[cursor] == "." {
            name.append(characters[cursor])
            cursor += 1
        }
        guard !name.isEmpty else { return nil }
        guard cursor >= characters.count
            || characters[cursor] == " " || characters[cursor] == "\t" || characters[cursor] == "\n"
            || characters[cursor] == ">" || characters[cursor] == "/"
        else { return nil }
        while cursor < characters.count, characters[cursor] != ">" {
            if characters[cursor] == "\"" || characters[cursor] == "'" {
                let quote = characters[cursor]
                cursor += 1
                while cursor < characters.count, characters[cursor] != quote, characters[cursor] != "\n" { cursor += 1 }
            }
            cursor += 1
        }
        guard cursor < characters.count else { return nil }
        return (cursor + 1, name, isClosing)
    }

    static func words(in line: Substring) -> [String] {
        var words: [String] = []
        var word = String()
        for character in line {
            if isWordCharacter(character) {
                word.append(character)
            } else if !word.isEmpty {
                words.append(word.lowercased())
                word = ""
            }
        }
        if !word.isEmpty { words.append(word.lowercased()) }
        return words
    }

    static func isPreprocessorLine(_ trimmed: Substring) -> Bool {
        trimmed.hasPrefix("#!") || trimmed.hasPrefix("#include") || trimmed.hasPrefix("#import")
            || trimmed.hasPrefix("#define") || trimmed.hasPrefix("#pragma")
    }

    static func isImportLine(_ trimmed: Substring) -> Bool {
        if trimmed.hasPrefix("#include") || trimmed.hasPrefix("#import") { return true }
        guard let first = trimmed.split(whereSeparator: { $0 == " " || $0 == "\t" }).first else { return false }
        return ["import", "from", "using", "package", "use"].contains(String(first))
    }

    /// `import Foundation`: a capitalised module name with no `from` clause, the shape
    /// Swift uses and JavaScript's `import React from "react"` does not.
    static func isUppercaseImportLine(_ trimmed: Substring) -> Bool {
        guard trimmed.hasPrefix("import") else { return false }
        let tokens = trimmed.split(whereSeparator: { $0 == " " || $0 == "\t" })
        guard tokens.count >= 2, let first = tokens[1].first, first.isUppercase else { return false }
        return !tokens.contains("from")
    }

    /// A statement-shaped line: it opens with a lowercase keyword and carries code
    /// punctuation or is indented.
    static func looksLikeStatement(_ trimmed: Substring, isIndented: Bool) -> Bool {
        guard let first = trimmed.split(whereSeparator: { $0 == " " || $0 == "\t" }).first,
              statementKeywords.contains(String(first))
        else { return false }
        if isIndented { return true }
        return trimmed.contains("(") || trimmed.contains("=") || trimmed.contains("{")
            || trimmed.contains(":") || trimmed.contains("[") || trimmed.hasSuffix(";")
    }

    /// `x = value` without `==`, `<=`, `+=` and friends, with or without spaces.
    static func containsAssignment(_ line: Substring) -> Bool {
        let characters = Array(line)
        for index in characters.indices where characters[index] == "=" {
            var before = index - 1
            while before >= 0, characters[before] == " " || characters[before] == "\t" { before -= 1 }
            guard before >= 0, isWordCharacter(characters[before]) else { continue }
            var after = index + 1
            while after < characters.count, characters[after] == " " || characters[after] == "\t" { after += 1 }
            guard after < characters.count, characters[after] != "=" else { continue }
            return true
        }
        return false
    }
}
