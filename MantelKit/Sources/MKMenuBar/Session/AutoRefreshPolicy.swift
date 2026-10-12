import Foundation
import MKCore

/// When Mantel refreshes the menu bar without being asked, as a value that is tested on its own: once a read of the bar has finished, it is
/// told how that went, and says whether to refresh.
///
/// - **MenuBarAgent that doesn't answer.** `failuresBeforeRefresh` reads in a row in which it didn't (it isn't running, or has no
///   windows) make a refresh. A read it answered starts the count again.
/// - **A display change that left a bar empty.** On the first read after the displays changed, a display with no slots on it makes a
///   refresh. (Only the first: the read that the refresh itself makes is not asked about again.) A read the agent didn't answer says
///   nothing of the displays: it is counted as a failure of the agent, not as an empty bar.
/// - **At most one in `cooldown`.** A reason that comes inside it is passed over, and is not remembered: the next read that gives one
///   after the minute is up is the one that refreshes. (The count of failures is kept while the refresh is held back, and begins again
///   from nothing once one is made.)
///
/// What the caller does about a verdict is to log the reason and refresh. It doesn't ask during a reset: the bar is empty for a moment
/// then, and no read of it says anything about a bar that is stuck.
public struct AutoRefreshPolicy: Sendable, Equatable {
    /// How many reads in a row the agent doesn't answer before Mantel refreshes.
    public static let failuresBeforeRefresh = 3
    /// The shortest time between two refreshes of its own.
    public static let cooldown: Duration = .seconds(60)

    public enum Verdict: Sendable, Equatable {
        case none
        /// Refresh now; `reason` is a clause for the log.
        case refresh(reason: String)
    }

    static let agentReason = "MenuBarAgent didn't answer \(failuresBeforeRefresh) times in a row; refreshing once"
    static let emptyBarReason = "a display change left the menu bar empty; refreshing once"

    private var failures = 0
    private var lastRefreshAt: Date?

    public init() {}

    /// A read of the menu bar has finished.
    ///
    /// - Parameters:
    ///   - agentAnswered: MenuBarAgent was there to be asked (`Inventory.agentAnswered`).
    ///   - displaysWithSlots: the displays that have slots on their bar in the read (`Inventory.displaysWithSlots`).
    ///   - displays: the displays there are (their UUIDs).
    ///   - afterDisplayChange: this is the first read since the displays changed.
    ///   - now: when the read finished.
    public mutating func scanFinished(agentAnswered: Bool, displaysWithSlots: Set<String>, displays: Set<String>,
                                      afterDisplayChange: Bool, now: Date) -> Verdict {
        let reason: String?
        if agentAnswered {
            failures = 0
            let left = afterDisplayChange && !displays.isEmpty && !displays.isSubset(of: displaysWithSlots)
            reason = left ? Self.emptyBarReason : nil
        } else {
            failures += 1
            reason = failures >= Self.failuresBeforeRefresh ? Self.agentReason : nil
        }
        guard let reason else { return .none }

        if let lastRefreshAt, now.timeIntervalSince(lastRefreshAt) < Self.cooldownSeconds { return .none }
        lastRefreshAt = now
        failures = 0
        return .refresh(reason: reason)
    }

    private static let cooldownSeconds = Double(cooldown.components.seconds)
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
