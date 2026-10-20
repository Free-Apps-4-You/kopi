import Foundation

public struct NotesAccountID: RawRepresentable, Hashable, Sendable, Codable, CustomStringConvertible {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
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

public struct NotesFolderID: RawRepresentable, Hashable, Sendable, Codable, CustomStringConvertible {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
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

public struct NotesNoteID: RawRepresentable, Hashable, Sendable, Codable, CustomStringConvertible {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
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

/// An Apple Notes account as exposed by the scriptable interface.
public struct NotesAccount: Sendable, Hashable, Identifiable, Codable {
    public let id: NotesAccountID
    public let name: String
    public let isDefault: Bool

    public var location: NotesAccountLocation {
        let identifier = id.rawValue.lowercased()
        let accountName = name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .filter { $0.isLetter || $0.isNumber }
        // Notes uses LocalAccount for local storage, independent of the UI language.
        if identifier.contains("localaccount") || accountName == "onmymac" { return .onMyMac }
        if accountName == "icloud" { return .iCloud }
        return .other
    }

    public init(id: NotesAccountID, name: String, isDefault: Bool = false) {
        self.id = id
        self.name = name
        self.isDefault = isDefault
    }
}

public enum NotesAccountLocation: String, Sendable {
    case onMyMac, iCloud, other
}

public enum NotesSourceFilter: String, CaseIterable, Identifiable, Sendable {
    case all, onMyMac, iCloud
    public var id: Self { self }
    public var title: String {
        switch self {
        case .all: "All"
        case .onMyMac: "On My Mac"
        case .iCloud: "iCloud"
        }
    }
    public func includes(_ account: NotesAccount) -> Bool {
        switch self {
        case .all: true
        case .onMyMac: account.location == .onMyMac
        case .iCloud: account.location == .iCloud
        }
    }
}

/// A folder inside an account.
public struct NotesFolder: Sendable, Hashable, Identifiable, Codable {
    public let id: NotesFolderID
    public let accountID: NotesAccountID
    public let name: String
    /// The default Notes folder, selected on first connect.
    public let isDefault: Bool
    public let noteCount: Int?

    public init(id: NotesFolderID, accountID: NotesAccountID, name: String, isDefault: Bool = false, noteCount: Int? = nil) {
        self.id = id
        self.accountID = accountID
        self.name = name
        self.isDefault = isDefault
        self.noteCount = noteCount
    }
}

/// Everything a Notes card needs, without the body.
public struct NotesNoteMetadata: Sendable, Hashable, Identifiable, Codable {
    public let id: NotesNoteID
    public let folderID: NotesFolderID
    public let folderName: String?
    public let title: String
    public let excerpt: String
    public let modificationDate: Date
    /// Locked note: Kopi must not read its body.
    public let isProtected: Bool
    public let isShared: Bool
    /// Content richer than plain text: attachments, checklists, tables, drawings.
    public let hasRichContent: Bool
    public let attachmentCount: Int

    public init(
        id: NotesNoteID,
        folderID: NotesFolderID,
        folderName: String? = nil,
        title: String,
        excerpt: String,
        modificationDate: Date,
        isProtected: Bool = false,
        isShared: Bool = false,
        hasRichContent: Bool = false,
        attachmentCount: Int = 0
    ) {
        self.id = id
        self.folderID = folderID
        self.folderName = folderName
        self.title = title
        self.excerpt = excerpt
        self.modificationDate = modificationDate
        self.isProtected = isProtected
        self.isShared = isShared
        self.hasRichContent = hasRichContent
        self.attachmentCount = attachmentCount
    }

    /// Content best opened in Apple Notes for full fidelity.
    public var requiresAppleNotes: Bool {
        isProtected || isShared || hasRichContent || attachmentCount > 0
    }
}

/// A note with its body.
public struct NotesNote: Sendable, Hashable, Identifiable, Codable {
    public let metadata: NotesNoteMetadata
    public let bodyHTML: String
    public let plainText: String

    public init(metadata: NotesNoteMetadata, bodyHTML: String, plainText: String) {
        self.metadata = metadata
        self.bodyHTML = bodyHTML
        self.plainText = plainText
    }

    public var id: NotesNoteID { metadata.id }

}

/// Progress of the note-body indexing pass.
public struct NotesIndexingProgress: Sendable, Hashable, Codable {
    public let indexedNoteCount: Int
    public let totalNoteCount: Int

    public init(indexedNoteCount: Int, totalNoteCount: Int) {
        self.indexedNoteCount = indexedNoteCount
        self.totalNoteCount = totalNoteCount
    }

    public var fractionCompleted: Double {
        guard totalNoteCount > 0 else { return 1 }
        return min(1, Double(indexedNoteCount) / Double(totalNoteCount))
    }

    public var isComplete: Bool {
        indexedNoteCount >= totalNoteCount
    }
}

/// Pagination for note metadata requests.
public struct NotesPage: Sendable, Hashable, Codable {
    public var offset: Int
    public var limit: Int

    public static let defaultLimit = 60

    public init(offset: Int = 0, limit: Int = NotesPage.defaultLimit) {
        self.offset = offset
        self.limit = limit
    }
}
