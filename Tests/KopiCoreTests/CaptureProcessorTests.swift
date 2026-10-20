import Foundation
import Testing

@testable import KopiCore

@Suite("Capture processing")
struct CaptureProcessorTests {
    @Test("The kind priority is files, image, link, rich text, text")
    func kindPriority() async throws {
        let text = textItem("https://example.com/notes")
        let rich = richItem(plainText: "Notes", html: "<p>Notes</p>")
        let link = linkItem("https://example.com/notes", text: "Notes")
        let image = imageItem(pngData())
        let file = fileItem(URL(fileURLWithPath: "/tmp/notes.txt"))
        let pdf = imageItem(Data("pdf bytes".utf8), kind: .pdf)

        #expect(CaptureProcessor.kind(of: PasteboardSnapshot(changeCount: 1, items: [text])) == .text)
        #expect(CaptureProcessor.kind(of: PasteboardSnapshot(changeCount: 1, items: [rich])) == .richText)
        #expect(CaptureProcessor.kind(of: PasteboardSnapshot(changeCount: 1, items: [link])) == .link)
        #expect(CaptureProcessor.kind(of: PasteboardSnapshot(changeCount: 1, items: [image])) == .image)
        #expect(CaptureProcessor.kind(of: PasteboardSnapshot(changeCount: 1, items: [file])) == .files)

        // One copy offering several kinds is stored as the first one in the priority.
        #expect(CaptureProcessor.kind(of: PasteboardSnapshot(changeCount: 1, items: [file, image, link, rich, text])) == .files)
        #expect(CaptureProcessor.kind(of: PasteboardSnapshot(changeCount: 1, items: [image, link, rich, text])) == .image)
        #expect(CaptureProcessor.kind(of: PasteboardSnapshot(changeCount: 1, items: [link, rich, text])) == .link)
        #expect(CaptureProcessor.kind(of: PasteboardSnapshot(changeCount: 1, items: [rich, text])) == .richText)

        #expect(CaptureProcessor.kind(of: PasteboardSnapshot(changeCount: 1, items: [])) == nil)
        #expect(CaptureProcessor.kind(of: PasteboardSnapshot(changeCount: 1, items: [pdf])) == nil)
        #expect(CaptureProcessor.kind(of: PasteboardSnapshot(changeCount: 1, items: [textItem("")])) == nil)
    }

    @Test("Plain text copies keep their text")
    func plainTextCopy() async throws {
        let harness = try await CaptureHarness()

        let insertion = try await harness.processor.insertion(
            from: textSnapshot("notes to keep"),
            origin: .external(changeCount: 1)
        )

        #expect(insertion.kind == .text)
        #expect(insertion.text == "notes to keep")
        #expect(insertion.representations == [ClipboardRepresentation(kind: .plainText, payload: .text("notes to keep"))])
        #expect(insertion.fileReferences.isEmpty)
        #expect(insertion.assets.isEmpty)
    }

    @Test("Rich copies keep their plain, HTML and RTF flavours")
    func richCopy() async throws {
        let harness = try await CaptureHarness()
        let rtf = rtfData("Hello from TextEdit", bold: true)
        let html = "<p>Hello from <b>TextEdit</b></p>"
        let snapshot = PasteboardSnapshot(
            changeCount: 4,
            items: [richItem(plainText: "Hello from TextEdit", html: html, rtf: rtf)]
        )

        let insertion = try await harness.processor.insertion(from: snapshot, origin: .external(changeCount: 4))

        #expect(insertion.kind == .richText)
        #expect(insertion.text == "Hello from TextEdit")
        #expect(insertion.representations.map(\.kind) == [.plainText, .html, .rtf])
        #expect(insertion.representation(.html)?.text == html)
        #expect(insertion.representation(.rtf)?.data == rtf)

        // The plain text is what the card is searched and excerpted by.
        let result = try await harness.workspace.store.insert(insertion)
        let hits = try await harness.workspace.store.page(HistoryQuery(text: "textedit"))
        #expect(hits.items.map(\.id) == [result.itemID])
        #expect(result.summary.excerpt == "Hello from TextEdit")
    }

    @Test("A copy that carries only HTML derives its plain text")
    func htmlOnlyCopy() async throws {
        let harness = try await CaptureHarness()
        let snapshot = PasteboardSnapshot(
            changeCount: 2,
            items: [richItem(html: "<p>Hello <b>world</b>!</p>")]
        )

        let insertion = try await harness.processor.insertion(from: snapshot, origin: .external(changeCount: 2))

        #expect(insertion.kind == .richText)
        #expect(insertion.text == "Hello world!")
        #expect(insertion.representations.map(\.kind) == [.plainText, .html])
    }

    @Test("A copy that carries only RTF derives its plain text")
    func rtfOnlyCopy() async throws {
        let harness = try await CaptureHarness()
        let rtf = rtfData("First line\nSecond line café")
        let snapshot = PasteboardSnapshot(
            changeCount: 3,
            items: [richItem(rtf: rtf)]
        )

        let insertion = try await harness.processor.insertion(from: snapshot, origin: .external(changeCount: 3))

        #expect(insertion.kind == .richText)
        #expect(insertion.text == "First line\nSecond line café")
        #expect(insertion.representations.map(\.kind) == [.plainText, .rtf])
    }

    @Test("Links keep their URL and display text")
    func linkCopy() async throws {
        let harness = try await CaptureHarness()
        let url = "https://example.com/kopi?tab=clipboard"
        let snapshot = PasteboardSnapshot(changeCount: 5, items: [linkItem(url, text: "Kopi clipboard tab")])

        let insertion = try await harness.processor.insertion(from: snapshot, origin: .external(changeCount: 5))

        #expect(insertion.kind == .link)
        #expect(insertion.url == URL(string: url))
        #expect(insertion.text == "Kopi clipboard tab")
        #expect(insertion.representations.map(\.kind) == [.plainText, .link])
        #expect(insertion.representation(.link)?.text == url)
    }

    @Test("A link copied without plain text uses the URL as its text")
    func linkWithoutPlainText() async throws {
        let harness = try await CaptureHarness()
        let url = "https://example.com/kopi"
        let snapshot = PasteboardSnapshot(changeCount: 5, items: [linkItem(url)])

        let insertion = try await harness.processor.insertion(from: snapshot, origin: .external(changeCount: 5))

        #expect(insertion.kind == .link)
        #expect(insertion.text == url)
        #expect(insertion.fingerprint == linkInsertion(url).fingerprint)
    }

    @Test("Image bytes are imported into the asset store at full fidelity")
    func imageCopy() async throws {
        let harness = try await CaptureHarness()
        let bytes = pngData(width: 12, height: 8)
        let snapshot = PasteboardSnapshot(changeCount: 6, items: [imageItem(bytes)])

        let insertion = try await harness.processor.insertion(from: snapshot, origin: .external(changeCount: 6))

        #expect(insertion.kind == .image)
        #expect(insertion.text == nil)
        #expect(insertion.representations.count == 1)
        let representation = try #require(insertion.representations.first)
        #expect(representation.kind == .png)
        let asset = try #require(representation.asset)
        #expect(asset.kind == .image)
        #expect(asset.byteCount == bytes.count)
        #expect(asset.contentHash == ContentHasher.sha256Hex(bytes))

        let stored = try await harness.workspace.assetStore.readData(for: asset)
        #expect(stored == bytes)
        let exists = await harness.workspace.assetStore.contains(asset)
        #expect(exists)

        let result = try await harness.workspace.store.insert(insertion)
        #expect(result.summary.kind == .image)
    }

    @Test("The first image flavour of the fidelity order is kept")
    func imageFlavourOrder() async throws {
        let harness = try await CaptureHarness()
        let bytes = pngData(width: 4, height: 4)
        let pngAndTIFF = PasteboardItemSnapshot(flavours: [
            PasteboardFlavour(type: ClipboardRepresentationKind.tiff.pasteboardType, data: bytes),
            PasteboardFlavour(type: ClipboardRepresentationKind.png.pasteboardType, data: bytes)
        ])
        let tiffAndGIF = PasteboardItemSnapshot(flavours: [
            PasteboardFlavour(type: ClipboardRepresentationKind.gif.pasteboardType, data: bytes),
            PasteboardFlavour(type: ClipboardRepresentationKind.tiff.pasteboardType, data: bytes)
        ])

        let preferred = try await harness.processor.insertion(
            from: PasteboardSnapshot(changeCount: 1, items: [pngAndTIFF]),
            origin: .external(changeCount: 1)
        )
        let fallback = try await harness.processor.insertion(
            from: PasteboardSnapshot(changeCount: 2, items: [tiffAndGIF]),
            origin: .external(changeCount: 2)
        )

        #expect(preferred.representations.first?.kind == .png)
        #expect(fallback.representations.first?.kind == .tiff)
    }

    @Test("Alternate flavours of one copy stay one card")
    func alternateFlavours() async throws {
        let harness = try await CaptureHarness()
        let bytes = pngData(width: 4, height: 4)
        let item = PasteboardItemSnapshot(flavours: [
            PasteboardFlavour(type: ClipboardRepresentationKind.png.pasteboardType, data: bytes),
            PasteboardFlavour(type: ClipboardRepresentationKind.tiff.pasteboardType, data: bytes),
            flavour(.plainText, "a screenshot")
        ])

        let insertion = try await harness.processor.insertion(
            from: PasteboardSnapshot(changeCount: 1, items: [item]),
            origin: .external(changeCount: 1)
        )

        #expect(insertion.kind == .image)
        #expect(insertion.representations.count == 1)
        #expect(insertion.assets.count == 1)
    }

    @Test("Finder copies stay one card in pasteboard order")
    func multiFileCopy() async throws {
        let harness = try await CaptureHarness()
        let first = try harness.workspace.writeFile("first.txt", contents: "first")
        let second = try harness.workspace.writeFile("second.txt", contents: "second!")
        let third = try harness.workspace.writeFile("third.txt", contents: "third")
        let snapshot = PasteboardSnapshot(
            changeCount: 7,
            items: [fileItem(first), fileItem(second), fileItem(third)]
        )

        let insertion = try await harness.processor.insertion(from: snapshot, origin: .external(changeCount: 7))
        #expect(insertion.kind == .files)
        #expect(insertion.fileReferences.map(\.displayName) == ["first.txt", "second.txt", "third.txt"])
        #expect(insertion.fileReferences.map(\.byteSize) == [5, 7, 5])
        #expect(insertion.fileReferences.allSatisfy { !$0.isDirectory })

        let result = try await harness.workspace.store.insert(insertion)
        #expect(result.summary.fileCount == 3)
        #expect(result.summary.fileNames == ["first.txt", "second.txt", "third.txt"])
        #expect(result.summary.kind == .files)
    }

    @Test("Folder copies are flagged and carry no byte size")
    func folderCopy() async throws {
        let harness = try await CaptureHarness()
        let folder = harness.workspace.root.appendingPathComponent("Report folder", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let snapshot = PasteboardSnapshot(changeCount: 8, items: [fileItem(folder)])

        let insertion = try await harness.processor.insertion(from: snapshot, origin: .external(changeCount: 8))

        let reference = try #require(insertion.fileReferences.first)
        #expect(reference.isDirectory)
        #expect(reference.byteSize == nil)
        #expect(reference.displayName == "Report folder")
        #expect(reference.path == folder.standardizedFileURL.path)
        #expect(insertion.kind == .files)
    }

    @Test("A mixed copy of files and an image keeps the files")
    func mixedFileAndImageCopy() async throws {
        let harness = try await CaptureHarness()
        let file = try harness.workspace.writeFile("kept.txt", contents: "kept")
        let snapshot = PasteboardSnapshot(
            changeCount: 9,
            items: [fileItem(file), imageItem(pngData())]
        )

        let insertion = try await harness.processor.insertion(from: snapshot, origin: .external(changeCount: 9))

        #expect(insertion.kind == .files)
        #expect(insertion.fileReferences.map(\.displayName) == ["kept.txt"])
        #expect(insertion.assets.isEmpty)
    }

    @Test("Content Kopi cannot store is rejected")
    func unsupportedContent() async throws {
        let harness = try await CaptureHarness()

        await #expect(throws: CaptureProcessorError.unsupportedContent) {
            try await harness.processor.insertion(
                from: PasteboardSnapshot(changeCount: 1, items: [imageItem(Data("pdf bytes".utf8), kind: .pdf)]),
                origin: .external(changeCount: 1)
            )
        }
        await #expect(throws: CaptureProcessorError.unsupportedContent) {
            try await harness.processor.insertion(
                from: PasteboardSnapshot(changeCount: 1, items: []),
                origin: .external(changeCount: 1)
            )
        }
    }

    @Test("Thumbnails come from the shared cache, off the main actor")
    func thumbnails() async throws {
        let harness = try await CaptureHarness()
        let insertion = try await harness.processor.insertion(
            from: PasteboardSnapshot(changeCount: 1, items: [imageItem(pngData(width: 64, height: 32))]),
            origin: .external(changeCount: 1)
        )
        let asset = try #require(insertion.representations.first?.asset)

        let first = try await harness.processor.thumbnail(for: asset, maxPixelSize: 16)
        let second = try await harness.processor.thumbnail(for: asset, maxPixelSize: 16)

        #expect(max(first.pixelSize.width, first.pixelSize.height) <= 16)
        #expect(first.cgImage === second.cgImage)

        let cached = await harness.thumbnailCache.contains(ThumbnailKey(assetID: asset.id, maxPixelSize: 16))
        #expect(cached)
        let count = await harness.thumbnailCache.count
        #expect(count == 1)

        _ = try await harness.processor.thumbnail(for: asset)
        let defaultCached = await harness.thumbnailCache.contains(
            ThumbnailKey(assetID: asset.id, maxPixelSize: CaptureProcessor.defaultThumbnailPixelSize)
        )
        #expect(defaultCached)
    }
}

private extension ClipboardItemInsertion {
    func representation(_ kind: ClipboardRepresentationKind) -> ClipboardRepresentation? {
        representations.first { $0.kind == kind }
    }
}
