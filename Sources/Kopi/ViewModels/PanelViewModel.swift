import AppKit
import Combine
import Foundation
import KopiCore

/// State of the panel: sections, sources, search, cards, selection, previews and
/// editors.
///
/// The view model never touches the database, the pasteboard or Notes directly: it
/// asks the actors the core provides and keeps immutable snapshots for the views.
@MainActor
final class PanelViewModel: ObservableObject {
    struct Page {
        var items: [ClipboardItemSummary] = []
        var totalCount = 0
        var isLoading = false
        var isLoadingMore = false
        var hasLoaded = false
        var error: String?

        var hasMore: Bool { items.count < totalCount }
        var isEmpty: Bool { hasLoaded && items.isEmpty && error == nil && !isLoading }
    }

    struct PreviewState: Identifiable {
        let itemID: ClipboardItemID
        var detail: ClipboardItemDetail?
        var isLoading = true
        var error: String?
        var image: CGImage?
        /// Highlight of the text when the card reads as code.
        var code: CodeHighlight?

        var id: ClipboardItemID { itemID }
    }

    struct EditorState {
        enum Kind {
            case text
            case richText
            case link
            case labelOnly

            var title: String {
                switch self {
                case .text: "Edit Text"
                case .richText: "Edit Rich Text"
                case .link: "Edit Link"
                case .labelOnly: "Edit Label"
                }
            }
        }

        let itemID: ClipboardItemID
        let kind: Kind
        let summary: ClipboardItemSummary
        var label: String
        var text: String
        var richText: RichTextDocument
        var url: String
        var isSaving = false
        var error: String?
    }

    struct StatusMessage: Equatable {
        var text: String
        var isError: Bool
    }

    // MARK: - Published state

    /// The main row: the kind of cards on show, or the Notes section.
    @Published private(set) var section: PanelSection = .all
    /// The sub row: pinned cards, the collection shelf, or neither for plain history.
    @Published private(set) var source: PanelSource?
    @Published private(set) var sourceAppBundleIdentifier: String?
    @Published private(set) var sourceApplications: [SourceAppInfo] = []
    @Published var queryText: String = "" {
        didSet {
            guard queryText != oldValue else { return }
            expandedItemID = nil
            guard !suppressesSearch else { return }
            scheduleSearch()
        }
    }
    @Published private(set) var clipboard = Page()
    @Published private(set) var pinned = Page()
    @Published private(set) var collection = Page()
    @Published private(set) var selection: ClipboardItemID?
    /// The one card expanded in place, if any.
    @Published private(set) var expandedItemID: ClipboardItemID?
    @Published private(set) var presentation: PanelPresentation = .grid
    @Published private(set) var preview: PreviewState?
    @Published private(set) var editor: EditorState?
    @Published private(set) var newItemDraft: NewItemDraft? {
        didSet { if oldValue != nil, newItemDraft == nil { pendingNewItemMode = nil; focusRequest += 1 } }
    }
    @Published private(set) var pendingNewItemMode: NewItemDraft.Mode?
    @Published private(set) var busyItems: Set<ClipboardItemID> = []
    @Published private(set) var statusMessage: StatusMessage?
    /// Bumped whenever the panel opens, before the window is ordered front, so the
    /// content returns to its entrance state while it is still hidden.
    @Published private(set) var openingToken = 0
    /// Bumped once the panel is front, which is what starts the content's entrance.
    @Published private(set) var revealToken = 0
    /// Bumped whenever the panel opens, so the search field takes the keyboard.
    @Published private(set) var focusRequest = 0
    /// The neck that reaches a notched display's top edge, set by the window layer
    /// before the panel is shown.
    @Published private(set) var panelAttachment: PanelAttachment?

    /// What the capture loop is doing, shown in the footer.
    @Published private(set) var captureState: ClipboardCaptureState = .idle
    /// The header offers a close button while clicking outside does not dismiss the panel.
    @Published private(set) var showsCloseButton = false
    @Published private(set) var usesCompactCards = false

    /// Set by the window layer: the Notes section offers Settings for folder selection.
    var onSettingsRequested: (() -> Void)?

    private let store: HistoryStore
    private let service: ClipboardService
    private let search: ClipboardSearchController
    private let settings: KopiSettingsStore
    let notes: NotesTabViewModel
    let passwords: PasswordsViewModel
    let previews: PreviewStore

    private var searchTask: Task<Void, Never>?
    private var loadGenerations: [HistoryScope: Int] = [:]
    private var previewRequestID = UUID()
    private var editorRequestID = UUID()
    private var statusTask: Task<Void, Never>?
    private var captureSubscription: AnyCancellable?
    private var captureSignalSubscription: AnyCancellable?
    private var settingsSubscription: AnyCancellable?
    private var captureReloadTask: Task<Void, Never>?
    private var pendingCaptureReload = false
    private var suppressesSearch = false
    private var isEntrancePlaying = false
    private var isOpen = false
    private var pendingNotice: String?
    /// The New Item card of an open editor, until it is saved or discarded.
    private var pendingNewItemID: ClipboardItemID?
    /// Longest an opening gives an in-flight background refresh to settle.
    private static let settleWindow: TimeInterval = 0.03

    init(
        store: HistoryStore,
        service: ClipboardService,
        search: ClipboardSearchController,
        captureStatus: ClipboardCaptureStatus,
        settings: KopiSettingsStore,
        notes: NotesTabViewModel,
        previews: PreviewStore,
        passwords: PasswordsViewModel = PasswordsViewModel()
    ) {
        self.store = store
        self.service = service
        self.search = search
        self.settings = settings
        self.notes = notes
        self.passwords = passwords
        self.previews = previews
        self.captureState = captureStatus.state
        self.showsCloseButton = !settings.settings.dismissesOnOutsideClick
        self.usesCompactCards = settings.settings.usesCompactCards
        passwords.onRequestCancel = { [weak self] in self?.requestLeavingEditor {} }
        settingsSubscription = settings.$settings
            .removeDuplicates()
            .sink { [weak self] updated in
                MainActor.assumeIsolated {
                    self?.showsCloseButton = !updated.dismissesOnOutsideClick
                    self?.usesCompactCards = updated.usesCompactCards
                }
            }
        captureSubscription = captureStatus.$state
            .removeDuplicates()
            .sink { [weak self] state in
                MainActor.assumeIsolated {
                    self?.captureState = state
                }
            }
        captureSignalSubscription = captureStatus.$latestCapture
            .compactMap { $0 }
            .sink { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.handleCaptureSignal()
                }
            }
    }

    // MARK: - Cards on screen

    var visibleCards: [ClipboardItemSummary] {
        section.showsClipboardCards ? page(for: listScope).items : []
    }

    var currentPage: Page {
        section.showsClipboardCards ? page(for: listScope) : Page()
    }

    /// The store scope the grid reads. The Notes section never reads it.
    var listScope: HistoryScope { source?.scope ?? .allClipboard }

    /// Whether the collection shelf is the section on show, which is what lets ⌘V
    /// collect the clipboard and a drop land on the grid.
    var isShowingCollection: Bool { section.showsClipboardCards && source == .collection }

    /// Card Return and the command shortcuts act on: the selection, or the first card.
    var pasteTarget: ClipboardItemID? {
        guard section.showsClipboardCards else { return nil }
        return selection ?? visibleCards.first?.id
    }

    var hasPasteTarget: Bool { pasteTarget != nil }

    func summary(for itemID: ClipboardItemID) -> ClipboardItemSummary? {
        clipboard.items.first { $0.id == itemID }
            ?? pinned.items.first { $0.id == itemID }
            ?? collection.items.first { $0.id == itemID }
    }

    /// Full record of a card: the expanded content and the drag payloads read it only
    /// once the user asks for it.
    func detail(for itemID: ClipboardItemID) async -> ClipboardItemDetail? {
        try? await store.detail(for: itemID)
    }

    /// Providers must resolve without MainActor: AppKit may synchronously wait during a drag.
    func dragSource(for item: ClipboardItemSummary) -> CardDragSource {
        let store = self.store
        let assets = store.assetStore
        return CardDragSource(itemID: item.id, kind: item.kind,
            loadDetail: { try? await store.detail(for: item.id) },
            readAsset: { try? await assets.readData(for: $0) },
            assetFileURL: { assets.fileURL(for: $0) })
    }

    func assetData(for reference: AssetReference) async -> Data? {
        try? await store.assetStore.readData(for: reference)
    }

    func assetFileURL(for reference: AssetReference) -> URL {
        store.assetStore.fileURL(for: reference)
    }

    func isBusy(_ itemID: ClipboardItemID) -> Bool { busyItems.contains(itemID) }

    @Published var showsSavePrompt = false
    private var pendingNavigation: (@MainActor () -> Void)?
    var isSavingDraft: Bool { newItemDraft?.isSaving == true || newItemDraft?.isLoading == true || editor?.isSaving == true || (passwords.draft != nil && passwords.isBusy) }
    var hasActiveEditor: Bool { newItemDraft != nil || editor != nil || passwords.draft != nil }
    func requestLeavingEditor(_ action: @escaping @MainActor () -> Void) {
        guard hasActiveEditor else { action(); return }
        guard !isSavingDraft else { showStatus("Finishing your save…"); return }
        guard !showsSavePrompt else { return }
        if let draft = newItemDraft, !draft.hasChanges {
            newItemDraft = nil
            action()
            return
        }
        if let draft = passwords.draft, !draft.hasChanges {
            passwords.discardDraft()
            action()
            return
        }
        pendingNavigation = action
        showsSavePrompt = true
    }
    func cancelPendingNavigation() { pendingNavigation = nil; showsSavePrompt = false }
    func discardAndContinue() {
        newItemDraft = nil
        closeEditor(); passwords.discardDraft()
        let action = pendingNavigation; pendingNavigation = nil; showsSavePrompt = false
        action?()
    }
    func saveAndContinue() async {
        if newItemDraft != nil { await saveNewItem() }
        if editor != nil { await saveEditor() }
        if passwords.draft != nil { await passwords.save() }
        guard !hasActiveEditor else { showsSavePrompt = false; return }
        let action = pendingNavigation; pendingNavigation = nil; showsSavePrompt = false
        action?()
    }
    func goHome() {
        requestLeavingEditor { [weak self] in
            guard let self else { return }
            self.performSetSection(.all)
            self.performSetSourceApp(nil)
            self.setSource(nil)
            self.clearSearchText()
            self.closePreview(); self.notes.closePreview(); self.passwords.lock()
            Task { await self.reload(.allClipboard) }
        }
    }
    func addItem() {
        guard section != .notes else { return }
        requestLeavingEditor { [weak self] in
            guard let self else { return }
            self.closePreview(); self.notes.closePreview()
            if self.section == .passwords { self.passwords.beginCreate() }
            else {
                self.newItemDraft = NewItemDraft()
            }
        }
    }

    // MARK: - Panel lifecycle

    /// Geometry of the neck the panel grows out of, handed over by the window layer
    /// when the display under the pointer has a camera housing.
    func setPanelAttachment(_ attachment: PanelAttachment?) {
        guard panelAttachment != attachment else { return }
        panelAttachment = attachment
    }

    func panelDidOpen() {
        isOpen = true
        openingToken += 1
        if let pendingNotice {
            self.pendingNotice = nil
            showStatus(pendingNotice)
        }
        notes.setVisible(section == .notes)
        passwords.setVisible(section == .passwords)
        if section == .passwords { Task { await passwords.activate() } }
        if section == .notes {
            Task { await notes.activate() }
        } else if !currentPage.hasLoaded && !currentPage.isLoading {
            Task { await reload(listScope) }
        }
    }

    /// Called by the window layer once the panel is ordered front, which is the moment
    /// the content settles in from the reset state published at open.
    func panelDidReveal() {
        isEntrancePlaying = true
        revealToken += 1
        focusRequest += 1
    }

    /// Called by the content once its entrance has played. A capture that landed
    /// while the animation ran is applied only now, so the grid never moves under it.
    func entranceDidFinish(token: Int) {
        guard token == revealToken, isEntrancePlaying else { return }
        isEntrancePlaying = false
        startCaptureReloadIfPending()
    }

    /// A background refresh is kept apart from the reveal: the panel gives one that is
    /// already settling a moment to finish, so the first frame shows a settled page
    /// when one is at hand. Opening is never held longer than that; the entrance defers
    /// the reloads a capture may ask for by itself.
    func settleBeforeReveal() async {
        let deadline = Date().addingTimeInterval(Self.settleWindow)
        while captureReloadTask != nil, Date() < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    func panelDidClose() {
        isOpen = false
        notes.setVisible(false)
        passwords.setVisible(false)
        isEntrancePlaying = false
        searchTask?.cancel()
        closeOverlays()
        clearSearchText()
        expandedItemID = nil
        selection = currentPage.items.first?.id
        Task { await search.cancel() }
        startCaptureReloadIfPending()
    }

    func setSection(_ section: PanelSection) {
        requestLeavingEditor { [weak self] in self?.performSetSection(section) }
    }
    private func performSetSection(_ section: PanelSection) {
        guard self.section != section else { return }
        searchTask?.cancel()
        pendingCaptureReload = false
        self.section = section
        closeOverlays()
        notes.closePreview()
        passwords.setVisible(isOpen && section == .passwords)
        if section == .passwords { Task { await passwords.activate() } }
        selection = nil
        expandedItemID = nil
        clearSearchText()
        notes.setVisible(isOpen && section == .notes)
        if section == .notes {
            Task { await notes.activate() }
        } else {
            Task { await reload(listScope) }
        }
    }

    /// The sub row toggles: picking the selected chip again returns to plain history.
    func toggleSource(_ source: PanelSource) {
        setSource(self.source == source ? nil : source)
    }

    func setSource(_ source: PanelSource?) {
        requestLeavingEditor { [weak self] in self?.performSetSource(source) }
    }
    private func performSetSource(_ source: PanelSource?) {
        guard self.source != source else { return }
        self.source = source
        closePreview(); notes.closePreview(); passwords.lock()
        expandedItemID = nil
        Task { await reload(listScope) }
    }

    func setSourceApp(_ identifier: String?) {
        requestLeavingEditor { [weak self] in self?.performSetSourceApp(identifier) }
    }

    private func performSetSourceApp(_ identifier: String?) {
        let identifier = identifier.map(SourceAppInfo.canonicalBundleIdentifier)
        guard sourceAppBundleIdentifier != identifier else { return }
        sourceAppBundleIdentifier = identifier
        searchTask?.cancel()
        pendingCaptureReload = false
        closePreview()
        selection = nil
        expandedItemID = nil
        // Invalidate both requests and cached shelves before a new filter loads.
        for scope in [HistoryScope.allClipboard, .pinned, .collection] {
            loadGenerations[scope] = (loadGenerations[scope] ?? 0) + 1
            update(scope) { $0 = Page() }
        }
        Task { await reload(listScope) }
    }

    @discardableResult
    func copyColorValue(_ value: String) async -> Bool {
        do {
            _ = try await service.copyPlainTextToPasteboard(value)
            showStatus("Color value copied")
            return true
        } catch {
            report(error: error)
            return false
        }
    }

    /// Loads the cards the panel would show, so the next open can be immediate.
    func warmUp() async {
        guard section.showsClipboardCards else { return }
        await reload(listScope)
    }

    // MARK: - Live updates

    /// A capture landed. A hidden panel refreshes its page in the background, so
    /// opening shows settled content; an open panel that is not searching reloads its
    /// scope so the new card shows up without reopening. Reloads are coalesced, so
    /// the newest capture is never lost while an earlier one is still being fetched.
    private func handleCaptureSignal() {
        guard section.showsClipboardCards, !isOpen || queryText.isEmpty else { return }
        pendingCaptureReload = true
        guard !isEntrancePlaying else { return }
        startCaptureReloadIfPending()
    }

    private func startCaptureReloadIfPending() {
        guard pendingCaptureReload, captureReloadTask == nil else { return }
        captureReloadTask = Task { [weak self] in
            await self?.drainCaptureReloads()
        }
    }

    private func drainCaptureReloads() async {
        defer { captureReloadTask = nil }
        while pendingCaptureReload, !isEntrancePlaying {
            pendingCaptureReload = false
            guard section.showsClipboardCards, !isOpen || queryText.isEmpty else { return }
            await reload(listScope)
        }
    }

    // MARK: - Selection and expansion

    func selectForPaste(_ itemID: ClipboardItemID) {
        selection = itemID
    }

    func isExpanded(_ itemID: ClipboardItemID) -> Bool {
        expandedItemID == itemID
    }

    /// Only one card is expanded at a time; the chevron toggles the card it belongs to.
    func toggleExpanded(_ itemID: ClipboardItemID) {
        expandedItemID = expandedItemID == itemID ? nil : itemID
    }

    // MARK: - Loading

    func reloadAll() async {
        await reload(.allClipboard)
        await reload(.pinned)
        await reload(.collection)
    }

    func reload(_ scope: HistoryScope) async {
        await load(scope: scope, reset: true)
    }

    func loadMoreIfNeeded(_ item: ClipboardItemSummary) {
        guard section.showsClipboardCards else { return }
        let scope = listScope
        let page = page(for: scope)
        guard page.items.last?.id == item.id, page.hasMore, !page.isLoading, !page.isLoadingMore else { return }
        Task { await load(scope: scope, reset: false) }
    }

    private func load(scope: HistoryScope, reset: Bool, debounce: Bool = false) async {
        guard !Task.isCancelled else { return }
        let existing = page(for: scope)
        guard let query = makeQuery(scope: scope, offset: reset ? 0 : existing.items.count) else { return }
        if !reset, existing.isLoadingMore { return }
        let generation = (loadGenerations[scope] ?? 0) + 1
        loadGenerations[scope] = generation
        defer {
            if loadGenerations[scope] == generation {
                update(scope) {
                    $0.isLoading = false
                    $0.isLoadingMore = false
                }
            }
        }
        if reset {
            update(scope) {
                $0.isLoading = true
                $0.error = nil
            }
        } else {
            update(scope) { $0.isLoadingMore = true }
        }

        do {
            let result: HistoryPageResult
            if section.showsClipboardCards, scope == listScope {
                let delivery = try await search.search(query, debounce: debounce)
                guard !delivery.isSuperseded, let page = delivery.page else { return }
                result = page
            } else {
                // Refreshing a hidden shelf must not supersede the visible tab's search.
                result = try await store.page(query)
            }
            guard !Task.isCancelled, loadGenerations[scope] == generation else { return }
            apply(result, scope: scope, reset: reset)
            if reset, let applications = try? await store.sourceApplications() {
                sourceApplications = applications
            }
        } catch {
            guard !Task.isCancelled, !(error is CancellationError),
                  loadGenerations[scope] == generation else { return }
            update(scope) {
                $0.isLoading = false
                $0.isLoadingMore = false
                $0.error = userFacingDescription(error)
                $0.hasLoaded = true
            }
        }
    }

    private func apply(_ result: HistoryPageResult, scope: HistoryScope, reset: Bool) {
        let merged: [ClipboardItemSummary]
        if reset {
            merged = result.items
        } else {
            let known = Set(page(for: scope).items.map(\.id))
            merged = page(for: scope).items + result.items.filter { !known.contains($0.id) }
        }
        update(scope) { page in
            page.items = merged
            page.totalCount = result.totalCount
            page.isLoading = false
            page.isLoadingMore = false
            page.hasLoaded = true
            page.error = nil
        }
        reconcileSelection(scope: scope, items: merged)
        if let expanded = expandedItemID, !merged.contains(where: { $0.id == expanded }) {
            expandedItemID = nil
        }
    }

    /// The selection always names a card of the page on show. A hidden page settles
    /// its card while the panel is away, so opening never moves the ring; the newest
    /// card is the one waiting for Return.
    private func reconcileSelection(scope: HistoryScope, items: [ClipboardItemSummary]) {
        guard section.showsClipboardCards, scope == listScope else { return }
        if !isOpen {
            selection = items.first?.id
            return
        }
        if let selected = selection, items.contains(where: { $0.id == selected }) { return }
        selection = items.first?.id
    }

    private func scheduleSearch() {
        guard isOpen, section.showsClipboardCards else { return }
        searchTask?.cancel()
        pendingCaptureReload = false
        let scope = listScope
        searchTask = Task { [weak self] in
            guard let self else { return }
            await self.load(scope: scope, reset: true, debounce: true)
        }
    }

    private func makeQuery(scope: HistoryScope, offset: Int) -> HistoryQuery? {
        let selection = PanelSelection(section: section, source: PanelSource(scope: scope))
        return selection.query(
            text: queryText,
            page: HistoryPage(offset: offset, limit: HistoryPage.defaultLimit),
            sourceAppBundleIdentifier: sourceAppBundleIdentifier
        )
    }

    private func clearSearchText() {
        guard !queryText.isEmpty else { return }
        suppressesSearch = true
        queryText = ""
        suppressesSearch = false
    }

    func page(for scope: HistoryScope) -> Page {
        switch scope {
        case .allClipboard: clipboard
        case .pinned: pinned
        case .collection: collection
        }
    }

    private func update(_ scope: HistoryScope, _ change: (inout Page) -> Void) {
        switch scope {
        case .allClipboard: change(&clipboard)
        case .pinned: change(&pinned)
        case .collection: change(&collection)
        }
    }

    // MARK: - Mutations

    func togglePin(_ itemID: ClipboardItemID) async {
        guard !busyItems.contains(itemID) else { return }
        guard let summary = summary(for: itemID) else { return }
        guard !summary.isCollection else {
            showStatus("Collected cards are kept already")
            return
        }
        busyItems.insert(itemID)
        defer { busyItems.remove(itemID) }
        let pinning = !summary.isPinned
        do {
            _ = try await store.setPinned(pinning, for: itemID)
            await reloadAll()
            showStatus(pinning ? "Pinned" : "Unpinned")
        } catch {
            report(error: error)
        }
    }

    func delete(_ itemID: ClipboardItemID) async {
        do {
            _ = try await store.delete(itemID)
            previews.invalidate(itemID)
            if selection == itemID { selection = nil }
            await reloadAll()
            showStatus("Deleted")
        } catch {
            report(error: error)
        }
    }

    func deletePinned(_ itemID: ClipboardItemID) async {
        guard let summary = summary(for: itemID), summary.isPinned else { return }
        await delete(itemID)
    }

    // MARK: - Collection

    func selectNewItemMode(_ mode: NewItemDraft.Mode) {
        guard let draft = newItemDraft, !isSavingDraft, draft.mode != mode else { return }
        if draft.hasContent { pendingNewItemMode = mode }
        else { applyNewItemMode(mode) }
    }

    func cancelNewItemModeChange() { pendingNewItemMode = nil }

    func confirmNewItemModeChange(_ requestedMode: NewItemDraft.Mode? = nil) {
        guard let mode = requestedMode ?? pendingNewItemMode, !isSavingDraft else { return }
        applyNewItemMode(mode)
    }

    private func applyNewItemMode(_ mode: NewItemDraft.Mode) {
        newItemDraft?.mode = mode
        newItemDraft?.text = ""
        newItemDraft?.richText = RichTextDocument(plainText: "")
        newItemDraft?.attachment = nil
        newItemDraft?.error = nil
        pendingNewItemMode = nil
    }

    func updateNewItemText(_ text: String) {
        guard let draft = newItemDraft, !isSavingDraft, draft.attachment == nil,
              draft.mode == .text || draft.mode == .link else { return }
        newItemDraft?.text = text
        newItemDraft?.richText = RichTextDocument(plainText: text)
        newItemDraft?.error = nil
    }

    func updateNewItemRichText(_ document: RichTextDocument) {
        guard newItemDraft?.mode == .text, !isSavingDraft else { return }
        newItemDraft?.richText = document
        newItemDraft?.text = document.plainText
        newItemDraft?.error = nil
    }

    func updateNewItemLabel(_ label: String) {
        guard newItemDraft != nil, !isSavingDraft else { return }
        newItemDraft?.label = label
        newItemDraft?.error = nil
    }

    func cancelNewItem() { requestLeavingEditor { [weak self] in self?.newItemDraft = nil } }

    func removeNewItemAttachment(_ id: UUID) {
        guard !isSavingDraft else { return }
        if newItemDraft?.attachment?.id == id {
            newItemDraft?.attachment = nil
            newItemDraft?.error = nil
        }
    }

    func pasteIntoNewItem() async {
        await loadNewItemAttachments { [service] in
            let snapshot = try await service.readSnapshotForUser()
            try Self.validateSingleItem(snapshot)
            return [NewItemAttachment(snapshot: snapshot)]
        }
    }

    func dropIntoNewItem(_ providers: [NSItemProvider]) {
        Task {
            await loadNewItemAttachments {
                guard providers.count == 1 else { throw NewItemImportError.oneItemOnly }
                let snapshot = await DroppedContent.snapshot(from: providers)
                try Self.validateSingleItem(snapshot)
                if newItemDraft?.mode == .image, CaptureProcessor.kind(of: snapshot) == .files,
                   let rawURL = snapshot.string(for: ClipboardRepresentationKind.fileURL.pasteboardType),
                   let url = URL(string: rawURL), url.isFileURL {
                    return try await NewItemImport.files([url], asImages: true)
                }
                return [NewItemAttachment(snapshot: snapshot)]
            }
        }
    }

    func importNewItemFiles(_ urls: [URL], asImages: Bool) async {
        await loadNewItemAttachments {
            guard urls.count == 1 else { throw NewItemImportError.oneItemOnly }
            return try await NewItemImport.files(urls, asImages: asImages)
        }
    }

    func chooseNewItemFiles(asImages: Bool) {
        guard let draft = newItemDraft, !draft.hasContent, !isSavingDraft, let window = NSApp.keyWindow else { return }
        guard draft.mode == (asImages ? .image : .file) else { return }
        let id = newItemDraft?.id
        let picker = NSOpenPanel()
        picker.title = asImages ? "Choose Image" : "Choose File"
        picker.prompt = "Choose"
        picker.allowsMultipleSelection = false
        picker.canChooseDirectories = !asImages
        picker.canChooseFiles = true
        if asImages { picker.allowedContentTypes = [.image] }
        picker.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let self, self.newItemDraft?.id == id else { return }
            let urls = picker.urls
            Task { await self.importNewItemFiles(urls, asImages: asImages) }
        }
    }

    private func loadNewItemAttachments(_ load: () async throws -> [NewItemAttachment]) async {
        guard var draft = newItemDraft, !isSavingDraft else { return }
        guard !draft.hasContent else { newItemDraft?.error = NewItemImportError.oneItemOnly.localizedDescription; return }
        draft.isLoading = true; draft.error = nil; newItemDraft = draft
        do {
            let attachments = try await load()
            guard newItemDraft?.id == draft.id else { return }
            guard attachments.count == 1 else { throw NewItemImportError.oneItemOnly }
            let attachment = attachments[0]
            switch attachment.kind {
            case .text:
                newItemDraft?.mode = .text
                let text = attachment.snapshot.string(for: ClipboardRepresentationKind.plainText.pasteboardType) ?? ""
                newItemDraft?.text = text
                newItemDraft?.richText = RichTextDocument(plainText: text)
            case .link:
                newItemDraft?.mode = .link
                newItemDraft?.text = attachment.snapshot.string(for: ClipboardRepresentationKind.link.pasteboardType) ?? ""
            case .richText:
                newItemDraft?.mode = .text
                newItemDraft?.attachment = attachment
            case .files:
                newItemDraft?.mode = .file
                newItemDraft?.attachment = attachment
            case .image:
                newItemDraft?.mode = .image
                newItemDraft?.attachment = attachment
            case nil: throw NewItemImportError.unsupported
            }
        } catch {
            guard newItemDraft?.id == draft.id else { return }
            newItemDraft?.error = error.localizedDescription
        }
        newItemDraft?.isLoading = false
    }

    private static func validateSingleItem(_ snapshot: PasteboardSnapshot) throws {
        guard CaptureProcessor.kind(of: snapshot) != nil else { throw NewItemImportError.unsupported }
        guard snapshot.items.filter({ !$0.isEmpty }).count == 1,
              snapshot.strings(for: ClipboardRepresentationKind.fileURL.pasteboardType).count <= 1 else { throw NewItemImportError.oneItemOnly }
    }

    func saveNewItem() async {
        guard var draft = newItemDraft, !isSavingDraft else { return }
        guard draft.hasContent else {
            newItemDraft?.error = "Write something, paste content, or add files or images first."
            return
        }
        draft.isSaving = true; draft.error = nil; newItemDraft = draft
        do {
            let snapshot: PasteboardSnapshot
            if let attachment = draft.attachment {
                snapshot = attachment.snapshot
            } else if draft.mode == .link {
                guard let url = LinkInput.normalizedURL(from: draft.text) else { throw EditorValidation.invalidURL }
                snapshot = PasteboardSnapshot(changeCount: 0, items: [PasteboardItemSnapshot(flavours: [
                    PasteboardFlavour(type: ClipboardRepresentationKind.link.pasteboardType, string: url.absoluteString),
                    PasteboardFlavour(type: ClipboardRepresentationKind.plainText.pasteboardType, string: url.absoluteString)
                ])])
            } else if draft.richText.hasFormatting {
                snapshot = PasteboardSnapshot(changeCount: 0, items: [PasteboardItemSnapshot(flavours: [
                    PasteboardFlavour(type: ClipboardRepresentationKind.plainText.pasteboardType, string: draft.richText.plainText),
                    PasteboardFlavour(type: ClipboardRepresentationKind.html.pasteboardType, string: draft.richText.html()),
                    PasteboardFlavour(type: ClipboardRepresentationKind.rtf.pasteboardType, data: draft.richText.rtf())
                ])])
            } else {
                snapshot = NewItemImport.text(draft.text, detectsLinks: false)
            }
            _ = try await service.capture(snapshot, into: .collection, label: draft.label)
            newItemDraft = nil
            performSetSection(.all)
            performSetSource(.collection)
            performSetSourceApp(nil)
            clearSearchText()
            await reload(.collection)
            showStatus("Added to Collection")
        } catch {
            newItemDraft?.isSaving = false
            newItemDraft?.error = userFacingDescription(error)
            await reload(.collection)
        }
    }

    /// The New Item action: a brand-new card on the shelf, opened in the editor so the
    /// user can type and Save. Cancelling the editor takes the card away again, unless
    /// it was saved.
    func createCollectionItem() async {
        clearSearchText()
        do {
            let result = try await store.insert(.newCollectionItem())
            pendingNewItemID = result.itemID
            await reload(.collection)
            await beginEditing(result.itemID)
            guard editor == nil else { return }
            // The editor refused to open, so the card it was made for is taken away again.
            discardPendingNewItem()
        } catch {
            report(error: error)
        }
    }

    /// ⌘V on the collection: the current clipboard becomes a card on the shelf, through
    /// the same capture pipeline that a copy goes through.
    func pasteClipboardIntoCollection() async {
        clearSearchText()
        do {
            let result = try await service.captureClipboard(into: .collection)
            await reload(.collection)
            showStatus(Self.collectionStatus(created: result.didCreateItem ? 1 : 0, collapsed: result.didCreateItem ? 0 : 1))
        } catch {
            report(error: error)
        }
    }

    /// A drop on the collection: a card dragged from another chip, or content dropped
    /// from another application or Finder. Both end up on the shelf through the core.
    func collectDropped(_ providers: [NSItemProvider]) {
        Task { [weak self] in
            await self?.performCollectionDrop(providers)
        }
    }

    private func performCollectionDrop(_ providers: [NSItemProvider]) async {
        var cardIDs: [ClipboardItemID] = []
        var content: [NSItemProvider] = []
        for provider in providers {
            if let itemID = await DroppedContent.cardIdentifier(in: provider) {
                cardIDs.append(itemID)
            } else {
                content.append(provider)
            }
        }

        clearSearchText()
        var created = 0
        var collapsed = 0
        do {
            for itemID in cardIDs {
                if try await store.addToCollection(itemID).didCreateItem {
                    created += 1
                } else {
                    collapsed += 1
                }
            }
            if !content.isEmpty {
                let snapshot = await DroppedContent.snapshot(from: content)
                if !snapshot.isEmpty {
                    if try await service.capture(snapshot, into: .collection).didCreateItem {
                        created += 1
                    } else {
                        collapsed += 1
                    }
                }
            }
        } catch {
            report(error: error)
            return
        }
        await reload(.collection)
        showStatus(Self.collectionStatus(created: created, collapsed: collapsed))
    }

    private static func collectionStatus(created: Int, collapsed: Int) -> String {
        if created == 0 { return "Already in Collection" }
        if created == 1 { return "Added to Collection" }
        return "Added \(created) items to Collection"
    }

    /// A New Item card that the editor closed without saving.
    private func discardPendingNewItem() {
        guard let discarded = pendingNewItemID else { return }
        pendingNewItemID = nil
        Task { [weak self] in
            guard let self else { return }
            _ = try? await store.delete(discarded)
            await reload(.collection)
        }
    }

    // MARK: - Previews

    func openPreview(_ itemID: ClipboardItemID) async {
        if hasActiveEditor {
            requestLeavingEditor { [weak self] in Task { await self?.openPreview(itemID) } }
            return
        }
        closeEditor()
        let requestID = UUID()
        previewRequestID = requestID
        var card = summary(for: itemID)
        if card == nil {
            card = (try? await store.summary(for: itemID)) ?? nil
        }
        guard previewRequestID == requestID, let summary = card else { return }
        preview = PreviewState(itemID: itemID)
        presentation = .preview
        let detail = try? await store.detail(for: itemID)
        guard previewRequestID == requestID else { return }
        if let detail {
            preview?.detail = detail
        } else {
            preview?.error = "The card could not be loaded."
        }
        if summary.kind == .text {
            let text = preview?.detail?.plainText ?? summary.excerpt
            let code = await previews.codeHighlight(for: summary, text: text)
            guard previewRequestID == requestID else { return }
            preview?.code = code
        } else if summary.kind == .richText {
            await previews.load(summary)
            guard previewRequestID == requestID else { return }
        }
        if summary.kind == .image {
            let image = await previews.largeImage(for: summary, maxPixelSize: 2560)
            guard previewRequestID == requestID else { return }
            preview?.image = image
            if image == nil { preview?.error = "The image could not be decoded." }
        }
        preview?.isLoading = false
    }

    func closePreview() {
        guard editor == nil else { return }
        previewRequestID = UUID()
        preview = nil
        presentation = .grid
    }

    // MARK: - Editors

    func beginEditing(_ itemID: ClipboardItemID) async {
        if hasActiveEditor {
            requestLeavingEditor { [weak self] in Task { await self?.beginEditing(itemID) } }
            return
        }
        let requestID = UUID()
        editorRequestID = requestID
        do {
            guard let detail = try await store.detail(for: itemID) else {
                throw HistoryStoreError.itemNotFound(itemID)
            }
            guard editorRequestID == requestID else { return }
            // An editor of another card replaces this one; an unsaved New Item of it goes
            // with it. The card this editor is for is left alone.
            if pendingNewItemID != itemID {
                discardPendingNewItem()
            }
            closePreview()
            editor = makeEditor(from: detail)
            presentation = .editor
        } catch {
            guard editorRequestID == requestID else { return }
            report(error: error)
        }
    }

    func cancelEditor() {
        requestLeavingEditor { [weak self] in self?.closeEditor() }
    }

    func updateEditor(_ change: (inout EditorState) -> Void) {
        guard var editor else { return }
        change(&editor)
        self.editor = editor
    }

    func saveEditor() async {
        guard var editor, !editor.isSaving else { return }
        editor.error = nil
        editor.isSaving = true
        self.editor = editor
        let requestID = editorRequestID

        do {
            try validateNewItem(editor)
            let edit = try makeEdit(from: editor)
            _ = try await store.edit(edit, for: editor.itemID)
            previews.invalidate(editor.itemID)
            guard editorRequestID == requestID else { return }
            pendingNewItemID = nil
            closeEditor()
            await reloadAll()
            showStatus("Saved")
        } catch {
            guard editorRequestID == requestID else { return }
            editor.isSaving = false
            editor.error = userFacingDescription(error)
            self.editor = editor
        }
    }

    /// A New Item has to gain content before it is saved: an empty card would stay on
    /// the shelf for good.
    private func validateNewItem(_ editor: EditorState) throws {
        guard editor.itemID == pendingNewItemID else { return }
        guard !editor.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw EditorValidation.emptyNewItem
        }
    }

    /// The editor going away without a save takes a New Item card with it, so cancelling
    /// never leaves an empty card behind. A save clears the marker first.
    private func closeEditor() {
        editorRequestID = UUID()
        editor = nil
        if presentation == .editor {
            presentation = .grid
        }
        discardPendingNewItem()
    }

    private func closeOverlays() {
        previewRequestID = UUID()
        preview = nil
        closeEditor()
        presentation = .grid
    }

    private func makeEditor(from detail: ClipboardItemDetail) -> EditorState {
        let summary = detail.summary
        let editableText = detail.editableText ?? ""
        return EditorState(
            itemID: summary.id,
            kind: editorKind(for: summary.kind),
            summary: summary,
            label: summary.label ?? "",
            text: editableText,
            richText: storedRichText(of: detail) ?? RichTextDocument(plainText: editableText),
            url: summary.primaryURL?.absoluteString ?? ""
        )
    }

    private func editorKind(for kind: ClipboardItemKind) -> EditorState.Kind {
        switch kind {
        case .text: .text
        case .richText: .richText
        case .link: .link
        case .image, .files: .labelOnly
        }
    }

    private func storedRichText(of detail: ClipboardItemDetail) -> RichTextDocument? {
        if let data = detail.representation(.rtf)?.data {
            return RichTextCoding.document(fromRTF: data)
        }
        if let html = detail.representation(.html)?.text {
            return RichTextCoding.document(fromHTML: html)
        }
        return nil
    }

    private func makeEdit(from editor: EditorState) throws -> ClipboardItemEdit {
        let label = editor.label.trimmingCharacters(in: .whitespacesAndNewlines)
        switch editor.kind {
        case .text:
            if editor.richText.hasFormatting {
                return ClipboardItemEdit(label: label, richText: editor.richText)
            }
            return .text(editor.text, label: label)
        case .richText:
            return ClipboardItemEdit(label: label, richText: editor.richText)
        case .link:
            guard let url = LinkInput.normalizedURL(from: editor.url) else {
                throw EditorValidation.invalidURL
            }
            return .link(url, label: label)
        case .labelOnly:
            return .label(label)
        }
    }

    // MARK: - Status

    func showStatus(_ text: String, isError: Bool = false) {
        statusMessage = StatusMessage(text: text, isError: isError)
        statusTask?.cancel()
        statusTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            self?.statusMessage = nil
        }
    }

    /// Queues a message for the next time the panel opens.
    func queueStatus(_ text: String) {
        if isOpen {
            showStatus(text)
        } else {
            pendingNotice = text
        }
    }

    func report(error: any Error) {
        showStatus(userFacingDescription(error), isError: true)
    }
}

/// What the editors reject before anything is written.
enum EditorValidation: Error, Equatable {
    case invalidURL
    case emptyNewItem
}
