import AppKit
import Foundation
import KopiCore

/// The objects Kopi owns, built once at launch and shared by the panel, the menu bar
/// item and the Settings window.
///
/// Actors do all database, clipboard and Notes work; the view models in here are main
/// actor isolated and exchange immutable snapshots only.
@MainActor
final class AppEnvironment {
    let settings: KopiSettingsStore
    let assetStore: AssetStore
    let store: HistoryStore
    let processor: CaptureProcessor
    let service: ClipboardService
    let search: ClipboardSearchController
    let maintenance: HistoryMaintenance
    let captureStatus: ClipboardCaptureStatus
    let notes: any NotesClient
    let notesModel: NotesTabViewModel
    let previews: PreviewStore
    let panelModel: PanelViewModel

    /// Shown in the panel the next time it opens, for things the user should know.
    private(set) var startupNotice: String?

    private init(
        settings: KopiSettingsStore,
        assetStore: AssetStore,
        store: HistoryStore,
        processor: CaptureProcessor,
        service: ClipboardService,
        search: ClipboardSearchController,
        maintenance: HistoryMaintenance,
        captureStatus: ClipboardCaptureStatus,
        notes: any NotesClient,
        notesModel: NotesTabViewModel,
        previews: PreviewStore,
        panelModel: PanelViewModel
    ) {
        self.settings = settings
        self.assetStore = assetStore
        self.store = store
        self.processor = processor
        self.service = service
        self.search = search
        self.maintenance = maintenance
        self.captureStatus = captureStatus
        self.notes = notes
        self.notesModel = notesModel
        self.previews = previews
        self.panelModel = panelModel
    }

    // MARK: - Building

    static func bootstrap() throws -> AppEnvironment {
        // Carry a pre-rename installation forward before any store opens: the whole
        // Application Support folder moves once. Recovering an archived vault key
        // is an explicit Passwords > Migrate action; launch never reads the Keychain.
        try ApplicationDataMigration.migrateSupportDirectoryIfNeeded()

        let settings = KopiSettingsStore()
        let assetStore = try AssetStore(rootDirectory: try AssetStore.defaultRootDirectory())
        let store = try HistoryStore(path: databaseURL(for: assetStore).path, assetStore: assetStore)
        let captureStatus = ClipboardCaptureStatus()
        let processor = CaptureProcessor(assetStore: assetStore)
        let service = ClipboardService(
            store: store,
            pasteboard: NSPasteboardAccess(),
            processor: processor,
            lifecycle: WorkspaceLifecycleObserver(),
            frontmostApp: WorkspaceFrontmostAppProvider(),
            status: captureStatus,
            excludedApplications: settings.settings.exclusion
        )
        let search = ClipboardSearchController(store: store)
        let maintenance = HistoryMaintenance(store: store)
        let notes: any NotesClient = NotesAutomationClient()
        let notesModel = NotesTabViewModel(client: notes, service: service, settings: settings)
        let previews = PreviewStore(store: store, processor: processor, code: CodeHighlightService())
        let panelModel = PanelViewModel(
            store: store,
            service: service,
            search: search,
            captureStatus: captureStatus,
            settings: settings,
            notes: notesModel,
            previews: previews
        )
        return AppEnvironment(
            settings: settings,
            assetStore: assetStore,
            store: store,
            processor: processor,
            service: service,
            search: search,
            maintenance: maintenance,
            captureStatus: captureStatus,
            notes: notes,
            notesModel: notesModel,
            previews: previews,
            panelModel: panelModel
        )
    }

    /// `~/Library/Application Support/Kopi/history.sqlite`, beside the asset files.
    static func databaseURL(for assetStore: AssetStore) -> URL {
        assetStore.rootDirectory
            .deletingLastPathComponent()
            .appendingPathComponent("history.sqlite")
    }

    // MARK: - Running

    /// Opens the session, applies retention and starts observing the clipboard.
    func start() async {
        do {
            let session = try await store.beginSession()
            if session.recoveredFromInterruptedExit {
                startupNotice = "Kopi closed unexpectedly last time. History rules were applied again."
            }
            await service.setExcludedApplications(settings.settings.exclusion)
            await service.setCapturePaused(settings.settings.isCapturePaused)
            await service.start(captureExistingClipboard: settings.settings.capturesClipboardOnLaunch)
            await maintenance.start()
            await panelModel.warmUp()
        } catch {
            startupNotice = "Kopi could not open its history: \(error.localizedDescription)"
        }
    }

    /// Ends the session, which is what clears "Current session" history on a normal quit.
    func shutdown() async {
        await service.stop()
        await maintenance.stop()
        _ = try? await store.endSession()
    }

    /// Applies the parts of the settings that live in the service.
    func apply(settings updated: KopiSettings) {
        Task { [service] in
            await service.setExcludedApplications(updated.exclusion)
            await service.setCapturePaused(updated.isCapturePaused)
        }
    }

    /// Clear History, either after a confirmation of its own or from Settings, which
    /// asks with SwiftUI. Pinned and collected cards are never removed.
    func clearHistory(withConfirmation: Bool) {
        Task { @MainActor in
            if withConfirmation {
                let alert = NSAlert()
                alert.messageText = "Clear clipboard history?"
                alert.informativeText = "Unpinned cards are removed. Pinned and collected cards are kept."
                alert.addButton(withTitle: "Clear History")
                alert.addButton(withTitle: "Cancel")
                guard alert.runModal() == .alertFirstButtonReturn else { return }
            }
            do {
                let report = try await store.clearHistory()
                await panelModel.reloadAll()
                panelModel.showStatus("Removed \(report.removedItemCount) card\(report.removedItemCount == 1 ? "" : "s")")
            } catch {
                panelModel.report(error: error)
            }
        }
    }
}
