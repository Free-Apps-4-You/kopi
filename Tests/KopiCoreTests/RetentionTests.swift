import Foundation
import Testing

@testable import KopiCore

@Suite("Retention")
struct RetentionTests {
    @Test("7 days expires cards copied more than a week ago")
    func sevenDayRetention() async throws {
        let workspace = try TempWorkspace()
        try await workspace.store.beginSession()
        _ = try await workspace.store.setRetention(.sevenDays)

        let recent = try await workspace.store.insert(textInsertion("copied today"))
        let old = try await workspace.store.insert(textInsertion("copied eight days ago", capturedAt: .daysAgo(8)))
        let borderline = try await workspace.store.insert(textInsertion("copied six days ago", capturedAt: .daysAgo(6)))

        let report = try await workspace.store.runCleanup(now: Date())

        #expect(report.retention == .sevenDays)
        #expect(report.removedItemIDs == [old.itemID])
        #expect(report.cutoff != nil)
        let remaining = try await workspace.store.page(HistoryQuery())
        #expect(Set(remaining.itemIDs) == [recent.itemID, borderline.itemID])
    }

    @Test("30 days keeps week-old cards and expires month-old ones")
    func thirtyDayRetention() async throws {
        let workspace = try TempWorkspace()
        try await workspace.store.beginSession()
        _ = try await workspace.store.setRetention(.thirtyDays)

        let weekOld = try await workspace.store.insert(textInsertion("copied eight days ago", capturedAt: .daysAgo(8)))
        let monthOld = try await workspace.store.insert(textInsertion("copied forty days ago", capturedAt: .daysAgo(40)))

        let report = try await workspace.store.runCleanup(now: Date())
        #expect(report.removedItemIDs == [monthOld.itemID])
        let remaining = try await workspace.store.page(HistoryQuery())
        #expect(remaining.itemIDs == [weekOld.itemID])
    }

    @Test("Changing the retention setting applies it immediately")
    func retentionChangeAppliesImmediately() async throws {
        let workspace = try TempWorkspace()
        try await workspace.store.beginSession()

        let weekOld = try await workspace.store.insert(textInsertion("survives a month, not a week", capturedAt: .daysAgo(8)))
        let monthOld = try await workspace.store.insert(textInsertion("does not survive a month", capturedAt: .daysAgo(40)))

        let thirtyDays = try await workspace.store.setRetention(.thirtyDays)
        #expect(thirtyDays.removedItemIDs == [monthOld.itemID])

        let sevenDays = try await workspace.store.setRetention(.sevenDays)
        #expect(sevenDays.removedItemIDs == [weekOld.itemID])

        let statistics = try await workspace.store.statistics()
        #expect(statistics.itemCount == 0)
        #expect(statistics.retention == .sevenDays)
    }

    @Test("Current session clears unpinned cards when Kopi quits")
    func currentSessionClearsOnQuit() async throws {
        let workspace = try TempWorkspace()
        try await workspace.store.beginSession()
        _ = try await workspace.store.setRetention(.currentSession)

        let unpinned = try await workspace.store.insert(textInsertion("ordinary history"))
        let pinned = try await workspace.store.insert(textInsertion("kept on purpose"))
        _ = try await workspace.store.setPinned(true, for: pinned.itemID)

        let report = try await workspace.store.endSession()

        #expect(report.removedItemIDs == [unpinned.itemID])
        let remaining = try await workspace.store.page(HistoryQuery())
        #expect(remaining.itemIDs == [pinned.itemID])

        let relaunched = try workspace.reopenStore()
        let afterRelaunch = try await relaunched.beginSession()
        #expect(afterRelaunch.recoveredFromInterruptedExit == false)
        let survivors = try await relaunched.page(HistoryQuery())
        #expect(survivors.itemIDs == [pinned.itemID])
    }

    @Test("An interrupted exit removes the previous session's unpinned cards")
    func interruptedExitRemovesPreviousSessionItems() async throws {
        let workspace = try TempWorkspace()
        try await workspace.store.beginSession()
        _ = try await workspace.store.setRetention(.currentSession)
        let unpinned = try await workspace.store.insert(textInsertion("from the crashed run"))
        let pinned = try await workspace.store.insert(textInsertion("pinned in the crashed run"))
        _ = try await workspace.store.setPinned(true, for: pinned.itemID)

        // No endSession: the previous run never shut down cleanly.
        let relaunched = try workspace.reopenStore()
        let start = try await relaunched.beginSession()

        #expect(start.recoveredFromInterruptedExit)
        #expect(start.cleanup.removedItemIDs == [unpinned.itemID])
        let survivors = try await relaunched.page(HistoryQuery())
        #expect(survivors.itemIDs == [pinned.itemID])
    }

    @Test("An interrupted exit keeps cards when retention is time based")
    func interruptedExitKeepsTimeBasedItems() async throws {
        let workspace = try TempWorkspace()
        try await workspace.store.beginSession()
        _ = try await workspace.store.setRetention(.sevenDays)
        let inserted = try await workspace.store.insert(textInsertion("survives a crash"))

        let relaunched = try workspace.reopenStore()
        let start = try await relaunched.beginSession()

        #expect(start.recoveredFromInterruptedExit)
        #expect(start.cleanup.removedItemIDs.isEmpty)
        let survivors = try await relaunched.page(HistoryQuery())
        #expect(survivors.itemIDs == [inserted.itemID])
    }

    @Test("Unpinning restarts the retention period")
    func unpinningRestartsRetention() async throws {
        let workspace = try TempWorkspace()
        try await workspace.store.beginSession()
        _ = try await workspace.store.setRetention(.sevenDays)

        let now = Date()
        let inserted = try await workspace.store.insert(
            textInsertion("preserved for a while", capturedAt: now.addingTimeInterval(-9 * 24 * 60 * 60))
        )
        _ = try await workspace.store.setPinned(true, for: inserted.itemID, now: now)

        let whilePinned = try await workspace.store.runCleanup(now: now)
        #expect(whilePinned.removedItemIDs.isEmpty)

        _ = try await workspace.store.unpin(for: inserted.itemID, now: now)

        let afterUnping = try await workspace.store.runCleanup(now: now)
        #expect(afterUnping.removedItemIDs.isEmpty)

        let summary = try #require(await workspace.store.summary(for: inserted.itemID))
        #expect(summary.lastCopiedAt == now)

        let later = try await workspace.store.runCleanup(now: now.addingTimeInterval(8 * 24 * 60 * 60))
        #expect(later.removedItemIDs == [inserted.itemID])
    }

    @Test("Pinned cards never expire, whatever their age")
    func pinnedCardsNeverExpire() async throws {
        let workspace = try TempWorkspace()
        try await workspace.store.beginSession()
        _ = try await workspace.store.setRetention(.sevenDays)

        let ancient = try await workspace.store.insert(textInsertion("pinned long ago", capturedAt: .daysAgo(400)))
        _ = try await workspace.store.setPinned(true, for: ancient.itemID, now: .daysAgo(399))

        let report = try await workspace.store.runCleanup(now: Date())
        #expect(report.removedItemIDs.isEmpty)
        let summary = try #require(await workspace.store.summary(for: ancient.itemID))
        #expect(summary.isPinned)
    }

    @Test("Clear History keeps pinned cards and removes the rest")
    func clearHistoryKeepsPins() async throws {
        let workspace = try TempWorkspace()
        try await workspace.store.beginSession()
        _ = try await workspace.store.setRetention(.thirtyDays)

        let first = try await workspace.store.insert(textInsertion("first ordinary card"))
        let second = try await workspace.store.insert(textInsertion("second ordinary card"))
        let pinned = try await workspace.store.insert(textInsertion("pinned card"))
        _ = try await workspace.store.setPinned(true, for: pinned.itemID)

        let report = try await workspace.store.clearHistory()

        #expect(Set(report.removedItemIDs) == [first.itemID, second.itemID])
        #expect(report.trigger == .clearHistory)
        let remaining = try await workspace.store.page(HistoryQuery())
        #expect(remaining.itemIDs == [pinned.itemID])

        let pinnedPage = try await workspace.store.page(HistoryQuery(scope: .pinned))
        #expect(pinnedPage.itemIDs == [pinned.itemID])

        // A pinned card can still be removed explicitly.
        _ = try await workspace.store.delete(pinned.itemID)
        let emptied = try await workspace.store.page(HistoryQuery())
        #expect(emptied.items.isEmpty)
    }

    @Test("Cleanup collects the assets of the cards it expires")
    func cleanupCollectsExpiredAssets() async throws {
        let workspace = try TempWorkspace()
        try await workspace.store.beginSession()
        _ = try await workspace.store.setRetention(.sevenDays)

        let bytes = Data(repeating: 7, count: 512)
        let asset = try await workspace.assetStore.importData(bytes, kind: .image, fileExtension: "png")
        let expired = try await workspace.store.insert(
            imageInsertion(asset: asset.reference, capturedAt: .daysAgo(9))
        )
        #expect(FileManager.default.fileExists(atPath: workspace.assetStore.fileURL(for: asset.reference).path))

        let report = try await workspace.store.runCleanup(now: Date())

        #expect(report.removedItemIDs == [expired.itemID])
        #expect(report.removedAssetIDs == [asset.reference.id])
        #expect(!FileManager.default.fileExists(atPath: workspace.assetStore.fileURL(for: asset.reference).path))
        let statistics = try await workspace.store.statistics()
        #expect(statistics.assetCount == 0)
    }

    @Test("Periodic maintenance applies retention while Kopi runs")
    func periodicMaintenanceAppliesRetention() async throws {
        let workspace = try TempWorkspace()
        try await workspace.store.beginSession()
        _ = try await workspace.store.setRetention(.sevenDays)
        let expired = try await workspace.store.insert(textInsertion("expired", capturedAt: .daysAgo(30)))
        let kept = try await workspace.store.insert(textInsertion("kept"))

        let maintenance = HistoryMaintenance(store: workspace.store, interval: .milliseconds(10))
        await maintenance.start()
        let running = await maintenance.isRunning
        #expect(running)

        var removed = false
        for _ in 0..<200 where !removed {
            try await Task.sleep(for: .milliseconds(5))
            let page = try await workspace.store.page(HistoryQuery())
            removed = !page.itemIDs.contains(expired.itemID)
        }
        await maintenance.stop()
        let stopped = await maintenance.isRunning
        #expect(stopped == false)

        #expect(removed)
        let remaining = try await workspace.store.page(HistoryQuery())
        #expect(remaining.itemIDs == [kept.itemID])
    }

    @Test("Switching to session retention removes the cards of earlier sessions")
    func cleanupRemovesEarlierSessions() async throws {
        let workspace = try TempWorkspace()
        let stale = try await workspace.store.insert(textInsertion("captured before this run"))

        try await workspace.store.beginSession()
        let current = try await workspace.store.insert(textInsertion("captured in this run"))

        let report = try await workspace.store.setRetention(.currentSession)
        #expect(report.removedItemIDs == [stale.itemID])

        let after = try await workspace.store.runCleanup(now: Date())
        #expect(after.removedItemIDs.isEmpty)

        let remaining = try await workspace.store.page(HistoryQuery())
        #expect(remaining.itemIDs == [current.itemID])
    }
}
