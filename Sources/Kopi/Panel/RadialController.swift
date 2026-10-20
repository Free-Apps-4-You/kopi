import AppKit
import SwiftUI
import KopiCore

@MainActor
final class RadialState: ObservableObject {
    @Published var items: [ClipboardItemSummary] = []
    @Published var selected: Int?
    @Published var ring = 0
    @Published var page = 0
    @Published var totalCount = 0
    @Published var loading = false
    @Published var presented = false
    @Published var trigger = RadialTrigger.optionSpace
    @Published var copiesOnly = false
    @Published var message = "No cards here yet"
    let names = ["Recent", "Pinned", "Collection"]
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

    init(store: HistoryStore, service: ClipboardService, panel: PanelController) {
        self.store = store
        self.service = service
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
        state.ring = 0
        state.page = 0
        state.totalCount = 0
        state.items = []
        state.selected = nil
        state.presented = false
        let pointer = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(pointer) } ?? NSScreen.main
        let bounds = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1000, height: 800)
        let size: CGFloat = 600
        center = NSPoint(x: min(max(pointer.x, bounds.minX + size / 2), bounds.maxX - size / 2),
                         y: min(max(pointer.y, bounds.minY + size / 2), bounds.maxY - size / 2))
        let window = self.window ?? KopiPanel.make()
        self.window = window
        window.contentView = NSHostingView(rootView: RadialView(state: state,
            choose: { [weak self] index in self?.finish(commit: true, chosen: index) },
            ring: { [weak self] ring in self?.switchRing(ring) },
            page: { [weak self] delta in self?.switchPage(delta) },
            cancel: { [weak self] in self?.finish(commit: false) }))
        window.setFrame(NSRect(x: center.x - size / 2, y: center.y - size / 2, width: size, height: size), display: true)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        activationPoint = pointer
        lastPointer = pointer
        load()
        state.presented = true
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
            if event.type == .scrollWheel {
                guard event.momentumPhase.isEmpty else { return nil }
                let horizontal = abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY)
                let delta = horizontal ? event.scrollingDeltaX : event.scrollingDeltaY
                if abs(delta) > 1, Date().timeIntervalSince(self.lastScroll) > 0.2 {
                    self.lastScroll = Date()
                    if horizontal || event.modifierFlags.contains(.shift) {
                        self.switchPage(delta < 0 ? 1 : -1)
                    } else {
                        self.switchRing((self.state.ring + (delta > 0 ? 2 : 1)) % 3)
                    }
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
        case 48: switchRing((state.ring + (event.modifierFlags.contains(.shift) ? 2 : 1)) % 3)
        case 125, 126:
            guard !state.loading, !state.items.isEmpty else { return true }
            let count = state.items.count
            let index = state.selected ?? (event.keyCode == 125 ? -1 : 0)
            state.selected = (index + (event.keyCode == 125 ? 1 : count - 1)) % count
            lastPointer = NSEvent.mouseLocation
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
        let selection = isAtOrigin || y < -225 ? nil : RadialSelection.index(x: x, y: y, count: state.items.count, previous: state.selected)
        if state.selected != selection { state.selected = selection }
    }

    private func switchRing(_ ring: Int) {
        guard (0..<3).contains(ring), state.ring != ring else { return }
        state.ring = ring
        state.page = 0
        load()
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
        let scope: HistoryScope = [.allClipboard, .pinned, .collection][state.ring]
        let page = state.page
        let key = page * 3 + state.ring
        state.selected = nil
        state.loading = true
        lastPointer = NSEvent.mouseLocation
        if let cached = cache[key] { apply(cached); return }
        loadTask = Task { @MainActor [weak self, store] in
            do {
                let result = try await store.page(HistoryQuery(scope: scope, page: HistoryPage(offset: page * 8, limit: 8)))
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
        state.message = state.ring == 1 ? "Pin a card in the panel to keep it here." :
            state.ring == 2 ? "Save a card to Collection to keep it here." : "Copy something to get started."
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
