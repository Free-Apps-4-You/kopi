import Foundation

/// A note being written in Copily: a new note, or an edit of an existing one.
///
/// The draft keeps the text the user typed across the two things that can go wrong
/// while it is open: a failed save, and a note that changed in Apple Notes. An
/// external change never overwrites the note: the draft is kept and the caller offers
/// Reload or Save as New Note.
public struct NotesNoteDraftSession: Sendable, Equatable {
    public enum Mode: Sendable, Equatable {
        case create
        case edit(NotesNoteID)

        public var noteID: NotesNoteID? {
            if case .edit(let id) = self { return id }
            return nil
        }
    }

    /// Message shown when Apple Notes has a newer version of the note.
    public static let conflictMessage = "This note changed in Apple Notes. Reload it, or save your text as a new note."

    public private(set) var mode: Mode
    public var title: String
    public var body: String
    public var folderID: NotesFolderID?
    /// Modification date the draft was based on, used to detect an external change.
    public private(set) var baseModificationDate: Date?
    /// The note as Apple Notes has it now, when the draft is out of date.
    public private(set) var conflict: NotesNoteMetadata?
    public private(set) var errorMessage: String?

    public init(createIn folderID: NotesFolderID?) {
        self.mode = .create
        self.title = ""
        self.body = ""
        self.folderID = folderID
        self.baseModificationDate = nil
    }

    /// An edit of a note Copily has just read. The note's first line is its title, so
    /// the editor shows the text after it.
    public init(editing note: NotesNote, folderID: NotesFolderID? = nil) {
        self.mode = .edit(note.id)
        self.title = note.metadata.title
        self.body = NotesNoteText.body(fromPlainText: note.plainText, title: note.metadata.title)
        self.folderID = folderID ?? note.metadata.folderID
        self.baseModificationDate = note.metadata.modificationDate
    }

    public var isNew: Bool { mode == .create }

    public var noteID: NotesNoteID? { mode.noteID }

    public var hasConflict: Bool { conflict != nil }

    /// The draft to save, which the client checks against the note's modification date
    /// before it writes anything.
    public var draft: NotesNoteDraft {
        NotesNoteDraft(
            noteID: noteID,
            title: title,
            body: body,
            folderID: folderID,
            baseModificationDate: baseModificationDate
        )
    }

    /// The draft that saves this text beside the note instead of over it.
    public var newNoteDraft: NotesNoteDraft {
        NotesNoteDraft(noteID: nil, title: title, body: body, folderID: folderID)
    }

    /// Records that the note changed in Apple Notes, keeping the text as it stands.
    public mutating func markConflict(with current: NotesNoteMetadata) {
        conflict = current
        errorMessage = Self.conflictMessage
    }

    /// Takes the note as Apple Notes has it now and drops the conflict.
    public mutating func reload(with note: NotesNote) {
        mode = .edit(note.id)
        title = note.metadata.title
        body = NotesNoteText.body(fromPlainText: note.plainText, title: note.metadata.title)
        folderID = note.metadata.folderID
        baseModificationDate = note.metadata.modificationDate
        conflict = nil
        errorMessage = nil
    }

    /// Applies what a save returned, returning the saved metadata when it went through.
    @discardableResult
    public mutating func apply(_ outcome: NotesSaveOutcome) -> NotesNoteMetadata? {
        switch outcome {
        case .saved(let metadata):
            baseModificationDate = metadata.modificationDate
            conflict = nil
            errorMessage = nil
            return metadata
        case .conflict(let current, _):
            markConflict(with: current)
            return nil
        }
    }

    public mutating func setError(_ message: String?) {
        errorMessage = message
    }

    /// Starts the save again after a failure cleared the error.
    public mutating func beginSaving() {
        errorMessage = nil
    }
}
