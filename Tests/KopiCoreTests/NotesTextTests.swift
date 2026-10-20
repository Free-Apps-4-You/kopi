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
        NotesTextCompatibility.inspect(bodyHTML: html).compatibility
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
        #expect(selection.isIncluded(folders[1], among: folders))
        #expect(selection.effectiveFolders(from: folders).map(\.id) == folders.map(\.id))

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
