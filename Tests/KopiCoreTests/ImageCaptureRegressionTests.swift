import Foundation
import Testing
@testable import KopiCore
@testable import Kopi

@Suite("Image file classification and radial previews")
struct ImageCaptureRegressionTests {
    private func fileSnapshot(_ urls: [URL]) -> PasteboardSnapshot {
        PasteboardSnapshot(changeCount: 12, items: urls.map { url in
            PasteboardItemSnapshot(flavours: [PasteboardFlavour(type: ClipboardRepresentationKind.fileURL.pasteboardType, string: url.absoluteString)])
        })
    }

    @Test func singleImageFileIsOwnedAndPreviewedAfterOriginalDisappears() async throws {
        let harness = try await CaptureHarness()
        let file = harness.workspace.root.appendingPathComponent("clipboard_image.png")
        let bytes = pngData(width: 120, height: 60)
        try bytes.write(to: file)
        let capture = try await harness.processor.insertion(from: fileSnapshot([file]), origin: .external(changeCount: 12))
        #expect(capture.kind == .image)
        #expect(capture.fileReferences.isEmpty)
        let saved = try await harness.workspace.store.insert(capture)
        try FileManager.default.removeItem(at: file)
        let asset = try #require(capture.assets.first)
        #expect(try await harness.workspace.assetStore.readData(for: asset) == bytes)
        let thumbnail = try await harness.processor.thumbnail(for: asset)
        #expect(thumbnail.cgImage.width == 120)
        #expect(thumbnail.cgImage.height == 60)
        let imagePage = try await harness.workspace.store.page(HistoryQuery(filter: .images))
        let filePage = try await harness.workspace.store.page(HistoryQuery(filter: .files))
        #expect(imagePage.itemIDs == [saved.itemID])
        #expect(filePage.items.isEmpty)
        let request = try await harness.service.writeRequest(for: saved.itemID)
        #expect(request.flavours.contains { $0.type == ClipboardRepresentationKind.png.pasteboardType && $0.data == bytes })
        #expect(!request.flavours.contains { $0.type == ClipboardRepresentationKind.fileURL.pasteboardType })
    }

    @Test func mixedSelectionsAndInvalidImagesKeepFileSemantics() async throws {
        let harness = try await CaptureHarness()
        let image = harness.workspace.root.appendingPathComponent("image.png")
        try pngData().write(to: image)
        let text = try harness.workspace.writeFile("document.txt", contents: "Document")
        let invalid = try harness.workspace.writeFile("invalid.png", contents: "Not an image")
        #expect(CaptureProcessor.kind(of: fileSnapshot([image, text])) == .files)
        #expect(CaptureProcessor.kind(of: fileSnapshot([invalid])) == .files)
        #expect(CaptureProcessor.kind(of: fileSnapshot([harness.workspace.root.appendingPathComponent("missing.png")])) == .files)
    }

    @Test func repairPreservesPinsLabelsAndCollectionAndDeduplicatesPlainCopies() async throws {
        let harness = try await CaptureHarness()
        let first = harness.workspace.root.appendingPathComponent("first.png")
        let bytes = pngData(width: 90, height: 45)
        let directory = harness.workspace.root.appendingPathComponent(ContentHasher.sha256Hex(bytes))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let second = directory.appendingPathComponent("second.png")
        try bytes.write(to: first)
        try bytes.write(to: second)
        let pinned = try await harness.workspace.store.insert(fileInsertion([first], label: "Keep my label", destination: .collection))
        _ = try await harness.workspace.store.setPinned(true, for: pinned.itemID)
        let unlabelled = try await harness.workspace.store.insert(fileInsertion([second]))
        let image = try await harness.processor.insertion(from: PasteboardSnapshot(changeCount: 1, items: [imageItem(bytes)]), origin: .external(changeCount: 1))
        let existing = try await harness.workspace.store.insert(image)
        let before = try #require(await harness.workspace.store.detail(for: pinned.itemID))
        #expect(try await harness.workspace.store.repairImageFileCards(using: harness.processor) == 2)
        let repaired = try #require(await harness.workspace.store.detail(for: pinned.itemID))
        #expect(repaired.summary.kind == .image)
        #expect(repaired.summary.isPinned)
        #expect(repaired.summary.isCollection)
        #expect(repaired.summary.label == "Keep my label")
        #expect(repaired.summary.createdAt == before.summary.createdAt)
        #expect(repaired.summary.lastCopiedAt == before.summary.lastCopiedAt)
        #expect(repaired.fileReferences.isEmpty)
        #expect(try await harness.workspace.store.detail(for: unlabelled.itemID) == nil)
        #expect(try await harness.workspace.store.detail(for: existing.itemID)?.summary.kind == .image)
        #expect(try await harness.workspace.store.repairImageFileCards(using: harness.processor) == 0)
        #expect(FileManager.default.fileExists(atPath: first.path))
        #expect(FileManager.default.fileExists(atPath: second.path))
    }

    @Test func privateAppImagePathsUseClipboardBytesWithoutOpeningTheFile() async throws {
        let harness = try await CaptureHarness()
        let privateURL = URL(fileURLWithPath: "/Users/example/Library/Containers/com.example.other/Data/export/image.png")
        let fileOnly = fileSnapshot([privateURL])
        #expect(CaptureProcessor.isPrivateAppStorage(privateURL))
        #expect(CaptureProcessor.kind(of: fileOnly) == .image)
        await #expect(throws: CaptureProcessorError.imageDataUnavailable) {
            try await harness.processor.insertion(from: fileOnly, origin: .external(changeCount: 12))
        }
        let supplied = PasteboardSnapshot(changeCount: 12, items: fileOnly.items + [imageItem(pngData())])
        let image = try await harness.processor.insertion(from: supplied, origin: .external(changeCount: 12))
        #expect(image.kind == .image)
        #expect(image.fileReferences.isEmpty)
    }

    @Test func automaticRepairNeverOpensUnownedExternalFiles() async throws {
        let harness = try await CaptureHarness()
        let file = harness.workspace.root.appendingPathComponent("unowned.png")
        try pngData().write(to: file)
        let saved = try await harness.workspace.store.insert(fileInsertion([file]))
        #expect(try await harness.workspace.store.repairImageFileCards(using: harness.processor) == 0)
        #expect(try await harness.workspace.store.detail(for: saved.itemID)?.summary.kind == .files)
    }

    @Test func recentQueryExcludesCollectionAndRetainsOrdinaryPinnedHistory() async throws {
        let workspace = try TempWorkspace()
        let clip = try await workspace.store.insert(textInsertion("Recent copy"))
        let pinned = try await workspace.store.insert(textInsertion("Pinned recent copy"))
        _ = try await workspace.store.setPinned(true, for: pinned.itemID)
        _ = try await workspace.store.insert(textInsertion("Saved collection", destination: .collection))
        let recent = try await workspace.store.page(HistoryQuery(includesCollection: false))
        #expect(recent.totalCount == 2)
        #expect(Set(recent.itemIDs) == Set([clip.itemID, pinned.itemID]))
    }

    @Test @MainActor func sharedPreviewStoreProvidesRadialThumbnails() async throws {
        let harness = try await CaptureHarness()
        let image = try await harness.processor.insertion(from: PasteboardSnapshot(changeCount: 1, items: [imageItem(pngData(width: 80, height: 40))]), origin: .external(changeCount: 1))
        let result = try await harness.workspace.store.insert(image)
        let previews = PreviewStore(store: harness.workspace.store, processor: harness.processor)
        await previews.load(result.summary, maxPixelSize: 320)
        #expect(previews.entry(for: result.itemID).image?.width == 80)
        #expect(previews.entry(for: result.itemID).image?.height == 40)
    }
    @Test @MainActor func radialCanUpgradeAnExistingSmallGridThumbnail() async throws {
        let harness = try await CaptureHarness()
        let image = try await harness.processor.insertion(from: PasteboardSnapshot(changeCount: 1, items: [imageItem(pngData(width: 800, height: 400))]), origin: .external(changeCount: 1))
        let result = try await harness.workspace.store.insert(image)
        let previews = PreviewStore(store: harness.workspace.store, processor: harness.processor)
        await previews.load(result.summary, maxPixelSize: 80)
        #expect(previews.entry(for: result.itemID).image?.width == 80)
        await previews.load(result.summary, maxPixelSize: 640)
        #expect(previews.entry(for: result.itemID).image?.width == 640)
        #expect(previews.entry(for: result.itemID).image?.height == 320)
        await previews.load(result.summary, maxPixelSize: 320)
        #expect(previews.entry(for: result.itemID).image?.width == 640)
        #expect(previews.cachedEntryCount == 1)
    }

}
