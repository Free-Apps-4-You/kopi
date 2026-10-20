import Foundation
import GRDB
import Testing

@testable import KopiCore

@Suite("History store persistence")
struct HistoryStorePersistenceTests {
    @Test("Pinned and edited content survives a relaunch after a force quit")
    func pinnedAndEditedContentSurvivesRelaunch() async throws {
        let workspace = try TempWorkspace()
        try await workspace.store.beginSession()

        let original = "Draft of the release note"
        let inserted = try await workspace.store.insert(textInsertion(original))
        _ = try await workspace.store.setPinned(true, for: inserted.itemID)

        let edited = try await workspace.store.edit(
            ClipboardItemEdit(label: "Release note", plainText: "Final release note text"),
            for: inserted.itemID
        )
        #expect(edited.label == "Release note")
        #expect(edited.isPinned)
        #expect(edited.isEdited)

        // No endSession: the process is gone as if it had been force quit.
        let relaunched = try workspace.reopenStore()

        let detail = try #require(await relaunched.detail(for: inserted.itemID))
        #expect(detail.summary.isPinned)
        #expect(detail.summary.isEdited)
        #expect(detail.summary.label == "Release note")
        #expect(detail.plainText == "Final release note text")
        #expect(detail.representations.count == 1)

        let newText = try await relaunched.page(HistoryQuery(text: "Final release"))
        #expect(newText.itemIDs == [inserted.itemID])

        let oldText = try await relaunched.page(HistoryQuery(text: "Draft of the release"))
        #expect(oldText.items.isEmpty)

        let pinned = try await relaunched.page(HistoryQuery(scope: .pinned))
        #expect(pinned.itemIDs == [inserted.itemID])
    }

    @Test("The database runs in WAL mode with fully synchronous commits")
    func durabilitySettingsAreApplied() async throws {
        let workspace = try TempWorkspace()
        let diagnostics = try await workspace.store.diagnostics()

        #expect(diagnostics.isWriteAheadLogging)
        #expect(diagnostics.isFullySynchronous)
        #expect(diagnostics.foreignKeysEnabled)
        #expect(FileManager.default.fileExists(atPath: workspace.databasePath))
    }

    @Test("Uncommitted changes never appear, and commits are visible to a second store")
    func commitsAreVisibleToSecondStore() async throws {
        let workspace = try TempWorkspace()
        try await workspace.store.beginSession()
        let inserted = try await workspace.store.insert(textInsertion("shared across connections"))

        let second = try workspace.reopenStore()
        let detail = try #require(await second.detail(for: inserted.itemID))
        #expect(detail.plainText == "shared across connections")
    }

    @Test("Deleting a card removes it from every view")
    func deletionRemovesCard() async throws {
        let workspace = try TempWorkspace()
        try await workspace.store.beginSession()
        let inserted = try await workspace.store.insert(textInsertion("temporary"))

        let report = try await workspace.store.delete(inserted.itemID)
        #expect(report.removedItemIDs == [inserted.itemID])
        let deleted = try await workspace.store.detail(for: inserted.itemID)
        #expect(deleted == nil)
        let remaining = try await workspace.store.page(HistoryQuery(text: "temporary"))
        #expect(remaining.items.isEmpty)
        let statistics = try await workspace.store.statistics()
        #expect(statistics.itemCount == 0)
    }

    @Test("A card missing from the store is reported as such")
    func missingCardIsReported() async throws {
        let workspace = try TempWorkspace()
        let missing = ClipboardItemID()
        await #expect(throws: HistoryStoreError.itemNotFound(missing)) {
            try await workspace.store.edit(.text("hello"), for: missing)
        }
        await #expect(throws: HistoryStoreError.itemNotFound(missing)) {
            try await workspace.store.setPinned(true, for: missing)
        }
    }

    @Test("Card snapshots and details describe the stored content")
    func snapshotsDescribeContent() async throws {
        let workspace = try TempWorkspace()
        try await workspace.store.beginSession()
        let url = "https://developer.apple.com/documentation/appkit/nspasteboard"
        let inserted = try await workspace.store.insert(
            linkInsertion(url, label: "Pasteboard access")
        )

        let summary = try #require(await workspace.store.summary(for: inserted.itemID))
        #expect(summary.kind == .link)
        #expect(summary.domain == "developer.apple.com")
        #expect(summary.label == "Pasteboard access")
        #expect(summary.displayTitle == "Pasteboard access")
        #expect(summary.fileCount == 0)

        let detail = try #require(await workspace.store.detail(for: inserted.itemID))
        #expect(detail.primaryURLText == url)
        #expect(detail.representation(.link)?.text == url)
        #expect(detail.isContentEditable)
        #expect(detail.searchText.contains("developer.apple.com"))
    }
}

extension ClipboardItemDetail {
    var primaryURLText: String? {
        representation(.link)?.text
    }
}
