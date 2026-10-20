import Foundation

/// One-time moves of data written by earlier builds, so renaming the application
/// never loses clipboard history, assets, passwords or settings.
///
/// The archived names below belong to data that already exists on disk. They are
/// read once, on first launch, and never written again.
public enum ApplicationDataMigration {
    /// Application Support folder used by earlier builds.
    ///
    /// This is an archived directory name: it identifies data written by earlier
    /// builds and is only moved away from.
    public static let archivedSupportDirectoryName = LegacyAppIdentity.supportDirectoryName
    public static let archivedSupportDirectoryNames = [archivedSupportDirectoryName, "Velpy"]

    /// Application Support folder the application uses now.
    public static let supportDirectoryName = "Kopi"

    /// Moves the archived Application Support folder to
    /// `~/Library/Application Support/Kopi` once, before any store opens.
    ///
    /// The whole directory moves together, so `history.sqlite`, `Assets` and
    /// `Passwords` keep their relative layout and references.
    ///
    /// - Returns: `true` when a directory was moved.
    @discardableResult
    public static func migrateSupportDirectoryIfNeeded(
        supportDirectory: URL? = nil,
        fileManager: FileManager = .default
    ) throws -> Bool {
        guard let supportDirectory = supportDirectory
            ?? fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        else { return false }

        for archivedName in archivedSupportDirectoryNames {
            if try migrateDirectory(
                from: supportDirectory.appendingPathComponent(archivedName, isDirectory: true),
                to: supportDirectory.appendingPathComponent(supportDirectoryName, isDirectory: true),
                fileManager: fileManager
            ) { return true }
        }
        return false
    }

    /// Moves `archived` to `current` when only the archived directory exists.
    ///
    /// Injectable URLs keep the move testable without touching the real home
    /// directory. Nothing happens when the current directory already exists, so a
    /// completed or interrupted upgrade is never merged into newer data.
    ///
    /// - Returns: `true` when the directory was moved.
    @discardableResult
    public static func migrateDirectory(
        from archived: URL,
        to current: URL,
        fileManager: FileManager = .default
    ) throws -> Bool {
        guard !fileManager.fileExists(atPath: current.path) else { return false }
        guard fileManager.fileExists(atPath: archived.path) else { return false }

        try fileManager.createDirectory(
            at: current.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try fileManager.moveItem(at: archived, to: current)
        return true
    }
}
