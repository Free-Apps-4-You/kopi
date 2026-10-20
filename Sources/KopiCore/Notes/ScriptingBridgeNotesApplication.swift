import CoreServices
import Foundation
import NotesScripting

/// The real Notes objects, wrapping the ScriptingBridge interface.
///
/// Every call goes to one shared application object with a finite reply timeout, and
/// the delegate records the errors ScriptingBridge would otherwise raise, so the
/// caller sees them as thrown errors instead.
///
/// ScriptingBridge hands out its own objects — an `SBScriptableApplication` and plain
/// `SBObject` references — rather than instances of the generated classes, so those
/// references are reinterpreted rather than checked; the objects answer every selector
/// the generated header declares.
final class ScriptingBridgeNotesApplication: NotesScriptingApplication {
    private let application: NotesScripting.NotesApplication
    private let recorder = ScriptingBridgeFailureRecorder()

    init(bundleIdentifier: String, timeout: TimeInterval) throws {
        guard let application = SBApplication(bundleIdentifier: bundleIdentifier) else {
            throw NotesClientError.automationUnavailable("Apple Notes does not expose a scripting interface.")
        }
        application.delegate = recorder
        // SBApplication.timeout is measured in Apple Event ticks (1/60 second).
        application.timeout = Int(timeout * 60)
        application.sendMode = Int32(kAEWaitReply)
        self.application = Self.scriptingObject(application)
    }

    func accounts() throws -> [any NotesScriptingAccount] {
        try recorder.perform {
            Self.elements(application.accounts()).map {
                ScriptingBridgeNotesAccount(Self.scriptingObject($0), recorder: recorder)
            }
        }
    }

    func defaultAccount() throws -> (any NotesScriptingAccount)? {
        try recorder.perform {
            guard let account = application.defaultAccount.get() as? SBObject else { return nil }
            return ScriptingBridgeNotesAccount(Self.scriptingObject(account), recorder: recorder)
        }
    }

    func note(withID id: String) throws -> (any NotesScriptingNote)? {
        try recorder.perform {
            guard let note = application.notes().object(withID: id) as? SBObject else { return nil }
            return ScriptingBridgeNotesNote(Self.scriptingObject(note), recorder: recorder)
        }
    }

    func openNoteLocation(_ location: String) throws {
        try recorder.perform {
            application.openNoteLocation(location)
        }
    }

    func activate() {
        application.activate()
    }

    /// Preserve addressable element references; get() can return detached value records.
    static func elements(_ array: SBElementArray) -> [SBObject] {
        (0..<array.count).compactMap { array.object(at: $0) as? SBObject }
    }

    /// One of the references above, seen as the generated class it represents.
    static func scriptingObject<T: AnyObject>(_ object: AnyObject) -> T {
        unsafeBitCast(Unmanaged.passUnretained(object), to: Unmanaged<T>.self).takeUnretainedValue()
    }
}

private final class ScriptingBridgeNotesAccount: NotesScriptingAccount {
    private let account: NotesScripting.NotesAccount
    private let recorder: ScriptingBridgeFailureRecorder

    init(_ account: NotesScripting.NotesAccount, recorder: ScriptingBridgeFailureRecorder) {
        self.account = account
        self.recorder = recorder
    }

    func identifier() throws -> String {
        try recorder.stringProperty(of: account, code: 0x49442020)
    }

    func name() throws -> String {
        try recorder.stringProperty(of: account, code: 0x706E616D)
    }

    func folders() throws -> [any NotesScriptingFolder] {
        try recorder.perform {
            ScriptingBridgeNotesApplication.elements(account.folders()).map {
                ScriptingBridgeNotesFolder(ScriptingBridgeNotesApplication.scriptingObject($0), recorder: recorder)
            }
        }
    }

    func defaultFolder() throws -> (any NotesScriptingFolder)? {
        try recorder.perform {
            guard let folder = account.defaultFolder.get() as? SBObject else { return nil }
            return ScriptingBridgeNotesFolder(ScriptingBridgeNotesApplication.scriptingObject(folder), recorder: recorder)
        }
    }
}

private final class ScriptingBridgeNotesFolder: NotesScriptingFolder {
    private let folder: NotesScripting.NotesFolder
    private let recorder: ScriptingBridgeFailureRecorder

    init(_ folder: NotesScripting.NotesFolder, recorder: ScriptingBridgeFailureRecorder) {
        self.folder = folder
        self.recorder = recorder
    }

    func identifier() throws -> String {
        try recorder.stringProperty(of: folder, code: 0x49442020)
    }

    func name() throws -> String {
        try recorder.stringProperty(of: folder, code: 0x706E616D)
    }

    func note(withID id: String) throws -> (any NotesScriptingNote)? {
        try recorder.perform {
            guard let note = folder.notes().object(withID: id) as? SBObject else { return nil }
            return ScriptingBridgeNotesNote(ScriptingBridgeNotesApplication.scriptingObject(note), recorder: recorder)
        }
    }

    func notes() throws -> [any NotesScriptingNote] {
        try recorder.perform {
            ScriptingBridgeNotesApplication.elements(folder.notes()).map {
                ScriptingBridgeNotesNote(ScriptingBridgeNotesApplication.scriptingObject($0), recorder: recorder)
            }
        }
    }

    func createNote(body: String) throws -> any NotesScriptingNote {
        try recorder.perform {
            let note = NotesScripting.NotesNote(properties: ["body": body])
            folder.notes().add(note)
            return ScriptingBridgeNotesNote(note, recorder: recorder)
        }
    }
}

private final class ScriptingBridgeNotesNote: NotesScriptingNote {
    private let note: NotesScripting.NotesNote
    private let recorder: ScriptingBridgeFailureRecorder

    init(_ note: NotesScripting.NotesNote, recorder: ScriptingBridgeFailureRecorder) {
        self.note = note
        self.recorder = recorder
    }

    func identifier() throws -> String {
        try recorder.stringProperty(of: note, code: 0x49442020)
    }

    func name() throws -> String {
        try recorder.stringProperty(of: note, code: 0x706E616D)
    }

    func body() throws -> String {
        try recorder.stringProperty(of: note, code: 0x626F6479)
    }

    func plainText() throws -> String {
        try recorder.stringProperty(of: note, code: 0x74657874)
    }

    func modificationDate() throws -> Date? {
        try recorder.perform { note.modificationDate }
    }

    func isPasswordProtected() throws -> Bool {
        try recorder.perform { note.passwordProtected }
    }

    func isShared() throws -> Bool {
        try recorder.perform { note.shared }
    }

    func containerFolder() throws -> (any NotesScriptingFolder)? {
        try recorder.perform {
            guard let folder = note.container.get() as? SBObject else { return nil }
            return ScriptingBridgeNotesFolder(ScriptingBridgeNotesApplication.scriptingObject(folder), recorder: recorder)
        }
    }

    func setBody(_ body: String) throws {
        try recorder.perform { note.body = body }
    }

    func show() throws {
        try recorder.perform { _ = note.showSeparately(false) }
    }
}

/// The delegate ScriptingBridge reports failed events to, and the place each wrapper
/// looks for the failure of the call it just made.
final class ScriptingBridgeFailureRecorder: NSObject, SBApplicationDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var failure: NSError?

    func eventDidFail(_ event: UnsafePointer<AppleEvent>, withError error: any Error) -> Any? {
        lock.withLock { failure = error as NSError }
        return nil
    }

    /// Runs one scripting call and throws the failure the delegate recorded for it,
    /// so a failed event never comes back as a successful nil result.
    func perform<T>(_ call: () throws -> T) throws -> T {
        let value = try call()
        if let failure = takeFailure() {
            throw failure
        }
        return value
    }

    /// Resolve the property before bridging to Swift. Runtime SBObjects can return
    /// property specifiers or nil from generated selectors, despite their String! type.
    func stringProperty(of object: SBObject, code: AEKeyword) throws -> String {
        let value = try perform { object.property(withCode: code).get() }
        return try Self.requireString(value)
    }

    static func requireString(_ value: Any?) throws -> String {
        guard let value = value as? String else {
            throw NotesClientError.automationUnavailable("Apple Notes returned an unreadable text property. Try connecting again.")
        }
        return value
    }

    private func takeFailure() -> NSError? {
        lock.withLock {
            defer { failure = nil }
            return failure
        }
    }
}
