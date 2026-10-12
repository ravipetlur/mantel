/// What Mantel does when the system asks it to end with SIGTERM, which is what `killall`, `pkill` and the installing of a new build
/// send: it quits the way the Quit command does, so that what Mantel changed in the system is put back (the switches the switches engine
/// turned off, the journal) and the control socket is closed. A process that is simply ended does none of that, and the next launch has to
/// find it all and clean it up.
///
/// The app's delegate hands every SIGTERM that arrives (through a dispatch source: the default action of the signal is ignored) to
/// `received()`, and tells it when a quit that was asked for another way has begun (`quitBegan()`). The quit itself is bounded by
/// `QuitTimer`. SIGKILL can't be caught: the next launch's replay covers it.
public struct TerminationSignal: Sendable, Equatable {
    /// What the delegate does with a SIGTERM.
    public enum Reply: Sendable, Equatable {
        /// The first request to quit: begin quitting, and say in the log that a signal began it.
        case quit(logLine: String)
        /// A quit is under way already (it was asked for, or an earlier SIGTERM began it): nothing more is done, and nothing is logged.
        case alreadyQuitting
    }

    /// The line the log says when a SIGTERM starts a quit.
    public static let logLine = "received SIGTERM; quitting as the Quit command does"

    private var quitHasBegun = false

    public init() {}

    /// A SIGTERM has arrived.
    public mutating func received() -> Reply {
        guard !quitHasBegun else { return .alreadyQuitting }
        quitHasBegun = true
        return .quit(logLine: Self.logLine)
    }

    /// A quit has begun, however it was asked for: a SIGTERM that comes now has nothing to start.
    public mutating func quitBegan() {
        quitHasBegun = true
    }
}
