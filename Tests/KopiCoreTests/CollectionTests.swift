import Foundation
import Testing

@testable import KopiCore

@Suite("Collecting content")
struct CollectionInsertionTests {
    @Test("Collecting identical content twice collapses onto one collected card")
    func repeatedCollectionCollapses() async throws {
        let workspace = try TempWorkspace()
        try await workspace.store.beginSession()

        let first = try await workspace.store.insert(textInsertion("collected text", destination: .collection))
        let second = try await workspace.store.insert(textInsertion("collected text", destination: .collection))

        #expect(first.didCreateItem)
        #expect(first.summary.isCollection)
        #expect(second.didCreateItem == false)
        #expect(second.itemID == first.itemID)
        #expect(try await workspace.store.count(scope: .collection) == 1)
    }

    @Test("Collected content keeps a card of its own beside identical history")
    func collectionStaysSeparateFromHistory() async throws {
        let workspace = try TempWorkspace()
        try await workspace.store.beginSession()

        let history = try await workspace.store.insert(textInsertion("the same words"))
        let collected = try await workspace.store.insert(textInsertion("the same words", destination: .collection))

        #expect(collected.didCreateItem)
        #expect(collected.itemID != history.itemID)
        let original = try #require(await workspace.store.summary(for: history.itemID))
        #expect(original.isCollection == false)
        #expect(try await workspace.store.count(scope: .collection) == 1)
        #expect(try await workspace.store.count() == 2)
    }

    @Test("A new item is an empty card of its own, never collapsed onto another")
    func newItemsStaySeparate() async throws {
        let workspace = try TempWorkspace()
        try await workspace.store.beginSession()

        let first = try await workspace.store.insert(.newCollectionItem())
        let second = try await workspace.store.insert(.newCollectionItem())

        #expect(first.didCreateItem)
        #expect(second.didCreateItem)
        #expect(first.itemID != second.itemID)
        #expect(first.summary.isCollection)
        #expect(first.summary.kind == .text)
        #expect(first.summary.excerpt.isEmpty)
        #expect(try await workspace.store.count(scope: .collection) == 2)
    }

    @Test("A snapshot prepared for the shelf is bound for the shelf")
    func processorDestination() async throws {
        let workspace = try TempWorkspace()
        let processor = CaptureProcessor(assetStore: workspace.assetStore)

        let collected = try await processor.insertion(
            from: textSnapshot("collected"),
            origin: .external(changeCount: 1),
            destination: .collection
        )
        #expect(collected.destination == .collection)

        let history = try await processor.insertion(from: textSnapshot("ordinary"), origin: .external(changeCount: 1))
        #expect(history.destination == .history)
    }
}

@Suite("Collecting a card")
struct CollectionCardCopyTests {
    @Test("Collecting a card stores a copy and leaves the original where it is")
    func copiesTheCard() async throws {
        let workspace = try TempWorkspace()
        try await workspace.store.beginSession()
        let original = try await workspace.store.insert(textInsertion("kept in history", label: "A label"))

        let collected = try await workspace.store.addToCollection(original.itemID)

        #expect(collected.didCreateItem)
        #expect(collected.itemID != original.itemID)
        #expect(collected.summary.isCollection)
        #expect(collected.summary.label == "A label")
        #expect(collected.summary.fingerprint == original.summary.fingerprint)

        let source = try #require(await workspace.store.summary(for: original.itemID))
        #expect(source.isCollection == false)
        #expect(source.label == "A label")
        #expect(try await workspace.store.count(scope: .collection) == 1)
        #expect(try await workspace.store.count() == 2)

        let repeated = try await workspace.store.addToCollection(original.itemID)
        #expect(repeated.didCreateItem == false)
        #expect(repeated.itemID == collected.itemID)
        #expect(try await workspace.store.count(scope: .collection) == 1)
    }

    @Test("Collecting an image card keeps the image and shares its stored bytes")
    func copiesAnImageCard() async throws {
        let workspace = try TempWorkspace()
        try await workspace.store.beginSession()
        let asset = try await workspace.assetStore.importData(pngData(), kind: .image, fileExtension: "png")
        let original = try await workspace.store.insert(imageInsertion(asset: asset.reference))

        let collected = try await workspace.store.addToCollection(original.itemID)
        #expect(collected.summary.kind == .image)
        let detail = try #require(await workspace.store.detail(for: collected.itemID))
        #expect(detail.representations.first?.asset?.id == asset.reference.id)

        // The collected copy keeps the file alive after the history card is deleted.
        _ = try await workspace.store.delete(original.itemID)
        #expect(try await workspace.store.count(scope: .collection) == 1)
        #expect(FileManager.default.fileExists(atPath: workspace.assetStore.fileURL(for: asset.reference).path))
    }

    @Test("Collecting a card that is already collected returns it as it is")
    func alreadyCollected() async throws {
        let workspace = try TempWorkspace()
        try await workspace.store.beginSession()
        let collected = try await workspace.store.insert(textInsertion("on the shelf", destination: .collection))

        let again = try await workspace.store.addToCollection(collected.itemID)

        #expect(again.didCreateItem == false)
        #expect(again.itemID == collected.itemID)
        #expect(try await workspace.store.count(scope: .collection) == 1)
    }

    @Test("Collecting a card that no longer exists fails")
    func missingCard() async throws {
        let workspace = try TempWorkspace()
        try await workspace.store.beginSession()
        let missing = ClipboardItemID()

        await #expect(throws: HistoryStoreError.itemNotFound(missing)) {
            try await workspace.store.addToCollection(missing)
        }
    }
}

@Suite("Pasting into the collection")
struct CollectionPasteTests {
    @Test("⌘V collects the clipboard without touching the observation bookkeeping")
    func pasteKeepsBookkeeping() async throws {
        let harness = try await CaptureHarness()
        await harness.service.start()
        harness.pasteboard.copyText("collected from the clipboard")
        let remembered = await harness.service.lastObservedChangeCount

        let collected = try await harness.service.captureClipboard(into: .collection)

        #expect(collected.didCreateItem)
        #expect(collected.summary.isCollection)
        let afterPaste = await harness.service.lastObservedChangeCount
        #expect(afterPaste == remembered)
        #expect(try await harness.workspace.store.ownCopyState() == nil)
        #expect(try await harness.workspace.store.count(scope: .collection) == 1)

        // The loop had not seen the copy yet, so its own tick still accounts for it,
        // and the identical content collapses onto the collected card.
        let captured = await harness.service.tick()
        #expect(captured.insertionResult?.didCreateItem == false)
        #expect(captured.summary?.id == collected.itemID)
        let statistics = try await harness.workspace.store.statistics()
        #expect(statistics.itemCount == 1)
    }

    @Test("Collecting a card Kopi copied itself does not disturb own-copy suppression")
    func pasteKeepsOwnCopy() async throws {
        let harness = try await CaptureHarness()
        await harness.service.start()
        harness.pasteboard.copyText("copied with ⌘C")
        let captured = await harness.service.tick()
        let itemID = try #require(captured.summary?.id)

        let ownCopy = try await harness.service.copyToPasteboard(itemID)
        let remembered = await harness.service.lastObservedChangeCount

        let collected = try await harness.service.captureClipboard(into: .collection)
        #expect(collected.didCreateItem)
        #expect(collected.summary.isCollection)
        let afterPaste = await harness.service.lastObservedChangeCount
        #expect(afterPaste == remembered)
        let recorded = try await harness.workspace.store.ownCopyState()
        #expect(recorded == ownCopy)

        // Kopi's own write is still recognised, so nothing more is stored.
        let skipped = await harness.service.tick()
        #expect(skipped == .ownCopy(itemID: itemID, changeCount: ownCopy.changeCount))
        #expect(try await harness.workspace.store.count(scope: .collection) == 1)
        #expect(try await harness.workspace.store.count() == 2)
    }

    @Test("A clipboard that moves once is read again")
    func retriesOnce() async throws {
        let harness = try await CaptureHarness()
        harness.pasteboard.copyText("first copy")
        harness.pasteboard.changeDuringNextRead(to: [textItem("second copy")])

        let collected = try await harness.service.captureClipboard(into: .collection)

        #expect(collected.summary.excerpt == "second copy")
        #expect(collected.summary.isCollection)
    }

    @Test("A clipboard that keeps moving is left alone")
    func givesUpOnAMovingClipboard() async throws {
        let harness = try await CaptureHarness()
        harness.pasteboard.copyText("first copy")
        harness.pasteboard.changeDuringEveryRead(to: [textItem("second copy")])

        await #expect(throws: ClipboardServiceError.clipboardChanged) {
            try await harness.service.captureClipboard(into: .collection)
        }
        #expect(try await harness.workspace.store.count() == 0)
    }

    @Test("An empty clipboard is refused")
    func emptyClipboard() async throws {
        let harness = try await CaptureHarness()

        await #expect(throws: CaptureProcessorError.unsupportedContent) {
            try await harness.service.captureClipboard(into: .collection)
        }
    }

    @Test("A refused read blocks the loop the way its own read would")
    func refusedRead() async throws {
        let harness = try await CaptureHarness()
        await harness.service.start()
        harness.pasteboard.failReads(with: PasteboardAccessError.accessDenied)

        await #expect(throws: PasteboardAccessError.accessDenied) {
            try await harness.service.captureClipboard(into: .collection)
        }
        #expect(await harness.service.state == .blocked(.pasteboardAccessDenied))
        #expect(harness.ticker.isActive == false)
    }
}

@Suite("Dropping into the collection")
struct CollectionDropTests {
    @Test("Only the flavours a dropped item registers are read")
    func readableKinds() {
        #expect(DropCaptureMapping.readableKinds(among: ["public.file-url", "public.utf8-plain-text"]) == [.plainText, .fileURL])
        #expect(DropCaptureMapping.readableKinds(among: ["public.png", "public.rtf"]) == [.rtf, .png])
        #expect(DropCaptureMapping.readableKinds(among: ["com.unknown.type"]) == [])
        #expect(DropCaptureMapping.readableKinds(among: ["com.adobe.pdf"]) == [])
        #expect(DropCaptureMapping.supportedKinds.contains(.pdf) == false)
        #expect(DropCaptureMapping.supportedKinds.contains(.fileURL))
    }

    @Test("Dropped content is collected in the shape a capture produces")
    func droppedKinds() async throws {
        let harness = try await CaptureHarness()

        let text = try await harness.service.capture(textSnapshot("dropped words"), into: .collection)
        #expect(text.summary.kind == .text)
        #expect(text.summary.isCollection)

        let rich = try await harness.service.capture(
            PasteboardSnapshot(changeCount: 2, items: [richItem(plainText: "bold words", rtf: rtfData("bold words", bold: true))]),
            into: .collection
        )
        #expect(rich.summary.kind == .richText)

        let link = try await harness.service.capture(
            PasteboardSnapshot(changeCount: 3, items: [linkItem("https://kopi.dev/docs")]),
            into: .collection
        )
        #expect(link.summary.kind == .link)

        let image = try await harness.service.capture(
            PasteboardSnapshot(changeCount: 4, items: [imageItem(pngData())]),
            into: .collection
        )
        #expect(image.summary.kind == .image)
        let imageDetail = try #require(await harness.workspace.store.detail(for: image.itemID))
        #expect(imageDetail.representations.first?.asset != nil)

        #expect(try await harness.workspace.store.count(scope: .collection) == 4)
    }

    @Test("A dropped multi-file selection stays one card, in drop order")
    func multiFileDrop() async throws {
        let harness = try await CaptureHarness()
        let first = try harness.workspace.writeFile("First.txt", contents: "first")
        let second = try harness.workspace.writeFile("Second.txt", contents: "second")
        let snapshot = PasteboardSnapshot(changeCount: 1, items: [fileItem(second), fileItem(first)])

        let collected = try await harness.service.capture(snapshot, into: .collection)

        #expect(collected.summary.kind == .files)
        #expect(collected.summary.isCollection)
        #expect(collected.summary.fileNames == ["Second.txt", "First.txt"])
        #expect(try await harness.workspace.store.count(scope: .collection) == 1)
    }

    @Test("A drop of something Kopi cannot store is refused")
    func unsupportedDrop() async throws {
        let harness = try await CaptureHarness()
        let empty = PasteboardSnapshot(changeCount: 0, items: [])

        await #expect(throws: CaptureProcessorError.unsupportedContent) {
            try await harness.service.capture(empty, into: .collection)
        }
        #expect(try await harness.workspace.store.count() == 0)
    }
}

@Suite("The collection is kept for good")
struct CollectionPersistenceTests {
    @Test("Collected cards survive quitting and relaunching")
    func cleanRelaunch() async throws {
        let workspace = try TempWorkspace()
        try await workspace.store.beginSession()
        _ = try await workspace.store.setRetention(.sevenDays)
        let collected = try await workspace.store.insert(textInsertion("collected before quitting", destination: .collection))
        _ = try await workspace.store.endSession()

        let relaunched = try workspace.reopenStore()
        let start = try await relaunched.beginSession()

        #expect(start.recoveredFromInterruptedExit == false)
        let page = try await relaunched.page(HistoryQuery(scope: .collection))
        #expect(page.itemIDs == [collected.itemID])
        #expect(page.items.first?.isCollection == true)
    }

    @Test("Collected cards survive a force quit and the next launch")
    func forcedRelaunch() async throws {
        let workspace = try TempWorkspace()
        try await workspace.store.beginSession()
        _ = try await workspace.store.setRetention(.currentSession)
        let collected = try await workspace.store.insert(textInsertion("collected before the crash", destination: .collection))
        let ordinary = try await workspace.store.insert(textInsertion("lost with the session"))

        // No endSession: the next start has to recover from an interrupted exit.
        let relaunched = try workspace.reopenStore()
        let start = try await relaunched.beginSession()

        #expect(start.recoveredFromInterruptedExit)
        #expect(start.cleanup.removedItemIDs == [ordinary.itemID])
        let page = try await relaunched.page(HistoryQuery(scope: .collection))
        #expect(page.itemIDs == [collected.itemID])
    }

    @Test("Clear History, retention and a relaunch leave mixed content standing")
    func mixedContentSurvivesEverything() async throws {
        let workspace = try TempWorkspace()
        try await workspace.store.beginSession()
        _ = try await workspace.store.setRetention(.sevenDays)

        let ordinary = try await workspace.store.insert(textInsertion("ordinary card", capturedAt: .daysAgo(40)))
        let pinned = try await workspace.store.insert(textInsertion("pinned card", capturedAt: .daysAgo(40)))
        _ = try await workspace.store.setPinned(true, for: pinned.itemID)
        let collected = try await workspace.store.insert(
            textInsertion("collected card", capturedAt: .daysAgo(40), destination: .collection)
        )

        let cleared = try await workspace.store.clearHistory()
        #expect(cleared.removedItemIDs == [ordinary.itemID])

        let cleanup = try await workspace.store.runCleanup(now: Date())
        #expect(cleanup.removedItemIDs.isEmpty)

        let relaunched = try workspace.reopenStore()
        let start = try await relaunched.beginSession()
        #expect(start.cleanup.removedItemIDs.isEmpty)

        let everything = try await relaunched.page(HistoryQuery())
        #expect(Set(everything.itemIDs) == [pinned.itemID, collected.itemID])
        #expect(try await relaunched.count(scope: .pinned) == 1)
        #expect(try await relaunched.count(scope: .collection) == 1)
        #expect(try await relaunched.count() == 2)
    }

    @Test("Retention passes leave a collected card of any age alone")
    func retentionNeverTouchesTheCollection() async throws {
        let workspace = try TempWorkspace()
        try await workspace.store.beginSession()
        _ = try await workspace.store.insert(
            textInsertion("collected long ago", capturedAt: .daysAgo(400), destination: .collection)
        )

        // The relaunch makes the card belong to an earlier session, which "Current
        // session" retention would remove if it were not collected.
        let relaunched = try workspace.reopenStore()
        try await relaunched.beginSession()
        for retention in HistoryRetention.allCases {
            _ = try await relaunched.setRetention(retention)
            let report = try await relaunched.runCleanup(now: Date())
            #expect(report.removedItemIDs.isEmpty)
        }

        #expect(try await relaunched.count(scope: .collection) == 1)
    }
}
