import KopiCore

extension SourceAppInfo {
    /// Present this app's current name without rewriting historical clipboard data.
    var kopiDisplayName: String? {
        switch bundleIdentifier {
        case "com.velpy.app", "com.velpy.Velpy", "com.copily.app", "com.kopi.app": "Kopi"
        default: displayName
        }
    }
}
