import AppKit
import SwiftUI

/// App-owned tooltips use a consistent 100 ms delay without changing system preferences.
@MainActor
final class KopiTooltipPresenter {
    static let shared = KopiTooltipPresenter()
    static let delay: Duration = .milliseconds(100)
    private var owner: UUID?
    private var pending: Task<Void, Never>?
    private var panel: NSPanel?
    private var interactionMonitor: Any?
    private var menuObservers: [NSObjectProtocol] = []
    private(set) var isMenuTracking = false
    var hasPendingRequest: Bool { pending != nil }
    var isVisible: Bool { panel?.isVisible == true }

    private init() {
        interactionMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown, .keyDown]) { [weak self] event in
            MainActor.assumeIsolated { self?.hideAll() }
            return event
        }
        menuObservers.append(NotificationCenter.default.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.isMenuTracking = true
                self?.hideAll()
            }
        })
        menuObservers.append(NotificationCenter.default.addObserver(forName: NSMenu.didEndTrackingNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.isMenuTracking = false }
        })
    }
    func request(_ text: String, owner: UUID) {
        guard !isMenuTracking else { return }
        pending?.cancel(); panel?.orderOut(nil); self.owner = owner
        pending = Task { [weak self] in
            do { try await Task.sleep(for: Self.delay) } catch { return }
            guard let self, self.owner == owner else { return }
            let panel = self.panel ?? self.makePanel()
            panel.contentView = NSHostingView(rootView: Text(text).font(.system(size: 11)).lineLimit(4).frame(maxWidth: 320).padding(.horizontal, 8).padding(.vertical, 5).background(.regularMaterial).clipShape(RoundedRectangle(cornerRadius: 6)))
            let size = panel.contentView?.fittingSize ?? CGSize(width: 100, height: 24)
            let point = NSEvent.mouseLocation
            let screen = NSScreen.screens.first { $0.frame.contains(point) }?.visibleFrame ?? ScreenGeometry.fallback.visibleFrame
            panel.setFrame(CGRect(x: min(max(point.x + 10, screen.minX), screen.maxX - size.width),
                                  y: max(screen.minY, point.y - size.height - 12), width: size.width, height: size.height), display: false)
            panel.orderFrontRegardless()
        }
    }
    func hide(owner: UUID) {
        guard self.owner == owner else { return }
        pending?.cancel(); pending = nil; panel?.orderOut(nil); self.owner = nil
    }
    func hideAll() { pending?.cancel(); pending = nil; panel?.orderOut(nil); owner = nil }
    private func makePanel() -> NSPanel {
        let panel = NonActivatingPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.backgroundColor = .clear; panel.isOpaque = false; panel.hasShadow = true
        panel.isExcludedFromWindowsMenu = true
        panel.setAccessibilityElement(false)
        panel.level = .popUpMenu; panel.ignoresMouseEvents = true; panel.hidesOnDeactivate = true
        self.panel = panel
        return panel
    }
}
private struct KopiTooltip: ViewModifier {
    let text: String
    @StateObject private var identity = PanelState(UUID())
    func body(content: Content) -> some View {
        content.onHover { inside in
            if inside { KopiTooltipPresenter.shared.request(text, owner: identity.value) }
            else { KopiTooltipPresenter.shared.hide(owner: identity.value) }
        }.onDisappear { KopiTooltipPresenter.shared.hide(owner: identity.value) }
    }
}
extension View {
    func kopiTooltip(_ text: String) -> some View { modifier(KopiTooltip(text: text)) }
}

/// Native formatting controls share the same tooltip timing as SwiftUI controls.
final class KopiTooltipButton: NSButton {
    var hintText = ""
    private var tracking: NSTrackingArea?
    private let tooltipOwner = UUID()
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.activeAlways, .inVisibleRect, .mouseEnteredAndExited], owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }
    override func mouseEntered(with event: NSEvent) { KopiTooltipPresenter.shared.request(hintText, owner: tooltipOwner) }
    override func mouseExited(with event: NSEvent) { KopiTooltipPresenter.shared.hide(owner: tooltipOwner) }
}
