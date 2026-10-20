import Foundation
import Testing

@testable import KopiCore

@Suite("Assets")
struct AssetStoreTests {
    @Test("Assets are content addressed and reuse the same file")
    func contentAddressedAssets() async throws {
        let workspace = try TempWorkspace()
        let bytes = Data("shared image bytes".utf8)

        let first = try await workspace.assetStore.importData(bytes, kind: .image, fileExtension: "png")
        let second = try await workspace.assetStore.importData(bytes, kind: .image, fileExtension: "png")

        #expect(first.wasCreated)
        #expect(second.wasCreated == false)
        #expect(first.reference.id == second.reference.id)
        #expect(first.reference.relativePath == second.reference.relativePath)
        #expect(first.reference.kind == .image)
        #expect(FileManager.default.fileExists(atPath: workspace.assetStore.fileURL(for: first.reference).path))
        let stored = try await workspace.assetStore.readData(for: first.reference)
        #expect(stored == bytes)
        let totalBytes = try await workspace.assetStore.byteCount()
        #expect(totalBytes == bytes.count)
    }

    @Test("A pinned file keeps working after the original is deleted")
    func pinnedFileSurvivesOriginalDeletion() async throws {
        let workspace = try TempWorkspace()
        try await workspace.store.beginSession()
        let file = try workspace.writeFile("Notes.txt", contents: "must survive the original")
        let inserted = try await workspace.store.insert(fileInsertion([file]))

        let pinned = try await workspace.store.setPinned(true, for: inserted.itemID)
        #expect(pinned.isPinned)

        let detail = try #require(await workspace.store.detail(for: inserted.itemID))
        let reference = try #require(detail.fileReferences.first)
        let snapshot = try #require(reference.snapshot)
        #expect(snapshot.kind == .fileSnapshot)
        #expect(snapshot.originalPath == file.path)
        #expect(reference.isPreserved)

        try FileManager.default.removeItem(at: file)
        #expect(!reference.isOriginalAvailable)

        let restored = try await workspace.assetStore.readData(for: snapshot)
        #expect(String(decoding: restored, as: UTF8.self) == "must survive the original")
        let protected = try await workspace.store.isAssetProtected(snapshot.id)
        #expect(protected)
        let references = try await workspace.store.assetReferenceCount(for: snapshot.id)
        #expect(references == 1)

        let relaunched = try workspace.reopenStore()
        let relaunchedDetail = try #require(await relaunched.detail(for: inserted.itemID))
        #expect(relaunchedDetail.fileSnapshots.map(\.id) == [snapshot.id])
    }

    @Test("Pinning copies through the injected copier")
    func pinningUsesInjectedCopier() async throws {
        let copier = RecordingAssetCopier(delay: .milliseconds(20))
        let workspace = try TempWorkspace(copier: copier)
        try await workspace.store.beginSession()
        let file = try workspace.writeFile("Slow.bin", contents: "slow copy")
        let inserted = try await workspace.store.insert(fileInsertion([file]))

        _ = try await workspace.store.setPinned(true, for: inserted.itemID)

        let copied = await copier.copiedSources
        #expect(copied == [file.path])
    }

    @Test("A failed copy leaves the card untouched and unpinned")
    func failedCopyKeepsCard() async throws {
        let copier = RecordingAssetCopier(failure: AssetStoreError.insufficientSpace("/Volumes/Full"))
        let workspace = try TempWorkspace(copier: copier)
        try await workspace.store.beginSession()
        let file = try workspace.writeFile("Large.bin", contents: "no room for this")
        let inserted = try await workspace.store.insert(fileInsertion([file]))

        var thrown: (any Error)?
        do {
            _ = try await workspace.store.setPinned(true, for: inserted.itemID)
        } catch {
            thrown = error
        }
        let failure = try #require(thrown as? HistoryStoreError)
        guard case .pinningFailed(let itemID, let message) = failure else {
            Issue.record("expected a pinning failure, got \(failure)")
            return
        }
        #expect(itemID == inserted.itemID)
        #expect(message.contains("space"))

        let summary = try #require(await workspace.store.summary(for: inserted.itemID))
        #expect(summary.isPinned == false)
        let detail = try #require(await workspace.store.detail(for: inserted.itemID))
        #expect(detail.fileReferences.count == 1)
        #expect(detail.fileSnapshots.isEmpty)
        let statistics = try await workspace.store.statistics()
        #expect(statistics.assetCount == 0)
    }

    @Test("Deleting an unpinned card collects its assets")
    func deletingCardCollectsAssets() async throws {
        let workspace = try TempWorkspace()
        try await workspace.store.beginSession()
        let bytes = Data(repeating: 4, count: 256)
        let asset = try await workspace.assetStore.importData(bytes, kind: .image, fileExtension: "png")
        let inserted = try await workspace.store.insert(imageInsertion(asset: asset.reference))
        let url = workspace.assetStore.fileURL(for: asset.reference)
        #expect(FileManager.default.fileExists(atPath: url.path))

        let report = try await workspace.store.delete(inserted.itemID)

        #expect(report.removedAssetIDs == [asset.reference.id])
        #expect(!FileManager.default.fileExists(atPath: url.path))
        let statistics = try await workspace.store.statistics()
        #expect(statistics.assetCount == 0)
    }

    @Test("An asset shared with a pinned card is protected until that card goes")
    func sharedAssetsAreProtected() async throws {
        let workspace = try TempWorkspace()
        try await workspace.store.beginSession()
        let bytes = Data(repeating: 6, count: 512)
        let asset = try await workspace.assetStore.importData(bytes, kind: .image, fileExtension: "png")
        let imageCard = try await workspace.store.insert(imageInsertion(asset: asset.reference, label: "first use"))

        let sharedFile = workspace.root.appendingPathComponent("shared.bin")
        try bytes.write(to: sharedFile)
        let fileCard = try await workspace.store.insert(fileInsertion([sharedFile], label: "second use"))
        _ = try await workspace.store.setPinned(true, for: fileCard.itemID)

        let referenceCount = try await workspace.store.assetReferenceCount(for: asset.reference.id)
        #expect(referenceCount == 2)
        let protected = try await workspace.store.isAssetProtected(asset.reference.id)
        #expect(protected)

        _ = try await workspace.store.delete(fileCard.itemID)
        let afterFileDeletion = try await workspace.store.assetReferenceCount(for: asset.reference.id)
        #expect(afterFileDeletion == 1)
        #expect(FileManager.default.fileExists(atPath: workspace.assetStore.fileURL(for: asset.reference).path))

        _ = try await workspace.store.delete(imageCard.itemID)
        let afterAllDeletions = try await workspace.store.assetReferenceCount(for: asset.reference.id)
        #expect(afterAllDeletions == 0)
        #expect(!FileManager.default.fileExists(atPath: workspace.assetStore.fileURL(for: asset.reference).path))
    }

    @Test("The asset directory can be swept of files no row refers to")
    func sweepingAssetDirectory() async throws {
        let workspace = try TempWorkspace()
        try await workspace.store.beginSession()
        let kept = try await workspace.assetStore.importData(Data("kept".utf8), kind: .image, fileExtension: "png")
        let orphan = try await workspace.assetStore.importData(Data("orphan".utf8), kind: .fileSnapshot, fileExtension: "png")
        _ = try await workspace.store.insert(imageInsertion(asset: kept.reference))

        let removed = try await workspace.store.sweepAssetDirectory()

        #expect(removed == 1)
        #expect(FileManager.default.fileExists(atPath: workspace.assetStore.fileURL(for: kept.reference).path))
        #expect(!FileManager.default.fileExists(atPath: workspace.assetStore.fileURL(for: orphan.reference).path))
    }

    @Test("Relative paths never escape the asset root")
    func pathsStayInsideRoot() throws {
        let workspace = try TempWorkspace()
        #expect(throws: AssetStoreError.invalidRelativePath("../outside.png")) {
            try workspace.assetStore.fileURL(forRelativePath: "../outside.png")
        }
        #expect(throws: AssetStoreError.invalidRelativePath("/absolute.png")) {
            try workspace.assetStore.fileURL(forRelativePath: "/absolute.png")
        }
        let nested = try workspace.assetStore.fileURL(forRelativePath: "images/within.png")
        #expect(nested.path.hasPrefix(workspace.root.path))
    }
}
