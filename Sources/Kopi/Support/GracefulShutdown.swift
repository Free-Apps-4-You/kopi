import Foundation

/// Allows persistence to finish without making Quit wait indefinitely for an
/// uncooperative operation. A structured task-group race would still wait for its
/// cancelled child before returning.
@MainActor
enum GracefulShutdown {
    static func wait(
        timeout: Duration = .seconds(2),
        operation: @escaping @MainActor () async -> Void
    ) async {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        await withCheckedContinuation { continuation in
            let completion = Completion(continuation)
            Task {
                await operation()
                completion.finish()
            }
            completion.timer = Task {
                do { try await Task.sleep(until: deadline, clock: .continuous) }
                catch { return }
                completion.finish()
            }
        }
    }

    @MainActor
    private final class Completion {
        private var continuation: CheckedContinuation<Void, Never>?
        var timer: Task<Void, Never>?

        init(_ continuation: CheckedContinuation<Void, Never>) {
            self.continuation = continuation
        }

        func finish() {
            guard let continuation else { return }
            self.continuation = nil
            timer?.cancel()
            timer = nil
            continuation.resume()
        }
    }
}
