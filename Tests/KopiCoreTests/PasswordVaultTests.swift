import CryptoKit
import Foundation
import Testing
@testable import KopiCore
@testable import Kopi

@Suite("Encrypted passwords")
struct PasswordVaultTests {
    @Test @MainActor func passwordComposerSavesAndViewsWithoutAnAdditionalUnlockStep() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("kopi-composer-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let auth = TestVaultAuthentication()
        let model = PasswordsViewModel(vault: PasswordVault(url: PasswordVault.storageURL(in: root), authentication: auth))
        model.setVisible(true)
        await model.activate()
        #expect(!model.authenticationUnavailable)
        model.beginCreate()
        model.draft?.title = "Account"
        model.draft?.password = "secret"
        await model.save()
        #expect(model.draft == nil)
        #expect(model.message == nil)
        #expect(await auth.attempts == 0)
        let record = try #require(model.records.first)
        await model.reveal(record)
        #expect(model.revealed?.password == "secret")
        #expect(await auth.attempts == 1)
        model.lock()
        #expect(model.revealed == nil)
    }

    @Test @MainActor func missingMacAuthenticationShowsSetupMessageAndDoesNotSave() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("kopi-no-auth-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let url = PasswordVault.storageURL(in: root)
        let auth = TestVaultAuthentication(available: false)
        let model = PasswordsViewModel(vault: PasswordVault(url: url, authentication: auth))
        await model.activate()
        #expect(model.authenticationUnavailable)
        #expect(model.message == PasswordVaultError.authenticationUnavailable.localizedDescription)
        model.beginCreate()
        #expect(model.message == PasswordVaultError.authenticationUnavailable.localizedDescription)
        model.draft?.title = "Account"
        model.draft?.password = "secret"
        await model.save()
        #expect(!FileManager.default.fileExists(atPath: url.path))
        #expect(!FileManager.default.fileExists(atPath: FileVaultKeyStore.keyURL(forVaultAt: url).path))
        #expect(await auth.attempts == 0)
    }

    @Test func existingVaultWithAKeyKeepsWorkingUnchanged() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("kopi-existing-vault-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let url = PasswordVault.storageURL(in: root)
        #expect(url == root.appendingPathComponent("vault.json"))
        let auth = TestVaultAuthentication()
        let vault = PasswordVault(url: url, authentication: auth)
        let secret = PasswordSecret(username: "", password: "existing-secret")
        let record = try await vault.add(title: "Existing", secret: secret)
        let keyURL = FileVaultKeyStore.keyURL(forVaultAt: url)
        #expect(FileManager.default.fileExists(atPath: keyURL.path))
        let restarted = PasswordVault(url: PasswordVault.storageURL(in: root), authentication: auth)
        #expect(try await restarted.needsKeyMigration() == false)
        #expect(try await restarted.reveal(record.id) == secret)
        #expect(await auth.attempts == 1)
    }

    @Test func missingKeyNeverGeneratesAReplacementOrOverwritesRecords() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("kopi-missing-key-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let url = PasswordVault.storageURL(in: root)
        let auth = TestVaultAuthentication()
        let vault = PasswordVault(url: url, authentication: auth)
        let record = try await vault.add(title: "Account", secret: PasswordSecret(username: "", password: "secret"))
        let bytes = try Data(contentsOf: url)
        let keyURL = FileVaultKeyStore.keyURL(forVaultAt: url)
        try FileManager.default.removeItem(at: keyURL)
        #expect(PasswordVault.storageURL(in: root) == url)
        #expect(try await vault.needsKeyMigration())
        await #expect(throws: PasswordVaultError.keyMigrationRequired) { try await vault.reveal(record.id) }
        await #expect(throws: PasswordVaultError.keyMigrationRequired) {
            try await vault.add(title: "New", secret: PasswordSecret(username: "", password: "new-secret"))
        }
        #expect(!FileManager.default.fileExists(atPath: keyURL.path))
        #expect(try Data(contentsOf: url) == bytes)
        #expect(await auth.attempts == 0)
    }

    @Test func archivedVaultIsListedAndBlocksRevealAndAddUntilMigrated() async throws {
        let archived = try await makeArchivedVault()
        defer { try? FileManager.default.removeItem(at: archived.url.deletingLastPathComponent()) }
        let auth = TestVaultAuthentication()
        let probe = TestArchivedKey(key: archived.key)
        let vault = PasswordVault(url: archived.url, authentication: auth, archivedKey: { probe.read() })
        let bytes = try Data(contentsOf: archived.url)

        #expect(try await vault.records().map(\.title) == ["Earlier build"])
        #expect(try await vault.needsKeyMigration())
        await #expect(throws: PasswordVaultError.keyMigrationRequired) { try await vault.reveal(archived.record.id) }
        await #expect(throws: PasswordVaultError.keyMigrationRequired) {
            try await vault.add(title: "New", secret: PasswordSecret(username: "", password: "new-secret"))
        }
        #expect(!FileManager.default.fileExists(atPath: archived.keyURL.path))
        #expect(try Data(contentsOf: archived.url) == bytes)
        #expect(await auth.attempts == 0)
        #expect(probe.count == 0)
    }

    @Test func explicitMigrationAdoptsTheArchivedKeyAndWritesAnOwnerOnlyKeyFile() async throws {
        let archived = try await makeArchivedVault()
        defer { try? FileManager.default.removeItem(at: archived.url.deletingLastPathComponent()) }
        let auth = TestVaultAuthentication()
        let probe = TestArchivedKey(key: archived.key)
        let vault = PasswordVault(url: archived.url, authentication: auth, archivedKey: { probe.read() })
        #expect(try await vault.needsKeyMigration())

        try await vault.migrateArchivedKey()

        #expect(try await vault.needsKeyMigration() == false)
        #expect(try Data(contentsOf: archived.keyURL) == archived.key)
        #expect(try permissions(archived.keyURL) == 0o600)
        #expect(try permissions(archived.keyURL.deletingLastPathComponent()) == 0o700)
        #expect(try await vault.reveal(archived.record.id) == archived.secret)
        #expect(probe.count == 1)
    }

    @Test func migrationWithoutAnArchivedKeyReportsAClearError() async throws {
        let archived = try await makeArchivedVault()
        defer { try? FileManager.default.removeItem(at: archived.url.deletingLastPathComponent()) }
        let vault = PasswordVault(url: archived.url, authentication: TestVaultAuthentication(), archivedKey: { nil })

        await #expect(throws: PasswordVaultError.archivedKeyUnavailable) { try await vault.migrateArchivedKey() }

        #expect(try await vault.needsKeyMigration())
        #expect(!FileManager.default.fileExists(atPath: archived.keyURL.path))
        #expect(try await vault.records().count == 1)
    }

    @Test func startFreshDiscardsArchivedRecordsAndLeavesAWorkingVault() async throws {
        let archived = try await makeArchivedVault()
        defer { try? FileManager.default.removeItem(at: archived.url.deletingLastPathComponent()) }
        let probe = TestArchivedKey(key: archived.key)
        let vault = PasswordVault(url: archived.url, authentication: TestVaultAuthentication(), archivedKey: { probe.read() })
        #expect(try await vault.needsKeyMigration())

        try await vault.startFresh()

        #expect(try await vault.records().isEmpty)
        #expect(try await vault.needsKeyMigration() == false)
        #expect(FileManager.default.fileExists(atPath: archived.keyURL.path))
        #expect(try permissions(archived.keyURL) == 0o600)
        let secret = PasswordSecret(username: "account", password: "fresh-secret")
        let record = try await vault.add(title: "Fresh", secret: secret)
        #expect(try await vault.reveal(record.id) == secret)
        #expect(probe.count == 0)
    }

    @Test @MainActor func reopeningAnArchivedVaultDoesNotReadItsKeyUntilExplicitMigration() async throws {
        let archived = try await makeArchivedVault()
        defer { try? FileManager.default.removeItem(at: archived.url.deletingLastPathComponent()) }
        let probe = TestArchivedKey(key: archived.key)
        let bytes = try Data(contentsOf: archived.url)

        for _ in 0..<2 {
            let model = PasswordsViewModel(vault: PasswordVault(
                url: archived.url, authentication: TestVaultAuthentication(), archivedKey: { probe.read() }
            ))
            await model.activate()
            #expect(model.needsKeyMigration)
            #expect(model.records.map(\.id) == [archived.record.id])
            #expect(probe.count == 0)
            #expect(!FileManager.default.fileExists(atPath: archived.keyURL.path))
            #expect(try Data(contentsOf: archived.url) == bytes)
        }

        let vault = PasswordVault(url: archived.url, authentication: TestVaultAuthentication(), archivedKey: { probe.read() })
        try await vault.migrateArchivedKey()
        try await vault.migrateArchivedKey()
        let reopened = PasswordVault(url: archived.url, authentication: TestVaultAuthentication(), archivedKey: { probe.read() })
        #expect(try await reopened.needsKeyMigration() == false)
        #expect(try await reopened.reveal(archived.record.id) == archived.secret)
        #expect(probe.count == 1)
    }

    @Test @MainActor func archivedVaultAsksForAnExplicitChoiceBeforeReadingTheKeychain() async throws {
        let archived = try await makeArchivedVault()
        defer { try? FileManager.default.removeItem(at: archived.url.deletingLastPathComponent()) }
        let probe = TestArchivedKey(key: archived.key)
        let auth = TestVaultAuthentication()
        let model = PasswordsViewModel(
            vault: PasswordVault(url: archived.url, authentication: auth, archivedKey: { probe.read() })
        )
        model.setVisible(true)
        await model.activate()

        #expect(model.needsKeyMigration)
        #expect(model.records.map(\.title) == ["Earlier build"])
        await model.reveal(archived.record)
        #expect(model.revealed == nil)
        #expect(model.message == PasswordVaultError.keyMigrationRequired.localizedDescription)
        model.beginCreate()
        model.draft?.title = "New"
        model.draft?.password = "new-secret"
        await model.save()
        #expect(model.message == PasswordVaultError.keyMigrationRequired.localizedDescription)
        #expect(model.needsKeyMigration)
        #expect(probe.count == 0)
        #expect(await auth.attempts == 0)
    }

    @Test @MainActor func migratingFromTheBannerRestoresTheArchivedEntry() async throws {
        let archived = try await makeArchivedVault()
        defer { try? FileManager.default.removeItem(at: archived.url.deletingLastPathComponent()) }
        let model = PasswordsViewModel(
            vault: PasswordVault(
                url: archived.url,
                authentication: TestVaultAuthentication(),
                archivedKey: { archived.key }
            )
        )
        model.setVisible(true)
        await model.activate()
        #expect(model.needsKeyMigration)

        await model.migrate()

        #expect(model.needsKeyMigration == false)
        #expect(model.message == nil)
        await model.reveal(archived.record)
        #expect(model.revealed == archived.secret)
    }

    @Test @MainActor func startingFreshFromTheBannerLeavesAnEmptyWorkingVault() async throws {
        let archived = try await makeArchivedVault()
        defer { try? FileManager.default.removeItem(at: archived.url.deletingLastPathComponent()) }
        let model = PasswordsViewModel(
            vault: PasswordVault(
                url: archived.url,
                authentication: TestVaultAuthentication(),
                archivedKey: { archived.key }
            )
        )
        model.setVisible(true)
        await model.activate()
        #expect(model.needsKeyMigration)

        await model.startFresh(withConfirmation: false)

        #expect(model.records.isEmpty)
        #expect(model.needsKeyMigration == false)
        #expect(model.message == nil)
        #expect(FileManager.default.fileExists(atPath: archived.keyURL.path))
        #expect(try permissions(archived.keyURL) == 0o600)
    }

    private func fixture(auth: TestVaultAuthentication = TestVaultAuthentication()) -> (PasswordVault, URL, TestVaultKeys) {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("kopi-vault-tests-\(UUID())/vault.json")
        let keys = TestVaultKeys()
        return (PasswordVault(url: url, keys: keys, authentication: auth), url, keys)
    }

    /// A vault whose records came from a build that kept the key in the Keychain: the
    /// records exist and no `vault-key` file does.
    private struct ArchivedVault {
        let url: URL
        let keyURL: URL
        let key: Data
        let record: PasswordRecord
        let secret: PasswordSecret
    }

    private func makeArchivedVault() async throws -> ArchivedVault {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("kopi-archived-vault-\(UUID())/vault.json")
        let secret = PasswordSecret(username: "person@example.com", password: "earlier-secret")
        let vault = PasswordVault(url: url, authentication: TestVaultAuthentication())
        let record = try await vault.add(title: "Earlier build", secret: secret)
        let keyURL = FileVaultKeyStore.keyURL(forVaultAt: url)
        let key = try Data(contentsOf: keyURL)
        try FileManager.default.removeItem(at: keyURL)
        return ArchivedVault(url: url, keyURL: keyURL, key: key, record: record, secret: secret)
    }

    private func permissions(_ url: URL) throws -> Int? {
        (try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?.intValue
    }

    @Test func payloadIsEncryptedAndSurvivesRestart() async throws {
        let auth = TestVaultAuthentication()
        let (vault, url, keys) = fixture(auth: auth)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let secret = PasswordSecret(username: "private-account", password: "NeverStorePlainText!123")
        let record = try await vault.add(title: "Personal email", secret: secret)
        let bytes = try Data(contentsOf: url)
        let file = String(decoding: bytes, as: UTF8.self)
        #expect(!file.contains(secret.password))
        #expect(!file.contains(secret.username))
        let reopened = PasswordVault(url: url, keys: keys, authentication: auth)
        #expect(try await reopened.records().map(\.id) == [record.id])
        #expect(try await reopened.reveal(record.id) == secret)
        #expect(try await reopened.reveal(record.id) == secret)
        #expect(await auth.attempts == 2)
        let permissions = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
        #expect(permissions?.intValue == 0o600)
    }
    @Test func deniedAuthenticationNeverReadsTheDecryptionKey() async throws {
        let auth = TestVaultAuthentication()
        let (vault, url, keys) = fixture(auth: auth)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let record = try await vault.add(title: "Account", secret: PasswordSecret(username: "", password: "Secret"))
        let reads = keys.count
        await auth.deny()
        await #expect(throws: PasswordVaultError.self) { try await vault.reveal(record.id) }
        #expect(keys.count == reads)
        await #expect(throws: PasswordVaultError.self) { try await vault.delete(record.id) }
        #expect(try await vault.records().count == 1)
    }
    @Test func unavailableMacAuthenticationFailsClosedBeforeSaving() async throws {
        let (vault, url, keys) = fixture(auth: TestVaultAuthentication(available: false))
        await #expect(throws: PasswordVaultError.self) {
            try await vault.add(title: "Account", secret: PasswordSecret(username: "", password: "Secret"))
        }
        #expect(keys.count == 0)
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }
    @Test func tamperedRecordsCannotDecryptAndCorruptFilesAreNotOverwritten() async throws {
        let (vault, url, _) = fixture()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        _ = try await vault.add(title: "Account", secret: PasswordSecret(username: "", password: "Secret"))
        var rows = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [[String: Any]])
        let swapped = UUID()
        rows[0]["id"] = swapped.uuidString
        let tampered = try JSONSerialization.data(withJSONObject: rows)
        try tampered.write(to: url)
        await #expect(throws: (any Error).self) { try await vault.reveal(swapped) }
        #expect(try Data(contentsOf: url) == tampered)
        let corrupt = Data("not-json".utf8)
        try corrupt.write(to: url)
        await #expect(throws: PasswordVaultError.self) {
            try await vault.add(title: "New", secret: PasswordSecret(username: "", password: "Secret2"))
        }
        #expect(try Data(contentsOf: url) == corrupt)
    }
    @Test @MainActor func revealedPasswordsHideOnTimeoutAndWhenLeaving() async throws {
        let (vault, url, _) = fixture()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let record = try await vault.add(title: "Account", secret: PasswordSecret(username: "", password: "Secret"))
        let model = PasswordsViewModel(vault: vault, revealTimeout: .milliseconds(20))
        model.setVisible(true)
        await model.activate()
        #expect(model.revealed == nil)
        await model.reveal(record)
        #expect(model.revealed?.password == "Secret")
        // A loaded Intel CI runner may resume this task before the hide task.
        // Yield until the observable result, with a bounded failure deadline.
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while model.revealed != nil, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(model.revealed == nil)
        await model.reveal(record)
        model.setVisible(false)
        #expect(model.revealed == nil)
        await model.reveal(record)
        #expect(model.revealed == nil)
    }
}
actor TestVaultAuthentication: VaultAuthenticating {
    private let available: Bool
    private var approved = true
    private(set) var attempts = 0
    init(available: Bool = true) { self.available = available }
    func requireAvailable() throws { if !available { throw PasswordVaultError.authenticationUnavailable } }
    func authenticate() throws {
        attempts += 1
        guard available, approved else { throw PasswordVaultError.cancelled }
    }
    func deny() { approved = false }
}
final class TestVaultKeys: VaultKeyStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var reads = 0
    private var stored: Data?
    private let key = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
    var count: Int { lock.withLock { reads } }
    func hasStoredKey() -> Bool { lock.withLock { stored != nil } }
    func loadExisting() throws -> Data { lock.withLock { reads += 1; stored = key; return key } }
    func loadOrCreate() -> Data { lock.withLock { reads += 1; stored = key; return key } }
    func store(_ key: Data) { lock.withLock { stored = key } }
}
/// The archived keychain key a test pretends an earlier build left behind.
final class TestArchivedKey: @unchecked Sendable {
    private let lock = NSLock()
    private var lookups = 0
    private let key: Data?
    init(key: Data?) { self.key = key }
    var count: Int { lock.withLock { lookups } }
    func read() -> Data? { lock.withLock { lookups += 1; return key } }
}
