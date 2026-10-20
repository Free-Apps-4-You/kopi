/// Read-only identifiers from the previous release. These are migration inputs,
/// never current branding. Changing them would make existing user data invisible.
public enum LegacyAppIdentity {
    public static let supportDirectoryName = "Copily"
    public static let bundleIdentifier = "com.copily.app"
    public static let settingsSuiteName = "com.copily.Copily"
    public static let settingsStorageKey = "copily.settings"
    public static let settingsMigrationKey = "copily.settings.migrationCompleted"
    public static let metadataTable = "copily_metadata"
    public static let metadataMigration = "v3_copily_metadata"
}
