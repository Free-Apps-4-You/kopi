import Foundation
import Testing

@testable import KopiCore

@Suite("Rich text")
struct RichTextTests {
    @Test("HTML escapes markup and keeps formatting")
    func htmlEncoding() {
        let document = RichTextDocument(runs: [
            RichTextDocument.Run(text: "a < b && c > d", traits: .bold),
            RichTextDocument.Run(text: " \"quoted\""),
            RichTextDocument.Run(text: " link", linkURL: URL(string: "https://example.com/x?a=1&b=2"))
        ])
        let html = document.html()

        #expect(html.hasPrefix("<!DOCTYPE html>"))
        #expect(html.contains("a &lt; b &amp;&amp; c &gt; d"))
        #expect(html.contains("&quot;quoted&quot;"))
        #expect(html.contains("font-weight:600"))
        #expect(html.contains(#"href="https://example.com/x?a=1&amp;b=2""#))
        #expect(document.plainText == "a < b && c > d \"quoted\" link")
    }

    @Test("Multi-line documents become paragraphs")
    func paragraphEncoding() {
        let document = RichTextDocument(plainText: "first line\nsecond line\n")
        let html = document.html()
        #expect(html.contains("<p>first line</p>"))
        #expect(html.contains("<p>second line</p>"))
        #expect(html.contains("<p><br></p>"))
    }

    @Test("RTF escapes control characters and non-ASCII")
    func rtfEncoding() {
        let document = RichTextDocument(plainText: "a {b} \\ c\nsecond")
        let rtf = String(decoding: document.rtf(), as: UTF8.self)

        #expect(rtf.hasPrefix(#"{\rtf1\ansi"#))
        #expect(rtf.contains(#"a \{b\} \\ c"#))
        #expect(rtf.contains(#"\par"#))
        #expect(rtf.hasSuffix("}"))

        let unicode = RichTextDocument(plainText: "café 😀")
        let unicodeRTF = String(decoding: unicode.rtf(), as: UTF8.self)
        #expect(unicodeRTF.contains("\\u233?"))
        #expect(unicodeRTF.contains("\\u-10179?"))
    }

    @Test("Editing rich text rebuilds its HTML and RTF flavours")
    func editingRebuildsRepresentations() async throws {
        let workspace = try TempWorkspace()
        try await workspace.store.beginSession()
        let inserted = try await workspace.store.insert(richTextInsertion("Original heading"))

        let initial = try #require(await workspace.store.detail(for: inserted.itemID))
        let initialHTML = try #require(initial.representation(.html)?.text)
        #expect(initialHTML.contains("Original heading"))

        _ = try await workspace.store.edit(.text("Updated heading"), for: inserted.itemID)

        let updated = try #require(await workspace.store.detail(for: inserted.itemID))
        #expect(updated.representation(.plainText)?.text == "Updated heading")
        let html = try #require(updated.representation(.html)?.text)
        let rtfData = try #require(updated.representation(.rtf)?.data)
        let rtf = String(decoding: rtfData, as: UTF8.self)
        #expect(html.contains("Updated heading"))
        #expect(!html.contains("Original heading"))
        #expect(rtf.contains("Updated heading"))
        #expect(!rtf.contains("Original heading"))
        #expect(updated.representations.count == 3)
    }

    @Test("Editing a link rebuilds its flavours around the new URL")
    func editingLink() async throws {
        let workspace = try TempWorkspace()
        try await workspace.store.beginSession()
        let inserted = try await workspace.store.insert(linkInsertion("https://example.com/old"))

        _ = try await workspace.store.edit(
            .link(URL(string: "https://example.com/new?x=1")!, label: "New target"),
            for: inserted.itemID
        )

        let detail = try #require(await workspace.store.detail(for: inserted.itemID))
        #expect(detail.representation(.link)?.text == "https://example.com/new?x=1")
        #expect(detail.plainText == "New target")
        #expect(detail.summary.primaryURL?.absoluteString == "https://example.com/new?x=1")
        let html = try #require(detail.representation(.html)?.text)
        #expect(html.contains("https://example.com/new?x=1"))
        #expect(detail.plainText != "https://example.com/old")
    }

    @Test("Label edits leave image content and fingerprints untouched")
    func labelEditsKeepImageContent() async throws {
        let workspace = try TempWorkspace()
        try await workspace.store.beginSession()
        let asset = try await workspace.assetStore.importData(Data(repeating: 1, count: 128), kind: .image, fileExtension: "png")
        let inserted = try await workspace.store.insert(imageInsertion(asset: asset.reference, label: "Raw capture"))
        let before = try #require(await workspace.store.detail(for: inserted.itemID))

        let edited = try await workspace.store.edit(.label("Product screenshot"), for: inserted.itemID)

        let after = try #require(await workspace.store.detail(for: inserted.itemID))
        #expect(edited.label == "Product screenshot")
        #expect(edited.fingerprint == before.summary.fingerprint)
        #expect(after.representations.map(\.contentHash) == before.representations.map(\.contentHash))
        #expect(after.assets.map(\.id) == before.assets.map(\.id))
        #expect(after.searchText.contains("Product screenshot"))

        var thrown: (any Error)?
        do {
            _ = try await workspace.store.edit(.text("not allowed"), for: inserted.itemID)
        } catch {
            thrown = error
        }
        #expect(thrown as? HistoryStoreError == .contentNotEditable(.image))
    }

    @Test("Label edits leave file references untouched")
    func labelEditsKeepFileReferences() async throws {
        let workspace = try TempWorkspace()
        try await workspace.store.beginSession()
        let file = try workspace.writeFile("Invoice.pdf", contents: "pdf bytes")
        let inserted = try await workspace.store.insert(fileInsertion([file]))
        _ = try await workspace.store.setPinned(true, for: inserted.itemID)
        let before = try #require(await workspace.store.detail(for: inserted.itemID))

        _ = try await workspace.store.edit(.label("March invoice"), for: inserted.itemID)

        let after = try #require(await workspace.store.detail(for: inserted.itemID))
        #expect(after.summary.label == "March invoice")
        #expect(after.summary.fingerprint == before.summary.fingerprint)
        #expect(after.fileReferences.map(\.path) == before.fileReferences.map(\.path))
        #expect(after.fileReferences.map(\.snapshot?.id) == before.fileReferences.map(\.snapshot?.id))
        #expect(after.fileSnapshots.count == 1)
    }
}
