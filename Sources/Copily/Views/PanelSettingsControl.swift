import AppKit
import SwiftUI

/// Settings can retain focus while hover brings the panel forward. A native
/// click-through control delivers that first mouse-down directly to the handoff.
struct PanelSettingsControl: NSViewRepresentable {
    let action: @MainActor () -> Void

    func makeNSView(context: Context) -> PanelSettingsButton {
        PanelSettingsButton(action: action)
    }

    func updateNSView(_ button: PanelSettingsButton, context: Context) {
        button.onPress = action
    }
}

final class PanelSettingsButton: NSButton {
    var onPress: @MainActor () -> Void

    init(action: @escaping @MainActor () -> Void) {
        onPress = action
        super.init(frame: NSRect(x: 0, y: 0, width: 28, height: 28))
        image = NSImage(systemSymbolName: "gearshape", accessibilityDescription: "Open Copily settings")?
            .withSymbolConfiguration(.init(pointSize: 13, weight: .medium))
        imagePosition = .imageOnly
        contentTintColor = .secondaryLabelColor
        isBordered = false
        setButtonType(.momentaryChange)
        target = self
        self.action = #selector(pressed)
        identifier = NSUserInterfaceItemIdentifier("copily.settings")
        setAccessibilityLabel("Open Copily settings")
    }

    required init?(coder: NSCoder) { nil }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    @objc private func pressed() {
        PanelDiagnostics.event("Settings gear activated; panel key: \(window?.isKeyWindow ?? false)")
        onPress()
    }
}
