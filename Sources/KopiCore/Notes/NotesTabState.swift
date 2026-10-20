import Foundation

/// What the Notes tab shows.
///
/// Derived from ``NotesConnectionState`` plus whether this build has a Notes client
/// at all, so the view never has to interpret the connection itself.
public enum NotesTabState: Sendable, Hashable {
    /// Not connected, and no request has been made yet.
    case disconnected
    /// Connecting, or loading notes.
    case connecting
    /// The user denied the Apple Events automation request.
    case permissionDenied
    /// Connected, still indexing note bodies.
    case indexing(NotesIndexingProgress)
    /// Connected and indexed.
    case loaded
    /// Connected and indexed, with no notes in the included folders.
    case empty
    /// No Notes client in this build.
    case unavailable(String)
    /// Connection or loading failed; the message is user-presentable.
    case error(String)

    public init(connectionState: NotesConnectionState, automationUnavailable: String? = nil) {
        if let automationUnavailable {
            self = .unavailable(automationUnavailable)
            return
        }
        switch connectionState {
        case .disconnected: self = .disconnected
        case .loading: self = .connecting
        case .permissionDenied: self = .permissionDenied
        case .indexing(let progress): self = progress.isComplete ? .loaded : .indexing(progress)
        case .empty: self = .empty
        case .error(let message): self = .error(message)
        }
    }

    /// States in which note cards can be shown.
    public var showsNoteList: Bool {
        switch self {
        case .indexing, .loaded: true
        case .disconnected, .connecting, .permissionDenied, .empty, .unavailable, .error: false
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

    public var unavailableMessage: String? {
        if case .unavailable(let message) = self { return message }
        return nil
    }

    public var isBusy: Bool {
        switch self {
        case .connecting, .indexing: true
        case .disconnected, .permissionDenied, .loaded, .empty, .unavailable, .error: false
        }
    }

    public var isConnected: Bool {
        switch self {
        case .indexing, .loaded, .empty: true
        case .disconnected, .connecting, .permissionDenied, .unavailable, .error: false
        }
    }

    public var displayName: String {
        switch self {
        case .disconnected: "Not Connected"
        case .connecting: "Connecting"
        case .permissionDenied: "Permission Denied"
        case .indexing: "Indexing"
        case .loaded: "Connected"
        case .empty: "No Notes"
        case .unavailable: "Unavailable"
        case .error: "Error"
        }
    }
}
