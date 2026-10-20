import Foundation
import GRDB

/// Tuning of the database connection pool.
public struct HistoryStoreConfiguration: Sendable, Hashable {
    public var maximumReaderCount: Int
    public var busyTimeout: TimeInterval

    public init(maximumReaderCount: Int = 5, busyTimeout: TimeInterval = 5) {
        self.maximumReaderCount = maximumReaderCount
        self.busyTimeout = busyTimeout
    }
}

/// What a deletion removed.
public struct HistoryDeletionReport: Sendable, Hashable {
    public let removedItemIDs: [ClipboardItemID]
    public let removedAssetIDs: [AssetID]

    public init(removedItemIDs: [ClipboardItemID] = [], removedAssetIDs: [AssetID] = []) {
        self.removedItemIDs = removedItemIDs
        self.removedAssetIDs = removedAssetIDs
    }

    public var removedItemCount: Int { removedItemIDs.count }
    public var removedAssetCount: Int { removedAssetIDs.count }
}

/// Persistence, search, edits, pins, deletion and retention of clipboard items.
///
/// The store owns a WAL connection pool configured with `synchronous = FULL`, and
/// serialises every access through this actor. No GRDB type escapes: callers only
/// see the immutable snapshots of the domain layer, and mutations are acknowledged
/// only once their transaction has committed.
public actor HistoryStore {
    public nonisolated let path: String
    public nonisolated let assetStore: AssetStore

    private let pool: DatabasePool

    public init(
        path: String,
        assetStore: AssetStore,
        configuration: HistoryStoreConfiguration = HistoryStoreConfiguration()
    ) throws {
        self.path = path
        self.assetStore = assetStore

        let fileURL = URL(fileURLWithPath: path)
        let directory = fileURL.deletingLastPathComponent()
        if !directory.path.isEmpty {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }

        var databaseConfiguration = Configuration()
        databaseConfiguration.maximumReaderCount = max(1, configuration.maximumReaderCount)
        databaseConfiguration.busyMode = .timeout(configuration.busyTimeout)
        databaseConfiguration.prepareDatabase { db in
            try db.execute(sql: "PRAGMA synchronous = FULL")
        }
        let pool = try DatabasePool(path: path, configuration: databaseConfiguration)
        try pool.writeWithoutTransaction { db in
            // DatabasePool configures WAL after prepareDatabase and resets this
            // pragma to NORMAL; durability wins over throughput, so re-apply FULL
            // to the writer, outside of any transaction.
            try db.execute(sql: "PRAGMA synchronous = FULL")
        }
        try HistoryStoreSchema.migrate(pool)
        try pool.writeWithoutTransaction { db in
            try Self.bootstrapMetadata(db)
        }
        self.pool = pool
    }

    // MARK: - Session lifecycle

    /// Starts a run. Call before showing any history.
    ///
    /// When retention is `.currentSession`, items kept by previous runs are removed
    /// here, which is what makes an interrupted exit safe: the items of the session
    /// that did not shut down cleanly are gone before the first card is shown.
    @discardableResult
    public func beginSession(now: Date = Date()) async throws -> SessionStartReport {
        let sessionID = SessionID()
        let result = try await pool.write { db -> (SessionStartReport, AssetGarbageCollection) in
            let previousSession = try Self.metadataValue(db, key: .sessionID)
            let previousWasClean = try Self.metadataValue(db, key: .cleanShutdown) == "1"
            let interrupted = previousSession != nil && !previousWasClean

            try Self.setMetadataValue(db, key: .sessionID, value: sessionID.rawValue)
            try Self.setMetadataValue(db, key: .sessionStartedAt, value: String(now.timeIntervalSince1970))
            try Self.setMetadataValue(db, key: .cleanShutdown, value: "0")

            let retention = try Self.retentionValue(db)
            let outcome = retention.isSessionScoped
                ? try Self.cleanup(db, trigger: .startup, retention: retention, now: now, sessionID: sessionID)
                : (HistoryCleanupReport(trigger: .startup, retention: retention), AssetGarbageCollection())
            let report = SessionStartReport(
                sessionID: sessionID,
                recoveredFromInterruptedExit: interrupted,
                cleanup: outcome.0
            )
            return (report, outcome.1)
        }
        await removeAssetFiles(result.1)
        return result.0
    }

    /// Ends a run. With session retention this clears every unpinned item; either
    /// way the shutdown is recorded so the next start is not treated as a crash.
    @discardableResult
    public func endSession(now: Date = Date()) async throws -> HistoryCleanupReport {
        let result = try await pool.write { db in
            let retention = try Self.retentionValue(db)
            let report: HistoryCleanupReport
            var garbage = AssetGarbageCollection()
            if retention.isSessionScoped {
                let outcome = try Self.cleanup(db, trigger: .sessionEnd, retention: retention, now: now, sessionID: nil)
                report = outcome.0
                garbage = outcome.1
            } else {
                report = HistoryCleanupReport(trigger: .sessionEnd, retention: retention)
            }
            try Self.setMetadataValue(db, key: .cleanShutdown, value: "1")
            return (report, garbage)
        }
        await removeAssetFiles(result.1)
        return result.0
    }

    public func sessionID() async throws -> SessionID? {
        try await pool.read { db in try Self.currentSessionID(db) }
    }

    // MARK: - Retention

    public func retention() async throws -> HistoryRetention {
        try await pool.read { db in try Self.retentionValue(db) }
    }

    /// Changes the retention setting and applies it immediately.
    @discardableResult
    public func setRetention(_ retention: HistoryRetention, now: Date = Date()) async throws -> HistoryCleanupReport {
        let result = try await pool.write { db -> (HistoryCleanupReport, AssetGarbageCollection) in
            try Self.setMetadataValue(db, key: .retention, value: retention.rawValue)
            return try Self.cleanup(db, trigger: .retentionChange, retention: retention, now: now, sessionID: try Self.currentSessionID(db))
        }
        await removeAssetFiles(result.1)
        return result.0
    }

    /// Expires unpinned items. Call at startup, after retention changes and periodically.
    @discardableResult
    public func runCleanup(trigger: HistoryCleanupTrigger = .periodic, now: Date = Date()) async throws -> HistoryCleanupReport {
        let result = try await pool.write { db -> (HistoryCleanupReport, AssetGarbageCollection) in
            let retention = try Self.retentionValue(db)
            return try Self.cleanup(db, trigger: trigger, retention: retention, now: now, sessionID: try Self.currentSessionID(db))
        }
        await removeAssetFiles(result.1)
        return result.0
    }

    /// Removes every unpinned item. Pinned and collected cards are always kept.
    @discardableResult
    public func clearHistory(now: Date = Date()) async throws -> HistoryCleanupReport {
        let result = try await pool.write { db -> (HistoryCleanupReport, AssetGarbageCollection) in
            let retention = try Self.retentionValue(db)
            let expired = try ClipItemSummaryRow.fetchAll(
                db,
                sql: ClipItemSummaryRow.summarySelect + " WHERE i.is_pinned = 0 AND i.is_collection = 0"
            )
            let garbage = try Self.deleteItems(db, itemIDs: expired.map { ClipboardItemID(rawValue: $0.id) })
            let report = HistoryCleanupReport(
                trigger: .clearHistory,
                retention: retention,
                cutoff: retention.expirationCutoff(now: now),
                removedItemIDs: expired.map { ClipboardItemID(rawValue: $0.id) },
                removedAssetIDs: garbage.assetIDs
            )
            return (report, garbage)
        }
        await removeAssetFiles(result.1)
        return result.0
    }

    // MARK: - Capture

    /// Stores a capture, collapsing it onto an existing card when the content is
    /// already there.
    ///
    /// Identical content collapses, but formatting differences produce distinct
    /// cards; a card the user edited is never collapsed into, and collapsing never
    /// changes pin state. Only an external copy moves the retention clock. A capture
    /// bound for the collection shelf only collapses onto collected cards, so
    /// collecting never has to touch a history card; a fresh copy of collected content
    /// still collapses onto the collected card rather than storing it twice.
    @discardableResult
    public func insert(_ insertion: ClipboardItemInsertion) async throws -> HistoryInsertionResult {
        if let error = insertion.validationError { throw error }
        return try await pool.write { db in
            try Self.insertItem(db, insertion)
        }
    }

    // MARK: - Editing

    /// Applies an edit to a card.
    ///
    /// Edited text, regenerated representations, search text and fingerprint are
    /// written in one transaction, so a crash leaves either the old card or the new
    /// one. Image and file cards accept label changes only, and their content — and
    /// therefore their fingerprint — is left untouched.
    @discardableResult
    public func edit(_ edit: ClipboardItemEdit, for itemID: ClipboardItemID) async throws -> ClipboardItemSummary {
        guard !edit.isEmpty else { throw HistoryStoreError.emptyEdit }
        let result = try await pool.write { db -> (ClipboardItemSummary, AssetGarbageCollection) in
            guard let row = try Self.summaryRow(db, id: itemID) else {
                throw HistoryStoreError.itemNotFound(itemID)
            }
            let kind: ClipboardItemKind = row.itemKind == .text && edit.richText != nil ? .richText : row.itemKind
            var representations = try Self.representations(db, itemID: itemID)
            var fileReferences = try Self.fileReferences(db, itemID: itemID)
            var text = representations.first { $0.kind == .plainText }?.text
            var url = row.primaryURL.flatMap { URL(string: $0) }

            if edit.changesContent || (kind == .link && edit.label != nil) {
                guard kind.supportsContentEditing else {
                    throw HistoryStoreError.contentNotEditable(kind)
                }
                if let newURL = edit.url {
                    url = newURL
                }
                if let resolved = edit.resolvedPlainText {
                    text = resolved
                } else if kind == .link, let label = edit.label, !label.isEmpty {
                    text = label
                } else if text == nil {
                    text = url?.absoluteString
                }
                representations = Self.rebuiltRepresentations(
                    kind: kind,
                    text: text ?? "",
                    url: url,
                    richText: edit.richText
                )
                fileReferences = []
            }

            let label = edit.label.map { $0.isEmpty ? nil : $0 } ?? row.label
            let fileNames = fileReferences.map(\.displayName)
            let searchText = ClipboardSearchText.searchText(
                text: text,
                url: url,
                label: label,
                fileNames: fileNames
            )
            let folded = ClipboardSearchText.folded(searchText)
            let fingerprint = ContentFingerprint.make(
                kind: kind,
                representations: representations,
                fileReferences: fileReferences
            )
            let excerpt = ClipboardSearchText.excerpt(
                from: text ?? fileNames.joined(separator: ", ")
            )

            try db.execute(
                sql: """
                UPDATE clip_item SET
                    kind = ?, label = ?, excerpt = ?, search_text = ?, search_text_folded = ?, fingerprint = ?,
                    primary_url = ?, file_names_json = ?, is_edited = 1, updated_at = ?
                WHERE id = ?
                """,
                arguments: [
                    kind.rawValue,
                    label,
                    excerpt,
                    searchText,
                    folded,
                    fingerprint.rawValue,
                    url?.absoluteString,
                    Self.encodeFileNames(fileNames),
                    edit.editedAt.timeIntervalSinceReferenceDate,
                    itemID.rawValue
                ]
            )
            if let rowID = try Int64.fetchOne(db, sql: "SELECT row_id FROM clip_item WHERE id = ?", arguments: [itemID.rawValue]) {
                try Self.indexSearchText(db, rowID: rowID, foldedText: folded)
            }
            if edit.changesContent {
                try db.execute(
                    sql: "DELETE FROM clip_asset_reference WHERE item_id = ? AND role = ?",
                    arguments: [itemID.rawValue, AssetReferenceRole.representation.rawValue]
                )
                try db.execute(sql: "DELETE FROM clip_representation WHERE item_id = ?", arguments: [itemID.rawValue])
                try Self.writeChildren(db, itemID: itemID, representations: representations, fileReferences: fileReferences)
            }
            let garbage = try Self.collectUnreferencedAssets(db)
            guard let updated = try Self.summaryRow(db, id: itemID) else {
                throw HistoryStoreError.itemNotFound(itemID)
            }
            return (updated.summary(), garbage)
        }
        await removeAssetFiles(result.1)
        return result.0
    }

    // MARK: - Pinning

    /// Pins or unpins a card. The returned snapshot is only produced after the
    /// transaction committed.
    ///
    /// Pinning a file card first copies the files into Kopi's asset directory, so
    /// the card keeps working when the originals move or disappear. If a copy fails
    /// the card is left exactly as it was.
    @discardableResult
    public func setPinned(
        _ isPinned: Bool,
        for itemID: ClipboardItemID,
        now: Date = Date()
    ) async throws -> ClipboardItemSummary {
        guard isPinned else {
            return try await commitPin(false, for: itemID, snapshots: [], now: now)
        }
        let prepared = try await prepareFileSnapshots(for: itemID, at: now)
        do {
            return try await commitPin(true, for: itemID, snapshots: prepared.attachments, now: now)
        } catch {
            await assetStore.remove(relativePaths: prepared.createdPaths)
            throw error
        }
    }

    /// Unpinning keeps the card and its label, and restarts its retention period.
    @discardableResult
    public func unpin(for itemID: ClipboardItemID, now: Date = Date()) async throws -> ClipboardItemSummary {
        try await commitPin(false, for: itemID, snapshots: [], now: now)
    }

    private func commitPin(
        _ isPinned: Bool,
        for itemID: ClipboardItemID,
        snapshots: [SnapshotAttachment],
        now: Date
    ) async throws -> ClipboardItemSummary {
        try await pool.write { db in
            guard let row = try Self.summaryRow(db, id: itemID) else {
                throw HistoryStoreError.itemNotFound(itemID)
            }
            guard row.isPinned != isPinned else { return row.summary() }

            for snapshot in snapshots {
                try Self.registerAsset(db, snapshot.asset, itemID: itemID, role: .fileSnapshot)
                try db.execute(
                    sql: "UPDATE clip_file SET snapshot_asset_id = ? WHERE item_id = ? AND position = ?",
                    arguments: [snapshot.asset.id.rawValue, itemID.rawValue, snapshot.position]
                )
            }
            if isPinned {
                try db.execute(
                    sql: "UPDATE clip_item SET is_pinned = 1, pinned_at = ?, updated_at = ? WHERE id = ?",
                    arguments: [now.timeIntervalSinceReferenceDate, now.timeIntervalSinceReferenceDate, itemID.rawValue]
                )
            } else {
                try db.execute(
                    sql: """
                    UPDATE clip_item SET is_pinned = 0, pinned_at = NULL,
                        last_copied_at = ?, updated_at = ? WHERE id = ?
                    """,
                    arguments: [now.timeIntervalSinceReferenceDate, now.timeIntervalSinceReferenceDate, itemID.rawValue]
                )
            }
            guard let updated = try Self.summaryRow(db, id: itemID) else {
                throw HistoryStoreError.itemNotFound(itemID)
            }
            return updated.summary()
        }
    }

    private func prepareFileSnapshots(
        for itemID: ClipboardItemID,
        at date: Date
    ) async throws -> (attachments: [SnapshotAttachment], createdPaths: [String]) {
        let pending = try await pool.read { db in
            try ClipFileRow.fetchAll(
                db,
                sql: "SELECT * FROM clip_file WHERE item_id = ? AND snapshot_asset_id IS NULL ORDER BY position",
                arguments: [itemID.rawValue]
            ).map { PendingSnapshot(position: $0.position, path: $0.path) }
        }
        var attachments: [SnapshotAttachment] = []
        var createdPaths: [String] = []
        for snapshot in pending {
            do {
                let stored = try await assetStore.snapshotFile(at: URL(fileURLWithPath: snapshot.path), createdAt: date)
                attachments.append(SnapshotAttachment(position: snapshot.position, asset: stored.reference))
                if stored.wasCreated {
                    createdPaths.append(stored.reference.relativePath)
                }
            } catch {
                await assetStore.remove(relativePaths: createdPaths)
                throw HistoryStoreError.pinningFailed(itemID, Self.describe(error))
            }
        }
        return (attachments, createdPaths)
    }

    // MARK: - Collection

    /// Stores a copy of an existing card on the collection shelf.
    ///
    /// Dropping a card from another chip onto the collection adds its content rather
    /// than moving it: the original card is left exactly as it is, the copy shares its
    /// stored assets, and identical content already on the shelf collapses onto one
    /// card. A card that is already collected is simply returned.
    @discardableResult
    public func addToCollection(_ itemID: ClipboardItemID, now: Date = Date()) async throws -> HistoryInsertionResult {
        try await pool.write { db in
            guard let source = try Self.fetchDetail(db, itemID: itemID) else {
                throw HistoryStoreError.itemNotFound(itemID)
            }
            guard !source.summary.isCollection else { return .collapsed(source.summary) }
            let insertion = ClipboardItemInsertion(
                kind: source.summary.kind,
                label: source.summary.label,
                text: source.plainText ?? source.summary.primaryURL?.absoluteString,
                url: source.summary.primaryURL,
                representations: source.representations,
                fileReferences: source.fileReferences,
                sourceApp: source.summary.sourceApp,
                origin: .external(changeCount: 0),
                capturedAt: now,
                destination: .collection
            )
            return try Self.insertItem(db, insertion)
        }
    }

    /// Keeps a card on the collection shelf, or takes it off. Collected cards are
    /// kept out of retention and Clear History, the way pinned cards are; leaving the
    /// shelf restarts the retention period.
    @discardableResult
    public func setCollection(
        _ isCollection: Bool,
        for itemID: ClipboardItemID,
        now: Date = Date()
    ) async throws -> ClipboardItemSummary {
        try await pool.write { db in
            guard let row = try Self.summaryRow(db, id: itemID) else {
                throw HistoryStoreError.itemNotFound(itemID)
            }
            guard row.isCollection != isCollection else { return row.summary() }
            if isCollection {
                try db.execute(
                    sql: "UPDATE clip_item SET is_collection = 1, updated_at = ? WHERE id = ?",
                    arguments: [now.timeIntervalSinceReferenceDate, itemID.rawValue]
                )
            } else {
                try db.execute(
                    sql: "UPDATE clip_item SET is_collection = 0, last_copied_at = ?, updated_at = ? WHERE id = ?",
                    arguments: [now.timeIntervalSinceReferenceDate, now.timeIntervalSinceReferenceDate, itemID.rawValue]
                )
            }
            guard let updated = try Self.summaryRow(db, id: itemID) else {
                throw HistoryStoreError.itemNotFound(itemID)
            }
            return updated.summary()
        }
    }

    // MARK: - Deleting

    @discardableResult
    public func delete(_ itemID: ClipboardItemID) async throws -> HistoryDeletionReport {
        try await delete([itemID])
    }

    @discardableResult
    public func delete(_ itemIDs: [ClipboardItemID]) async throws -> HistoryDeletionReport {
        let result = try await pool.write { db -> (HistoryDeletionReport, AssetGarbageCollection) in
            let garbage = try Self.deleteItems(db, itemIDs: itemIDs)
            let report = HistoryDeletionReport(removedItemIDs: itemIDs, removedAssetIDs: garbage.assetIDs)
            return (report, garbage)
        }
        await removeAssetFiles(result.1)
        return result.0
    }

    // MARK: - Reading

    public func summary(for itemID: ClipboardItemID) async throws -> ClipboardItemSummary? {
        try await pool.read { db in try Self.summaryRow(db, id: itemID)?.summary() }
    }

    /// Full record, for preview, copy, paste and editing.
    public func detail(for itemID: ClipboardItemID) async throws -> ClipboardItemDetail? {
        try await pool.read { db in try Self.fetchDetail(db, itemID: itemID) }
    }

    /// One page of lightweight cards, 60 by default.
    public func page(_ query: HistoryQuery) async throws -> HistoryPageResult {
        try await pool.read { db in try Self.fetchPage(db, query: query) }
    }

    /// All source apps in history, independent of the current page and filters.
    public func sourceApplications() async throws -> [SourceAppInfo] {
        try await pool.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT source_app_bundle_id AS identifier, MAX(source_app_name) AS name
                FROM clip_item WHERE source_app_bundle_id IS NOT NULL AND source_app_bundle_id != ''
                GROUP BY source_app_bundle_id
                """)
            var apps: [String: SourceAppInfo] = [:]
            for row in rows {
                let identifier = SourceAppInfo.canonicalBundleIdentifier(row["identifier"])
                let name: String? = row["name"]
                apps[identifier] = SourceAppInfo(bundleIdentifier: identifier,
                    name: identifier == SourceAppInfo.kopiBundleIdentifier ? "Kopi" : name)
            }
            return apps.values.sorted {
                let order = ($0.displayName ?? "").localizedCaseInsensitiveCompare($1.displayName ?? "")
                return order == .orderedSame
                    ? ($0.bundleIdentifier ?? "") < ($1.bundleIdentifier ?? "") : order == .orderedAscending
            }
        }
    }

    public func count(scope: HistoryScope = .allClipboard) async throws -> Int {
        try await pool.read { db in
            switch scope {
            case .allClipboard: try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM clip_item") ?? 0
            case .pinned: try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM clip_item WHERE is_pinned = 1") ?? 0
            case .collection: try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM clip_item WHERE is_collection = 1") ?? 0
            }
        }
    }

    public func statistics() async throws -> HistoryStatistics {
        let counts = try await pool.read { db -> (Int, Int, Int, Int, SessionID, HistoryRetention) in
            let itemCount = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM clip_item") ?? 0
            let pinnedCount = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM clip_item WHERE is_pinned = 1") ?? 0
            let assetCount = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM clip_asset") ?? 0
            let assetBytes = try Int.fetchOne(db, sql: "SELECT COALESCE(SUM(byte_count), 0) FROM clip_asset") ?? 0
            let sessionID = try Self.currentSessionID(db) ?? SessionID()
            let retention = try Self.retentionValue(db)
            return (itemCount, pinnedCount, assetCount, assetBytes, sessionID, retention)
        }
        return HistoryStatistics(
            itemCount: counts.0,
            pinnedCount: counts.1,
            assetCount: counts.2,
            assetByteCount: counts.3,
            sessionID: counts.4,
            retention: counts.5
        )
    }

    // MARK: - Assets

    public func assetReferenceCount(for assetID: AssetID) async throws -> Int {
        try await pool.read { db in
            try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM clip_asset_reference WHERE asset_id = ?",
                arguments: [assetID.rawValue]
            ) ?? 0
        }
    }

    /// Whether a pinned card still needs this asset. Protected assets are never
    /// deleted, by cleanup or by deleting the card that introduced them.
    public func isAssetProtected(_ assetID: AssetID) async throws -> Bool {
        try await pool.read { db in
            let references = try ClipAssetReferenceRow.fetchAll(
                db,
                sql: ClipAssetReferenceRow.ledgerSelect + " WHERE r.asset_id = ?",
                arguments: [assetID.rawValue]
            )
            return AssetLedger(references: references.map(\.ledgerReference)).isProtected(assetID)
        }
    }

    // MARK: - Own copy bookkeeping

    /// Records the clipboard generation produced by Kopi itself, so the capture
    /// loop can ignore it without suppressing the next external copy.
    public func recordOwnCopy(_ state: OwnCopyState) async throws {
        try await pool.write { db in
            try Self.setMetadataValue(db, key: .ownCopyItemID, value: state.itemID.rawValue)
            try Self.setMetadataValue(db, key: .ownCopyChangeCount, value: String(state.changeCount))
        }
    }

    public func ownCopyState() async throws -> OwnCopyState? {
        try await pool.read { db in try Self.ownCopyState(db) }
    }

    public func isOwnCopy(changeCount: Int) async throws -> Bool {
        try await pool.read { db in
            try Self.ownCopyState(db)?.changeCount == changeCount
        }
    }

    public func clearOwnCopy() async throws {
        try await pool.write { db in try Self.clearOwnCopy(db) }
    }

    // MARK: - Diagnostics

    /// Connection settings the store guarantees, for the self check and for
    /// diagnosing a user's installation. No user content is included.
    public func diagnostics() async throws -> HistoryStoreDiagnostics {
        try await pool.writeWithoutTransaction { db in
            HistoryStoreDiagnostics(
                journalMode: try String.fetchOne(db, sql: "PRAGMA journal_mode") ?? "",
                synchronous: try Int.fetchOne(db, sql: "PRAGMA synchronous") ?? -1,
                foreignKeysEnabled: try Bool.fetchOne(db, sql: "PRAGMA foreign_keys") ?? false
            )
        }
    }

    // MARK: - Asset files

    /// Deletes asset files that no stored asset row refers to, for example files
    /// left behind by a crash between writing a file and committing its row.
    @discardableResult
    public func sweepAssetDirectory() async throws -> Int {
        let known = try await pool.read { db in
            try String.fetchAll(db, sql: "SELECT relative_path FROM clip_asset")
        }
        return await assetStore.removeFiles(notIn: Set(known))
    }

    private func removeAssetFiles(_ garbage: AssetGarbageCollection) async {
        guard !garbage.relativePaths.isEmpty else { return }
        await assetStore.remove(relativePaths: garbage.relativePaths)
    }

    private static func describe(_ error: any Error) -> String {
        if let error = error as? AssetStoreError {
            switch error {
            case .sourceUnavailable(let path): return "the original is unavailable at \(path)"
            case .copyFailed(let message): return "the copy failed: \(message)"
            case .writeFailed(let message): return "the copy could not be written: \(message)"
            case .assetNotFound(let id): return "the stored copy \(id) is missing"
            case .invalidRelativePath(let path): return "invalid asset path \(path)"
            case .insufficientSpace(let path): return "there is not enough space to preserve \(path)"
            }
        }
        return error.localizedDescription
    }
}

// MARK: - Store layer records

extension HistoryStore {
    struct SnapshotAttachment: Sendable {
        var position: Int
        var asset: AssetReference
    }

    struct PendingSnapshot: Sendable {
        var position: Int
        var path: String
    }

    struct AssetGarbageCollection: Sendable {
        var assetIDs: [AssetID] = []
        var relativePaths: [String] = []
    }
}

extension HistoryStore {
    /// Repairs earlier image-file captures without changing source files, pin state,
    /// labels, collection membership or retention clocks. Only already-owned assets
    /// are read; unowned external originals are never opened during startup.
    @discardableResult
    public func repairImageFileCards(using processor: CaptureProcessor) async throws -> Int {
        let ids = try await pool.read { db in
            try String.fetchAll(db, sql: "SELECT id FROM clip_item WHERE kind = 'files'")
        }
        let knownImages = try await pool.read { db -> [ClipboardRepresentation] in
            let imageIDs = try String.fetchAll(db, sql: "SELECT id FROM clip_item WHERE kind = 'image'")
            return try imageIDs.flatMap { rawID in
                try Self.representations(db, itemID: ClipboardItemID(rawValue: rawID))
                    .filter { $0.kind.isImage && $0.asset != nil }
            }
        }
        var repaired = 0
        for rawID in ids {
            let id = ClipboardItemID(rawValue: rawID)
            guard let original = try await detail(for: id), original.fileReferences.count == 1,
                  let file = original.fileReferences.first, !file.isDirectory else { continue }
            let digestComponents = Set(URL(fileURLWithPath: file.path).pathComponents.filter {
                $0.count == 64 && $0.allSatisfy { "0123456789abcdef".contains($0) }
            })
            var image: ClipboardItemInsertion
            if let stored = knownImages.first(where: { digestComponents.contains($0.contentHash) }) {
                // The export path contains the exact digest of bytes already owned
                // by Kopi. Recover from our asset, never the other app's directory.
                image = ClipboardItemInsertion(kind: .image, representations: [stored],
                    sourceApp: original.summary.sourceApp, origin: .kopi(itemID: id, changeCount: 0),
                    capturedAt: original.summary.createdAt)
            } else if let snapshotAsset = file.snapshot {
                let url = assetStore.fileURL(for: snapshotAsset)
                let snapshot = PasteboardSnapshot(changeCount: 0, items: [PasteboardItemSnapshot(flavours: [
                    PasteboardFlavour(type: ClipboardRepresentationKind.fileURL.pasteboardType, string: url.absoluteString)
                ])])
                guard CaptureProcessor.kind(of: snapshot) == .image,
                      let restored = try? await processor.insertion(from: snapshot, sourceApp: original.summary.sourceApp,
                        origin: .kopi(itemID: id, changeCount: 0), capturedAt: original.summary.createdAt)
                else { continue }
                image = restored
            } else {
                // Automatic repair must never open old external file references.
                continue
            }
            image.label = original.summary.label
            let prepared = image
            let changed = try await pool.write { db -> (Bool, AssetGarbageCollection) in
                var garbage = AssetGarbageCollection()
                guard let current = try Self.summaryRow(db, id: id), current.itemKind == .files,
                      current.summary().fingerprint == original.summary.fingerprint else { return (false, garbage) }
                let duplicate = try String.fetchOne(db, sql: "SELECT id FROM clip_item WHERE kind = 'image' AND fingerprint = ? AND is_edited = 0 ORDER BY is_collection, is_pinned, (label IS NOT NULL), row_id LIMIT 1",
                                                   arguments: [prepared.fingerprint.rawValue])
                if let duplicate, !original.summary.isPinned, !original.summary.isCollection,
                   !original.summary.isEdited, original.summary.label == nil {
                    try db.execute(sql: "UPDATE clip_item SET last_copied_at = MAX(last_copied_at, ?), updated_at = MAX(updated_at, ?) WHERE id = ?",
                        arguments: [original.summary.lastCopiedAt.timeIntervalSinceReferenceDate,
                                    original.summary.updatedAt.timeIntervalSinceReferenceDate, duplicate])
                    garbage = try Self.deleteItems(db, itemIDs: [id])
                } else {
                    try db.execute(sql: "DELETE FROM clip_asset_reference WHERE item_id = ?", arguments: [rawID])
                    try db.execute(sql: "DELETE FROM clip_representation WHERE item_id = ?", arguments: [rawID])
                    try db.execute(sql: "DELETE FROM clip_file WHERE item_id = ?", arguments: [rawID])
                    try Self.writeChildren(db, itemID: id, representations: prepared.representations, fileReferences: [])
                    let text = prepared.composedSearchText
                    let folded = ClipboardSearchText.folded(text)
                    try db.execute(sql: "UPDATE clip_item SET kind = 'image', excerpt = ?, search_text = ?, search_text_folded = ?, fingerprint = ?, file_names_json = '[]', primary_url = NULL WHERE id = ?",
                        arguments: [prepared.excerpt, text, folded, prepared.fingerprint.rawValue, rawID])
                    if let rowID = try Int64.fetchOne(db, sql: "SELECT row_id FROM clip_item WHERE id = ?", arguments: [rawID]) {
                        try Self.indexSearchText(db, rowID: rowID, foldedText: folded)
                    }
                }
                return (true, garbage)
            }
            await removeAssetFiles(changed.1)
            if changed.0 { repaired += 1 }
        }
        let garbage = try await pool.write { db in try Self.collectUnreferencedAssets(db) }
        await removeAssetFiles(garbage)
        return repaired
    }
}
