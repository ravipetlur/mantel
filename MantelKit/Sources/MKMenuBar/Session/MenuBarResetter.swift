import Foundation
import MKCommands
import MKCore
import Synchronization

/// Whether a reset of the menu bar is under way, readable from any thread: the probes that change the menu bar ask it (a reset restarts
/// what they measure), and whoever resets sets it. One at a time: `begin()` says whether it was this call that set it.
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
/// 1. A second reset is refused at once (`.alreadyUnderWay`), before it asks anything.
/// 2. The probes are told that one is under way, so that none that changes the menu bar starts from here on.
/// 3. `refusal` is asked, and its sentence (a platform test is changing the menu bar) makes the reset `.refused`, with nothing torn down,
///    replayed or signalled. Asked after step 2: a probe that began a moment earlier is found by it, and one that begins a moment later is
///    refused by the flag.
/// 4. The session resets.
///
/// The flag comes down when the reset is over, whatever came of it.
public struct MenuBarResetter: Sendable {
    private let session: MenuBarSession
    private let restarter: any MenuBarAgentRestarting
    private let replayJournal: @Sendable () async -> Void
    private let refusal: @Sendable () async -> String?
    private let activity: ResetActivity

    /// - Parameters:
    ///   - replayJournal: puts back what the journal still holds.
    ///   - refusal: why a reset can't be made now, if it can't (`ReplayNowPolicy.resetRefusal`).
    ///   - activity: what the probes read.
    public init(session: MenuBarSession, restarter: any MenuBarAgentRestarting, replayJournal: @escaping @Sendable () async -> Void,
                refusal: @escaping @Sendable () async -> String?, activity: ResetActivity) {
        self.session = session
        self.restarter = restarter
        self.replayJournal = replayJournal
        self.refusal = refusal
        self.activity = activity
    }

    public func reset() async -> ResetOutcome {
        guard activity.begin() else { return .alreadyUnderWay }
        defer { activity.end() }
        if let reason = await refusal() { return .refused(reason) }
        return await session.resetIfIdle(restarter: restarter, replayJournal: replayJournal)
    }
}
