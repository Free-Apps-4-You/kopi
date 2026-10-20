import Foundation

/// Runs retention while Copily stays open, in addition to the startup and
/// retention-change passes.
public actor HistoryMaintenance {
    /// Cleanup periodicity required by the persistence design.
    public static let defaultInterval = Duration.seconds(300)

    private let store: HistoryStore
    private let interval: Duration
    private var loop: Task<Void, Never>?

    public init(store: HistoryStore, interval: Duration = HistoryMaintenance.defaultInterval) {
        self.store = store
        self.interval = interval
    }

    deinit {
        loop?.cancel()
    }

    public var isRunning: Bool {
        loop != nil
    }

    public func start(interval: Duration? = nil) {
        guard loop == nil else { return }
        let period = interval ?? self.interval
        let store = self.store
        loop = Task {
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: period)
                } catch {
                    return
                }
                guard !Task.isCancelled else { return }
                _ = try? await store.runCleanup(trigger: .periodic)
            }
        }
    }

    public func stop() {
        loop?.cancel()
        loop = nil
    }

    /// One maintenance pass, for callers that schedule cleanup themselves.
    @discardableResult
    public func runCleanup(trigger: HistoryCleanupTrigger = .periodic, now: Date = Date()) async throws -> HistoryCleanupReport {
        try await store.runCleanup(trigger: trigger, now: now)
    }
}
