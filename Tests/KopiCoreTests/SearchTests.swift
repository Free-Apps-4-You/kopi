import Foundation
import Testing

@testable import KopiCore

@Suite("Search")
struct SearchTests {
    @Test("URL fragments are found by substring")
    func urlFragments() async throws {
        let workspace = try TempWorkspace()
        try await workspace.store.beginSession()
        let url = "https://example.com/kopi/history?tab=pinned&page=2#anchor"
        let inserted = try await workspace.store.insert(linkInsertion(url))
        _ = try await workspace.store.insert(textInsertion("unrelated snippet about lunch"))

        for fragment in ["example.com/kopi", "/history?tab", "tab=pinned&page=2", "#anchor", "pinned&page"] {
            let page = try await workspace.store.page(HistoryQuery(text: fragment))
            #expect(page.itemIDs == [inserted.itemID], "fragment \(fragment) matched \(page.itemIDs)")
            #expect(page.searchMode == .fullTextIndex)
        }
    }

    @Test("Code fragments and punctuation are found by substring")
    func codeFragments() async throws {
        let workspace = try TempWorkspace()
        try await workspace.store.beginSession()
        let code = "let total = items.reduce(0) { $0 + $1.count }"
        let inserted = try await workspace.store.insert(textInsertion(code))
        _ = try await workspace.store.insert(textInsertion("nothing to do with the snippet"))

        for fragment in ["items.reduce(0)", "{ $0 + $1.count }", "reduce(0) { $0", "total = items"] {
            let page = try await workspace.store.page(HistoryQuery(text: fragment))
            #expect(page.itemIDs == [inserted.itemID], "fragment \(fragment)")
        }
    }

    @Test("Unicode text is searched case insensitively")
    func unicodeSearch() async throws {
        let workspace = try TempWorkspace()
        try await workspace.store.beginSession()
        let german = try await workspace.store.insert(textInsertion("Grüße aus München — naïve café"))
        let japanese = try await workspace.store.insert(textInsertion("日本語のテキストです"))
        _ = try await workspace.store.insert(textInsertion("plain ascii text"))

        let cases: [(String, ClipboardItemID)] = [
            ("München", german.itemID),
            ("münchen", german.itemID),
            ("MÜNCHEN", german.itemID),
            ("üße aus", german.itemID),
            ("Café", german.itemID),
            ("naïve", german.itemID),
            ("語のテキ", japanese.itemID),
            ("テキスト", japanese.itemID)
        ]
        for (query, expected) in cases {
            let page = try await workspace.store.page(HistoryQuery(text: query))
            #expect(page.itemIDs == [expected], "query \(query) matched \(page.itemIDs)")
        }
    }

    @Test("Queries shorter than three characters use the bounded scan")
    func shortQueriesUseScan() async throws {
        let workspace = try TempWorkspace()
        try await workspace.store.beginSession()
        let alpha = try await workspace.store.insert(textInsertion("alpha beta"))
        let gamma = try await workspace.store.insert(textInsertion("gamma delta"))

        let twoCharacters = try await workspace.store.page(HistoryQuery(text: "ga"))
        #expect(twoCharacters.searchMode == .scan)
        #expect(twoCharacters.itemIDs == [gamma.itemID])

        let oneCharacter = try await workspace.store.page(HistoryQuery(text: "a"))
        #expect(oneCharacter.searchMode == .scan)
        #expect(Set(oneCharacter.itemIDs) == [alpha.itemID, gamma.itemID])

        let empty = try await workspace.store.page(HistoryQuery(text: "   "))
        #expect(empty.searchMode == .listing)
        #expect(empty.items.count == 2)
    }

    @Test("Search covers labels and file names")
    func labelsAndFileNames() async throws {
        let workspace = try TempWorkspace()
        try await workspace.store.beginSession()
        let file = try workspace.writeFile("Quarterly Report.txt", contents: "numbers")
        let fileCard = try await workspace.store.insert(fileInsertion([file], label: "Budget figures"))

        let byFileName = try await workspace.store.page(HistoryQuery(text: "Quarterly"))
        #expect(byFileName.itemIDs == [fileCard.itemID])

        let byLabel = try await workspace.store.page(HistoryQuery(text: "Budget"))
        #expect(byLabel.itemIDs == [fileCard.itemID])

        _ = try await workspace.store.edit(.label("Planning spreadsheet"), for: fileCard.itemID)
        let renamed = try await workspace.store.page(HistoryQuery(text: "Planning"))
        #expect(renamed.itemIDs == [fileCard.itemID])
        let oldLabel = try await workspace.store.page(HistoryQuery(text: "Budget"))
        #expect(oldLabel.items.isEmpty)

        let imageBytes = Data(repeating: 9, count: 128)
        let asset = try await workspace.assetStore.importData(imageBytes, kind: .image, fileExtension: "png")
        let imageCard = try await workspace.store.insert(imageInsertion(asset: asset.reference, label: "Screenshot of the panel"))
        let byImageLabel = try await workspace.store.page(HistoryQuery(text: "Screenshot"))
        #expect(byImageLabel.itemIDs == [imageCard.itemID])
    }

    @Test("Wildcards and punctuation are literal characters")
    func wildcardsAreLiteral() async throws {
        let workspace = try TempWorkspace()
        try await workspace.store.beginSession()
        let percent = try await workspace.store.insert(textInsertion("progress 50% complete"))
        let underscore = try await workspace.store.insert(textInsertion("file_name_with_underscores"))
        _ = try await workspace.store.insert(textInsertion("nothing similar"))

        let percentQuery = try await workspace.store.page(HistoryQuery(text: "50% com"))
        #expect(percentQuery.itemIDs == [percent.itemID])

        let underscoreQuery = try await workspace.store.page(HistoryQuery(text: "name_with_under"))
        #expect(underscoreQuery.itemIDs == [underscore.itemID])

        let wildcardOnly = try await workspace.store.page(HistoryQuery(text: "%"))
        #expect(wildcardOnly.searchMode == .scan)
        #expect(wildcardOnly.itemIDs == [percent.itemID])
    }

    @Test("Kind filters and the pinned scope narrow the results")
    func filtersAndScope() async throws {
        let workspace = try TempWorkspace()
        try await workspace.store.beginSession()

        let text = try await workspace.store.insert(textInsertion("filterable text"))
        let rich = try await workspace.store.insert(richTextInsertion("filterable rich text"))
        let link = try await workspace.store.insert(linkInsertion("https://example.org/filterable"))
        let file = try workspace.writeFile("filterable.txt", contents: "x")
        let files = try await workspace.store.insert(fileInsertion([file]))
        _ = try await workspace.store.setPinned(true, for: link.itemID)

        let textFilter = try await workspace.store.page(HistoryQuery(filter: .text))
        #expect(Set(textFilter.itemIDs) == [text.itemID, rich.itemID])

        let linkFilter = try await workspace.store.page(HistoryQuery(filter: .links))
        #expect(linkFilter.itemIDs == [link.itemID])

        let fileFilter = try await workspace.store.page(HistoryQuery(filter: .files))
        #expect(fileFilter.itemIDs == [files.itemID])

        let pinned = try await workspace.store.page(HistoryQuery(text: "filterable", scope: .pinned))
        #expect(pinned.itemIDs == [link.itemID])

        let sortedByPin = try await workspace.store.page(
            HistoryQuery(text: "filterable", sort: .recentlyPinned)
        )
        #expect(sortedByPin.items.first?.id == link.itemID)
    }

    @Test("Indexed text and the trigram index stay in step with edits")
    func indexStaysInStep() async throws {
        let workspace = try TempWorkspace()
        try await workspace.store.beginSession()
        let inserted = try await workspace.store.insert(textInsertion("original indexed sentence"))

        _ = try await workspace.store.edit(.text("replacement indexed sentence"), for: inserted.itemID)

        let updated = try await workspace.store.page(HistoryQuery(text: "replacement"))
        #expect(updated.itemIDs == [inserted.itemID])

        let stale = try await workspace.store.page(HistoryQuery(text: "original"))
        #expect(stale.items.isEmpty)

        let detail = try #require(await workspace.store.detail(for: inserted.itemID))
        #expect(detail.searchText == "replacement indexed sentence")
    }
}

@Suite("Search delivery")
struct SearchDeliveryTests {
    @Test("A superseded request is answered with a stale marker")
    func supersededRequestIsDiscarded() async throws {
        let workspace = try TempWorkspace()
        try await workspace.store.beginSession()
        _ = try await workspace.store.insert(textInsertion("alpha content"))
        _ = try await workspace.store.insert(textInsertion("beta content"))

        let controller = ClipboardSearchController(
            store: workspace.store,
            debounceInterval: .milliseconds(20)
        )
        let first = await controller.submit(HistoryQuery(text: "alpha"))
        let second = await controller.submit(HistoryQuery(text: "beta"))

        let stale = try await controller.results(for: first)
        #expect(stale.isSuperseded)
        #expect(stale.generation == first.generation)
        #expect(stale.items.isEmpty)

        let fresh = try await controller.results(for: second)
        #expect(fresh.isSuperseded == false)
        #expect(fresh.items.count == 1)
        #expect(fresh.generation == second.generation)
    }

    @Test("The newest of many rapid queries wins")
    func newestRapidQueryWins() async throws {
        let workspace = try TempWorkspace()
        try await workspace.store.beginSession()
        for index in 0..<5 {
            _ = try await workspace.store.insert(textInsertion("rapid query sample \(index)"))
        }

        let controller = ClipboardSearchController(store: workspace.store, debounceInterval: .milliseconds(5))
        var tokens: [SearchRequestToken] = []
        for query in ["r", "ra", "rap", "rapi", "rapid"] {
            tokens.append(await controller.submit(HistoryQuery(text: query)))
        }

        for token in tokens.dropLast() {
            let delivery = try await controller.results(for: token)
            #expect(delivery.isSuperseded)
        }
        let last = try #require(tokens.last)
        let delivery = try await controller.results(for: last)
        #expect(delivery.items.count == 5)

        let pending = await controller.pendingRequestCount
        #expect(pending == 0)
    }

    @Test("Cancelling drops everything in flight")
    func cancellingDropsInFlightRequests() async throws {
        let workspace = try TempWorkspace()
        try await workspace.store.beginSession()
        _ = try await workspace.store.insert(textInsertion("cancelled content"))

        let controller = ClipboardSearchController(store: workspace.store)
        let token = await controller.submit(HistoryQuery(text: "cancelled"))
        await controller.cancel()

        let delivery = try await controller.results(for: token)
        #expect(delivery.isSuperseded)
        let pending = await controller.pendingRequestCount
        #expect(pending == 0)
    }

    @Test("Convenience searches answer immediately")
    func convenienceSearch() async throws {
        let workspace = try TempWorkspace()
        try await workspace.store.beginSession()
        _ = try await workspace.store.insert(textInsertion("convenient content"))

        let controller = ClipboardSearchController(store: workspace.store, debounceInterval: .zero)
        let delivery = try await controller.search(HistoryQuery(text: "convenient"))
        #expect(delivery.items.count == 1)
    }

    @Test("Programmatic requests answer without waiting out the typing debounce")
    func programmaticRequestsSkipDebounce() async throws {
        let workspace = try TempWorkspace()
        try await workspace.store.beginSession()
        _ = try await workspace.store.insert(textInsertion("immediate content"))

        // Far longer than the test is willing to wait: answering proves the debounce
        // was skipped rather than merely shortened.
        let controller = ClipboardSearchController(store: workspace.store, debounceInterval: .seconds(5))
        let started = Date()
        let direct = try await controller.search(HistoryQuery(text: "immediate"), debounce: false)
        #expect(direct.items.count == 1)
        #expect(direct.isSuperseded == false)

        let token = await controller.submit(HistoryQuery(text: "immediate"))
        let viaToken = try await controller.results(for: token, debounce: false)
        #expect(viaToken.items.count == 1)

        #expect(Date().timeIntervalSince(started) < 1)
    }
}
