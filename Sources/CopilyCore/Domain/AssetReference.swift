import Foundation

/// Why an asset file exists.
public enum AssetKind: String, Sendable, Codable, CaseIterable, Hashable {
    /// An image captured from the pasteboard.
    case image
    /// A copy of a file or folder that a pinned card must keep working.
    case fileSnapshot

    var directoryName: String {
        switch self {
        case .image: "images"
        case .fileSnapshot: "snapshots"
        }
    }
}

/// A file managed by Copily under its Application Support directory.
public struct AssetReference: Sendable, Hashable, Codable, Identifiable {
    public let id: AssetID
    public let kind: AssetKind
    /// Path relative to the asset store root, never absolute.
    public let relativePath: String
    public let byteCount: Int
    public let contentHash: String
    public let createdAt: Date
    /// Original location, for file snapshots.
    public let originalPath: String?

    public init(
        id: AssetID,
        kind: AssetKind,
        relativePath: String,
        byteCount: Int,
        contentHash: String,
        createdAt: Date,
        originalPath: String? = nil
    ) {
        self.id = id
        self.kind = kind
        self.relativePath = relativePath
        self.byteCount = byteCount
        self.contentHash = contentHash
        self.createdAt = createdAt
        self.originalPath = originalPath
    }
}

/// Result of storing bytes in the asset directory.
public struct AssetSnapshot: Sendable, Hashable {
    public let reference: AssetReference
    /// `false` when identical bytes were already stored, meaning the file is shared
    /// and must not be removed by whoever asked for it.
    public let wasCreated: Bool

    public init(reference: AssetReference, wasCreated: Bool) {
        self.reference = reference
        self.wasCreated = wasCreated
    }
}

/// Failures of the asset layer.
public enum AssetStoreError: Error, Sendable, Equatable {
    case sourceUnavailable(String)
    case copyFailed(String)
    case writeFailed(String)
    case assetNotFound(AssetID)
    case invalidRelativePath(String)
    case insufficientSpace(String)
}

/// Copies a file or directory into Copily's asset directory. Injected so tests can
/// fail, delay or observe the copy.
public protocol AssetFileCopying: Sendable {
    func copyItem(at source: URL, to destination: URL) async throws
}

/// Production copier: performs the copy off the caller's executor so pinning a
/// large file never blocks a worker.
public struct FileManagerAssetCopier: AssetFileCopying {
    public init() {}

    public func copyItem(at source: URL, to destination: URL) async throws {
        try await Task.detached(priority: .utility) {
            try FileManager.default.copyItem(at: source, to: destination)
        }.value
    }
}

/// Copier used by tests that need to observe or break file copying.
public struct FailingAssetCopier: AssetFileCopying {
    public struct Failure: Error, Sendable, Equatable {
        public let message: String
        public init(_ message: String = "copy failed") {
            self.message = message
        }
    }

    public init() {}

    public func copyItem(at source: URL, to destination: URL) async throws {
        throw Failure()
    }
}
