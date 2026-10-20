import AppKit
import QuartzCore
import SwiftUI
import CopilyCore

/// Commands the panel content asks of the window layer.
///
/// Pasting needs the application the user came from and event posting, which belong to
/// AppKit; the view models stay free of both. The closures capture the controller
/// weakly, so the hosted view never keeps its own window alive.
struct PanelCommands: Sendable {
    var paste: @MainActor (ClipboardItemID) -> Void
    var copy: @MainActor (ClipboardItemID) -> Void
    var pasteNote: @MainActor (NotesNoteMetadata) -> Void = { _ in }
    var dismiss: @MainActor () -> Void
    var openSettings: @MainActor () -> Void
}

/// The panel window: placement, activation, focus restoration, shortcuts and dismissal.
@MainActor
final class PanelController: NSObject {
    private let model: PanelViewModel
    private let service: ClipboardService
    private let settings: CopilySettingsStore
    private let pasteSynthesizer = PasteSynthesizer()
    private let toast = PanelToastController()

    private var panel: CopilyPanel?
    private var placement: PanelPlacement?
    private var keyMonitor: Any?
    private var resignObserver: (any NSObjectProtocol)?
    private var globalClickMonitor: Any?
    private var paddingClickMonitor: Any?
    private var previousApplication: NSRunningApplication?
    private var openedAt: Date?
    private var isOpening = false
    private var isClosing = false
    private var visibilityGeneration = UUID()
    private var presentationIntent = WindowPresentationIntent()
    var isPointerOverMenuBarItem: (() -> Bool)?

    /// Called after the panel becomes visible or is dismissed, so the hover monitor can
    /// pause and resume.
    var onVisibilityChange: ((Bool) -> Void)?

    init(model: PanelViewModel, service: ClipboardService, settings: CopilySettingsStore) {
        self.model = model
        self.service = service
        self.settings = settings
    }

    var isVisible: Bool { isOpening || (!isClosing && (panel?.isVisible ?? false)) }

    /// Builds the panel ahead of the first reveal, so the first hover or hot key opening
    /// is as fast as every later one.
    func prepare() {
        _ = ensurePanel()
    }

    // MARK: - Opening and closing

    func toggle() {
        if isVisible {
            dismiss()
        } else {
            open()
        }
    }

    /// Opens the panel from the hot key or the menu bar item.
    ///
    /// The window is ordered front on the next main-actor turn: the opening token has
    /// been published before that, so SwiftUI commits the content's reset state while
    /// the panel is still hidden. Once the shell is front, the reveal token starts the
    /// content's entrance.
    func open() {
        guard !isVisible, presentationIntent.requestPanel() else { return }
        PanelDiagnostics.event("Opening panel")
        let generation = UUID()
        visibilityGeneration = generation
        isOpening = true
        isClosing = false
        captureFrontmostApplication()
        model.panelDidOpen()
        let panel = ensurePanel()
        position(panel)
        panel.contentView?.layoutSubtreeIfNeeded()
        addMonitors()
        onVisibilityChange?(true)
        Task { @MainActor [self] in
            await model.settleBeforeReveal()
            guard visibilityGeneration == generation, isOpening else { return }
            let reducedMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            let duration = reducedMotion ? 0 : settings.settings.animationSpeed.openingDuration
            panel.alphaValue = 1
            NSApp.activate(ignoringOtherApps: true)
            panel.makeKeyAndOrderFront(nil)
            openedAt = Date()
            model.panelDidReveal()
            focusSearchField()
            // Reassert after status-menu tracking and the field editor have settled.
            DispatchQueue.main.async { [weak self] in
                guard let self, self.visibilityGeneration == generation, self.isVisible else { return }
                panel.makeKey()
                self.focusSearchField()
            }
            WindowTransition.animate(panel.contentView, opening: true, fromTop: true, duration: duration, sourceWidth: placement?.triggerRect.width) { [weak self] in
                guard let self, self.visibilityGeneration == generation else { return }
                self.isOpening = false
                self.model.entranceDidFinish(token: self.model.revealToken)
            }
        }
    }

    /// Opens the panel because the pointer rested at the notch. The pointer is already
    /// over the trigger area, so the frontmost application is whichever one the user
    /// was working in.
    func openFromHover() {
        guard !isVisible else { return }
        open()
    }

    func dismiss(restoreFocus: Bool = true) {
        if model.hasActiveEditor {
            let restoreAfterPrompt = restoreFocus || !NSApp.isActive
            if !NSApp.isActive { captureFrontmostApplication() }
            NSApp.activate(ignoringOtherApps: true)
            panel?.makeKeyAndOrderFront(nil)
            model.requestLeavingEditor { [weak self] in self?.performDismiss(restoreFocus: restoreAfterPrompt) }
            return
        }
        performDismiss(restoreFocus: restoreFocus)
    }

    /// Every Settings entry point uses this handoff, including an already-open
    /// Settings window. Keep the previous app's focus out of the transition.
    var isHandingOffToSettings: Bool { presentationIntent.isHandingOffToSettings }

    func shouldFocusSettingsOnReopen(settingsAreVisible: Bool) -> Bool {
        presentationIntent.shouldFocusSettingsOnReopen(settingsAreVisible: settingsAreVisible)
    }

    func showSettings(_ show: @escaping @MainActor () -> Void) {
        PanelDiagnostics.event("Settings handoff requested")
        model.requestLeavingEditor { [weak self] in
            guard let self else { return }
            self.model.passwords.lock()
            let request = self.presentationIntent.requestSettings()
            self.performDismiss(restoreFocus: false) { [weak self] in
                guard let self, self.presentationIntent.isCurrentSettingsRequest(request) else { return }
                // An existing Settings window can activate this accessory app.
                // Keep passive reopen/activation callbacks out of that handoff.
                self.panel?.orderOut(nil)
                show()
                self.panel?.orderOut(nil)
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.presentationIntent.isCurrentSettingsRequest(request) else { return }
                    self.panel?.orderOut(nil)
                    self.presentationIntent.finishSettingsRequest(request)
                    PanelDiagnostics.event("Settings handoff finished; panel visible: \(self.panel?.isVisible ?? false)")
                }
            }
        }
    }

    private func performDismiss(restoreFocus: Bool, completion: (@MainActor () -> Void)? = nil) {
        CopilyTooltipPresenter.shared.hideAll()
        guard let panel else { completion?(); return }
        let wasPresented = isOpening || isClosing || panel.isVisible
        let generation = UUID()
        visibilityGeneration = generation
        isOpening = false
        isClosing = true
        removeMonitors()
        model.panelDidClose()
        if restoreFocus { self.restoreFocus() }
        let duration = !wasPresented || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : settings.settings.animationSpeed.closingDuration
        WindowTransition.animate(panel.contentView, opening: false, fromTop: true, duration: duration, sourceWidth: placement?.triggerRect.width)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            panel.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.visibilityGeneration == generation else { return }
                panel.orderOut(nil)
                WindowTransition.clear(panel.contentView)
                PanelDiagnostics.event("Panel ordered out; visible: \(panel.isVisible)")
                panel.alphaValue = 1
                self.isClosing = false
                self.onVisibilityChange?(false)
                completion?()
            }
        }
    }

    private func focusSearchField() {
        guard let panel, model.preview == nil, model.editor == nil,
              model.newItemDraft == nil,
              model.notes.preview == nil, model.notes.composer == nil, model.passwords.draft == nil else { return }
        func find(_ view: NSView) -> NSTextField? {
            if let field = view as? NSTextField, field.identifier?.rawValue == "copily.search" { return field }
            return view.subviews.lazy.compactMap { find($0) }.first
        }
        if let content = panel.contentView, let field = find(content) {
            panel.makeFirstResponder(field)
        }
    }

    // MARK: - Pasting and copying

    /// Return: writes the card through the capture service, dismisses the panel and
    /// posts ⌘V into the application the user came from.
    func paste(_ itemID: ClipboardItemID) {
        let target = previousApplication
        Task { @MainActor in
            do {
                _ = try await service.copyToPasteboard(itemID)
            } catch {
                model.report(error: error)
                return
            }
            dismiss(restoreFocus: true)
            await postPaste(into: target)
        }
    }

    /// ⌘C: copies the card and leaves the panel open.
    func copy(_ itemID: ClipboardItemID) {
        Task { @MainActor in
            do {
                _ = try await service.copyToPasteboard(itemID)
                model.selectForPaste(itemID)
                model.showStatus("Copied to clipboard")
            } catch {
                model.report(error: error)
            }
        }
    }

    func pasteNote(_ note: NotesNoteMetadata) {
        let target = previousApplication
        Task { @MainActor in
            guard await model.notes.copyText(of: note) else { return }
            dismiss(restoreFocus: true)
            await postPaste(into: target)
        }
    }

    private func postPaste(into application: NSRunningApplication?) async {
        guard let application,
              !application.isTerminated,
              application.processIdentifier != ProcessInfo.processInfo.processIdentifier
        else {
            toast.show("Copied — press ⌘V to paste", on: ScreenGeometry.displayUnderPointer())
            return
        }
        // The target has to be frontmost before the keystroke lands in it.
        try? await Task.sleep(for: .milliseconds(90))
        if !pasteSynthesizer.paste(into: application.processIdentifier) {
            toast.show("Copied — press ⌘V to paste", on: ScreenGeometry.displayUnderPointer())
        }
    }

    private func captureFrontmostApplication() {
        guard let application = NSWorkspace.shared.frontmostApplication,
              application.processIdentifier != ProcessInfo.processInfo.processIdentifier
        else { return }
        previousApplication = application
    }

    private func restoreFocus() {
        guard let application = previousApplication,
              !application.isTerminated,
              application.processIdentifier != ProcessInfo.processInfo.processIdentifier
        else { return }
        application.activate()
    }

    // MARK: - Window

    private func ensurePanel() -> CopilyPanel {
        if let panel { return panel }
        let panel = CopilyPanel.make()
        panel.delegate = self
        let commands = PanelCommands(
            paste: { [weak self] itemID in self?.paste(itemID) },
            copy: { [weak self] itemID in self?.copy(itemID) },
            pasteNote: { [weak self] note in self?.pasteNote(note) },
            dismiss: { [weak self] in self?.dismiss() },
            openSettings: { [weak self] in self?.model.onSettingsRequested?() }
        )
        panel.contentView = WindowTransitionHost(rootView: PanelRootView(model: model, commands: commands))
        self.panel = panel
        return panel
    }

    private func position(_ panel: NSPanel) {
        let placement = PanelGeometry.bodyOnlyPlacement(for: ScreenGeometry.displayUnderPointer())
        self.placement = placement
        // Keep the captured window rectangular: physical camera hardware is not app content.
        model.setPanelAttachment(nil)
        panel.setFrame(placement.bodyRect.insetBy(dx: -CopilyTheme.shadowInset, dy: -CopilyTheme.shadowInset), display: false)
    }

    // MARK: - Monitors

    private func addMonitors() {
        if keyMonitor == nil {
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
                let box = MainThreadEvent(event: event)
                let consumed = MainActor.assumeIsolated {
                    guard let self else { return false }
                    return self.handleKeyDown(box.event)
                }
                return consumed ? nil : event
            }
        }
        if resignObserver == nil {
            resignObserver = NotificationCenter.default.addObserver(
                forName: NSApplication.didResignActiveNotification,
                object: NSApp,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.applicationDidResignActive()
                }
            }
        }
        installClickMonitors()
    }

    private func removeMonitors() {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
        }
        keyMonitor = nil
        if let resignObserver {
            NotificationCenter.default.removeObserver(resignObserver)
        }
        resignObserver = nil
        removeClickMonitors()
    }

    // MARK: - Outside clicks

    /// Installs the monitors that dismiss the panel on a click outside it, when the
    /// setting asks for that. The global monitor never sees the application's own
    /// events, so a click in the panel does not reach it; the local monitor adds the
    /// transparent margin the panel's shadow keeps around the visible surface.
    private func installClickMonitors() {
        guard settings.settings.dismissesOnOutsideClick else { return }
        if globalClickMonitor == nil {
            globalClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.dismissForOutsideClick()
                }
            }
        }
        if paddingClickMonitor == nil {
            paddingClickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
                let box = MainThreadEvent(event: event)
                let consumed = MainActor.assumeIsolated {
                    self?.handleLocalClick(box.event) ?? false
                }
                return consumed ? nil : event
            }
        }
    }

    private func removeClickMonitors() {
        if let globalClickMonitor {
            NSEvent.removeMonitor(globalClickMonitor)
        }
        globalClickMonitor = nil
        if let paddingClickMonitor {
            NSEvent.removeMonitor(paddingClickMonitor)
        }
        paddingClickMonitor = nil
    }

    /// Follows the dismissal setting, which the user can change while the panel is open.
    func settingsDidChange() {
        guard isVisible else { return }
        if settings.settings.dismissesOnOutsideClick {
            installClickMonitors()
        } else {
            removeClickMonitors()
        }
    }

    /// A click in another application, anywhere on screen. The click already belongs to
    /// that application, so focus is not taken back from it.
    private func dismissForOutsideClick() {
        // The system authentication sheet is outside our process, but belongs to View/Save.
        if model.section == .passwords, model.passwords.isBusy { return }
        guard isPointerOverMenuBarItem?() != true else { return }
        guard !pointerIsInsideNotch else { return }
        guard isVisible, settings.settings.dismissesOnOutsideClick else { return }
        dismiss(restoreFocus: false)
    }

    /// Settings belongs to this process, so neither the global click monitor nor
    /// application deactivation sees its clicks. Dismiss without consuming them or
    /// restoring the previous application's focus. Padding clicks are consumed.
    private func handleLocalClick(_ event: NSEvent) -> Bool {
        guard isVisible,
              let panel,
              settings.settings.dismissesOnOutsideClick
        else { return false }
        if let window = event.window, window !== panel {
            // Scope this to Settings: menus, sheets and authentication retain their
            // own event handling and must not accidentally dismiss a draft or reveal.
            guard window.delegate is SettingsWindowController else { return false }
            if model.section == .passwords, model.passwords.isBusy { return false }
            PanelDiagnostics.event("Settings window clicked; dismissing clipboard panel")
            dismiss(restoreFocus: false)
            return false
        }
        guard event.window === panel else { return false }
        let point = panel.convertPoint(toScreen: event.locationInWindow)
        guard placement?.containsRevealTarget(point) != true,
              placement?.containsSurface(point) != true else {
            return false
        }
        dismiss(restoreFocus: true)
        return true
    }

    /// Any click outside the panel in another application leaves Copily inactive, which
    /// is what an outside click means for a panel that floats above everything else.
    private func applicationDidResignActive() {
        CopilyTooltipPresenter.shared.hideAll()
        if model.section == .passwords && model.passwords.isBusy { return }
        model.passwords.lock()
        guard settings.settings.dismissesOnOutsideClick, isPointerOverMenuBarItem?() != true else { return }
        guard !isOpening, !pointerIsInsideNotch,
              isVisible, let openedAt, Date().timeIntervalSince(openedAt) > 0.2 else { return }
        dismiss(restoreFocus: false)
    }

    /// The camera housing belongs to the reveal interaction even though it lies
    /// outside the body-only window. Menu-bar activation there must not close it.
    private var pointerIsInsideNotch: Bool {
        placement?.containsRevealTarget(NSEvent.mouseLocation) == true
    }

    /// Handles one key press while the panel is open, returning whether it was consumed.
    private func handleKeyDown(_ event: NSEvent) -> Bool {
        guard event.window === panel else { return false }
        if model.showsSavePrompt { return false }
        if event.keyCode == 13, Self.modifiers(from: event.modifierFlags) == [.command] {
            dismiss(); return true
        }
        if model.newItemDraft != nil {
            if event.keyCode == PanelKeyBindings.escapeKeyCode { model.cancelNewItem(); return true }
            if event.keyCode == 9, Self.modifiers(from: event.modifierFlags) == [.command] {
                let types = Set((NSPasteboard.general.types ?? []).map(\.rawValue))
                let hasImage = ClipboardRepresentationKind.allCases.contains { $0.isImage && types.contains($0.pasteboardType) }
                if types.contains(ClipboardRepresentationKind.fileURL.pasteboardType) || hasImage || !isEditingText {
                    Task { await model.pasteIntoNewItem() }
                    return true
                }
            }
            // A draft owns editing shortcuts; never paste a background card by mistake.
            return false
        }
        if model.section == .passwords {
            if event.keyCode == PanelKeyBindings.escapeKeyCode {
                if model.passwords.draft != nil { model.passwords.cancel() } else { dismiss() }
                return true
            }
            return false
        }
        if model.section == .notes, event.keyCode == PanelKeyBindings.escapeKeyCode {
            if model.notes.composer != nil {
                model.notes.cancelComposer()
                return true
            }
            if model.notes.preview != nil {
                model.notes.closePreview()
                return true
            }
        }
        if model.section == .notes {
            let notes = model.notes
            let action = PanelKeyBindings.action(for: PanelKeyEvent(
                keyCode: event.keyCode, characters: event.charactersIgnoringModifiers ?? "",
                modifiers: Self.modifiers(from: event.modifierFlags),
                presentation: notes.composer != nil ? .editor : .grid,
                isTextEditing: isEditingText, hasVisibleCard: notes.pasteTarget != nil,
                visibleCardCount: notes.filteredNotes.count))
            switch action {
            case .pasteSelection: if let note = notes.pasteTarget { pasteNote(note) }
            case .copySelection: if let note = notes.pasteTarget { Task { await notes.copyText(of: note) } }
            case .togglePreview:
                if notes.preview != nil { notes.closePreview() }
                else if let note = notes.pasteTarget { Task { await notes.preparePreview(note) } }
            case .editSelection: if let note = notes.pasteTarget { Task { await notes.beginEdit(note) } }
            case .pasteVisibleCard(let position): pasteNote(notes.filteredNotes[position - 1])
            case .dismiss: dismiss()
            case .cancelEditor: notes.cancelComposer()
            default: return false
            }
            return true
        }
        let keyEvent = PanelKeyEvent(
            keyCode: event.keyCode,
            characters: event.charactersIgnoringModifiers ?? "",
            modifiers: Self.modifiers(from: event.modifierFlags),
            presentation: model.presentation,
            isTextEditing: isEditingText,
            hasVisibleCard: model.hasPasteTarget,
            visibleCardCount: model.visibleCards.count,
            isCollectionShown: model.isShowingCollection
        )
        switch PanelKeyBindings.action(for: keyEvent) {
        case .dismiss:
            dismiss()
        case .closePreview:
            model.closePreview()
        case .cancelEditor:
            model.cancelEditor()
        case .pasteSelection:
            if let itemID = model.pasteTarget { paste(itemID) }
        case .copySelection:
            if let itemID = model.pasteTarget { copy(itemID) }
        case .togglePreview:
            if let itemID = model.pasteTarget {
                Task { await model.openPreview(itemID) }
            }
        case .editSelection:
            if let itemID = model.pasteTarget {
                Task { await model.beginEditing(itemID) }
            }
        case .togglePin:
            if let itemID = model.pasteTarget {
                Task { await model.togglePin(itemID) }
            }
        case .pasteVisibleCard(let position):
            if model.visibleCards.indices.contains(position - 1) {
                paste(model.visibleCards[position - 1].id)
            }
        case .pasteIntoCollection:
            Task { await model.pasteClipboardIntoCollection() }
        case .none:
            return false
        }
        return true
    }

    /// Whether the keys belong to a text input.
    ///
    /// The search field takes the keyboard whenever the panel opens, so an empty one
    /// still counts as the grid: Return pastes, Space previews and, on the collection,
    /// ⌘V collects. Once the field holds text the user is searching, and the keys are
    /// left to it — except Return, which pastes in this panel by design. While a field
    /// is edited its window field editor is the first responder, which is why both are
    /// recognised here.
    private var isEditingText: Bool {
        guard let responder = panel?.firstResponder else { return false }
        if let textView = responder as? NSTextView {
            guard textView.isEditable else { return false }
            return !textView.isFieldEditor || !isIdleSearchField
        }
        if let textField = responder as? NSTextField, textField.isEditable {
            return !isIdleSearchField
        }
        return false
    }

    private var isIdleSearchField: Bool {
        model.queryText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private static func modifiers(from flags: NSEvent.ModifierFlags) -> HotkeyModifiers {
        var modifiers: HotkeyModifiers = []
        if flags.contains(.command) { modifiers.insert(.command) }
        if flags.contains(.option) { modifiers.insert(.option) }
        if flags.contains(.control) { modifiers.insert(.control) }
        if flags.contains(.shift) { modifiers.insert(.shift) }
        return modifiers
    }
}

extension PanelController: NSWindowDelegate {
    func windowDidResignKey(_ notification: Notification) {
        if model.section == .passwords, model.passwords.isBusy { return }
        // The Settings window or another application taking the keyboard while the panel
        // is open belongs to the user's flow; only leaving Copily dismisses the panel.
        guard settings.settings.dismissesOnOutsideClick else { return }
        guard !isOpening, !pointerIsInsideNotch else { return }
        guard !NSApp.isActive, isPointerOverMenuBarItem?() != true else { return }
        dismiss(restoreFocus: false)
    }
}

/// Carries an event from an AppKit callback into the main actor. Local event monitors
/// already run on the main thread; this only satisfies the sendability requirement.
private struct MainThreadEvent: @unchecked Sendable {
    let event: NSEvent
}
