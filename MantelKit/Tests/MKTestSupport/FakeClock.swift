import Foundation
import MKCore
import Synchronization

/// A clock that only moves when a test says so, so nothing waits in real time.
///
/// - `sleep(for:)` suspends until `advance(by:)` has moved the clock to the sleeper's deadline.
/// - Time is counted in `Duration`s, which add up exactly: sleeping 500 ms and then advancing 300 ms and 200 ms wakes
///   the sleeper, which `Date` arithmetic doesn't promise.
/// - A sleeper registers when its task gets to run, not when the task is created, so a test that has just started
///   something that sleeps calls `waitForSleepers(_:)` before it advances; advancing first would move the clock past a
///   sleeper that then never wakes.
public final class FakeClock: Clock {
    private struct Sleeper {
        let id: UInt64
        let deadline: Duration
        let continuation: CheckedContinuation<Void, any Error>
    }

    private struct Waiter {
        let id: UInt64
        let count: Int
        let continuation: CheckedContinuation<Void, Never>
    }

    private struct State {
        var elapsed: Duration = .zero
        var nextID: UInt64 = 0
        var sleepers: [Sleeper] = []
        var waiters: [Waiter] = []
    }

    private let start: Date
    private let state = Mutex(State())

    public init(now: Date = Date(timeIntervalSince1970: 1_700_000_000)) {
        start = now
    }

    public func now() -> Date {
        start.addingTimeInterval(state.withLock { Self.seconds($0.elapsed) })
    }

    /// How many tasks are sleeping on this clock now.
    public var sleeperCount: Int {
        state.withLock { $0.sleepers.count }
    }

    /// Moves the clock forward and wakes every sleeper whose deadline has come, earliest deadline first (sleepers with
    /// the same deadline in the order they went to sleep). The woken tasks run afterwards, not inside this call.
    public func advance(by duration: Duration) {
        let due = state.withLock { state -> [Sleeper] in
            state.elapsed += duration
            let due = state.sleepers
                .filter { $0.deadline <= state.elapsed }
                .sorted { ($0.deadline, $0.id) < ($1.deadline, $1.id) }
            state.sleepers.removeAll { $0.deadline <= state.elapsed }
            return due
        }
        for sleeper in due {
            sleeper.continuation.resume()
        }
    }

    /// Returns once at least `count` tasks are sleeping on this clock. Use it before `advance(by:)` to know that what a
    /// test started has reached its sleep. If the waiting task is cancelled (a test over its time limit), it returns at
    /// once, so a test that waits for a sleeper that never comes fails instead of hanging.
    public func waitForSleepers(_ count: Int = 1) async {
        let id = nextID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let enough = state.withLock { state -> Bool in
                    if state.sleepers.count >= count || Task.isCancelled { return true }
                    state.waiters.append(Waiter(id: id, count: count, continuation: continuation))
                    return false
                }
                if enough { continuation.resume() }
            }
        } onCancel: {
            let waiter = state.withLock { state -> Waiter? in
                guard let index = state.waiters.firstIndex(where: { $0.id == id }) else { return nil }
                return state.waiters.remove(at: index)
            }
            waiter?.continuation.resume()
        }
    }

    public func sleep(for duration: Duration) async throws {
        guard duration > .zero else { return }
        let id = nextID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                // Looking at the cancellation inside the lock closes the gap in which a cancel could arrive before the
                // sleeper is registered and then find nothing to cancel.
                let outcome = state.withLock { state -> (cancelled: Bool, ready: [Waiter]) in
                    if Task.isCancelled { return (true, []) }
                    state.sleepers.append(Sleeper(id: id, deadline: state.elapsed + duration, continuation: continuation))
                    let ready = state.waiters.filter { $0.count <= state.sleepers.count }
                    state.waiters.removeAll { $0.count <= state.sleepers.count }
                    return (false, ready)
                }
                if outcome.cancelled { continuation.resume(throwing: CancellationError()) }
                for waiter in outcome.ready { waiter.continuation.resume() }
            }
        } onCancel: {
            let sleeper = state.withLock { state -> Sleeper? in
                guard let index = state.sleepers.firstIndex(where: { $0.id == id }) else { return nil }
                return state.sleepers.remove(at: index)
            }
            sleeper?.continuation.resume(throwing: CancellationError())
        }
    }

    private func nextID() -> UInt64 {
        state.withLock { state in
            state.nextID += 1
            return state.nextID
        }
    }

    private static func seconds(_ duration: Duration) -> TimeInterval {
        Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }
}
