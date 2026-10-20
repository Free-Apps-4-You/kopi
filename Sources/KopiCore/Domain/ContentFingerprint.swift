import Foundation

/// Canonical identity of the content of a card, used to deduplicate captures.
///
/// The fingerprint covers the item kind and every representation (kind plus
/// content digest), so identical content collapses while formatting differences
/// produce distinct cards. Labels, edit state and pin state are deliberately not
/// part of it: they never make two cards look like different content.
public struct ContentFingerprint: RawRepresentable, Hashable, Sendable, Codable, CustomStringConvertible {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    /// Builds the fingerprint of an item from its kind and stored flavours.
    /// Representations are sorted by kind so the order of capture does not matter.
    public static func make(
        kind: ClipboardItemKind,
        representations: [ClipboardRepresentation],
        fileReferences: [FileReference] = []
    ) -> ContentFingerprint {
        var components: [String] = ["kind:\(kind.rawValue)"]
        for representation in representations.sorted(by: { $0.kind.rawValue < $1.kind.rawValue }) {
            components.append("rep:\(representation.kind.rawValue):\(representation.contentHash)")
        }
        for file in fileReferences.sorted(by: { $0.path < $1.path }) {
            let size = file.byteSize.map(String.init) ?? "-"
            components.append("file:\(file.isDirectory ? "d" : "f"):\(file.path):\(size)")
        }
        return ContentFingerprint(rawValue: "sha256:" + ContentHasher.sha256Hex(digests: components))
    }

    public var description: String { rawValue }

    public init(from decoder: any Decoder) throws {
        self.rawValue = try decoder.singleValueContainer().decode(String.self)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}
