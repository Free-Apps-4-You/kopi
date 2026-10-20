import AppKit
import SwiftUI
import KopiCore

@MainActor
final class RadialState: ObservableObject {
    @Published var items: [ClipboardItemSummary] = []
    @Published var selected: Int?
    @Published var ring = 0
    @Published var trigger = RadialTrigger.optionSpace
    @Published var message = "Loading clipboard…"
    let names = ["Recent", "Pinned", "Collection"]
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
    private var isOpen = false

    init(store: HistoryStore, service: ClipboardService, panel: PanelController) {
        self.store = store
        self.service = service
        clipboardPanel = panel
    }

    func configure(enabled: Bool, trigger: RadialTrigger) {
        if !enabled || state.trigger != trigger { finish(commit: false) }
        state.trigger = trigger
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
        target = NSWorkspace.shared.frontmostApplication
        state.ring = 0
        state.selected = nil
        let pointer = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(pointer) } ?? NSScreen.main
        let bounds = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1000, height: 800)
        let size: CGFloat = 520
        center = NSPoint(x: min(max(pointer.x, bounds.minX + size / 2), bounds.maxX - size / 2),
                         y: min(max(pointer.y, bounds.minY + size / 2), bounds.maxY - size / 2))
        // Keep the cancellation origin at the pointer, including close to screen edges.
        let origin = NSPoint(x: pointer.x - (center.x - size / 2), y: size - (pointer.y - (center.y - size / 2)))
        let window = self.window ?? KopiPanel.make()
        self.window = window
        window.contentView = NSHostingView(rootView: RadialView(state: state, origin: origin,
            choose: { [weak self] index in self?.finish(commit: true, chosen: index) }))
        window.setFrame(NSRect(x: center.x - size / 2, y: center.y - size / 2, width: size, height: size), display: true)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        activationPoint = pointer
        load()
        resignObserver = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.finish(commit: false, restoreFocus: false) }
        }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .scrollWheel, .leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self else { return event }
            if event.type == .keyDown && event.keyCode == 53 { self.finish(commit: false); return nil }
            if event.type == .rightMouseDown { self.finish(commit: false); return nil }
            if event.type == .leftMouseDown, event.window !== self.window { self.finish(commit: false, restoreFocus: false); return event }
            if event.type == .scrollWheel {
                if abs(event.scrollingDeltaY) > 1, Date().timeIntervalSince(self.lastScroll) > 0.25 {
                    self.lastScroll = Date()
                    self.state.ring = (self.state.ring + (event.scrollingDeltaY > 0 ? 2 : 1)) % 3
                    self.load()
                }
                return nil
            }
            return event
        }
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateSelection() }
        }
    }

    private func updateSelection() {
        let pointer = NSEvent.mouseLocation
        guard hypot(pointer.x - activationPoint.x, pointer.y - activationPoint.y) >= 12 else {
            state.selected = nil; return
        }
        state.selected = RadialSelection.index(x: pointer.x - center.x, y: pointer.y - center.y, count: state.items.count)
    }

    private func load() {
        loadTask?.cancel()
        generation = UUID()
        let token = generation
        let scope: HistoryScope = [.allClipboard, .pinned, .collection][state.ring]
        state.items = []
        state.selected = nil
        state.message = "Loading clipboard…"
        loadTask = Task { @MainActor [weak self, store] in
            do {
                let result = try await store.page(HistoryQuery(scope: scope))
                guard let self, self.isOpen, self.generation == token, !Task.isCancelled else { return }
                self.state.items = Array(result.items.prefix(8))
                self.state.message = self.state.items.isEmpty ? "No cards here yet" : "Move to a card"
            } catch {
                guard let self, self.isOpen, self.generation == token else { return }
                self.state.message = "Couldn’t load cards"
            }
        }
    }

    private func finish(commit: Bool, restoreFocus: Bool = true, chosen: Int? = nil) {
        guard isOpen else { return }
        if commit {
            if let chosen { state.selected = chosen } else { updateSelection() }
        }
        let item = commit ? state.selected.flatMap { state.items.indices.contains($0) ? state.items[$0] : nil } : nil
        isOpen = false
        generation = UUID()
        loadTask?.cancel()
        timer?.invalidate(); timer = nil
        if let monitor { NSEvent.removeMonitor(monitor) }; monitor = nil
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }; resignObserver = nil
        window?.orderOut(nil)
        guard let item else {
            if restoreFocus, let target, target.processIdentifier != ProcessInfo.processInfo.processIdentifier { target.activate() }
            return
        }
        let target = target
        Task { @MainActor [self] in
            do {
                _ = try await service.copyToPasteboard(item.id)
                guard let target, !target.isTerminated, target.processIdentifier != ProcessInfo.processInfo.processIdentifier else {
                    toast.show("Copied — press ⌘V to paste", on: ScreenGeometry.displayUnderPointer()); return
                }
                target.activate()
                try? await Task.sleep(for: .milliseconds(120))
                if !PasteSynthesizer().paste(into: target.processIdentifier) {
                    toast.show("Copied — press ⌘V to paste", on: ScreenGeometry.displayUnderPointer())
                }
            } catch {
                toast.show("Couldn’t copy this card", on: ScreenGeometry.displayUnderPointer())
            }
        }
    }
}

private struct RadialView: View {
    @ObservedObject var state: RadialState
    let origin: CGPoint
    let choose: (Int) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @StateObject private var entrance = PanelState<Bool>(false)

    var body: some View {
        ZStack {
            Circle().fill(KopiTheme.surface).frame(width: 420, height: 420)
                .overlay(Circle().strokeBorder(KopiTheme.accent.opacity(0.16), lineWidth: 1))
                .shadow(color: .black.opacity(0.25), radius: 20, y: 8)
                .position(x: 260, y: 260)
            ForEach(Array(state.items.enumerated()), id: \.element.id) { index, item in
                let angle = Double(index) * 2 * .pi / Double(max(1, state.items.count)) - .pi / 2
                let selected = state.selected == index
                Button { choose(index) } label: {
                    VStack(spacing: 5) {
                        Image(systemName: item.isPinned ? "pin.fill" : symbol(item))
                            .font(.system(size: 19, weight: .semibold))
                        Text(item.displayTitle).font(.system(size: 11, weight: .medium)).lineLimit(2)
                            .multilineTextAlignment(.center).frame(width: 94, height: 28)
                    }
                    .foregroundStyle(selected ? Color.white : Color.primary)
                    .frame(width: 100, height: 72)
                    .background(selected ? KopiTheme.accent : KopiTheme.controlSurface,
                                in: RoundedRectangle(cornerRadius: 18))
                    .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(selected ? KopiTheme.accent : Color.primary.opacity(0.08)))
                    .scaleEffect(selected ? 1.06 : 1)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Paste \(item.displayTitle)")
                .position(x: 260 + cos(angle) * 160, y: 260 + sin(angle) * 160)
            }
            VStack(spacing: 6) {
                Text("Kopi").font(.system(size: 12, weight: .semibold)).foregroundStyle(KopiTheme.accent)
                Text(state.names[state.ring]).font(.system(size: 18, weight: .bold, design: .rounded))
                Text(state.selected.map { "Release to paste #\($0 + 1)" } ?? state.message)
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                Text("\(state.trigger.title) · Scroll to switch").font(.system(size: 9)).foregroundStyle(.secondary)
            }.frame(width: 150).position(x: 260, y: 260).allowsHitTesting(false)
        }
        .frame(width: 520, height: 520)
        .scaleEffect(entrance.value ? 1 : 0.94, anchor: UnitPoint(x: origin.x / 520, y: origin.y / 520))
        .opacity(entrance.value ? 1 : 0)
        .animation(reduceMotion ? nil : .spring(response: 0.22, dampingFraction: 0.82), value: entrance.value)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.1), value: state.selected)
        .onAppear { entrance.value = true }
    }

    private func symbol(_ item: ClipboardItemSummary) -> String {
        switch item.kind {
        case .text: "text.alignleft"
        case .link: "link"
        case .image: "photo"
        default: "doc.on.doc"
        }
    }
}
