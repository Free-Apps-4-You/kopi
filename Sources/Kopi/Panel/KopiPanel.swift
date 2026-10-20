import AppKit
import SwiftUI
import KopiCore

/// Panel that hosts the clipboard interface.
///
/// A borderless panel cannot become key by default, and the panel has to take the
/// keyboard so typing and the shortcuts work as soon as it opens.
final class KopiPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// The panel reaches the display's top edge on a notched display, inside the strip
    /// macOS normally keeps for the menu bar.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }

    /// The card sits inside the panel with room around it for its shadow.
    static func make() -> KopiPanel {
        let panel = KopiPanel(
            contentRect: .zero,
            styleMask: [.borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.isMovable = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.worksWhenModal = true
        panel.animationBehavior = .none
        panel.ignoresMouseEvents = false
        return panel
    }
}

/// Transient message shown near the top of the display, for example after a paste that
/// could only be copied. It never takes focus and never accepts clicks.
@MainActor
final class PanelToastController {
    private var panel: NSPanel?
    private var hideTask: Task<Void, Never>?

    func show(_ message: String, on display: PanelDisplayGeometry) {
        let panel = ensurePanel()
        panel.contentView = NSHostingView(rootView: PanelToastView(message: message))
        let size = panel.contentView?.fittingSize ?? CGSize(width: 320, height: 40)
        let width = max(200, min(size.width + 4, 460))
        let height = max(38, size.height + 2)
        panel.setFrame(
            CGRect(
                x: (display.frame.midX - width / 2).rounded(),
                y: display.panelTopY - height - 14,
                width: width,
                height: height
            ),
            display: false
        )
        panel.orderFront(nil)
        hideTask?.cancel()
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2.4))
            guard !Task.isCancelled else { return }
            self?.hide()
        }
    }

    func hide() {
        hideTask?.cancel()
        hideTask = nil
        panel?.orderOut(nil)
    }

    private func ensurePanel() -> NSPanel {
        if let panel { return panel }
        let panel = NonActivatingPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        self.panel = panel
        return panel
    }
}

/// Panel that never becomes key, so a message can be shown while another application
/// keeps the keyboard.
final class NonActivatingPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Contents of the transient message.
struct PanelToastView: View {
    let message: String
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "doc.on.clipboard")
                .foregroundStyle(KopiTheme.accent)
            Text(message)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.primary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(KopiTheme.surface)
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(KopiTheme.border(contrast: contrast), lineWidth: 1)
                )
        )
        .padding(2)
    }
}
