import Foundation
import Testing

@testable import CopilyCore

@Suite("Deduplication")
struct DeduplicationTests {
    @Test("Identical content collapses onto one card")
    func identicalContentCollapses() async throws {
        let workspace = try TempWorkspace()
        try await workspace.store.beginSession()

        let first = try await workspace.store.insert(textInsertion("identical content", origin: .external(changeCount: 1)))
        let second = try await workspace.store.insert(textInsertion("identical content", origin: .external(changeCount: 2)))

        #expect(first.didCreateItem)
        #expect(second.didCreateItem == false)
        #expect(second.itemID == first.itemID)
        let statistics = try await workspace.store.statistics()
        #expect(statistics.itemCount == 1)
    }

    @Test("Formatting differences keep cards apart")
    func formattingDifferencesStaySeparate() async throws {
        let workspace = try TempWorkspace()
        try await workspace.store.beginSession()

        let plain = try await workspace.store.insert(textInsertion("bold heading", origin: .external(changeCount: 1)))
        let rich = try await workspace.store.insert(richTextInsertion("bold heading", origin: .external(changeCount: 2)))

        #expect(rich.didCreateItem)
        #expect(rich.itemID != plain.itemID)
        let statistics = try await workspace.store.statistics()
        #expect(statistics.itemCount == 2)
    }

    @Test("An edited card is never collapsed into")
    func editedCardsArePreserved() async throws {
        let workspace = try TempWorkspace()
        try await workspace.store.beginSession()

        let original = try await workspace.store.insert(textInsertion("greeting to keep", origin: .external(changeCount: 1)))
        let edited = try await workspace.store.edit(.label("Saved greeting"), for: original.itemID)
        #expect(edited.isEdited)

        let capturedAgain = try await workspace.store.insert(
            textInsertion("greeting to keep", origin: .external(changeCount: 2))
        )

        #expect(capturedAgain.didCreateItem)
        #expect(capturedAgain.itemID != original.itemID)
        let preserved = try #require(await workspace.store.summary(for: original.itemID))
        #expect(preserved.isEdited)
        #expect(preserved.label == "Saved greeting")
        let statistics = try await workspace.store.statistics()
        #expect(statistics.itemCount == 2)
    }

    @Test("Collapsing preserves pin state")
    func collapsingPreservesPinState() async throws {
        let workspace = try TempWorkspace()
        try await workspace.store.beginSession()

        let first = try await workspace.store.insert(textInsertion("pinned content", origin: .external(changeCount: 1)))
        let pinned = try await workspace.store.setPinned(true, for: first.itemID)
        #expect(pinned.isPinned)

        let repeated = try await workspace.store.insert(textInsertion("pinned content", origin: .external(changeCount: 2)))

        #expect(repeated.didCreateItem == false)
        #expect(repeated.summary.isPinned)
        let statistics = try await workspace.store.statistics()
        #expect(statistics.itemCount == 1)
        #expect(statistics.pinnedCount == 1)
    }

    @Test("Copily's own copy does not extend retention, an external one does")
    func ownCopyDoesNotExtendRetention() async throws {
        let workspace = try TempWorkspace()
        try await workspace.store.beginSession()

        let captured = Date().addingTimeInterval(-6 * 24 * 60 * 60)
        let item = try await workspace.store.insert(
            textInsertion("copied externally", capturedAt: captured, origin: .external(changeCount: 5))
        )

        let ownCopy = try await workspace.store.insert(
            textInsertion("copied externally", capturedAt: Date(), origin: .copily(itemID: item.itemID, changeCount: 6))
        )
        #expect(ownCopy.didCreateItem == false)

        let afterOwnCopy = try #require(await workspace.store.summary(for: item.itemID))
        #expect(afterOwnCopy.lastCopiedAt == captured)
        let recorded = try #require(await workspace.store.ownCopyState())
        #expect(recorded == OwnCopyState(itemID: item.itemID, changeCount: 6))
        let isOwnCopy = try await workspace.store.isOwnCopy(changeCount: 6)
        #expect(isOwnCopy)
        let isNotOwnCopy = try await workspace.store.isOwnCopy(changeCount: 7)
        #expect(isNotOwnCopy == false)

        let recopied = Date()
        let external = try await workspace.store.insert(
            textInsertion("copied externally", capturedAt: recopied, origin: .external(changeCount: 7))
        )
        #expect(external.didCreateItem == false)
        let refreshed = try #require(await workspace.store.summary(for: item.itemID))
        #expect(refreshed.lastCopiedAt == recopied)
        let statistics = try await workspace.store.statistics()
        #expect(statistics.itemCount == 1)
    }

    @Test("Invalid captures are rejected")
    func invalidCapturesAreRejected() async throws {
        let workspace = try TempWorkspace()

        await #expect(throws: HistoryStoreError.invalidInsertion("a files card needs at least one file reference")) {
            try await workspace.store.insert(
                ClipboardItemInsertion(kind: .files, representations: [], fileReferences: [])
            )
        }
        await #expect(throws: HistoryStoreError.invalidInsertion("a link card needs a URL")) {
            try await workspace.store.insert(
                ClipboardItemInsertion(kind: .link, representations: [])
            )
        }
        await #expect(throws: HistoryStoreError.emptyEdit) {
            try await workspace.store.edit(ClipboardItemEdit(), for: ClipboardItemID())
        }
    }

    @Test("Multi-file copies stay together, different selections stay apart")
    func fileSelections() async throws {
        let workspace = try TempWorkspace()
        try await workspace.store.beginSession()
        let first = try workspace.writeFile("first.txt", contents: "first")
        let second = try workspace.writeFile("second.txt", contents: "second")
        let third = try workspace.writeFile("third.txt", contents: "third")

        let pair = try await workspace.store.insert(fileInsertion([first, second], origin: .external(changeCount: 1)))
        #expect(pair.summary.fileNames == ["first.txt", "second.txt"])

        let repeated = try await workspace.store.insert(fileInsertion([first, second], origin: .external(changeCount: 2)))
        #expect(repeated.didCreateItem == false)
        #expect(repeated.itemID == pair.itemID)

        let triple = try await workspace.store.insert(fileInsertion([first, second, third], origin: .external(changeCount: 3)))
        #expect(triple.didCreateItem)
        #expect(triple.summary.fileCount == 3)

        let statistics = try await workspace.store.statistics()
        #expect(statistics.itemCount == 2)
    }
}
