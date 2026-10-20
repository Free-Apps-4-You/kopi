import Foundation

/// History retention setting, as offered in Settings.
public enum HistoryRetention: String, Sendable, Codable, CaseIterable, Identifiable, Hashable {
    /// Kept until Copily quits or restarts.
    case currentSession
    case sevenDays
    case thirtyDays

    public static let `default`: HistoryRetention = .sevenDays

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .currentSession: "Current session"
        case .sevenDays: "7 days"
        case .thirtyDays: "30 days"
        }
    }

    /// Time an unpinned item survives since its last external copy, or `nil` when
    /// retention is bounded by the current run instead of by the clock.
    public var timeToLive: TimeInterval? {
        switch self {
        case .currentSession: nil
        case .sevenDays: 7 * 24 * 60 * 60
        case .thirtyDays: 30 * 24 * 60 * 60
        }
    }

    public var isSessionScoped: Bool {
        self == .currentSession
    }

    /// Items last copied before this instant are expired, or `nil` for
    /// session-scoped retention.
    public func expirationCutoff(now: Date) -> Date? {
        guard let timeToLive else { return nil }
        return now.addingTimeInterval(-timeToLive)
    }
}
