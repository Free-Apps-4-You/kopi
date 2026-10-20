import Foundation
import Testing

@testable import KopiCore

@Suite("Collection scope")
struct CollectionScopeTests {
    @Test("Collected cards are listed by the collection scope only")
    func scopeQueries() async throws {
        let workspace = try TempWorkspace()
        try await workspace.store.beginSession()

        let ordinary = try await workspace.store.insert(textInsertion("ordinary card"))
        let collected = try await workspace.store.insert(textInsertion("collected card"))
        let pinned = try await workspace.store.insert(textInsertion("pinned card"))
        _ = try await workspace.store.setPinned(true, for: pinned.itemID)
        let marked = try await workspace.store.setCollection(true, for: collected.itemID)
        #expect(marked.isCollection)

        let collectionPage = try await workspace.store.page(HistoryQuery(scope: .collection))
        #expect(collectionPage.itemIDs == [collected.itemID])
        #expect(collectionPage.items.first?.isCollection == true)

        let everything = try await workspace.store.page(HistoryQuery())
        #expect(Set(everything.itemIDs) == [ordinary.itemID, collected.itemID, pinned.itemID])

        #expect(try await workspace.store.count(scope: .collection) == 1)
        #expect(try await workspace.store.count(scope: .pinned) == 1)

        // A collected card keeps collapsing on fresh copies of the same content, so
        // an ordinary capture never turns into a second card.
        let recopied = try await workspace.store.insert(textInsertion("collected card"))
        #expect(recopied.didCreateItem == false)
        #expect(try await workspace.store.count(scope: .collection) == 1)

        _ = try await workspace.store.setCollection(false, for: collected.itemID)
        let emptied = try await workspace.store.page(HistoryQuery(scope: .collection))
        #expect(emptied.items.isEmpty)
    }

    @Test("Time-based retention never removes collected cards")
    func retentionKeepsCollection() async throws {
        let workspace = try TempWorkspace()
        try await workspace.store.beginSession()
        _ = try await workspace.store.setRetention(.sevenDays)

        let expired = try await workspace.store.insert(textInsertion("expired ordinary", capturedAt: .daysAgo(40)))
        let collected = try await workspace.store.insert(textInsertion("collected long ago", capturedAt: .daysAgo(40)))
        _ = try await workspace.store.setCollection(true, for: collected.itemID)

        let report = try await workspace.store.runCleanup(now: Date())
        #expect(report.removedItemIDs == [expired.itemID])

        let survivors = try await workspace.store.page(HistoryQuery())
        #expect(survivors.itemIDs == [collected.itemID])
    }

    @Test("Session retention leaves collected cards of earlier runs alone")
    func sessionRetentionKeepsCollection() async throws {
        let workspace = try TempWorkspace()
        try await workspace.store.beginSession()
        _ = try await workspace.store.setRetention(.currentSession)

        let collected = try await workspace.store.insert(textInsertion("collected in the previous run"))
        _ = try await workspace.store.setCollection(true, for: collected.itemID)
        let ordinary = try await workspace.store.insert(textInsertion("ordinary in the previous run"))

        let relaunched = try workspace.reopenStore()
        let start = try await relaunched.beginSession()

        #expect(start.cleanup.removedItemIDs == [ordinary.itemID])
        let survivors = try await relaunched.page(HistoryQuery())
        #expect(survivors.itemIDs == [collected.itemID])
    }

    @Test("Clear History keeps collected cards and their assets")
    func clearHistoryKeepsCollection() async throws {
        let workspace = try TempWorkspace()
        try await workspace.store.beginSession()

        let bytes = Data(repeating: 9, count: 256)
        let asset = try await workspace.assetStore.importData(bytes, kind: .image, fileExtension: "png")
        let collected = try await workspace.store.insert(imageInsertion(asset: asset.reference))
        _ = try await workspace.store.setCollection(true, for: collected.itemID)
        let ordinary = try await workspace.store.insert(textInsertion("ordinary card"))

        let report = try await workspace.store.clearHistory()
        #expect(report.removedItemIDs == [ordinary.itemID])
        #expect(report.removedAssetIDs.isEmpty)
        #expect(try await workspace.store.count(scope: .collection) == 1)
        #expect(FileManager.default.fileExists(atPath: workspace.assetStore.fileURL(for: asset.reference).path))
    }

    @Test("Leaving the collection restarts the retention period")
    func leavingCollectionRestartsRetention() async throws {
        let workspace = try TempWorkspace()
        try await workspace.store.beginSession()
        _ = try await workspace.store.setRetention(.sevenDays)

        let now = Date()
        let collected = try await workspace.store.insert(
            textInsertion("collected long ago", capturedAt: now.addingTimeInterval(-40 * 24 * 60 * 60))
        )
        _ = try await workspace.store.setCollection(true, for: collected.itemID, now: now)
        let whileCollected = try await workspace.store.runCleanup(now: now)
        #expect(whileCollected.removedItemIDs.isEmpty)

        let released = try await workspace.store.setCollection(false, for: collected.itemID, now: now)
        #expect(released.isCollection == false)
        #expect(released.lastCopiedAt == now)

        let rightAfter = try await workspace.store.runCleanup(now: now)
        #expect(rightAfter.removedItemIDs.isEmpty)

        let later = try await workspace.store.runCleanup(now: now.addingTimeInterval(8 * 24 * 60 * 60))
        #expect(later.removedItemIDs == [collected.itemID])
    }

    @Test("A collected card can still be deleted explicitly")
    func explicitDeletion() async throws {
        let workspace = try TempWorkspace()
        try await workspace.store.beginSession()
        let collected = try await workspace.store.insert(textInsertion("collected card"))
        _ = try await workspace.store.setCollection(true, for: collected.itemID)

        let report = try await workspace.store.delete(collected.itemID)
        #expect(report.removedItemIDs == [collected.itemID])
        #expect(try await workspace.store.count(scope: .collection) == 0)
    }
}
