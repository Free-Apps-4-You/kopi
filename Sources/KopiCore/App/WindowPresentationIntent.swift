import Foundation

/// Explicit panel actions can reopen the panel while Settings exists. Activation
/// and application-reopen callbacks must respect an in-progress Settings handoff.
public struct WindowPresentationIntent: Sendable {
    public enum Destination: Sendable, Equatable { case panel, settings }
    public private(set) var destination: Destination = .panel
    private var settingsHandoff: UUID?

    public init() {}
    public var isHandingOffToSettings: Bool { settingsHandoff != nil }

    @discardableResult
    public mutating func requestPanel() -> Bool {
        guard !isHandingOffToSettings else { return false }
        destination = .panel
        return true
    }

    public mutating func requestSettings() -> UUID {
        let token = UUID()
        destination = .settings
        settingsHandoff = token
        return token
    }

    public func isCurrentSettingsRequest(_ token: UUID) -> Bool { settingsHandoff == token }

    public mutating func finishSettingsRequest(_ token: UUID) {
        guard isCurrentSettingsRequest(token) else { return }
        settingsHandoff = nil
    }

    public func shouldFocusSettingsOnReopen(settingsAreVisible: Bool) -> Bool {
        isHandingOffToSettings || (destination == .settings && settingsAreVisible)
    }
}
