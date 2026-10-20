import Foundation
import Testing

@testable import CopilyCore

// MARK: - Fixtures

/// Values shaped like the ones Notes returns, so tests read like Notes does.
enum NotesFixtures {
    static let accountID = NotesAccountID(rawValue: "acct-1")
    static let folderID = NotesFolderID(rawValue: "x-coredata://ACCOUNT/ICFolder/p1")
    static let otherFolderID = NotesFolderID(rawValue: "x-coredata://ACCOUNT/ICFolder/p2")
    static let baseDate = Date(timeIntervalSince1970: 1_700_000_000)

    static let account = NotesAccount(id: accountID, name: "iCloud", isDefault: true)

    static var defaultFolder: NotesFolder {
        NotesFolder(id: folderID, accountID: accountID, name: "Notes", isDefault: true)
    }

    static var otherFolder: NotesFolder {
        NotesFolder(id: otherFolderID, accountID: accountID, name: "Work", isDefault: false)
    }

    static func noteID(_ index: Int) -> NotesNoteID {
        NotesNoteID(rawValue: "x-coredata://ACCOUNT/ICNote/p\(index)")
    }

    static func summary(
        _ index: Int,
        folderID: NotesFolderID = NotesFixtures.folderID,
        title: String? = nil,
        date: Date = baseDate,
        isProtected: Bool = false,
        isShared: Bool = false
    ) -> NotesNoteSummary {
        NotesNoteSummary(
            id: noteID(index),
            folderID: folderID,
            folderName: folderID == otherFolderID ? "Work" : "Notes",
            title: title ?? "Note \(index)",
            modificationDate: date,
            isProtected: isProtected,
            isShared: isShared
        )
    }

    static func content(
        _ index: Int,
        text: String? = nil,
        html: String? = nil
    ) -> NotesNoteContent {
        let body = text ?? "Body \(index)"
        return NotesNoteContent(
            id: noteID(index),
            plainText: body,
            bodyHTML: html ?? "<div>\(body)</div>"
        )
    }

    static func note(_ index: Int, text: String? = nil, folderID: NotesFolderID = folderID) -> NotesNote {
        let body = text ?? "Body \(index)"
        return NotesNote(
            metadata: NotesNoteMetadata(
                id: noteID(index),
                folderID: folderID,
                folderName: "Notes",
                title: "Note \(index)",
                excerpt: body,
                modificationDate: baseDate
            ),
            bodyHTML: "<div>\(body)</div>",
            plainText: body
        )
    }

    static let simpleHTML = "<!DOCTYPE html><html><head><meta charset=\"utf-8\"></head><body><div>Hello</div><div>World</div></body></html>"
}

// MARK: - Fake Notes runner

/// Permission answer a test chooses, with a count of how often Copily asked.
final class FixedPermissionChecker: NotesAutomationPermissionChecking, @unchecked Sendable {
    private let lock = NSLock()
    private var answer: NotesAutomationPermission
    private var requests = 0

    init(_ answer: NotesAutomationPermission = .authorized) {
        self.answer = answer
    }

    var requestCount: Int { lock.withLock { requests } }

    func setAnswer(_ value: NotesAutomationPermission) {
        lock.withLock { answer = value }
    }

    func requestAutomationPermission() async -> NotesAutomationPermission {
        lock.withLock {
            requests += 1
            return answer
        }
    }
}

/// Scripted Apple Notes: answers the runner protocol and records every call.
actor FakeNotesRunner: NotesAutomationRunning {
    enum Call: Equatable, Sendable {
        case accounts
        case folders
        case summaries(NotesFolderID)
        case contents([NotesNoteID])
        case summary(NotesNoteID)
        case create(NotesFolderID, String)
        case setBody(NotesNoteID, String)
        case open(NotesNoteID)
        case reset
    }

    private(set) var calls: [Call] = []
    private var accountList: [NotesAccount]
    private var folderList: [NotesFolder]
    private var summaries: [NotesFolderID: [NotesNoteSummary]]
    private var contents: [NotesNoteID: NotesNoteContent]
    private var unreadable: Set<NotesNoteID> = []
    private var contentReadDelays: [NotesNoteID: Duration] = [:]
    private var failure: NotesClientError?
    private var nextIdentifier = 100

    init(
        accounts: [NotesAccount] = [NotesFixtures.account],
        folders: [NotesFolder] = [NotesFixtures.defaultFolder, NotesFixtures.otherFolder],
        summaries: [NotesFolderID: [NotesNoteSummary]] = [:],
        contents: [NotesNoteID: NotesNoteContent] = [:]
    ) {
        self.accountList = accounts
        self.folderList = folders
        self.summaries = summaries
        self.contents = contents
    }

    /// One account, two folders and three plain notes, which is the shape most tests need.
    static func sample() -> FakeNotesRunner {
        FakeNotesRunner(
            summaries: [
                NotesFixtures.folderID: [
                    NotesFixtures.summary(1),
                    NotesFixtures.summary(2, date: NotesFixtures.baseDate.addingTimeInterval(60)),
                    NotesFixtures.summary(3)
                ]
            ],
            contents: [
                NotesFixtures.noteID(1): NotesFixtures.content(1),
                NotesFixtures.noteID(2): NotesFixtures.content(2),
                NotesFixtures.noteID(3): NotesFixtures.content(3)
            ]
        )
    }

    func debugSummaries() -> [NotesNoteSummary] {
        summaries.values.flatMap { $0 }
    }

    func contentsOf(_ noteID: NotesNoteID) -> NotesNoteContent? {
        contents[noteID]
    }

    func setFailure(_ error: NotesClientError?) {
        failure = error
    }

    /// Notes that cannot be read, the way a locked note cannot be.
    func setUnreadable(_ noteIDs: Set<NotesNoteID>) {
        unreadable = noteIDs
    }

    func setContentReadDelay(_ delay: Duration, for noteID: NotesNoteID) {
        contentReadDelays[noteID] = delay
    }

    func setContents(_ updated: [NotesNoteID: NotesNoteContent]) {
        contents = updated
    }

    func setSummaries(_ updated: [NotesFolderID: [NotesNoteSummary]]) {
        summaries = updated
    }

    func setSummary(_ summary: NotesNoteSummary) {
        contents[summary.id] = contents[summary.id] ?? NotesNoteContent(id: summary.id, plainText: "", bodyHTML: "")
        if let folderID = summary.folderID {
            var list = summaries[folderID] ?? []
            if let index = list.firstIndex(where: { $0.id == summary.id }) {
                list[index] = summary
            } else {
                list.append(summary)
            }
            summaries[folderID] = list
        }
    }

    func callCount(_ name: String) -> Int {
        calls.filter { call in
            switch (call, name) {
            case (.setBody, "setBody"), (.create, "create"), (.open, "open"), (.contents, "contents"),
                 (.summaries, "summaries"), (.summary, "summary"), (.reset, "reset"):
                true
            default:
                false
            }
        }.count
    }

    // MARK: NotesAutomationRunning

    func accounts() async throws -> [NotesAccount] {
        calls.append(.accounts)
        try fail()
        return accountList
    }

    func folders(inAccounts accountIDs: [NotesAccountID]) async throws -> [NotesFolder] {
        calls.append(.folders)
        try fail()
        guard !accountIDs.isEmpty else { return folderList }
        return folderList.filter { accountIDs.contains($0.accountID) }
    }

    func noteSummaries(in folderID: NotesFolderID) async throws -> [NotesNoteSummary] {
        calls.append(.summaries(folderID))
        try fail()
        guard let list = summaries[folderID] else { throw NotesClientError.folderNotFound(folderID) }
        return list
    }

    func noteContents(for notes: [NotesNoteLocation]) async throws -> [NotesNoteContent] {
        calls.append(.contents(notes.map(\.id)))
        for note in notes {
            if let delay = contentReadDelays[note.id] {
                try await Task.sleep(for: delay)
            }
        }
        try fail()
        return notes.compactMap { contents[$0.id] }.filter { !unreadable.contains($0.id) }
    }

    func noteSummary(for note: NotesNoteLocation) async throws -> NotesNoteSummary {
        calls.append(.summary(note.id))
        try fail()
        let all = summaries.values.flatMap { $0 }
        guard let summary = all.first(where: { $0.id == note.id }) else {
            throw NotesClientError.noteNotFound(note.id)
        }
        return summary
    }

    func createNote(in folderID: NotesFolderID, body: String) async throws -> NotesNoteSummary {
        calls.append(.create(folderID, body))
        try fail()
        nextIdentifier += 1
        let summary = NotesNoteSummary(
            id: NotesNoteID(rawValue: "x-coredata://ACCOUNT/ICNote/p\(nextIdentifier)"),
            folderID: folderID,
            folderName: folderID == NotesFixtures.otherFolderID ? "Work" : "Notes",
            title: NotesNoteText.excerpt(fromPlainText: body, limit: 60),
            modificationDate: NotesFixtures.baseDate.addingTimeInterval(600)
        )
        summaries[folderID, default: []].insert(summary, at: 0)
        contents[summary.id] = NotesNoteContent(id: summary.id, plainText: body, bodyHTML: "<div>\(body)</div>")
        return summary
    }

    func setBody(_ body: String, for note: NotesNoteLocation) async throws {
        calls.append(.setBody(note.id, body))
        try fail()
        contents[note.id] = NotesNoteContent(id: note.id, plainText: body, bodyHTML: "<div>\(body)</div>")
        for (folderID, list) in summaries where list.contains(where: { $0.id == note.id }) {
            summaries[folderID] = list.map { summary in
                guard summary.id == note.id else { return summary }
                return NotesNoteSummary(
                    id: summary.id,
                    folderID: summary.folderID,
                    folderName: summary.folderName,
                    title: NotesNoteText.excerpt(fromPlainText: body, limit: 60),
                    modificationDate: (summary.modificationDate ?? NotesFixtures.baseDate).addingTimeInterval(120),
                    isProtected: summary.isProtected,
                    isShared: summary.isShared
                )
            }
        }
    }

    func openNote(_ note: NotesNoteLocation) async throws {
        calls.append(.open(note.id))
        try fail()
    }

    func reset() async {
        calls.append(.reset)
    }

    private func fail() throws {
        if let failure { throw failure }
    }
}

// MARK: - Scripting fakes

/// Failures shaped the way ScriptingBridge's delegate reports them.
enum NotesScriptingFixtures {
    static func failure(_ status: OSStatus, message: String? = nil) -> NSError {
        NSError(
            domain: NSOSStatusErrorDomain,
            code: Int(status),
            userInfo: message.map { [NSLocalizedDescriptionKey: $0] }
        )
    }
}

/// Scripted Notes for the ScriptingBridge runner: the objects answer with the values a
/// test sets, record what the runner asked for, and throw the failure it scripts.
final class FakeNotesScriptingApplication: NotesScriptingApplication, @unchecked Sendable {
    enum Call: Equatable, Sendable {
        case openNoteLocation(String)
        case activate
    }

    var accountsResult: [FakeNotesScriptingAccount] = []
    var defaultAccountResult: FakeNotesScriptingAccount?
    var notesByID: [String: FakeNotesScriptingNote] = [:]
    var failure: NSError?
    var openNoteLocationFailure: NSError?

    private(set) var calls: [Call] = []
    private(set) var accountReads = 0
    var buildTimeouts: [TimeInterval] = []

    /// One account, one folder and three plain notes, which is the shape most tests need.
    static func sample() -> FakeNotesScriptingApplication {
        let application = FakeNotesScriptingApplication()
        let account = FakeNotesScriptingAccount()
        let folder = FakeNotesScriptingFolder()
        folder.notesResult = (1 ... 3).map { index in
            FakeNotesScriptingNote(
                id: NotesFixtures.noteID(index).rawValue,
                title: "Note \(index)",
                plainText: "Body \(index)",
                bodyHTML: "<div>Body \(index)</div>",
                date: index == 2 ? NotesFixtures.baseDate.addingTimeInterval(60) : NotesFixtures.baseDate
            )
        }
        account.foldersResult = [folder]
        account.defaultFolderResult = folder
        application.accountsResult = [account]
        application.defaultAccountResult = account
        for note in folder.notesResult {
            application.notesByID[note.idValue] = note
            note.containerResult = folder
        }
        return application
    }

    func accounts() throws -> [any NotesScriptingAccount] {
        accountReads += 1
        try fail()
        return accountsResult
    }

    func defaultAccount() throws -> (any NotesScriptingAccount)? {
        try fail()
        return defaultAccountResult
    }

    func note(withID id: String) throws -> (any NotesScriptingNote)? {
        try fail()
        return notesByID[id]
    }

    func openNoteLocation(_ location: String) throws {
        calls.append(.openNoteLocation(location))
        if let openNoteLocationFailure {
            throw openNoteLocationFailure
        }
        try fail()
    }

    func activate() {
        calls.append(.activate)
    }

    private func fail() throws {
        if let failure { throw failure }
    }
}

final class FakeNotesScriptingAccount: NotesScriptingAccount, @unchecked Sendable {
    var idValue: String
    var nameValue: String
    var foldersResult: [FakeNotesScriptingFolder] = []
    var defaultFolderResult: FakeNotesScriptingFolder?
    var failure: NSError?

    init(id: String = NotesFixtures.accountID.rawValue, name: String = "iCloud") {
        self.idValue = id
        self.nameValue = name
    }

    func identifier() throws -> String {
        try fail()
        return idValue
    }

    func name() throws -> String {
        try fail()
        return nameValue
    }

    func folders() throws -> [any NotesScriptingFolder] {
        try fail()
        return foldersResult
    }

    func defaultFolder() throws -> (any NotesScriptingFolder)? {
        try fail()
        return defaultFolderResult
    }

    private func fail() throws {
        if let failure { throw failure }
    }
}

final class FakeNotesScriptingFolder: NotesScriptingFolder, @unchecked Sendable {
    var idValue: String
    var nameValue: String
    var notesResult: [FakeNotesScriptingNote] = []
    var failure: NSError?
    private(set) var createdNoteBodies: [String] = []

    init(id: String = NotesFixtures.folderID.rawValue, name: String = "Notes") {
        self.idValue = id
        self.nameValue = name
    }

    func identifier() throws -> String {
        try fail()
        return idValue
    }

    func name() throws -> String {
        try fail()
        return nameValue
    }

    func note(withID id: String) throws -> (any NotesScriptingNote)? {
        try fail()
        return notesResult.first { $0.idValue == id }
    }

    func notes() throws -> [any NotesScriptingNote] {
        try fail()
        return notesResult
    }

    func createNote(body: String) throws -> any NotesScriptingNote {
        try fail()
        createdNoteBodies.append(body)
        let note = FakeNotesScriptingNote(
            id: "x-coredata://ACCOUNT/ICNote/created-\(createdNoteBodies.count)",
            title: "Created note",
            plainText: body,
            bodyHTML: "<div>\(body)</div>",
            date: NotesFixtures.baseDate
        )
        note.containerResult = self
        notesResult.insert(note, at: 0)
        return note
    }

    private func fail() throws {
        if let failure { throw failure }
    }
}

final class FakeNotesScriptingNote: NotesScriptingNote, @unchecked Sendable {
    enum Call: Equatable, Sendable {
        case setBody(String)
        case show
    }

    var idValue: String
    var nameValue: String
    var plainTextValue: String
    var bodyHTMLValue: String
    var dateValue: Date?
    var isProtectedValue: Bool
    var isSharedValue: Bool
    var containerResult: FakeNotesScriptingFolder?
    var failure: NSError?
    private(set) var calls: [Call] = []

    init(
        id: String,
        title: String = "",
        plainText: String = "",
        bodyHTML: String = "",
        date: Date? = nil,
        isProtected: Bool = false,
        isShared: Bool = false,
        failure: NSError? = nil
    ) {
        self.idValue = id
        self.nameValue = title
        self.plainTextValue = plainText
        self.bodyHTMLValue = bodyHTML
        self.dateValue = date
        self.isProtectedValue = isProtected
        self.isSharedValue = isShared
        self.failure = failure
    }

    func identifier() throws -> String {
        try fail()
        return idValue
    }

    func name() throws -> String {
        try fail()
        return nameValue
    }

    func body() throws -> String {
        try fail()
        return bodyHTMLValue
    }

    func plainText() throws -> String {
        try fail()
        return plainTextValue
    }

    func modificationDate() throws -> Date? {
        try fail()
        return dateValue
    }

    func isPasswordProtected() throws -> Bool {
        try fail()
        return isProtectedValue
    }

    func isShared() throws -> Bool {
        try fail()
        return isSharedValue
    }

    func containerFolder() throws -> (any NotesScriptingFolder)? {
        try fail()
        return containerResult
    }

    func setBody(_ body: String) throws {
        try fail()
        calls.append(.setBody(body))
        bodyHTMLValue = body
        plainTextValue = body
    }

    func show() throws {
        try fail()
        calls.append(.show)
    }

    private func fail() throws {
        if let failure { throw failure }
    }
}
