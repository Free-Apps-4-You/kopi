import AppKit
import Combine
import CopilyCore

@MainActor
final class PasswordsViewModel: ObservableObject {
    struct Draft {
        var title = ""
        var username = ""
        var password = ""
        var hasChanges: Bool { !title.isEmpty || !username.isEmpty || !password.isEmpty }
    }
    @Published private(set) var records: [PasswordRecord] = []
    @Published var draft: Draft?
    @Published private(set) var revealed: PasswordSecret?
    @Published private(set) var revealedID: UUID?
    @Published private(set) var isBusy = false
    @Published private(set) var authenticationUnavailable = false
    /// A vault from an earlier build whose keychain key this signature cannot read.
    @Published private(set) var needsKeyMigration = false
    @Published var message: String?
    var onRequestCancel: (() -> Void)?
    private let vault: PasswordVault
    private var request = UUID()
    private var hideTask: Task<Void, Never>?
    private var visible = false
    private var sessionObservers: VaultSessionObservers?
    private let revealTimeout: Duration
    init(vault: PasswordVault = PasswordVault(url: PasswordVault.defaultURL()), revealTimeout: Duration = .seconds(20)) {
        self.vault = vault
        self.revealTimeout = revealTimeout
        sessionObservers = VaultSessionObservers { [weak self] in self?.lock() }
    }
    func activate() async { await reload() }
    func setVisible(_ value: Bool) { visible = value; if !value { lock() } }
    func reload() async {
        do {
            records = try await vault.records()
            needsKeyMigration = try await vault.needsKeyMigration()
            try await vault.requireAuthenticationAvailable()
            if authenticationUnavailable { message = nil }
            authenticationUnavailable = false
        }
        catch {
            if let error = error as? PasswordVaultError, case .authenticationUnavailable = error {
                authenticationUnavailable = true
            }
            message = error.localizedDescription
        }
    }
    func beginCreate() {
        lock(); draft = Draft()
        message = authenticationUnavailable ? PasswordVaultError.authenticationUnavailable.localizedDescription : nil
    }
    func cancel() { if let onRequestCancel { onRequestCancel() } else { discardDraft() } }
    func discardDraft() { draft = nil; message = nil }
    /// Asks macOS for the key an earlier build left in the keychain, once.
    func migrate() async {
        guard !isBusy else { return }
        lock()
        isBusy = true
        defer { isBusy = false }
        do {
            try await vault.migrateArchivedKey()
            message = nil
            await reload()
        } catch { message = error.localizedDescription }
    }
    /// Discards the vault of an earlier build and starts an empty one.
    ///
    /// The confirmation is an `NSAlert` here, so the view needs no state for it; callers
    /// that have already asked pass `withConfirmation: false`.
    func startFresh(withConfirmation: Bool = true) async {
        guard !isBusy else { return }
        if withConfirmation, !confirmStartFresh() { return }
        lock()
        isBusy = true
        defer { isBusy = false }
        do {
            try await vault.startFresh()
            message = nil
            await reload()
        } catch { message = error.localizedDescription }
    }
    private func confirmStartFresh() -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Start Fresh and discard the old password?"
        alert.informativeText = "The entry saved by an earlier Copily build cannot be read without its old key. Starting fresh removes it for good and creates an empty vault."
        alert.addButton(withTitle: "Start Fresh")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        return alert.runModal() == .alertFirstButtonReturn
    }
    func save() async {
        guard let draft, !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            _ = try await vault.add(title: draft.title, secret: PasswordSecret(username: draft.username, password: draft.password))
            self.draft = nil
            message = nil
            await reload()
        } catch { message = error.localizedDescription }
    }
    func reveal(_ record: PasswordRecord) async {
        guard visible, !isBusy else { return }
        lock()
        let token = UUID(); request = token
        isBusy = true
        defer { isBusy = false }
        do {
            let secret = try await vault.reveal(record.id)
            guard request == token, visible else { return }
            revealed = secret; revealedID = record.id
            // Count from the reveal, even if a busy UI delays starting this task.
            let deadline = ContinuousClock.now.advanced(by: revealTimeout)
            hideTask = Task { [weak self] in
                do { try await Task.sleep(until: deadline, clock: .continuous) } catch { return }
                guard !Task.isCancelled, self?.request == token else { return }
                self?.lock()
            }
        } catch { if request == token { message = error.localizedDescription } }
    }
    func delete(_ record: PasswordRecord) async {
        guard !isBusy else { return }
        lock()
        isBusy = true
        defer { isBusy = false }
        do { try await vault.delete(record.id); lock(); await reload() }
        catch { message = error.localizedDescription }
    }
    func lock() { request = UUID(); revealed = nil; revealedID = nil; hideTask?.cancel(); hideTask = nil }
    deinit { hideTask?.cancel() }
}

private final class VaultSessionObservers: @unchecked Sendable {
    private let center: NotificationCenter
    private let tokens: [NSObjectProtocol]
    @MainActor init(onLock: @escaping @MainActor @Sendable () -> Void) {
        let center = NSWorkspace.shared.notificationCenter
        self.center = center
        tokens = [NSWorkspace.sessionDidResignActiveNotification, NSWorkspace.willSleepNotification].map { name in
            center.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { onLock() }
            }
        }
    }
    deinit { tokens.forEach(center.removeObserver) }
}
