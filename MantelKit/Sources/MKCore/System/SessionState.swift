import Foundation

/// Whether anyone is looking at this Mac's menu bar: the displays are on, the screen isn't locked, and the session Mantel runs in is the
/// one that is on screen (with fast user switching, another person's session can be). While nobody is, what Mantel reads of the menu
/// bar says nothing about the bar the person will see, so it doesn't refresh the menu bar on the strength of it.
///
/// A plain value, so that what holds and what lets go is tested without a Mac to put to sleep. The three facts are told one at a time
/// (`applying(_:)`), by whatever watches the system (`SessionStateSource`).
public struct SessionState: Sendable, Equatable {
    /// The displays are off: the Mac is asleep, or only its displays are.
    public var displaysAsleep: Bool
    /// The screen is locked: the login window draws its own menu bar.
    public var screenLocked: Bool
    /// This user's session is the one on screen. False while another user's is (fast user switching).
    public var sessionActive: Bool

    public init(displaysAsleep: Bool = false, screenLocked: Bool = false, sessionActive: Bool = true) {
        self.displaysAsleep = displaysAsleep
        self.screenLocked = screenLocked
        self.sessionActive = sessionActive
    }

    /// The displays are on, the screen is unlocked and this session is the one on screen.
    public static let awake = SessionState(displaysAsleep: false, screenLocked: false, sessionActive: true)

    /// Whether the menu bar the person sees is the one Mantel reads: nothing here is holding it back.
    public var isAwake: Bool { !displaysAsleep && !screenLocked && sessionActive }

    /// Why it isn't, for the log: the first of the three that applies, in the order the displays, the lock, the session. Nil when it is.
    public var pauseReason: String? {
        if displaysAsleep { return "the displays are asleep" }
        if screenLocked { return "the screen is locked" }
        if !sessionActive { return "another user's session is on screen" }
        return nil
    }

    /// The state after this change. A wake of the system is an event, not a state: the state stays as it was (the displays' own
    /// notifications say whether they are on).
    public func applying(_ change: SessionChange) -> SessionState {
        var next = self
        switch change {
        case .displaysAsleep(let asleep): next.displaysAsleep = asleep
        case .screenLocked(let locked): next.screenLocked = locked
        case .sessionActive(let active): next.sessionActive = active
        case .systemWoke: break
        }
        return next
    }
}

/// One thing that happened to the session state.
public enum SessionChange: Sendable, Equatable {
    case displaysAsleep(Bool)
    case screenLocked(Bool)
    case sessionActive(Bool)
    /// The Mac woke from sleep. Told as an event on top of the others: it starts what depended on being asleep over, whether or not the
    /// displays' own notifications arrive before or after it.
    case systemWoke
}

/// Where the session state comes from: what it is now, and what happens to it after that.
public protocol SessionStateSource: Sendable {
    /// The state as it is now.
    func current() -> SessionState
    /// What happens to it from now on, as it happens. A caller that is to miss none asks for this first and reads `current()` after.
    func changes() -> AsyncStream<SessionChange>
}

/// A session that is always awake and never changes: what the session is given when nothing watches the system.
public struct SteadySessionState: SessionStateSource {
    public init() {}

    public func current() -> SessionState { .awake }

    public func changes() -> AsyncStream<SessionChange> {
        AsyncStream { $0.finish() }
    }
}
