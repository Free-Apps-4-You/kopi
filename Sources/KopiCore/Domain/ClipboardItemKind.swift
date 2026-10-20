import Foundation

/// The kind of content a card represents.
public enum ClipboardItemKind: String, Sendable, Codable, CaseIterable, Hashable {
    case text
    case richText
    case link
    case image
    case files

    public var displayName: String {
        switch self {
        case .text: "Text"
        case .richText: "Rich Text"
        case .link: "Link"
        case .image: "Image"
        case .files: "Files"
        }
    }

    /// Whether the stored content itself may be edited. Images and file copies
    /// only expose a user-editable label: their content is never rewritten.
    public var supportsContentEditing: Bool {
        switch self {
        case .text, .richText, .link: true
        case .image, .files: false
        }
    }
}

/// The All / Text / Links / Images / Files filters of the clipboard and pinned tabs.
public enum ClipboardFilter: String, Sendable, Codable, CaseIterable, Identifiable, Hashable {
    case all
    case text
    case links
    case images
    case files

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .all: "All"
        case .text: "Text"
        case .links: "Links"
        case .images: "Images"
        case .files: "Files"
        }
    }

    /// Item kinds matched by this filter. An empty set means "no kind restriction".
    public var kinds: Set<ClipboardItemKind> {
        switch self {
        case .all: []
        case .text: [.text, .richText]
        case .links: [.link]
        case .images: [.image]
        case .files: [.files]
        }
    }

    public var itemKind: ClipboardItemKind? {
        switch self {
        case .all: nil
        case .text, .links, .images, .files: kinds.first
        }
    }
}
