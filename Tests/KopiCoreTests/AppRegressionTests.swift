import AppKit
import Combine
import QuartzCore
import SwiftUI
import Testing

@testable import Kopi
@testable import KopiCore

@Suite("App responsiveness and preview regressions")
@MainActor
struct AppRegressionTests {
    @Test("Panel background paints an opaque, uniform surface in every appearance")
    func panelBackgroundDoesNotDependOnBackdropCompositing() throws {
        for scheme in [ColorScheme.light, .dark] {
            for scale in [1.0, 2.0] {
                let renderer = ImageRenderer(content: PanelSurface()
                    .environment(\.colorScheme, scheme)
                    .frame(width: 160, height: 100))
                renderer.scale = scale
                let image = try #require(renderer.cgImage)
                let bitmap = NSBitmapImageRep(cgImage: image)
                let reference = try #require(bitmap.colorAt(x: image.width / 2, y: image.height / 2)?.usingColorSpace(.deviceRGB))
                for (x, y) in [(0, 0), (image.width - 1, 0), (0, image.height - 1), (image.width - 1, image.height - 1)] {
                    let color = try #require(bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB))
                    #expect(color.alphaComponent == 1)
                    #expect(abs(color.redComponent - reference.redComponent) < 0.005)
                    #expect(abs(color.greenComponent - reference.greenComponent) < 0.005)
                    #expect(abs(color.blueComponent - reference.blueComponent) < 0.005)
                }
            }
        }
    }

    @Test("Settings gear accepts a first click and forwards repeated requests")
    func settingsGearClickThrough() {
        // NSButton dispatches target/action through NSApp, including in CI.
        _ = NSApplication.shared
        var requests = 0
        let button = PanelSettingsButton { requests += 1 }
        #expect(button.acceptsFirstMouse(for: nil))
        #expect(button.identifier?.rawValue == "kopi.settings")
        button.performClick(nil)
        button.performClick(nil)
        #expect(requests == 2)
        button.onPress = { requests += 10 }
        button.performClick(nil)
        #expect(requests == 12)
    }

    @Test("Panel input accepts the first click while Settings owns window focus")
    func panelControlsAcceptTheFirstClick() throws {
        let host = WindowTransitionHost(rootView: EmptyView())
        let hosting = try #require(host.animatedSurface.subviews.first)
        // AppKit asks the clicked view before dispatching mouseDown when another
        // window owns focus. Checking the action alone bypasses this decision.
        #expect(host.acceptsFirstMouse(for: nil))
        #expect(host.animatedSurface.acceptsFirstMouse(for: nil))
        #expect(hosting.acceptsFirstMouse(for: nil))
    }

    @Test("Settings handoff blocks reopening until the panel is hidden, then permits explicit opening")
    func settingsHandoffOwnsReopenIntent() {
        var presentation = WindowPresentationIntent()
        let initialOpen = presentation.requestPanel()
        #expect(initialOpen)
        let first = presentation.requestSettings()
        let openDuringHandoff = presentation.requestPanel()
        #expect(!openDuringHandoff)
        #expect(presentation.shouldFocusSettingsOnReopen(settingsAreVisible: false))
        presentation.finishSettingsRequest(first)
        #expect(presentation.shouldFocusSettingsOnReopen(settingsAreVisible: true))
        #expect(!presentation.shouldFocusSettingsOnReopen(settingsAreVisible: false))
        // The menu-bar or hover action is still allowed while Settings exists.
        let explicitOpen = presentation.requestPanel()
        #expect(explicitOpen)
        #expect(!presentation.shouldFocusSettingsOnReopen(settingsAreVisible: true))
        let second = presentation.requestSettings()
        presentation.finishSettingsRequest(first)
        #expect(presentation.isHandingOffToSettings)
        #expect(presentation.isCurrentSettingsRequest(second))
        presentation.finishSettingsRequest(second)
        #expect(!presentation.isHandingOffToSettings)
        #expect(presentation.shouldFocusSettingsOnReopen(settingsAreVisible: true))
    }

    @Test("Expansion starts at a notch-sized shape and holds the top edge on different screen sizes")
    func panelExpansionGeometry() {
        for size in [CGSize(width: 684, height: 464), CGSize(width: 924, height: 604), CGSize(width: 1600, height: 900)] {
            for flipped in [false, true] {
                let transform = WindowTransition.collapsedTransform(size: size, fromTop: true, isFlipped: flipped, sourceWidth: 180)
                #expect(abs(size.width * transform.m11 - 180) < 0.001)
                #expect(abs(size.height * transform.m22 - 32) < 0.001)
                let top = (flipped ? -1.0 : 1.0) * size.height / 2
                #expect(abs(top * transform.m22 + transform.m42 - top) < 0.001)
                #expect(transform.m41 == 0)
            }
        }
        let fallback = WindowTransition.collapsedTransform(size: CGSize(width: 924, height: 604), fromTop: true, isFlipped: true, sourceWidth: 0)
        #expect(abs(fallback.m11 * 924 - 180) < 0.001)
        let empty = WindowTransition.collapsedTransform(size: .zero, fromTop: true, isFlipped: true)
        #expect(CATransform3DIsIdentity(empty))
    }

    @Test("Item types show their own fields and switching protects existing content")
    func newItemModeSwitchProtectsContent() async throws {
        let fixture = try await AppFixture()
        fixture.panel.addItem()
        #expect(fixture.panel.newItemDraft?.mode == .text)
        fixture.panel.updateNewItemText("Keep this text")
        fixture.panel.updateNewItemLabel("Keep this label")
        fixture.panel.selectNewItemMode(.file)
        #expect(fixture.panel.pendingNewItemMode == .file)
        #expect(fixture.panel.newItemDraft?.mode == .text)
        fixture.panel.cancelNewItemModeChange()
        #expect(fixture.panel.newItemDraft?.text == "Keep this text")
        fixture.panel.selectNewItemMode(.image)
        fixture.panel.confirmNewItemModeChange()
        #expect(fixture.panel.newItemDraft?.mode == .image)
        #expect(fixture.panel.newItemDraft?.text == "")
        #expect(fixture.panel.newItemDraft?.label == "Keep this label")
        fixture.panel.updateNewItemText("Files and images cannot accept text")
        #expect(fixture.panel.newItemDraft?.text == "")
        let image = fixture.capture.workspace.root.appendingPathComponent("dropped-image.png")
        try pngData().write(to: image)
        fixture.panel.dropIntoNewItem([NSItemProvider(item: image as NSURL, typeIdentifier: "public.file-url")])
        for _ in 0..<100 {
            if fixture.panel.newItemDraft?.attachment != nil { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(fixture.panel.newItemDraft?.mode == .image)
        #expect(fixture.panel.newItemDraft?.attachment?.kind == .image)
        fixture.panel.selectNewItemMode(.link)
        fixture.panel.confirmNewItemModeChange()
        fixture.panel.updateNewItemText("not a valid link")
        await fixture.panel.saveNewItem()
        #expect(fixture.panel.newItemDraft?.error != nil)
        #expect(fixture.panel.newItemDraft?.mode == .link)
        fixture.panel.updateNewItemText("example.com/path")
        await fixture.panel.saveNewItem()
        let saved = try await fixture.capture.workspace.store.page(HistoryQuery(scope: .collection)).items
        #expect(saved.first?.kind == .link)
        #expect(saved.first?.primaryURL?.absoluteString == "https://example.com/path")
        fixture.panel.addItem()
        fixture.panel.updateNewItemText("https://example.com/keep-as-text")
        await fixture.panel.saveNewItem()
        let cards = try await fixture.capture.workspace.store.page(HistoryQuery(scope: .collection)).items
        #expect(cards.filter { $0.kind == .text }.count == 1)
    }

    @Test("Reconnecting migrates the old empty folder choice to a usable default scope")
    func reconnectRestoresDefaultNotesScope() async throws {
        let fixture = try await AppFixture()
        await fixture.notes.connect()
        let folder = try #require(fixture.notes.folders.first { $0.isDefault })
        #expect(fixture.notes.isIncluded(folder))
        fixture.notes.setIncluded(false, for: folder)
        #expect(!fixture.notes.isIncluded(folder))
        #expect(fixture.notes.notes.isEmpty)
        #expect(fixture.settings.settings.notesFoldersConfigured)
        #expect(fixture.settings.settings.notesFolderIDs.isEmpty)
        let persisted = try JSONDecoder().decode(KopiSettings.self, from: JSONEncoder().encode(fixture.settings.settings))
        #expect(persisted.notesFoldersConfigured)
        #expect(persisted.notesFolderIDs.isEmpty)
        let runner = FakeNotesRunner.sample()
        let restored = NotesTabViewModel(client: NotesAutomationClient(runner: runner, permission: FixedPermissionChecker(.authorized)),
                                        service: fixture.capture.service, settings: fixture.settings)
        await restored.connect()
        #expect(restored.isIncluded(folder))
        #expect(restored.state == .loaded)
        #expect(!restored.notes.isEmpty)
        #expect(await runner.callCount("contents") > 0)
        #expect(!fixture.settings.settings.notesFoldersConfigured)
    }

    @Test("Unchecking the Notes connection clears cards and stays disconnected on tab activation")
    func notesConnectionCheckboxDisconnects() async throws {
        let runner = FakeNotesRunner.sample()
        let fixture = try await AppFixture(runner: runner)
        await fixture.notes.setConnected(true)
        #expect(fixture.notes.state.isConnected)
        #expect(!fixture.notes.notes.isEmpty)
        await fixture.notes.setConnected(false)
        #expect(fixture.notes.state == .disconnected)
        #expect(fixture.notes.notes.isEmpty)
        #expect(fixture.notes.filteredNotes.isEmpty)
        #expect(fixture.notes.folders.isEmpty)
        #expect(!fixture.notes.isBusy)
        #expect(!fixture.notes.isChangingConnection)
        #expect(await runner.callCount("reset") == 1)
        let reads = await runner.callCount("summaries")
        await fixture.notes.activate()
        fixture.notes.setVisible(true)
        await fixture.notes.synchronizeIfNeeded()
        fixture.notes.setVisible(false)
        #expect(fixture.notes.state == .disconnected)
        #expect(await runner.callCount("summaries") == reads)
        await fixture.notes.setConnected(true)
        #expect(fixture.notes.state.isConnected)
        #expect(!fixture.notes.notes.isEmpty)
    }

    @Test("Disconnecting during Notes sync cannot restore cards after the request completes")
    func disconnectDuringNotesRefresh() async throws {
        let runner = FakeNotesRunner.sample()
        let fixture = try await AppFixture(runner: runner)
        await fixture.notes.connect()
        await runner.setContentReadDelay(.milliseconds(80), for: NotesFixtures.noteID(1))
        await runner.setSummary(NotesFixtures.summary(1, date: NotesFixtures.baseDate.addingTimeInterval(500)))
        let before = await runner.callCount("contents")
        let refresh = Task { await fixture.notes.refresh(silently: true) }
        for _ in 0..<1000 {
            if await runner.callCount("contents") > before { break }
            await Task.yield()
        }
        await fixture.notes.setConnected(false)
        await refresh.value
        await fixture.notes.activate()
        #expect(fixture.notes.state == .disconnected)
        #expect(fixture.notes.notes.isEmpty)
        #expect(fixture.notes.filteredNotes.isEmpty)
        #expect(!fixture.notes.isBusy)
    }

    @Test("Folder changes during a slow Notes refresh cannot restore excluded notes")
    func notesFolderChangesDuringRefresh() async throws {
        let runner = FakeNotesRunner.sample()
        let fixture = try await AppFixture(runner: runner)
        await fixture.notes.connect()
        let folder = try #require(fixture.notes.folders.first { $0.isDefault })
        await runner.setContentReadDelay(.milliseconds(70), for: NotesFixtures.noteID(1))
        await runner.setSummary(NotesFixtures.summary(1, date: NotesFixtures.baseDate.addingTimeInterval(500)))
        let refresh = Task { await fixture.notes.refresh(silently: true) }
        while !fixture.notes.isBusy { await Task.yield() }
        fixture.notes.setIncluded(false, for: folder)
        fixture.notes.setIncluded(true, for: folder)
        fixture.notes.setIncluded(false, for: folder)
        await refresh.value
        for _ in 0..<100 {
            if fixture.notes.state == .empty, !fixture.notes.isBusy { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(!fixture.notes.isIncluded(folder))
        #expect(fixture.notes.notes.isEmpty)
        #expect(fixture.notes.filteredNotes.isEmpty)
        #expect(fixture.notes.state == .empty)
        fixture.settings.reset()
        #expect(fixture.notes.isIncluded(folder))
    }

    @Test("Discarding Add preserves the previous tab, source, search and stored cards")
    func stagedAddReturnsToPreviousScreen() async throws {
        let fixture = try await AppFixture()
        fixture.panel.setSection(.images)
        fixture.panel.setSource(.pinned)
        fixture.panel.queryText = "previous search"
        let before = try await fixture.capture.workspace.store.page(HistoryQuery()).totalCount
        fixture.panel.addItem()
        #expect(fixture.panel.newItemDraft != nil)
        #expect(fixture.panel.section == .images)
        #expect(fixture.panel.source == .pinned)
        fixture.panel.updateNewItemText("An unsaved draft")
        fixture.panel.cancelNewItem()
        #expect(fixture.panel.showsSavePrompt)
        fixture.panel.cancelPendingNavigation()
        #expect(fixture.panel.newItemDraft?.text == "An unsaved draft")
        fixture.panel.cancelNewItem()
        fixture.panel.discardAndContinue()
        #expect(fixture.panel.newItemDraft == nil)
        #expect(fixture.panel.section == .images)
        #expect(fixture.panel.source == .pinned)
        #expect(fixture.panel.queryText == "previous search")
        #expect(try await fixture.capture.workspace.store.page(HistoryQuery()).totalCount == before)
    }

    @Test("Add closes untouched drafts immediately, but protects label-only changes")
    func emptyAddClosesWithoutPrompt() async throws {
        let fixture = try await AppFixture()
        fixture.panel.setSection(.images)
        fixture.panel.addItem()
        fixture.panel.cancelNewItem()
        #expect(fixture.panel.newItemDraft == nil)
        #expect(!fixture.panel.showsSavePrompt)
        #expect(fixture.panel.section == .images)
        fixture.panel.addItem()
        fixture.panel.updateNewItemLabel("Unsaved label")
        fixture.panel.cancelNewItem()
        #expect(fixture.panel.showsSavePrompt)
        await fixture.panel.saveAndContinue()
        #expect(fixture.panel.newItemDraft?.error != nil)
        #expect(fixture.panel.newItemDraft?.label == "Unsaved label")
        fixture.panel.discardAndContinue()
        #expect(fixture.panel.newItemDraft == nil)
        fixture.panel.setSection(.passwords)
        fixture.panel.addItem()
        fixture.panel.passwords.cancel()
        #expect(fixture.panel.passwords.draft == nil)
        #expect(!fixture.panel.showsSavePrompt)
    }

    @Test("Add enforces one payload and preserves labels for files, images, links and pasted text")
    func addOneItemAtATime() async throws {
        let fixture = try await AppFixture()
        let root = fixture.capture.workspace.root
        let image = root.appendingPathComponent("image.png")
        let file = root.appendingPathComponent("document.pdf")
        try pngData(width: 31, height: 17).write(to: image)
        try Data("File contents".utf8).write(to: file)
        fixture.panel.addItem()
        await fixture.panel.importNewItemFiles([image, image], asImages: true)
        #expect(fixture.panel.newItemDraft?.attachment == nil)
        #expect(fixture.panel.newItemDraft?.error != nil)
        fixture.panel.selectNewItemMode(.link)
        fixture.panel.updateNewItemText("https://example.com/kopi")
        await fixture.panel.importNewItemFiles([image], asImages: true)
        #expect(fixture.panel.newItemDraft?.attachment == nil)
        #expect(fixture.panel.newItemDraft?.text == "https://example.com/kopi")
        fixture.panel.updateNewItemLabel("Saved website")
        await fixture.panel.saveNewItem()
        fixture.panel.addItem()
        await fixture.panel.importNewItemFiles([image], asImages: true)
        fixture.panel.updateNewItemText("Cannot mix text and image")
        #expect(fixture.panel.newItemDraft?.text == "")
        fixture.panel.updateNewItemLabel("Saved picture")
        await fixture.panel.saveNewItem()
        fixture.panel.addItem()
        await fixture.panel.importNewItemFiles([file], asImages: false)
        fixture.capture.pasteboard.copyText("Cannot mix text and file")
        await fixture.panel.pasteIntoNewItem()
        #expect(fixture.panel.newItemDraft?.attachment?.kind == .files)
        fixture.panel.updateNewItemLabel("Saved document")
        await fixture.panel.saveNewItem()
        fixture.panel.addItem()
        fixture.capture.pasteboard.copyText("Pasted plain text")
        await fixture.panel.pasteIntoNewItem()
        fixture.panel.updateNewItemLabel("Saved text")
        await fixture.panel.saveNewItem()
        let cards = try await fixture.capture.workspace.store.page(HistoryQuery(scope: .collection)).items
        #expect(cards.count == 4)
        #expect(Set(cards.compactMap(\.label)) == Set(["Saved website", "Saved picture", "Saved document", "Saved text"]))
        #expect(Set(cards.map(\.kind)) == Set([.text, .link, .image, .files]))
        let found = try await fixture.capture.workspace.store.page(HistoryQuery(text: "Saved picture", scope: .collection))
        #expect(found.items.first?.label == "Saved picture")
    }

    @Test("Add rejects multi-item clipboard content and can replace a removed item")
    func addValidationAndImportFailures() async throws {
        let fixture = try await AppFixture()
        fixture.panel.addItem()
        await fixture.panel.saveNewItem()
        #expect(fixture.panel.newItemDraft?.error != nil)
        await fixture.panel.importNewItemFiles([fixture.capture.workspace.root.appendingPathComponent("missing.png")], asImages: true)
        #expect(fixture.panel.newItemDraft?.error != nil)
        #expect(fixture.panel.newItemDraft?.isLoading == false)
        fixture.capture.pasteboard.copy([textItem("First"), textItem("Second")])
        await fixture.panel.pasteIntoNewItem()
        #expect(fixture.panel.newItemDraft?.attachment == nil)
        #expect(fixture.panel.newItemDraft?.error != nil)
        fixture.capture.pasteboard.copyText("One item")
        await fixture.panel.pasteIntoNewItem()
        #expect(fixture.panel.newItemDraft?.text == "One item")
        fixture.panel.updateNewItemText("")
        let image = fixture.capture.workspace.root.appendingPathComponent("removable.png")
        try pngData().write(to: image)
        await fixture.panel.importNewItemFiles([image], asImages: true)
        let id = try #require(fixture.panel.newItemDraft?.attachment?.id)
        fixture.panel.removeNewItemAttachment(id)
        #expect(fixture.panel.newItemDraft?.attachment == nil)
        fixture.panel.updateNewItemText("Save before going Home")
        fixture.panel.goHome()
        await fixture.panel.saveAndContinue()
        #expect(fixture.panel.newItemDraft == nil)
        #expect(fixture.panel.source == nil)
        #expect(fixture.panel.section == .all)
    }

    @Test("Labeled additions preserve each label without overwriting or duplicating another label")
    func labeledCaptureDeduplication() async throws {
        let fixture = try await AppFixture()
        let snapshot = NewItemImport.text("Same content")
        _ = try await fixture.capture.service.capture(snapshot, into: .collection, label: "First label")
        _ = try await fixture.capture.service.capture(snapshot, into: .collection, label: "Second label")
        _ = try await fixture.capture.service.capture(snapshot, into: .collection, label: "First label")
        let cards = try await fixture.capture.workspace.store.page(HistoryQuery(scope: .collection)).items
        #expect(cards.count == 2)
        #expect(Set(cards.compactMap(\.label)) == Set(["First label", "Second label"]))
    }

    @Test("Discarding a draft and returning Home cannot leave stale kind-filtered cards")
    func draftCleanupCannotCancelHomeRefresh() async throws {
        let fixture = try await AppFixture()
        _ = try await fixture.capture.workspace.store.insert(textInsertion("Text item"))
        let asset = try await fixture.capture.workspace.assetStore.importData(pngData(), kind: .image, fileExtension: "png")
        let image = try await fixture.capture.workspace.store.insert(imageInsertion(asset: asset.reference))
        fixture.panel.panelDidOpen()
        fixture.panel.setSection(.text)
        await fixture.panel.reload(.allClipboard)
        #expect(!fixture.panel.visibleCards.contains { $0.id == image.itemID })
        fixture.panel.setSource(.collection)
        await fixture.panel.createCollectionItem()
        fixture.panel.goHome()
        fixture.panel.discardAndContinue()
        // A concurrent hidden-shelf refresh reproduces the navigation race.
        await fixture.panel.reload(.collection)
        for _ in 0..<100 {
            if fixture.panel.visibleCards.contains(where: { $0.id == image.itemID }) { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(fixture.panel.section == .all)
        #expect(fixture.panel.source == nil)
        #expect(fixture.panel.visibleCards.contains { $0.id == image.itemID })
        fixture.panel.panelDidClose()
    }

    @Test("Add cannot create notes or trigger a connection from the Notes tab")
    func addCannotCreateAppleNotes() async throws {
        let fixture = try await AppFixture()
        fixture.panel.setSection(.notes)
        fixture.panel.addItem()
        #expect(fixture.panel.newItemDraft == nil)
        await fixture.notes.connect()
        #expect(fixture.notes.state.isConnected)
        fixture.panel.addItem()
        #expect(fixture.panel.newItemDraft == nil)
        #expect(NotesTabState.empty.isConnected)
        #expect(!NotesTabState.disconnected.isConnected)
        #expect(!NotesTabState.permissionDenied.isConnected)
    }

    @Test("Home asks before leaving an editor, preserves cancelled drafts, and saves before navigation")
    func homeProtectsDrafts() async throws {
        let fixture = try await AppFixture()
        fixture.panel.setSource(.collection)
        await fixture.panel.createCollectionItem()
        let id = try #require(fixture.panel.editor?.itemID)
        fixture.panel.updateEditor { $0.text = "Keep this manually written item" }
        fixture.panel.goHome()
        #expect(fixture.panel.showsSavePrompt)
        #expect(fixture.panel.editor?.text == "Keep this manually written item")
        fixture.panel.cancelPendingNavigation()
        #expect(fixture.panel.editor != nil)
        #expect(fixture.panel.source == .collection)
        fixture.panel.goHome()
        await fixture.panel.saveAndContinue()
        #expect(fixture.panel.editor == nil)
        #expect(fixture.panel.section == .all)
        #expect(fixture.panel.source == nil)
        #expect(try await fixture.capture.workspace.store.detail(for: id)?.plainText == "Keep this manually written item")
    }

    @Test("Failed saves block closing; discard explicitly completes the pending action")
    func failedSaveDoesNotCloseEditor() async throws {
        let fixture = try await AppFixture()
        await fixture.panel.createCollectionItem()
        var closed = false
        fixture.panel.requestLeavingEditor { closed = true }
        await fixture.panel.saveAndContinue()
        #expect(!closed)
        #expect(fixture.panel.editor != nil)
        #expect(fixture.panel.editor?.error != nil)
        fixture.panel.discardAndContinue()
        #expect(closed)
        #expect(fixture.panel.editor == nil)
    }

    @Test("Tabs close previews and Home clears the section and source")
    func headerNavigationClosesPreviews() async throws {
        let fixture = try await AppFixture()
        let inserted = try await fixture.capture.workspace.store.insert(textInsertion("Focused item"))
        await fixture.panel.openPreview(inserted.itemID)
        fixture.panel.setSection(.links)
        #expect(fixture.panel.preview == nil)
        fixture.panel.setSource(.pinned)
        fixture.panel.goHome()
        #expect(fixture.panel.section == .all)
        #expect(fixture.panel.source == nil)
        await fixture.notes.connect()
        let note = try #require(fixture.notes.notes.first)
        fixture.panel.setSection(.notes)
        await fixture.notes.preparePreview(note)
        fixture.panel.setSection(.images)
        #expect(fixture.notes.preview == nil)
    }

    @Test("Drag payload resolves while the main thread waits, preventing AppKit's synchronous drag deadlock")
    func dragPayloadDoesNotNeedMainActor() async throws {
        let fixture = try await AppFixture()
        let bytes = pngData(width: 32, height: 16)
        let asset = try await fixture.capture.workspace.assetStore.importData(bytes, kind: .image, fileExtension: "png")
        let inserted = try await fixture.capture.workspace.store.insert(imageInsertion(asset: asset.reference))
        let item = try #require(await fixture.capture.workspace.store.summary(for: inserted.itemID))
        let provider = CardDrag.provider(for: fixture.panel.dragSource(for: item))
        let completed = DispatchSemaphore(value: 0)
        let result = DragPayloadResult()
        provider.loadFileRepresentation(forTypeIdentifier: "public.file-url") { url, error in
            if let url, error == nil { result.set(try? Data(contentsOf: url)) }
            completed.signal()
        }
        // AppKit blocks the UI thread in precisely this way. A UI-isolated loader
        // cannot finish until this wait times out; a background loader finishes now.
        #expect(waitForDragCompletion(completed))
        #expect(result.value == bytes)
    }

    @Test("Notes copy selects the card and drags its full text without the main actor")
    func notesCopyAndDragUseFullBody() async throws {
        let fixture = try await AppFixture()
        await fixture.notes.connect()
        let note = try #require(fixture.notes.notes.first)
        #expect(await fixture.notes.copyText(of: note))
        #expect(fixture.notes.selection == note.id)
        #expect(fixture.notes.pasteTarget?.id == note.id)
        let provider = fixture.notes.dragProvider(for: note)
        let completed = DispatchSemaphore(value: 0)
        let result = DragPayloadResult()
        provider.loadDataRepresentation(forTypeIdentifier: "public.utf8-plain-text") { data, _ in
            result.set(data)
            completed.signal()
        }
        #expect(waitForDragCompletion(completed))
        #expect(String(data: try #require(result.value), encoding: .utf8) == "Body 2")
    }

    @Test("Maximised image previews load a complete image before ending the loading state")
    func maximisedImageHasDecodedContent() async throws {
        let fixture = try await AppFixture()
        let asset = try await fixture.capture.workspace.assetStore.importData(pngData(width: 120, height: 480), kind: .image, fileExtension: "png")
        let inserted = try await fixture.capture.workspace.store.insert(imageInsertion(asset: asset.reference))
        await fixture.panel.openPreview(inserted.itemID)
        #expect(fixture.panel.preview?.isLoading == false)
        #expect(fixture.panel.preview?.error == nil)
        #expect(fixture.panel.preview?.image?.width == 120)
        #expect(fixture.panel.preview?.image?.height == 480)
    }

    @Test("Automatic Notes sync discovers additions and deletions without refresh")
    func automaticNotesAddAndDelete() async throws {
        let runner = FakeNotesRunner.sample()
        let fixture = try await AppFixture(runner: runner, syncInterval: .milliseconds(20))
        await fixture.notes.connect()
        fixture.notes.setVisible(true)
        defer { fixture.notes.setVisible(false) }
        await runner.setSummary(NotesFixtures.summary(9, title: "Automatically added"))
        await runner.setContents([NotesFixtures.noteID(9): NotesFixtures.content(9)])
        for _ in 0..<100 {
            if fixture.notes.notes.contains(where: { $0.id == NotesFixtures.noteID(9) }) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(fixture.notes.notes.contains { $0.id == NotesFixtures.noteID(9) })
        let deleted = try #require(fixture.notes.notes.first { $0.id == NotesFixtures.noteID(9) })
        await fixture.notes.preparePreview(deleted)
        fixture.notes.searchText = "Automatically added"
        await fixture.notes.synchronizeIfNeeded()
        // Search is debounced independently of the periodic sync.
        for _ in 0..<100 {
            if fixture.notes.filteredNotes.map(\.id) == [deleted.id] { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(fixture.notes.filteredNotes.map(\.id) == [deleted.id])
        await runner.setSummaries([NotesFixtures.folderID: []])
        for _ in 0..<100 {
            if fixture.notes.state == .empty { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(fixture.notes.notes.isEmpty)
        #expect(fixture.notes.filteredNotes.isEmpty)
        #expect(fixture.notes.state == .empty)
        #expect(fixture.notes.preview == nil)
        // An empty folder must keep syncing so the next note appears too.
        fixture.notes.searchText = ""
        await runner.setSummary(NotesFixtures.summary(10))
        await runner.setContents([NotesFixtures.noteID(10): NotesFixtures.content(10)])
        for _ in 0..<100 {
            if fixture.notes.notes.count == 1 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(fixture.notes.notes.first?.id == NotesFixtures.noteID(10))
        #expect(fixture.notes.state == .loaded)
    }

    @Test("Quiet sync updates search after external edits and does not reread unchanged bodies")
    func notesSyncUpdatesSearchIncrementally() async throws {
        let runner = FakeNotesRunner.sample()
        let fixture = try await AppFixture(runner: runner)
        await fixture.notes.connect()
        fixture.notes.setVisible(true)
        defer { fixture.notes.setVisible(false) }
        let reads = await runner.callCount("contents")
        await fixture.notes.synchronizeIfNeeded()
        #expect(await runner.callCount("contents") == reads)
        fixture.notes.searchText = "Changed externally"
        await runner.setContents([NotesFixtures.noteID(1): NotesFixtures.content(1, text: "Changed externally")])
        await runner.setSummary(NotesFixtures.summary(1, date: NotesFixtures.baseDate.addingTimeInterval(500)))
        await fixture.notes.synchronizeIfNeeded()
        #expect(fixture.notes.filteredNotes.map(\.id) == [NotesFixtures.noteID(1)])
        #expect(fixture.notes.notes.first?.excerpt.contains("Changed externally") == true)
        #expect(await runner.callCount("contents") == reads + 1)
    }

    @Test("Notes sync pauses while hidden and resumes on return")
    func notesSyncVisibilityAndDraft() async throws {
        let runner = FakeNotesRunner.sample()
        let fixture = try await AppFixture(runner: runner)
        await fixture.notes.connect()
        let calls = await runner.callCount("summaries")
        await fixture.notes.synchronizeIfNeeded()
        #expect(await runner.callCount("summaries") == calls)
        fixture.notes.setVisible(true)
        defer { fixture.notes.setVisible(false) }
        await fixture.notes.synchronizeIfNeeded()
        #expect(await runner.callCount("summaries") > calls)
        fixture.notes.setVisible(false)
        let paused = await runner.callCount("summaries")
        await fixture.notes.synchronizeIfNeeded()
        #expect(await runner.callCount("summaries") == paused)
    }

    @Test("Editor text uses an adaptive foreground in both dark and light appearance")
    func editorTextContrast() throws {
        let document = RichTextDocument(runs: [.init(text: "Readable", traits: [.bold, .underline])])
        let attributed = RichTextCoding.attributedString(from: document)
        let color = try #require(attributed.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor)
        let dark = try #require(NSAppearance(named: .darkAqua))
        let light = try #require(NSAppearance(named: .aqua))
        var darkBrightness: CGFloat = 0
        var lightBrightness: CGFloat = 1
        dark.performAsCurrentDrawingAppearance { darkBrightness = color.usingColorSpace(.deviceRGB)?.brightnessComponent ?? 0 }
        light.performAsCurrentDrawingAppearance { lightBrightness = color.usingColorSpace(.deviceRGB)?.brightnessComponent ?? 1 }
        #expect(darkBrightness > 0.7)
        #expect(lightBrightness < 0.3)
        #expect(RichTextCoding.document(from: attributed).runs.first?.traits == [.bold, .underline])
    }
    @Test("A slow note preview cannot replace a newer note preview")
    func newestNotePreviewWins() async throws {
        let runner = FakeNotesRunner.sample()
        let fixture = try await AppFixture(runner: runner)
        await fixture.notes.connect()
        let first = try #require(fixture.notes.notes.first { $0.id == NotesFixtures.noteID(1) })
        let second = try #require(fixture.notes.notes.first { $0.id == NotesFixtures.noteID(2) })
        await runner.setContentReadDelay(.milliseconds(150), for: first.id)
        let slow = Task { await fixture.notes.preparePreview(first) }
        for _ in 0..<100 {
            if fixture.notes.preview?.id == first.id { break }
            await Task.yield()
        }
        await fixture.notes.preparePreview(second)
        await slow.value
        #expect(fixture.notes.preview?.id == second.id)
        #expect(fixture.notes.preview?.note?.id == second.id)
        #expect(fixture.notes.preview?.isLoading == false)
    }

    @Test("Cancelling a debounced search releases its pending request")
    func cancelledSearchReleasesRequest() async throws {
        let workspace = try TempWorkspace()
        let controller = ClipboardSearchController(store: workspace.store, debounceInterval: .seconds(30))
        let token = await controller.submit(HistoryQuery(text: "cancel"))
        let request = Task { try await controller.results(for: token) }
        request.cancel()
        do {
            _ = try await request.value
            Issue.record("Expected cancellation")
        } catch is CancellationError {
            #expect(await controller.pendingRequestCount == 0)
        }
    }
    @Test("Quit has a real deadline even when a persistence operation ignores cancellation")
    func shutdownDeadline() async {
        let started = ContinuousClock.now
        await GracefulShutdown.wait(timeout: .milliseconds(20)) {
            await withCheckedContinuation { continuation in
                DispatchQueue.global().asyncAfter(deadline: .now() + 0.4) {
                    continuation.resume()
                }
            }
        }
        #expect(started.duration(to: .now) < .milliseconds(300))
    }

    @Test("A completed shutdown does not wait out its grace period")
    func promptShutdown() async {
        let started = ContinuousClock.now
        await GracefulShutdown.wait(timeout: .seconds(10)) {}
        #expect(started.duration(to: .now) < .seconds(1))
    }
    @Test("The notched outline stays inside its window, including its bottom corners")
    func notchedOutlineBounds() {
        let rect = CGRect(x: 0, y: 0, width: 880, height: 592)
        let outline = PanelOutline(cornerRadius: 16, attachment: PanelAttachment(neckWidth: 200, neckHeight: 32))
        let path = outline.path(in: rect)
        #expect(path.boundingRect.maxY <= rect.maxY)
        #expect(path.contains(CGPoint(x: 440, y: 10)))
        #expect(path.contains(CGPoint(x: 440, y: 580)))
        #expect(!path.contains(CGPoint(x: 1, y: 591)))
    }

    @Test("UI previews evict old entries instead of retaining every scrolled card")
    func previewEntryBudget() async throws {
        let harness = try await CaptureHarness()
        try await harness.workspace.store.beginSession()
        let cache = PreviewStore(store: harness.workspace.store, processor: harness.processor, entryLimit: 3)
        var first: PreviewStore.Entry?
        for index in 0..<12 {
            let item = try await harness.workspace.store.insert(richTextInsertion("Preview \(index)"))
            if index == 0 { first = cache.entry(for: item.summary.id) }
            await cache.load(item.summary)
        }
        #expect(cache.cachedEntryCount <= 3)
        #expect(first?.payload == nil)
    }

    @Test("Loading another card does not invalidate an unrelated card preview")
    func independentPreviewObservation() async throws {
        let harness = try await CaptureHarness()
        try await harness.workspace.store.beginSession()
        let cache = PreviewStore(store: harness.workspace.store, processor: harness.processor)
        let first = try await harness.workspace.store.insert(richTextInsertion("First"))
        let second = try await harness.workspace.store.insert(richTextInsertion("Second"))
        await cache.load(first.summary)
        let changes = NotificationCounter()
        let subscription = cache.entry(for: first.summary.id).objectWillChange.sink { changes.increment() }
        await cache.load(second.summary)
        #expect(changes.value == 0)
        withExtendedLifetime(subscription) {}
    }

    @Test("Editing preserves card identity but replaces cached preview content")
    func editedPreviewUpdates() async throws {
        let harness = try await CaptureHarness()
        try await harness.workspace.store.beginSession()
        let cache = PreviewStore(store: harness.workspace.store, processor: harness.processor)
        let inserted = try await harness.workspace.store.insert(richTextInsertion("Before edit"))
        let entry = cache.entry(for: inserted.summary.id)
        await cache.load(inserted.summary)
        #expect(entry.richText?.plainText == "Before edit")
        _ = try await harness.workspace.store.edit(.text("After edit"), for: inserted.summary.id)
        let updated = try #require(await harness.workspace.store.summary(for: inserted.summary.id))
        cache.invalidate(updated.id)
        await cache.load(updated)
        #expect(cache.entry(for: updated.id) === entry)
        #expect(entry.richText?.plainText == "After edit")
    }

    @Test("UI image previews respect their decoded byte budget")
    func imagePreviewByteBudget() async throws {
        let harness = try await CaptureHarness()
        try await harness.workspace.store.beginSession()
        let cache = PreviewStore(store: harness.workspace.store, processor: harness.processor, byteLimit: 1)
        let snapshot = PasteboardSnapshot(changeCount: 1, items: [imageItem(pngData(width: 32, height: 32))])
        let insertion = try await harness.processor.insertion(from: snapshot, origin: .external(changeCount: 1))
        let item = try await harness.workspace.store.insert(insertion)
        await cache.load(item.summary)
        #expect(cache.cachedByteCount <= 1)
        #expect(cache.image(for: item.summary.id) == nil)
    }

    @Test("Cancelling a typing search never leaves an error or stuck loading state")
    func searchCancellationIsNotAnError() async throws {
        let fixture = try await AppFixture(debounce: .seconds(30))
        try await fixture.capture.workspace.store.beginSession()
        _ = try await fixture.capture.workspace.store.insert(textInsertion("Searchable"))
        fixture.panel.panelDidOpen()
        await fixture.panel.reload(.allClipboard)
        fixture.panel.queryText = "Searchable"
        // Wait for the typing request to enter its debounce, then cancel by closing.
        for _ in 0..<100 {
            if await fixture.search.pendingRequestCount > 0 { break }
            await Task.yield()
        }
        fixture.panel.panelDidClose()
        for _ in 0..<100 {
            if !fixture.panel.clipboard.isLoading { break }
            await Task.yield()
        }
        #expect(fixture.panel.clipboard.error == nil)
        #expect(!fixture.panel.clipboard.isLoading)
    }

    @Test("Notes cards are not silently truncated after the first 180 notes")
    func allNotesAreAvailable() async throws {
        let summaries = (1...205).map { NotesFixtures.summary($0) }
        let contents = Dictionary(uniqueKeysWithValues: (1...205).map { (NotesFixtures.noteID($0), NotesFixtures.content($0)) })
        let runner = FakeNotesRunner(summaries: [NotesFixtures.folderID: summaries], contents: contents)
        let fixture = try await AppFixture(runner: runner)
        await fixture.notes.connect()
        #expect(fixture.notes.notes.count == 205)
    }

    @Test("Notes search finds text beyond a card's excerpt")
    func notesSearchesWholeBody() async throws {
        let body = "A short opening. " + String(repeating: "Ordinary context. ", count: 80) + "unique-deep-match"
        let runner = FakeNotesRunner(
            summaries: [NotesFixtures.folderID: [NotesFixtures.summary(1), NotesFixtures.summary(2)]],
            contents: [NotesFixtures.noteID(1): NotesFixtures.content(1, text: body), NotesFixtures.noteID(2): NotesFixtures.content(2)]
        )
        let fixture = try await AppFixture(runner: runner)
        await fixture.notes.connect()
        #expect(fixture.notes.notes.allSatisfy { !$0.excerpt.contains("unique-deep-match") })
        #expect(fixture.notes.filteredNotes.count == 2)
        fixture.notes.searchText = "unique-deep-match"
        for _ in 0..<100 {
            if fixture.notes.filteredNotes.count == 1 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(fixture.notes.filteredNotes.map(\.id) == [NotesFixtures.noteID(1)])
    }
    @Test("Notes discovers a new local account, nested folders and filters all account sources")
    func notesReadsAllAccountsAndFiltersSources() async throws {
        let fixture = try await AppFixture()
        let application = FakeNotesScriptingApplication.sample()
        let bridge = ScriptingBridgeNotesRunner { _ in application }
        let permission = FixedPermissionChecker(.authorized)
        let model = NotesTabViewModel(client: NotesAutomationClient(runner: bridge, permission: permission),
                                      service: fixture.capture.service, settings: fixture.settings)
        #expect(permission.requestCount == 0)
        await model.connect()
        #expect(model.filteredNotes.count == 3)
        let local = FakeNotesScriptingAccount(id: "LocalAccount", name: "Sur mon Mac")
        let parent = FakeNotesScriptingFolder(id: "local-folder", name: "Local")
        let nested = FakeNotesScriptingFolder(id: "local-child", name: "Nested")
        nested.folderListingError = NSError(domain: NSOSStatusErrorDomain, code: Int(AppleEventStatus.noSuchObject))
        let note = FakeNotesScriptingNote(id: NotesFixtures.noteID(101).rawValue, title: "Local note",
                                          plainText: "only local needle", bodyHTML: "<div>only local needle</div>", date: NotesFixtures.baseDate)
        nested.notesResult = [note]
        parent.foldersResult = [nested]
        local.foldersResult = [parent, nested] // Some scripting lists repeat descendants.
        local.defaultFolderResult = parent
        application.accountsResult.append(local)
        await model.refresh(silently: true)
        #expect(model.accounts.count == 2)
        #expect(model.accounts.last?.location == .onMyMac)
        #expect(model.folders.filter { $0.accountID.rawValue == "LocalAccount" }.count == 2)
        #expect(model.filteredNotes.count == 4)

        model.sourceFilter = .onMyMac
        #expect(model.filteredNotes.map(\.id) == [NotesFixtures.noteID(101)])
        model.sourceFilter = .iCloud
        #expect(model.filteredNotes.count == 3)
        model.searchText = "local needle"
        model.sourceFilter = .all
        model.sourceFilter = .onMyMac
        for _ in 0..<200 {
            if model.filteredNotes.map(\.id) == [NotesFixtures.noteID(101)] { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(model.filteredNotes.map(\.id) == [NotesFixtures.noteID(101)])
        model.sourceFilter = .iCloud
        for _ in 0..<200 {
            if !model.isBusy && model.filteredNotes.isEmpty { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(model.filteredNotes.isEmpty)
        #expect(NotesSourceFilter.all.includes(NotesAccount(id: .init(rawValue: "gmail"), name: "Gmail")))
        #expect(!NotesSourceFilter.iCloud.includes(NotesAccount(id: .init(rawValue: "gmail"), name: "Gmail")))
        #expect(permission.requestCount == 1)
    }

    @Test("Read-only Notes previews do not require saving before navigation")
    func notesNavigationIsReadOnly() async throws {
        let fixture = try await AppFixture()
        await fixture.notes.connect()
        fixture.panel.setSection(.notes)
        let note = try #require(fixture.notes.notes.first)
        await fixture.notes.preparePreview(note)
        #expect(await fixture.notes.copyText(of: note))
        fixture.panel.goHome()
        #expect(!fixture.panel.showsSavePrompt)
        #expect(fixture.notes.preview == nil)
        #expect(fixture.panel.section == .all)
    }

    @Test("Menu tracking dismisses pending tooltips and prevents tooltips over actions")
    func actionMenusDismissTooltips() async throws {
        let presenter = KopiTooltipPresenter.shared
        let menu = NSMenu(title: "Note actions")
        defer {
            NotificationCenter.default.post(name: NSMenu.didEndTrackingNotification, object: menu)
            presenter.hideAll()
        }
        presenter.request("Note actions", owner: UUID())
        #expect(presenter.hasPendingRequest)
        NotificationCenter.default.post(name: NSMenu.didBeginTrackingNotification, object: menu)
        #expect(presenter.isMenuTracking)
        #expect(!presenter.hasPendingRequest)
        presenter.request("Note actions", owner: UUID())
        try await Task.sleep(for: .milliseconds(150))
        #expect(!presenter.hasPendingRequest)
        #expect(!presenter.isVisible)
        NotificationCenter.default.post(name: NSMenu.didEndTrackingNotification, object: menu)
        #expect(!presenter.isMenuTracking)
        presenter.request("Note actions", owner: UUID())
        #expect(presenter.hasPendingRequest)
        presenter.hideAll()
        try await Task.sleep(for: .milliseconds(150))
        #expect(!presenter.isVisible)
        #expect(KopiTooltipPresenter.delay == .milliseconds(100))
    }

    @Test("Top-center hover works on notchless displays in global coordinates")
    func topCenterHoverOnAnyDisplay() {
        for frame in [CGRect(x: 0, y: 0, width: 1440, height: 900), CGRect(x: -1920, y: 400, width: 1920, height: 1080)] {
            let display = PanelDisplayGeometry(frame: frame, visibleFrame: frame)
            let target = PanelGeometry.triggerRect(for: display)
            #expect(target.width == 180)
            #expect(target.maxY == frame.maxY)
            #expect(target.midX == frame.midX)
            var hover = NotchHoverState()
            let point = CGPoint(x: frame.midX, y: frame.maxY)
            #expect(hover.update(point: point, targets: [target], now: 1, delay: 0.3) == 1.3)
            #expect(hover.update(point: CGPoint(x: frame.midX, y: frame.maxY - 11), targets: [target], now: 2, delay: 0.3) == nil)
            #expect(hover.update(point: point, targets: [target], now: 3, delay: 0.3) == 3.3)
        }
    }
}

@MainActor
private struct AppFixture {
    let capture: CaptureHarness
    let search: ClipboardSearchController
    let notes: NotesTabViewModel
    let panel: PanelViewModel
    let settings: KopiSettingsStore

    init(runner: FakeNotesRunner = FakeNotesRunner.sample(), debounce: Duration = .zero, syncInterval: Duration = .seconds(3)) async throws {
        let capture = try await CaptureHarness()
        let defaults = try #require(UserDefaults(suiteName: "kopi-app-tests-\(UUID().uuidString)"))
        let settings = KopiSettingsStore(defaults: defaults)
        self.settings = settings
        let notes = NotesTabViewModel(
            client: NotesAutomationClient(runner: runner, permission: FixedPermissionChecker(.authorized)),
            service: capture.service,
            settings: settings,
            syncInterval: syncInterval
        )
        let search = ClipboardSearchController(store: capture.workspace.store, debounceInterval: debounce)
        self.capture = capture
        self.search = search
        self.notes = notes
        self.panel = PanelViewModel(
            store: capture.workspace.store,
            service: capture.service,
            search: search,
            captureStatus: capture.status,
            settings: settings,
            notes: notes,
            previews: PreviewStore(store: capture.workspace.store, processor: capture.processor)
        )
    }
}

private final class NotificationCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func increment() { lock.withLock { count += 1 } }
    var value: Int { lock.withLock { count } }
}

private final class DragPayloadResult: @unchecked Sendable {
    private let lock = NSLock()
    private var data: Data?
    func set(_ value: Data?) { lock.withLock { data = value } }
    var value: Data? { lock.withLock { data } }
}

// Intentionally synchronous to reproduce AppKit's promise-data wait on the UI thread.
private func waitForDragCompletion(_ semaphore: DispatchSemaphore) -> Bool {
    semaphore.wait(timeout: .now() + 2) == .success
}
