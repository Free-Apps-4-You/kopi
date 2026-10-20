import Foundation
import Testing

@testable import KopiCore

@Suite("Card drag")
struct CardDragMappingTests {
    @Test("A text card drags its stored text")
    func textCard() async throws {
        let workspace = try TempWorkspace()
        try await workspace.store.beginSession()
        let inserted = try await workspace.store.insert(textInsertion("dragged text"))
        let detail = try #require(await workspace.store.detail(for: inserted.itemID))

        #expect(CardDragMapping.flavours(for: detail) == [
            CardDragFlavour(typeIdentifier: "public.utf8-plain-text", source: .text("dragged text"))
        ])
    }

    @Test("A rich text card offers RTF, HTML and plain text")
    func richTextCard() async throws {
        let workspace = try TempWorkspace()
        try await workspace.store.beginSession()
        let inserted = try await workspace.store.insert(richTextInsertion("Formatted text"))
        let detail = try #require(await workspace.store.detail(for: inserted.itemID))

        let flavours = CardDragMapping.flavours(for: detail)
        #expect(flavours.map(\.typeIdentifier) == ["public.rtf", "public.html", "public.utf8-plain-text"])
        #expect(flavours.allSatisfy { !$0.source.isFile })
        #expect(text(of: flavours[2]) == "Formatted text")
        #expect(text(of: flavours[1])?.contains("Formatted text") == true)
        guard case .data(let rtf)? = flavours.first?.source else {
            Issue.record("RTF flavour should carry bytes")
            return
        }
        #expect(String(decoding: rtf, as: UTF8.self).contains("Formatted text"))
    }

    @Test("A rich text card without a stored plain flavour derives one")
    func richTextDerivesPlainText() {
        let document = RichTextDocument(runs: [RichTextDocument.Run(text: "Derived heading", traits: .bold)])
        let detail = makeDetail(
            kind: .richText,
            representations: [
                ClipboardRepresentation(kind: .html, payload: .text(document.html())),
                ClipboardRepresentation(kind: .rtf, payload: .data(document.rtf()))
            ]
        )

        let flavours = CardDragMapping.flavours(for: detail)
        #expect(flavours.map(\.typeIdentifier) == ["public.rtf", "public.html", "public.utf8-plain-text"])
        #expect(text(of: flavours[2]) == "Derived heading")
    }

    @Test("A link card drags its URL and its label")
    func linkCard() async throws {
        let workspace = try TempWorkspace()
        try await workspace.store.beginSession()
        let inserted = try await workspace.store.insert(
            linkInsertion("https://example.com/page", label: "Example page")
        )
        let detail = try #require(await workspace.store.detail(for: inserted.itemID))

        let flavours = CardDragMapping.flavours(for: detail)
        #expect(flavours.map(\.typeIdentifier) == ["public.url", "public.utf8-plain-text"])
        #expect(text(of: flavours[0]) == "https://example.com/page")
        #expect(text(of: flavours[1]) == "Example page")
    }

    @Test("An image card drags its asset file and its image bytes")
    func imageCard() async throws {
        let workspace = try TempWorkspace()
        try await workspace.store.beginSession()
        let asset = try await workspace.assetStore.importData(
            Data(repeating: 7, count: 64),
            kind: .image,
            fileExtension: "png"
        )
        let inserted = try await workspace.store.insert(imageInsertion(asset: asset.reference))
        let detail = try #require(await workspace.store.detail(for: inserted.itemID))

        let flavours = CardDragMapping.flavours(for: detail)
        #expect(flavours == [
            CardDragFlavour(typeIdentifier: "public.file-url", source: .assetFile(asset.reference)),
            CardDragFlavour(typeIdentifier: "public.png", source: .asset(asset.reference))
        ])
        #expect(flavours.first?.source.isFile == true)
    }

    @Test("An image card without an asset file still drags its bytes")
    func inlineImageCard() {
        let bytes = Data(repeating: 9, count: 8)
        let detail = makeDetail(
            kind: .image,
            representations: [ClipboardRepresentation(kind: .tiff, payload: .data(bytes))]
        )

        #expect(CardDragMapping.flavours(for: detail) == [
            CardDragFlavour(typeIdentifier: "public.tiff", source: .data(bytes))
        ])
    }

    @Test("A file card drags the original file")
    func fileCard() async throws {
        let workspace = try TempWorkspace()
        try await workspace.store.beginSession()
        let file = try workspace.writeFile("Invoice.pdf", contents: "pdf bytes")
        let inserted = try await workspace.store.insert(fileInsertion([file]))
        let detail = try #require(await workspace.store.detail(for: inserted.itemID))

        #expect(CardDragMapping.flavours(for: detail) == [
            CardDragFlavour(typeIdentifier: "public.file-url", source: .file(file))
        ])
    }

    @Test("A pinned file card drags its snapshot once the original is gone")
    func pinnedFileCardUsesSnapshot() async throws {
        let workspace = try TempWorkspace()
        try await workspace.store.beginSession()
        let file = try workspace.writeFile("Report.pages", contents: "pages bytes")
        let inserted = try await workspace.store.insert(fileInsertion([file]))
        _ = try await workspace.store.setPinned(true, for: inserted.itemID)
        try FileManager.default.removeItem(at: file)

        let detail = try #require(await workspace.store.detail(for: inserted.itemID))
        let snapshot = try #require(detail.fileReferences.first?.snapshot)
        #expect(detail.fileReferences.first?.isOriginalAvailable == false)

        #expect(CardDragMapping.flavours(for: detail) == [
            CardDragFlavour(typeIdentifier: "public.file-url", source: .assetFile(snapshot))
        ])
    }

    @Test("A card holding several files does not drag")
    func multiFileCardDoesNotDrag() async throws {
        let workspace = try TempWorkspace()
        try await workspace.store.beginSession()
        let first = try workspace.writeFile("First.txt", contents: "first")
        let second = try workspace.writeFile("Second.txt", contents: "second")
        let inserted = try await workspace.store.insert(fileInsertion([first, second]))
        let detail = try #require(await workspace.store.detail(for: inserted.itemID))

        #expect(CardDragMapping.isDraggable(inserted.summary) == false)
        #expect(CardDragMapping.flavours(for: detail).isEmpty)
    }

    @Test("Every other card drags, including a single file")
    func singleItemCardsDrag() async throws {
        let workspace = try TempWorkspace()
        try await workspace.store.beginSession()
        let text = try await workspace.store.insert(textInsertion("drag me"))
        let file = try workspace.writeFile("Only.txt", contents: "only")
        let files = try await workspace.store.insert(fileInsertion([file]))

        #expect(CardDragMapping.isDraggable(text.summary))
        #expect(CardDragMapping.isDraggable(files.summary))
    }

    @Test("Registrations follow the kind of the card")
    func registrations() {
        #expect(CardDragMapping.registrations(for: .text) == [.data("public.utf8-plain-text")])
        #expect(CardDragMapping.registrations(for: .richText) == [
            .data("public.rtf"),
            .data("public.html"),
            .data("public.utf8-plain-text")
        ])
        #expect(CardDragMapping.registrations(for: .link) == [
            .data("public.url"),
            .data("public.utf8-plain-text")
        ])
        #expect(CardDragMapping.registrations(for: .files) == [.file("public.file-url")])

        let image = CardDragMapping.registrations(for: .image)
        #expect(image.first == .file("public.file-url"))
        #expect(image.dropFirst() == [
            .data("public.png"),
            .data("public.tiff"),
            .data("public.jpeg"),
            .data("public.heic"),
            .data("com.compuserve.gif"),
            .data("org.webmproject.webp")
        ])
    }

    @Test("Resolution matches requests and only falls back between image flavours")
    func resolution() {
        let asset = AssetReference(
            id: AssetID(rawValue: "asset"),
            kind: .image,
            relativePath: "images/asset.png",
            byteCount: 10,
            contentHash: "hash",
            createdAt: Date()
        )
        let imageFlavours = [
            CardDragFlavour(typeIdentifier: "public.file-url", source: .assetFile(asset)),
            CardDragFlavour(typeIdentifier: "public.png", source: .asset(asset))
        ]
        #expect(CardDragMapping.flavour(for: .file("public.file-url"), in: imageFlavours) == imageFlavours[0])
        #expect(CardDragMapping.flavour(for: .data("public.png"), in: imageFlavours) == imageFlavours[1])
        #expect(CardDragMapping.flavour(for: .data("public.tiff"), in: imageFlavours) == imageFlavours[1])
        #expect(CardDragMapping.flavour(for: .data("public.rtf"), in: imageFlavours) == nil)
        #expect(CardDragMapping.flavour(for: .file("public.file-url"), in: []) == nil)

        let textFlavours = [CardDragFlavour(typeIdentifier: "public.utf8-plain-text", source: .text("hello"))]
        #expect(CardDragMapping.flavour(for: .data("public.utf8-plain-text"), in: textFlavours) == textFlavours[0])
        #expect(CardDragMapping.flavour(for: .data("public.png"), in: textFlavours) == nil)
        #expect(CardDragMapping.flavour(for: .file("public.file-url"), in: textFlavours) == nil)

        let rtfOnly = [CardDragFlavour(typeIdentifier: "public.rtf", source: .data(Data()))]
        #expect(CardDragMapping.flavour(for: .data("public.html"), in: rtfOnly) == nil)
    }

    // MARK: - Helpers

    private func text(of flavour: CardDragFlavour) -> String? {
        if case .text(let value) = flavour.source { return value }
        return nil
    }

    private func makeDetail(
        kind: ClipboardItemKind,
        representations: [ClipboardRepresentation] = [],
        files: [FileReference] = [],
        url: URL? = nil
    ) -> ClipboardItemDetail {
        let summary = ClipboardItemSummary(
            id: ClipboardItemID(),
            kind: kind,
            excerpt: "",
            primaryURL: url,
            fileNames: files.map(\.displayName),
            fingerprint: ContentFingerprint(rawValue: "test"),
            createdAt: Date(),
            lastCopiedAt: Date(),
            updatedAt: Date()
        )
        return ClipboardItemDetail(
            summary: summary,
            searchText: "",
            representations: representations,
            fileReferences: files
        )
    }
}
