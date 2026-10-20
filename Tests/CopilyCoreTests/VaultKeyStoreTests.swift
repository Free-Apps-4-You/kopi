import Foundation
import Testing

@testable import CopilyCore

@Suite("Vault key storage")
struct VaultKeyStoreTests {
    private func directory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("copily-key-tests-\(UUID())", isDirectory: true)
    }

    private func permissions(_ url: URL) throws -> Int? {
        (try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?.intValue
    }

    @Test func createsAnOwnerOnlyKeyAndReusesIt() throws {
        let root = directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("vault-key")
        let store = FileVaultKeyStore(fileURL: file)

        let key = try store.loadOrCreate()
        #expect(key.count == 32)
        #expect(try store.loadOrCreate() == key)
        #expect(try permissions(file) == 0o600)
        #expect(try permissions(root) == 0o700)
    }

    @Test func readingAMissingKeyNeverCreatesOne() throws {
        let root = directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("vault-key")
        let store = FileVaultKeyStore(fileURL: file)
        #expect(throws: PasswordVaultError.self) { try store.loadExisting() }
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }

    @Test func rejectsAMalformedKeyFile() throws {
        let root = directory()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("vault-key")
        let damaged = Data([1, 2, 3])
        try damaged.write(to: file)

        let store = FileVaultKeyStore(fileURL: file)
        #expect(throws: PasswordVaultError.self) { try store.loadOrCreate() }
        #expect(try Data(contentsOf: file) == damaged)
    }

    @Test func storingAKeyKeepsItAcrossReopening() throws {
        let root = directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("vault-key")
        let key = Data(repeating: 5, count: 32)
        try FileVaultKeyStore(fileURL: file).store(key)

        let reopened = FileVaultKeyStore(fileURL: file)
        #expect(reopened.hasStoredKey())
        #expect(try reopened.loadExisting() == key)
        #expect(try reopened.loadOrCreate() == key)
    }

    @Test func storesAndReportsAKeyWithoutTheKeychain() throws {
        let root = directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("vault-key")
        let store = FileVaultKeyStore(fileURL: file)
        let key = Data(repeating: 7, count: 32)

        #expect(!store.hasStoredKey())
        try store.store(key)

        #expect(store.hasStoredKey())
        #expect(try store.loadExisting() == key)
        #expect(try permissions(file) == 0o600)
        #expect(try permissions(root) == 0o700)
    }

    @Test func refusesAKeyOfTheWrongLength() throws {
        let root = directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("vault-key")
        let store = FileVaultKeyStore(fileURL: file)

        #expect(throws: PasswordVaultError.self) { try store.store(Data([1, 2, 3])) }
        #expect(!store.hasStoredKey())
    }
}

