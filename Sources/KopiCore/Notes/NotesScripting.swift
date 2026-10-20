import Foundation

/// The Notes objects a ``ScriptingBridgeNotesRunner`` talks to, in Notes' own terms:
/// one protocol per scripting class of the application's dictionary.
///
/// The real implementations wrap the ScriptingBridge objects; fakes stand in for
/// Notes in tests. Failures are the errors ScriptingBridge reports, so the runner
/// owns the mapping to ``NotesClientError``.
protocol NotesScriptingApplication: AnyObject {
    func accounts() throws -> [any NotesScriptingAccount]
    func defaultAccount() throws -> (any NotesScriptingAccount)?
    func note(withID id: String) throws -> (any NotesScriptingNote)?
    func openNoteLocation(_ location: String) throws
    func activate()
}

protocol NotesScriptingAccount: AnyObject {
    func identifier() throws -> String
    func name() throws -> String
    func folders() throws -> [any NotesScriptingFolder]
    func defaultFolder() throws -> (any NotesScriptingFolder)?
}

protocol NotesScriptingFolder: AnyObject {
    func identifier() throws -> String
    func name() throws -> String
    func note(withID id: String) throws -> (any NotesScriptingNote)?
    func notes() throws -> [any NotesScriptingNote]
    func folders() throws -> [any NotesScriptingFolder]
}

protocol NotesScriptingNote: AnyObject {
    func identifier() throws -> String
    func name() throws -> String
    func body() throws -> String
    func plainText() throws -> String
    func modificationDate() throws -> Date?
    func isPasswordProtected() throws -> Bool
    func isShared() throws -> Bool
    func containerFolder() throws -> (any NotesScriptingFolder)?
    func show() throws
}
