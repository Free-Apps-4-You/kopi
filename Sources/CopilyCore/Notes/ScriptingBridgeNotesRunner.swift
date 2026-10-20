import Foundation

/// The real Notes automation, through ScriptingBridge.
///
/// Notes stays the source of truth: accounts, folders and note text are read from the
/// scripting interface, and only the references that make later requests addressable
/// are cached. Failures ScriptingBridge reports are mapped to ``NotesClientError``,
/// so the client's connection states are unchanged.
public actor ScriptingBridgeNotesRunner: NotesAutomationRunning {
    /// The scripting interface Copily drives.
    public static let bundleIdentifier = "com.apple.Notes"

    /// Notes answers most requests quickly; anything past this is treated as a
    /// timeout rather than left hanging.
    public static let defaultTimeout: TimeInterval = 20

    typealias ApplicationFactory = @Sendable (TimeInterval) throws -> any NotesScriptingApplication

    private let timeout: TimeInterval
    private let makeApplication: ApplicationFactory

    private var application: (any NotesScriptingApplication)?
    private var accounts: [NotesAccount] = []
    private var accountObjects: [NotesAccountID: any NotesScriptingAccount] = [:]
    private var folderObjects: [NotesFolderID: any NotesScriptingFolder] = [:]
    private var folderNames: [NotesFolderID: String] = [:]

    public init(timeout: TimeInterval = ScriptingBridgeNotesRunner.defaultTimeout) {
        self.init(timeout: timeout) { timeout in
            try ScriptingBridgeNotesApplication(
                bundleIdentifier: ScriptingBridgeNotesRunner.bundleIdentifier,
                timeout: timeout
            )
        }
    }

    /// The scripting application is injected so tests can stand in for Notes.
    init(timeout: TimeInterval = ScriptingBridgeNotesRunner.defaultTimeout, makeApplication: @escaping ApplicationFactory) {
        self.timeout = timeout
        self.makeApplication = makeApplication
    }

    // MARK: - Accounts

    public func accounts() async throws -> [NotesAccount] {
        if accounts.isEmpty {
            try loadAccounts()
        }
        return accounts
    }

    private func loadAccounts() throws {
        let application = try scriptingApplication()
        let scriptingAccounts = try mapped { try application.accounts() }
        var defaultAccountID: NotesAccountID?
        if let account = try? application.defaultAccount(), let identifier = try? account.identifier() {
            defaultAccountID = NotesAccountID(rawValue: identifier)
        }

        var loaded: [NotesAccount] = []
        for account in scriptingAccounts {
            let identifier = try mapped { try account.identifier() }
            guard !identifier.isEmpty else { continue }
            let id = NotesAccountID(rawValue: identifier)
            accountObjects[id] = account
            loaded.append(
                NotesAccount(id: id, name: try mapped { try account.name() }, isDefault: id == defaultAccountID)
            )
        }
        accounts = loaded
    }

    // MARK: - Folders

    public func folders(inAccounts accountIDs: [NotesAccountID]) async throws -> [NotesFolder] {
        if accounts.isEmpty {
            try loadAccounts()
        }
        let wanted = accountIDs.isEmpty ? accounts : accounts.filter { accountIDs.contains($0.id) }
        var loaded: [NotesFolder] = []
        for account in wanted {
            guard let object = accountObjects[account.id] else { continue }
            let scriptingFolders = try mapped { try object.folders() }
            var defaultFolderID: NotesFolderID?
            if let folder = try? object.defaultFolder(), let identifier = try? folder.identifier() {
                defaultFolderID = NotesFolderID(rawValue: identifier)
            }

            for folder in scriptingFolders {
                let identifier = try mapped { try folder.identifier() }
                guard !identifier.isEmpty else { continue }
                let id = NotesFolderID(rawValue: identifier)
                let name = try mapped { try folder.name() }
                folderObjects[id] = folder
                folderNames[id] = name
                loaded.append(
                    NotesFolder(
                        id: id,
                        accountID: account.id,
                        name: name,
                        isDefault: id == defaultFolderID,
                        noteCount: nil
                    )
                )
            }
        }
        return loaded
    }

    // MARK: - Notes

    public func noteSummaries(in folderID: NotesFolderID) async throws -> [NotesNoteSummary] {
        guard let folder = folderObjects[folderID] else {
            throw NotesClientError.folderNotFound(folderID)
        }
        var summaries: [NotesNoteSummary] = []
        for note in try mapped(folder: folderID, { try folder.notes() }) {
            let identifier = try mapped(folder: folderID, { try note.identifier() })
            guard !identifier.isEmpty else { continue }
            summaries.append(
                NotesNoteSummary(
                    id: NotesNoteID(rawValue: identifier),
                    folderID: folderID,
                    folderName: folderNames[folderID],
                    title: try mapped(folder: folderID, { try note.name() }),
                    modificationDate: try mapped(folder: folderID, { try note.modificationDate() }),
                    isProtected: try mapped(folder: folderID, { try note.isPasswordProtected() }),
                    isShared: try mapped(folder: folderID, { try note.isShared() })
                )
            )
        }
        return summaries
    }

    public func noteSummary(for note: NotesNoteLocation) async throws -> NotesNoteSummary {
        guard let object = try noteObject(for: note) else {
            throw NotesClientError.noteNotFound(note.id)
        }
        var folderID = note.folderID
        var folderName = note.folderID.flatMap { folderNames[$0] }
        if folderID == nil, let folder = try? object.containerFolder() {
            if let identifier = try? folder.identifier(), !identifier.isEmpty {
                let id = NotesFolderID(rawValue: identifier)
                folderID = id
                folderObjects[id] = folder
                folderName = try? folder.name()
                if let folderName {
                    folderNames[id] = folderName
                }
            }
        }

        return NotesNoteSummary(
            id: note.id,
            folderID: folderID,
            folderName: folderName,
            title: try mapped(note: note, { try object.name() }),
            modificationDate: try mapped(note: note, { try object.modificationDate() }),
            isProtected: try mapped(note: note, { try object.isPasswordProtected() }),
            isShared: try mapped(note: note, { try object.isShared() })
        )
    }

    public func noteContents(for notes: [NotesNoteLocation]) async throws -> [NotesNoteContent] {
        guard !notes.isEmpty else { return [] }
        var contents: [NotesNoteContent] = []
        var failure: NotesClientError?
        for note in notes {
            do {
                guard let object = try noteObject(for: note) else { continue }
                contents.append(
                    NotesNoteContent(
                        id: note.id,
                        plainText: try mapped(note: note, { try object.plainText() }),
                        bodyHTML: try mapped(note: note, { try object.body() })
                    )
                )
            } catch let error as NotesClientError {
                failure = failure ?? error
            }
        }
        if contents.isEmpty, let failure {
            throw failure
        }
        return contents
    }

    public func createNote(in folderID: NotesFolderID, body: String) async throws -> NotesNoteSummary {
        guard let folder = folderObjects[folderID] else {
            throw NotesClientError.folderNotFound(folderID)
        }
        do {
            let note = try folder.createNote(body: body)
            let identifier = try note.identifier()
            guard !identifier.isEmpty else {
                throw NotesClientError.commandFailed("Apple Notes created a note but did not return its identifier.")
            }
            return NotesNoteSummary(
                id: NotesNoteID(rawValue: identifier),
                folderID: folderID,
                folderName: folderNames[folderID],
                title: (try? note.name()) ?? "",
                modificationDate: try? note.modificationDate(),
                isProtected: false,
                isShared: false
            )
        } catch let error as NotesClientError {
            throw error
        } catch {
            throw Self.clientError(from: error, folder: folderID)
        }
    }

    public func setBody(_ body: String, for note: NotesNoteLocation) async throws {
        guard let object = try noteObject(for: note) else {
            throw NotesClientError.noteNotFound(note.id)
        }
        try mapped(note: note, folder: note.folderID, { try object.setBody(body) })
    }

    public func openNote(_ note: NotesNoteLocation) async throws {
        let application = try scriptingApplication()
        do {
            try application.openNoteLocation(note.id.rawValue)
        } catch {
            guard Self.shouldFallBackToShow(after: error) else {
                throw Self.clientError(from: error, note: note, folder: note.folderID)
            }
            do {
                guard let object = try noteObject(for: note) else {
                    throw NotesClientError.noteNotFound(note.id)
                }
                try object.show()
                application.activate()
            } catch let error as NotesClientError {
                throw error
            } catch {
                throw Self.clientError(from: error, note: note, folder: note.folderID)
            }
        }
    }

    public func reset() async {
        accounts = []
        accountObjects = [:]
        folderObjects = [:]
        folderNames = [:]
    }

    // MARK: - Scripting

    private func scriptingApplication() throws -> any NotesScriptingApplication {
        if let application {
            return application
        }
        do {
            let application = try makeApplication(timeout)
            self.application = application
            return application
        } catch let error as NotesClientError {
            throw error
        } catch {
            throw Self.clientError(from: error)
        }
    }

    /// The scripting object of a note: inside its folder when the caller knows one,
    /// from the application's own notes otherwise.
    private func noteObject(for note: NotesNoteLocation) throws -> (any NotesScriptingNote)? {
        if let folderID = note.folderID, let folder = folderObjects[folderID] {
            return try mapped(note: note, folder: folderID, { try folder.note(withID: note.id.rawValue) })
        }
        let application = try scriptingApplication()
        return try mapped(note: note, folder: note.folderID, { try application.note(withID: note.id.rawValue) })
    }

    private func mapped<T>(
        note: NotesNoteLocation? = nil,
        folder: NotesFolderID? = nil,
        _ call: () throws -> T
    ) throws -> T {
        do {
            return try call()
        } catch {
            throw Self.clientError(from: error, note: note, folder: folder)
        }
    }

    // MARK: - Failures

    /// The client's error for a failure reported by ScriptingBridge: a denial, a
    /// timeout, and a missing object are told apart by the Apple Event status.
    ///
    /// ScriptingBridge errors carry that status as their code in the `OSStatus`
    /// domain; `NSAppleEventDescriptor` reports the same errors as code 4099 of the
    /// Cocoa domain, and the delegate's error carries an `ErrorNumber` entry.
    static func clientError(
        from error: any Error,
        note: NotesNoteLocation? = nil,
        folder: NotesFolderID? = nil
    ) -> NotesClientError {
        let status = status(from: error)
        if status == AppleEventStatus.eventNotPermitted
            || status == AppleEventStatus.targetNotFound
            || status == AppleEventStatus.wouldRequireConsent {
            return .permissionDenied
        }
        if status == AppleEventStatus.timedOut {
            return .timedOut
        }
        if status == AppleEventStatus.noSuchObject {
            if let note { return .noteNotFound(note.id) }
            if let folder { return .folderNotFound(folder) }
        }
        if status == AppleEventStatus.userCanceled {
            return .commandFailed("Apple Notes cancelled the request.")
        }
        return .commandFailed((error as NSError).localizedDescription)
    }

    static func status(from error: any Error) -> OSStatus? {
        let error = error as NSError
        if error.domain == NSOSStatusErrorDomain {
            return OSStatus(error.code)
        }
        if error.domain == NSCocoaErrorDomain, error.code == 4099 {
            return AppleEventStatus.eventNotHandled
        }
        if let number = error.userInfo["ErrorNumber"] as? NSNumber {
            return OSStatus(number.int32Value)
        }
        return nil
    }

    /// A failure about the note location, rather than about permission or time, can be
    /// retried by asking Notes to show the note itself.
    static func shouldFallBackToShow(after error: any Error) -> Bool {
        guard let status = status(from: error) else { return true }
        return status != AppleEventStatus.eventNotPermitted
            && status != AppleEventStatus.targetNotFound
            && status != AppleEventStatus.wouldRequireConsent
            && status != AppleEventStatus.timedOut
    }
}
