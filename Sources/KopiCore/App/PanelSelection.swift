import Foundation

/// The main row of the panel: the kind of cards the grid lists, or the Notes section.
public enum PanelSection: String, Sendable, Codable, CaseIterable, Identifiable, Hashable {
    case all
    case text
    case links
    case images
    case files
    case notes
    case passwords

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .all: "All"
        case .text: "Text"
        case .links: "Links"
        case .images: "Images"
        case .files: "Files"
        case .notes: "Notes"
        case .passwords: "Passwords"
        }
    }

    /// The kind filter this chip selects. `nil` for Notes, which lists no clipboard cards.
    public var clipboardFilter: ClipboardFilter? {
        switch self {
        case .all: .all
        case .text: .text
        case .links: .links
        case .images: .images
        case .files: .files
        case .notes, .passwords: nil
        }
    }

    /// Whether the section lists cards of the clipboard history at all.
    public var showsClipboardCards: Bool { clipboardFilter != nil }
}

/// The sub row of the panel: which slice of clipboard storage is on show. Neither
/// chip selected means ordinary history.
public enum PanelSource: String, Sendable, Codable, CaseIterable, Identifiable, Hashable {
    case pinned
    case collection

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .pinned: "Pinned"
        case .collection: "Collection"
        }
    }

    public var scope: HistoryScope {
        switch self {
        case .pinned: .pinned
        case .collection: .collection
        }
    }

    /// The chip that selects `scope`, or `nil` for ordinary history.
    public init?(scope: HistoryScope) {
        switch scope {
        case .allClipboard: return nil
        case .pinned: self = .pinned
        case .collection: self = .collection
        }
    }
}

/// One position of the panel's two chip rows, and the `HistoryQuery` it asks the
/// store for. Keeping the mapping out here leaves the view model and the grid free
/// of it, and makes every combination checkable.
public struct PanelSelection: Sendable, Hashable, Codable {
    public var section: PanelSection
    /// `nil` is ordinary history; otherwise the selected sub-row chip.
    public var source: PanelSource?

    public init(section: PanelSection = .all, source: PanelSource? = nil) {
        self.section = section
        self.source = source
    }

    /// The store scope the grid reads, or `nil` on Notes.
    public var scope: HistoryScope? {
        guard section.showsClipboardCards else { return nil }
        return source?.scope ?? .allClipboard
    }

    public var filter: ClipboardFilter {
        section.clipboardFilter ?? .all
    }

    public var sort: HistorySort {
        source == .pinned ? .recentlyPinned : .recentlyCopied
    }

    /// The query for one page of cards, or `nil` on Notes.
    public func query(text: String = "", page: HistoryPage = HistoryPage(), sourceAppBundleIdentifier: String? = nil) -> HistoryQuery? {
        guard let scope else { return nil }
        return HistoryQuery(text: text, scope: scope, filter: filter, sort: sort, page: page,
                            sourceAppBundleIdentifier: sourceAppBundleIdentifier)
    }
}
