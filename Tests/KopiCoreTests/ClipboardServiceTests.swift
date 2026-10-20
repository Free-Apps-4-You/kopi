import Foundation
import Testing

@testable import KopiCore

@Suite("Clipboard capture")
struct ClipboardServiceTests {
    @Test("An unchanged clipboard is never read")
    func unchangedClipboard() async throws {
        let harness = try await CaptureHarness()
        await harness.service.start()

        let first = await harness.service.tick()
        #expect(first == .unchanged(changeCount: 0))
        #expect(harness.pasteboard.snapshotReadCount == 0)
        var count = try await harness.workspace.store.count()
        #expect(count == 0)

        harness.pasteboard.copyText("fresh copy")
        let captured = await harness.service.tick()
        #expect(captured.insertionResult?.didCreateItem == true)

        let repeated = await harness.service.tick()
        #expect(repeated == .unchanged(changeCount: 1))
        #expect(harness.pasteboard.snapshotReadCount == 1)
        count = try await harness.workspace.store.count()
        #expect(count == 1)
    }

    @Test("An external text copy becomes one card")
    func externalTextCopy() async throws {
        let harness = try await CaptureHarness()
        let textEdit = SourceAppInfo(bundleIdentifier: "com.apple.TextEdit", name: "TextEdit", processIdentifier: 501)
        harness.frontmostApp.current = textEdit
        await harness.service.start()
        harness.pasteboard.copyText("copied from TextEdit")

        let outcome = await harness.service.tick()

        let insertion = try #require(outcome.insertion)
        #expect(insertion.origin == .external(changeCount: 1))
        #expect(insertion.sourceApp == textEdit)
        #expect(insertion.kind == .text)
        #expect(harness.frontmostApp.lookupCount == 1)
        let summary = try #require(outcome.summary)
        #expect(summary.kind == .text)
        #expect(summary.excerpt == "copied from TextEdit")
        #expect(summary.sourceApp?.displayName == "TextEdit")
        #expect(summary.sourceApp?.processIdentifier == 501)
        #expect(harness.pasteboard.snapshotReadCount == 1)
        let statistics = try await harness.workspace.store.statistics()
        #expect(statistics.itemCount == 1)
    }

    @Test("Recopying identical content collapses and extends the retention clock")
    func recopyingIdenticalContent() async throws {
        let harness = try await CaptureHarness()
        await harness.service.start()
        let first = Date()
        harness.pasteboard.copyText("the same text twice")
        let inserted = await harness.service.tick(now: first)
        let itemID = try #require(inserted.summary?.id)

        let later = first.addingTimeInterval(3600)
        harness.pasteboard.copyText("the same text twice")
        let repeated = await harness.service.tick(now: later)

        #expect(repeated.insertionResult?.didCreateItem == false)
        #expect(repeated.summary?.id == itemID)
        let stored = try #require(await harness.workspace.store.summary(for: itemID))
        #expect(stored.createdAt == first)
        #expect(stored.lastCopiedAt == later)
        let statistics = try await harness.workspace.store.statistics()
        #expect(statistics.itemCount == 1)
    }

    @Test("Kopi's own copy is not captured and does not hide the next external copy")
    func ownCopySuppression() async throws {
        let harness = try await CaptureHarness()
        await harness.service.start()
        harness.pasteboard.copyText("copied by the user")
        let captured = await harness.service.tick()
        let itemID = try #require(captured.summary?.id)

        let ownCopy = try await harness.service.copyToPasteboard(itemID)
        let expected = OwnCopyState(itemID: itemID, changeCount: harness.pasteboard.changeCount)
        #expect(ownCopy == expected)
        #expect(harness.pasteboard.writeRequests.first?.flavours == [flavour(.plainText, "copied by the user")])

        let duplicate = await harness.service.tick()
        #expect(duplicate == .ownCopy(itemID: itemID, changeCount: ownCopy.changeCount))
        let recorded = try #require(await harness.workspace.store.ownCopyState())
        #expect(recorded == ownCopy)
        var statistics = try await harness.workspace.store.statistics()
        #expect(statistics.itemCount == 1)

        harness.pasteboard.copyText("an external copy afterwards")
        let external = await harness.service.tick()
        #expect(external.insertionResult?.didCreateItem == true)
        statistics = try await harness.workspace.store.statistics()
        #expect(statistics.itemCount == 2)
    }

    @Test("A generation recorded by an earlier run does not swallow a copy")
    func staleOwnCopyGeneration() async throws {
        let harness = try await CaptureHarness()
        let previousRun = ClipboardItemID()
        try await harness.workspace.store.recordOwnCopy(OwnCopyState(itemID: previousRun, changeCount: 1))

        await harness.service.start()
        harness.pasteboard.copyText("copied after a relaunch")

        let outcome = await harness.service.tick()

        #expect(outcome.insertionResult?.didCreateItem == true)
        #expect(outcome.summary?.excerpt == "copied after a relaunch")
    }

    @Test("A snapshot the clipboard changes during is rejected, and the next tick retries")
    func rejectedSnapshot() async throws {
        let harness = try await CaptureHarness()
        await harness.service.start()
        harness.pasteboard.copyText("first copy")
        harness.pasteboard.changeDuringNextRead(to: [textItem("second copy")])

        let rejected = await harness.service.tick()
        #expect(rejected == .rejectedSnapshot(changeCount: 2))
        var statistics = try await harness.workspace.store.statistics()
        #expect(statistics.itemCount == 0)

        let retried = await harness.service.tick()
        #expect(retried.summary?.excerpt == "second copy")
        #expect(retried.insertion?.origin == .external(changeCount: 2))
        statistics = try await harness.workspace.store.statistics()
        #expect(statistics.itemCount == 1)
        #expect(harness.pasteboard.snapshotReadCount == 2)
    }

    @Test("Paused capture ignores changes and resumes with the latest content")
    func pausedCapture() async throws {
        let harness = try await CaptureHarness()
        await harness.service.start()
        await harness.service.setCapturePaused(true)

        let pausedState = await harness.service.state
        #expect(pausedState == .paused(.captureDisabled))
        #expect(harness.ticker.isActive == false)

        harness.pasteboard.copyText("copy while paused")
        harness.pasteboard.copyText("second copy while paused")

        let paused = await harness.service.tick()
        #expect(paused == .paused(.captureDisabled))
        #expect(harness.pasteboard.snapshotReadCount == 0)
        var count = try await harness.workspace.store.count()
        #expect(count == 0)

        await harness.service.setCapturePaused(false)
        let resumedState = await harness.service.state
        #expect(resumedState == .running)
        #expect(harness.ticker.scheduleCount == 2)
        #expect(await harness.ticker.fire())

        let captured = await harness.service.lastOutcome
        #expect(captured?.summary?.excerpt == "second copy while paused")
        count = try await harness.workspace.store.count()
        #expect(count == 1)
    }

    @Test("Sleep stops the loop and wake resumes it")
    func sleepAndWake() async throws {
        let harness = try await CaptureHarness()
        await harness.service.start()
        #expect(harness.ticker.scheduleCount == 1)

        await harness.lifecycle.emit(.willSleep)
        let sleeping = await harness.service.state
        #expect(sleeping == .paused(.systemSleep))
        #expect(harness.ticker.isActive == false)

        harness.pasteboard.copyText("copied while asleep")
        #expect(await harness.ticker.fire() == false)
        let suspended = await harness.service.tick()
        #expect(suspended == .paused(.systemSleep))
        #expect(harness.pasteboard.snapshotReadCount == 0)

        await harness.lifecycle.emit(.didWake)
        let awake = await harness.service.state
        #expect(awake == .running)
        #expect(harness.ticker.scheduleCount == 2)
        #expect(await harness.ticker.fire())
        let statistics = try await harness.workspace.store.statistics()
        #expect(statistics.itemCount == 1)
    }

    @Test("Stopping releases the tick and the sleep observation")
    func stopping() async throws {
        let harness = try await CaptureHarness()
        await harness.service.start()
        #expect(harness.lifecycle.isObserving)
        #expect(harness.ticker.isActive)

        await harness.service.stop()

        #expect(harness.lifecycle.isObserving == false)
        #expect(harness.ticker.isActive == false)
        let state = await harness.service.state
        #expect(state == .idle)
        let outcome = await harness.service.tick()
        #expect(outcome == .idle)
    }

    @Test("Excluded applications are not captured")
    func excludedApplication() async throws {
        let harness = try await CaptureHarness(
            excludedApplications: ExcludedApplications(bundleIdentifiers: ["COM.APPLE.PASSWORDS"])
        )
        harness.frontmostApp.current = SourceAppInfo(bundleIdentifier: "com.apple.Passwords", name: "Passwords")
        await harness.service.start()
        harness.pasteboard.copyText("secret from the password manager")

        let outcome = await harness.service.tick()

        #expect(outcome == .excludedApp(changeCount: 1))
        #expect(harness.pasteboard.snapshotReadCount == 0)
        var statistics = try await harness.workspace.store.statistics()
        #expect(statistics.itemCount == 0)

        // An application that is not on the list is captured as usual.
        harness.frontmostApp.current = SourceAppInfo(bundleIdentifier: "com.apple.Safari", name: "Safari")
        harness.pasteboard.copyText("public content")
        let captured = await harness.service.tick()
        #expect(captured.insertionResult?.didCreateItem == true)
        statistics = try await harness.workspace.store.statistics()
        #expect(statistics.itemCount == 1)
    }

    @Test("Denied pasteboard access blocks capture instead of retrying")
    func deniedAccess() async throws {
        let harness = try await CaptureHarness()
        await harness.service.start()
        harness.pasteboard.failReads(with: PasteboardAccessError.accessDenied)
        harness.pasteboard.copyText("denied content")

        let blocked = await harness.service.tick()
        #expect(blocked == .blocked(.pasteboardAccessDenied))
        let state = await harness.service.state
        #expect(state == .blocked(.pasteboardAccessDenied))
        #expect(harness.pasteboard.snapshotReadCount == 1)
        #expect(harness.ticker.isActive == false)

        harness.pasteboard.copyText("denied content again")
        let stillBlocked = await harness.service.tick()
        #expect(stillBlocked == .blocked(.pasteboardAccessDenied))
        #expect(harness.pasteboard.snapshotReadCount == 1)
        let statistics = try await harness.workspace.store.statistics()
        #expect(statistics.itemCount == 0)

        harness.pasteboard.allowReads()
        await harness.service.clearAccessBlock()
        let cleared = await harness.service.state
        #expect(cleared == .running)
        let captured = await harness.service.tick()
        #expect(captured.summary?.excerpt == "denied content again")
    }

    @Test("A card is written back with the flavours it was stored with")
    func writingACard() async throws {
        let harness = try await CaptureHarness()
        let file = try harness.workspace.writeFile("kept.txt", contents: "kept")
        let inserted = try await harness.workspace.store.insert(
            fileInsertion([file], origin: .external(changeCount: 3))
        )

        _ = try await harness.service.copyToPasteboard(inserted.itemID)

        let request = try #require(harness.pasteboard.writeRequests.first)
        #expect(request.items.count == 1)
        #expect(request.flavours.map(\.type) == [ClipboardRepresentationKind.fileURL.pasteboardType])
        #expect(request.flavours.first?.string == file.absoluteString)
    }

    @Test("The loop polls at 250 ms by default, or at the interval it is given")
    func pollInterval() async throws {
        let standard = try await CaptureHarness()
        await standard.service.start()
        #expect(standard.ticker.scheduledIntervals == [ClipboardService.defaultPollInterval])
        #expect(ClipboardService.defaultPollInterval == .milliseconds(250))

        let fast = try await CaptureHarness(pollInterval: .milliseconds(50))
        await fast.service.start()
        #expect(fast.ticker.scheduledIntervals == [.milliseconds(50)])
    }

    @Test("The production ticker polls until it is cancelled")
    func taskTicker() async throws {
        let ticker = TaskCaptureTicker()
        let counter = TickCounter()
        let handle = await ticker.schedule(every: .milliseconds(5)) {
            await counter.increment()
        }
        await counter.waitForTick()
        handle.cancel()

        let atCancel = await counter.value
        #expect(atCancel > 0)
        try await Task.sleep(for: .milliseconds(60))
        let afterCancel = await counter.value
        #expect(afterCancel - atCancel <= 1)
    }

    @MainActor
    @Test("The capture state is published to the main-actor mirror")
    func statusMirror() async throws {
        let harness = try await CaptureHarness()
        #expect(harness.status.state == .idle)
        #expect(harness.status.revision == 0)

        await harness.service.start()
        #expect(harness.status.state == .running)
        #expect(harness.status.revision == 1)

        await harness.service.setCapturePaused(true)
        #expect(harness.status.state == .paused(.captureDisabled))
        #expect(harness.status.state.displayName == "Capture paused")

        await harness.lifecycle.emit(.willSleep)
        #expect(harness.status.state == .paused(.systemSleep))

        await harness.lifecycle.emit(.didWake)
        #expect(harness.status.state == .paused(.captureDisabled))

        await harness.service.stop()
        #expect(harness.status.state == .idle)
    }

    @MainActor
    @Test("Every captured tick publishes the capture signal to the main-actor mirror")
    func captureSignalMirror() async throws {
        let harness = try await CaptureHarness()
        await harness.service.start()
        #expect(harness.status.latestCapture == nil)

        let first = Date()
        harness.pasteboard.copyText("the newest card")
        let outcome = await harness.service.tick(now: first)
        let signal = try #require(harness.status.latestCapture)
        #expect(signal.summary.id == outcome.summary?.id)
        #expect(signal.summary.excerpt == "the newest card")
        #expect(signal.timestamp == first)
        // The state itself did not move; the signal is what wakes the panel.
        #expect(harness.status.state == .running)
        #expect(harness.status.revision == 1)

        // A tick that stores nothing leaves the signal where it is.
        let unchanged = await harness.service.tick(now: first.addingTimeInterval(0.5))
        #expect(unchanged == .unchanged(changeCount: 1))
        #expect(harness.status.latestCapture == signal)

        let later = first.addingTimeInterval(1)
        harness.pasteboard.copyText("another card")
        _ = await harness.service.tick(now: later)
        let newer = try #require(harness.status.latestCapture)
        #expect(newer.summary.id != signal.summary.id)
        #expect(newer.summary.excerpt == "another card")
        #expect(newer.timestamp == later)
    }
}
