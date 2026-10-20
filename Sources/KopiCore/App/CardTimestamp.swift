import Foundation

/// Timestamp shown on clipboard and note cards.
public enum CardTimestamp {
    /// "Just now", "5 min ago", "3 hr ago", "Yesterday", then an absolute date.
    public static func description(for date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        let elapsed = now.timeIntervalSince(date)
        if elapsed < 60 { return "Just now" }
        // Day boundaries are compared against `now` rather than against the clock, so
        // the description of a card never depends on when it is asked for.
        let days = calendar.dateComponents(
            [.day],
            from: calendar.startOfDay(for: date),
            to: calendar.startOfDay(for: now)
        ).day ?? 0
        if days == 0 {
            if elapsed < 3600 { return "\(Int(elapsed / 60)) min ago" }
            return "\(Int(elapsed / 3600)) hr ago"
        }
        if days == 1 { return "Yesterday" }
        return absolute(date, calendar: calendar)
    }

    /// Absolute date, for previews where the exact moment matters.
    public static func absolute(_ date: Date, calendar: Calendar = .current) -> String {
        formatter(.absolute, calendar: calendar).string(from: date)
    }

    /// Absolute date and time, used by the Notes tab and by previews.
    public static func detailed(_ date: Date, calendar: Calendar = .current) -> String {
        formatter(.detailed, calendar: calendar).string(from: date)
    }

    private enum Format: String {
        case absolute
        case detailed
    }

    /// Building a `DateFormatter` costs far more than using one, and these run once per
    /// card body evaluation, so formatters are kept per locale, time zone and style.
    private static func formatter(_ format: Format, calendar: Calendar) -> DateFormatter {
        let locale = calendar.locale ?? .current
        let key = "\(format.rawValue)|\(locale.identifier)|\(calendar.timeZone.identifier)"
        return cache.formatter(forKey: key) {
            let formatter = DateFormatter()
            formatter.locale = locale
            formatter.timeZone = calendar.timeZone
            formatter.dateStyle = .medium
            formatter.timeStyle = format == .absolute ? .none : .short
            return formatter
        }
    }

    private static let cache = FormatterCache()

    /// `DateFormatter` is thread-safe once configured, so the configured instances can
    /// be shared; the lock only guards the table itself.
    private final class FormatterCache: @unchecked Sendable {
        private let lock = NSLock()
        private var formatters: [String: DateFormatter] = [:]

        func formatter(forKey key: String, make: () -> DateFormatter) -> DateFormatter {
            lock.withLock {
                if let existing = formatters[key] { return existing }
                let formatter = make()
                formatters[key] = formatter
                return formatter
            }
        }
    }
}
