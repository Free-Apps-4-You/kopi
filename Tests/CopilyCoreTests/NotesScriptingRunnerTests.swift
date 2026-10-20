import CoreServices
import Foundation
import Testing

@testable import CopilyCore

@Suite("ScriptingBridge runner")
struct ScriptingBridgeNotesRunnerTests {
    private func makeRunner(
        _ application: FakeNotesScriptingApplication,
        timeout: TimeInterval = ScriptingBridgeNotesRunner.defaultTimeout
    ) -> ScriptingBridgeNotesRunner {
        ScriptingBridgeNotesRunner(timeout: timeout) { requested in
            application.buildTimeouts.append(requested)
            return application
        }
    }

    @Test("Accounts and folders are read with their identifiers and defaults")
    func readsAccountsAndFolders() async throws {
        let application = FakeNotesScriptingApplication.sample()
        let runner = makeRunner(application)

        let accounts = try await runner.accounts()
        #expect(accounts == [NotesAccount(id: NotesFixtures.accountID, name: "iCloud", isDefault: true)])

        let folders = try await runner.folders(inAccounts: [NotesFixtures.accountID])
        #expect(folders == [
            NotesFolder(id: NotesFixtures.folderID, accountID: NotesFixtures.accountID, name: "Notes", isDefault: true)
        ])
    }

    @Test("Accounts are read once, and again after a reset")
    func cachesAccountsUntilReset() async throws {
        let application = FakeNotesScriptingApplication.sample()
        let runner = makeRunner(application)

        _ = try await runner.accounts()
        _ = try await runner.accounts()
        #expect(application.accountReads == 1)

        await runner.reset()
        _ = try await runner.accounts()
        #expect(application.accountReads == 2)
    }

    @Test("Note metadata is read for the whole folder")
    func readsNoteSummaries() async throws {
        let application = FakeNotesScriptingApplication.sample()
        let runner = makeRunner(application)
        _ = try await runner.folders(inAccounts: [NotesFixtures.accountID])

        let summaries = try await runner.noteSummaries(in: NotesFixtures.folderID)
        #expect(summaries.map(\.title) == ["Note 1", "Note 2", "Note 3"])
        #expect(summaries.map(\.id) == (1 ... 3).map(NotesFixtures.noteID))
        #expect(summaries[0].modificationDate == NotesFixtures.baseDate)
        #expect(summaries[1].modificationDate == NotesFixtures.baseDate.addingTimeInterval(60))
        #expect(summaries[0].folderName == "Notes")
    }

    @Test("Notes without an identifier are skipped")
    func skipsUnidentifiedNotes() async throws {
        let application = FakeNotesScriptingApplication.sample()
        let folder = application.accountsResult[0].foldersResult[0]
        folder.notesResult.append(FakeNotesScriptingNote(id: "", title: "Untitled"))
        let runner = makeRunner(application)
        _ = try await runner.folders(inAccounts: [NotesFixtures.accountID])

        let summaries = try await runner.noteSummaries(in: NotesFixtures.folderID)
        #expect(summaries.count == 3)
    }

    @Test("A folder Copily has not read is reported as missing")
    func reportsUnknownFolder() async throws {
        let application = FakeNotesScriptingApplication.sample()
        let runner = makeRunner(application)

        var thrown: (any Error)?
        do {
            _ = try await runner.noteSummaries(in: NotesFixtures.otherFolderID)
        } catch {
            thrown = error
        }
        #expect(thrown as? NotesClientError == .folderNotFound(NotesFixtures.otherFolderID))
    }

    @Test("A batch of bodies is read one note at a time")
    func readsBodies() async throws {
        let application = FakeNotesScriptingApplication.sample()
        let runner = makeRunner(application)
        _ = try await runner.folders(inAccounts: [NotesFixtures.accountID])

        let contents = try await runner.noteContents(for: [
            NotesNoteLocation(id: NotesFixtures.noteID(1), folderID: NotesFixtures.folderID),
            NotesNoteLocation(id: NotesFixtures.noteID(2), folderID: NotesFixtures.folderID)
        ])
        #expect(contents == [NotesFixtures.content(1), NotesFixtures.content(2)])
    }

    @Test("A note that cannot be read does not take the batch down")
    func skipsUnreadableNotes() async throws {
        let application = FakeNotesScriptingApplication.sample()
        application.notesByID[NotesFixtures.noteID(2).rawValue]?.failure = NotesScriptingFixtures.failure(AppleEventStatus.noSuchObject)
        let runner = makeRunner(application)
        _ = try await runner.folders(inAccounts: [NotesFixtures.accountID])

        let contents = try await runner.noteContents(for: (1 ... 3).map {
            NotesNoteLocation(id: NotesFixtures.noteID($0), folderID: NotesFixtures.folderID)
        })
        #expect(contents.map(\.id) == [NotesFixtures.noteID(1), NotesFixtures.noteID(3)])
    }

    @Test("A batch whose every note fails reports the failure")
    func reportsFailureWhenNothingIsReadable() async throws {
        let application = FakeNotesScriptingApplication.sample()
        application.notesByID[NotesFixtures.noteID(1).rawValue]?.failure = NotesScriptingFixtures.failure(AppleEventStatus.noSuchObject)
        let runner = makeRunner(application)

        var thrown: (any Error)?
        do {
            _ = try await runner.noteContents(for: [
                NotesNoteLocation(id: NotesFixtures.noteID(1), folderID: NotesFixtures.folderID)
            ])
        } catch {
            thrown = error
        }
        #expect(thrown as? NotesClientError == .noteNotFound(NotesFixtures.noteID(1)))
    }

    @Test("Creating a note adds it to the folder with its body")
    func createsNote() async throws {
        let application = FakeNotesScriptingApplication.sample()
        let folder = application.accountsResult[0].foldersResult[0]
        let runner = makeRunner(application)
        _ = try await runner.folders(inAccounts: [NotesFixtures.accountID])

        let created = try await runner.createNote(in: NotesFixtures.folderID, body: "Title\n\nBody")

        #expect(folder.createdNoteBodies == ["Title\n\nBody"])
        #expect(created.folderID == NotesFixtures.folderID)
        #expect(created.folderName == "Notes")
        #expect(created.title == "Created note")
        #expect(created.modificationDate == NotesFixtures.baseDate)
    }

    @Test("Saving a note sets its body")
    func savesBody() async throws {
        let application = FakeNotesScriptingApplication.sample()
        let note = try #require(application.notesByID[NotesFixtures.noteID(1).rawValue])
        let runner = makeRunner(application)

        try await runner.setBody(
            "Title\n\nBody",
            for: NotesNoteLocation(id: NotesFixtures.noteID(1), folderID: NotesFixtures.folderID)
        )

        #expect(note.plainTextValue == "Title\n\nBody")
        #expect(note.bodyHTMLValue == "Title\n\nBody")
        #expect(note.calls == [.setBody("Title\n\nBody")])
    }

    @Test("Opening a note uses its identifier as the note location")
    func opensNoteByLocation() async throws {
        let application = FakeNotesScriptingApplication.sample()
        let runner = makeRunner(application)

        try await runner.openNote(NotesNoteLocation(id: NotesFixtures.noteID(1), folderID: NotesFixtures.folderID))

        #expect(application.calls == [.openNoteLocation(NotesFixtures.noteID(1).rawValue)])
    }

    @Test("Opening falls back to showing the note when Notes refuses the location")
    func fallsBackToShow() async throws {
        let application = FakeNotesScriptingApplication.sample()
        let note = try #require(application.notesByID[NotesFixtures.noteID(1).rawValue])
        application.openNoteLocationFailure = NotesScriptingFixtures.failure(AppleEventStatus.eventNotHandled, message: "no handler")
        let runner = makeRunner(application)

        try await runner.openNote(NotesNoteLocation(id: NotesFixtures.noteID(1), folderID: NotesFixtures.folderID))

        #expect(application.calls == [
            .openNoteLocation(NotesFixtures.noteID(1).rawValue),
            .activate
        ])
        #expect(note.calls == [.show])
    }

    @Test("A denied open is never retried as a show")
    func deniedOpenDoesNotFallBack() async throws {
        let application = FakeNotesScriptingApplication.sample()
        application.openNoteLocationFailure = NotesScriptingFixtures.failure(AppleEventStatus.eventNotPermitted)
        let runner = makeRunner(application)

        var thrown: (any Error)?
        do {
            try await runner.openNote(NotesNoteLocation(id: NotesFixtures.noteID(1), folderID: NotesFixtures.folderID))
        } catch {
            thrown = error
        }

        #expect(thrown as? NotesClientError == .permissionDenied)
        #expect(application.calls == [.openNoteLocation(NotesFixtures.noteID(1).rawValue)])
    }

    @Test("The scripting application is built once, with the runner's timeout")
    func usesFiniteTimeouts() async throws {
        let application = FakeNotesScriptingApplication.sample()
        let runner = makeRunner(application, timeout: 12)

        _ = try await runner.accounts()
        _ = try await runner.folders(inAccounts: [NotesFixtures.accountID])
        _ = try await runner.noteSummaries(in: NotesFixtures.folderID)

        #expect(application.buildTimeouts == [12])
    }

    @Test("Notes failures become the client's failures")
    func mapsFailures() async throws {
        func failure(_ status: OSStatus) async -> NotesClientError? {
            let application = FakeNotesScriptingApplication()
            application.failure = NotesScriptingFixtures.failure(status)
            let runner = ScriptingBridgeNotesRunner(makeApplication: { _ in application })
            do {
                _ = try await runner.accounts()
                return nil
            } catch let error as NotesClientError {
                return error
            } catch {
                return nil
            }
        }

        #expect(await failure(AppleEventStatus.eventNotPermitted) == .permissionDenied)
        #expect(await failure(AppleEventStatus.targetNotFound) == .permissionDenied)
        #expect(await failure(AppleEventStatus.timedOut) == .timedOut)
        #expect(await failure(AppleEventStatus.eventNotHandled) != nil)
    }

    @Test("A ScriptingBridge failure number is read from the error's user info")
    func mapsFailureNumbers() {
        let error = NSError(
            domain: "com.apple.ScriptingBridge",
            code: 1,
            userInfo: ["ErrorNumber": NSNumber(value: AppleEventStatus.eventNotPermitted)]
        )
        #expect(ScriptingBridgeNotesRunner.clientError(from: error) == .permissionDenied)
    }

    @Test("A note Notes refuses to describe is reported as missing")
    func reportsMissingNote() async throws {
        let application = FakeNotesScriptingApplication.sample()
        application.notesByID[NotesFixtures.noteID(1).rawValue]?.failure = NotesScriptingFixtures.failure(AppleEventStatus.noSuchObject)
        let runner = makeRunner(application)

        var thrown: (any Error)?
        do {
            _ = try await runner.noteSummary(for: NotesNoteLocation(id: NotesFixtures.noteID(1), folderID: NotesFixtures.folderID))
        } catch {
            thrown = error
        }
        #expect(thrown as? NotesClientError == .noteNotFound(NotesFixtures.noteID(1)))
    }

    @Test("A note that no longer exists is reported as missing")
    func reportsUnknownNote() async throws {
        let application = FakeNotesScriptingApplication.sample()
        let runner = makeRunner(application)

        var thrown: (any Error)?
        do {
            _ = try await runner.noteSummary(for: NotesNoteLocation(id: NotesFixtures.noteID(9), folderID: NotesFixtures.folderID))
        } catch {
            thrown = error
        }
        #expect(thrown as? NotesClientError == .noteNotFound(NotesFixtures.noteID(9)))
    }

    @Test("A note's folder is resolved when the caller does not know it")
    func resolvesFolderFromContainer() async throws {
        let application = FakeNotesScriptingApplication.sample()
        let runner = makeRunner(application)

        let summary = try await runner.noteSummary(for: NotesNoteLocation(id: NotesFixtures.noteID(1)))

        #expect(summary.folderID == NotesFixtures.folderID)
        #expect(summary.folderName == "Notes")
        #expect(summary.modificationDate == NotesFixtures.baseDate)
    }
}
