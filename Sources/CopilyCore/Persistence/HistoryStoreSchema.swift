import Foundation
import GRDB

/// Database schema of the history store.
enum HistoryStoreSchema {
    static func migrate(_ writer: any DatabaseWriter) throws {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1") { db in
            try db.execute(sql: schemaV1)
        }
        migrator.registerMigration("v2") { db in
            try db.execute(sql: schemaV2)
        }
        migrator.registerMigration("v3_copily_metadata") { db in
            // Existing installations have already applied v1 under the old name.
            // Early Copily builds created the new table directly, so accept both.
            if try !db.tableExists("copily_metadata"), try db.tableExists("velpy_metadata") {
                try db.execute(sql: "ALTER TABLE velpy_metadata RENAME TO copily_metadata")
            }
        }
        try migrator.migrate(writer)
    }

    /// `clip_item.row_id` is an autoincrementing rowid that never changes, so the
    /// FTS5 index can address items by rowid while `clip_item.id` stays the stable
    /// public identifier.
    private static let schemaV1 = """
    CREATE TABLE velpy_metadata(
        key TEXT PRIMARY KEY NOT NULL,
        value TEXT NOT NULL
    );

    CREATE TABLE clip_item(
        row_id INTEGER PRIMARY KEY AUTOINCREMENT,
        id TEXT NOT NULL UNIQUE,
        kind TEXT NOT NULL,
        label TEXT,
        excerpt TEXT NOT NULL,
        search_text TEXT NOT NULL,
        search_text_folded TEXT NOT NULL,
        fingerprint TEXT NOT NULL,
        primary_url TEXT,
        file_names_json TEXT NOT NULL DEFAULT '[]',
        source_app_bundle_id TEXT,
        source_app_name TEXT,
        source_app_process_id INTEGER,
        is_pinned INTEGER NOT NULL DEFAULT 0,
        pinned_at REAL,
        is_edited INTEGER NOT NULL DEFAULT 0,
        session_id TEXT NOT NULL,
        created_at REAL NOT NULL,
        last_copied_at REAL NOT NULL,
        updated_at REAL NOT NULL
    );

    CREATE INDEX clip_item_fingerprint ON clip_item(fingerprint);
    CREATE INDEX clip_item_last_copied ON clip_item(last_copied_at DESC);
    CREATE INDEX clip_item_pinned ON clip_item(is_pinned, pinned_at DESC);

    CREATE TABLE clip_asset(
        id TEXT PRIMARY KEY NOT NULL,
        kind TEXT NOT NULL,
        relative_path TEXT NOT NULL,
        byte_count INTEGER NOT NULL,
        content_hash TEXT NOT NULL,
        original_path TEXT,
        created_at REAL NOT NULL
    );

    CREATE TABLE clip_representation(
        item_id TEXT NOT NULL REFERENCES clip_item(id) ON DELETE CASCADE,
        position INTEGER NOT NULL,
        kind TEXT NOT NULL,
        content_hash TEXT NOT NULL,
        byte_count INTEGER NOT NULL,
        inline_text TEXT,
        inline_data BLOB,
        asset_id TEXT REFERENCES clip_asset(id) ON DELETE SET NULL,
        PRIMARY KEY (item_id, position)
    );

    CREATE TABLE clip_file(
        item_id TEXT NOT NULL REFERENCES clip_item(id) ON DELETE CASCADE,
        position INTEGER NOT NULL,
        path TEXT NOT NULL,
        display_name TEXT NOT NULL,
        byte_size INTEGER,
        is_directory INTEGER NOT NULL DEFAULT 0,
        snapshot_asset_id TEXT REFERENCES clip_asset(id) ON DELETE SET NULL,
        PRIMARY KEY (item_id, position)
    );

    CREATE TABLE clip_asset_reference(
        asset_id TEXT NOT NULL REFERENCES clip_asset(id) ON DELETE CASCADE,
        item_id TEXT NOT NULL REFERENCES clip_item(id) ON DELETE CASCADE,
        role TEXT NOT NULL,
        PRIMARY KEY (asset_id, item_id, role)
    );

    CREATE INDEX clip_asset_reference_item ON clip_asset_reference(item_id);

    CREATE VIRTUAL TABLE clip_item_search USING fts5(search_text, tokenize='trigram');
    """

    /// The collection shelf: cards marked here are kept out of retention and
    /// Clear History, the way pinned cards are.
    private static let schemaV2 = """
    ALTER TABLE clip_item ADD COLUMN is_collection INTEGER NOT NULL DEFAULT 0;
    CREATE INDEX clip_item_collection ON clip_item(is_collection, last_copied_at DESC);
    """
}

/// Keys of the `copily_metadata` table.
enum MetadataKey: String {
    case sessionID = "session_id"
    case sessionStartedAt = "session_started_at"
    case cleanShutdown = "clean_shutdown"
    case retention = "retention"
    case ownCopyItemID = "own_copy_item_id"
    case ownCopyChangeCount = "own_copy_change_count"
}

/// Role of an asset reference, so an asset can be shared by representations and
/// by pinned file snapshots at the same time.
enum AssetReferenceRole: String {
    case representation
    case fileSnapshot = "file_snapshot"
}
