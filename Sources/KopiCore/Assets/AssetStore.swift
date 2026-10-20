import Foundation

/// App-managed files under Kopi's Application Support directory.
///
/// Asset files are content addressed: the digest of the bytes is the asset
/// identity, so importing the same image or snapshotting the same file twice
/// stores and references a single file.
public actor AssetStore {
    public nonisolated let rootDirectory: URL

    private let copier: any AssetFileCopying

    public init(rootDirectory: URL, copier: any AssetFileCopying = FileManagerAssetCopier()) throws {
        self.rootDirectory = rootDirectory.standardizedFileURL
        self.copier = copier
        try Self.createDirectoryIfNeeded(rootDirectory)
    }

    /// `~/Library/Application Support/Kopi/Assets`.
    public static func defaultRootDirectory() throws -> URL {
        guard let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            throw AssetStoreError.sourceUnavailable("Application Support directory is unavailable")
        }
        return support.appendingPathComponent("Kopi", isDirectory: true)
            .appendingPathComponent("Assets", isDirectory: true)
    }

    // MARK: - Writing

    /// Stores bytes as an asset and returns the reference to persist.
    public func importData(
        _ data: Data,
        kind: AssetKind,
        fileExtension: String? = nil,
        originalPath: String? = nil,
        createdAt: Date = Date()
    ) throws -> AssetSnapshot {
        let digest = ContentHasher.sha256Hex(data)
        let relativePath = Self.relativePath(
            kind: kind,
            digest: digest,
            fileExtension: fileExtension,
            fileNameHint: originalPath.map { URL(fileURLWithPath: $0).lastPathComponent }
        )
        let destination = try fileURL(forRelativePath: relativePath)
        let existed = FileManager.default.fileExists(atPath: destination.path)
        let existingAttributes = try? FileManager.default.attributesOfItem(atPath: destination.path)
        let existingSize = (existingAttributes?[.size] as? NSNumber)?.intValue
        if existingSize != data.count {
            do {
                try Self.createDirectoryIfNeeded(destination.deletingLastPathComponent())
                try data.write(to: destination, options: [.atomic])
            } catch {
                throw Self.writeError(error, path: destination)
            }
        }
        return AssetSnapshot(
            reference: AssetReference(
                id: AssetID(rawValue: digest),
                kind: kind,
                relativePath: relativePath,
                byteCount: data.count,
                contentHash: digest,
                createdAt: createdAt,
                originalPath: originalPath
            ),
            wasCreated: !existed
        )
    }

    /// Copies a file or folder into Kopi's storage so a pinned card keeps working
    /// after the original moves or disappears. The copy itself is delegated to the
    /// injected ``AssetFileCopying`` implementation and runs off this actor.
    public func snapshotFile(at source: URL, createdAt: Date = Date()) async throws -> AssetSnapshot {
        let source = source.standardizedFileURL
        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: source.path, isDirectory: &isDirectory) else {
            throw AssetStoreError.sourceUnavailable(source.path)
        }

        let sourceAttributes = try? fileManager.attributesOfItem(atPath: source.path)
        let fileSize = (sourceAttributes?[.size] as? NSNumber)?.intValue ?? 0

        let digest: String
        let byteCount: Int
        if isDirectory.boolValue {
            digest = try ContentHasher.sha256Hex(directoryAt: source)
            byteCount = try Self.byteCount(ofDirectory: source)
        } else {
            do {
                digest = try ContentHasher.sha256Hex(fileAt: source)
            } catch {
                throw AssetStoreError.sourceUnavailable(source.path)
            }
            byteCount = fileSize
        }

        let relativePath = Self.relativePath(
            kind: .fileSnapshot,
            digest: digest,
            fileExtension: isDirectory.boolValue ? nil : source.pathExtension,
            fileNameHint: source.lastPathComponent
        )
        let destination = try fileURL(forRelativePath: relativePath)
        let existed = fileManager.fileExists(atPath: destination.path)
        if !existed {
            do {
                try Self.createDirectoryIfNeeded(destination.deletingLastPathComponent())
                try await copier.copyItem(at: source, to: destination)
            } catch {
                throw Self.copyError(error, path: source.path)
            }
            guard fileManager.fileExists(atPath: destination.path) else {
                throw AssetStoreError.copyFailed(source.path)
            }
        }
        return AssetSnapshot(
            reference: AssetReference(
                id: AssetID(rawValue: digest),
                kind: .fileSnapshot,
                relativePath: relativePath,
                byteCount: byteCount,
                contentHash: digest,
                createdAt: createdAt,
                originalPath: source.path
            ),
            wasCreated: !existed
        )
    }

    // MARK: - Reading

    public nonisolated func fileURL(for reference: AssetReference) -> URL {
        rootDirectory.appendingPathComponent(reference.relativePath, isDirectory: reference.kind == .fileSnapshot)
    }

    public func readData(for reference: AssetReference) throws -> Data {
        let url = fileURL(for: reference)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw AssetStoreError.assetNotFound(reference.id)
        }
        do {
            return try Data(contentsOf: url)
        } catch {
            throw AssetStoreError.assetNotFound(reference.id)
        }
    }

    public func contains(_ reference: AssetReference) -> Bool {
        FileManager.default.fileExists(atPath: fileURL(for: reference).path)
    }

    public func byteCount() throws -> Int {
        guard FileManager.default.fileExists(atPath: rootDirectory.path) else { return 0 }
        return try Self.byteCount(ofDirectory: rootDirectory)
    }

    // MARK: - Removing

    /// Removes the given assets. Paths outside the store are rejected, and missing
    /// files are ignored, so callers can garbage collect without special cases.
    @discardableResult
    public func remove(relativePaths: [String]) -> Int {
        var removed = 0
        for relativePath in relativePaths {
            guard let url = try? fileURL(forRelativePath: relativePath) else { continue }
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            do {
                try FileManager.default.removeItem(at: url)
                removed += 1
            } catch {
                continue
            }
        }
        return removed
    }

    public func removeAll() throws {
        guard FileManager.default.fileExists(atPath: rootDirectory.path) else { return }
        do {
            try FileManager.default.removeItem(at: rootDirectory)
            try Self.createDirectoryIfNeeded(rootDirectory)
        } catch {
            throw AssetStoreError.writeFailed(error.localizedDescription)
        }
    }

    /// Removes stored files that are not in `kept`, returning how many were deleted.
    /// Used to collect files whose rows are gone, for example after a crash between
    /// writing a file and committing its row.
    @discardableResult
    public func removeFiles(notIn kept: Set<String>) -> Int {
        let keys: [URLResourceKey] = [.isRegularFileKey]
        guard let enumerator = FileManager.default.enumerator(
            at: rootDirectory,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        ) else {
            return 0
        }
        let rootPath = rootDirectory.standardizedFileURL.path
        var removed = 0
        for case let file as URL in enumerator {
            guard (try? file.resourceValues(forKeys: Set(keys)).isRegularFile) == true else { continue }
            let relativePath = String(file.standardizedFileURL.path.dropFirst(rootPath.count + 1))
            guard !kept.contains(relativePath) else { continue }
            if (try? FileManager.default.removeItem(at: file)) != nil {
                removed += 1
            }
        }
        return removed
    }

    // MARK: - Paths

    nonisolated func fileURL(forRelativePath relativePath: String) throws -> URL {
        let components = relativePath.split(separator: "/", omittingEmptySubsequences: false)
        guard !relativePath.hasPrefix("/"), !components.contains(".."), !components.contains("") else {
            throw AssetStoreError.invalidRelativePath(relativePath)
        }
        return rootDirectory.appendingPathComponent(relativePath)
    }

    static func relativePath(kind: AssetKind, digest: String, fileExtension: String?, fileNameHint: String?) -> String {
        let shortDigest = String(digest.prefix(32))
        var name = shortDigest
        if let hint = sanitizedName(fileNameHint) {
            name += "-\(hint)"
        }
        if let fileExtension, !fileExtension.isEmpty {
            name += ".\(fileExtension.lowercased())"
        }
        return "\(kind.directoryName)/\(name)"
    }

    private static func sanitizedName(_ hint: String?) -> String? {
        guard let hint, !hint.isEmpty else { return nil }
        let allowed = hint.map { character -> Character in
            switch character {
            case "/", ":", "\\", "\0", "\n": "-"
            default: character
            }
        }
        let cleaned = String(allowed).prefix(64).trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? nil : String(cleaned)
    }

    private static func createDirectoryIfNeeded(_ url: URL) throws {
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        } catch {
            throw writeError(error, path: url)
        }
    }

    private static func byteCount(ofDirectory url: URL) throws -> Int {
        var total = 0
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey]
        guard let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: keys) else {
            throw AssetStoreError.sourceUnavailable(url.path)
        }
        for case let child as URL in enumerator {
            guard let values = try? child.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { continue }
            total += values.fileSize ?? 0
        }
        return total
    }

    private static func writeError(_ error: any Error, path: URL) -> AssetStoreError {
        if (error as? CocoaError)?.code == .fileWriteOutOfSpace {
            return .insufficientSpace(path.path)
        }
        return .writeFailed("\(path.path): \(error.localizedDescription)")
    }

    private static func copyError(_ error: any Error, path: String) -> AssetStoreError {
        if let error = error as? AssetStoreError { return error }
        if (error as? CocoaError)?.code == .fileWriteOutOfSpace {
            return .insufficientSpace(path)
        }
        return .copyFailed("\(path): \(error.localizedDescription)")
    }
}
