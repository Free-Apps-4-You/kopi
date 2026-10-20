import Testing
@testable import Copily

@Suite("Hover monitor lifecycle")
@MainActor
struct HoverMonitorTests {
    @Test func changingSettingsDoesNotResumeWhilePanelIsOpen() {
        let monitor = HoverRevealMonitor()
        monitor.setActive(false)
        monitor.configure(enabled: true, delay: 0.1, onReveal: {})
        #expect(!monitor.isRunning)
        monitor.configure(enabled: true, delay: 0.5, onReveal: {})
        #expect(!monitor.isRunning)
        monitor.stop()
    }

    @Test func disabledHoverStaysStoppedWhenPanelCloses() {
        let monitor = HoverRevealMonitor()
        monitor.configure(enabled: false, delay: 0.1, onReveal: {})
        monitor.setActive(false)
        monitor.setActive(true)
        #expect(!monitor.isRunning)
    }
}
