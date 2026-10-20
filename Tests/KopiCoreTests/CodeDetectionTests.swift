import Foundation
import Testing

@testable import KopiCore

@Suite("Code detection")
struct CodeDetectionTests {
    private let detector = CodeDetector()

    // MARK: - Languages

    @Test("A Swift snippet is detected as Swift")
    func swiftSnippet() throws {
        let text = """
        func add(_ a: Int, _ b: Int) -> Int {
            return a + b
        }
        """
        #expect(detector.detect(text) == .swift)
    }

    @Test("A JavaScript snippet is detected as JavaScript")
    func javascriptSnippet() throws {
        let text = """
        const greet = (name) => {
          return `Hello, ${name}!`
        }
        """
        #expect(detector.detect(text) == .javascript)
    }

    @Test("A TypeScript snippet is detected as TypeScript")
    func typescriptSnippet() throws {
        let text = """
        interface User {
          name: string;
          age: number;
        }

        function greet(user: User): string {
          return `Hello, ${user.name}`;
        }
        """
        #expect(detector.detect(text) == .typescript)
    }

    @Test("A Python snippet is detected as Python")
    func pythonSnippet() throws {
        let text = """
        def add(a, b):
            return a + b
        """
        #expect(detector.detect(text) == .python)
    }

    @Test("A Python loop without comments is still code")
    func pythonLoop() throws {
        let text = """
        for item in items:
            print(item)
        """
        #expect(detector.detect(text) == .python)
    }

    @Test("A JSON object and a JSON array are JSON")
    func jsonDocuments() throws {
        #expect(detector.detect(#"{"name": "Kopi", "count": 3}"#) == .json)
        #expect(detector.detect(#"[{"id": 1}, {"id": 2}]"#) == .json)
        #expect(detector.detect("{\n  \"pinned\": true,\n  \"items\": []\n}") == .json)
    }

    @Test("A shell script is detected from its shebang")
    func shellScript() throws {
        let text = """
        #!/bin/bash
        set -euo pipefail
        for file in "$@"; do
          echo "$file"
        done
        """
        #expect(detector.detect(text) == .shell)
    }

    @Test("Shell commands without a shebang are detected too")
    func shellCommands() throws {
        let text = """
        echo "Removing old builds"
        export PATH="$PATH:/usr/local/bin"
        sudo rm -rf ./build
        """
        #expect(detector.detect(text) == .shell)
    }

    @Test("HTML with elements is detected as HTML")
    func htmlSnippet() throws {
        let text = #"<div class="card"><span>Hello</span></div>"#
        #expect(detector.detect(text) == .html)
    }

    @Test("An XML document is detected as XML")
    func xmlDocument() throws {
        let text = #"<?xml version="1.0" encoding="UTF-8"?><catalog><book id="1"/></catalog>"#
        #expect(detector.detect(text) == .xml)
    }

    @Test("A Swift import list is code only with an editor hint")
    func uppercaseImports() throws {
        let text = """
        import Foundation
        import SwiftUI
        """
        #expect(detector.detect(text) == nil)
        let xcode = SourceAppInfo(bundleIdentifier: "com.apple.dt.Xcode", name: "Xcode")
        #expect(detector.detect(text, sourceApp: xcode) == .swift)
    }

    // MARK: - False positives

    @Test("Prose is never detected")
    func prose() throws {
        let text = """
        The quick brown fox jumps over the lazy dog. It was a dark and stormy night; the rain fell in
        torrents. Every sentence has a comma, a semicolon or a full stop, and none of it is code.
        """
        #expect(detector.detect(text) == nil)
    }

    @Test("A bullet list with semicolons is not code")
    func bulletList() throws {
        let text = """
        Steps:
          - buy milk;
          - buy eggs;
          - buy bread;
        """
        #expect(detector.detect(text) == nil)
    }

    @Test("URL fragments are not code")
    func urls() throws {
        #expect(detector.detect("https://example.com/docs?page=2&mode=edit#section") == nil)
        #expect(detector.detect("https://example.com/kopi?tab=clipboard&page=2") == nil)
    }

    @Test("Prose with parentheses, braces or semicolons stays prose")
    func prosePunctuation() throws {
        #expect(detector.detect("Use {braces} sparingly; they are rarely needed in writing.") == nil)
        #expect(detector.detect("If you can, please; otherwise, wait for the others (they are late).") == nil)
        #expect(detector.detect("The Committee (UK) met; the minutes are attached.") == nil)
    }

    @Test("Email addresses and plain numbers are not code")
    func contactDetails() throws {
        #expect(detector.detect("john.doe@example.com") == nil)
        #expect(detector.detect("3.14 and 1-800-555-0199") == nil)
    }

    @Test("A hash heading and an indented list is not code")
    func markdownHeading() throws {
        let text = """
        # Notes
          - first item
          - second item
        """
        #expect(detector.detect(text) == nil)
    }

    @Test("A prose paragraph copied from an editor is still not code")
    func editorHintProse() throws {
        let text = """
        The detector is deliberately conservative, because a card that is styled as code when it is
        not is worse than a code fragment that stays plain.
        """
        let editor = SourceAppInfo(bundleIdentifier: "com.apple.dt.Xcode", name: "Xcode")
        #expect(detector.detect(text, sourceApp: editor) == nil)
    }

    @Test("Only editors and terminals count as hints")
    func hintSourceApps() {
        #expect(CodeDetector.hasSourceHint(SourceAppInfo(bundleIdentifier: "com.apple.dt.Xcode")))
        #expect(CodeDetector.hasSourceHint(SourceAppInfo(bundleIdentifier: "com.apple.Terminal")))
        #expect(CodeDetector.hasSourceHint(SourceAppInfo(bundleIdentifier: "com.jetbrains.intellij")))
        #expect(!CodeDetector.hasSourceHint(SourceAppInfo(bundleIdentifier: "com.apple.Safari")))
        #expect(!CodeDetector.hasSourceHint(SourceAppInfo(bundleIdentifier: nil)))
    }

    @Test("Short fragments stay plain")
    func shortFragments() throws {
        #expect(detector.detect("x") == nil)
        #expect(detector.detect("{}") == .json)
        #expect(detector.detect("let") == nil)
    }

    @Test("The analysis is bounded to the first characters")
    func boundedAnalysis() throws {
        let longProse = String(repeating: "A sentence of prose; another sentence follows. ", count: 200)
        #expect(longProse.count > CodeDetector.maximumAnalyzedLength)
        #expect(detector.detect(longProse) == nil)
    }
}
