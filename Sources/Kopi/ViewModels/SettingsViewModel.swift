import AppKit
import Combine
import Foundation
import KopiCore

/// State of the Settings window.
///
/// The settings themselves live in ``KopiSettingsStore``; this model only reads them,
/// changes them and reports what the environment did with them. Retention is read from
/// and written to ``HistoryStore``, which owns it.
@MainActor
final class SettingsViewModel: ObservableObject {
    let settings: KopiSettingsStore
    let notes: NotesTabViewModel

    @Published private(set) var retention: HistoryRetention = .default
    @Published private(set) var statistics: HistoryStatistics?
    @Published private(set) var launchAtLoginStatus: LaunchAtLogin.Status = .disabled
    @Published private(set) var isClearingHistory = false
    @Published private(set) var message: String?
    @Published private(set) var isRecordingShortcut = false
    @Published var newExcludedApplication: String = ""
    /// Drives the Clear History confirmation dialog.
    @Published var isConfirmingClear = false
    @Published var isConfirmingReset = false
    /// Applications currently running, offered as exclusion candidates.
    @Published private(set) var runningApplications: [SourceAppInfo] = []

    private let store: HistoryStore
    private let environment: AppEnvironment
    private var messageTask: Task<Void, Never>?

    init(environment: AppEnvironment) {
        self.environment = environment
        self.settings = environment.settings
        self.store = environment.store
        self.notes = environment.notesModel
    }

    // MARK: - Loading

    func load() async {
        retention = (try? await store.retention()) ?? .default
        statistics = try? await store.statistics()
        launchAtLoginStatus = LaunchAtLogin.status
        runningApplications = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap { application in
                guard let bundleIdentifier = application.bundleIdentifier else { return nil }
                return SourceAppInfo(bundleIdentifier: bundleIdentifier, name: application.localizedName)
            }
            .sorted { ($0.displayName ?? "") < ($1.displayName ?? "") }
    }

    // MARK: - History

    func setRetention(_ retention: HistoryRetention) async {
        guard self.retention != retention else { return }
        do {
            _ = try await store.setRetention(retention)
            self.retention = retention
            statistics = try? await store.statistics()
            await environment.panelModel.reloadAll()
            show("Retention set to \(retention.displayName)")
        } catch {
            show(userFacingDescription(error))
        }
    }

    func clearHistory() async {
        isClearingHistory = true
        do {
            let report = try await store.clearHistory()
            statistics = try? await store.statistics()
            await environment.panelModel.reloadAll()
            show("Removed \(report.removedItemCount) card\(report.removedItemCount == 1 ? "" : "s"). Pinned and collected cards were kept.")
        } catch {
            show(userFacingDescription(error))
        }
        isClearingHistory = false
    }

    // MARK: - Capture

    func setCapturesClipboardOnLaunch(_ enabled: Bool) {
        settings.update { $0.capturesClipboardOnLaunch = enabled }
    }

    func setExcludedApplications(_ identifiers: [String]) {
        settings.update { $0.excludedApplications = identifiers.sorted() }
        environment.apply(settings: settings.settings)
    }

    func addExcludedApplication(_ identifier: String) {
        let trimmed = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var identifiers = settings.settings.excludedApplications
        guard !identifiers.contains(trimmed) else { return }
        identifiers.append(trimmed)
        setExcludedApplications(identifiers)
        newExcludedApplication = ""
        show("Kopi no longer captures from \(trimmed)")
    }

    func removeExcludedApplication(_ identifier: String) {
        setExcludedApplications(settings.settings.excludedApplications.filter { $0 != identifier })
    }

    // MARK: - Shortcut

    func setHotkey(_ hotkey: HotkeyDefinition) {
        settings.update { $0.hotkey = hotkey }
        show("Shortcut set to \(hotkey.displayString)")
    }

    func setHotkeyEnabled(_ enabled: Bool) {
        settings.update { $0.isHotkeyEnabled = enabled }
    }

    func setRecordingShortcut(_ recording: Bool) {
        isRecordingShortcut = recording
    }

    func setHoverReveal(_ reveal: HoverReveal) {
        settings.update { $0.hoverReveal = reveal }
    }

    func setDismissesOnOutsideClick(_ dismisses: Bool) {
        settings.update { $0.dismissesOnOutsideClick = dismisses }
    }

    func setAppearance(_ appearance: AppearancePreference) {
        settings.update { $0.appearance = appearance }
    }

    // MARK: - Launch at login

    func setLaunchAtLogin(_ enabled: Bool) {
        let status = LaunchAtLogin.setEnabled(enabled)
        launchAtLoginStatus = status
        settings.update { $0.launchAtLogin = enabled && status.isOn }
        if case .unsupported(let reason) = status {
            show("Launch at login is unavailable: \(reason)")
        } else {
            show(enabled ? "Kopi will open at login" : "Kopi will not open at login")
        }
    }

    // MARK: - Presentation and capture

    func setAnimationSpeed(_ speed: AnimationSpeed) {
        settings.update { $0.animationSpeed = speed }
    }

    func setCompactCards(_ compact: Bool) {
        settings.update { $0.usesCompactCards = compact }
    }

    func setCapturePaused(_ paused: Bool) {
        settings.update { $0.isCapturePaused = paused }
    }

    // MARK: - Messages

    func resetSettings() {
        settings.reset()
        isConfirmingReset = false
        show("Settings reset")
    }

    private func show(_ text: String) {
        message = text
        messageTask?.cancel()
        messageTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else { return }
            self?.message = nil
        }
    }
}
