import Foundation

/// How long quitting may take before the app answers the quit anyway.
///
/// macOS gives a quitting app little time, so the answer comes after `base` (one second): what must be done first (the settings
/// written, the socket stopped) takes milliseconds. Putting back what Mantel changed in the system can take longer, and must not
/// be cut short for no reason, so the wait is stretched to `extended` (three seconds in all), but only when that replay has to
/// run: `extend()` is called by the cleanup when the journal holds changes, before the hiding method is taken down (its undoing and the
/// replay after it share the three seconds), and counts only if the first second has not run out.
///
/// `wait()` is started as quitting begins, next to the cleanup; the app answers the quit when the cleanup returns or when `wait()`
/// does, whichever comes first.
public actor QuitTimer {
    /// The wait when nothing needs more.
    public static let base: Duration = .seconds(1)
    /// The wait once the journal is known to hold changes to put back (a replay is about to run, or is running).
    public static let extended: Duration = .seconds(3)

    private static let baseSeconds = Double(base.components.seconds)

    private let clock: any Clock
    private var startedAt: Date?
    private var isExtended = false

    public init(clock: any Clock = SystemClock()) {
        self.clock = clock
    }

    /// Asks for the longer wait. The cleanup asks when the journal holds changes: before the hiding method is taken down (its undoing
    /// and the replay after it share the three seconds), and again before the replay. It counts only in time: after `base` has passed
    /// since `wait()` began, the app has answered the quit already, and this changes nothing.
    public func extend() {
        if let startedAt, clock.now().timeIntervalSince(startedAt) >= Self.baseSeconds { return }
        isExtended = true
    }

    /// How much of the wait is left, as the wait is now: what the cleanup has to finish what it is doing in. All of it before `wait()`
    /// has begun, and never less than nothing.
    public func remaining() -> Duration {
        let total = isExtended ? Self.extended : Self.base
        guard let startedAt else { return total }
        // Whole milliseconds, so that a time that is meant to be round is.
        let spent = Duration.milliseconds(Int((clock.now().timeIntervalSince(startedAt) * 1000).rounded()))
        return max(.zero, total - spent)
    }

    /// Returns at `base`, or at `extended` when `extend()` came before `base` ran out.
    public func wait() async {
        startedAt = clock.now()
        try? await clock.sleep(for: Self.base)
        guard isExtended else { return }
        try? await clock.sleep(for: Self.extended - Self.base)
    }
}
