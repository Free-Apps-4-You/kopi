import Foundation

/// Where a captured copy came from.
///
/// Retention measures the last *external* copy, so a paste or copy initiated by
/// Kopi itself must not extend the life of an item.
public enum CopyOrigin: Sendable, Hashable, Codable {
    case external(changeCount: Int)
    case kopi(itemID: ClipboardItemID, changeCount: Int)

    public var isExternal: Bool {
        if case .external = self { return true }
        return false
    }

    public var changeCount: Int {
        switch self {
        case .external(let changeCount): changeCount
        case .kopi(_, let changeCount): changeCount
        }
    }

    public var sourceItemID: ClipboardItemID? {
        if case .kopi(let itemID, _) = self { return itemID }
        return nil
    }
}

/// Where a capture is stored: ordinary history, or the collection shelf that retention
/// and Clear History leave alone.
public enum CaptureDestination: Sendable, Hashable, Codable {
    case history
    case collection

    public var isCollection: Bool { self == .collection }
}

/// A capture ready to be stored. The store derives fingerprints, excerpts and
/// search text from it, so callers cannot disagree with what is persisted.
public struct ClipboardItemInsertion: Sendable, Hashable {
    public var id: ClipboardItemID
    public var kind: ClipboardItemKind
    public var label: String?
    /// Primary text content, used for the card excerpt and for search.
    public var text: String?
    public var url: URL?
    public var representations: [ClipboardRepresentation]
    public var fileReferences: [FileReference]
    public var sourceApp: SourceAppInfo?
    public var origin: CopyOrigin
    public var capturedAt: Date
    public var destination: CaptureDestination

    public init(
        id: ClipboardItemID = ClipboardItemID(),
        kind: ClipboardItemKind,
        label: String? = nil,
        text: String? = nil,
        url: URL? = nil,
        representations: [ClipboardRepresentation],
        fileReferences: [FileReference] = [],
        sourceApp: SourceAppInfo? = nil,
        origin: CopyOrigin = .external(changeCount: 0),
        capturedAt: Date = Date(),
        destination: CaptureDestination = .history
    ) {
        self.id = id
        self.kind = kind
        self.label = label
        self.text = text
        self.url = url
        self.representations = representations
        self.fileReferences = fileReferences
        self.sourceApp = sourceApp
        self.origin = origin
        self.capturedAt = capturedAt
        self.destination = destination
    }

    /// A brand-new, still empty card on the collection shelf, as the New Item action
    /// creates it. The user types the content in the editor that opens on it.
    public static func newCollectionItem(
        id: ClipboardItemID = ClipboardItemID(),
        now: Date = Date()
    ) -> ClipboardItemInsertion {
        ClipboardItemInsertion(
            id: id,
            kind: .text,
            text: "",
            representations: [ClipboardRepresentation(kind: .plainText, payload: .text(""))],
            capturedAt: now,
            destination: .collection
        )
    }

    /// Whether the insertion carries nothing a fingerprint could identify, which is the
    /// state of a brand-new collection card. Such an insertion is always its own card:
    /// there is no content for it to collapse onto.
    public var carriesNoContent: Bool {
        switch kind {
        case .text:
            let value = text ?? representations.first { $0.kind == .plainText }?.text
            return (value ?? "").isEmpty
        case .richText:
            return representations.allSatisfy { $0.byteCount == 0 }
        case .image:
            return representations.isEmpty
        case .link:
            return url == nil && !representations.contains { $0.kind == .link }
        case .files:
            return fileReferences.isEmpty
        }
    }

    public var fingerprint: ContentFingerprint {
        ContentFingerprint.make(kind: kind, representations: representations, fileReferences: fileReferences)
    }

    public var assets: [AssetReference] {
        representations.compactMap(\.asset) + fileReferences.compactMap(\.snapshot)
    }
}
