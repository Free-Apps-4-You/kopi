import Foundation
import Testing

@testable import KopiCore

@Suite("Notes domain")
struct NotesDomainTests {
    @Test("Connection states are distinct and describe themselves")
    func connectionStates() throws {
        let states: [NotesConnectionState] = [
            .disconnected,
            .loading,
            .permissionDenied,
            .indexing(NotesIndexingProgress(indexedNoteCount: 2, totalNoteCount: 5)),
            .empty,
            .error("Apple Events failed")
        ]

        #expect(Set(states).count == states.count)
        #expect(states[0].isConnected == false)
        #expect(states[1].isConnected == false)
        #expect(states[2].isConnected == false)
        #expect(states[3].isConnected)
        #expect(states[4].isConnected)
        #expect(states[5].isConnected == false)

        let progress = try #require(states[3].indexingProgress)
        #expect(progress.fractionCompleted == 0.4)
        #expect(progress.isComplete == false)
        #expect(NotesIndexingProgress(indexedNoteCount: 5, totalNoteCount: 5).isComplete)
        #expect(NotesIndexingProgress(indexedNoteCount: 0, totalNoteCount: 0).isComplete)
        #expect(states[5].errorMessage == "Apple Events failed")
        #expect(states[0].displayName == "Not Connected")
    }

    @Test("Inline editing is limited to plain, unprotected notes")
    func inlineEditingCompatibility() {
        let folderID = NotesFolderID(rawValue: "folder")
        let plain = NotesNoteMetadata(
            id: NotesNoteID(rawValue: "1"),
            folderID: folderID,
            title: "Plain note",
            excerpt: "Short body",
            modificationDate: Date()
        )
        #expect(plain.supportsInlineEditing)
        #expect(plain.requiresAppleNotes == false)

        let rich = NotesNoteMetadata(
            id: NotesNoteID(rawValue: "2"),
            folderID: folderID,
            title: "Checklist",
            excerpt: "with attachments",
            modificationDate: Date(),
            hasRichContent: true,
            attachmentCount: 2
        )
        #expect(rich.supportsInlineEditing == false)
        #expect(rich.requiresAppleNotes)

        let locked = NotesNoteMetadata(
            id: NotesNoteID(rawValue: "3"),
            folderID: folderID,
            title: "Locked",
            excerpt: "",
            modificationDate: Date(),
            isProtected: true
        )
        #expect(locked.supportsInlineEditing == false)
    }

    @Test("Drafts and save outcomes carry conflicts without overwriting")
    func draftAndConflictOutcomes() {
        let folderID = NotesFolderID(rawValue: "folder")
        let metadata = NotesNoteMetadata(
            id: NotesNoteID(rawValue: "1"),
            folderID: folderID,
            folderName: "Notes",
            title: "Existing",
            excerpt: "body",
            modificationDate: Date()
        )
        let draft = NotesNoteDraft(
            noteID: metadata.id,
            title: "Edited outside",
            body: "new body",
            folderID: folderID,
            baseModificationDate: metadata.modificationDate
        )
        #expect(draft.isNew == false)

        let conflict = NotesSaveOutcome.conflict(current: metadata, draft: draft)
        #expect(conflict.isConflict)
        #expect(conflict.savedNote == nil)

        let saved = NotesSaveOutcome.saved(metadata)
        #expect(saved.isConflict == false)
        #expect(saved.savedNote == metadata)

        let newDraft = NotesNoteDraft(title: "New", body: "content")
        #expect(newDraft.isNew)
    }

    @Test("Notes pages default to 60 items")
    func notesPaging() {
        #expect(NotesPage().limit == NotesPage.defaultLimit)
        #expect(NotesPage.defaultLimit == 60)
        #expect(NotesPage(offset: 60, limit: 60).offset == 60)
    }

    @Test("A notes client can be implemented against the protocol")
    func clientProtocolIsImplementable() async throws {
        let client = StubNotesClient()
        let state = await client.connectionState
        #expect(state == .disconnected)

        let accounts = try await client.connect()
        #expect(accounts.count == 1)
        let connected = await client.connectionState
        #expect(connected.isConnected)

        let folders = try await client.folders(inAccounts: nil)
        let folderID = try #require(folders.first?.id)
        let notes = try await client.notes(in: folderID, page: NotesPage(limit: 10))
        #expect(notes.count == 1)

        let bodies = try await client.notes(withIDs: notes.map(\.id))
        #expect(bodies.first?.plainText == "Note body")

        let progress = try await client.refresh()
        #expect(progress.isComplete)

        let created = try await client.createNote(NotesNoteDraft(title: "T", body: "B", folderID: folderID))
        #expect(created.title == "T")

        let outcome = try await client.save(
            NotesNoteDraft(
                noteID: created.id,
                title: "T2",
                body: "B2",
                baseModificationDate: Date(timeIntervalSince1970: 1)
            )
        )
        #expect(outcome.isConflict)

        await client.disconnect()
        let afterDisconnect = await client.connectionState
        #expect(afterDisconnect == .disconnected)
    }

    @Test("Notes failures do not affect clipboard storage")
    func notesFailuresAreContained() async throws {
        let workspace = try TempWorkspace()
        try await workspace.store.beginSession()
        _ = try await workspace.store.insert(textInsertion("clipboard stays usable"))

        let failing = StubNotesClient(shouldFail: true)
        var thrown: (any Error)?
        do {
            _ = try await failing.connect()
        } catch {
            thrown = error
        }
        #expect(thrown as? NotesClientError == .permissionDenied)

        let page = try await workspace.store.page(HistoryQuery())
        #expect(page.items.count == 1)
    }
}

/// Minimal implementation used to prove the protocol is usable by a real client.
private actor StubNotesClient: NotesClient {
    func searchNotes(_ query: String, in folderIDs: Set<NotesFolderID>) async throws -> [NotesNoteMetadata] {
        guard state.isConnected else { throw NotesClientError.notConnected }
        let folderID = NotesFolderID(rawValue: "folder")
        guard folderIDs.contains(folderID) else { return [] }
        let metadata = Self.metadata(folderID: folderID, title: "Existing")
        return query.isEmpty || metadata.title.localizedCaseInsensitiveContains(query) ? [metadata] : []
    }
    private let shouldFail: Bool

    init(shouldFail: Bool = false) {
        self.shouldFail = shouldFail
    }

    private var state: NotesConnectionState = .disconnected
    private var includedFolders: Set<NotesFolderID> = []

    var connectionState: NotesConnectionState {
        state
    }

    func connect() async throws -> [NotesAccount] {
        if shouldFail {
            state = .permissionDenied
            throw NotesClientError.permissionDenied
        }
        state = .empty
        return [NotesAccount(id: NotesAccountID(rawValue: "account"), name: "iCloud", isDefault: true)]
    }

    func disconnect() async {
        state = .disconnected
    }

    func setIncludedFolders(_ folderIDs: Set<NotesFolderID>) async {
        includedFolders = folderIDs
    }

    func accounts() async throws -> [NotesAccount] {
        guard state.isConnected else { throw NotesClientError.notConnected }
        return [NotesAccount(id: NotesAccountID(rawValue: "account"), name: "iCloud", isDefault: true)]
    }

    func folders(inAccounts accountIDs: [NotesAccountID]?) async throws -> [NotesFolder] {
        guard state.isConnected else { throw NotesClientError.notConnected }
        return [
            NotesFolder(
                id: NotesFolderID(rawValue: "folder"),
                accountID: NotesAccountID(rawValue: "account"),
                name: "Notes",
                isDefault: true,
                noteCount: 1
            )
        ]
    }

    func notes(in folderID: NotesFolderID, page: NotesPage) async throws -> [NotesNoteMetadata] {
        guard state.isConnected else { throw NotesClientError.notConnected }
        return [Self.metadata(folderID: folderID, title: "Existing")]
    }

    func notes(withIDs noteIDs: [NotesNoteID]) async throws -> [NotesNote] {
        guard state.isConnected else { throw NotesClientError.notConnected }
        let folderID = NotesFolderID(rawValue: "folder")
        return noteIDs.map { id in
            NotesNote(
                metadata: Self.metadata(folderID: folderID, title: "Existing", id: id),
                bodyHTML: "<p>Note body</p>",
                plainText: "Note body"
            )
        }
    }

    func refresh() async throws -> NotesIndexingProgress {
        guard state.isConnected else { throw NotesClientError.notConnected }
        let progress = NotesIndexingProgress(indexedNoteCount: 1, totalNoteCount: 1)
        state = .indexing(progress)
        return progress
    }

    func createNote(_ draft: NotesNoteDraft) async throws -> NotesNoteMetadata {
        guard state.isConnected else { throw NotesClientError.notConnected }
        let folderID = draft.folderID ?? NotesFolderID(rawValue: "folder")
        return Self.metadata(folderID: folderID, title: draft.title)
    }

    func save(_ draft: NotesNoteDraft) async throws -> NotesSaveOutcome {
        guard state.isConnected else { throw NotesClientError.notConnected }
        let folderID = draft.folderID ?? NotesFolderID(rawValue: "folder")
        let current = Self.metadata(folderID: folderID, title: draft.title)
        if let base = draft.baseModificationDate, base != current.modificationDate {
            return .conflict(current: current, draft: draft)
        }
        return .saved(current)
    }

    func openInNotes(id: NotesNoteID) async throws {
        guard state.isConnected else { throw NotesClientError.notConnected }
    }

    private static func metadata(
        folderID: NotesFolderID,
        title: String,
        id: NotesNoteID = NotesNoteID(rawValue: "note")
    ) -> NotesNoteMetadata {
        NotesNoteMetadata(
            id: id,
            folderID: folderID,
            folderName: "Notes",
            title: title,
            excerpt: "Note body",
            modificationDate: Date(timeIntervalSince1970: 1_700_000_000)
        )
    }
}
