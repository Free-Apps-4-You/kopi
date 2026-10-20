import Foundation
import Testing

@testable import KopiCore

@Suite("Code highlight service")
struct CodeHighlightServiceTests {
    @Test("The service highlights code and leaves prose alone")
    func detectsAndHighlights() async throws {
        let service = CodeHighlightService()
        let highlight = await service.highlight(text: "let total = 42 // answer", sourceApp: nil)
        let result = try #require(highlight)
        #expect(result.language == .swift || result.language == .javascript)
        #expect(result.tokens.contains { $0.tokenClass == .keyword })
        #expect(result.tokens.contains { $0.tokenClass == .number })
        #expect(result.tokens.contains { $0.tokenClass == .comment })

        let prose = await service.highlight(text: "A plain sentence, with a comma and a full stop.")
        #expect(prose == nil)
    }

    @Test("Repeated requests for the same content share one cache entry")
    func cachesByContent() async throws {
        let service = CodeHighlightService()
        let text = "const value = 1;"
        _ = await service.highlight(text: text)
        _ = await service.highlight(text: text)
        #expect(await service.cachedEntryCount == 1)

        _ = await service.highlight(text: "const other = 2;")
        #expect(await service.cachedEntryCount == 2)
    }

    @Test("Prose outcomes are cached too, so scrolling does not re-detect")
    func cachesNegativeResults() async throws {
        let service = CodeHighlightService()
        let text = "The quick brown fox jumps over the lazy dog."
        _ = await service.highlight(text: text)
        _ = await service.highlight(text: text)
        #expect(await service.cachedEntryCount == 1)
    }

    @Test("The source app is part of the cache key, because it changes the outcome")
    func sourceAppIsPartOfTheKey() async throws {
        let service = CodeHighlightService()
        let text = "import Foundation\nimport SwiftUI"
        let withoutHint = await service.highlight(text: text)
        #expect(withoutHint == nil)

        let editor = SourceAppInfo(bundleIdentifier: "com.apple.dt.Xcode", name: "Xcode")
        let withHint = await service.highlight(text: text, sourceApp: editor)
        #expect(withHint?.language == .swift)
        #expect(await service.cachedEntryCount == 2)
    }

    @Test("The cache is bounded")
    func cacheIsBounded() async throws {
        let service = CodeHighlightService(cacheLimit: 3)
        for index in 0..<6 {
            _ = await service.highlight(text: "const value\(index) = \(index);")
        }
        #expect(await service.cachedEntryCount == 3)
    }
}
