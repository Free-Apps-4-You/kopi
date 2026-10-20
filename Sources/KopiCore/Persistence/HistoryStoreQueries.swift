import Foundation
import GRDB

/// Store layer helpers. Everything here is internal to the module: the public
/// surface of ``HistoryStore`` only exchanges domain snapshots.
extension HistoryStore {
    // MARK: - Metadata

    static func bootstrapMetadata(_ db: Database) throws {
        let isNewDatabase = try metadataValue(db, key: .sessionID) == nil
        if isNewDatabase {
            try setMetadataValue(db, key: .sessionID, value: SessionID().rawValue)
            // Nothing can be left over from a session that never ran.
            try setMetadataValue(db, key: .cleanShutdown, value: "1")
        }
        if try metadataValue(db, key: .retention) == nil {
            try setMetadataValue(db, key: .retention, value: HistoryRetention.default.rawValue)
        }
        if try metadataValue(db, key: .sessionStartedAt) == nil {
            try setMetadataValue(db, key: .sessionStartedAt, value: String(Date().timeIntervalSince1970))
        }
    }

    static func metadataValue(_ db: Database, key: MetadataKey) throws -> String? {
        try String.fetchOne(db, sql: "SELECT value FROM kopi_metadata WHERE key = ?", arguments: [key.rawValue])
    }

    static func setMetadataValue(_ db: Database, key: MetadataKey, value: String) throws {
        try db.execute(
            sql: "INSERT INTO kopi_metadata(key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value",
            arguments: [key.rawValue, value]
        )
    }

    static func removeMetadataValue(_ db: Database, key: MetadataKey) throws {
        try db.execute(sql: "DELETE FROM kopi_metadata WHERE key = ?", arguments: [key.rawValue])
    }

    static func currentSessionID(_ db: Database) throws -> SessionID? {
        try metadataValue(db, key: .sessionID).map { SessionID(rawValue: $0) }
    }

    static func retentionValue(_ db: Database) throws -> HistoryRetention {
        guard let raw = try metadataValue(db, key: .retention), let retention = HistoryRetention(rawValue: raw) else {
            return .default
        }
        return retention
    }

    static func ownCopyState(_ db: Database) throws -> OwnCopyState? {
        guard let itemID = try metadataValue(db, key: .ownCopyItemID),
              let changeCount = try metadataValue(db, key: .ownCopyChangeCount).flatMap(Int.init)
        else {
            return nil
        }
        return OwnCopyState(itemID: ClipboardItemID(rawValue: itemID), changeCount: changeCount)
    }

    static func setOwnCopy(_ db: Database, state: OwnCopyState) throws {
        try setMetadataValue(db, key: .ownCopyItemID, value: state.itemID.rawValue)
        try setMetadataValue(db, key: .ownCopyChangeCount, value: String(state.changeCount))
    }

    static func clearOwnCopy(_ db: Database) throws {
        try removeMetadataValue(db, key: .ownCopyItemID)
        try removeMetadataValue(db, key: .ownCopyChangeCount)
    }

    static func recordOwnCopyIfNeeded(_ db: Database, origin: CopyOrigin) throws {
        guard let itemID = origin.sourceItemID else { return }
        try setOwnCopy(db, state: OwnCopyState(itemID: itemID, changeCount: origin.changeCount))
    }

    static func clearOwnCopyIfDeleted(_ db: Database, itemIDs: [ClipboardItemID]) throws {
        guard let state = try ownCopyState(db), itemIDs.contains(state.itemID) else { return }
        try clearOwnCopy(db)
    }

    // MARK: - Item rows

    static func summaryRow(_ db: Database, id: ClipboardItemID) throws -> ClipItemSummaryRow? {
        try ClipItemSummaryRow.fetchOne(
            db,
            sql: ClipItemSummaryRow.summarySelect + " WHERE i.id = ?",
            arguments: [id.rawValue]
        )
    }

    static func encodeFileNames(_ names: [String]) -> String {
        guard !names.isEmpty, let data = try? JSONEncoder().encode(names), let json = String(data: data, encoding: .utf8) else {
            return "[]"
        }
        return json
    }

    /// Keeps the trigram index in step with the stored search text. Always called
    /// inside the same transaction as the content change.
    static func indexSearchText(_ db: Database, rowID: Int64, foldedText: String) throws {
        try db.execute(sql: "DELETE FROM clip_item_search WHERE rowid = ?", arguments: [rowID])
        try db.execute(sql: "INSERT INTO clip_item_search(rowid, search_text) VALUES (?, ?)", arguments: [rowID, foldedText])
    }

    static func assetsByID(_ db: Database, itemID: ClipboardItemID) throws -> [String: AssetReference] {
        let rows = try ClipAssetRow.fetchAll(
            db,
            sql: "SELECT a.* FROM clip_asset a JOIN clip_asset_reference r ON r.asset_id = a.id WHERE r.item_id = ?",
            arguments: [itemID.rawValue]
        )
        return Dictionary(rows.map { ($0.id, $0.reference) }, uniquingKeysWith: { first, _ in first })
    }

    static func representations(_ db: Database, itemID: ClipboardItemID) throws -> [ClipboardRepresentation] {
        let assets = try assetsByID(db, itemID: itemID)
        return try ClipRepresentationRow.fetchAll(
            db,
            sql: "SELECT * FROM clip_representation WHERE item_id = ? ORDER BY position",
            arguments: [itemID.rawValue]
        ).map { try $0.representation(assets: assets) }
    }

    static func fileReferences(_ db: Database, itemID: ClipboardItemID) throws -> [FileReference] {
        let assets = try assetsByID(db, itemID: itemID)
        return try ClipFileRow.fetchAll(
            db,
            sql: "SELECT * FROM clip_file WHERE item_id = ? ORDER BY position",
            arguments: [itemID.rawValue]
        ).map { $0.fileReference(snapshots: assets) }
    }

    static func fetchDetail(_ db: Database, itemID: ClipboardItemID) throws -> ClipboardItemDetail? {
        guard let row = try summaryRow(db, id: itemID) else { return nil }
        let searchText = try String.fetchOne(
            db,
            sql: "SELECT search_text FROM clip_item WHERE id = ?",
            arguments: [itemID.rawValue]
        ) ?? ""
        let assets = try assetsByID(db, itemID: itemID)
        let representations = try ClipRepresentationRow.fetchAll(
            db,
            sql: "SELECT * FROM clip_representation WHERE item_id = ? ORDER BY position",
            arguments: [itemID.rawValue]
        ).map { try $0.representation(assets: assets) }
        let files = try ClipFileRow.fetchAll(
            db,
            sql: "SELECT * FROM clip_file WHERE item_id = ? ORDER BY position",
            arguments: [itemID.rawValue]
        ).map { $0.fileReference(snapshots: assets) }
        return ClipboardItemDetail(
            summary: row.summary(),
            searchText: searchText,
            representations: representations,
            assets: assets.values.sorted { $0.id.rawValue < $1.id.rawValue },
            fileReferences: files
        )
    }

    // MARK: - Paging and searching

    static func fetchPage(_ db: Database, query: HistoryQuery) throws -> HistoryPageResult {
        let limit = min(max(query.page.limit, 1), 500)
        let offset = max(query.page.offset, 0)
        var join = ""
        var conditions: [String] = []
        var arguments: [String: (any DatabaseValueConvertible)?] = [:]
        var mode: HistorySearchMode = .listing

        switch query.scope {
        case .allClipboard:
            break
        case .pinned:
            conditions.append("i.is_pinned = 1")
        case .collection:
            conditions.append("i.is_collection = 1")
        }
        if !query.includesCollection { conditions.append("i.is_collection = 0") }
        if !query.kinds.isEmpty {
            let kinds = query.kinds.map(\.rawValue).sorted()
            let placeholders = kinds.enumerated().map { ":kind\($0.offset)" }.joined(separator: ", ")
            conditions.append("i.kind IN (\(placeholders))")
            for (index, kind) in kinds.enumerated() {
                arguments["kind\(index)"] = kind
            }
        }

        if let identifier = query.sourceAppBundleIdentifier {
            if SourceAppInfo.canonicalBundleIdentifier(identifier) == SourceAppInfo.kopiBundleIdentifier {
                let identifiers = SourceAppInfo.kopiBundleIdentifiers
                let placeholders = identifiers.indices.map { ":app\($0)" }.joined(separator: ", ")
                conditions.append("i.source_app_bundle_id IN (\(placeholders))")
                for (index, identifier) in identifiers.enumerated() { arguments["app\(index)"] = identifier }
            } else {
                conditions.append("i.source_app_bundle_id = :sourceApp")
                arguments["sourceApp"] = identifier
            }
        }

        let searchText = query.searchText
        if !searchText.isEmpty {
            if let pattern = ClipboardSearchText.fullTextPattern(for: searchText) {
                mode = .fullTextIndex
                join = " JOIN clip_item_search ON clip_item_search.rowid = i.row_id"
                conditions.append("clip_item_search MATCH :pattern")
                arguments["pattern"] = pattern
            } else {
                mode = .scan
                conditions.append("instr(i.search_text_folded, :needle) > 0")
                arguments["needle"] = ClipboardSearchText.scanNeedle(for: searchText)
            }
        }

        let whereClause = conditions.isEmpty ? "" : " WHERE " + conditions.joined(separator: " AND ")
        let orderClause = Self.orderClause(for: query.sort)
        arguments["limit"] = limit
        arguments["offset"] = offset

        let totalCount = try Int.fetchOne(
            db,
            sql: "SELECT COUNT(*) FROM clip_item i\(join)\(whereClause)",
            arguments: StatementArguments(arguments)
        ) ?? 0
        let rows = try ClipItemSummaryRow.fetchAll(
            db,
            sql: "\(ClipItemSummaryRow.summarySelect)\(join)\(whereClause) ORDER BY \(orderClause) LIMIT :limit OFFSET :offset",
            arguments: StatementArguments(arguments)
        )
        return HistoryPageResult(
            items: rows.map { $0.summary() },
            totalCount: totalCount,
            page: HistoryPage(offset: offset, limit: limit),
            searchMode: mode
        )
    }

    static func orderClause(for sort: HistorySort) -> String {
        switch sort {
        case .recentlyCopied: "i.last_copied_at DESC, i.row_id DESC"
        case .recentlyPinned: "i.is_pinned DESC, i.pinned_at DESC, i.last_copied_at DESC, i.row_id DESC"
        }
    }

    // MARK: - Inserting

    /// Stores one insertion inside the caller's transaction.
    ///
    /// This is the single path both capture and the collection use, so a card is
    /// always written the same way whichever way it was created. Collapsing matches
    /// unedited content of the same fingerprint; a collection insertion only matches
    /// collected cards, while an ordinary capture also collapses onto a collected one.
    static func insertItem(_ db: Database, _ insertion: ClipboardItemInsertion) throws -> HistoryInsertionResult {
        let fingerprint = insertion.fingerprint
        let folded = ClipboardSearchText.folded(insertion.composedSearchText)

        if !insertion.carriesNoContent,
           let existing = try collapseCandidate(db, fingerprint: fingerprint, destination: insertion.destination, label: insertion.label) {
            if insertion.origin.isExternal {
                try db.execute(
                    sql: "UPDATE clip_item SET last_copied_at = ?, updated_at = ? WHERE row_id = ?",
                    arguments: [
                        insertion.capturedAt.timeIntervalSinceReferenceDate,
                        insertion.capturedAt.timeIntervalSinceReferenceDate,
                        existing.rowID
                    ]
                )
            }
            try recordOwnCopyIfNeeded(db, origin: insertion.origin)
            let refreshed = try summaryRow(db, id: ClipboardItemID(rawValue: existing.id)) ?? existing
            return .collapsed(refreshed.summary())
        }

        let sessionID = try currentSessionID(db) ?? SessionID()
        try db.execute(
            sql: """
            INSERT INTO clip_item(
                id, kind, label, excerpt, search_text, search_text_folded, fingerprint, primary_url,
                file_names_json, source_app_bundle_id, source_app_name, source_app_process_id,
                is_pinned, pinned_at, is_edited, is_collection, session_id, created_at, last_copied_at, updated_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 0, NULL, 0, ?, ?, ?, ?, ?)
            """,
            arguments: [
                insertion.id.rawValue,
                insertion.kind.rawValue,
                insertion.label,
                insertion.excerpt,
                insertion.composedSearchText,
                folded,
                fingerprint.rawValue,
                insertion.url?.absoluteString,
                encodeFileNames(insertion.fileReferences.map(\.displayName)),
                insertion.sourceApp?.bundleIdentifier,
                insertion.sourceApp?.name,
                insertion.sourceApp?.processIdentifier.map { Int($0) },
                insertion.destination.isCollection ? 1 : 0,
                sessionID.rawValue,
                insertion.capturedAt.timeIntervalSinceReferenceDate,
                insertion.capturedAt.timeIntervalSinceReferenceDate,
                insertion.capturedAt.timeIntervalSinceReferenceDate
            ]
        )
        let rowID = db.lastInsertedRowID
        try indexSearchText(db, rowID: rowID, foldedText: folded)
        try writeChildren(
            db,
            itemID: insertion.id,
            representations: insertion.representations,
            fileReferences: insertion.fileReferences
        )
        try recordOwnCopyIfNeeded(db, origin: insertion.origin)

        guard let row = try summaryRow(db, id: insertion.id) else {
            throw HistoryStoreError.invalidInsertion("insert did not persist \(insertion.id)")
        }
        return .inserted(row.summary())
    }

    /// The card an insertion of this content collapses onto: the newest unedited card
    /// of the same fingerprint. A collection insertion only considers cards already on
    /// the shelf. An explicitly supplied label must also match, so a labeled manual
    /// addition cannot silently lose its label or rename another collected card.
    static func collapseCandidate(
        _ db: Database,
        fingerprint: ContentFingerprint,
        destination: CaptureDestination,
        label: String? = nil
    ) throws -> ClipItemSummaryRow? {
        var sql = ClipItemSummaryRow.summarySelect + " WHERE i.fingerprint = ? AND i.is_edited = 0"
        var arguments: StatementArguments = [fingerprint.rawValue]
        if let label {
            sql += " AND i.label = ?"
            arguments += [label]
        }
        if destination.isCollection {
            sql += " AND i.is_collection = 1"
        }
        sql += " ORDER BY i.last_copied_at DESC, i.row_id DESC LIMIT 1"
        return try ClipItemSummaryRow.fetchOne(db, sql: sql, arguments: arguments)
    }

    // MARK: - Writing children

    static func writeChildren(
        _ db: Database,
        itemID: ClipboardItemID,
        representations: [ClipboardRepresentation],
        fileReferences: [FileReference]
    ) throws {
        for (position, representation) in representations.enumerated() {
            var inlineText: String?
            var inlineData: Data?
            var assetID: String?
            switch representation.payload {
            case .text(let value):
                inlineText = value
            case .data(let bytes):
                inlineData = bytes
            case .asset(let reference):
                assetID = reference.id.rawValue
                try registerAsset(db, reference, itemID: itemID, role: .representation)
            }
            try db.execute(
                sql: """
                INSERT INTO clip_representation(item_id, position, kind, content_hash, byte_count, inline_text, inline_data, asset_id)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                """,
                arguments: [
                    itemID.rawValue,
                    position,
                    representation.kind.rawValue,
                    representation.contentHash,
                    representation.byteCount,
                    inlineText,
                    inlineData,
                    assetID
                ]
            )
        }
        for (position, file) in fileReferences.enumerated() {
            if let snapshot = file.snapshot {
                try registerAsset(db, snapshot, itemID: itemID, role: .fileSnapshot)
            }
            try db.execute(
                sql: """
                INSERT INTO clip_file(item_id, position, path, display_name, byte_size, is_directory, snapshot_asset_id)
                VALUES (?, ?, ?, ?, ?, ?, ?)
                """,
                arguments: [
                    itemID.rawValue,
                    position,
                    file.path,
                    file.displayName,
                    file.byteSize,
                    file.isDirectory,
                    file.snapshot?.id.rawValue
                ]
            )
        }
    }

    static func registerAsset(_ db: Database, _ asset: AssetReference, itemID: ClipboardItemID, role: AssetReferenceRole) throws {
        try db.execute(
            sql: """
            INSERT OR IGNORE INTO clip_asset(id, kind, relative_path, byte_count, content_hash, original_path, created_at)
            VALUES (?, ?, ?, ?, ?, ?, ?)
            """,
            arguments: [
                asset.id.rawValue,
                asset.kind.rawValue,
                asset.relativePath,
                asset.byteCount,
                asset.contentHash,
                asset.originalPath,
                asset.createdAt.timeIntervalSinceReferenceDate
            ]
        )
        try db.execute(
            sql: "INSERT OR IGNORE INTO clip_asset_reference(asset_id, item_id, role) VALUES (?, ?, ?)",
            arguments: [asset.id.rawValue, itemID.rawValue, role.rawValue]
        )
    }

    static func rebuiltRepresentations(
        kind: ClipboardItemKind,
        text: String,
        url: URL?,
        richText: RichTextDocument?
    ) -> [ClipboardRepresentation] {
        switch kind {
        case .text:
            return [ClipboardRepresentation(kind: .plainText, payload: .text(text))]
        case .richText:
            let document = richText ?? RichTextDocument(plainText: text)
            let plain = document.plainText.isEmpty ? text : document.plainText
            return [
                ClipboardRepresentation(kind: .plainText, payload: .text(plain)),
                ClipboardRepresentation(kind: .html, payload: .text(document.html())),
                ClipboardRepresentation(kind: .rtf, payload: .data(document.rtf()))
            ]
        case .link:
            guard let url else {
                return [ClipboardRepresentation(kind: .plainText, payload: .text(text))]
            }
            let label = text.isEmpty ? url.absoluteString : text
            let document = richText ?? RichTextDocument(runs: [RichTextDocument.Run(text: label, linkURL: url)])
            return [
                ClipboardRepresentation(kind: .plainText, payload: .text(label)),
                ClipboardRepresentation(kind: .link, payload: .text(url.absoluteString)),
                ClipboardRepresentation(kind: .html, payload: .text(document.html())),
                ClipboardRepresentation(kind: .rtf, payload: .data(document.rtf()))
            ]
        case .image, .files:
            return []
        }
    }

    // MARK: - Deleting and retention

    static func deleteItems(_ db: Database, itemIDs: [ClipboardItemID]) throws -> AssetGarbageCollection {
        guard !itemIDs.isEmpty else { return AssetGarbageCollection() }
        let ids = itemIDs.map(\.rawValue)
        let placeholders = databaseQuestionMarks(count: ids.count)
        try db.execute(
            sql: "DELETE FROM clip_item_search WHERE rowid IN (SELECT row_id FROM clip_item WHERE id IN (\(placeholders)))",
            arguments: StatementArguments(ids)
        )
        try db.execute(
            sql: "DELETE FROM clip_item WHERE id IN (\(placeholders))",
            arguments: StatementArguments(ids)
        )
        try clearOwnCopyIfDeleted(db, itemIDs: itemIDs)
        return try collectUnreferencedAssets(db)
    }

    /// Assets that no card references any more, and that no pinned card protects.
    static func collectUnreferencedAssets(_ db: Database) throws -> AssetGarbageCollection {
        let candidates = try ClipAssetRow.fetchAll(
            db,
            sql: "SELECT * FROM clip_asset WHERE id NOT IN (SELECT asset_id FROM clip_asset_reference)"
        )
        guard !candidates.isEmpty else { return AssetGarbageCollection() }

        let references = try ClipAssetReferenceRow.fetchAll(db, sql: ClipAssetReferenceRow.ledgerSelect)
        let ledger = AssetLedger(references: references.map(\.ledgerReference))
        let unreferenced = Set(ledger.unreferencedAssets(among: candidates.map { AssetID(rawValue: $0.id) }))
        let doomed = candidates.filter { unreferenced.contains(AssetID(rawValue: $0.id)) && !ledger.isProtected(AssetID(rawValue: $0.id)) }
        guard !doomed.isEmpty else { return AssetGarbageCollection() }

        let ids = doomed.map(\.id)
        try db.execute(
            sql: "DELETE FROM clip_asset WHERE id IN (\(databaseQuestionMarks(count: ids.count)))",
            arguments: StatementArguments(ids)
        )
        return AssetGarbageCollection(
            assetIDs: doomed.map { AssetID(rawValue: $0.id) },
            relativePaths: doomed.map(\.relativePath)
        )
    }

    /// Applies retention. Pinned and collected cards are never considered.
    static func cleanup(
        _ db: Database,
        trigger: HistoryCleanupTrigger,
        retention: HistoryRetention,
        now: Date,
        sessionID: SessionID?
    ) throws -> (HistoryCleanupReport, AssetGarbageCollection) {
        let expired: [ClipItemSummaryRow]
        switch retention {
        case .currentSession:
            if let sessionID {
                expired = try ClipItemSummaryRow.fetchAll(
                    db,
                    sql: ClipItemSummaryRow.summarySelect + " WHERE i.is_pinned = 0 AND i.is_collection = 0 AND i.session_id <> ?",
                    arguments: [sessionID.rawValue]
                )
            } else {
                expired = try ClipItemSummaryRow.fetchAll(
                    db,
                    sql: ClipItemSummaryRow.summarySelect + " WHERE i.is_pinned = 0 AND i.is_collection = 0"
                )
            }
        case .sevenDays, .thirtyDays:
            let cutoff = retention.expirationCutoff(now: now) ?? now
            expired = try ClipItemSummaryRow.fetchAll(
                db,
                sql: ClipItemSummaryRow.summarySelect + " WHERE i.is_pinned = 0 AND i.is_collection = 0 AND i.last_copied_at < ?",
                arguments: [cutoff.timeIntervalSinceReferenceDate]
            )
        }
        let itemIDs = expired.map { ClipboardItemID(rawValue: $0.id) }
        let garbage = try deleteItems(db, itemIDs: itemIDs)
        let report = HistoryCleanupReport(
            trigger: trigger,
            retention: retention,
            cutoff: retention.expirationCutoff(now: now),
            removedItemIDs: itemIDs,
            removedAssetIDs: garbage.assetIDs
        )
        return (report, garbage)
    }
}

extension ClipboardItemInsertion {
    /// Text indexed for search: content, URL, label and file names.
    var composedSearchText: String {
        ClipboardSearchText.searchText(
            text: text,
            url: url,
            label: label,
            fileNames: fileReferences.map(\.displayName)
        )
    }

    /// Card excerpt.
    var excerpt: String {
        let names = fileReferences.map(\.displayName)
        let source = text ?? url?.absoluteString ?? (names.isEmpty ? (label ?? "") : names.joined(separator: ", "))
        return ClipboardSearchText.excerpt(from: source)
    }

    var validationError: HistoryStoreError? {
        switch kind {
        case .text:
            guard text != nil || representations.contains(where: { $0.kind == .plainText }) else {
                return .invalidInsertion("a text card needs text or a plain-text representation")
            }
        case .richText, .image:
            guard !representations.isEmpty else {
                return .invalidInsertion("a \(kind.rawValue) card needs at least one representation")
            }
        case .link:
            guard url != nil || representations.contains(where: { $0.kind == .link }) else {
                return .invalidInsertion("a link card needs a URL")
            }
        case .files:
            guard !fileReferences.isEmpty else {
                return .invalidInsertion("a files card needs at least one file reference")
            }
        }
        if let id = origin.sourceItemID, origin.changeCount < 0 {
            return .invalidInsertion("own copy \(id) has a negative pasteboard change count")
        }
        return nil
    }
}
