import Foundation

/// Application that put the content on the pasteboard.
public struct SourceAppInfo: Sendable, Hashable, Codable {
    public static let kopiBundleIdentifier = "com.kopi.app"
    /// These identify the same app in history written before its rename.
    public static let kopiBundleIdentifiers = ["com.kopi.app", LegacyAppIdentity.bundleIdentifier, "com.velpy.app", "com.velpy.Velpy"]

    public static func canonicalBundleIdentifier(_ identifier: String) -> String {
        kopiBundleIdentifiers.contains(identifier) ? kopiBundleIdentifier : identifier
    }

    public let bundleIdentifier: String?
    public let name: String?
    public let processIdentifier: Int32?

    public init(bundleIdentifier: String? = nil, name: String? = nil, processIdentifier: Int32? = nil) {
        self.bundleIdentifier = bundleIdentifier
        self.name = name
        self.processIdentifier = processIdentifier
    }

    /// Name shown on the card, falling back to the bundle identifier.
    public var displayName: String? {
        if let name, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return name
        }
        if let bundleIdentifier, !bundleIdentifier.isEmpty {
            return bundleIdentifier
        }
        return nil
    }
}

/// One file or folder of a Finder copy. Ordinary cards keep only this reference;
/// pinning attaches an app-managed ``snapshot``.
public struct FileReference: Sendable, Hashable, Codable {
    public let path: String
    public let displayName: String
    public let byteSize: Int64?
    public let isDirectory: Bool
    /// App-managed copy of the content, created when the card is pinned.
    public var snapshot: AssetReference?

    public init(
        path: String,
        displayName: String,
        byteSize: Int64? = nil,
        isDirectory: Bool = false,
        snapshot: AssetReference? = nil
    ) {
        self.path = path
        self.displayName = displayName
        self.byteSize = byteSize
        self.isDirectory = isDirectory
        self.snapshot = snapshot
    }

    public var url: URL {
        URL(fileURLWithPath: path)
    }

    /// Whether the original file is still where the card says it is.
    public var isOriginalAvailable: Bool {
        FileManager.default.fileExists(atPath: path)
    }

    /// Whether Kopi holds an app-managed copy that survives the original moving away.
    public var isPreserved: Bool {
        snapshot != nil
    }
}
