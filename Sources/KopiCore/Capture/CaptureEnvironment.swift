import Foundation

/// Delivers periodic capture ticks.
///
/// The interval is injected so the running app polls on the 250 ms cadence of the
/// design while tests drive capture one tick at a time, without a clock.
public protocol CaptureTicking: Sendable {
    /// Starts calling `tick` every `interval` until the returned handle is cancelled.
    func schedule(every interval: Duration, tick: @Sendable @escaping () async -> Void) async -> any CaptureTickHandle
}

/// A scheduled tick loop that can be stopped.
public protocol CaptureTickHandle: Sendable {
    /// Stops the schedule. The tick closure is not called again.
    func cancel()
}

/// Production schedule: a task that polls at a fixed interval until it is cancelled.
public struct TaskCaptureTicker: CaptureTicking {
    public init() {}

    public func schedule(every interval: Duration, tick: @Sendable @escaping () async -> Void) async -> any CaptureTickHandle {
        let task = Task {
            while !Task.isCancelled {
                await tick()
                guard !Task.isCancelled else { break }
                do {
                    try await Task.sleep(for: interval)
                } catch {
                    break
                }
            }
        }
        return TaskCaptureTickHandle(task: task)
    }
}

struct TaskCaptureTickHandle: CaptureTickHandle {
    let task: Task<Void, Never>

    func cancel() {
        task.cancel()
    }
}

/// System sleep and wake, so clipboard observation stops while the Mac is asleep.
public enum PasteboardLifecycleEvent: String, Sendable, Hashable, Codable, CaseIterable {
    case willSleep
    case didWake
}

/// Source of sleep and wake events.
public protocol PasteboardLifecycleObserving: Sendable {
    /// Starts observing. The handler is called for every event until the returned
    /// observation is cancelled.
    func observe(
        _ handler: @Sendable @escaping (PasteboardLifecycleEvent) async -> Void
    ) async -> any PasteboardLifecycleObservation
}

/// A started lifecycle observation.
public protocol PasteboardLifecycleObservation: Sendable {
    func cancel()
}

/// Lookup of the application that is frontmost when the clipboard changes. Injected
/// so the source app recorded on a card is deterministic under test.
public protocol FrontmostAppProviding: Sendable {
    /// The frontmost application, or `nil` when the system cannot say.
    func frontmostApp() -> SourceAppInfo?
}

/// Applications Kopi must not capture from.
///
/// Matching is by bundle identifier and is case-insensitive, so identifiers entered
/// by hand still match what the system reports.
public struct ExcludedApplications: Sendable, Hashable, Codable {
    public var bundleIdentifiers: Set<String>

    public init(bundleIdentifiers: Set<String> = []) {
        self.bundleIdentifiers = Set(bundleIdentifiers.map { $0.lowercased() })
    }

    public var isEmpty: Bool { bundleIdentifiers.isEmpty }

    public func excludes(_ app: SourceAppInfo?) -> Bool {
        guard let identifier = app?.bundleIdentifier?.lowercased(), !identifier.isEmpty else { return false }
        return bundleIdentifiers.contains(identifier)
    }

    public mutating func exclude(_ bundleIdentifier: String) {
        bundleIdentifiers.insert(bundleIdentifier.lowercased())
    }

    public mutating func include(_ bundleIdentifier: String) {
        bundleIdentifiers.remove(bundleIdentifier.lowercased())
    }
}
