import CopilyCore

extension SourceAppInfo {
    /// Present this app's current name without rewriting historical clipboard data.
    var copilyDisplayName: String? {
        switch bundleIdentifier {
        case "com.velpy.app", "com.velpy.Velpy", "com.copily.app": "Copily"
        default: displayName
        }
    }
}
