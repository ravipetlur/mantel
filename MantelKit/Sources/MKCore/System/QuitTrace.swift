import Foundation
import Synchronization

/// What the log says of a quit, so that one that overruns can be told from why: each step of the cleanup with the time it began and ended
/// (counted from the start of the quit), who answered the quit and when, and what was going on when the SIGTERM fallback ended Mantel
/// instead (the last step reached, what the readers were waiting for, and the answer of whatever was registered to say more).
///
/// One quit stuck for 8 seconds in the first sitting under load and the log said nothing between "received SIGTERM" and the fallback.
/// Every step is bounded, but a step that waits for the main thread, or for a thread of Swift's pool that a read is holding, is not
/// bounded by the timer that answers the quit, since the timer needs both too. With a line for each step, and the app's own heartbeats
/// (`QuitHeartbeat`), the next overrun says which it was: the last step reached, and whether the main thread and the pool were free.
public final class QuitTrace: Sendable {
    private struct State {
        var began: Date?
        var lastStep = "the quit hadn't begun"
        var answeredBy: String?
        var answeredAt: TimeInterval?
        var over = false
        var diagnostics: @Sendable () -> String = { "" }
    }

    private let clock: any Clock
    private let write: @Sendable (String) -> Void
    private let state = Mutex(State())

    /// - Parameter write: where a line goes (the log's `quit` category in the app).
    public init(clock: any Clock = SystemClock(), write: @escaping @Sendable (String) -> Void) {
        self.clock = clock
        self.write = write
    }

    /// The quit has begun: the times that follow are counted from now. Only the first call counts.
    public func begin(_ cause: String) {
        let first = state.withLock { state -> Bool in
            guard state.began == nil else { return false }
            state.began = clock.now()
            state.lastStep = "the quit began"
            return true
        }
        if first { write("quit trace: \(cause) (0 ms)") }
    }

    /// What a line of the fallback says besides the last step: what the readers were waiting for, and the like. Asked when the fallback ends
    /// Mantel, on its own thread: it must not wait for anything.
    public func setDiagnostics(_ diagnostics: @escaping @Sendable () -> String) {
        state.withLock { $0.diagnostics = diagnostics }
    }

    /// Whether the quit has been answered.
    public var isOver: Bool { state.withLock { $0.over } }

    /// Milliseconds since the quit began; 0 before it did.
    public var elapsedMilliseconds: Int {
        let (began, now) = (state.withLock { $0.began }, clock.now())
        return began.map { Int((now.timeIntervalSince($0) * 1000).rounded()) } ?? 0
    }

    /// Runs one step of the cleanup, saying when it began and when it ended, and how long it took.
    public func step<Result>(_ name: String, isolation: isolated (any Actor)? = #isolation, _ body: () async -> Result) async -> Result {
        let startedAt = elapsedMilliseconds
        state.withLock { $0.lastStep = "\(name) (begun)" }
        write("quit trace: \(name) begins (\(startedAt) ms)")
        let result = await body()
        let endedAt = elapsedMilliseconds
        state.withLock { $0.lastStep = "\(name) (ended)" }
        write("quit trace: \(name) ends (\(endedAt) ms, took \(endedAt - startedAt) ms)")
        return result
    }

    /// The same for a step that doesn't wait.
    public func quickStep<Result>(_ name: String, _ body: () -> Result) -> Result {
        let startedAt = elapsedMilliseconds
        state.withLock { $0.lastStep = "\(name) (begun)" }
        write("quit trace: \(name) begins (\(startedAt) ms)")
        let result = body()
        let endedAt = elapsedMilliseconds
        state.withLock { $0.lastStep = "\(name) (ended)" }
        write("quit trace: \(name) ends (\(endedAt) ms, took \(endedAt - startedAt) ms)")
        return result
    }

    /// The quit is being answered by `who` (the cleanup, or the timer). Only the first counts; false for any other.
    @discardableResult
    public func answered(by who: String) -> Bool {
        let at = elapsedMilliseconds
        let first = state.withLock { state -> Bool in
            guard state.answeredBy == nil else { return false }
            state.answeredBy = who
            state.answeredAt = TimeInterval(at)
            state.over = true
            state.lastStep = "the quit was answered"
            return true
        }
        if first { write("quit trace: the quit is answered by \(who) (\(at) ms)") }
        return first
    }

    /// A line of the heartbeat of a thread that is free: it ran when it was asked to, so it wasn't held.
    public func beat(_ what: String) {
        write("quit trace: \(what) is free (\(elapsedMilliseconds) ms)")
    }

    /// The line the SIGTERM fallback logs before it ends Mantel: the last step that was reached, who answered the quit if anyone did, and what
    /// the registered diagnostics say. It takes no lock for long and waits for nothing.
    public func fallbackLine() -> String {
        let (last, by, diagnostics) = state.withLock { ($0.lastStep, $0.answeredBy, $0.diagnostics) }
        let answered = by.map { "answered by \($0)" } ?? "not answered"
        let more = diagnostics()
        return "quit trace: ending now (\(elapsedMilliseconds) ms): the last step reached was \(last); the quit was \(answered)"
            + (more.isEmpty ? "" : "; \(more)")
    }
}
