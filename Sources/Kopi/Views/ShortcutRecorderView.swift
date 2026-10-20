import AppKit
import SwiftUI
import KopiCore

/// Shortcut recorder: click, then press the combination.
///
/// A local key view rather than a global monitor: the recording happens while the
/// Settings window has the keyboard, so no permission is involved.
struct ShortcutRecorderView: NSViewRepresentable {
    let hotkey: HotkeyDefinition
    @Binding var isRecording: Bool
    let onChange: (HotkeyDefinition) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(isRecording: $isRecording, onChange: onChange)
    }

    func makeNSView(context: Context) -> RecorderField {
        let field = RecorderField()
        field.coordinator = context.coordinator
        field.hotkey = hotkey
        return field
    }

    func updateNSView(_ nsView: RecorderField, context: Context) {
        context.coordinator.isRecording = $isRecording
        context.coordinator.onChange = onChange
        nsView.hotkey = hotkey
        nsView.needsDisplay = true
    }

    @MainActor
    final class Coordinator {
        var isRecording: Binding<Bool>
        var onChange: (HotkeyDefinition) -> Void

        init(isRecording: Binding<Bool>, onChange: @escaping (HotkeyDefinition) -> Void) {
            self.isRecording = isRecording
            self.onChange = onChange
        }

        func capture(_ event: NSEvent) -> Bool {
            var modifiers: HotkeyModifiers = []
            let flags = event.modifierFlags
            if flags.contains(.command) { modifiers.insert(.command) }
            if flags.contains(.option) { modifiers.insert(.option) }
            if flags.contains(.control) { modifiers.insert(.control) }
            if flags.contains(.shift) { modifiers.insert(.shift) }
            guard HotkeyDefinition.isModifierKeyCode(event.keyCode) == false else { return false }
            if event.keyCode == PanelKeyBindings.escapeKeyCode, modifiers.isEmpty {
                isRecording.wrappedValue = false
                return true
            }
            guard let captured = HotkeyDefinition.captured(
                keyCode: event.keyCode,
                modifiers: modifiers,
                characters: event.charactersIgnoringModifiers ?? ""
            ) else {
                return false
            }
            onChange(captured)
            isRecording.wrappedValue = false
            return true
        }

        func setRecording(_ recording: Bool) {
            isRecording.wrappedValue = recording
        }
    }

    /// Field that shows the shortcut and takes the next key press while recording.
    final class RecorderField: NSView {
        weak var coordinator: Coordinator?
        var hotkey: HotkeyDefinition? {
            didSet { needsDisplay = true }
        }

        private var isRecording: Bool { coordinator?.isRecording.wrappedValue ?? false }

        override var acceptsFirstResponder: Bool { true }
        override var focusRingMaskBounds: NSRect { bounds }

        override func isAccessibilityElement() -> Bool { true }
        override func accessibilityRole() -> NSAccessibility.Role? { .button }
        override func accessibilityLabel() -> String? { "Global shortcut" }
        override func accessibilityValue() -> Any? { isRecording ? "Press shortcut" : hotkey?.displayString ?? "None" }
        override func accessibilityHelp() -> String? { "Press to record a new shortcut. Escape cancels." }
        override func accessibilityPerformPress() -> Bool {
            window?.makeFirstResponder(self)
            coordinator?.setRecording(!isRecording)
            needsDisplay = true
            return true
        }

        override func draw(_ dirtyRect: NSRect) {
            let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 7, yRadius: 7)
            (isRecording ? NSColor.controlAccentColor.withAlphaComponent(0.16) : NSColor.controlBackgroundColor).setFill()
            path.fill()
            (isRecording ? NSColor.controlAccentColor : NSColor.separatorColor).setStroke()
            path.lineWidth = 1
            path.stroke()

            let text = isRecording ? "Press shortcut…" : (hotkey?.displayString ?? "None")
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 12, weight: .medium),
                .foregroundColor: isRecording ? NSColor.controlAccentColor : NSColor.labelColor
            ]
            let size = text.size(withAttributes: attributes)
            text.draw(
                at: NSPoint(x: 10, y: (bounds.height - size.height) / 2),
                withAttributes: attributes
            )
        }

        override func mouseDown(with event: NSEvent) {
            _ = accessibilityPerformPress()
        }

        override func performKeyEquivalent(with event: NSEvent) -> Bool {
            guard isRecording, event.type == .keyDown else { return super.performKeyEquivalent(with: event) }
            return coordinator?.capture(event) ?? false
        }

        override func keyDown(with event: NSEvent) {
            if !isRecording, event.keyCode == PanelKeyBindings.returnKeyCode || event.keyCode == PanelKeyBindings.spaceKeyCode {
                _ = accessibilityPerformPress()
                return
            }
            guard isRecording, coordinator?.capture(event) == true else {
                return super.keyDown(with: event)
            }
        }

        override func flagsChanged(with event: NSEvent) {
            guard isRecording else { return }
            needsDisplay = true
        }

        override func resignFirstResponder() -> Bool {
            coordinator?.setRecording(false)
            return true
        }
    }
}
