import CryptoKit
import Foundation

/// SHA-256 helpers shared by content fingerprints and the asset store.
public enum ContentHasher {
    /// Hex encoded SHA-256 of `data`.
    public static func sha256Hex(_ data: Data) -> String {
        hex(SHA256.hash(data: data))
    }

    /// Hex encoded SHA-256 of the UTF-8 bytes of `text`.
    public static func sha256Hex(text: String) -> String {
        sha256Hex(Data(text.utf8))
    }

    /// Hex encoded SHA-256 of the file contents, streamed so large files do not
    /// have to fit in memory.
    public static func sha256Hex(fileAt url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hex(hasher.finalize())
    }

    /// Hex encoded SHA-256 over the sorted layout of a directory tree.
    /// File contents are not read: the digest identifies the structure, which is
    /// what a snapshot of a folder needs in order to be recognised again.
    public static func sha256Hex(directoryAt url: URL) throws -> String {
        let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey]
        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        ) else {
            throw CocoaError(.fileReadUnknown, userInfo: [NSFilePathErrorKey: url.path])
        }
        var entries: [String] = []
        let rootPath = url.standardizedFileURL.path
        for case let child as URL in enumerator {
            guard let values = try? child.resourceValues(forKeys: Set(keys)) else { continue }
            let relativePath = String(child.standardizedFileURL.path.dropFirst(rootPath.count))
            if values.isDirectory == true {
                entries.append("d:\(relativePath)")
            } else {
                entries.append("f:\(relativePath):\(values.fileSize ?? 0)")
            }
        }
        entries.sort()
        return sha256Hex(text: entries.joined(separator: "\n"))
    }

    /// Hex encoded SHA-256 over an ordered list of digests.
    public static func sha256Hex(digests: [String]) -> String {
        sha256Hex(text: digests.joined(separator: "\u{1F}"))
    }

    private static func hex(_ digest: SHA256.Digest) -> String {
        let bytes = Array(digest)
        var output = String()
        output.reserveCapacity(bytes.count * 2)
        for byte in bytes {
            output.append(Character(UnicodeScalar(hexDigits[Int(byte >> 4)])))
            output.append(Character(UnicodeScalar(hexDigits[Int(byte & 0x0F)])))
        }
        return output
    }

    private static let hexDigits: [UInt8] = Array("0123456789abcdef".utf8)
}
