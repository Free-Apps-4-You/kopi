import Foundation
import GRDB

/// Store-layer row types.
///
/// These exist so the database schema never leaks past the store: every public
/// API of ``HistoryStore`` exchanges `Sendable` domain snapshots only.
struct ClipItemSummaryRow: FetchableRecord {
    static let databaseTableName = "clip_item"

    /// Column list for the lightweight projection. Cards are always fetched with a
    /// table alias so the same list can be used with and without the search join.
    static let aliasedSummaryColumns = "i.row_id, i.id, i.kind, i.label, i.excerpt, i.primary_url, "
        + "i.file_names_json, i.source_app_bundle_id, i.source_app_name, i.source_app_process_id, "
        + "i.fingerprint, i.is_pinned, i.pinned_at, i.is_edited, i.is_collection, "
        + "i.created_at, i.last_copied_at, i.updated_at"

    static let summarySelect = "SELECT \(aliasedSummaryColumns) FROM clip_item i"

    var rowID: Int64
    var id: String
    var kind: String
    var label: String?
    var excerpt: String
    var primaryURL: String?
    var fileNamesJSON: String
    var sourceAppBundleID: String?
    var sourceAppName: String?
    var sourceAppProcessID: Int64?
    var fingerprint: String
    var isPinned: Bool
    var pinnedAt: Double?
    var isEdited: Bool
    var isCollection: Bool
    var createdAt: Double
    var lastCopiedAt: Double
    var updatedAt: Double

    init(row: Row) {
        rowID = row["row_id"]
        id = row["id"]
        kind = row["kind"]
        label = row["label"]
        excerpt = row["excerpt"]
        primaryURL = row["primary_url"]
        fileNamesJSON = row["file_names_json"]
        sourceAppBundleID = row["source_app_bundle_id"]
        sourceAppName = row["source_app_name"]
        sourceAppProcessID = row["source_app_process_id"]
        fingerprint = row["fingerprint"]
        isPinned = row["is_pinned"]
        pinnedAt = row["pinned_at"]
        isEdited = row["is_edited"]
        isCollection = row["is_collection"]
        createdAt = row["created_at"]
        lastCopiedAt = row["last_copied_at"]
        updatedAt = row["updated_at"]
    }

    var fileNames: [String] {
        guard let data = fileNamesJSON.data(using: .utf8) else { return [] }
        return (try? JSONDecoder().decode([String].self, from: data)) ?? []
    }

    var itemKind: ClipboardItemKind {
        ClipboardItemKind(rawValue: kind) ?? .text
    }

    var sourceApp: SourceAppInfo? {
        guard sourceAppBundleID != nil || sourceAppName != nil || sourceAppProcessID != nil else { return nil }
        return SourceAppInfo(
            bundleIdentifier: sourceAppBundleID,
            name: sourceAppName,
            processIdentifier: sourceAppProcessID.map(Int32.init)
        )
    }

    func summary() -> ClipboardItemSummary {
        ClipboardItemSummary(
            id: ClipboardItemID(rawValue: id),
            kind: itemKind,
            label: label,
            excerpt: excerpt,
            primaryURL: primaryURL.flatMap { URL(string: $0) },
            fileNames: fileNames,
            sourceApp: sourceApp,
            fingerprint: ContentFingerprint(rawValue: fingerprint),
            isPinned: isPinned,
            pinnedAt: pinnedAt.map(Date.init(timeIntervalSinceReferenceDate:)),
            isEdited: isEdited,
            isCollection: isCollection,
            createdAt: Date(timeIntervalSinceReferenceDate: createdAt),
            lastCopiedAt: Date(timeIntervalSinceReferenceDate: lastCopiedAt),
            updatedAt: Date(timeIntervalSinceReferenceDate: updatedAt)
        )
    }
}

struct ClipRepresentationRow: FetchableRecord {
    static let databaseTableName = "clip_representation"

    var itemID: String
    var position: Int
    var kind: String
    var contentHash: String
    var byteCount: Int
    var inlineText: String?
    var inlineData: Data?
    var assetID: String?

    init(row: Row) {
        itemID = row["item_id"]
        position = row["position"]
        kind = row["kind"]
        contentHash = row["content_hash"]
        byteCount = row["byte_count"]
        inlineText = row["inline_text"]
        inlineData = row["inline_data"]
        assetID = row["asset_id"]
    }

    func representation(assets: [String: AssetReference]) throws -> ClipboardRepresentation {
        guard let representationKind = ClipboardRepresentationKind(rawValue: kind) else {
            throw HistoryStoreError.invalidInsertion("unknown representation kind \(kind)")
        }
        let payload: ClipboardRepresentationPayload
        if let inlineText {
            payload = .text(inlineText)
        } else if let inlineData {
            payload = .data(inlineData)
        } else if let assetID, let asset = assets[assetID] {
            payload = .asset(asset)
        } else if let assetID {
            throw HistoryStoreError.assetNotFound(AssetID(rawValue: assetID))
        } else {
            payload = .data(Data())
        }
        return ClipboardRepresentation(
            kind: representationKind,
            payload: payload,
            byteCount: byteCount,
            contentHash: contentHash
        )
    }
}

struct ClipFileRow: FetchableRecord {
    static let databaseTableName = "clip_file"

    var itemID: String
    var position: Int
    var path: String
    var displayName: String
    var byteSize: Int64?
    var isDirectory: Bool
    var snapshotAssetID: String?

    init(row: Row) {
        itemID = row["item_id"]
        position = row["position"]
        path = row["path"]
        displayName = row["display_name"]
        byteSize = row["byte_size"]
        isDirectory = row["is_directory"]
        snapshotAssetID = row["snapshot_asset_id"]
    }

    func fileReference(snapshots: [String: AssetReference]) -> FileReference {
        FileReference(
            path: path,
            displayName: displayName,
            byteSize: byteSize,
            isDirectory: isDirectory,
            snapshot: snapshotAssetID.flatMap { snapshots[$0] }
        )
    }
}

struct ClipAssetRow: FetchableRecord {
    static let databaseTableName = "clip_asset"

    var id: String
    var kind: String
    var relativePath: String
    var byteCount: Int
    var contentHash: String
    var originalPath: String?
    var createdAt: Double

    init(row: Row) {
        id = row["id"]
        kind = row["kind"]
        relativePath = row["relative_path"]
        byteCount = row["byte_count"]
        contentHash = row["content_hash"]
        originalPath = row["original_path"]
        createdAt = row["created_at"]
    }

    var reference: AssetReference {
        AssetReference(
            id: AssetID(rawValue: id),
            kind: AssetKind(rawValue: kind) ?? .image,
            relativePath: relativePath,
            byteCount: byteCount,
            contentHash: contentHash,
            createdAt: Date(timeIntervalSinceReferenceDate: createdAt),
            originalPath: originalPath
        )
    }
}

/// Reference rows joined with the pin state of their owning card.
struct ClipAssetReferenceRow: FetchableRecord {
    static let databaseTableName = "clip_asset_reference"

    static let ledgerSelect = "SELECT r.asset_id, r.item_id, i.is_pinned "
        + "FROM clip_asset_reference r JOIN clip_item i ON i.id = r.item_id"

    var assetID: String
    var itemID: String
    var isPinned: Bool

    init(row: Row) {
        assetID = row["asset_id"]
        itemID = row["item_id"]
        isPinned = row["is_pinned"]
    }

    var ledgerReference: AssetLedger.Reference {
        AssetLedger.Reference(
            assetID: AssetID(rawValue: assetID),
            itemID: ClipboardItemID(rawValue: itemID),
            isPinned: isPinned
        )
    }
}
