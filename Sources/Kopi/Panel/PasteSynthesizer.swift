import AppKit
import CoreGraphics
import Foundation

/// Posts Return's ⌘V into the application the panel took the user away from.
///
/// macOS only lets a process inject events when it is trusted for accessibility, so the
/// result is reported honestly: when posting is not possible the card is still on the
/// clipboard and the caller tells the user to press ⌘V.
struct PasteSynthesizer {
    /// Virtual key code of "V" on every layout.
    static let pasteKeyCode: CGKeyCode = 9

    /// Whether this process may post events at all.
    var canPostEvents: Bool { CGPreflightPostEventAccess() }

    /// Posts ⌘V to `processIdentifier`. Returns `false` when the event was not delivered.
    @discardableResult
    func paste(into processIdentifier: pid_t) -> Bool {
        guard processIdentifier > 0, canPostEvents else { return false }
        let source = CGEventSource(stateID: .combinedSessionState)
        guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: Self.pasteKeyCode, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: Self.pasteKeyCode, keyDown: false)
        else { return false }
        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand
        keyDown.postToPid(processIdentifier)
        keyUp.postToPid(processIdentifier)
        return true
    }
}
