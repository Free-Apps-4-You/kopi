import Foundation

/// Which Apple Notes folders the Notes tab reads.
///
/// The user's choice is kept as identifiers; before anything was chosen the default
/// folder of the connected accounts is the one that is read, and if Notes has no
/// default folder the first one stands in.
public struct NotesFolderSelection: Sendable, Equatable {
    public private(set) var includedFolderIDs: Set<NotesFolderID>
    public private(set) var usesDefaultWhenEmpty: Bool

    public init(includedFolderIDs: Set<NotesFolderID> = [], usesDefaultWhenEmpty: Bool = true) {
        self.includedFolderIDs = includedFolderIDs
        self.usesDefaultWhenEmpty = usesDefaultWhenEmpty && includedFolderIDs.isEmpty
    }

    public var isEmpty: Bool { includedFolderIDs.isEmpty }

    public mutating func setIncluded(_ isIncluded: Bool, for folderID: NotesFolderID) {
        usesDefaultWhenEmpty = false
        if isIncluded {
            includedFolderIDs.insert(folderID)
        } else {
            includedFolderIDs.remove(folderID)
        }
    }

    /// Whether a folder is read: one the user included, or the default folder while no
    /// choice has been made yet.
    public func isIncluded(_ folder: NotesFolder, among folders: [NotesFolder]) -> Bool {
        if includedFolderIDs.contains(folder.id) { return true }
        guard includedFolderIDs.isEmpty, usesDefaultWhenEmpty else { return false }
        if let defaultFolder = folders.first(where: \.isDefault) {
            return defaultFolder.id == folder.id
        }
        return folders.first?.id == folder.id
    }

    /// The folders to read, in the order Notes lists them.
    public func effectiveFolders(from folders: [NotesFolder]) -> [NotesFolder] {
        let chosen = folders.filter { includedFolderIDs.contains($0.id) }
        guard chosen.isEmpty else { return chosen }
        guard usesDefaultWhenEmpty else { return [] }
        if let defaultFolder = folders.first(where: \.isDefault) {
            return [defaultFolder]
        }
        return folders.first.map { [$0] } ?? []
    }

    /// The chosen folders that still exist in the connected accounts.
    public func resolvedIDs(among folders: [NotesFolder]) -> Set<NotesFolderID> {
        let available = Set(folders.map(\.id))
        return includedFolderIDs.intersection(available)
    }
}
