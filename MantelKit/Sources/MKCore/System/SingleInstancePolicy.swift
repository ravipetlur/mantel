/// A running copy of Mantel, as reported by `NSRunningApplication`.
public struct RunningInstance: Sendable, Equatable {
    public let pid: Int32
    public let isTerminated: Bool

    public init(pid: Int32, isTerminated: Bool) {
        self.pid = pid
        self.isTerminated = isTerminated
    }
}

/// Decides whether a newly launched copy should hand off to an existing one and quit.
public enum SingleInstancePolicy {
    /// The environment variable the copy that moves itself into Applications sets on the one it starts there.
    public static let relaunchedFromMoveKey = "MANTEL_RELAUNCHED_FROM_MOVE"

    public static func instanceToHandOffTo(running: [RunningInstance], currentPID: Int32) -> RunningInstance? {
        running.first { $0.pid != currentPID && !$0.isTerminated }
    }

    /// Whether this copy was started by the move to Applications, and so must not hand off. The copy that started it is
    /// still running (it quits right after), so handing off to it would quit this one and leave nothing running once that
    /// one is gone.
    public static func suppressesHandOff(environment: [String: String]) -> Bool {
        environment[relaunchedFromMoveKey] == "1"
    }
}
