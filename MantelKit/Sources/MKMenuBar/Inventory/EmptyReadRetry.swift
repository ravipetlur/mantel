import Foundation

/// What is done with a read of the menu bar that has no bar in it while MenuBarAgent runs.
///
/// MenuBarAgent is running and Accessibility is granted, so the bar is there; a read that finds no window of it is one whose queries
/// timed out (a busy Mac answers late), and says nothing of the bar. It isn't acted on: MenuBarAgent is asked again, after a short wait
/// that grows, a few times. Only if every one of them comes back empty is the read taken as it is, and what is said for it is that the bar
/// couldn't be read.
enum EmptyReadRetry {
    /// The waits before each new try: three tries in all, within 1.75 seconds.
    static let waits: [Duration] = [.milliseconds(250), .milliseconds(500), .seconds(1)]

    /// How long to wait before the try that follows `attempt` earlier ones (none before the first), or nil when the tries are used up.
    static func wait(afterAttempt attempt: Int) -> Duration? {
        attempt >= 0 && attempt < waits.count ? waits[attempt] : nil
    }
}
