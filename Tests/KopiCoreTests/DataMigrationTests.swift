import Foundation
import Testing

@testable import KopiCore

@Suite("Application Support migration")
struct ApplicationDataMigrationTests {
    private func supportDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("kopi-support-migration-\(UUID().uuidString)", isDirectory: true)
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

    @Test("The immediately previous folder wins over the oldest archive")
    func newestArchiveWins() throws {
        let support = supportDirectory()
        defer { try? FileManager.default.removeItem(at: support) }
        try write("recent", to: support.appendingPathComponent("\(LegacyAppIdentity.supportDirectoryName)/history.sqlite"))
        try write("old", to: support.appendingPathComponent("Velpy/history.sqlite"))
        #expect(try ApplicationDataMigration.migrateSupportDirectoryIfNeeded(supportDirectory: support))
        #expect(try String(contentsOf: currentDirectory(in: support).appendingPathComponent("history.sqlite"), encoding: .utf8) == "recent")
        #expect(FileManager.default.fileExists(atPath: support.appendingPathComponent("Velpy/history.sqlite").path))
    }

    @Test("The oldest archive can upgrade directly to the current name")
    func oldestArchiveStillMigrates() throws {
        let support = supportDirectory()
        defer { try? FileManager.default.removeItem(at: support) }
        try write("old", to: support.appendingPathComponent("Velpy/history.sqlite"))
        #expect(try ApplicationDataMigration.migrateSupportDirectoryIfNeeded(supportDirectory: support))
        #expect(try String(contentsOf: currentDirectory(in: support).appendingPathComponent("history.sqlite"), encoding: .utf8) == "old")
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
        let currentName = "kopi.tests.current.\(UUID().uuidString)"
        let archivedName = "kopi.tests.archived.\(UUID().uuidString)"
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
            var stored = KopiSettings()
            stored.appearance = .dark
            stored.hoverReveal = HoverReveal(isEnabled: false, delay: 0.9)
            stored.usesCompactCards = true
            let blob = try JSONEncoder().encode(stored)
            archived.set(blob, forKey: "archive.settings")

            let migrated = KopiSettingsStore(defaults: current, archivedDefaults: archived)
            #expect(migrated.settings == stored)
            #expect(current.data(forKey: KopiSettingsStore.storageKey) == blob)

            // A later launch reads the copied value and never copies a second time.
            archived.set(try JSONEncoder().encode(KopiSettings()), forKey: "archive.settings")
            let reloaded = KopiSettingsStore(defaults: current, archivedDefaults: archived)
            #expect(reloaded.settings == stored)
            #expect(current.data(forKey: KopiSettingsStore.storageKey) == blob)
        }
    }

    @Test("Explicit default settings from the previous app are preserved")
    func importsExplicitPreviousDefaults() throws {
        try withSuites { current, archived in
            let blob = try JSONEncoder().encode(KopiSettings())
            archived.set(blob, forKey: LegacyAppIdentity.settingsStorageKey)
            let migrated = KopiSettingsStore(defaults: current, archivedDefaults: archived)
            #expect(migrated.settings == KopiSettings())
            #expect(current.data(forKey: KopiSettingsStore.storageKey) == blob)
        }
    }

    @Test("A previous-app reset prevents resurrection of older preferences")
    func importsPreviousReset() throws {
        try withSuites { current, archived in
            archived.set(true, forKey: LegacyAppIdentity.settingsMigrationKey)
            var stale = KopiSettings()
            stale.appearance = .dark
            archived.set(try JSONEncoder().encode(stale), forKey: "velpy.settings")
            let migrated = KopiSettingsStore(defaults: current, archivedDefaults: archived)
            #expect(migrated.settings == KopiSettings())
            #expect(current.bool(forKey: KopiSettingsStore.migrationKey))
        }
    }

    @Test("Reset is not undone by the archived suite on the next launch")
    func resetDoesNotReimport() throws {
        try withSuites { current, archived in
            var archivedSettings = KopiSettings()
            archivedSettings.appearance = .dark
            archived.set(try JSONEncoder().encode(archivedSettings), forKey: "archive.settings")

            let store = KopiSettingsStore(defaults: current, archivedDefaults: archived)
            #expect(store.settings == archivedSettings)
            store.reset()
            #expect(store.settings == KopiSettings())

            let relaunched = KopiSettingsStore(defaults: current, archivedDefaults: archived)
            #expect(relaunched.settings == KopiSettings())
        }
    }

    @Test("A value already stored in the new suite is not overwritten")
    func currentSettingsWin() throws {
        try withSuites { current, archived in
            var existing = KopiSettings()
            existing.appearance = .light
            let existingBlob = try JSONEncoder().encode(existing)
            current.set(existingBlob, forKey: KopiSettingsStore.storageKey)

            var archivedSettings = KopiSettings()
            archivedSettings.appearance = .dark
            archived.set(try JSONEncoder().encode(archivedSettings), forKey: "archive.settings")

            let store = KopiSettingsStore(defaults: current, archivedDefaults: archived)
            #expect(store.settings == existing)
            #expect(current.data(forKey: KopiSettingsStore.storageKey) == existingBlob)
        }
    }
}
