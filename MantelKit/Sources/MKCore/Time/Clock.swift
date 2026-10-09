import Foundation

/// Where "now" and waiting come from, so what debounces or timestamps can be tested without waiting in real time.
/// Mantel's code takes a `Clock` (default: `SystemClock`); tests hand it the `FakeClock` from `MKTestSupport`.
public protocol Clock: Sendable {
    func now() -> Date
    /// Returns after `duration` has passed on this clock. Throws `CancellationError` when the task is cancelled first.
    func sleep(for duration: Duration) async throws
}

/// The real time.
public struct SystemClock: Clock {
    public init() {}

    public func now() -> Date { Date() }

    public func sleep(for duration: Duration) async throws {
        try await Task.sleep(for: duration)
    }
}
