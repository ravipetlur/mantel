import Foundation
import MKCore

/// When Mantel refreshes the menu bar without being asked, as a value that is tested on its own: once a read of the bar has finished, it is
/// told how that went, and says whether to refresh.
///
/// - **MenuBarAgent that doesn't answer.** `failuresBeforeRefresh` reads in a row in which it didn't (it isn't running, or has no
///   windows) make a refresh, the first of an outage. The outage ends, and the count starts again, once the agent has answered every read
///   for `answeringToEndAnOutage` (an idle poll's interval): the read a refresh makes is most likely answered by an agent that then goes
///   silent again, and so may the poll after it while Settings reads every two seconds, and an outage that such answers ended would refresh
///   once a minute for as long as the agent kept that up. A read it doesn't answer starts the span again.
/// - **An outage has at most `refreshesPerOutage` refreshes, each after a longer wait.** The first needs `cooldown` since the last
///   refresh of any kind; the 2nd, 3rd and 4th need at least `backOff[0]`, `backOff[1]` and `backOff[2]` since the one before. After the
///   4th, nothing refreshes until the agent has answered for `answeringToEndAnOutage`, or a wake (`woke()`), and then the first of the next outage still waits
///   for `cooldown`. A silent agent that a refresh can't bring back (the Mac has been asleep for an hour, say) is refreshed four times
///   and then left alone.
/// - **A display change that left a bar empty.** On the first read after the displays changed, a display with no slots on it makes a
///   refresh. (Only the first: the read that the refresh itself makes is not asked about again.) A read the agent didn't answer says
///   nothing of the displays: it is counted as a failure of the agent, not as an empty bar.
/// - **At most one in `cooldown`, of any kind.** A reason that comes inside it is passed over, and is not remembered: the next read that
///   gives one after the minute is up is the one that refreshes. (The count of failures is kept while the refresh is held back, and
///   begins again from nothing once one is made.) The waits of the back-off are on top of it, and none is shorter.
/// - **Nothing while nobody is looking.** While the caller says it may not refresh (`mayRefresh` false: the displays are asleep, the
///   screen is locked, another user's session is on screen) every verdict is `.none` and a failed read is not counted: what a bar reads
///   like then says nothing of the bar the person will see. A display change that is read then is remembered, and the first read that
///   may refresh is judged as if it had followed the change: the displays' notifications can arrive before the one that wakes them.
///
/// What the caller does about a verdict is to log the reason and refresh. It doesn't ask during a reset: the bar is empty for a moment
/// then, and no read of it says anything about a bar that is stuck. A refresh the person asks for is never a step of this, nor held
/// by it: the policy is not told of it, only of the read that it makes.
public struct AutoRefreshPolicy: Sendable, Equatable {
    /// How many reads in a row the agent doesn't answer before Mantel refreshes.
    public static let failuresBeforeRefresh = 3
    /// The shortest time between two refreshes of its own.
    public static let cooldown: Duration = .seconds(60)
    /// The least waits before the 2nd, 3rd and 4th refresh of one outage, each from the refresh before it.
    public static let backOff: [Duration] = [.seconds(60), .seconds(300), .seconds(900)]
    /// How many refreshes one outage has: the first, and one for each wait of the back-off.
    public static var refreshesPerOutage: Int { backOff.count + 1 }

    public enum Verdict: Sendable, Equatable {
        case none
        /// Refresh now; `reason` is a clause for the log.
        case refresh(reason: String)
    }

    /// How long the agent answers every read, after a refresh, before the outage is over: an idle poll's interval, so that a recovering agent
    /// ends it at the first poll after the refresh's own read.
    static let answeringToEndAnOutage: Duration = ScanScheduler.idleInterval

    /// What the log says for the agent's `number`th refresh of an outage (from 1): which of how many it is, and how long the next waits.
    static func agentReason(refreshNumber number: Int) -> String {
        let base = "MenuBarAgent didn't answer \(failuresBeforeRefresh) times in a row; refreshing (\(number) of \(refreshesPerOutage))"
        guard number < refreshesPerOutage else { return base + "; no more until it answers" }
        return base + "; if it still doesn't answer, the next is in at least \(wording(of: backOff[number - 1]))"
    }

    static let emptyBarReason = "a display change left the menu bar empty; refreshing once"

    private var failures = 0
    /// How many refreshes the agent's silence has had since it answered for `answeringToEndAnOutage`, or a wake.
    private var refreshesInOutage = 0
    /// Since when the agent has answered every read: from the first answer after a refresh or a read it didn't answer.
    private var answeringSince: Date?
    private var lastRefreshAt: Date?
    /// A display change was read while refreshing wasn't allowed, and no read has judged it since.
    private var pendingDisplayCheck = false

    public init() {}

    /// A read of the menu bar has finished.
    ///
    /// - Parameters:
    ///   - agentAnswered: MenuBarAgent was there to be asked (`Inventory.agentAnswered`).
    ///   - displaysWithSlots: the displays that have slots on their bar in the read (`Inventory.displaysWithSlots`).
    ///   - displays: the displays there are (their UUIDs).
    ///   - afterDisplayChange: this is the first read since the displays changed.
    ///   - mayRefresh: nothing holds refreshing back now (`SessionState.isAwake`).
    ///   - now: when the read finished.
    public mutating func scanFinished(agentAnswered: Bool, displaysWithSlots: Set<String>, displays: Set<String>,
                                      afterDisplayChange: Bool, mayRefresh: Bool, now: Date) -> Verdict {
        guard mayRefresh else {
            if afterDisplayChange { pendingDisplayCheck = true }
            return .none
        }
        let followsDisplayChange = afterDisplayChange || pendingDisplayCheck
        pendingDisplayCheck = false

        if agentAnswered {
            failures = 0
            let since = answeringSince ?? now
            answeringSince = since
            if hasPassed(Self.answeringToEndAnOutage, since: since, now: now) { refreshesInOutage = 0 }
            let left = followsDisplayChange && !displays.isEmpty && !displays.isSubset(of: displaysWithSlots)
            guard left, hasPassed(Self.cooldown, since: lastRefreshAt, now: now) else { return .none }
            lastRefreshAt = now
            return .refresh(reason: Self.emptyBarReason)
        }

        failures += 1
        answeringSince = nil
        guard failures >= Self.failuresBeforeRefresh, refreshesInOutage < Self.refreshesPerOutage else { return .none }
        let wait = refreshesInOutage == 0 ? Self.cooldown : Self.backOff[refreshesInOutage - 1]
        guard hasPassed(wait, since: lastRefreshAt, now: now) else { return .none }
        lastRefreshAt = now
        failures = 0
        answeringSince = nil
        refreshesInOutage += 1
        return .refresh(reason: Self.agentReason(refreshNumber: refreshesInOutage))
    }

    /// The Mac woke, the screen was unlocked, or this user's session is on screen again: the failures that were counted are of before, so
    /// the count begins again, and the next outage has its four refreshes. Two things stay. The time of the last refresh: `cooldown` is
    /// the floor between any two refreshes, a wake as well, so the first refresh after a wake waits out what is left of it. And a display
    /// change that is waiting to be judged: the displays' notification can come before the one that wakes them, and that is the one to
    /// judge it by.
    public mutating func woke() {
        failures = 0
        refreshesInOutage = 0
        answeringSince = nil
    }

    /// Whether `wait` has gone by since `last` (it has, when there was none).
    private func hasPassed(_ wait: Duration, since last: Date?, now: Date) -> Bool {
        guard let last else { return true }
        return now.timeIntervalSince(last) >= Self.seconds(of: wait)
    }

    private static func seconds(of duration: Duration) -> Double {
        Double(duration.components.seconds)
    }

    /// "1 minute", "5 minutes": a wait of whole minutes, as the log says it.
    private static func wording(of duration: Duration) -> String {
        let minutes = Int(seconds(of: duration)) / 60
        return minutes == 1 ? "1 minute" : "\(minutes) minutes"
    }
}

extension Inventory {
    /// The displays that have something on their bar in this read: an item with a frame there, an item piled at the « or behind the notch
    /// there, or a slot that no item claimed. A display that isn't in the set has an empty bar, or none that was read.
    public var displaysWithSlots: Set<String> {
        var displays: Set<String> = []
        for item in items {
            displays.formUnion(item.frames.keys)
            displays.formUnion(item.overflowedOn)
        }
        for (display, slots) in untiedSlots where !slots.isEmpty { displays.insert(display) }
        return displays
    }
}
