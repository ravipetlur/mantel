import Foundation

/// What a copy that found another Mantel running did to hand off to it, and what it saw. These are facts the app observed;
/// `HandOff.decide` turns them into a decision.
public struct HandOffFacts: Sendable, Equatable {
    /// The running Mantel answered the request to open Settings over the control socket.
    public var socketAnswered: Bool
    /// The copy that was asked, as last seen: its process and whether it has exited. Nil when none was known (the
    /// socket's lock found it, and LaunchServices doesn't list it).
    public var target: RunningInstance?
    /// The process of the app LaunchServices returned when the target was opened again, which is how it is told to show
    /// Settings. Nil when that wasn't done or failed.
    public var reopenedPID: Int32?
    /// Whether another Mantel still holds the control socket's lock after the hand-off, when the lock is what found it;
    /// nil when it wasn't. `false` means this copy has the lock now.
    public var socketLockStillHeld: Bool?

    public init(socketAnswered: Bool, target: RunningInstance?, reopenedPID: Int32?, socketLockStillHeld: Bool?) {
        self.socketAnswered = socketAnswered
        self.target = target
        self.reopenedPID = reopenedPID
        self.socketLockStillHeld = socketLockStillHeld
    }
}

public enum HandOffDecision: Sendable, Equatable {
    /// Another Mantel was reached, or is alive: this copy quits.
    case quit
    /// Nobody was reached and nobody is known to be running: this copy stays and starts.
    case start
}

/// How the running Mantel answered the request to open Settings over the control socket.
public enum HandOffSocketReply: Sendable, Equatable {
    /// It did what was asked.
    case answered
    /// Nobody is listening at the socket: Mantel isn't running, or is still starting.
    case notRunning
    /// It answered, and refused (the socket only takes Mantel's own tools).
    case refused
    /// Anything else that went wrong.
    case failed
}

/// What a hand-off does and sees in the outside world, so that it can be run with a fake one. The app's own are the control
/// socket's client, `NSRunningApplication` and `NSWorkspace`.
public struct HandOffPorts: Sendable {
    /// Asks the running Mantel over the control socket to open Settings.
    public var sendOpenSettings: @Sendable () async -> HandOffSocketReply
    /// The copy being handed off to, as it is at this moment; nil when none is known.
    public var observeTarget: @Sendable () -> RunningInstance?
    /// Opens the target's app again through LaunchServices, which a running app takes as a reopen and answers by showing
    /// Settings. The process LaunchServices answered with, or nil if it couldn't be done.
    public var reopenTarget: @Sendable () async -> Int32?
    /// Waits.
    public var pause: @Sendable (Duration) async -> Void

    public init(sendOpenSettings: @escaping @Sendable () async -> HandOffSocketReply,
                observeTarget: @escaping @Sendable () -> RunningInstance?,
                reopenTarget: @escaping @Sendable () async -> Int32?,
                pause: @escaping @Sendable (Duration) async -> Void) {
        self.sendOpenSettings = sendOpenSettings
        self.observeTarget = observeTarget
        self.reopenTarget = reopenTarget
        self.pause = pause
    }
}

/// Whether a copy that handed off may quit. The rule is that the only copy running never quits: a copy quits only when it
/// knows that another Mantel is alive and has been told.
public enum HandOff {
    /// Asks the running Mantel to open Settings and gathers what that comes to; `decide` says what it means.
    ///
    /// First over the control socket. The other Mantel may still be starting and not listening yet, so "nobody is listening"
    /// is tried again after `pause`, up to `attempts` times in all. A refusal or a failure is not tried again. Then, if the
    /// target is known and hasn't exited, its app is opened again through LaunchServices. The target is looked at again
    /// last, so the facts say whether it was still there when everything was over.
    public static func attempt(_ ports: HandOffPorts, attempts: Int = 12,
                               pause: Duration = .milliseconds(250)) async -> HandOffFacts {
        var facts = HandOffFacts(socketAnswered: false, target: nil, reopenedPID: nil, socketLockStillHeld: nil)

        attempts: for attempt in 0..<attempts {
            switch await ports.sendOpenSettings() {
            case .answered:
                facts.socketAnswered = true
                facts.target = ports.observeTarget()
                return facts
            case .notRunning where attempt < attempts - 1:
                await ports.pause(pause)
            case .notRunning, .refused, .failed:
                break attempts
            }
        }

        // Not for a copy that has gone: opening its app again would reopen this copy (the same bundle) or start a new one.
        if let target = ports.observeTarget(), !target.isTerminated {
            facts.reopenedPID = await ports.reopenTarget()
        }
        facts.target = ports.observeTarget()
        return facts
    }

    public static func decide(_ facts: HandOffFacts) -> HandOffDecision {
        // The socket's lock is the best witness there is, because the system releases it the moment its holder ends, however
        // it ends. Held, a live Mantel is there; free, nobody is, whatever was answered a moment ago.
        if let held = facts.socketLockStillHeld {
            return held ? .quit : .start
        }
        if facts.socketAnswered { return .quit }
        // Opening the target's bundle again only counts if it is the very process that was meant: when the target has exited,
        // LaunchServices answers with this copy (the same bundle) or starts a fresh one, and neither takes over.
        if let target = facts.target, !target.isTerminated, facts.reopenedPID == target.pid {
            return .quit
        }
        return .start
    }
}
