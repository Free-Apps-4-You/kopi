import Foundation
import Testing

@testable import CopilyCore

@Suite("Application Support migration")
struct ApplicationDataMigrationTests {
    private func supportDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("copily-support-migration-\(UUID().uuidString)", isDirectory: true)
    }

    private func archivedDirectory(in support: URL) -> URL {
        support.appendingPathComponent(ApplicationDataMigration.archivedSupportDirectoryName, isDirectory: true)
    }

    private func currentDirectory(in support: URL) -> URL {
        support.appendingPathComponent(ApplicationDataMigration.supportDirectoryName, isDirectory: true)
    }

    private func write(_ contents: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: url)
    }

    @Test("The archived folder moves once")
    func movesOnce() throws {
        let support = supportDirectory()
        defer { try? FileManager.default.removeItem(at: support) }
        try FileManager.default.createDirectory(at: archivedDirectory(in: support), withIntermediateDirectories: true)

        #expect(try ApplicationDataMigration.migrateSupportDirectoryIfNeeded(supportDirectory: support))
        #expect(FileManager.default.fileExists(atPath: currentDirectory(in: support).path))
        #expect(!FileManager.default.fileExists(atPath: archivedDirectory(in: support).path))
        #expect(try ApplicationDataMigration.migrateSupportDirectoryIfNeeded(supportDirectory: support) == false)
    }

    @Test("History, assets and passwords move together")
    func keepsEveryFile() throws {
        let support = supportDirectory()
        defer { try? FileManager.default.removeItem(at: support) }
        let archived = archivedDirectory(in: support)
        try write("history", to: archived.appendingPathComponent("history.sqlite"))
        try write("asset", to: archived.appendingPathComponent("Assets/image.png"))
        try write("vault", to: archived.appendingPathComponent("Passwords/vault.json"))

        #expect(try ApplicationDataMigration.migrateSupportDirectoryIfNeeded(supportDirectory: support))

        let current = currentDirectory(in: support)
        #expect(try String(contentsOf: current.appendingPathComponent("history.sqlite"), encoding: .utf8) == "history")
        #expect(try String(contentsOf: current.appendingPathComponent("Assets/image.png"), encoding: .utf8) == "asset")
        #expect(try String(contentsOf: current.appendingPathComponent("Passwords/vault.json"), encoding: .utf8) == "vault")
    }

    @Test("An existing current folder is never replaced")
    func currentDirectoryWins() throws {
        let support = supportDirectory()
        defer { try? FileManager.default.removeItem(at: support) }
        let current = currentDirectory(in: support)
        let archived = archivedDirectory(in: support)
        try write("new history", to: current.appendingPathComponent("history.sqlite"))
        try write("old history", to: archived.appendingPathComponent("history.sqlite"))

        #expect(try ApplicationDataMigration.migrateSupportDirectoryIfNeeded(supportDirectory: support) == false)
        #expect(try String(contentsOf: current.appendingPathComponent("history.sqlite"), encoding: .utf8) == "new history")
        #expect(FileManager.default.fileExists(atPath: archived.appendingPathComponent("history.sqlite").path))
    }

    @Test("A first install has nothing to migrate")
    func nothingToMove() throws {
        let support = supportDirectory()
        defer { try? FileManager.default.removeItem(at: support) }

        #expect(try ApplicationDataMigration.migrateSupportDirectoryIfNeeded(supportDirectory: support) == false)
        #expect(!FileManager.default.fileExists(atPath: currentDirectory(in: support).path))
    }
}

@Suite("Settings migration")
@MainActor
struct SettingsMigrationTests {
    /// Two suites in a temporary defaults domain, removed when the test ends.
    private func withSuites(_ body: (UserDefaults, UserDefaults) throws -> Void) throws {
        let currentName = "copily.tests.current.\(UUID().uuidString)"
        let archivedName = "copily.tests.archived.\(UUID().uuidString)"
        let current = try #require(UserDefaults(suiteName: currentName))
        let archived = try #require(UserDefaults(suiteName: archivedName))
        defer {
            current.removePersistentDomain(forName: currentName)
            archived.removePersistentDomain(forName: archivedName)
        }
        try body(current, archived)
    }

    @Test("Settings from the earlier suite are copied into the new suite once")
    func copiesArchivedSettings() throws {
        try withSuites { current, archived in
            var stored = CopilySettings()
            stored.appearance = .dark
            stored.hoverReveal = HoverReveal(isEnabled: false, delay: 0.9)
            stored.usesCompactCards = true
            let blob = try JSONEncoder().encode(stored)
            archived.set(blob, forKey: "archive.settings")

            let migrated = CopilySettingsStore(defaults: current, archivedDefaults: archived)
            #expect(migrated.settings == stored)
            #expect(current.data(forKey: CopilySettingsStore.storageKey) == blob)

            // A later launch reads the copied value and never copies a second time.
            archived.set(try JSONEncoder().encode(CopilySettings()), forKey: "archive.settings")
            let reloaded = CopilySettingsStore(defaults: current, archivedDefaults: archived)
            #expect(reloaded.settings == stored)
            #expect(current.data(forKey: CopilySettingsStore.storageKey) == blob)
        }
    }

    @Test("Reset is not undone by the archived suite on the next launch")
    func resetDoesNotReimport() throws {
        try withSuites { current, archived in
            var archivedSettings = CopilySettings()
            archivedSettings.appearance = .dark
            archived.set(try JSONEncoder().encode(archivedSettings), forKey: "archive.settings")

            let store = CopilySettingsStore(defaults: current, archivedDefaults: archived)
            #expect(store.settings == archivedSettings)
            store.reset()
            #expect(store.settings == CopilySettings())

            let relaunched = CopilySettingsStore(defaults: current, archivedDefaults: archived)
            #expect(relaunched.settings == CopilySettings())
        }
    }

    @Test("A value already stored in the new suite is not overwritten")
    func currentSettingsWin() throws {
        try withSuites { current, archived in
            var existing = CopilySettings()
            existing.appearance = .light
            let existingBlob = try JSONEncoder().encode(existing)
            current.set(existingBlob, forKey: CopilySettingsStore.storageKey)

            var archivedSettings = CopilySettings()
            archivedSettings.appearance = .dark
            archived.set(try JSONEncoder().encode(archivedSettings), forKey: "archive.settings")

            let store = CopilySettingsStore(defaults: current, archivedDefaults: archived)
            #expect(store.settings == existing)
            #expect(current.data(forKey: CopilySettingsStore.storageKey) == existingBlob)
        }
    }
}
