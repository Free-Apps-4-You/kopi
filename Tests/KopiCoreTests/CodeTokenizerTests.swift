import Foundation
import Testing

@testable import KopiCore

@Suite("Code tokenizing")
struct CodeTokenizerTests {
    // MARK: - Per-language classes

    @Test("Swift keywords, numbers and comments are classified")
    func swiftTokens() throws {
        let text = "let total = 42 // answer"
        let tokens = CodeTokenizer.tokens(in: text, language: .swift)
        #expect(tokenClass(containing: "let", in: text, tokens) == .keyword)
        #expect(tokenClass(containing: "42", in: text, tokens) == .number)
        #expect(tokenClass(containing: "// answer", in: text, tokens) == .comment)
        #expect(tokenClass(containing: "total", in: text, tokens) == .plain)
    }

    @Test("Swift strings, property wrappers and type names are classified")
    func swiftStringsAndTypes() throws {
        let text = "@State private var title: String = \"Hello\""
        let tokens = CodeTokenizer.tokens(in: text, language: .swift)
        #expect(tokenClass(containing: "@", in: text, tokens) == .plain)
        #expect(tokenClass(containing: "State", in: text, tokens) == .type)
        #expect(tokenClass(containing: "private", in: text, tokens) == .keyword)
        #expect(tokenClass(containing: "String", in: text, tokens) == .type)
        #expect(tokenClass(containing: "\"Hello\"", in: text, tokens) == .string)
    }

    @Test("JavaScript keywords, strings and arrow tokens are classified")
    func javascriptTokens() throws {
        let text = "const greet = (name) => `Hi ${name}`"
        let tokens = CodeTokenizer.tokens(in: text, language: .javascript)
        #expect(tokenClass(containing: "const", in: text, tokens) == .keyword)
        #expect(tokenClass(containing: "`Hi ${name}`", in: text, tokens) == .string)
        #expect(tokenClass(containing: "greet", in: text, tokens) == .plain)
    }

    @Test("TypeScript interfaces and literal types are keywords")
    func typescriptTokens() throws {
        let text = "interface User { name: string }"
        let tokens = CodeTokenizer.tokens(in: text, language: .typescript)
        #expect(tokenClass(containing: "interface", in: text, tokens) == .keyword)
        #expect(tokenClass(containing: "string", in: text, tokens) == .keyword)
        #expect(tokenClass(containing: "User", in: text, tokens) == .type)
    }

    @Test("Python keywords and comments are classified")
    func pythonTokens() throws {
        let text = "def greet(name):  # say hi\n    return f\"Hello {name}\""
        let tokens = CodeTokenizer.tokens(in: text, language: .python)
        #expect(tokenClass(containing: "def", in: text, tokens) == .keyword)
        #expect(tokenClass(containing: "# say hi", in: text, tokens) == .comment)
        #expect(tokenClass(containing: "return", in: text, tokens) == .keyword)
        #expect(tokenClass(containing: "\"Hello {name}\"", in: text, tokens) == .string)
    }

    @Test("Python triple-quoted strings may run over lines")
    func pythonTripleQuoted() throws {
        let text = "note = \"\"\"first line\nsecond line\"\"\""
        let tokens = CodeTokenizer.tokens(in: text, language: .python)
        #expect(tokenClass(containing: "\"\"\"first line\nsecond line\"\"\"", in: text, tokens) == .string)
    }

    @Test("JSON strings, literals and numbers are classified")
    func jsonTokens() throws {
        let text = #"{"count": 3.5, "pinned": true, "label": null}"#
        let tokens = CodeTokenizer.tokens(in: text, language: .json)
        #expect(tokenClass(containing: #""count""#, in: text, tokens) == .string)
        #expect(tokenClass(containing: "3.5", in: text, tokens) == .number)
        #expect(tokenClass(containing: "true", in: text, tokens) == .keyword)
        #expect(tokenClass(containing: "null", in: text, tokens) == .keyword)
        #expect(tokenClass(containing: ":", in: text, tokens) == .plain)
    }

    @Test("Shell variables are types and commands are keywords")
    func shellTokens() throws {
        let text = "echo $HOME > ${OUTPUT_DIR}/log"
        let tokens = CodeTokenizer.tokens(in: text, language: .shell)
        #expect(tokenClass(containing: "echo", in: text, tokens) == .keyword)
        #expect(tokenClass(containing: "$HOME", in: text, tokens) == .type)
        #expect(tokenClass(containing: "${OUTPUT_DIR}", in: text, tokens) == .type)
    }

    @Test("HTML element names, attributes and text are classified")
    func htmlTokens() throws {
        let text = #"<div class="card"><span>Hello</span></div>"#
        let tokens = CodeTokenizer.tokens(in: text, language: .html)
        #expect(tokenClass(containing: "div", in: text, tokens) == .type)
        #expect(tokenClass(containing: "\"card\"", in: text, tokens) == .string)
        #expect(tokenClass(containing: "class", in: text, tokens) == .plain)
        #expect(tokenClass(containing: "Hello", in: text, tokens) == .plain)
    }

    @Test("HTML comments and doctypes are comments")
    func htmlComments() throws {
        let comment = "<!-- a note -->"
        let tokens = CodeTokenizer.tokens(in: comment, language: .html)
        #expect(tokenClass(containing: comment, in: comment, tokens) == .comment)

        let document = "<!DOCTYPE html><html></html>"
        let documentTokens = CodeTokenizer.tokens(in: document, language: .html)
        #expect(tokenClass(containing: "<!DOCTYPE html>", in: document, documentTokens) == .comment)
    }

    @Test("A closing tag straight after text is still a tag")
    func htmlClosingTagAfterText() throws {
        let text = "<p>Hello</p>"
        let tokens = CodeTokenizer.tokens(in: text, language: .html)
        let tags = tokens.filter { $0.tokenClass == .type }.map { substring(of: $0, in: text) }
        #expect(tags == ["p", "p"])
    }

    @Test("Every language's tokens cover its text without gaps")
    func coverageAcrossLanguages() throws {
        let samples: [(String, CodeLanguage)] = [
            ("let value = 1 // note", .swift),
            ("const value = { key: 1 };", .javascript),
            ("interface User { name: string }", .typescript),
            ("def f(x):\n    return x", .python),
            (#"{"key": [1, 2.5, true]}"#, .json),
            (#"echo "$HOME" > out.txt"#, .shell),
            (#"<div class="card">Hi</div>"#, .html),
            (#"<?xml version="1.0"?><root><item/></root>"#, .xml),
            ("value = compute(3) /* block */", .generic)
        ]
        for (text, language) in samples {
            assertCoverage(text, CodeTokenizer.tokens(in: text, language: language))
        }
    }

    @Test("Generic code still colours strings, comments and numbers")
    func genericTokens() throws {
        let text = "value = compute(3) // check"
        let tokens = CodeTokenizer.tokens(in: text, language: .generic)
        #expect(tokenClass(containing: "3", in: text, tokens) == .number)
        #expect(tokenClass(containing: "// check", in: text, tokens) == .comment)
    }

    // MARK: - Edge cases

    @Test("An unterminated string stops at the line break")
    func unterminatedString() throws {
        let text = "let s = \"oops\nlet t = 2"
        let tokens = CodeTokenizer.tokens(in: text, language: .swift)
        #expect(tokenClass(containing: "\"oops", in: text, tokens) == .string)
        #expect(tokens.filter { $0.tokenClass == .keyword }.map(\.range) == [0..<3, 14..<17])
        #expect(tokenClass(containing: "2", in: text, tokens) == .number)
    }

    @Test("An unterminated block comment runs to the end")
    func unterminatedBlockComment() throws {
        let text = "let x = 1\n/* open comment"
        let tokens = CodeTokenizer.tokens(in: text, language: .swift)
        #expect(tokenClass(containing: "/* open comment", in: text, tokens) == .comment)
        #expect(tokenClass(containing: "1", in: text, tokens) == .number)
    }

    @Test("A lone trailing comment is classified to the end")
    func trailingComment() throws {
        let text = "// just a note"
        let tokens = CodeTokenizer.tokens(in: text, language: .swift)
        #expect(tokenClass(containing: "// just a note", in: text, tokens) == .comment)
    }

    @Test("An unterminated JSON string stops at the line break")
    func unterminatedJSONString() throws {
        let text = "{\n  \"broken\": \"value\n}"
        let tokens = CodeTokenizer.tokens(in: text, language: .json)
        #expect(tokenClass(containing: "\"broken\"", in: text, tokens) == .string)
        #expect(tokenClass(containing: "\"value", in: text, tokens) == .string)
    }

    @Test("A stray quote in prose-like content cannot swallow the rest")
    func strayQuote() throws {
        let text = "It's fine\nnumbers: 3 and 4"
        let tokens = CodeTokenizer.tokens(in: text, language: .swift)
        #expect(tokenClass(containing: "'s fine", in: text, tokens) != .string)
        #expect(tokenClass(containing: "3", in: text, tokens) == .number)
    }

    @Test("Tokens cover the analysed prefix without gaps or overlaps")
    func coverage() throws {
        let text = #"func f() { let url = "https://example.com/a" } // done"#
        assertCoverage(text, CodeTokenizer.tokens(in: text, language: .swift))
    }

    @Test("Tokenizing is deterministic")
    func determinism() throws {
        let text = "const value = { key: \"value\" }; // note 4"
        let first = CodeTokenizer.tokens(in: text, language: .javascript)
        let second = CodeTokenizer.tokens(in: text, language: .javascript)
        #expect(first == second)
    }

    @Test("Highlighting is capped to the bounded prefix")
    func cappedLength() throws {
        let text = String(repeating: "let value = 1234\n", count: 500)
        let highlight = CodeTokenizer.highlight(text, language: .swift)
        #expect(highlight.length == CodeTokenizer.maximumHighlightedCharacterCount)
        #expect(highlight.tokens.allSatisfy { $0.range.upperBound <= highlight.length })
        #expect(highlight.tokens.last?.tokenClass == .plain)
        assertCoverage(String(text.prefix(CodeTokenizer.maximumHighlightedCharacterCount)), highlight.tokens)
    }

    @Test("Multi-byte characters keep their UTF-16 offsets")
    func unicodeOffsets() throws {
        let text = "let emoji = \"🙂🙂\" // done"
        let tokens = CodeTokenizer.tokens(in: text, language: .swift)
        assertCoverage(text, tokens)
        #expect(tokenClass(containing: "\"🙂🙂\"", in: text, tokens) == .string)
        #expect(tokenClass(containing: "// done", in: text, tokens) == .comment)
    }

    // MARK: - Helpers

    private func tokenClass(
        containing substring: String,
        in text: String,
        _ tokens: [CodeToken]
    ) -> CodeTokenClass? {
        let range = (text as NSString).range(of: substring)
        guard range.location != NSNotFound else { return nil }
        return tokens
            .first { $0.range.lowerBound <= range.location && range.location + range.length <= $0.range.upperBound }?
            .tokenClass
    }

    private func substring(of token: CodeToken, in text: String) -> String {
        (text as NSString).substring(with: NSRange(location: token.range.lowerBound, length: token.range.count))
    }

    private func assertCoverage(_ text: String, _ tokens: [CodeToken], sourceLocation: SourceLocation = #_sourceLocation) {
        var cursor = 0
        for token in tokens {
            #expect(token.range.lowerBound == cursor, "gap or overlap before \(token)", sourceLocation: sourceLocation)
            cursor = token.range.upperBound
        }
        #expect(cursor == text.utf16.count, "tokens should cover the analysed prefix", sourceLocation: sourceLocation)
    }
}
