import Foundation
import MKCore
import Synchronization

/// A clock that moves by itself: `sleep(for:)` returns at once, having added the duration to the time. Code that polls and
/// waits runs through minutes of its own time in no time at all, and what it measures between two readings is exactly the
/// sleeps in between. For tests that don't need to say when a sleeper wakes (`FakeClock` is for those that do).
public final class SteppingClock: Clock {
    private let start: Date
    private let elapsed = Mutex<Duration>(.zero)

    public init(now: Date = Date(timeIntervalSince1970: 1_700_000_000)) {
        start = now
    }

    public func now() -> Date {
        start.addingTimeInterval(Self.seconds(elapsed.withLock { $0 }))
    }

    /// Moves the clock on without anyone sleeping, for a test that wants time to pass between two steps.
    public func advance(by duration: Duration) {
        elapsed.withLock { $0 += duration }
    }

    public func sleep(for duration: Duration) async throws {
        try Task.checkCancellation()
        elapsed.withLock { $0 += max(duration, .zero) }
        // Lets other tasks run, as a real sleep would.
        await Task.yield()
    }

    private static func seconds(_ duration: Duration) -> TimeInterval {
        Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }
}
