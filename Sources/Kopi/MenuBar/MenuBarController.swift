import AppKit
import Foundation
import KopiCore

/// Menu bar item: a left click opens the panel, a right click opens the menu with
/// Open, Clear History, Settings and Quit.
@MainActor
final class MenuBarController: NSObject, NSMenuDelegate {
    private let statusItem: NSStatusItem
    private let toggle: () -> Void
    private let open: () -> Void
    private let clearHistory: () -> Void
    private let openSettings: () -> Void
    private let quit: () -> Void

    private var hotkey: HotkeyDefinition?
    private let tooltipOwner = UUID()
    private var tooltipText = "Kopi — click to show or hide"
    private var tooltipTracking: NSTrackingArea?

    init(
        toggle: @escaping () -> Void,
        open: @escaping () -> Void,
        clearHistory: @escaping () -> Void,
        openSettings: @escaping () -> Void,
        quit: @escaping () -> Void
    ) {
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        self.toggle = toggle
        self.open = open
        self.clearHistory = clearHistory
        self.openSettings = openSettings
        self.quit = quit
        super.init()
        statusItem.button?.image = Self.symbol("doc.on.clipboard")
        statusItem.button?.toolTip = nil
        let tracking = NSTrackingArea(rect: .zero, options: [.activeAlways, .inVisibleRect, .mouseEnteredAndExited], owner: self, userInfo: nil)
        statusItem.button?.addTrackingArea(tracking)
        tooltipTracking = tracking
        statusItem.button?.target = self
        statusItem.button?.action = #selector(statusItemClicked)
        _ = statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
    }

    @objc(mouseEntered:) private func tooltipEntered(_ event: NSEvent) {
        guard statusItem.menu == nil else { return }
        KopiTooltipPresenter.shared.request(tooltipText, owner: tooltipOwner)
    }
    @objc(mouseExited:) private func tooltipExited(_ event: NSEvent) {
        KopiTooltipPresenter.shared.hide(owner: tooltipOwner)
    }

    var containsPointer: Bool {
        guard let button = statusItem.button, let window = button.window else { return false }
        let rect = window.convertToScreen(button.convert(button.bounds, to: nil))
        return rect.contains(NSEvent.mouseLocation)
    }

    func update(captureState: ClipboardCaptureState, hotkey: HotkeyDefinition?) {
        self.hotkey = hotkey
        statusItem.button?.image = Self.symbol("doc.on.clipboard")
        tooltipText = Self.tooltip(for: captureState)
    }

    // MARK: - Clicking

    /// A plain click opens the panel; a secondary or control click opens the menu
    /// under the status item.
    @objc private func statusItemClicked() {
        guard let event = NSApp.currentEvent else {
            toggle()
            return
        }
        let requestsMenu = event.type == .rightMouseUp
            || event.type == .rightMouseDown
            || event.modifierFlags.contains(.control)
            || event.clickCount > 1
        if requestsMenu {
            presentMenu()
        } else {
            toggle()
        }
    }

    private func presentMenu() {
        guard let button = statusItem.button else { return }
        KopiTooltipPresenter.shared.hideAll()
        // Let NSStatusItem place and track its own menu. A manual popUp above the
        // button is clamped to the screen and can turn into a clipped, scrolling menu.
        let menu = makeMenu()
        menu.delegate = self
        statusItem.menu = menu
        button.performClick(nil)
    }

    func menuDidClose(_ menu: NSMenu) {
        // Restore the ordinary click-to-toggle action after native menu tracking ends.
        statusItem.menu = nil
        statusItem.button?.highlight(false)
    }

    // MARK: - Menu

    private func makeMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false

        let openItem = NSMenuItem(title: "Open Kopi", action: #selector(openSelected), keyEquivalent: "")
        openItem.target = self
        if let hotkey {
            openItem.keyEquivalent = hotkey.keyLabel.lowercased()
            openItem.keyEquivalentModifierMask = Self.eventModifiers(from: hotkey.modifiers)
        }
        menu.addItem(openItem)

        menu.addItem(.separator())

        let clearItem = NSMenuItem(title: "Clear History…", action: #selector(clearHistorySelected), keyEquivalent: "")
        clearItem.target = self
        menu.addItem(clearItem)

        menu.addItem(.separator())

        let settingsItem = NSMenuItem(title: "Settings…", action: #selector(openSettingsSelected), keyEquivalent: ",")
        settingsItem.keyEquivalentModifierMask = .command
        settingsItem.target = self
        menu.addItem(settingsItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "Quit Kopi", action: #selector(quitSelected), keyEquivalent: "q")
        quitItem.keyEquivalentModifierMask = .command
        quitItem.target = self
        menu.addItem(quitItem)
        return menu
    }

    /// The mark in the menu bar.
    ///
    /// It is the same glyph as the application icon, drawn as a template image so
    /// macOS paints it in the colour of the menu bar and inverts it when the item
    /// is highlighted. A build without a bundle falls back to the system symbol.
    private static func symbol(_ name: String) -> NSImage? {
        if let bundled = Bundle.main.image(forResource: "MenuBarTemplate") {
            // The mark is drawn at thirty-two pixels and shown at sixteen points,
            // which is the size a menu bar item expects.
            bundled.size = NSSize(width: 16, height: 16)
            bundled.isTemplate = true
            return bundled
        }
        let image = NSImage(systemSymbolName: name, accessibilityDescription: "Kopi")
        image?.isTemplate = true
        return image
    }

    /// The tooltip only reports a capture loop that needs the user's attention.
    private static func tooltip(for state: ClipboardCaptureState) -> String {
        switch state {
        case .running, .idle, .paused(.captureDisabled):
            return "Kopi — click to show or hide"
        case .paused(.systemSleep), .blocked:
            return "Kopi — \(state.displayName)"
        }
    }

    private static func eventModifiers(from modifiers: HotkeyModifiers) -> NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        if modifiers.contains(.command) { flags.insert(.command) }
        if modifiers.contains(.option) { flags.insert(.option) }
        if modifiers.contains(.control) { flags.insert(.control) }
        if modifiers.contains(.shift) { flags.insert(.shift) }
        return flags
    }

    // MARK: - Actions

    @objc private func openSelected() { open() }
    @objc private func clearHistorySelected() { clearHistory() }
    @objc private func openSettingsSelected() { openSettings() }
    @objc private func quitSelected() { quit() }
}
