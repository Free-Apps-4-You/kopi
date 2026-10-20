import Foundation
import Testing

@testable import CopilyCore

@Suite("Pagination")
struct PaginationTests {
    @Test("Cards are fetched 60 per page")
    func sixtyItemsPerPage() async throws {
        let workspace = try TempWorkspace()
        try await workspace.store.beginSession()

        var insertedIDs: [ClipboardItemID] = []
        for index in 0..<130 {
            let insertion = textInsertion(
                "clipboard sample number \(index)",
                capturedAt: Date().addingTimeInterval(TimeInterval(index)),
                origin: .external(changeCount: index)
            )
            let result = try await workspace.store.insert(insertion)
            insertedIDs.append(result.itemID)
        }

        let first = try await workspace.store.page(HistoryQuery())
        #expect(first.items.count == 60)
        #expect(first.page.limit == HistoryPage.defaultLimit)
        #expect(first.totalCount == 130)
        #expect(first.hasMore)
        #expect(first.nextPage == HistoryPage(offset: 60, limit: 60))
        #expect(first.items.first?.id == insertedIDs.last)

        let secondPage = try #require(first.nextPage)
        let second = try await workspace.store.page(HistoryQuery(page: secondPage))
        #expect(second.items.count == 60)
        #expect(second.hasMore)

        let thirdPage = try #require(second.nextPage)
        let third = try await workspace.store.page(HistoryQuery(page: thirdPage))
        #expect(third.items.count == 10)
        #expect(third.hasMore == false)
        #expect(third.nextPage == nil)

        let allIDs = first.itemIDs + second.itemIDs + third.itemIDs
        #expect(Set(allIDs).count == 130)
        #expect(Set(allIDs) == Set(insertedIDs))
    }

    @Test("Search results page with the same size")
    func searchingPages() async throws {
        let workspace = try TempWorkspace()
        try await workspace.store.beginSession()

        for index in 0..<70 {
            _ = try await workspace.store.insert(
                textInsertion("searchable needle \(index)", origin: .external(changeCount: index))
            )
        }
        for index in 0..<20 {
            _ = try await workspace.store.insert(
                textInsertion("unrelated haystack \(index)", origin: .external(changeCount: 100 + index))
            )
        }

        let first = try await workspace.store.page(HistoryQuery(text: "needle"))
        #expect(first.items.count == 60)
        #expect(first.totalCount == 70)
        #expect(first.searchMode == .fullTextIndex)

        let secondPage = try #require(first.nextPage)
        let second = try await workspace.store.page(HistoryQuery(text: "needle", page: secondPage))
        #expect(second.items.count == 10)
        #expect(second.hasMore == false)
        #expect(Set(first.itemIDs).isDisjoint(with: Set(second.itemIDs)))
    }

    @Test("Pinned cards page independently of ordinary history")
    func pinnedPages() async throws {
        let workspace = try TempWorkspace()
        try await workspace.store.beginSession()

        for index in 0..<8 {
            let inserted = try await workspace.store.insert(
                textInsertion("pinned sample \(index)", origin: .external(changeCount: index))
            )
            _ = try await workspace.store.setPinned(true, for: inserted.itemID, now: Date().addingTimeInterval(TimeInterval(index)))
        }
        for index in 0..<4 {
            _ = try await workspace.store.insert(
                textInsertion("ordinary sample \(index)", origin: .external(changeCount: 50 + index))
            )
        }

        let pinned = try await workspace.store.page(HistoryQuery(scope: .pinned, sort: .recentlyPinned))
        #expect(pinned.items.count == 8)
        let allPinned = pinned.items.allSatisfy(\.isPinned)
        #expect(allPinned)

        let everything = try await workspace.store.page(HistoryQuery(sort: .recentlyPinned))
        #expect(everything.items.count == 12)
        let leadingArePinned = everything.items.prefix(8).allSatisfy(\.isPinned)
        let trailingAreUnpinned = everything.items.suffix(4).allSatisfy { !$0.isPinned }
        #expect(leadingArePinned)
        #expect(trailingAreUnpinned)

        let counts = try await workspace.store.count(scope: .pinned)
        #expect(counts == 8)
        let allCounts = try await workspace.store.count()
        #expect(allCounts == 12)
    }

    @Test("An offset past the end returns an empty page")
    func offsetPastEnd() async throws {
        let workspace = try TempWorkspace()
        try await workspace.store.beginSession()
        _ = try await workspace.store.insert(textInsertion("only card"))

        let page = try await workspace.store.page(HistoryQuery(page: HistoryPage(offset: 500, limit: 60)))
        #expect(page.items.isEmpty)
        #expect(page.totalCount == 1)
        #expect(page.hasMore == false)
    }
}
