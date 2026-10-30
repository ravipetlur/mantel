import Foundation

/// When the next background check is due.
public struct UpdateSchedule {
    /// How long after launch the first check waits.
    public static let firstCheckDelay: TimeInterval = 5 * 60
    /// How long after a check the next one waits.
    public static let interval: TimeInterval = 24 * 60 * 60

    /// The time of the next background check, or nil when automatic checks are off (a manual check always works).
    ///
    /// - With no last check, or one more than a day old: `firstCheckDelay` after `launch`.
    /// - Otherwise: `interval` after the last check.
    /// - A last check in the future (the clock moved back) counts as `now`.
    ///
    /// Apart from that last case the answer comes from `lastCheck` and `launch`, not from when it's asked, so asking
    /// again doesn't push the check out. A last check in the future does: it counts as `now`, so each later ask gives a
    /// later answer. The caller therefore overwrites the stored value with `correctedLastCheck(stored:now:)` before
    /// asking, which fixes the answer from then on. A date at or before `now` is a check that's due; it isn't moved
    /// forward. The caller records the time of every check it makes, a failed one included, or a stale last check keeps
    /// the answer in the past.
    public static func nextCheck(lastCheck: Date?, launch: Date, now: Date, automatic: Bool) -> Date? {
        guard automatic else { return nil }
        guard let lastCheck else { return launch.addingTimeInterval(firstCheckDelay) }
        let last = min(lastCheck, now)
        if now.timeIntervalSince(last) > interval { return launch.addingTimeInterval(firstCheckDelay) }
        return last.addingTimeInterval(interval)
    }

    /// The last check as it should be kept. One later than `now` (the clock moved back) is replaced by `now`, so the
    /// next check is a day from now and not a day from a time that hasn't come. No last check stays none, and any other
    /// is kept as it is. The caller stores the answer back when it differs from what was stored.
    public static func correctedLastCheck(stored: Date?, now: Date) -> Date? {
        guard let stored else { return nil }
        return min(stored, now)
    }

    /// Whether a background check may start from `state`. Not while a check, a download, a verification or an install
    /// runs, nor under a hand-off (the person is dragging the app across), and not while the offer window is open
    /// (`offerWindowOpen`): a check under an open window would change what the person is reading. A failed or cancelled
    /// update, an offer left waiting and a finished check don't stop one.
    public static func backgroundCheckMayStart(state: InstallFlow.State, offerWindowOpen: Bool) -> Bool {
        guard !offerWindowOpen else { return false }
        switch state {
        case .checking, .downloading, .verifying, .installing, .handedOff: return false
        case .idle, .available, .failed, .cancelled, .upToDate: return true
        }
    }
}
