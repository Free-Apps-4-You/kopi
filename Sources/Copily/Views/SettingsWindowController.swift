import AppKit
import QuartzCore
import SwiftUI
import CopilyCore

/// Settings window, hosting the SwiftUI settings form.
@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    private let environment: AppEnvironment
    private var window: NSWindow?
    private var model: SettingsViewModel?
    private var revealGeneration = UUID()

    init(environment: AppEnvironment) {
        self.environment = environment
    }

    var isVisible: Bool { window?.isVisible == true && window?.isMiniaturized == false }

    func show() {
        let model = self.model ?? SettingsViewModel(environment: environment)
        self.model = model
        let window = self.window ?? makeWindow(model: model)
        self.window = window
        Task { await model.load() }
        let needsReveal = !window.isVisible || window.isMiniaturized
        NSApp.activate()
        guard needsReveal else {
            window.makeKeyAndOrderFront(nil)
            return
        }
        if window.isMiniaturized { window.deminiaturize(nil) }
        let generation = UUID()
        revealGeneration = generation
        let destination = window.frame
        let duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : environment.settings.settings.animationSpeed.openingDuration
        window.alphaValue = duration > 0 ? 0 : 1
        window.setFrame(duration > 0 ? destination.offsetBy(dx: 0, dy: -8) : destination, display: false)
        window.makeKeyAndOrderFront(nil)
        WindowTransition.animate(window.contentView, opening: true, fromTop: false, duration: duration)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.16, 1, 0.3, 1)
            window.animator().alphaValue = 1
            window.animator().setFrame(destination, display: true)
        } completionHandler: { [weak self, weak window] in
            MainActor.assumeIsolated {
                guard self?.revealGeneration == generation else { return }
                WindowTransition.clear(window?.contentView)
            }
        }
    }

    func windowWillClose(_ notification: Notification) {
        revealGeneration = UUID()
        WindowTransition.clear(window?.contentView)
        window?.alphaValue = 1
    }

    private func makeWindow(model: SettingsViewModel) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 540),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Copily Settings"
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentViewController = NSHostingController(rootView: SettingsView(model: model))
        window.setContentSize(NSSize(width: 600, height: 540))
        window.minSize = NSSize(width: 560, height: 482)
        window.center()
        return window
    }
}
