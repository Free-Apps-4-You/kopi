import Foundation
import Testing

@testable import KopiCore

@Suite("Hotkey definition")
struct HotkeyTests {
    /// Carbon constants, repeated here so the mapping is checked against values
    /// rather than against the same constants the implementation uses.
    private enum Carbon {
        static let command: UInt32 = 256
        static let shift: UInt32 = 512
        static let option: UInt32 = 2048
        static let control: UInt32 = 4096
    }

    @Test("The default shortcut is ⌥⌘V and maps to the Carbon modifier mask")
    func defaultShortcut() {
        let hotkey = HotkeyDefinition.default
        #expect(hotkey.displayString == "⌥⌘V")
        #expect(hotkey.keyCode == 9)
        #expect(hotkey.isValid)
        #expect(hotkey.modifiers.carbonValue == Carbon.command | Carbon.option)
    }

    @Test("Carbon modifiers cover every modifier key")
    func carbonModifiers() {
        #expect(HotkeyModifiers.command.carbonValue == Carbon.command)
        #expect(HotkeyModifiers.shift.carbonValue == Carbon.shift)
        #expect(HotkeyModifiers.option.carbonValue == Carbon.option)
        #expect(HotkeyModifiers.control.carbonValue == Carbon.control)
        #expect(HotkeyModifiers([.command, .option]).carbonValue == Carbon.command | Carbon.option)
        #expect(HotkeyModifiers([.control, .shift, .command]).carbonValue == Carbon.control | Carbon.shift | Carbon.command)
        #expect(HotkeyModifiers([]).carbonValue == 0)
    }

    @Test("Modifiers print in the order macOS writes them")
    func modifierDisplay() {
        #expect(HotkeyModifiers([.control, .option, .shift, .command]).displayString == "⌃⌥⇧⌘")
        #expect(HotkeyModifiers([.shift, .command]).displayString == "⇧⌘")
        #expect(HotkeyModifiers([]).displayString.isEmpty)
    }

    @Test("A press becomes a shortcut only with a modifier and a real key")
    func captureValidation() {
        #expect(HotkeyDefinition.captured(keyCode: 9, modifiers: [.command, .option], characters: "v")
            == HotkeyDefinition(keyCode: 9, modifiers: [.command, .option], keyLabel: "V"))
        #expect(HotkeyDefinition.captured(keyCode: 9, modifiers: [], characters: "v") == nil)
        #expect(HotkeyDefinition.captured(keyCode: 55, modifiers: [.command], characters: "") == nil)
        #expect(HotkeyDefinition.captured(keyCode: 49, modifiers: [.control], characters: " ")?.keyLabel == "Space")
        #expect(HotkeyDefinition.captured(keyCode: 122, modifiers: [.option], characters: "")?.keyLabel == "F1")
    }

    @Test("A shortcut without a modifier is rejected")
    func validity() {
        #expect(HotkeyDefinition(keyCode: 9, modifiers: [], keyLabel: "V").isValid == false)
        #expect(HotkeyDefinition(keyCode: 56, modifiers: [.command], keyLabel: "").isValid == false)
        #expect(HotkeyDefinition(keyCode: 11, modifiers: [.command], keyLabel: "B").isValid)
    }
}

@Suite("Panel key bindings")
struct PanelKeyBindingsTests {
    @Test("Return copies the card in view and Escape dismisses")
    func pasteAndDismiss() {
        let returnPress = PanelKeyEvent(keyCode: PanelKeyBindings.returnKeyCode, hasVisibleCard: true, visibleCardCount: 4)
        #expect(PanelKeyBindings.action(for: returnPress) == .copySelection)
        #expect(PanelKeyBindings.action(for: PanelKeyEvent(keyCode: PanelKeyBindings.returnKeyCode)) == .none)
        #expect(PanelKeyBindings.action(for: PanelKeyEvent(keyCode: PanelKeyBindings.keypadEnterKeyCode, hasVisibleCard: true)) == .copySelection)
        #expect(PanelKeyBindings.action(for: PanelKeyEvent(keyCode: PanelKeyBindings.escapeKeyCode)) == .dismiss)
    }

    @Test("Return also copies while the search field has the focus")
    func returnWhileSearching() {
        let press = PanelKeyEvent(
            keyCode: PanelKeyBindings.returnKeyCode,
            isTextEditing: true,
            hasVisibleCard: true,
            visibleCardCount: 3
        )
        #expect(PanelKeyBindings.action(for: press) == .copySelection)
    }

    @Test("Command shortcuts copy, edit, pin and copy numbered cards")
    func commandShortcuts() {
        func command(_ keyCode: UInt16) -> PanelKeyEvent {
            PanelKeyEvent(keyCode: keyCode, modifiers: [.command], hasVisibleCard: true, visibleCardCount: 9)
        }
        #expect(PanelKeyBindings.action(for: command(PanelKeyBindings.cKeyCode)) == .copySelection)
        #expect(PanelKeyBindings.action(for: command(PanelKeyBindings.eKeyCode)) == .editSelection)
        #expect(PanelKeyBindings.action(for: command(PanelKeyBindings.pKeyCode)) == .togglePin)
        #expect(PanelKeyBindings.action(for: command(PanelKeyBindings.digitKeyCodes[0])) == .copyVisibleCard(1))
        #expect(PanelKeyBindings.action(for: command(PanelKeyBindings.digitKeyCodes[8])) == .copyVisibleCard(9))
        // Nothing is pasted for a number past the last visible card.
        #expect(PanelKeyBindings.action(for: PanelKeyEvent(
            keyCode: PanelKeyBindings.digitKeyCodes[3],
            modifiers: [.command],
            hasVisibleCard: true,
            visibleCardCount: 2
        )) == .none)
        // A shortcut with more than the command key is left alone.
        #expect(PanelKeyBindings.action(for: PanelKeyEvent(
            keyCode: PanelKeyBindings.cKeyCode,
            modifiers: [.command, .shift],
            hasVisibleCard: true
        )) == .none)
    }

    @Test("⌘V collects only on the collection shelf, and never while typing")
    func collectShortcut() {
        #expect(PanelKeyBindings.vKeyCode == 9)
        func collect(_ event: PanelKeyEvent) -> PanelKeyAction {
            PanelKeyBindings.action(for: event)
        }
        #expect(collect(PanelKeyEvent(
            keyCode: PanelKeyBindings.vKeyCode,
            modifiers: [.command],
            isCollectionShown: true
        )) == .pasteIntoCollection)

        // Anywhere else the key belongs to whatever the user is doing.
        #expect(collect(PanelKeyEvent(keyCode: PanelKeyBindings.vKeyCode, modifiers: [.command])) == .none)
        #expect(collect(PanelKeyEvent(
            keyCode: PanelKeyBindings.vKeyCode,
            modifiers: [.command],
            isTextEditing: true,
            isCollectionShown: true
        )) == .none)
        #expect(collect(PanelKeyEvent(
            keyCode: PanelKeyBindings.vKeyCode,
            modifiers: [.command],
            presentation: .editor,
            isCollectionShown: true
        )) == .none)
        #expect(collect(PanelKeyEvent(
            keyCode: PanelKeyBindings.vKeyCode,
            modifiers: [.command, .shift],
            isCollectionShown: true
        )) == .none)
    }

    @Test("Space previews only when the user is not typing")
    func spacePreview() {
        #expect(PanelKeyBindings.action(for: PanelKeyEvent(
            keyCode: PanelKeyBindings.spaceKeyCode,
            hasVisibleCard: true
        )) == .togglePreview)
        #expect(PanelKeyBindings.action(for: PanelKeyEvent(
            keyCode: PanelKeyBindings.spaceKeyCode,
            isTextEditing: true,
            hasVisibleCard: true
        )) == .none)
        #expect(PanelKeyBindings.action(for: PanelKeyEvent(keyCode: PanelKeyBindings.spaceKeyCode)) == .none)
    }

    @Test("An open editor owns the keyboard except for Escape")
    func editorOwnsInput() {
        #expect(PanelKeyBindings.action(for: PanelKeyEvent(
            keyCode: PanelKeyBindings.escapeKeyCode,
            presentation: .editor,
            isTextEditing: true
        )) == .cancelEditor)
        #expect(PanelKeyBindings.action(for: PanelKeyEvent(
            keyCode: PanelKeyBindings.returnKeyCode,
            presentation: .editor,
            isTextEditing: true,
            hasVisibleCard: true
        )) == .none)
        #expect(PanelKeyBindings.action(for: PanelKeyEvent(
            keyCode: PanelKeyBindings.cKeyCode,
            modifiers: [.command],
            presentation: .editor,
            isTextEditing: true,
            hasVisibleCard: true
        )) == .none)
    }

    @Test("A preview closes with Escape and copies with Return")
    func previewKeys() {
        #expect(PanelKeyBindings.action(for: PanelKeyEvent(
            keyCode: PanelKeyBindings.escapeKeyCode,
            presentation: .preview
        )) == .closePreview)
        #expect(PanelKeyBindings.action(for: PanelKeyEvent(
            keyCode: PanelKeyBindings.returnKeyCode,
            presentation: .preview,
            hasVisibleCard: true
        )) == .copySelection)
    }

    @Test("Unrelated keys stay with the text input")
    func unhandledKeys() {
        #expect(PanelKeyBindings.action(for: PanelKeyEvent(keyCode: 0, characters: "a", isTextEditing: true)) == .none)
        #expect(PanelKeyBindings.action(for: PanelKeyEvent(keyCode: 48)) == .none)
    }
}

@Suite("Settings store")
@MainActor
struct KopiSettingsStoreTests {
    /// Suite with a unique name, removed again when the test ends.
    private func withDefaults(_ body: (UserDefaults) -> Void) {
        let name = "kopi.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name) ?? .standard
        defer { defaults.removePersistentDomain(forName: name) }
        body(defaults)
    }

    @Test("Defaults match the design")
    func defaults() {
        withDefaults { defaults in
            let store = KopiSettingsStore(defaults: defaults)
            #expect(store.settings == KopiSettings())
            #expect(store.settings.hotkey.displayString == "⌥⌘V")
            #expect(store.settings.activeHotkey == HotkeyDefinition.default)
            #expect(store.settings.hoverReveal.isEnabled)
            #expect(store.settings.hoverReveal.delay == 0.35)
            #expect(store.settings.dismissesOnOutsideClick)
            #expect(store.settings.appearance == .system)
            #expect(store.settings.excludedApplications.isEmpty)
            #expect(store.settings.launchAtLogin == false)
        }
    }

    @Test("Changes are written to UserDefaults and read back")
    func roundTrip() {
        withDefaults { defaults in
            let store = KopiSettingsStore(defaults: defaults)
            store.update { settings in
                settings.hotkey = HotkeyDefinition(keyCode: 11, modifiers: [.command, .shift], keyLabel: "B")
                settings.isHotkeyEnabled = false
                settings.hoverReveal = HoverReveal(isEnabled: false, delay: 0.75)
                settings.dismissesOnOutsideClick = false
                settings.appearance = .dark
                settings.animationSpeed = .relaxed
                settings.usesCompactCards = true
                settings.isCapturePaused = true
                settings.excludedApplications = ["com.apple.keychainaccess"]
                settings.notesFolderIDs = ["folder"]
                settings.launchAtLogin = true
            }

            let reloaded = KopiSettingsStore(defaults: defaults)
            #expect(reloaded.settings == store.settings)
            #expect(reloaded.settings.hotkey.displayString == "⇧⌘B")
            #expect(reloaded.settings.activeHotkey == nil)
            #expect(reloaded.settings.hoverReveal.delay == 0.75)
            #expect(reloaded.settings.dismissesOnOutsideClick == false)
            #expect(reloaded.settings.appearance == .dark)
            #expect(reloaded.settings.exclusion.bundleIdentifiers == ["com.apple.keychainaccess"])
            #expect(reloaded.settings.notesFolderIDs == ["folder"])

            reloaded.reset()
            #expect(KopiSettingsStore(defaults: defaults).settings == KopiSettings())
        }
    }

    @Test("Hover delay is clamped to the range the UI offers")
    func hoverDelayClamping() {
        #expect(HoverReveal(isEnabled: true, delay: 10).delay == HoverReveal.delayRange.upperBound)
        #expect(HoverReveal(isEnabled: true, delay: 0).delay == HoverReveal.delayRange.lowerBound)
        #expect(HoverReveal(isEnabled: true, delay: 0.5).dwell == .milliseconds(500))
    }

    @Test("A stored value from an earlier build keeps working")
    func forwardCompatibleDecoding() throws {
        let payload = Data(#"{"appearance":"light","excludedApplications":["com.example.editor"]}"#.utf8)
        let decoded = try JSONDecoder().decode(KopiSettings.self, from: payload)
        #expect(decoded.appearance == .light)
        #expect(decoded.excludedApplications == ["com.example.editor"])
        #expect(decoded.hotkey == .default)
        #expect(decoded.hoverReveal == .default)
        #expect(decoded.dismissesOnOutsideClick)
        #expect(decoded.animationSpeed == .normal)
        #expect(!decoded.usesCompactCards)
        #expect(!decoded.isCapturePaused)
    }

    @Test("Pause capture persists across upgrades and restarts")
    func pauseSettingDecodes() throws {
        let payload = Data(#"{"appearance":"dark","isCapturePaused":true,"excludedApplications":["com.example.editor"]}"#.utf8)
        let decoded = try JSONDecoder().decode(KopiSettings.self, from: payload)
        #expect(decoded.appearance == .dark)
        #expect(decoded.excludedApplications == ["com.example.editor"])
        #expect(decoded.hotkey == .default)

        let encoded = try JSONEncoder().encode(decoded)
        #expect(decoded.isCapturePaused)
        #expect(decoded.animationSpeed == .normal)
        #expect(!decoded.usesCompactCards)
        let reloaded = try JSONDecoder().decode(KopiSettings.self, from: encoded)
        #expect(reloaded == decoded)
    }

    @Test("Modifiers read from the archived number form and the keyed form")
    func hotkeyModifierCoding() throws {
        let numeric = Data(#"{"keyCode":9,"keyLabel":"V","modifiers":3}"#.utf8)
        let hotkey = try JSONDecoder().decode(HotkeyDefinition.self, from: numeric)
        #expect(hotkey.keyCode == 9)
        #expect(hotkey.keyLabel == "V")
        #expect(hotkey.modifiers == [.option, .command])

        let keyed = Data(#"{"rawValue":3}"#.utf8)
        #expect(try JSONDecoder().decode(HotkeyModifiers.self, from: keyed) == [.option, .command])

        let encoded = try JSONEncoder().encode(HotkeyModifiers([.option, .command]))
        #expect(String(decoding: encoded, as: UTF8.self) == "3")
    }

    @Test("Settings written by an earlier build decode and migrate")
    func archivedSettingsDecode() throws {
        let payload = Data("""
        {"excludedApplications":[],"animationSpeed":"relaxed","dismissesOnOutsideClick":true,\
        "notesFolderIDs":[],"appearance":"system","usesCompactCards":false,\
        "hotkey":{"keyCode":9,"keyLabel":"V","modifiers":3},\
        "hoverReveal":{"delay":0.1,"isEnabled":true},"launchAtLogin":false,\
        "isHotkeyEnabled":true,"isCapturePaused":false,"notesFoldersConfigured":false}
        """.utf8)
        let decoded = try JSONDecoder().decode(KopiSettings.self, from: payload)
        #expect(decoded.hoverReveal.delay == 0.1)
        #expect(decoded.hoverReveal.isEnabled)
        #expect(decoded.hotkey == .default)
        #expect(decoded.animationSpeed == .relaxed)
        #expect(decoded != KopiSettings())
    }
}
