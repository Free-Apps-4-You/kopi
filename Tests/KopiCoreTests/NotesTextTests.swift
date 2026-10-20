import Foundation
import Testing

@testable import KopiCore

/// Counts attempts made from a `@Sendable` handler.
final class AttemptCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func next() -> Int {
        lock.withLock {
            value += 1
            return value
        }
    }
}

@Suite("Notes text")
struct NotesTextTests {
    @Test("A title and a body compose into the text Notes stores")
    func composesTitleAndBody() {
        #expect(NotesNoteText.compose(title: "Shopping", body: "Milk\nBread") == "Shopping\n\nMilk\nBread")
        #expect(NotesNoteText.compose(title: "Shopping", body: "") == "Shopping")
        #expect(NotesNoteText.compose(title: "", body: "Just a body") == "Just a body")
        #expect(NotesNoteText.compose(title: "  ", body: "  ") == "")
    }

    @Test("The body of a note is its text without the title line")
    func splitsBodyFromTitle() {
        #expect(NotesNoteText.body(fromPlainText: "Shopping\n\nMilk\nBread", title: "Shopping") == "Milk\nBread")
        #expect(NotesNoteText.body(fromPlainText: "Shopping", title: "Shopping") == "")
        #expect(NotesNoteText.body(fromPlainText: "Something else\n\nBody", title: "Shopping") == "Something else\n\nBody")
        #expect(NotesNoteText.body(fromPlainText: "Shopping\r\n\r\nMilk", title: "Shopping") == "Milk")
    }

    @Test("A composed note reads back as the same title and body")
    func compositionRoundTrip() {
        let text = NotesNoteText.compose(title: "Trip", body: "Pack\nLeave early")
        let title = text.components(separatedBy: "\n").first ?? ""
        #expect(title == "Trip")
        #expect(NotesNoteText.body(fromPlainText: text, title: title) == "Pack\nLeave early")
    }

    @Test("Excerpts are one line of readable text")
    func excerpts() {
        #expect(NotesNoteText.excerpt(fromPlainText: "  First\n\nSecond   line ") == "First Second line")
        let long = String(repeating: "a", count: 300)
        let excerpt = NotesNoteText.excerpt(fromPlainText: long, limit: 220)
        #expect(excerpt.count == 221)
        #expect(excerpt.hasSuffix("…"))
    }
}

@Suite("Notes compatibility")
struct NotesCompatibilityTests {
    private func check(_ html: String, plainText: String = "Hello World") -> NotesBodyCompatibility {
        NotesTextCompatibility.check(bodyHTML: html, plainText: plainText)
    }

    @Test("Plain paragraphs pass the text-only check")
    func plainNoteIsEditable() {
        #expect(check(NotesFixtures.simpleHTML) == .textOnly)
        #expect(check("<body><div><span class=\"Apple-converted-space\"> </span>Hello World</div></body>") == .textOnly)
        #expect(check("<body>Hello<br>World</body>") == .textOnly)
    }

    @Test("Formatting Kopi would drop opens the note in Apple Notes")
    func formattingIsRich() {
        #expect(check("<body><div style=\"font-size:14px\">Hello World</div></body>") == .rich(.formatting("style")))
        #expect(check("<body><span class=\"Apple-style-span\">Hello World</span></body>") == .rich(.formatting("class")))
        #expect(check("<body><font face=\"Helvetica\">Hello World</font></body>") == .rich(.unknownMarkup("font")))
    }

    @Test("Lists, tables and links are content Kopi does not edit as text")
    func structuredContentIsRich() {
        #expect(check("<body><ul><li>Hello World</li></ul></body>") == .rich(.lists))
        #expect(check("<body><table><tr><td>Hello World</td></tr></table></body>") == .rich(.tables))
        #expect(check("<body><a href=\"https://kopi.dev\">Hello World</a></body>") == .rich(.links))
    }

    @Test("Attachments are counted and keep the note out of the editor")
    func attachmentsAreRich() {
        let inspection = NotesTextCompatibility.inspect(
            bodyHTML: "<body><div>Hello World</div><img src=\"data:image/png;base64,AAA\"><object type=\"attachment\"></object></body>"
        )
        #expect(inspection.attachmentCount == 2)
        #expect(inspection.hasRichContent)
        #expect(inspection.compatibility == .rich(.attachments(2)))
    }

    @Test("Markup whose text does not match the note's plain text is not edited")
    func textMismatchIsRich() {
        let compatibility = NotesTextCompatibility.check(
            bodyHTML: "<body><div>Hello World</div><div>Hidden</div></body>",
            plainText: "Hello World"
        )
        #expect(compatibility == .rich(.textMismatch))
    }

    @Test("Rich content describes itself for the queued message")
    func reasonsDescribeThemselves() {
        #expect(NotesRichContent.attachments(1).displayName.contains("1 attachment"))
        #expect(NotesRichContent.tables.displayName.contains("a table"))
        #expect(NotesRichContent.formatting("style").description == "formatting (style)")
    }
}

@Suite("Notes folder selection")
struct NotesFolderSelectionTests {
    private var folders: [NotesFolder] {
        [
            NotesFolder(id: NotesFixtures.folderID, accountID: NotesFixtures.accountID, name: "Notes", isDefault: true),
            NotesFolder(id: NotesFixtures.otherFolderID, accountID: NotesFixtures.accountID, name: "Work")
        ]
    }

    @Test("The default folder is read until the user chooses")
    func defaultFolderUntilChosen() {
        var selection = NotesFolderSelection()
        #expect(selection.isEmpty)
        #expect(selection.isIncluded(folders[0], among: folders))
        #expect(selection.isIncluded(folders[1], among: folders) == false)
        #expect(selection.effectiveFolders(from: folders).map(\.id) == [NotesFixtures.folderID])

        selection.setIncluded(true, for: NotesFixtures.otherFolderID)
        #expect(selection.isIncluded(folders[0], among: folders) == false)
        #expect(selection.isIncluded(folders[1], among: folders))
        #expect(selection.effectiveFolders(from: folders).map(\.id) == [NotesFixtures.otherFolderID])
    }

    @Test("Excluding the last folder explicitly selects no folders")
    func excludingEverythingStaysEmpty() {
        var selection = NotesFolderSelection(includedFolderIDs: [NotesFixtures.otherFolderID])
        selection.setIncluded(false, for: NotesFixtures.otherFolderID)
        #expect(selection.isEmpty)
        #expect(selection.effectiveFolders(from: folders).isEmpty)
        #expect(!selection.isIncluded(folders[0], among: folders))
        #expect(!selection.isIncluded(folders[1], among: folders))
    }

    @Test("Folders without a default fall back to the first one")
    func noDefaultFolder() {
        let plain = [NotesFolder(id: NotesFixtures.otherFolderID, accountID: NotesFixtures.accountID, name: "Work")]
        let selection = NotesFolderSelection()
        #expect(selection.effectiveFolders(from: plain).map(\.id) == [NotesFixtures.otherFolderID])
    }

    @Test("Folder identifiers that no longer exist are dropped")
    func resolvesIdentifiers() {
        let selection = NotesFolderSelection(includedFolderIDs: [NotesFixtures.folderID, NotesFixtures.otherFolderID])
        let available = [NotesFolder(id: NotesFixtures.folderID, accountID: NotesFixtures.accountID, name: "Notes")]
        #expect(selection.resolvedIDs(among: available) == [NotesFixtures.folderID])
    }
}

@Suite("Notes draft session")
struct NotesDraftSessionTests {
    @Test("An edit starts from the note's title and the rest of its text")
    func editSplitsTheNote() {
        let session = NotesNoteDraftSession(editing: NotesFixtures.note(1, text: "Note 1\n\nBody 1"))
        #expect(session.isNew == false)
        #expect(session.noteID == NotesFixtures.noteID(1))
        #expect(session.title == "Note 1")
        #expect(session.body == "Body 1")
        #expect(session.baseModificationDate == NotesFixtures.baseDate)
        #expect(session.draft.noteID == NotesFixtures.noteID(1))
    }

    @Test("An external change keeps the draft and offers a new note")
    func conflictKeepsText() {
        var session = NotesNoteDraftSession(editing: NotesFixtures.note(1))
        session.title = "Edited title"
        session.body = "Edited body"

        let current = NotesNoteMetadata(
            id: NotesFixtures.noteID(1),
            folderID: NotesFixtures.folderID,
            title: "Changed elsewhere",
            excerpt: "",
            modificationDate: NotesFixtures.baseDate.addingTimeInterval(600)
        )
        session.markConflict(with: current)

        #expect(session.hasConflict)
        #expect(session.conflict?.title == "Changed elsewhere")
        #expect(session.title == "Edited title")
        #expect(session.body == "Edited body")
        #expect(session.errorMessage == NotesNoteDraftSession.conflictMessage)
        #expect(session.newNoteDraft.isNew)
        #expect(session.newNoteDraft.body == "Edited body")
    }

    @Test("Reload takes the note as Apple Notes has it now")
    func reloadReplacesTheDraft() {
        var session = NotesNoteDraftSession(editing: NotesFixtures.note(1))
        session.markConflict(with: NotesNoteMetadata(
            id: NotesFixtures.noteID(1),
            folderID: NotesFixtures.folderID,
            title: "Changed elsewhere",
            excerpt: "",
            modificationDate: NotesFixtures.baseDate.addingTimeInterval(600)
        ))

        let reloaded = NotesNote(
            metadata: NotesNoteMetadata(
                id: NotesFixtures.noteID(1),
                folderID: NotesFixtures.folderID,
                title: "Changed elsewhere",
                excerpt: "New text",
                modificationDate: NotesFixtures.baseDate.addingTimeInterval(600)
            ),
            bodyHTML: "<div>New text</div>",
            plainText: "Changed elsewhere\n\nNew text"
        )
        session.reload(with: reloaded)

        #expect(session.hasConflict == false)
        #expect(session.title == "Changed elsewhere")
        #expect(session.body == "New text")
        #expect(session.errorMessage == nil)
    }

    @Test("A saved outcome updates the base date and a conflict does not")
    func appliesOutcomes() {
        var session = NotesNoteDraftSession(editing: NotesFixtures.note(1))
        let saved = NotesNoteMetadata(
            id: NotesFixtures.noteID(1),
            folderID: NotesFixtures.folderID,
            title: "Note 1",
            excerpt: "",
            modificationDate: NotesFixtures.baseDate.addingTimeInterval(120)
        )
        #expect(session.apply(.saved(saved)) == saved)
        #expect(session.baseModificationDate == saved.modificationDate)

        let outcome = NotesSaveOutcome.conflict(current: saved, draft: session.draft)
        #expect(session.apply(outcome) == nil)
        #expect(session.hasConflict)
    }

    @Test("A new note starts empty and can be saved as a note of its own")
    func createSession() {
        var session = NotesNoteDraftSession(createIn: NotesFixtures.folderID)
        #expect(session.isNew)
        #expect(session.draft.isNew)
        session.title = "Shopping"
        session.body = "Milk"
        #expect(session.newNoteDraft.folderID == NotesFixtures.folderID)
        #expect(session.newNoteDraft.baseModificationDate == nil)
    }
}
