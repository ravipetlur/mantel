import Foundation

/// How long a Recapture waits before it reveals anything: a bar that was captured a moment ago isn't captured again (the collector's
/// throttle, `CaptureRules.perBarInterval`), so a Recapture that revealed everything right away would show every icon for nothing and
/// answer that the bar was captured a moment ago. It waits out what is left of the interval instead, so the command does what it was asked.
public enum RecaptureWait {
    /// What is left of `interval` since the last strip of the bar was taken, or nil when nothing is (or none was taken).
    public static func remaining(lastStrip: Date?, now: Date, interval: Duration) -> Duration? {
        guard let lastStrip else { return nil }
        let elapsed = max(now.timeIntervalSince(lastStrip), 0)
        let seconds = Double(interval.components.seconds) + Double(interval.components.attoseconds) / 1e18
        guard elapsed < seconds else { return nil }
        return .milliseconds(max(Int(((seconds - elapsed) * 1000).rounded()), 1))
    }
}
