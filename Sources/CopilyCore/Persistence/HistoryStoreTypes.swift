import Foundation

/// Failures of the history store.
public enum HistoryStoreError: Error, Sendable, Equatable {
    case itemNotFound(ClipboardItemID)
    case invalidInsertion(String)
    case emptyEdit
    case contentNotEditable(ClipboardItemKind)
    case pinningFailed(ClipboardItemID, String)
    case stateChanged(ClipboardItemID)
    case assetNotFound(AssetID)
}

/// One page of results, as requested by the grid.
public struct HistoryPage: Sendable, Hashable, Codable {
    public var offset: Int
    public var limit: Int

    /// Cards fetched per page.
    public static let defaultLimit = 60

    public init(offset: Int = 0, limit: Int = HistoryPage.defaultLimit) {
        self.offset = offset
        self.limit = limit
    }
}

/// Which cards a query looks at.
public enum HistoryScope: Sendable, Hashable, Codable {
    /// Everything, including pinned cards, newest copy first.
    case allClipboard
    /// Only pinned cards.
    case pinned
    /// Only cards kept on the collection shelf.
    case collection

    public var isPinnedOnly: Bool { self == .pinned }
    public var isCollectionOnly: Bool { self == .collection }
}

/// Card ordering.
public enum HistorySort: Sendable, Hashable, Codable {
    /// Newest external copy first.
    case recentlyCopied
    /// Newest pin first.
    case recentlyPinned
}

/// How the store answered a search.
public enum HistorySearchMode: String, Sendable, Hashable, Codable {
    /// No search text: a plain page of cards.
    case listing
    /// FTS5 trigram index, substring semantics.
    case fullTextIndex
    /// Bounded database scan, used for queries shorter than three characters.
    case scan
}

/// A page request: search text, scope, filters, ordering and pagination.
public struct HistoryQuery: Sendable, Hashable, Codable {
    public var text: String
    public var scope: HistoryScope
    /// Empty means "every kind".
    public var kinds: Set<ClipboardItemKind>
    public var sort: HistorySort
    public var page: HistoryPage
    /// Optional exact source-app filter, combined with search, kind, and scope.
    public var sourceAppBundleIdentifier: String?

    public init(
        text: String = "",
        scope: HistoryScope = .allClipboard,
        kinds: Set<ClipboardItemKind> = [],
        sort: HistorySort = .recentlyCopied,
        page: HistoryPage = HistoryPage(),
        sourceAppBundleIdentifier: String? = nil
    ) {
        self.text = text
        self.scope = scope
        self.kinds = kinds
        self.sort = sort
        self.page = page
        self.sourceAppBundleIdentifier = sourceAppBundleIdentifier
    }

    /// Query for one of the All / Text / Links / Images / Files filters.
    public init(
        text: String = "",
        scope: HistoryScope = .allClipboard,
        filter: ClipboardFilter,
        sort: HistorySort = .recentlyCopied,
        page: HistoryPage = HistoryPage(),
        sourceAppBundleIdentifier: String? = nil
    ) {
        self.init(text: text, scope: scope, kinds: filter.kinds, sort: sort, page: page,
                  sourceAppBundleIdentifier: sourceAppBundleIdentifier)
    }

    public var searchText: String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public var isEmptySearch: Bool {
        searchText.isEmpty
    }
}

/// Result of a page request.
public struct HistoryPageResult: Sendable, Hashable, Codable {
    public let items: [ClipboardItemSummary]
    public let totalCount: Int
    public let page: HistoryPage
    public let searchMode: HistorySearchMode

    public init(items: [ClipboardItemSummary], totalCount: Int, page: HistoryPage, searchMode: HistorySearchMode) {
        self.items = items
        self.totalCount = totalCount
        self.page = page
        self.searchMode = searchMode
    }

    public var hasMore: Bool {
        page.offset + items.count < totalCount
    }

    public var nextPage: HistoryPage? {
        hasMore ? HistoryPage(offset: page.offset + items.count, limit: page.limit) : nil
    }

    public static let empty = HistoryPageResult(items: [], totalCount: 0, page: HistoryPage(), searchMode: .listing)
}

/// Outcome of an insertion: a new card, or a collapse onto an existing one.
public enum HistoryInsertionResult: Sendable, Hashable {
    case inserted(ClipboardItemSummary)
    case collapsed(ClipboardItemSummary)

    public var summary: ClipboardItemSummary {
        switch self {
        case .inserted(let summary), .collapsed(let summary): summary
        }
    }

    public var didCreateItem: Bool {
        if case .inserted = self { return true }
        return false
    }

    public var itemID: ClipboardItemID { summary.id }
}

/// What triggered a cleanup pass.
public enum HistoryCleanupTrigger: String, Sendable, Hashable, Codable, CaseIterable {
    case startup
    case retentionChange
    case periodic
    case manual
    case clearHistory
    case sessionEnd
}

/// What a cleanup pass did.
public struct HistoryCleanupReport: Sendable, Hashable {
    public let trigger: HistoryCleanupTrigger
    public let retention: HistoryRetention
    /// Date before which unpinned cards expired, or `nil` for session retention.
    public let cutoff: Date?
    public let removedItemIDs: [ClipboardItemID]
    public let removedAssetIDs: [AssetID]

    public init(
        trigger: HistoryCleanupTrigger,
        retention: HistoryRetention,
        cutoff: Date? = nil,
        removedItemIDs: [ClipboardItemID] = [],
        removedAssetIDs: [AssetID] = []
    ) {
        self.trigger = trigger
        self.retention = retention
        self.cutoff = cutoff
        self.removedItemIDs = removedItemIDs
        self.removedAssetIDs = removedAssetIDs
    }

    public var removedItemCount: Int { removedItemIDs.count }
    public var removedAssetCount: Int { removedAssetIDs.count }
}

/// Result of starting a run.
public struct SessionStartReport: Sendable, Hashable {
    public let sessionID: SessionID
    /// The previous run did not mark a clean shutdown.
    public let recoveredFromInterruptedExit: Bool
    public let cleanup: HistoryCleanupReport

    public init(sessionID: SessionID, recoveredFromInterruptedExit: Bool, cleanup: HistoryCleanupReport) {
        self.sessionID = sessionID
        self.recoveredFromInterruptedExit = recoveredFromInterruptedExit
        self.cleanup = cleanup
    }
}

/// Copily's own clipboard generation, so copying a card is not captured as a new item.
public struct OwnCopyState: Sendable, Hashable, Codable {
    public let itemID: ClipboardItemID
    public let changeCount: Int

    public init(itemID: ClipboardItemID, changeCount: Int) {
        self.itemID = itemID
        self.changeCount = changeCount
    }
}

/// Connection settings the store guarantees.
public struct HistoryStoreDiagnostics: Sendable, Hashable {
    public let journalMode: String
    /// 2 is `synchronous = FULL`.
    public let synchronous: Int
    public let foreignKeysEnabled: Bool

    public init(journalMode: String, synchronous: Int, foreignKeysEnabled: Bool) {
        self.journalMode = journalMode
        self.synchronous = synchronous
        self.foreignKeysEnabled = foreignKeysEnabled
    }

    public var isWriteAheadLogging: Bool { journalMode.lowercased() == "wal" }
    public var isFullySynchronous: Bool { synchronous == 2 }
}

/// Counts used by diagnostics and the headless self check.
public struct HistoryStatistics: Sendable, Hashable {
    public let itemCount: Int
    public let pinnedCount: Int
    public let assetCount: Int
    public let assetByteCount: Int
    public let sessionID: SessionID
    public let retention: HistoryRetention

    public init(
        itemCount: Int,
        pinnedCount: Int,
        assetCount: Int,
        assetByteCount: Int,
        sessionID: SessionID,
        retention: HistoryRetention
    ) {
        self.itemCount = itemCount
        self.pinnedCount = pinnedCount
        self.assetCount = assetCount
        self.assetByteCount = assetByteCount
        self.sessionID = sessionID
        self.retention = retention
    }
}
