import Foundation
import KopiCore

/// A scripted Apple Notes client for the showcase renderer.
///
/// The real client drives Apple Notes through Apple Events, which would ask for
/// automation permission and read the user's own notes. The showcase only needs
/// believable note cards, so this client answers with a fixed set of sample notes
/// and never touches the Notes app.
struct ShowcaseNotesClient: NotesClient {
    private let account = NotesAccount(id: NotesAccountID(rawValue: "showcase-iCloud"), name: "iCloud", isDefault: true)
    private let localAccount = NotesAccount(id: NotesAccountID(rawValue: "showcase-local"), name: "On My Mac")
    private let folder = NotesFolder(id: NotesFolderID(rawValue: "showcase-notes"),
                                     accountID: NotesAccountID(rawValue: "showcase-iCloud"),
                                     name: "Notes", isDefault: true, noteCount: 3)
    private let localFolder = NotesFolder(id: NotesFolderID(rawValue: "showcase-local-notes"),
                                          accountID: NotesAccountID(rawValue: "showcase-local"),
                                          name: "Reading", isDefault: false, noteCount: 1)

    private var notes: [NotesNote] {
        [
            NotesNote(
                metadata: NotesNoteMetadata(
                    id: NotesNoteID(rawValue: "note-release"),
                    folderID: folder.id,
                    folderName: folder.name,
                    title: "Release checklist",
                    excerpt: "Tag the release, verify the DMG, write the notes.",
                    modificationDate: Date().addingTimeInterval(-600),
                    hasRichContent: true,
                    attachmentCount: 1
                ),
                bodyHTML: "<h1>Release checklist</h1>",
                plainText: "Release checklist\n\nTag the release, verify the DMG, write the notes."
            ),
            NotesNote(
                metadata: NotesNoteMetadata(
                    id: NotesNoteID(rawValue: "note-ideas"),
                    folderID: folder.id,
                    folderName: folder.name,
                    title: "Ideas worth keeping",
                    excerpt: "A clipboard that shows what you copied, keeps what matters, and stays out of the way.",
                    modificationDate: Date().addingTimeInterval(-4_200)
                ),
                bodyHTML: "<p>A clipboard that shows what you copied, keeps what matters, and stays out of the way.</p>",
                plainText: "A clipboard that shows what you copied, keeps what matters, and stays out of the way."
            ),
            NotesNote(
                metadata: NotesNoteMetadata(
                    id: NotesNoteID(rawValue: "note-snippets"),
                    folderID: folder.id,
                    folderName: folder.name,
                    title: "Snippets",
                    excerpt: "swift build --configuration release --product Kopi",
                    modificationDate: Date().addingTimeInterval(-86_000)
                ),
                bodyHTML: "<p>swift build --configuration release --product Kopi</p>",
                plainText: "swift build --configuration release --product Kopi"
            ),
            NotesNote(
                metadata: NotesNoteMetadata(
                    id: NotesNoteID(rawValue: "note-reading"),
                    folderID: localFolder.id,
                    folderName: localFolder.name,
                    title: "Reading list",
                    excerpt: "On My Mac notes stay on this Mac.",
                    modificationDate: Date().addingTimeInterval(-172_800)
                ),
                bodyHTML: "<p>On My Mac notes stay on this Mac.</p>",
                plainText: "On My Mac notes stay on this Mac."
            )
        ]
    }

    var connectionState: NotesConnectionState {
        .indexing(NotesIndexingProgress(indexedNoteCount: notes.count, totalNoteCount: notes.count))
    }

    func connect() async throws -> [NotesAccount] {
        [account, localAccount]
    }

    func disconnect() async {}

    func accounts() async throws -> [NotesAccount] {
        [account, localAccount]
    }

    func folders(inAccounts accountIDs: [NotesAccountID]?) async throws -> [NotesFolder] {
        let all = [folder, localFolder]
        guard let accountIDs else { return all }
        let wanted = Set(accountIDs)
        return all.filter { wanted.contains($0.accountID) }
    }

    func setIncludedFolders(_ folderIDs: Set<NotesFolderID>?) async {}

    func notes(in folderID: NotesFolderID, page: NotesPage) async throws -> [NotesNoteMetadata] {
        let matching = notes.filter { $0.metadata.folderID == folderID }.map(\.metadata)
        guard page.offset < matching.count else { return [] }
        let end = min(matching.count, page.offset + page.limit)
        return Array(matching[page.offset ..< end])
    }

    func searchNotes(_ query: String, in folderIDs: Set<NotesFolderID>) async throws -> [NotesNoteMetadata] {
        let lowered = query.lowercased()
        return notes
            .filter { folderIDs.isEmpty || folderIDs.contains($0.metadata.folderID) }
            .filter { $0.plainText.lowercased().contains(lowered) }
            .map(\.metadata)
    }

    func notes(withIDs noteIDs: [NotesNoteID]) async throws -> [NotesNote] {
        let wanted = Set(noteIDs)
        return notes.filter { wanted.contains($0.metadata.id) }
    }

    func refresh() async throws -> NotesIndexingProgress {
        NotesIndexingProgress(indexedNoteCount: notes.count, totalNoteCount: notes.count)
    }

    func openInNotes(id: NotesNoteID) async throws {}
}
