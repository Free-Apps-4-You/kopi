import Foundation

/// Connection state of the Apple Notes tab.
///
/// Clipboard and Pinned stay usable in every one of these states: Notes failures
/// are contained by the Notes feature.
public enum NotesConnectionState: Sendable, Hashable, Codable {
    /// Not connected, and no request has been made yet.
    case disconnected
    /// Connecting or refreshing metadata.
    case loading
    /// The user denied the Apple Events automation request.
    case permissionDenied
    /// Connected, still indexing note bodies in bounded batches.
    case indexing(NotesIndexingProgress)
    /// Connected and indexed, but no notes exist in the included folders.
    case empty
    /// Connection failed; the message is user-presentable.
    case error(String)

    public var isConnected: Bool {
        switch self {
        case .indexing, .empty: true
        case .disconnected, .loading, .permissionDenied, .error: false
        }
    }

    public var indexingProgress: NotesIndexingProgress? {
        if case .indexing(let progress) = self { return progress }
        return nil
    }

    public var errorMessage: String? {
        if case .error(let message) = self { return message }
        return nil
    }

    public var displayName: String {
        switch self {
        case .disconnected: "Not Connected"
        case .loading: "Connecting"
        case .permissionDenied: "Permission Denied"
        case .indexing: "Indexing"
        case .empty: "No Notes"
        case .error: "Error"
        }
    }
}

/// Failures reported by a ``NotesClient``.
public enum NotesClientError: Error, Sendable, Equatable {
    case notConnected
    case permissionDenied
    case timedOut
    case automationUnavailable(String)
    case accountNotFound(NotesAccountID)
    case folderNotFound(NotesFolderID)
    case noteNotFound(NotesNoteID)
    case noteNotEditable(NotesNoteID)
    case noteChangedExternally(NotesNoteID)
    case commandFailed(String)
}

extension NotesClientError {
    /// Message to show the user for this failure.
    public var userMessage: String {
        switch self {
        case .notConnected: "Connect Apple Notes to use the Notes tab."
        case .permissionDenied: "Kopi is not allowed to control Apple Notes. Allow it in System Settings ▸ Privacy & Security ▸ Automation."
        case .timedOut: "Apple Notes did not answer in time."
        case .automationUnavailable(let message): message
        case .accountNotFound: "That Notes account is no longer available."
        case .folderNotFound: "That Notes folder is no longer available."
        case .noteNotFound: "That note no longer exists in Apple Notes."
        case .noteNotEditable: "That note can only be edited in Apple Notes."
        case .noteChangedExternally: "The note changed in Apple Notes. Reload it or save your text as a new note."
        case .commandFailed(let message): message
        }
    }

    /// Failures that mean the automation permission itself is missing.
    public var isPermissionFailure: Bool {
        switch self {
        case .permissionDenied: true
        case .notConnected, .timedOut, .automationUnavailable, .accountNotFound, .folderNotFound,
             .noteNotFound, .noteNotEditable, .noteChangedExternally, .commandFailed:
            false
        }
    }
}
