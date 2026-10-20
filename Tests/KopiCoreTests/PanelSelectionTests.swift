import Foundation
import Testing

@testable import KopiCore

@Suite("Panel sections and sources")
struct PanelSelectionTests {
    @Test("The main row maps to the kind filters, and Notes has none")
    func sectionFilters() {
        #expect(PanelSection.allCases.map(\.displayName) == ["All", "Text", "Links", "Images", "Files", "Notes", "Passwords"])
        #expect(PanelSection.all.clipboardFilter == .all)
        #expect(PanelSection.text.clipboardFilter == .text)
        #expect(PanelSection.links.clipboardFilter == .links)
        #expect(PanelSection.images.clipboardFilter == .images)
        #expect(PanelSection.files.clipboardFilter == .files)
        #expect(PanelSection.notes.clipboardFilter == nil)
        #expect(PanelSection.notes.showsClipboardCards == false)
        #expect(PanelSection.all.showsClipboardCards)
    }

    @Test("All without a source is plain history, newest copy first")
    func plainHistoryQuery() {
        let selection = PanelSelection(section: .all)
        #expect(selection.scope == .allClipboard)
        #expect(selection.filter == .all)
        #expect(selection.sort == .recentlyCopied)
        #expect(
            selection.query(text: "report")
                == HistoryQuery(text: "report", scope: .allClipboard, kinds: [], sort: .recentlyCopied)
        )
    }

    @Test("A kind and a source combine into one query")
    func kindAndSource() {
        let textPinned = PanelSelection(section: .text, source: .pinned)
        #expect(textPinned.scope == .pinned)
        #expect(textPinned.filter == .text)
        #expect(textPinned.sort == .recentlyPinned)
        #expect(
            textPinned.query()
                == HistoryQuery(scope: .pinned, kinds: [.text, .richText], sort: .recentlyPinned)
        )

        let everythingCollected = PanelSelection(section: .all, source: .collection)
        #expect(everythingCollected.scope == .collection)
        #expect(
            everythingCollected.query()
                == HistoryQuery(scope: .collection, kinds: [], sort: .recentlyCopied)
        )

        let filesPinned = PanelSelection(section: .files, source: .pinned).query()
        #expect(filesPinned?.kinds == [.files])
        #expect(filesPinned?.scope == .pinned)

        let linksInHistory = PanelSelection(section: .links).query()
        #expect(linksInHistory?.kinds == [.link])
        #expect(linksInHistory?.scope == .allClipboard)
    }

    @Test("Notes never asks the store for cards")
    func notesHasNoQuery() {
        #expect(PanelSelection(section: .notes).scope == nil)
        #expect(PanelSelection(section: .notes, source: .pinned).scope == nil)
        #expect(PanelSelection(section: .notes).query() == nil)
        #expect(PanelSelection(section: .notes, source: .collection).query() == nil)
    }

    @Test("The sub row selects a scope; neither chip means history")
    func sourceScopes() {
        #expect(PanelSource.allCases.map(\.displayName) == ["Pinned", "Collection"])
        #expect(PanelSource.pinned.scope == .pinned)
        #expect(PanelSource.collection.scope == .collection)
        #expect(PanelSource(scope: .allClipboard) == nil)
        #expect(PanelSource(scope: .pinned) == .pinned)
        #expect(PanelSource(scope: .collection) == .collection)
    }

    @Test("A page keeps its offset and text when it is asked for")
    func paging() {
        let query = PanelSelection(section: .links, source: .collection)
            .query(text: "kopi", page: HistoryPage(offset: 60, limit: 60))
        #expect(
            query
                == HistoryQuery(
                    text: "kopi",
                    scope: .collection,
                    kinds: [.link],
                    sort: .recentlyCopied,
                    page: HistoryPage(offset: 60, limit: 60)
                )
        )
    }
}
