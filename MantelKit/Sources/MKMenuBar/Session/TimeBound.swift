import Foundation
import MKCore

/// Waiting for work for a limited time, without stopping it.
enum TimeBound {
    /// Runs `operation` and returns true when it finishes within `limit` of the clock's time, or false when the limit comes first. When it
    /// does, the work isn't cancelled: it carries on by itself, and nothing waits for it.
    ///
    /// For work that must not be cut short (a teardown that has a side effect in the system) but that the caller can't wait for for ever.
    static func finishes(within limit: Duration, clock: any Clock, operation: @escaping @Sendable () async -> Void) async -> Bool {
        let (outcomes, signal) = AsyncStream.makeStream(of: Bool.self)
        Task {
            await operation()
            signal.yield(true)
        }
        let timer = Task {
            guard (try? await clock.sleep(for: limit)) != nil else { return }
            signal.yield(false)
        }
        var iterator = outcomes.makeAsyncIterator()
        let finished = await iterator.next() ?? false
        timer.cancel()
        signal.finish()
        return finished
    }
}
