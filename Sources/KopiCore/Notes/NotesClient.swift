import Foundation

/// Access to Apple Notes through Apple Events.
///
/// The protocol is deliberately value-typed: implementations run automation on
/// their own serial worker and hand back immutable snapshots. Views never see
/// scripting objects, database records or note bodies.
public protocol NotesClient: Sendable {
    /// Current connection state, as shown by the Notes tab.
    var connectionState: NotesConnectionState { get async }

    /// Requests automation permission and loads accounts. Called only after the
    /// user selects Connect Apple Notes.
    @discardableResult
    func connect() async throws -> [NotesAccount]

    /// Forgets the connection; the next connect requests permission again.
    func disconnect() async

    /// Accounts visible to the automation interface.
    func accounts() async throws -> [NotesAccount]

    /// Folders of the given accounts. Pass `nil` for every connected account.
    func folders(inAccounts accountIDs: [NotesAccountID]?) async throws -> [NotesFolder]

    /// Restricts indexing to the given folders. An empty set means the default folder
    /// of the connected accounts.
    func setIncludedFolders(_ folderIDs: Set<NotesFolderID>) async

    /// Note metadata, fetched before bodies so cards can appear immediately.
    func notes(in folderID: NotesFolderID, page: NotesPage) async throws -> [NotesNoteMetadata]

    /// Searches full indexed note text, not just the short excerpt shown on a card.
    func searchNotes(_ query: String, in folderIDs: Set<NotesFolderID>) async throws -> [NotesNoteMetadata]

    /// Bodies of the given notes, in bounded batches.
    func notes(withIDs noteIDs: [NotesNoteID]) async throws -> [NotesNote]

    /// Re-reads metadata and reports indexing progress.
    func refresh() async throws -> NotesIndexingProgress

    /// Re-reads metadata, indexes changed note bodies in bounded batches and calls
    /// `progress` after every batch, so the tab can show indexing coverage.
    func refresh(progress: @escaping @Sendable (NotesIndexingProgress) -> Void) async throws -> NotesIndexingProgress

    /// Creates a note and returns its metadata.
    func createNote(_ draft: NotesNoteDraft) async throws -> NotesNoteMetadata

    /// Saves an existing note. Implementations must re-read the modification date
    /// first and return `.conflict` rather than overwriting an external change.
    func save(_ draft: NotesNoteDraft) async throws -> NotesSaveOutcome

    /// Brings the note up in Apple Notes, for rich, shared or protected content.
    func openInNotes(id: NotesNoteID) async throws
}

public extension NotesClient {
    /// Clients that have no progress to report still serve the progress-taking call.
    func refresh(progress: @escaping @Sendable (NotesIndexingProgress) -> Void) async throws -> NotesIndexingProgress {
        try await refresh()
    }
}
