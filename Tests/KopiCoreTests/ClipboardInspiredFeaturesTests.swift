import Foundation
import Testing
@testable import KopiCore
@testable import Kopi

@Suite("Clipboard workflow additions")
struct ClipboardInspiredFeaturesTests {
    @Test("Previous app identities are displayed and filtered as Kopi")
    func previousBrandIdentity() {
        #expect(SourceAppInfo.canonicalBundleIdentifier(LegacyAppIdentity.bundleIdentifier) == "com.kopi.app")
        #expect(SourceAppInfo(bundleIdentifier: LegacyAppIdentity.bundleIdentifier, name: LegacyAppIdentity.supportDirectoryName).kopiDisplayName == "Kopi")
    }

    @Test("Colors recognize explicit HEX and RGB formats without guessing ordinary text")
    func explicitColors() throws {
        #expect(ClipboardColor.parse(" #abc\n")?.hexString == "#AABBCC")
        #expect(ClipboardColor.parse("#abcd")?.hexString == "#AABBCCDD")
        #expect(ClipboardColor.parse("#5e7cf8")?.rgbString == "rgb(94, 124, 248)")
        #expect(ClipboardColor.parse("rgb(94, 124, 248)")?.hexString == "#5E7CF8")
        #expect(ClipboardColor.parse("RGBA(255, 0, 128, 0.5)")?.hexString == "#FF008080")
        #expect(ClipboardColor.parse("rgba(255, 0, 128, 0.5)")?.rgbString == "rgba(255, 0, 128, 0.5)")
        #expect(ClipboardColor.parse("#00000000")?.alpha == 0)
        for invalid in ["123456", "123,123,123", "See #ABC", "#ABC #DEF", "#12", "#GGGGGG",
                        "rgb(256,0,0)", "rgb(-1,0,0)", "rgb(1.5,0,0)", "rgb(1,2,)",
                        "rgba(1,2,3,NaN)", "rgba(1,2,3,1.1)", "rgb(1,2,3) trailing", String(repeating: "f", count: 1000)] {
            #expect(ClipboardColor.parse(invalid) == nil)
        }
    }

    @Test("App filtering combines with search, pagination, kinds, pins, and collection")
    func sourceAppQueries() async throws {
        let workspace = try TempWorkspace()
        var chromeIDs: [ClipboardItemID] = []
        for index in 0..<75 {
            var insertion = textInsertion("Design color \(index)")
            insertion.sourceApp = SourceAppInfo(bundleIdentifier: "com.google.Chrome", name: "Chrome")
            chromeIDs.append(try await workspace.store.insert(insertion).itemID)
        }
        var code = textInsertion("Design in code")
        code.sourceApp = SourceAppInfo(bundleIdentifier: "com.microsoft.VSCode", name: "Code")
        _ = try await workspace.store.insert(code)
        let first = try await workspace.store.page(HistoryQuery(text: "Design", sourceAppBundleIdentifier: "com.google.Chrome"))
        #expect(first.totalCount == 75)
        #expect(first.items.count == 60)
        let next = try #require(first.nextPage)
        let second = try await workspace.store.page(HistoryQuery(text: "Design", page: next, sourceAppBundleIdentifier: "com.google.Chrome"))
        #expect(second.items.count == 15)
        #expect(!second.hasMore)
        #expect(Set(first.items.map(\.id)).isDisjoint(with: Set(second.items.map(\.id))))
        #expect((first.items + second.items).allSatisfy { $0.sourceApp?.bundleIdentifier == "com.google.Chrome" })
        _ = try await workspace.store.setPinned(true, for: chromeIDs[0])
        let pinned = try await workspace.store.page(HistoryQuery(text: "De", scope: .pinned, filter: .text, sourceAppBundleIdentifier: "com.google.Chrome"))
        #expect(pinned.itemIDs == [chromeIDs[0]])
        let wrongKind = try await workspace.store.page(HistoryQuery(filter: .images, sourceAppBundleIdentifier: "com.google.Chrome"))
        #expect(wrongKind.totalCount == 0)
        var collected = textInsertion("Collected Design", destination: .collection)
        collected.sourceApp = code.sourceApp
        let collectionID = try await workspace.store.insert(collected).itemID
        let shelf = try await workspace.store.page(HistoryQuery(scope: .collection, sourceAppBundleIdentifier: "com.microsoft.VSCode"))
        #expect(shelf.itemIDs == [collectionID])
        let escaped = try await workspace.store.page(HistoryQuery(sourceAppBundleIdentifier: "' OR 1=1 --"))
        #expect(escaped.totalCount == 0)
    }

    @Test("The app menu covers all history and groups earlier Kopi identities")
    func sourceAppNamesAndRename() async throws {
        let workspace = try TempWorkspace()
        for (index, identifier) in ["com.velpy.app", "com.kopi.app", "com.example.other"].enumerated() {
            var insertion = textInsertion("Source \(index)")
            insertion.sourceApp = SourceAppInfo(bundleIdentifier: identifier, name: index == 1 ? "Kopi" : "Velpy")
            _ = try await workspace.store.insert(insertion)
        }
        let apps = try await workspace.store.sourceApplications()
        #expect(apps.count == 2)
        #expect(apps.first { $0.bundleIdentifier == "com.kopi.app" }?.name == "Kopi")
        #expect(apps.first { $0.bundleIdentifier == "com.example.other" }?.name == "Velpy")
        for identifier in ["com.velpy.app", "com.kopi.app"] {
            let page = try await workspace.store.page(HistoryQuery(sourceAppBundleIdentifier: identifier))
            #expect(page.totalCount == 2)
        }
    }

    @Test("Launch import is opt-in, imports once, and never guesses the previous source app")
    func startupImport() async throws {
        let harness = try await CaptureHarness()
        harness.pasteboard.copyText("Before launch")
        harness.frontmostApp.current = SourceAppInfo(bundleIdentifier: "com.apple.TextEdit", name: "TextEdit")
        await harness.service.start(captureExistingClipboard: true)
        let imported = await harness.service.tick()
        #expect(imported.summary?.excerpt == "Before launch")
        #expect(imported.summary?.sourceApp == nil)
        #expect(harness.frontmostApp.lookupCount == 0)
        _ = await harness.service.tick()
        #expect(harness.pasteboard.snapshotReadCount == 1)
        harness.pasteboard.copyText("After launch")
        let external = await harness.service.tick()
        #expect(external.summary?.sourceApp?.name == "TextEdit")
        #expect(try await harness.workspace.store.count() == 2)
    }

    @Test("Opting into launch import still respects pause and a newer external copy")
    func startupImportPauseAndNewCopy() async throws {
        let harness = try await CaptureHarness()
        harness.pasteboard.copyText("Before launch")
        await harness.service.setCapturePaused(true)
        await harness.service.start(captureExistingClipboard: true)
        _ = await harness.service.tick()
        #expect(harness.pasteboard.snapshotReadCount == 0)
        harness.frontmostApp.current = SourceAppInfo(bundleIdentifier: "com.example.editor", name: "Editor")
        harness.pasteboard.copyText("New copy while paused")
        await harness.service.setCapturePaused(false)
        let external = await harness.service.tick()
        #expect(external.summary?.sourceApp?.name == "Editor")
        #expect(external.summary?.excerpt == "New copy while paused")
        #expect(try await harness.workspace.store.count() == 1)
    }

    @Test("Startup import defaults off when older settings are loaded and persists when selected")
    func startupPreferenceCompatibility() throws {
        let old = try JSONDecoder().decode(KopiSettings.self, from: Data("{}".utf8))
        #expect(!old.capturesClipboardOnLaunch)
        var changed = old
        changed.capturesClipboardOnLaunch = true
        #expect(try JSONDecoder().decode(KopiSettings.self, from: JSONEncoder().encode(changed)) == changed)
        let oldQuery = Data("{\"text\":\"\",\"scope\":{\"allClipboard\":{}},\"kinds\":[],\"sort\":{\"recentlyCopied\":{}},\"page\":{\"offset\":0,\"limit\":60}}".utf8)
        #expect(try JSONDecoder().decode(HistoryQuery.self, from: oldQuery).sourceAppBundleIdentifier == nil)
    }

    @Test @MainActor func filtersResetSelectionAndHomeClearsTheAppWithoutDuplicatingColorCopies() async throws {
        let capture = try await CaptureHarness()
        let domain = "kopi-features-tests-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let settings = KopiSettingsStore(defaults: defaults)
        let notes = NotesTabViewModel(client: NotesAutomationClient(runner: FakeNotesRunner.sample(), permission: FixedPermissionChecker(.authorized)), service: capture.service, settings: settings)
        let panel = PanelViewModel(store: capture.workspace.store, service: capture.service,
            search: ClipboardSearchController(store: capture.workspace.store, debounceInterval: .zero), captureStatus: capture.status,
            settings: settings, notes: notes, previews: PreviewStore(store: capture.workspace.store, processor: capture.processor),
            passwords: PasswordsViewModel(vault: PasswordVault(url: capture.workspace.root.appendingPathComponent("passwords/vault.json"))))
        var insertion = textInsertion("#5E7CF8")
        insertion.sourceApp = SourceAppInfo(bundleIdentifier: "com.example.editor", name: "Editor")
        let colorID = try await capture.workspace.store.insert(insertion).itemID
        _ = try await capture.workspace.store.insert(textInsertion("Unattributed text"))
        await panel.warmUp()
        panel.selectForPaste(colorID)
        panel.setSourceApp("com.example.editor")
        await panel.reloadAll()
        #expect(panel.visibleCards.map(\.id) == [colorID])
        panel.goHome()
        await panel.reloadAll()
        #expect(panel.sourceAppBundleIdentifier == nil)
        #expect(panel.visibleCards.count == 2)

        await capture.service.start()
        #expect(await panel.copyColorValue("rgb(94, 124, 248)"))
        #expect(capture.pasteboard.writeRequests.last?.flavours.first?.string == "rgb(94, 124, 248)")
        _ = await capture.service.tick()
        #expect(try await capture.workspace.store.count() == 2)
        capture.pasteboard.copyText("A subsequent external copy")
        #expect(await capture.service.tick().summary != nil)

        panel.setSourceApp("com.example.editor")
        await panel.reloadAll()
        panel.addItem()
        panel.updateNewItemText("#00FF00")
        await panel.saveNewItem()
        await panel.reloadAll()
        #expect(panel.sourceAppBundleIdentifier == nil)
        #expect(panel.source == .collection)
        #expect(panel.visibleCards.contains { $0.excerpt == "#00FF00" })
    }
}
