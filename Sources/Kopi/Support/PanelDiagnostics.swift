import os

/// Lifecycle-only debug events; clipboard content and window titles are never logged.
enum PanelDiagnostics {
    private static let logger = Logger(subsystem: "com.kopi.app", category: "Panel")
    static func event(_ event: String) { logger.debug("\(event, privacy: .public)") }
}
