import Foundation

/// Runs `body` and gives what it returns, or nil when it hasn't finished within `limit` of real time (the body is cancelled then).
///
/// For a test that waits for something another task has to do: a test whose code is broken fails when the limit is up, and doesn't
/// wait for the suite's time limit. The body has to end when it is cancelled.
public func withinTimeLimit<T: Sendable>(_ limit: Duration, _ body: @escaping @Sendable () async -> T) async -> T? {
    await withTaskGroup(of: T?.self) { group in
        group.addTask { await body() }
        group.addTask {
            try? await Task.sleep(for: limit)
            return nil
        }
        let first = await group.next() ?? nil
        group.cancelAll()
        return first
    }
}

/// Waits, in real time and at most `limit`, until `condition` holds; whether it did.
public func waitUntil(_ limit: Duration = .seconds(5), _ condition: @escaping @Sendable () -> Bool) async -> Bool {
    await withinTimeLimit(limit) {
        while !condition() {
            guard (try? await Task.sleep(for: .milliseconds(1))) != nil else { return false }
        }
        return true
    } ?? false
}

extension FakeClock {
    /// `waitForSleepers`, but false, and not for ever, when that many don't come within `limit` of real time.
    public func waitForSleepers(_ count: Int, within limit: Duration) async -> Bool {
        await withinTimeLimit(limit) { [self] in
            await waitForSleepers(count)
            return sleeperCount >= count
        } ?? false
    }
}
