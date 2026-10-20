import AppKit
import Combine
import Foundation
import KopiCore

/// State of the Notes tab: connection, folders, note cards, previews.
///
/// Everything goes through the injected ``NotesClient`` and through
/// ``ClipboardService`` for copying text, so a Notes failure stays inside this feature:
/// Clipboard and Pinned never see one.
@MainActor
final class NotesTabViewModel: ObservableObject {
    struct Preview: Identifiable {
        let metadata: NotesNoteMetadata
        var note: NotesNote?
        var richText: RichTextDocument?
        var isLoading = true
        var error: String?

        var id: NotesNoteID { metadata.id }
    }

    @Published var selection: NotesNoteID?
    var pasteTarget: NotesNoteMetadata? {
        preview?.metadata ?? filteredNotes.first(where: { $0.id == selection }) ?? filteredNotes.first
    }

    @Published private(set) var state: NotesTabState = .disconnected
    @Published private(set) var accounts: [NotesAccount] = []
    @Published private(set) var folders: [NotesFolder] = []
    @Published private(set) var notes: [NotesNoteMetadata] = []
    @Published private(set) var filteredNotes: [NotesNoteMetadata] = []
    @Published private(set) var preview: Preview?
    @Published private(set) var isBusy = false
    @Published private(set) var isChangingConnection = false
    @Published private(set) var statusMessage: String?
    @Published var sourceFilter: NotesSourceFilter = .all {
        didSet {
            guard sourceFilter != oldValue else { return }
            selection = nil
            closePreview()
            filterTask?.cancel()
            let included = sourceFolderIDs()
            filteredNotes = searchText.isEmpty ? notes.filter { included.contains($0.folderID) } : []
            filterTask = Task { await applyFilter() }
        }
    }

    var emptySourceMessage: String {
        if sourceFilter == .onMyMac, !accounts.contains(where: { $0.location == .onMyMac }) {
            return "Apple Notes has not reported an On My Mac account. Enable it in Apple Notes → Settings, then refresh Kopi."
        }
        return "Notes from the included folders will appear here automatically. Check included folders in Settings if notes are missing."
    }
    @Published var searchText: String = "" {
        didSet {
            guard searchText != oldValue else { return }
            scheduleFilter()
        }
    }

    private let client: any NotesClient
    private let service: ClipboardService
    private let settings: KopiSettingsStore
    private var folderSelection: NotesFolderSelection
    private var folderRevision = 0
    private var pendingFolderRefresh = false
    private var folderSettingsSubscription: AnyCancellable?
    private var unavailableMessage: String?
    private var filterTask: Task<Void, Never>?
    private var statusTask: Task<Void, Never>?
    private var previewRequestID = UUID()
    private var connectionGeneration = UUID()
    private var automaticSyncTask: Task<Void, Never>?
    private var isVisible = false
    private let syncInterval: Duration

    init(client: any NotesClient, service: ClipboardService, settings: KopiSettingsStore, syncInterval: Duration = .seconds(3)) {
        self.syncInterval = syncInterval
        self.client = client
        self.service = service
        self.settings = settings
        self.folderSelection = NotesFolderSelection(
            includedFolderIDs: Set(settings.settings.notesFolderIDs.map { NotesFolderID(rawValue: $0) }),
            usesDefaultWhenEmpty: !settings.settings.notesFoldersConfigured
        )
        folderSettingsSubscription = settings.$settings.dropFirst().sink { [weak self] updated in
            self?.applyFolderSettings(updated)
        }
    }

    // MARK: - Connection

    /// Called every time the Notes tab becomes visible, which is also when the notes
    /// index is refreshed.
    func activate() async {
        guard !isChangingConnection else { return }
        let generation = connectionGeneration
        let connection = await client.connectionState
        guard generation == connectionGeneration, !isChangingConnection else { return }
        state = NotesTabState(connectionState: connection, automationUnavailable: unavailableMessage)
        guard connection.isConnected else { return }
        await refresh(silently: true)
    }

    /// Poll only while Notes is visible. Apple Notes exposes no public change stream.
    /// Each pass reads summaries; the client fetches bodies only for new or changed notes.
    func setVisible(_ visible: Bool) {
        guard isVisible != visible else { return }
        isVisible = visible
        automaticSyncTask?.cancel()
        automaticSyncTask = nil
        guard visible else { return }
        let interval = syncInterval
        automaticSyncTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: interval) } catch { return }
                guard !Task.isCancelled else { return }
                await self?.synchronizeIfNeeded()
            }
        }
    }

    func synchronizeIfNeeded() async {
        guard isVisible, !isBusy else { return }
        switch state {
        case .loaded, .empty, .error: await refresh(silently: true)
        default: break
        }
    }

    deinit { automaticSyncTask?.cancel() }

    func connect() async {
        guard !isBusy else { return }
        // Older builds let the only folder be unchecked without disconnecting.
        // Reconnecting now restores the default scope instead of an empty index.
        if settings.settings.notesFoldersConfigured && settings.settings.notesFolderIDs.isEmpty {
            settings.update { $0.notesFoldersConfigured = false }
        }
        isBusy = true
        isChangingConnection = true
        pendingFolderRefresh = false
        let generation = UUID()
        connectionGeneration = generation
        defer {
            if connectionGeneration == generation { isChangingConnection = false }
            finishFolderWork(generation: generation)
        }
        state = .connecting
        do {
            // Apply a saved choice before connect indexes any bodies, including an
            // explicit empty selection. First-run defaults still resolve from Notes.
            if !folderSelection.usesDefaultWhenEmpty {
                await client.setIncludedFolders(folderSelection.includedFolderIDs)
            }
            let connectedAccounts = try await client.connect()
            let connectedFolders = try await client.folders(inAccounts: nil)
            guard connectionGeneration == generation else { return }
            accounts = connectedAccounts
            folders = connectedFolders
            let revision = folderRevision
            await client.setIncludedFolders(folderSelection.usesDefaultWhenEmpty ? nil : Set(includedFolders().map(\.id)))
            if folderSelection.usesDefaultWhenEmpty { _ = try await client.refresh() }
            let connection = await client.connectionState
            state = NotesTabState(connectionState: connection, automationUnavailable: unavailableMessage)
            try await loadNotes(generation: generation, revision: revision)
        } catch {
            guard connectionGeneration == generation else { return }
            apply(error)
        }
    }

    /// The checkbox represents a connection, never a folder filter.
    func setConnected(_ connected: Bool) async {
        guard !isChangingConnection else { return }
        if connected { await connect() } else { await disconnect() }
    }

    func disconnect() async {
        guard !isChangingConnection else { return }
        let generation = UUID()
        connectionGeneration = generation
        isChangingConnection = true
        isBusy = true
        pendingFolderRefresh = false
        filterTask?.cancel()
        statusTask?.cancel()
        statusMessage = nil
        previewRequestID = UUID()
        preview = nil
        selection = nil
        notes = []
        filteredNotes = []
        accounts = []
        folders = []
        state = .disconnected
        await client.disconnect()
        guard generation == connectionGeneration else { return }
        isChangingConnection = false
        isBusy = false
    }

    /// Quiet refreshes keep cards and scroll position stable while the index updates.
    func refresh(silently: Bool = false) async {
        guard !isBusy else { return }
        switch state {
        case .loaded, .empty, .indexing, .error: break
        default: return
        }
        isBusy = true
        pendingFolderRefresh = false
        let generation = connectionGeneration
        let revision = folderRevision
        defer { finishFolderWork(generation: generation) }
        await client.setIncludedFolders(folderSelection.usesDefaultWhenEmpty ? nil : Set(includedFolders().map(\.id)))
        do {
            if silently {
                _ = try await client.refresh()
            } else {
                let relay = IndexingProgressRelay { [weak self] progress in
                    guard let self, self.isBusy, self.connectionGeneration == generation else { return }
                    self.state = .indexing(progress)
                }
                _ = try await client.refresh(progress: relay.publish)
            }
            let updatedAccounts = try await client.accounts()
            let updatedFolders = try await client.folders(inAccounts: nil)
            guard connectionGeneration == generation, !Task.isCancelled else { return }
            if accounts != updatedAccounts { accounts = updatedAccounts }
            if folders != updatedFolders { folders = updatedFolders }
            try await loadNotes(generation: generation, revision: revision)
        } catch {
            guard connectionGeneration == generation, !Task.isCancelled else { return }
            if silently, let notesError = error as? NotesClientError,
               !notesError.isPermissionFailure, notesError != .notConnected {
                showStatus("Notes sync paused: \(userFacingDescription(error))")
            } else {
                apply(error)
            }
        }
    }

    private func loadNotes(generation: UUID, revision: Int) async throws {
        var collected: [NotesNoteMetadata] = []
        for folder in includedFolders() {
            var offset = 0
            while true {
                let page = try await client.notes(in: folder.id, page: NotesPage(offset: offset, limit: NotesPage.defaultLimit))
                guard connectionGeneration == generation, folderRevision == revision, !Task.isCancelled else { return }
                collected.append(contentsOf: page)
                guard page.count == NotesPage.defaultLimit else { break }
                offset += page.count
            }
        }
        guard connectionGeneration == generation, folderRevision == revision, !Task.isCancelled else { return }
        let updated = Self.sortedByModification(collected)
        if notes != updated { notes = updated }
        // A deleted note cannot leave a stale preview on screen.
        if let preview, !updated.contains(where: { $0.id == preview.id }) { closePreview() }
        state = notes.isEmpty ? .empty : .loaded
        await applyFilter()
    }

    /// Folders the user included, or all folders before anything was chosen.
    private func includedFolders() -> [NotesFolder] {
        folderSelection.effectiveFolders(from: folders)
    }

    private func sourceFolderIDs() -> Set<NotesFolderID> {
        let accountIDs = Set(accounts.filter { sourceFilter.includes($0) }.map(\.id))
        return Set(includedFolders().filter { accountIDs.contains($0.accountID) }.map(\.id))
    }

    // MARK: - Folders

    func isIncluded(_ folder: NotesFolder) -> Bool {
        folderSelection.isIncluded(folder, among: folders)
    }

    func setIncluded(_ included: Bool, for folder: NotesFolder, confirmed: Bool = false) {
        objectWillChange.send()
        folderSelection.setIncluded(included, for: folder.id)
        settings.update {
            $0.notesFolderIDs = folderSelection.includedFolderIDs.map(\.rawValue).sorted()
            $0.notesFoldersConfigured = true
        }
        guard !confirmed else { return }
        folderSelectionChanged()
    }

    private func applyFolderSettings(_ updated: KopiSettings) {
        let selection = NotesFolderSelection(includedFolderIDs: Set(updated.notesFolderIDs.map { NotesFolderID(rawValue: $0) }),
                                             usesDefaultWhenEmpty: !updated.notesFoldersConfigured)
        guard selection != folderSelection else { return }
        objectWillChange.send()
        folderSelection = selection
        folderSelectionChanged()
    }

    private func folderSelectionChanged() {
        folderRevision += 1
        filterTask?.cancel()
        pendingFolderRefresh = true
        let included = Set(includedFolders().map(\.id))
        notes.removeAll { !included.contains($0.folderID) }
        filteredNotes.removeAll { !included.contains($0.folderID) }
        if let preview, !included.contains(preview.metadata.folderID) { closePreview() }
        Task { await refresh(silently: true) }
    }

    private func finishFolderWork(generation: UUID) {
        guard connectionGeneration == generation else { return }
        isBusy = false
        guard pendingFolderRefresh else { return }
        pendingFolderRefresh = false
        Task { await refresh(silently: true) }
    }

    func folderName(for id: NotesFolderID) -> String? {
        folders.first { $0.id == id }?.name
    }

    // MARK: - Search

    private func scheduleFilter() {
        filterTask?.cancel()
        filterTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled else { return }
            await self?.applyFilter()
        }
    }

    private func applyFilter() async {
        guard state.showsNoteList || state == .empty else {
            if !filteredNotes.isEmpty { filteredNotes = [] }
            return
        }
        let generation = connectionGeneration
        let originalQuery = searchText
        let originalSource = sourceFilter
        let snapshot = notes
        let folderIDs = sourceFolderIDs()
        let query = originalQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            let result = notes.filter { folderIDs.contains($0.folderID) }
            if filteredNotes != result { filteredNotes = result }
            return
        }
        do {
            let result = try await client.searchNotes(query, in: folderIDs)
            guard !Task.isCancelled, connectionGeneration == generation, searchText == originalQuery,
                  sourceFilter == originalSource, folderIDs == sourceFolderIDs(), notes == snapshot,
                  state.showsNoteList || state == .empty else { return }
            if filteredNotes != result { filteredNotes = result }
        } catch {
            guard !Task.isCancelled, connectionGeneration == generation, searchText == originalQuery else { return }
            statusMessage = userFacingDescription(error)
        }
    }

    private static func sortedByModification(_ notes: [NotesNoteMetadata]) -> [NotesNoteMetadata] {
        var seen = Set<NotesNoteID>()
        return notes
            .sorted { $0.modificationDate > $1.modificationDate }
            .filter { seen.insert($0.id).inserted }
    }

    // MARK: - Notes

    func preparePreview(_ metadata: NotesNoteMetadata) async {
        let requestID = UUID()
        previewRequestID = requestID
        preview = Preview(metadata: metadata)
        do {
            let loaded = try await client.notes(withIDs: [metadata.id])
            guard previewRequestID == requestID else { return }
            let document = loaded.first.flatMap { RichTextCoding.document(fromHTML: $0.bodyHTML) }
            guard previewRequestID == requestID else { return }
            preview?.note = loaded.first
            preview?.richText = document
            preview?.isLoading = false
        } catch {
            guard previewRequestID == requestID else { return }
            preview?.isLoading = false
            preview?.error = userFacingDescription(error)
        }
    }

    func closePreview() {
        previewRequestID = UUID()
        preview = nil
    }

    @discardableResult
    func copyText(of metadata: NotesNoteMetadata) async -> Bool {
        selection = metadata.id
        let note: NotesNote?
        if let loaded = preview?.note, loaded.id == metadata.id {
            note = loaded
        } else {
            note = try? await client.notes(withIDs: [metadata.id]).first
        }
        guard let note else {
            showStatus("The note could not be read.")
            return false
        }
        let document = (preview?.note?.id == note.id ? preview?.richText : nil)
            ?? RichTextCoding.document(fromHTML: note.bodyHTML)
        guard !note.plainText.isEmpty || document?.isEmpty == false else {
            showStatus("That note has no text to copy.")
            return false
        }
        do {
            if let document, !document.isEmpty {
                _ = try await service.copyRichTextToPasteboard(document)
            } else {
                _ = try await service.copyPlainTextToPasteboard(note.plainText)
            }
            showStatus("Note copied with formatting")
            return true
        } catch {
            showStatus(userFacingDescription(error))
            return false
        }
    }

    func dragProvider(for metadata: NotesNoteMetadata) -> NSItemProvider {
        selection = metadata.id
        return NoteDrag.provider(client: client, id: metadata.id)
    }

    func openInNotes(_ metadata: NotesNoteMetadata) async {
        do {
            try await client.openInNotes(id: metadata.id)
        } catch {
            showStatus(userFacingDescription(error))
        }
    }

    // MARK: - Failures

    /// Maps a failure to the tab state, keeping automation problems apart from the
    /// states a working Notes connection can be in.
    private func apply(_ error: any Error) {
        if let notesError = error as? NotesClientError {
            switch notesError {
            case .automationUnavailable(let message):
                unavailableMessage = message
                state = .unavailable(message)
            case .permissionDenied:
                state = .permissionDenied
            case .notConnected:
                state = .disconnected
            default:
                state = .error(notesError.userMessage)
            }
            return
        }
        state = .error(userFacingDescription(error))
    }

    /// Shows a message in the Notes footer, clearing it again after a moment.
    private func showStatus(_ text: String) {
        statusMessage = text
        statusTask?.cancel()
        statusTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            self?.statusMessage = nil
        }
    }
}

/// Indexing progress is reported off the main actor and shown on it.
private struct IndexingProgressRelay: Sendable {
    let publish: @Sendable (NotesIndexingProgress) -> Void

    init(handler: @escaping @MainActor (NotesIndexingProgress) -> Void) {
        publish = { progress in
            Task { @MainActor in
                handler(progress)
            }
        }
    }
}
