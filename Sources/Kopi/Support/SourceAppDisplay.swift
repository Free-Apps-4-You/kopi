import KopiCore

extension SourceAppInfo {
    /// Present the current name without rewriting historical clipboard data.
    var kopiDisplayName: String? {
        if let bundleIdentifier,
           Self.canonicalBundleIdentifier(bundleIdentifier) == Self.kopiBundleIdentifier {
            return "Kopi"
        }
        return displayName
    }
}
