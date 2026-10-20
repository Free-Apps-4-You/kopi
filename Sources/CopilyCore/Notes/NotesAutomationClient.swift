import Foundation

/// The Notes tab as Apple Notes sees it: connection state, the searchable note index,
/// and the rules around saving.
///
/// The client asks for automation permission, keeps metadata separate from bodies so
/// cards appear before indexing finishes, indexes changed bodies in bounded batches
/// while reporting progress, and never overwrites a note that changed in Apple Notes
/// while a draft was open. Notes stays the source of truth: nothing is stored locally
/// and a failure here leaves Clipboard and Pinned untouched.
public actor NotesAutomationClient: NotesClient {
    private struct IndexedNote: Sendable {
        var summary: NotesNoteSummary
        var folderID: NotesFolderID?
        var plainText: String?
        var bodyHTML: String?
        var inspection: NotesBodyInspection?
    }

    private let runner: any NotesAutomationRunning
    private let permission: any NotesAutomationPermissionChecking
    private let batchSize: Int
    private let conflictTolerance: TimeInterval

    private var state: NotesConnectionState = .disconnected
    private var connectionGeneration = UUID()
    private var isDisconnecting = false
    private var accounts: [NotesAccount] = []
    private var folders: [NotesFolder] = []
    private var selection = NotesFolderSelection()
    private var folderNames: [NotesFolderID: String] = [:]
    private var notesByFolder: [NotesFolderID: [NotesNoteID]] = [:]
    private var notes: [NotesNoteID: IndexedNote] = [:]

    public init(
        runner: any NotesAutomationRunning = ScriptingBridgeNotesRunner(),
        permission: any NotesAutomationPermissionChecking = AppleEventPermissionChecker(),
        batchSize: Int = 20,
        conflictTolerance: TimeInterval = 1
    ) {
        self.runner = runner
        self.permission = permission
        self.batchSize = max(1, batchSize)
        self.conflictTolerance = conflictTolerance
    }

    // MARK: - Connection

    public var connectionState: NotesConnectionState { state }

    /// Requests permission, reads accounts and folders, and indexes the included
    /// folders once so the tab has cards when it opens.
    @discardableResult
    public func connect() async throws -> [NotesAccount] {
        guard !isDisconnecting else { throw NotesClientError.notConnected }
        let generation = UUID()
        connectionGeneration = generation
        state = .loading
        let authorization = await permission.requestAutomationPermission()
        try requireCurrentConnection(generation)
        guard authorization != .denied else {
            state = .permissionDenied
            throw NotesClientError.permissionDenied
        }
        do {
            _ = try await index(progress: nil, generation: generation)
            try requireCurrentConnection(generation)
            return accounts
        } catch {
            if connectionGeneration == generation { state = Self.failureState(for: error) }
            throw error
        }
    }

    public func disconnect() async {
        guard !isDisconnecting else { return }
        connectionGeneration = UUID()
        isDisconnecting = true
        // Invalidate and clear before waiting on automation. In-flight reads must
        // never repopulate the index or restore the connected state after this point.
        state = .disconnected
        accounts = []
        folders = []
        folderNames = [:]
        notesByFolder = [:]
        notes = [:]
        await runner.reset()
        isDisconnecting = false
    }

    private func requireCurrentConnection(_ generation: UUID) throws {
        guard generation == connectionGeneration, !isDisconnecting else { throw NotesClientError.notConnected }
        try Task.checkCancellation()
    }

    public func accounts() async throws -> [NotesAccount] {
        guard state.isConnected else { throw NotesClientError.notConnected }
        return accounts
    }

    public func folders(inAccounts accountIDs: [NotesAccountID]?) async throws -> [NotesFolder] {
        guard state.isConnected else { throw NotesClientError.notConnected }
        guard let accountIDs else { return folders }
        return folders.filter { accountIDs.contains($0.accountID) }
    }

    public func setIncludedFolders(_ folderIDs: Set<NotesFolderID>) async {
        selection = NotesFolderSelection(includedFolderIDs: folderIDs, usesDefaultWhenEmpty: false)
        pruneIndex()
    }

    // MARK: - Notes

    public func notes(in folderID: NotesFolderID, page: NotesPage) async throws -> [NotesNoteMetadata] {
        guard state.isConnected else { throw NotesClientError.notConnected }
        if notesByFolder[folderID] == nil {
            try await loadSummaries(in: folderID)
        }
        let identifiers = notesByFolder[folderID] ?? []
        guard page.offset < identifiers.count else { return [] }
        return identifiers
            .dropFirst(max(page.offset, 0))
            .prefix(page.limit)
            .compactMap { notes[$0] }
            .map { metadata(for: $0, folder: folderID) }
    }

    public func notes(withIDs noteIDs: [NotesNoteID]) async throws -> [NotesNote] {
        guard state.isConnected else { throw NotesClientError.notConnected }
        let generation = connectionGeneration
        var loaded: [NotesNote] = []
        for id in noteIDs {
            guard let record = notes[id] else { continue }
            if record.summary.isProtected {
                loaded.append(NotesNote(metadata: metadata(for: record), bodyHTML: "", plainText: ""))
                continue
            }
            let location = NotesNoteLocation(id: id, folderID: record.folderID)
            let contents = try await runner.noteContents(for: [location])
            try requireCurrentConnection(generation)
            guard let content = contents.first(where: { $0.id == id }) else {
                loaded.append(NotesNote(metadata: metadata(for: record), bodyHTML: "", plainText: ""))
                continue
            }
            let updated = store(content: content)
            loaded.append(
                NotesNote(
                    metadata: metadata(for: updated),
                    bodyHTML: content.bodyHTML,
                    plainText: content.plainText
                )
            )
        }
        return loaded
    }

    public func searchNotes(_ query: String, in folderIDs: Set<NotesFolderID>) async throws -> [NotesNoteMetadata] {
        guard state.isConnected else { throw NotesClientError.notConnected }
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        return notes.values.compactMap { record -> NotesNoteMetadata? in
            let metadata = metadata(for: record)
            guard folderIDs.contains(metadata.folderID) else { return nil }
            let text = [metadata.title, metadata.folderName ?? "", record.summary.isProtected ? "" : record.plainText ?? ""]
                .joined(separator: "\n")
                .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            return needle.isEmpty || text.contains(needle) ? metadata : nil
        }.sorted {
            if $0.modificationDate != $1.modificationDate { return $0.modificationDate > $1.modificationDate }
            return $0.id.rawValue < $1.id.rawValue
        }
    }

    public func refresh() async throws -> NotesIndexingProgress {
        guard state != .disconnected else { throw NotesClientError.notConnected }
        return try await index(progress: nil, generation: connectionGeneration)
    }

    public func refresh(progress: @escaping @Sendable (NotesIndexingProgress) -> Void) async throws -> NotesIndexingProgress {
        guard state != .disconnected else { throw NotesClientError.notConnected }
        return try await index(progress: progress, generation: connectionGeneration)
    }

    public func createNote(_ draft: NotesNoteDraft) async throws -> NotesNoteMetadata {
        guard state.isConnected else { throw NotesClientError.notConnected }
        let generation = connectionGeneration
        guard let folderID = draft.folderID ?? selection.effectiveFolders(from: folders).first?.id else {
            throw NotesClientError.folderNotFound(NotesFolderID(rawValue: ""))
        }
        let summary = try await runner.createNote(
            in: folderID,
            body: NotesNoteText.compose(title: draft.title, body: draft.body)
        )
        try requireCurrentConnection(generation)
        // Notes reports the note's first line as its name, which is not always the
        // title the user typed; the card shows what the composer wrote.
        var record = IndexedNote(
            summary: NotesNoteSummary(
                id: summary.id,
                folderID: summary.folderID ?? folderID,
                folderName: summary.folderName,
                title: draft.title,
                modificationDate: summary.modificationDate,
                isProtected: summary.isProtected,
                isShared: summary.isShared
            ),
            folderID: folderID
        )
        if !summary.isProtected,
           let content = try? await runner.noteContents(for: [NotesNoteLocation(id: summary.id, folderID: folderID)]).first {
            record.plainText = content.plainText
            record.bodyHTML = content.bodyHTML
            record.inspection = NotesTextCompatibility.inspect(bodyHTML: content.bodyHTML)
        }
        try requireCurrentConnection(generation)
        notes[summary.id] = record
        notesByFolder[folderID] = (notesByFolder[folderID] ?? []).filter { $0 != summary.id }
        notesByFolder[folderID, default: []].insert(summary.id, at: 0)
        return metadata(for: record, folder: folderID)
    }

    /// Saves an edit, but never over an external change: the modification date is read
    /// again first, and a note that changed is handed back as a conflict with the draft
    /// kept for the user to reload or save as a new note.
    public func save(_ draft: NotesNoteDraft) async throws -> NotesSaveOutcome {
        guard state.isConnected else { throw NotesClientError.notConnected }
        let generation = connectionGeneration
        guard let noteID = draft.noteID else {
            return .saved(try await createNote(draft))
        }
        let record = notes[noteID]
        let folderID = draft.folderID ?? record?.folderID
        let location = NotesNoteLocation(id: noteID, folderID: folderID)
        if record?.summary.isProtected == true {
            throw NotesClientError.noteNotEditable(noteID)
        }

        let current = try await runner.noteSummary(for: location)
        try requireCurrentConnection(generation)
        guard !current.isProtected else { throw NotesClientError.noteNotEditable(noteID) }
        if Self.changedExternally(draft: draft, current: current, tolerance: conflictTolerance) {
            store(summary: current, content: nil, folder: folderID)
            _ = try? await loadContent(for: location)
            try requireCurrentConnection(generation)
            return .conflict(current: metadata(for: noteID), draft: draft)
        }

        guard let content = try await loadContent(for: location),
              NotesTextCompatibility.check(bodyHTML: content.bodyHTML, plainText: content.plainText).isTextOnly
        else {
            throw NotesClientError.noteNotEditable(noteID)
        }

        try requireCurrentConnection(generation)
        let body = NotesNoteText.compose(title: draft.title, body: draft.body)
        try await runner.setBody(body, for: location)
        try requireCurrentConnection(generation)
        let updated = try await runner.noteSummary(for: location)
        try requireCurrentConnection(generation)
        let saved = store(
            summary: updated,
            content: NotesNoteContent(id: noteID, plainText: body, bodyHTML: ""),
            folder: folderID,
            contentIsCurrent: false
        )
        return .saved(metadata(for: saved))
    }

    public func openInNotes(id: NotesNoteID) async throws {
        guard state.isConnected else { throw NotesClientError.notConnected }
        try await runner.openNote(NotesNoteLocation(id: id, folderID: notes[id]?.folderID))
    }

    // MARK: - Indexing

    /// Reads notes and folders, then indexes the bodies of the notes that are new or
    /// changed, `batchSize` notes at a time, publishing progress at every batch so the
    /// tab can show how much of the folder is covered.
    private func index(progress: (@Sendable (NotesIndexingProgress) -> Void)?, generation: UUID) async throws -> NotesIndexingProgress {
        do {
            try await loadStructure(generation: generation)
        } catch {
            if connectionGeneration == generation { state = Self.failureState(for: error) }
            throw error
        }

        let scope = selection.effectiveFolders(from: folders)
        guard !scope.isEmpty else {
            notes = [:]
            notesByFolder = [:]
            let empty = NotesIndexingProgress(indexedNoteCount: 0, totalNoteCount: 0)
            progress?(empty)
            state = .empty
            return empty
        }

        var summariesByFolder: [NotesFolderID: [NotesNoteSummary]] = [:]
        do {
            for folder in scope {
                summariesByFolder[folder.id] = try await summaries(in: folder.id)
                try requireCurrentConnection(generation)
            }
        } catch {
            if connectionGeneration == generation { state = Self.failureState(for: error) }
            throw error
        }

        let summaries = scope.flatMap { summariesByFolder[$0.id] ?? [] }
        // The notes to read are found before the new metadata replaces the old, so a
        // note whose modification date moved is seen as changed.
        let pending = changedNoteIDs(in: summaries)
        replaceIndex(with: summariesByFolder)

        let total = summaries.count
        guard total > 0 else {
            let empty = NotesIndexingProgress(indexedNoteCount: 0, totalNoteCount: 0)
            progress?(empty)
            state = .empty
            return empty
        }

        var processed = 0
        var update = NotesIndexingProgress(indexedNoteCount: processed, totalNoteCount: total)
        state = .indexing(update)
        progress?(update)

        for batch in Self.batches(of: summaries, size: batchSize) {
            let toRead = batch.filter { pending.contains($0.id) }
            if !toRead.isEmpty {
                do {
                    let contents = try await runner.noteContents(
                        for: toRead.map { NotesNoteLocation(id: $0.id, folderID: $0.folderID) }
                    )
                    try requireCurrentConnection(generation)
                    for content in contents {
                        store(content: content)
                    }
                } catch {
                    if connectionGeneration == generation { state = Self.failureState(for: error) }
                    throw error
                }
            }
            processed = min(processed + batch.count, total)
            update = NotesIndexingProgress(indexedNoteCount: processed, totalNoteCount: total)
            state = .indexing(update)
            progress?(update)
        }

        return update
    }

    /// Notes lists a folder but answers its note list with "no such object" when the
    /// folder holds no notes; an empty list keeps the connection and reports zero.
    private func summaries(in folderID: NotesFolderID) async throws -> [NotesNoteSummary] {
        do {
            return try await runner.noteSummaries(in: folderID)
        } catch let error as NotesClientError {
            guard case .folderNotFound = error else { throw error }
            return []
        }
    }

    private func loadStructure(generation: UUID) async throws {
        let loadedAccounts = try await runner.accounts()
        try requireCurrentConnection(generation)
        let loadedFolders = try await runner.folders(inAccounts: loadedAccounts.map(\.id))
        try requireCurrentConnection(generation)
        accounts = loadedAccounts
        folders = loadedFolders
        folderNames = Dictionary(grouping: folders, by: \.id).compactMapValues { $0.first?.name }
        pruneIndex()
    }

    private func loadSummaries(in folderID: NotesFolderID) async throws {
        let generation = connectionGeneration
        let summaries = try await runner.noteSummaries(in: folderID)
        try requireCurrentConnection(generation)
        notesByFolder[folderID] = summaries.map(\.id)
        for summary in summaries {
            if notes[summary.id] == nil {
                notes[summary.id] = IndexedNote(summary: summary, folderID: folderID)
            }
        }
    }

    private func replaceIndex(with summaries: [NotesFolderID: [NotesNoteSummary]]) {
        var updated: [NotesNoteID: IndexedNote] = [:]
        var order: [NotesFolderID: [NotesNoteID]] = [:]
        for (folderID, list) in summaries {
            order[folderID] = list.map(\.id)
            for summary in list {
                var record = notes[summary.id] ?? IndexedNote(summary: summary, folderID: folderID)
                record.summary = summary
                record.folderID = folderID
                if summary.isProtected {
                    record.plainText = nil
                    record.bodyHTML = nil
                    record.inspection = nil
                }
                updated[summary.id] = record
            }
        }
        notes = updated
        notesByFolder = order
    }

    /// Drops the notes of folders that are no longer part of the connected accounts or
    /// the included selection, so an excluded folder leaves nothing behind.
    private func pruneIndex() {
        guard !folders.isEmpty else { return }
        let available = Set(folders.map(\.id))
        let included = Set(selection.effectiveFolders(from: folders).map(\.id))
        notesByFolder = notesByFolder.filter { available.contains($0.key) && included.contains($0.key) }
        let kept = Set(notesByFolder.values.flatMap { $0 })
        notes = notes.filter { kept.contains($0.key) }
        let resolved = selection.resolvedIDs(among: folders)
        if resolved != selection.includedFolderIDs {
            selection = NotesFolderSelection(includedFolderIDs: resolved, usesDefaultWhenEmpty: selection.usesDefaultWhenEmpty)
        }
    }

    /// The notes whose bodies are new, changed or unreadable since the last pass. The
    /// check runs against the index as it stood before this pass replaced it, so a
    /// modification date Notes moved is seen as a change. Locked notes are skipped:
    /// their bodies are never read.
    private func changedNoteIDs(in summaries: [NotesNoteSummary]) -> Set<NotesNoteID> {
        Set(summaries.compactMap { summary in
            guard !summary.isProtected else { return nil }
            guard let record = notes[summary.id], record.inspection != nil else { return summary.id }
            guard record.summary.modificationDate == summary.modificationDate else { return summary.id }
            guard summary.folderID == nil || record.folderID == summary.folderID else { return summary.id }
            return nil
        })
    }

    @discardableResult
    private func store(content: NotesNoteContent) -> IndexedNote {
        var record = notes[content.id] ?? IndexedNote(
            summary: NotesNoteSummary(id: content.id, title: "", modificationDate: nil),
            folderID: nil
        )
        guard !record.summary.isProtected else { return record }
        record.plainText = content.plainText
        record.bodyHTML = content.bodyHTML
        record.inspection = NotesTextCompatibility.inspect(bodyHTML: content.bodyHTML)
        notes[content.id] = record
        return record
    }

    @discardableResult
    private func store(
        summary: NotesNoteSummary,
        content: NotesNoteContent?,
        folder: NotesFolderID?,
        contentIsCurrent: Bool = true
    ) -> IndexedNote {
        var record = notes[summary.id] ?? IndexedNote(summary: summary, folderID: folder)
        record.summary = summary
        record.folderID = folder ?? record.folderID ?? summary.folderID
        if let content {
            record.plainText = content.plainText
            record.bodyHTML = content.bodyHTML
            record.inspection = contentIsCurrent ? NotesTextCompatibility.inspect(bodyHTML: content.bodyHTML) : nil
        }
        notes[summary.id] = record
        return record
    }

    /// Reads a note's text into the index, returning it.
    private func loadContent(for location: NotesNoteLocation) async throws -> NotesNoteContent? {
        let generation = connectionGeneration
        let contents = try await runner.noteContents(for: [location])
        try requireCurrentConnection(generation)
        guard let content = contents.first(where: { $0.id == location.id }) else { return nil }
        var record = store(content: content)
        if record.folderID == nil {
            record.folderID = location.folderID
            notes[content.id] = record
        }
        return content
    }

    // MARK: - Metadata

    private func metadata(for id: NotesNoteID) -> NotesNoteMetadata {
        guard let record = notes[id] else {
            return NotesNoteMetadata(
                id: id,
                folderID: NotesFolderID(rawValue: ""),
                title: "",
                excerpt: "",
                modificationDate: Date(timeIntervalSince1970: 0)
            )
        }
        return metadata(for: record)
    }

    /// A note whose folder Notes did not report is filed under the first included
    /// folder: only its folder name is affected, never the note itself.
    private func metadata(for record: IndexedNote, folder: NotesFolderID? = nil) -> NotesNoteMetadata {
        let folderID = folder ?? record.folderID ?? record.summary.folderID
            ?? selection.effectiveFolders(from: folders).first?.id
            ?? NotesFolderID(rawValue: "")
        let inspection = record.inspection
        return NotesNoteMetadata(
            id: record.summary.id,
            folderID: folderID,
            folderName: record.summary.folderName ?? folderNames[folderID],
            title: record.summary.title,
            excerpt: record.summary.isProtected ? "" : record.plainText.map { NotesNoteText.excerpt(fromPlainText: $0) } ?? "",
            modificationDate: record.summary.modificationDate ?? Date(timeIntervalSince1970: 0),
            isProtected: record.summary.isProtected,
            isShared: record.summary.isShared,
            hasRichContent: inspection?.hasRichContent ?? false,
            attachmentCount: inspection?.attachmentCount ?? 0
        )
    }

    // MARK: - Helpers

    /// A note counts as changed when the date differs by more than a second, when it
    /// cannot be read at all, or when the draft has no date to compare with: Copily
    /// would rather ask than overwrite.
    static func changedExternally(
        draft: NotesNoteDraft,
        current: NotesNoteSummary,
        tolerance: TimeInterval
    ) -> Bool {
        guard let base = draft.baseModificationDate, let now = current.modificationDate else { return true }
        return abs(now.timeIntervalSince(base)) >= tolerance
    }

    static func batches<T>(of values: [T], size: Int) -> [[T]] {
        guard !values.isEmpty else { return [] }
        let step = max(size, 1)
        return stride(from: 0, to: values.count, by: step).map { start in
            Array(values[start ..< min(start + step, values.count)])
        }
    }

    /// User-facing text for a failure, used for the tab's error state.
    static func message(for error: any Error) -> String {
        if let notesError = error as? NotesClientError { return notesError.userMessage }
        return error.localizedDescription
    }

    /// The state a failure leaves behind: a permission failure Notes reported shows as
    /// the permission state, everything else as an error with its message.
    static func failureState(for error: any Error) -> NotesConnectionState {
        if let notesError = error as? NotesClientError, notesError.isPermissionFailure {
            return .permissionDenied
        }
        return .error(message(for: error))
    }
}
