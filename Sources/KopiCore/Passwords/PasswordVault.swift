import CryptoKit
import Foundation
import LocalAuthentication
import Security

public struct PasswordRecord: Identifiable, Codable, Sendable, Equatable {
    public let id: UUID
    public let title: String
    let encrypted: Data
}
public struct PasswordSecret: Codable, Sendable, Equatable {
    public var username: String
    public var password: String
    public init(username: String, password: String) { self.username = username; self.password = password }
}
public enum PasswordVaultError: Error, LocalizedError, Sendable, Equatable {
    case authenticationUnavailable, cancelled, storage(OSStatus), corrupt, invalidInput
    case keyMigrationRequired, archivedKeyUnavailable
    public var errorDescription: String? {
        switch self {
        case .authenticationUnavailable: "Set a Mac login password in System Settings to use Passwords. Touch ID is optional."
        case .cancelled: "Authentication was cancelled. The password stays hidden."
        case .storage(let status): "The secure vault could not be accessed (\(status))."
        case .corrupt: "The password vault could not be read. Its data has been preserved."
        case .invalidInput: "Enter a title and a password."
        case .keyMigrationRequired: "This password was saved by an earlier build of Kopi. Choose Migrate or Start Fresh in the Passwords tab."
        case .archivedKeyUnavailable: "The earlier vault key is not available from the keychain. Approve the macOS request when it appears, or choose Start Fresh to replace the old entry."
        }
    }
}
public protocol VaultAuthenticating: Sendable {
    func requireAvailable() async throws
    func authenticate() async throws
}
public struct MacVaultAuthentication: VaultAuthenticating {
    public init() {}
    public func requireAvailable() async throws {
        let context = LAContext()
        defer { context.invalidate() }
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: nil) else { throw PasswordVaultError.authenticationUnavailable }
    }
    public func authenticate() async throws {
        let context = LAContext()
        defer { context.invalidate() }
        context.localizedCancelTitle = "Keep Hidden"
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: nil) else { throw PasswordVaultError.authenticationUnavailable }
        do {
            guard try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "Reveal this password in Kopi") else {
                throw PasswordVaultError.cancelled
            }
        } catch let error as LAError where error.code == .passcodeNotSet {
            throw PasswordVaultError.authenticationUnavailable
        } catch { throw PasswordVaultError.cancelled }
    }
}

/// The vault key. Only ``PasswordVault`` reads, creates or replaces it.
public protocol VaultKeyStoring: Sendable {
    /// Whether a key is stored, without reading it and without touching the Keychain.
    func hasStoredKey() -> Bool
    /// The stored key; throws when no key is stored or the stored one is unusable.
    func loadExisting() throws -> Data
    /// The stored key, or a new key when none is stored.
    func loadOrCreate() throws -> Data
    /// Stores a key, which only an explicit migration does.
    func store(_ key: Data) throws
}

/// The archived service name must stay unchanged so earlier passwords remain recoverable.
/// Only the explicit Passwords > Migrate action reads this Keychain item.
public enum ArchivedVaultKeychain {
    public static let service = "com.velpy.app.password-vault-key"

    /// The archived key, with the system's keychain prompt allowed after user action.
    public static func readKeyWithInteraction() -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecUseAuthenticationContext as String: LAContext()
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              data.count == 32
        else { return nil }
        return data
    }
}

/// The 32-byte vault key, kept as an owner-only file beside the vault.
///
/// The key deliberately does not live in the Keychain: a Keychain item's default ACL
/// trusts the exact code signature that created it, and a development build signed ad
/// hoc changes identity with every build, so macOS would keep asking for the login
/// keychain password. The vault stays AES-GCM encrypted; the key file is written with
/// owner-only permissions inside an owner-only directory, and reading a stored password
/// still requires the system authentication that ``PasswordVault`` performs.
public struct FileVaultKeyStore: VaultKeyStoring {
    private let fileURL: URL
    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    /// The key file that belongs to the vault at `url`.
    public static func keyURL(forVaultAt url: URL) -> URL {
        url.deletingLastPathComponent().appendingPathComponent("vault-key")
    }

    public func hasStoredKey() -> Bool {
        FileManager.default.fileExists(atPath: fileURL.path)
    }

    public func loadExisting() throws -> Data {
        guard let key = try read() else { throw PasswordVaultError.corrupt }
        return key
    }

    public func loadOrCreate() throws -> Data {
        if let key = try read() { return key }
        let key = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
        try write(key)
        return key
    }

    public func store(_ key: Data) throws {
        try write(key)
    }

    private func read() throws -> Data? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        guard let data = try? Data(contentsOf: fileURL), data.count == 32 else {
            throw PasswordVaultError.corrupt
        }
        return data
    }

    private func write(_ key: Data) throws {
        guard key.count == 32 else { throw PasswordVaultError.corrupt }
        let directory = fileURL.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try key.write(to: fileURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        } catch {
            throw PasswordVaultError.storage(errSecIO)
        }
    }
}

/// Password payloads never enter clipboard history, search indexes, logs or preferences.
/// The authenticated reveal method is the only path that decrypts a stored credential.
///
/// A vault written by an earlier build keeps its key in the Keychain, and the current
/// signature cannot read that item without the login keychain password. Such records
/// are listed but stay encrypted until the user chooses to migrate the archived key or
/// to start fresh. Only an explicit ``migrateArchivedKey()`` reads the Keychain;
/// launch, listing records, and checking migration status never access it.
public actor PasswordVault {
    private let url: URL
    private let keys: any VaultKeyStoring
    private let authentication: any VaultAuthenticating
    private let archivedKey: @Sendable () -> Data?

    public init(
        url: URL,
        keys: (any VaultKeyStoring)? = nil,
        authentication: any VaultAuthenticating = MacVaultAuthentication(),
        archivedKey: (@Sendable () -> Data?)? = nil
    ) {
        self.url = url
        self.keys = keys ?? FileVaultKeyStore(fileURL: FileVaultKeyStore.keyURL(forVaultAt: url))
        self.authentication = authentication
        self.archivedKey = archivedKey ?? ArchivedVaultKeychain.readKeyWithInteraction
    }
    /// The Passwords folder in the application's Application Support directory.
    static var defaultPasswordsDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Kopi/Passwords", isDirectory: true)
    }

    public static func defaultURL() -> URL {
        storageURL(in: defaultPasswordsDirectory)
    }

    /// The one vault location: `vault.json` with `vault-key` beside it.
    static func storageURL(in directory: URL) -> URL {
        directory.appendingPathComponent("vault.json")
    }

    public func records() throws -> [PasswordRecord] { try read() }

    /// Whether stored records have no key beside them, which is what a vault from an
    /// earlier build looks like. Only the Keychain holds that key.
    public func needsKeyMigration() throws -> Bool {
        guard !keys.hasStoredKey() else { return false }
        return try !read().isEmpty
    }

    public func requireAuthenticationAvailable() async throws {
        try await authentication.requireAvailable()
    }

    /// Adopts the key an earlier build kept in the Keychain, so its records open again.
    ///
    /// This is the only path that may show the login keychain prompt, and only the
    /// explicit Migrate action reaches it. Does nothing when a key is already stored,
    /// which never reads the Keychain.
    public func migrateArchivedKey() throws {
        guard !keys.hasStoredKey() else { return }
        guard let key = archivedKey(), key.count == 32 else { throw PasswordVaultError.archivedKeyUnavailable }
        try keys.store(key)
    }

    /// Discards the records of an earlier build and starts a new, empty vault with a
    /// key of its own. Never reads the Keychain and never prompts.
    public func startFresh() throws {
        try write([])
        _ = try keys.loadOrCreate()
    }

    private func encryptionKey(forExistingRecords exists: Bool) throws -> Data {
        if exists { return try keys.loadExisting() }
        return try keys.loadOrCreate()
    }

    private func requireNoKeyMigration() throws {
        if try needsKeyMigration() { throw PasswordVaultError.keyMigrationRequired }
    }

    @discardableResult public func add(title: String, secret: PasswordSecret) async throws -> PasswordRecord {
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !secret.password.isEmpty else { throw PasswordVaultError.invalidInput }
        try requireNoKeyMigration()
        try await authentication.requireAvailable()
        var records = try read()
        let key = try encryptionKey(forExistingRecords: !records.isEmpty)
        let id = UUID()
        let data = try JSONEncoder().encode(secret)
        let sealed = try AES.GCM.seal(data, using: SymmetricKey(data: key), authenticating: Data(id.uuidString.utf8))
        guard let encrypted = sealed.combined else { throw PasswordVaultError.corrupt }
        let record = PasswordRecord(id: id, title: title, encrypted: encrypted)
        records.append(record)
        try write(records)
        return record
    }
    public func reveal(_ id: UUID) async throws -> PasswordSecret {
        try requireNoKeyMigration()
        // A fresh system authentication is required for every reveal, even after another reveal.
        try await authentication.authenticate()
        guard let record = try read().first(where: { $0.id == id }) else { throw PasswordVaultError.corrupt }
        let key = try encryptionKey(forExistingRecords: true)
        let box = try AES.GCM.SealedBox(combined: record.encrypted)
        let data: Data
        do {
            data = try AES.GCM.open(box, using: SymmetricKey(data: key), authenticating: Data(id.uuidString.utf8))
        } catch {
            throw PasswordVaultError.corrupt
        }
        return try JSONDecoder().decode(PasswordSecret.self, from: data)
    }
    public func delete(_ id: UUID) async throws {
        try await authentication.authenticate()
        try write(read().filter { $0.id != id })
    }
    private func read() throws -> [PasswordRecord] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        do { return try JSONDecoder().decode([PasswordRecord].self, from: Data(contentsOf: url)) }
        catch { throw PasswordVaultError.corrupt }
    }
    private func write(_ records: [PasswordRecord]) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try JSONEncoder().encode(records).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
