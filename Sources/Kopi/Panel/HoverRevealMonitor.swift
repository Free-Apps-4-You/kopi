import AppKit
import Foundation
import KopiCore

/// Mouse-only monitors catch fast entries and exits; a one-shot timer completes stationary dwells.
@MainActor
final class HoverRevealMonitor {
    var onReveal: (() -> Void)?
    private var timer: Timer?
    private var deadlineTimer: Timer?
    private var scheduledDeadline: TimeInterval?
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var observers: [NSObjectProtocol] = []
    private var workspaceObservers: [NSObjectProtocol] = []
    private var state = NotchHoverState()
    private var targets: [CGRect] = []
    private var isEnabled = false
    private var isActive = true
    private var delay = HoverReveal.default.delay
    var isRunning: Bool { timer != nil }

    func configure(enabled: Bool, delay: TimeInterval, onReveal: @escaping () -> Void) {
        self.onReveal = onReveal
        self.delay = delay.isFinite ? max(0.1, delay) : HoverReveal.default.delay
        isEnabled = enabled
        if enabled && isActive { start() } else { stop() }
    }

    func setActive(_ active: Bool) {
        isActive = active
        if isEnabled && active { start() } else { stop() }
    }

    func start() {
        guard isEnabled, isActive, !isRunning else { return }
        refreshTargets()
        let mask: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged]
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] event in
            MainActor.assumeIsolated { self?.handle(event) }
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            MainActor.assumeIsolated { self?.handle(event) }
            return event
        }
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.refreshTargets() } })
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.activeSpaceDidChangeNotification, NSWorkspace.willSleepNotification] {
            workspaceObservers.append(NSWorkspace.shared.notificationCenter.addObserver(
                forName: name, object: nil, queue: .main
            ) { [weak self] _ in MainActor.assumeIsolated { self?.refreshTargets() } })
        }
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.sample() }
        }
        timer.tolerance = 0.02
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        sample()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        cancelDeadline()
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        globalMonitor = nil
        localMonitor = nil
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
        workspaceObservers.forEach(NSWorkspace.shared.notificationCenter.removeObserver)
        workspaceObservers.removeAll()
        state.reset()
    }

    func suppressUntilPointerLeaves() {
        state.suppress(at: NSEvent.mouseLocation, targets: targets)
        cancelDeadline()
    }

    private func refreshTargets() {
        targets = NSScreen.screens.map { PanelGeometry.triggerRect(for: ScreenGeometry.geometry(for: $0)) }.filter { !$0.isEmpty }
        state.reset()
        cancelDeadline()
    }

    private func handle(_ event: NSEvent) {
        // Preserve queued exit/re-entry positions, then check the current pointer before revealing.
        let point = event.window.map { $0.convertPoint(toScreen: event.locationInWindow) } ?? event.locationInWindow
        _ = state.update(point: point, targets: targets, now: event.timestamp, delay: delay)
        sample()
    }

    private func sample() {
        guard isEnabled, isActive else { return }
        let now = ProcessInfo.processInfo.systemUptime
        guard let deadline = state.update(point: NSEvent.mouseLocation, targets: targets, now: now, delay: delay) else {
            cancelDeadline()
            return
        }
        if now >= deadline {
            suppressUntilPointerLeaves()
            onReveal?()
        } else if scheduledDeadline != deadline {
            cancelDeadline()
            scheduledDeadline = deadline
            let timer = Timer(timeInterval: deadline - now, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.scheduledDeadline = nil
                    self?.sample()
                }
            }
            RunLoop.main.add(timer, forMode: .common)
            deadlineTimer = timer
        }
    }

    private func cancelDeadline() {
        deadlineTimer?.invalidate()
        deadlineTimer = nil
        scheduledDeadline = nil
    }
}
