import AppKit
import Testing
@testable import Kopi
@testable import KopiCore

@Suite("Native rich formatting")
@MainActor
struct RichFormattingTests {
    private func tableDocument() -> RichTextDocument {
        let editor = FormattingTextView()
        editor.insertTable()
        return RichTextCoding.document(from: editor.attributedString())
    }

    @Test("Tables survive native encoding, persistence, copying and reopening a plain clip")
    func tableRoundTrip() async throws {
        let document = tableDocument()
        #expect(document.html().contains("<table"))
        let harness = try await CaptureHarness()
        let workspace = harness.workspace
        try await workspace.store.beginSession()
        let inserted = try await workspace.store.insert(textInsertion("Original text"))
        _ = try await workspace.store.edit(ClipboardItemEdit(richText: document), for: inserted.itemID)
        let detail = try #require(await workspace.store.detail(for: inserted.itemID))
        #expect(detail.summary.kind == .richText)
        #expect(detail.id == inserted.itemID)
        #expect(detail.plainText?.contains("Cell") == true)
        let rtf = try #require(detail.representation(.rtf)?.data)
        let reopened = try #require(RichTextCoding.document(fromRTF: rtf))
        let attributed = RichTextCoding.attributedString(from: reopened)
        let style = try #require(attributed.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle)
        let cell = try #require(style.textBlocks.first as? NSTextTableBlock)
        #expect(cell.table.numberOfColumns == 2)
        let request = try await harness.service.writeRequest(for: inserted.itemID)
        #expect(request.flavours.contains { $0.type == ClipboardRepresentationKind.rtf.pasteboardType })
        #expect(request.flavours.contains { $0.type == ClipboardRepresentationKind.html.pasteboardType })
    }

    @Test("Notes HTML tables are rendered as native cells and copied with rich flavours")
    func htmlTableCopy() async throws {
        let html = "<h1>Shopping</h1><table border='1'><tr><th>Item</th><th>Count</th></tr><tr><td>Apples</td><td>3</td></tr></table><ul><li>Buy fresh</li></ul>"
        let document = try #require(RichTextCoding.document(fromHTML: html))
        let native = RichTextCoding.attributedString(from: document)
        var foundCell = false
        native.enumerateAttribute(.paragraphStyle, in: NSRange(location: 0, length: native.length)) { value, _, _ in
            if (value as? NSParagraphStyle)?.textBlocks.contains(where: { $0 is NSTextTableBlock }) == true { foundCell = true }
        }
        #expect(foundCell)
        #expect(document.plainText.contains("Apples"))
        let harness = try await CaptureHarness()
        _ = try await harness.service.copyRichTextToPasteboard(document)
        let snapshot = try harness.pasteboard.readSnapshot()
        #expect(snapshot.string(for: ClipboardRepresentationKind.html.pasteboardType)?.contains("<table") == true)
        #expect(snapshot.data(for: ClipboardRepresentationKind.rtf.pasteboardType) != nil)
    }

    @Test("Styles beyond inline traits survive serialization")
    func paragraphStylesRoundTrip() throws {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.textLists = [NSTextList(markerFormat: .decimal, options: 0)]
        let source = NSAttributedString(string: "Heading\nItem", attributes: [
            .font: NSFont.boldSystemFont(ofSize: 24),
            .foregroundColor: NSColor.red,
            .strikethroughStyle: 1,
            .paragraphStyle: paragraph
        ])
        let document = RichTextCoding.document(from: source)
        let decoded = try JSONDecoder().decode(RichTextDocument.self, from: JSONEncoder().encode(document))
        let restored = RichTextCoding.attributedString(from: decoded)
        #expect((restored.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)?.pointSize == 24)
        #expect((restored.attribute(.strikethroughStyle, at: 0, effectiveRange: nil) as? NSNumber)?.intValue == 1)
        let style = try #require(restored.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle)
        #expect(style.alignment == .center)
        #expect(style.textLists.count == 1)
    }

    @Test("Editing runs invalidates archived formatting instead of copying stale content")
    func mutationInvalidatesArchives() {
        var document = tableDocument()
        document.runs = [RichTextDocument.Run(text: "Replacement")]
        #expect(document.preservedRTF == nil)
        #expect(document.preservedHTML == nil)
        #expect(!document.html().contains("Cell"))
    }

    @Test("Lists continue, exit empty items and toggle without losing inline formatting")
    func listEditing() throws {
        let view = FormattingTextView()
        view.isRichText = true
        view.textStorage?.setAttributedString(NSAttributedString(string: "First", attributes: [.font: NSFont.boldSystemFont(ofSize: 18)]))
        #expect((view.textStorage?.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)?.pointSize == 18)
        view.bulletList()
        #expect((view.textStorage?.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)?.pointSize == 18)
        #expect(view.string.contains("•"))
        view.setSelectedRange(NSRange(location: (view.string as NSString).length, length: 0))
        view.insertNewline(nil)
        #expect(view.string.components(separatedBy: "•").count == 3)
        view.insertNewline(nil)
        #expect(view.string.components(separatedBy: "•").count == 2)
        view.setSelectedRange(NSRange(location: 0, length: 0))
        view.bulletList()
        #expect(!view.string.contains("•"))
        let font = try #require(view.textStorage?.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
        #expect(font.pointSize == 18)
        #expect(font.fontDescriptor.symbolicTraits.contains(.bold))
    }

    @Test("Native layout places table cells in columns and rows")
    func tableLayout() throws {
        let text = RichTextCoding.attributedString(from: tableDocument())
        let storage = NSTextStorage(attributedString: text)
        let manager = NSLayoutManager()
        let container = NSTextContainer(containerSize: NSSize(width: 500, height: 1000))
        storage.addLayoutManager(manager)
        manager.addTextContainer(container)
        manager.ensureLayout(for: container)
        func rect(_ index: Int) -> NSRect {
            let glyphs = manager.glyphRange(forCharacterRange: NSRange(location: index, length: 4), actualCharacterRange: nil)
            return manager.boundingRect(forGlyphRange: glyphs, in: container)
        }
        #expect(rect(5).minX > rect(0).maxX)
        #expect(rect(10).minY > rect(0).maxY)
    }

    @Test("Formatting applies to new typing and can be toggled off")
    func typingStyle() throws {
        let view = FormattingTextView()
        view.typingAttributes = [.font: NSFont.systemFont(ofSize: 13)]
        view.toggleBold()
        #expect((view.typingAttributes[.font] as? NSFont)?.fontDescriptor.symbolicTraits.contains(.bold) == true)
        view.toggleBold()
        #expect((view.typingAttributes[.font] as? NSFont)?.fontDescriptor.symbolicTraits.contains(.bold) == false)
    }
}
