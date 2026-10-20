import AppKit
import Combine
import Foundation
import CopilyCore

/// Entry point of the executable.
///
/// `swift run Copily --selfcheck` stays headless and runs the core self-check;
/// plain `swift run Copily` starts the menu bar application.
@main
enum CopilyMain {
    @MainActor
    static func main() {
        if CommandLine.arguments.contains("--selfcheck") {
            CopilySelfCheck.runHeadless()
        }
        CopilyApplication.run()
    }
}

/// Starts Copily as an accessory application: no Dock icon, a menu bar item and the
/// clipboard panel.
@MainActor
enum CopilyApplication {
    /// `NSApplication` holds its delegate weakly, so the application keeps it here.
    private static let delegate = AppDelegate()

    static func run() {
        let application = NSApplication.shared
        application.delegate = delegate
        application.setActivationPolicy(.accessory)
        application.run()
    }
}

/// Owns the windows and controllers, and follows the settings the user changes.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var environment: AppEnvironment?
    private var panelController: PanelController?
    private var menuBarController: MenuBarController?
    private var settingsWindowController: SettingsWindowController?
    private var hotKey: GlobalHotKey?
    private var hover: HoverRevealMonitor?
    private var settingsSubscription: AnyCancellable?
    private var captureSubscription: AnyCancellable?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        do {
            let environment = try AppEnvironment.bootstrap()
            self.environment = environment
            start(environment)
        } catch {
            presentStartupFailure(error)
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let environment else { return .terminateNow }
        if environment.panelModel.hasActiveEditor {
            panelController?.open()
            environment.panelModel.requestLeavingEditor { NSApp.terminate(nil) }
            return .terminateCancel
        }
        Task { @MainActor in
            await Self.finishShutdown(environment)
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    /// Ends the session, giving up after a moment so that quitting is always prompt.
    /// The session end is one small database write; a store busy with something else
    /// must never keep the application from quitting.
    private static func finishShutdown(_ environment: AppEnvironment) async {
        await GracefulShutdown.wait {
            await environment.shutdown()
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        PanelDiagnostics.event("Application reopen requested; existing windows: \(flag)")
        if panelController?.isHandingOffToSettings == true { return true }
        if panelController?.shouldFocusSettingsOnReopen(settingsAreVisible: settingsWindowController?.isVisible == true) == true {
            settingsWindowController?.show()
        } else {
            panelController?.open()
        }
        return true
    }

    // MARK: - Wiring

    private func start(_ environment: AppEnvironment) {
        let panelController = PanelController(
            model: environment.panelModel,
            service: environment.service,
            settings: environment.settings
        )
        panelController.prepare()
        let settingsWindowController = SettingsWindowController(environment: environment)
        let hotKey = GlobalHotKey()
        let hover = HoverRevealMonitor()

        self.panelController = panelController
        self.settingsWindowController = settingsWindowController
        self.hotKey = hotKey
        self.hover = hover

        panelController.onVisibilityChange = { [weak hover] isVisible in
            hover?.setActive(!isVisible)
            if !isVisible {
                hover?.suppressUntilPointerLeaves()
            }
        }

        menuBarController = MenuBarController(
            toggle: { [weak panelController] in panelController?.toggle() },
            open: { [weak panelController] in panelController?.open() },
            clearHistory: { [weak environment] in environment?.clearHistory(withConfirmation: true) },
            openSettings: { [weak panelController, weak settingsWindowController] in
                panelController?.showSettings { [weak settingsWindowController] in settingsWindowController?.show() }
            },
            quit: { NSApp.terminate(nil) }
        )

        panelController.isPointerOverMenuBarItem = { [weak self] in
            self?.menuBarController?.containsPointer ?? false
        }

        environment.panelModel.onSettingsRequested = { [weak panelController, weak settingsWindowController] in
            panelController?.showSettings { [weak settingsWindowController] in settingsWindowController?.show() }
        }

        settingsSubscription = environment.settings.$settings
            .removeDuplicates()
            .sink { [weak self] settings in
                MainActor.assumeIsolated {
                    self?.apply(settings)
                }
            }

        captureSubscription = environment.captureStatus.$state
            .removeDuplicates()
            .sink { [weak self] state in
                MainActor.assumeIsolated {
                    guard let self, let environment = self.environment else { return }
                    self.menuBarController?.update(captureState: state, hotkey: environment.settings.settings.activeHotkey)
                }
            }

        Task { @MainActor in
            await environment.start()
            if let notice = environment.startupNotice {
                environment.panelModel.queueStatus(notice)
            }
            apply(environment.settings.settings)
        }
    }

    /// Follows the settings store: everything the user changes takes effect here.
    private func apply(_ settings: CopilySettings) {
        guard let environment else { return }
        NSApp.appearance = settings.appearance.nsAppearance
        environment.apply(settings: settings)
        panelController?.settingsDidChange()
        if hotKey?.register(settings.activeHotkey, onPress: { [weak panelController] in panelController?.toggle() }) == false,
           settings.activeHotkey != nil {
            environment.panelModel.queueStatus("That shortcut is already taken by another application.")
        }
        hover?.configure(enabled: settings.hoverReveal.isEnabled, delay: settings.hoverReveal.delay) { [weak panelController] in
            panelController?.openFromHover()
        }
        menuBarController?.update(captureState: environment.captureStatus.state, hotkey: settings.activeHotkey)
    }

    private func presentStartupFailure(_ error: any Error) {
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "Copily could not start"
        alert.informativeText = error.localizedDescription
        alert.addButton(withTitle: "Quit")
        alert.runModal()
        NSApp.terminate(nil)
    }
}
