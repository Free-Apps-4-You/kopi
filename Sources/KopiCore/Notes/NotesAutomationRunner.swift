import Foundation

/// Identity and the cheap properties of one note, without its body.
public struct NotesNoteSummary: Sendable, Hashable {
    public let id: NotesNoteID
    public let folderID: NotesFolderID?
    public let folderName: String?
    public let title: String
    /// `nil` when Notes did not report a date, which the client treats as an external
    /// change it cannot rule out.
    public let modificationDate: Date?
    public let isProtected: Bool
    public let isShared: Bool

    public init(
        id: NotesNoteID,
        folderID: NotesFolderID? = nil,
        folderName: String? = nil,
        title: String,
        modificationDate: Date?,
        isProtected: Bool = false,
        isShared: Bool = false
    ) {
        self.id = id
        self.folderID = folderID
        self.folderName = folderName
        self.title = title
        self.modificationDate = modificationDate
        self.isProtected = isProtected
        self.isShared = isShared
    }
}

/// A note with its text.
public struct NotesNoteContent: Sendable, Hashable {
    public let id: NotesNoteID
    public let plainText: String
    public let bodyHTML: String

    public init(id: NotesNoteID, plainText: String, bodyHTML: String) {
        self.id = id
        self.plainText = plainText
        self.bodyHTML = bodyHTML
    }
}

/// Where a note lives, as far as the caller knows. The folder is a hint: a note can be
/// addressed by its own identifier without one.
public struct NotesNoteLocation: Sendable, Hashable {
    public let id: NotesNoteID
    public let folderID: NotesFolderID?

    public init(id: NotesNoteID, folderID: NotesFolderID? = nil) {
        self.id = id
        self.folderID = folderID
    }
}

/// The work Kopi does against Apple Notes, in Notes' own terms.
///
/// Everything above this protocol — connection state and read-only indexing — belongs
/// to ``NotesAutomationClient``; everything below it is the ScriptingBridge transport.
/// A fake runner stands in for Notes in tests, which is the only way to exercise the
/// automation logic without talking to the real application.
public protocol NotesAutomationRunning: Sendable {
    /// Accounts visible to the scripting interface.
    func accounts() async throws -> [NotesAccount]

    /// Folders of the given accounts. Re-reads them: folders change while Kopi runs.
    func folders(inAccounts accountIDs: [NotesAccountID]) async throws -> [NotesFolder]

    /// Metadata of every note in a folder, in Notes' own order.
    func noteSummaries(in folderID: NotesFolderID) async throws -> [NotesNoteSummary]

    /// Plain text and HTML body of the given notes. Locked notes are never read.
    func noteContents(for notes: [NotesNoteLocation]) async throws -> [NotesNoteContent]

    /// Fresh metadata of one note, including its modification date.
    func noteSummary(for note: NotesNoteLocation) async throws -> NotesNoteSummary

    /// Brings a note up in Apple Notes: its URL when Notes accepts one, otherwise the
    /// note itself, with Notes brought forward.
    func openNote(_ note: NotesNoteLocation) async throws

    /// Forgets cached accounts, folders and specifiers.
    func reset() async
}
