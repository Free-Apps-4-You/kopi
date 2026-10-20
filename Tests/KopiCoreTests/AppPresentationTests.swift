import Foundation
import Testing

@testable import KopiCore

@Suite("Card presentation")
struct CardPresentationTests {
    private var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
        calendar.locale = Locale(identifier: "en_US_POSIX")
        return calendar
    }

    private var now: Date { Date(timeIntervalSince1970: 1_700_000_000) }

    @Test("Card timestamps read as elapsed time, yesterday, then a date")
    func timestamps() {
        let calendar = utc
        #expect(CardTimestamp.description(for: now, now: now, calendar: calendar) == "Just now")
        #expect(CardTimestamp.description(for: now.addingTimeInterval(-59), now: now, calendar: calendar) == "Just now")
        #expect(CardTimestamp.description(for: now.addingTimeInterval(-300), now: now, calendar: calendar) == "5 min ago")
        #expect(CardTimestamp.description(for: now.addingTimeInterval(-3 * 3600), now: now, calendar: calendar) == "3 hr ago")
        #expect(CardTimestamp.description(for: now.addingTimeInterval(-26 * 3600), now: now, calendar: calendar) == "Yesterday")

        let older = CardTimestamp.description(for: now.addingTimeInterval(-40 * 86_400), now: now, calendar: calendar)
        #expect(older.contains("2023"))
        #expect(older.contains("Oct"))

        let detailed = CardTimestamp.detailed(now, calendar: calendar)
        #expect(detailed.contains("2023"))
        #expect(detailed.contains(":") || detailed.contains("AM") || detailed.contains("PM"))
    }

    @Test("Link input normalises what a person types")
    func linkNormalisation() {
        #expect(LinkInput.normalizedURL(from: "example.com/kopi")?.absoluteString == "https://example.com/kopi")
        #expect(LinkInput.normalizedURL(from: "  https://kopi.dev/docs  ")?.absoluteString == "https://kopi.dev/docs")
        #expect(LinkInput.normalizedURL(from: "mailto:kopi@example.com")?.scheme == "mailto")
        #expect(LinkInput.normalizedURL(from: "   ") == nil)
        #expect(LinkInput.normalizedURL(from: "not a url") == nil)
        #expect(LinkInput.normalizedURL(from: "https://") == nil)
        #expect(LinkInput.normalizedURL(from: "://example.com") == nil)
    }

    @Test("Cached absolute formatting still follows the calendar it is given")
    func cachedAbsoluteFormatting() {
        var tokyo = Calendar(identifier: .gregorian)
        tokyo.timeZone = TimeZone(identifier: "Asia/Tokyo") ?? .gmt
        tokyo.locale = Locale(identifier: "en_US_POSIX")

        // Late evening in UTC is already the next day in Tokyo.
        let evening = Date(timeIntervalSince1970: 1_700_004_600)
        let utcDate = CardTimestamp.absolute(evening, calendar: utc)
        let tokyoDate = CardTimestamp.absolute(evening, calendar: tokyo)
        #expect(utcDate != tokyoDate)
        #expect(utcDate.contains("14"))
        #expect(tokyoDate.contains("15"))

        // Repeating the call reuses the cached formatter and returns the same string.
        #expect(CardTimestamp.absolute(evening, calendar: utc) == utcDate)
        #expect(CardTimestamp.detailed(evening, calendar: utc).contains(":"))
    }
}

@Suite("Notes tab states")
struct NotesTabStateTests {
    @Test("Every connection state maps to a distinct Notes tab state")
    func mapping() {
        #expect(NotesTabState(connectionState: .disconnected) == .disconnected)
        #expect(NotesTabState(connectionState: .loading) == .connecting)
        #expect(NotesTabState(connectionState: .permissionDenied) == .permissionDenied)
        #expect(NotesTabState(connectionState: .empty) == .empty)
        #expect(NotesTabState(connectionState: .error("Apple Events failed")) == .error("Apple Events failed"))

        let partial = NotesIndexingProgress(indexedNoteCount: 2, totalNoteCount: 5)
        #expect(NotesTabState(connectionState: .indexing(partial)) == .indexing(partial))
        #expect(NotesTabState(connectionState: .indexing(partial)).indexingProgress == partial)
        #expect(NotesTabState(connectionState: .indexing(partial)).showsNoteList)

        let complete = NotesIndexingProgress(indexedNoteCount: 5, totalNoteCount: 5)
        #expect(NotesTabState(connectionState: .indexing(complete)) == .loaded)
        #expect(NotesTabState(connectionState: .indexing(complete)).isBusy == false)
        #expect(NotesTabState(connectionState: .loading).isBusy)
    }

    @Test("A build without automation reports it explicitly")
    func unavailableOverride() {
        let state = NotesTabState(connectionState: .disconnected, automationUnavailable: "No automation here")
        #expect(state == .unavailable("No automation here"))
        #expect(state.unavailableMessage == "No automation here")
        #expect(state.showsNoteList == false)
        #expect(state.displayName == "Unavailable")
        #expect(state.isBusy == false)
    }

    @Test("A Notes failure leaves clipboard storage untouched")
    func notesFailureIsContained() async throws {
        let workspace = try TempWorkspace()
        try await workspace.store.beginSession()
        _ = try await workspace.store.insert(textInsertion("clipboard content stays put"))

        let runner = FakeNotesRunner.sample()
        await runner.setFailure(.commandFailed("Apple Notes is unavailable"))
        let client = NotesAutomationClient(runner: runner, permission: FixedPermissionChecker(.denied))
        #expect(await client.connectionState == .disconnected)

        var thrown: NotesClientError?
        do {
            _ = try await client.connect()
        } catch let error as NotesClientError {
            thrown = error
        }
        #expect(thrown == .permissionDenied)
        #expect(thrown?.userMessage == NotesClientError.permissionDenied.userMessage)
        #expect(await client.connectionState == .permissionDenied)

        var notesError: NotesClientError?
        do {
            _ = try await client.notes(in: NotesFolderID(rawValue: "folder"), page: NotesPage())
        } catch let error as NotesClientError {
            notesError = error
        }
        #expect(notesError == .notConnected)

        await client.disconnect()
        #expect(await client.connectionState == .disconnected)

        let page = try await workspace.store.page(HistoryQuery())
        #expect(page.items.count == 1)
    }

    @Test("Permission failures are told apart from other Notes errors")
    func permissionFailures() {
        #expect(NotesClientError.permissionDenied.isPermissionFailure)
        #expect(NotesClientError.automationUnavailable("no").isPermissionFailure == false)
        #expect(NotesClientError.notConnected.isPermissionFailure == false)
        #expect(NotesClientError.timedOut.userMessage.contains("did not answer"))
    }
}

@Suite("Loose text copies")
struct LooseTextCopyTests {
    @Test("Copying text that is not a card records Kopi's own generation")
    func ownTextWrite() async throws {
        let harness = try await CaptureHarness()
        await harness.service.start()

        let state = try await harness.service.copyPlainTextToPasteboard("a note body")
        #expect(state.changeCount == harness.pasteboard.changeCount)
        #expect(try await harness.workspace.store.isOwnCopy(changeCount: state.changeCount))

        let requests = harness.pasteboard.writeRequests
        #expect(requests.count == 1)
        #expect(requests.first?.flavours.first?.type == ClipboardRepresentationKind.plainText.pasteboardType)
        #expect(requests.first?.flavours.first?.string == "a note body")

        // Kopi's own write does not become a card.
        let skipped = await harness.service.tick()
        #expect(skipped == .ownCopy(itemID: state.itemID, changeCount: state.changeCount))
        #expect(try await harness.workspace.store.count() == 0)

        // The next external copy still is captured.
        harness.pasteboard.copyText("copied elsewhere")
        let captured = await harness.service.tick()
        #expect(captured.insertionResult?.didCreateItem == true)
        #expect(try await harness.workspace.store.count() == 1)
    }
}
