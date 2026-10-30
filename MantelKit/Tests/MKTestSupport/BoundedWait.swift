import Foundation

/// How long a test waits for something that has to happen before it is called hung: far longer than anything takes, on a Mac that is
/// busy with other builds (a load average of 30 to 70 is usual here, and a task can wait seconds for a thread). Waits end when
/// what they wait for happens, so this is only ever spent on a test that is broken.
public let hungTestLimit: Duration = .seconds(30)

/// Runs `body` and gives what it returns, or nil when it hasn't finished within `limit` of real time (the body is cancelled then).
///
/// For a test that waits for something another task has to do: a test whose code is broken fails when the limit is up, and doesn't
/// wait for the suite's time limit. The body has to end when it is cancelled.
///
/// A limit of a second or more only says when a wait has hung, so it is at least `hungTestLimit`: how long a busy machine takes to run
/// the other task must not decide a pass. A shorter limit is taken as it is (a poll's interval, not a bound on a wait).
public func withinTimeLimit<T: Sendable>(_ limit: Duration, _ body: @escaping @Sendable () async -> T) async -> T? {
    let limit = limit >= .seconds(1) ? max(limit, hungTestLimit) : limit
    return await withTaskGroup(of: T?.self) { group in
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

/// Waits until `condition` holds; whether it did. The limit only ends a wait that hangs (see `withinTimeLimit`).
public func waitUntil(_ limit: Duration = hungTestLimit, _ condition: @escaping @Sendable () -> Bool) async -> Bool {
    await withinTimeLimit(limit) {
        while !condition() {
            guard (try? await Task.sleep(for: .milliseconds(1))) != nil else { return false }
        }
        return true
    } ?? false
}

extension FakeClock {
    /// `waitForSleepers`, but false, and not for ever, when that many don't come within `limit` of real time. A limit of a second or more
    /// is a bound on a wait that hangs, not on how long the sleepers take (see `withinTimeLimit`); a shorter one is a poll, which comes
    /// back false when nothing has slept yet, and which no test may take as meaning that nothing will.
    public func waitForSleepers(_ count: Int, within limit: Duration) async -> Bool {
        await withinTimeLimit(limit) { [self] in
            await waitForSleepers(count)
            return sleeperCount >= count
        } ?? false
    }
}

extension FakeClock {
    /// Moves the clock `step` at a time, each time something sleeps on it, until `done` holds; false if that doesn't happen before the
    /// test is called hung. Nothing here is bound by real time but that: a loaded machine makes it slower, and the clock is never moved
    /// when nothing sleeps on it, so a sleeper that hasn't registered yet isn't passed.
    public func advance(by step: Duration, until done: @escaping @Sendable () async -> Bool) async -> Bool {
        await withinTimeLimit(hungTestLimit) { [self] in
            while await !done() {
                if sleeperCount > 0 {
                    advance(by: step)
                    await Task.yield()
                } else {
                    guard (try? await Task.sleep(for: .milliseconds(1))) != nil else { return false }
                }
            }
            return true
        } ?? false
    }
}

/// Lets the tasks that are ready run, for a test that has started something and has to know it has got as far as it will get without
/// anything moving the clock or opening a gate: some turns of the executor, and no real time.
///
/// It is for setting up only. A check that something did *not* happen has to wait for a signal that can't come before the work has run (the
/// clock's sleepers, a count the work bumps, the end of a task): these turns say nothing of how far the work has got.
public func letTasksRun(turns: Int = 400) async {
    for _ in 0..<turns { await Task.yield() }
}
