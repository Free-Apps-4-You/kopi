import AppKit
import SwiftUI
import KopiCore

@MainActor
final class RadialState: ObservableObject {
    @Published var items: [ClipboardItemSummary] = []
    @Published var selected: Int?
    @Published var controlsY = RadialGeometry.dockCenterY
    @Published var page = 0
    @Published var totalCount = 0
    @Published var loading = false
    @Published var presented = false
    @Published var trigger = RadialTrigger.optionSpace
    @Published var copiesOnly = false
    @Published var message = "No cards here yet"
    var pageCount: Int { max(1, (totalCount + 7) / 8) }
    var selectedItem: ClipboardItemSummary? {
        guard let selected, items.indices.contains(selected), !loading else { return nil }
        return items[selected]
    }
}

/// A held Carbon shortcut avoids requesting Input Monitoring just to open the ring.
@MainActor
final class RadialController {
    private let store: HistoryStore
    private let service: ClipboardService
    private let previews: PreviewStore
    private weak var clipboardPanel: PanelController?
    private let hotkey = GlobalHotKey(identifier: 2)
    private let state = RadialState()
    private let toast = PanelToastController()
    private var window: KopiPanel?
    private var timer: Timer?
    private var monitor: Any?
    private var resignObserver: (any NSObjectProtocol)?
    private var target: NSRunningApplication?
    private var generation = UUID()
    private var loadTask: Task<Void, Never>?
    private var lastScroll = Date.distantPast
    private var center = NSPoint.zero
    private var activationPoint = NSPoint.zero
    private var lastPointer = NSPoint.zero
    private var isOpen = false
    private var cache: [Int: HistoryPageResult] = [:]

    init(store: HistoryStore, service: ClipboardService, previews: PreviewStore, panel: PanelController) {
        self.store = store
        self.service = service
        self.previews = previews
        clipboardPanel = panel
    }

    func configure(enabled: Bool, trigger: RadialTrigger, copiesOnly: Bool) {
        if !enabled || state.trigger != trigger { finish(commit: false) }
        state.trigger = trigger
        state.copiesOnly = copiesOnly
        let registered = hotkey.register(enabled ? trigger.hotkey : nil,
            onPress: { [weak self] in self?.open() },
            onRelease: { [weak self] in self?.finish(commit: true) })
        if enabled && !registered {
            toast.show("Radial shortcut \(trigger.title) is already in use", on: ScreenGeometry.displayUnderPointer())
        }
    }

    func show() { open() }

    private func open() {
        guard !isOpen, clipboardPanel?.isVisible != true else { return }
        isOpen = true
        generation = UUID()
        cache.removeAll()
        target = NSWorkspace.shared.frontmostApplication
        state.page = 0
        state.totalCount = 0
        state.items = []
        state.selected = nil
        state.controlsY = RadialGeometry.dockCenterY
        state.presented = false
        let pointer = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(pointer) } ?? NSScreen.main
        let bounds = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1000, height: 800)
        let width = CGFloat(RadialGeometry.windowWidth)
        let height = CGFloat(RadialGeometry.windowHeight)
        let above = CGFloat(RadialGeometry.wheelCenterY)
        let below = height - above
        center = NSPoint(x: min(max(pointer.x, bounds.minX + width / 2), bounds.maxX - width / 2),
                         y: min(max(pointer.y, bounds.minY + below), bounds.maxY - above))
        let window = self.window ?? KopiPanel.make()
        self.window = window
        window.contentView = RadialWindowContent(rootView: RadialView(state: state, previews: previews,
            choose: { [weak self] index in self?.finish(commit: true, chosen: index) },
            page: { [weak self] delta in self?.switchPage(delta) },
            cancel: { [weak self] in self?.finish(commit: false) }))
        window.setFrame(NSRect(x: center.x - width / 2, y: center.y - below, width: width, height: height), display: true)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        activationPoint = pointer
        lastPointer = pointer
        load()
        state.presented = true
        (window.contentView as? RadialWindowContent)?.setPresented(true)
        resignObserver = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.finish(commit: false, restoreFocus: false) }
        }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .scrollWheel, .leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self else { return event }
            if event.type == .keyDown { return self.handleKey(event) ? nil : event }
            if event.type == .rightMouseDown { self.finish(commit: false); return nil }
            if event.type == .leftMouseDown, event.window !== self.window {
                self.finish(commit: false, restoreFocus: false); return event
            }
            if event.type == .leftMouseDown, event.window === self.window {
                let pointer = NSEvent.mouseLocation
                let x = pointer.x - self.center.x
                let y = pointer.y - self.center.y
                let dockTop = CGFloat(self.state.controlsY - RadialGeometry.wheelCenterY - 36)
                let dockBottom = CGFloat(RadialGeometry.windowHeight - RadialGeometry.wheelCenterY)
                let inDock = abs(x) < 180 && y < -dockTop && y > -dockBottom
                let inCancel = hypot(x, y) < RadialGeometry.cancelRadius
                if hypot(x, y) > RadialGeometry.outerRadius * RadialGeometry.hoverScale + 1 && !inDock && !inCancel {
                    self.finish(commit: false); return nil
                }
            }
            if event.type == .scrollWheel {
                guard event.momentumPhase.isEmpty else { return nil }
                let horizontal = abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY)
                let delta = horizontal ? event.scrollingDeltaX : event.scrollingDeltaY
                if abs(delta) > 1, Date().timeIntervalSince(self.lastScroll) > 0.2 {
                    self.lastScroll = Date()
                    self.switchPage(delta < 0 ? 1 : -1)
                }
                return nil
            }
            return event
        }
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateSelection() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func handleKey(_ event: NSEvent) -> Bool {
        switch event.keyCode {
        case 53: finish(commit: false)
        case 36, 76: finish(commit: true)
        case 123: switchPage(-1)
        case 124: switchPage(1)
        case 48: selectNext(backwards: event.modifierFlags.contains(.shift))
        case 125, 126: selectNext(backwards: event.keyCode == 126)
        default:
            if let character = event.charactersIgnoringModifiers?.first, let number = character.wholeNumberValue,
               (1...8).contains(number), state.items.indices.contains(number - 1), !state.loading {
                state.selected = number - 1
                lastPointer = NSEvent.mouseLocation
            } else { return false }
        }
        return true
    }

    private func updateSelection() {
        guard !state.loading else { return }
        let pointer = NSEvent.mouseLocation
        guard hypot(pointer.x - lastPointer.x, pointer.y - lastPointer.y) > 0.5 else { return }
        lastPointer = pointer
        let x = pointer.x - center.x
        let y = pointer.y - center.y
        let isAtOrigin = hypot(pointer.x - activationPoint.x, pointer.y - activationPoint.y) < 12
        let controlsBoundary = CGFloat(state.controlsY - RadialGeometry.wheelCenterY - 36)
        let selection = isAtOrigin || y < -controlsBoundary ? nil : RadialSelection.index(x: x, y: y, count: state.items.count, previous: state.selected)
        if state.selected != selection { state.selected = selection }
    }

    private func selectNext(backwards: Bool) {
        guard !state.loading, !state.items.isEmpty else { return }
        let count = state.items.count
        let index = state.selected ?? (backwards ? 0 : -1)
        state.selected = (index + (backwards ? count - 1 : 1)) % count
        lastPointer = NSEvent.mouseLocation
    }

    private func switchPage(_ delta: Int) {
        guard !state.loading else { return }
        let page = min(max(state.page + delta, 0), state.pageCount - 1)
        guard page != state.page else { return }
        state.page = page
        load()
    }

    private func load() {
        loadTask?.cancel()
        generation = UUID()
        let token = generation
        let page = state.page
        let key = page
        state.selected = nil
        state.loading = true
        lastPointer = NSEvent.mouseLocation
        if let cached = cache[key] { apply(cached); return }
        loadTask = Task { @MainActor [weak self, store] in
            do {
                let result = try await store.page(HistoryQuery(includesCollection: false, page: HistoryPage(offset: page * 8, limit: 8)))
                guard let self, self.isOpen, self.generation == token, !Task.isCancelled else { return }
                self.cache[key] = result
                self.apply(result)
            } catch {
                guard let self, self.isOpen, self.generation == token else { return }
                self.state.items = []
                self.state.totalCount = 0
                self.state.loading = false
                self.state.message = "Couldn’t load cards. Reopen to retry."
            }
        }
    }

    private func apply(_ result: HistoryPageResult) {
        state.items = result.items
        state.totalCount = result.totalCount
        state.loading = false
        state.message = "Copy something to get started."
    }

    private func finish(commit: Bool, restoreFocus: Bool = true, chosen: Int? = nil) {
        guard isOpen else { return }
        if commit {
            if let chosen { state.selected = chosen } else { updateSelection() }
        }
        let item = commit ? state.selectedItem : nil
        let copiesOnly = state.copiesOnly
        isOpen = false
        generation = UUID()
        loadTask?.cancel()
        timer?.invalidate(); timer = nil
        if let monitor { NSEvent.removeMonitor(monitor) }; monitor = nil
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }; resignObserver = nil
        state.presented = false
        (window?.contentView as? RadialWindowContent)?.setPresented(false)
        let window = window
        let reduced = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let delay: Duration = reduced || !restoreFocus ? .zero : .milliseconds(110)
        let closing = generation
        let target = target
        Task { @MainActor [self] in
            if delay != .zero { try? await Task.sleep(for: delay) }
            let canRestore = generation == closing && !isOpen
            if canRestore { window?.orderOut(nil) }
            guard let item else {
                if canRestore, restoreFocus, let target, target.processIdentifier != ProcessInfo.processInfo.processIdentifier { target.activate() }
                return
            }
            do {
                _ = try await service.copyToPasteboard(item.id)
                let canPaste = generation == closing && !isOpen
                if canPaste, restoreFocus, let target, !target.isTerminated { target.activate() }
                guard !copiesOnly, canPaste, let target, !target.isTerminated,
                      target.processIdentifier != ProcessInfo.processInfo.processIdentifier else {
                    toast.show(copiesOnly ? "Copied to clipboard" : "Copied — press ⌘V to paste", on: ScreenGeometry.displayUnderPointer()); return
                }
                try? await Task.sleep(for: .milliseconds(100))
                if !PasteSynthesizer().paste(into: target.processIdentifier) {
                    toast.show("Copied — press ⌘V to paste", on: ScreenGeometry.displayUnderPointer())
                }
            } catch {
                toast.show("Couldn’t copy this card", on: ScreenGeometry.displayUnderPointer())
            }
        }
    }
}
