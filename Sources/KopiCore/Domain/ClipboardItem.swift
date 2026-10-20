import Foundation

/// Immutable, lightweight description of a card. Everything a history grid needs,
/// without loading representations or payloads.
public struct ClipboardItemSummary: Sendable, Hashable, Identifiable, Codable {
    public let id: ClipboardItemID
    public let kind: ClipboardItemKind
    public let label: String?
    public let excerpt: String
    public let primaryURL: URL?
    public let fileNames: [String]
    public let sourceApp: SourceAppInfo?
    public let fingerprint: ContentFingerprint
    public let isPinned: Bool
    public let pinnedAt: Date?
    public let isEdited: Bool
    /// On the collection shelf, which retention and Clear History leave alone.
    public let isCollection: Bool
    public let createdAt: Date
    /// Time of the last external copy, which is what retention measures.
    public let lastCopiedAt: Date
    public let updatedAt: Date

    public init(
        id: ClipboardItemID,
        kind: ClipboardItemKind,
        label: String? = nil,
        excerpt: String,
        primaryURL: URL? = nil,
        fileNames: [String] = [],
        sourceApp: SourceAppInfo? = nil,
        fingerprint: ContentFingerprint,
        isPinned: Bool = false,
        pinnedAt: Date? = nil,
        isEdited: Bool = false,
        isCollection: Bool = false,
        createdAt: Date,
        lastCopiedAt: Date,
        updatedAt: Date
    ) {
        self.id = id
        self.kind = kind
        self.label = label
        self.excerpt = excerpt
        self.primaryURL = primaryURL
        self.fileNames = fileNames
        self.sourceApp = sourceApp
        self.fingerprint = fingerprint
        self.isPinned = isPinned
        self.pinnedAt = pinnedAt
        self.isEdited = isEdited
        self.isCollection = isCollection
        self.createdAt = createdAt
        self.lastCopiedAt = lastCopiedAt
        self.updatedAt = updatedAt
    }

    /// Editable label, then content excerpt, then the kind name.
    public var displayTitle: String {
        if let label, !label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return label
        }
        let firstLine = excerpt.prefix { !$0.isNewline }.trimmingCharacters(in: .whitespaces)
        if !firstLine.isEmpty {
            return firstLine
        }
        if kind == .files, !fileNames.isEmpty {
            return fileNames.count == 1 ? fileNames[0] : "\(fileNames.count) items"
        }
        return kind.displayName
    }

    /// Host shown on link cards.
    public var domain: String? {
        guard let primaryURL else { return nil }
        guard let host = primaryURL.host(), !host.isEmpty else {
            return primaryURL.absoluteString
        }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    public var fileCount: Int { fileNames.count }
}

/// Full record of a card, loaded for preview, copy, paste and editing.
public struct ClipboardItemDetail: Sendable, Hashable, Identifiable, Codable {
    public let summary: ClipboardItemSummary
    public let searchText: String
    public let representations: [ClipboardRepresentation]
    public let assets: [AssetReference]
    public let fileReferences: [FileReference]

    public init(
        summary: ClipboardItemSummary,
        searchText: String,
        representations: [ClipboardRepresentation],
        assets: [AssetReference] = [],
        fileReferences: [FileReference] = []
    ) {
        self.summary = summary
        self.searchText = searchText
        self.representations = representations
        self.assets = assets
        self.fileReferences = fileReferences
    }

    public var id: ClipboardItemID { summary.id }

    public func representation(_ kind: ClipboardRepresentationKind) -> ClipboardRepresentation? {
        representations.first { $0.kind == kind }
    }

    /// Text pasted into a plain-text application.
    public var plainText: String? {
        representation(.plainText)?.text
    }

    /// Current stored text, for the editor.
    public var editableText: String? {
        if let text = plainText { return text }
        return summary.primaryURL?.absoluteString
    }

    public var isContentEditable: Bool {
        summary.kind.supportsContentEditing
    }

    public var fileSnapshots: [AssetReference] {
        fileReferences.compactMap(\.snapshot)
    }
}
