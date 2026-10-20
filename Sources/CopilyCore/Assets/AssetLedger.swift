import Foundation

/// Reference bookkeeping for app-managed assets.
///
/// An asset may be referenced by several cards at once; it is only deletable when
/// nothing references it. Cards that are pinned protect their assets regardless of
/// reference counting, which is what keeps a pinned file card working when its
/// original moves away.
public struct AssetLedger: Sendable, Hashable {
    public struct Reference: Sendable, Hashable {
        public let assetID: AssetID
        public let itemID: ClipboardItemID
        public let isPinned: Bool

        public init(assetID: AssetID, itemID: ClipboardItemID, isPinned: Bool) {
            self.assetID = assetID
            self.itemID = itemID
            self.isPinned = isPinned
        }
    }

    public let references: [Reference]

    public init(references: [Reference] = []) {
        self.references = references
    }

    public func referenceCount(of assetID: AssetID) -> Int {
        references.count { $0.assetID == assetID }
    }

    public func isReferenced(_ assetID: AssetID) -> Bool {
        references.contains { $0.assetID == assetID }
    }

    /// Whether a pinned card still needs the asset.
    public func isProtected(_ assetID: AssetID) -> Bool {
        references.contains { $0.assetID == assetID && $0.isPinned }
    }

    public func referencingItemIDs(of assetID: AssetID) -> [ClipboardItemID] {
        references.filter { $0.assetID == assetID }.map(\.itemID)
    }

    public func pinnedAssetIDs() -> Set<AssetID> {
        Set(references.filter(\.isPinned).map(\.assetID))
    }

    /// Assets among `candidates` that nothing references any more.
    public func unreferencedAssets(among candidates: [AssetID]) -> [AssetID] {
        let referenced = Set(references.map(\.assetID))
        return candidates.filter { !referenced.contains($0) }
    }
}
