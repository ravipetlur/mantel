import Foundation
import MKCommands
import MKCore
import Synchronization

/// Whether a reset of the menu bar is under way, readable from any thread: whoever resets sets it. One at a time: `begin()` says
/// whether it was this call that set it.
public final class ResetActivity: Sendable {
    private let flag = Mutex(false)

    public init() {}

    public var isUnderWay: Bool {
        flag.withLock { $0 }
    }

    /// Sets it. False, and nothing set, when it already was.
    public func begin() -> Bool {
        flag.withLock { flag in
            guard !flag else { return false }
            flag = true
            return true
        }
    }

    public func end() {
        flag.withLock { $0 = false }
    }
}

/// What the app does around `MenuBarSession.resetIfIdle`, as the one place that decides in what order:
/// 1. A second reset is refused at once (`.alreadyUnderWay`).
/// 2. The flag is set, so that the recovery of a stuck menu bar doesn't start from here on.
/// 3. The session resets.
///
/// The flag comes down when the reset is over, whatever came of it.
public struct MenuBarResetter: Sendable {
    private let session: MenuBarSession
    private let restarter: any MenuBarAgentRestarting
    private let replayJournal: @Sendable () async -> Void
    private let activity: ResetActivity

    /// - Parameters:
    ///   - replayJournal: puts back what the journal still holds.
    ///   - activity: the flag a reset sets.
    public init(session: MenuBarSession, restarter: any MenuBarAgentRestarting, replayJournal: @escaping @Sendable () async -> Void,
                activity: ResetActivity) {
        self.session = session
        self.restarter = restarter
        self.replayJournal = replayJournal
        self.activity = activity
    }

    public func reset() async -> ResetOutcome {
        guard activity.begin() else { return .alreadyUnderWay }
        defer { activity.end() }
        return await session.resetIfIdle(restarter: restarter, replayJournal: replayJournal)
    }
}
