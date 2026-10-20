import Foundation
import Testing

@testable import KopiCore

/// Indexing progress collected off the client's worker.
private final class ProgressLog: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [NotesIndexingProgress] = []

    func record(_ value: NotesIndexingProgress) {
        lock.withLock { values.append(value) }
    }

    var all: [NotesIndexingProgress] { lock.withLock { values } }
}

@Suite("Notes automation client")
struct NotesAutomationClientTests {
    @Test("An old body read cannot repopulate a disconnected Notes client")
    func disconnectInvalidatesInFlightRefresh() async throws {
        let runner = FakeNotesRunner.sample()
        let client = try await connectedClient(runner: runner)
        await runner.setContentReadDelay(.milliseconds(100), for: NotesFixtures.noteID(1))
        await runner.setSummary(NotesFixtures.summary(1, date: NotesFixtures.baseDate.addingTimeInterval(500)))
        let before = await runner.callCount("contents")
        let refresh = Task { try await client.refresh() }
        for _ in 0..<1000 {
            if await runner.callCount("contents") > before { break }
            await Task.yield()
        }
        #expect(await runner.callCount("contents") > before)
        await client.disconnect()
        do {
            _ = try await refresh.value
            Issue.record("The disconnected refresh unexpectedly completed")
        } catch { #expect(error as? NotesClientError == .notConnected) }
        #expect(await client.connectionState == .disconnected)
        _ = try await client.connect()
        #expect(await client.connectionState.isConnected)
    }

    @Test("Locking a previously indexed note removes its cached excerpt and searchable body")
    func newlyProtectedNotesForgetTheirBody() async throws {
        let runner = FakeNotesRunner(
            summaries: [NotesFixtures.folderID: [NotesFixtures.summary(1)]],
            contents: [NotesFixtures.noteID(1): NotesFixtures.content(1, text: "private-body-marker")]
        )
        let client = try await connectedClient(runner: runner)
        #expect(try await client.searchNotes("private-body-marker", in: [NotesFixtures.folderID]).count == 1)
        await runner.setSummary(NotesFixtures.summary(1, isProtected: true))
        _ = try await client.refresh()
        let metadata = try #require(await client.notes(in: NotesFixtures.folderID, page: NotesPage()).first)
        #expect(metadata.isProtected)
        #expect(metadata.excerpt.isEmpty)
        #expect(try await client.searchNotes("private-body-marker", in: [NotesFixtures.folderID]).isEmpty)
    }

    @Test("Full-body note search is Unicode aware and respects included folders")
    func fullBodySearchScope() async throws {
        let runner = FakeNotesRunner.sample()
        await runner.setContents([
            NotesFixtures.noteID(1): NotesFixtures.content(1, text: String(repeating: "context ", count: 80) + "CAFÉ"),
            NotesFixtures.noteID(2): NotesFixtures.content(2),
            NotesFixtures.noteID(3): NotesFixtures.content(3)
        ])
        let client = try await connectedClient(runner: runner)
        #expect(try await client.searchNotes("cafe", in: [NotesFixtures.folderID]).map(\.id) == [NotesFixtures.noteID(1)])
        #expect(try await client.searchNotes("cafe", in: [NotesFixtures.otherFolderID]).isEmpty)
    }
    private func connectedClient(
        runner: FakeNotesRunner,
        permission: FixedPermissionChecker = FixedPermissionChecker(.authorized),
        batchSize: Int = 20
    ) async throws -> NotesAutomationClient {
        let client = NotesAutomationClient(runner: runner, permission: permission, batchSize: batchSize)
        _ = try await client.connect()
        return client
    }

    @Test("Connecting moves from not connected to an indexed connection")
    func connectionTransitions() async throws {
        let runner = FakeNotesRunner.sample()
        let permission = FixedPermissionChecker(.authorized)
        let client = NotesAutomationClient(runner: runner, permission: permission)

        #expect(await client.connectionState == .disconnected)

        let accounts = try await client.connect()
        #expect(accounts.count == 1)
        #expect(permission.requestCount == 1)

        let state = await client.connectionState
        let progress = try #require(state.indexingProgress)
        #expect(state.isConnected)
        #expect(progress.isComplete)
        #expect(progress.totalNoteCount == 3)

        await client.disconnect()
        #expect(await client.connectionState == .disconnected)
    }

    @Test("A denied permission stops the connection before Notes is asked anything")
    func permissionDenied() async throws {
        let runner = FakeNotesRunner.sample()
        let permission = FixedPermissionChecker(.denied)
        let client = NotesAutomationClient(runner: runner, permission: permission)

        var thrown: (any Error)?
        do {
            _ = try await client.connect()
        } catch {
            thrown = error
        }

        #expect(thrown as? NotesClientError == .permissionDenied)
        #expect(await client.connectionState == .permissionDenied)
        #expect(await runner.calls.isEmpty)
    }

    @Test("An undetermined permission lets the first request decide")
    func undeterminedPermissionProceeds() async throws {
        let runner = FakeNotesRunner.sample()
        let client = NotesAutomationClient(runner: runner, permission: FixedPermissionChecker(.undetermined))
        _ = try await client.connect()
        #expect(await client.connectionState.isConnected)
    }

    @Test("A permission failure reported by Notes becomes the permission state")
    func permissionFailureFromNotes() async throws {
        let runner = FakeNotesRunner.sample()
        await runner.setFailure(.permissionDenied)
        let client = NotesAutomationClient(runner: runner, permission: FixedPermissionChecker(.authorized))

        var thrown: (any Error)?
        do {
            _ = try await client.connect()
        } catch {
            thrown = error
        }

        #expect((thrown as? NotesClientError)?.isPermissionFailure == true)
        #expect(await client.connectionState == .permissionDenied)
    }

    @Test("All folders are read initially, and an explicit folder selection restricts them")
    func folderSelection() async throws {
        let runner = FakeNotesRunner(
            summaries: [
                NotesFixtures.folderID: [NotesFixtures.summary(1)],
                NotesFixtures.otherFolderID: [NotesFixtures.summary(9, folderID: NotesFixtures.otherFolderID)]
            ],
            contents: [
                NotesFixtures.noteID(1): NotesFixtures.content(1),
                NotesFixtures.noteID(9): NotesFixtures.content(9)
            ]
        )
        let client = try await connectedClient(runner: runner)

        let folders = try await client.folders(inAccounts: nil)
        #expect(folders.count == 2)
        #expect(folders.first { $0.isDefault }?.id == NotesFixtures.folderID)

        var page = try await client.notes(in: NotesFixtures.folderID, page: NotesPage())
        #expect(page.map(\.id) == [NotesFixtures.noteID(1)])

        await client.setIncludedFolders([NotesFixtures.otherFolderID])
        _ = try await client.refresh()
        page = try await client.notes(in: NotesFixtures.otherFolderID, page: NotesPage())
        #expect(page.map(\.id) == [NotesFixtures.noteID(9)])

        let indexed = await runner.calls.filter { call in
            if case .summaries = call { return true }
            return false
        }
        #expect(indexed.count == 3)
    }

    @Test("Bodies are indexed in bounded batches while progress is published")
    func boundedBatchIndexing() async throws {
        let summaries = (1 ... 5).map { NotesFixtures.summary($0) }
        let contents = Dictionary(
            uniqueKeysWithValues: (1 ... 5).map { (NotesFixtures.noteID($0), NotesFixtures.content($0)) }
        )
        let runner = FakeNotesRunner(
            summaries: [NotesFixtures.folderID: summaries],
            contents: contents
        )
        let client = NotesAutomationClient(
            runner: runner,
            permission: FixedPermissionChecker(.authorized),
            batchSize: 2
        )

        let log = ProgressLog()
        _ = try await client.connect()
        let progress = try await client.refresh { log.record($0) }

        #expect(progress == NotesIndexingProgress(indexedNoteCount: 5, totalNoteCount: 5))

        let batches = await runner.calls.compactMap { call -> [NotesNoteID]? in
            if case .contents(let ids) = call { return ids }
            return nil
        }
        #expect(batches.map(\.count) == [2, 2, 1])
        #expect(batches.flatMap { $0 }.count == Set(batches.flatMap { $0 }).count)

        #expect(log.all.map(\.indexedNoteCount) == [0, 2, 4, 5])
        #expect(log.all.allSatisfy { $0.totalNoteCount == 5 })
    }

    @Test("Locked notes are listed without ever being read")
    func protectedNotesAreNotRead() async throws {
        let runner = FakeNotesRunner(
            summaries: [NotesFixtures.folderID: [
                NotesFixtures.summary(1),
                NotesFixtures.summary(2, isProtected: true)
            ]],
            contents: [NotesFixtures.noteID(1): NotesFixtures.content(1)]
        )
        let client = try await connectedClient(runner: runner)

        let readIDs = await runner.calls.compactMap { call -> [NotesNoteID]? in
            if case .contents(let ids) = call { return ids }
            return nil
        }.flatMap { $0 }
        #expect(readIDs == [NotesFixtures.noteID(1)])

        let page = try await client.notes(in: NotesFixtures.folderID, page: NotesPage())
        let locked = try #require(page.first { $0.id == NotesFixtures.noteID(2) })
        #expect(locked.isProtected)
        #expect(locked.requiresAppleNotes)
        #expect(locked.excerpt.isEmpty)
        #expect(await client.connectionState.indexingProgress?.isComplete == true)
    }

    @Test("Only notes that changed are read again")
    func incrementalIndexing() async throws {
        let runner = FakeNotesRunner.sample()
        let client = try await connectedClient(runner: runner)
        let firstPass = await runner.callCount("contents")

        _ = try await client.refresh()
        #expect(await runner.callCount("contents") == firstPass)

        await runner.setSummary(NotesFixtures.summary(2, date: NotesFixtures.baseDate.addingTimeInterval(300)))
        _ = try await client.refresh()

        #expect(await runner.callCount("contents") == firstPass + 1)
        let lastBatch = await runner.calls.compactMap { call -> [NotesNoteID]? in
            if case .contents(let ids) = call { return ids }
            return nil
        }.last
        #expect(lastBatch == [NotesFixtures.noteID(2)])
    }

    @Test("A note that cannot be read does not stop the pass")
    func unreadableNoteIsSkipped() async throws {
        let runner = FakeNotesRunner.sample()
        await runner.setUnreadable([NotesFixtures.noteID(2)])
        let client = NotesAutomationClient(runner: runner, permission: FixedPermissionChecker(.authorized), batchSize: 2)
        _ = try await client.connect()

        #expect(await client.connectionState.indexingProgress?.isComplete == true)
        let page = try await client.notes(in: NotesFixtures.folderID, page: NotesPage())
        let skipped = try #require(page.first { $0.id == NotesFixtures.noteID(2) })
        #expect(skipped.excerpt.isEmpty)
    }

    @Test("Search reads indexed note text")
    func indexedTextIsSearchable() async throws {
        let runner = FakeNotesRunner.sample()
        await runner.setContents([
            NotesFixtures.noteID(1): NotesFixtures.content(1, text: "Quarterly report for the harbour project"),
            NotesFixtures.noteID(2): NotesFixtures.content(2),
            NotesFixtures.noteID(3): NotesFixtures.content(3)
        ])
        let client = try await connectedClient(runner: runner)

        let page = try await client.notes(in: NotesFixtures.folderID, page: NotesPage())
        #expect(page.contains { $0.excerpt.contains("harbour") })
    }

    @Test("Notes are served in Notes' order, one page at a time")
    func pagingFollowsNotesOrder() async throws {
        let runner = FakeNotesRunner.sample()
        let client = try await connectedClient(runner: runner)

        let first = try await client.notes(in: NotesFixtures.folderID, page: NotesPage(offset: 0, limit: 2))
        let second = try await client.notes(in: NotesFixtures.folderID, page: NotesPage(offset: 2, limit: 2))

        #expect(first.map(\.id) == [NotesFixtures.noteID(1), NotesFixtures.noteID(2)])
        #expect(second.map(\.id) == [NotesFixtures.noteID(3)])
    }

    @Test("Open in Apple Notes routes the note's own identifier")
    func openInNotesRouting() async throws {
        let runner = FakeNotesRunner.sample()
        let client = try await connectedClient(runner: runner)
        try await client.openInNotes(id: NotesFixtures.noteID(2))

        let opened = await runner.calls.compactMap { call -> NotesNoteID? in
            if case .open(let id) = call { return id }
            return nil
        }
        #expect(opened == [NotesFixtures.noteID(2)])
    }

    @Test("Disconnecting clears the index and the next connect asks Notes again")
    func disconnectClearsTheIndex() async throws {
        let runner = FakeNotesRunner.sample()
        let permission = FixedPermissionChecker(.authorized)
        let client = try await connectedClient(runner: runner, permission: permission)

        await client.disconnect()
        var thrown: (any Error)?
        do {
            _ = try await client.notes(in: NotesFixtures.folderID, page: NotesPage())
        } catch {
            thrown = error
        }
        #expect(thrown as? NotesClientError == .notConnected)

        _ = try await client.connect()
        #expect(permission.requestCount == 2)
        #expect(await runner.calls.contains(.accounts))
        #expect(await runner.calls.contains(.reset))
    }

    @Test("Progress stops at the folder count when a folder is empty")
    func emptyFolderState() async throws {
        let runner = FakeNotesRunner(folders: [NotesFixtures.defaultFolder], summaries: [:], contents: [:])
        let client = NotesAutomationClient(runner: runner, permission: FixedPermissionChecker(.authorized))
        _ = try await client.connect()

        #expect(await client.connectionState == .empty)
    }

    @Test("A folder that no longer exists is reported as such")
    func unknownFolderIsReported() async throws {
        let runner = FakeNotesRunner.sample()
        let client = try await connectedClient(runner: runner)
        var thrown: (any Error)?
        do {
            _ = try await client.notes(in: NotesFolderID(rawValue: "missing-folder"), page: NotesPage())
        } catch {
            thrown = error
        }
        #expect(thrown as? NotesClientError == .folderNotFound(NotesFolderID(rawValue: "missing-folder")))
    }
}
