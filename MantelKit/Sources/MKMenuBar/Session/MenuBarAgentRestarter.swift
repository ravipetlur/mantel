import AppKit
import Darwin
import Foundation
import MKCore

/// Something that makes macOS's menu bar start again.
public protocol MenuBarAgentRestarting: Sendable {
    /// Returns when the menu bar's process is running again.
    func restart() async throws(RestartError)
}

/// Why the menu bar couldn't be restarted. The text says what to do.
public enum RestartError: Error, Equatable, LocalizedError {
    /// MenuBarAgent isn't running, so there is nothing to stop and start.
    case notRunning
    /// It was told to stop and isn't running again, as another process, ten seconds on.
    case didNotComeBack

    public var errorDescription: String? {
        switch self {
        case .notRunning: "macOS's menu bar isn't running. Log out and back in to start it."
        case .didNotComeBack: "macOS's menu bar didn't restart. Log out and back in to restart it."
        }
    }
}

/// Restarts macOS's menu bar by asking its process, MenuBarAgent, to quit: launchd starts it again, as it does when it crashes.
///
/// - **It signals the agent and nothing else.** The process is found by its bundle ID, `com.apple.MenuBarAgent`, in the list of running
///   apps at the moment of sending (not a process ID kept from before), and the signal is `SIGTERM`: the polite one. Never `SIGKILL`.
/// - **Only a process ID that is a real, other process is ever signalled.** A list entry can carry -1 (`NSRunningApplication` says so for
///   a process it can't name), and `kill(-1, …)` reaches every process the person owns; 0 and below name a process group. So an entry
///   whose process ID isn't above 0 is not the agent (it doesn't count as the agent coming back either), Mantel's own process is never
///   signalled, and just before the signal the system is asked once more who has that process ID: if it isn't the agent, nothing is sent.
/// - **Then it looks every 100 ms, for up to 10 seconds, for the agent with another process ID.** An agent that is still the same process
///   hasn't been restarted; one that is gone is on its way back. A signal that the system refused is still followed by the wait: the
///   list is what says whether it came back.
/// - **Nothing is retried.** One signal is sent, and the answer is the list's.
///
/// The list of running apps and the signal are given, so that a test sends no signal to anything.
public struct MenuBarAgentRestarter: MenuBarAgentRestarting {
    /// How often the list is looked at while the agent comes back.
    static let pollInterval: Duration = .milliseconds(100)
    /// How long it is waited for.
    static let timeout: Duration = .seconds(10)

    private let runningApps: @Sendable () -> [RunningApp]
    private let clock: any Clock
    private let signal: @Sendable (pid_t) -> Int32
    private let isTheAgent: @Sendable (pid_t) -> Bool

    /// - Parameters:
    ///   - runningApps: every running app (`RunningAppsSource.all`), read afresh each time.
    ///   - signal: sends the stop to a process and answers 0 when the system took it, as `kill(2)` does.
    ///   - isTheAgent: whether the system says that process is MenuBarAgent right now. Asked once, just before the signal. The default
    ///     asks the system; a test gives its own, so that no test looks at a real process.
    public init(runningApps: @escaping @Sendable () -> [RunningApp], clock: any Clock = SystemClock(),
                signal: @escaping @Sendable (pid_t) -> Int32 = { kill($0, SIGTERM) },
                isTheAgent: @escaping @Sendable (pid_t) -> Bool = Self.systemSaysItIsTheAgent) {
        self.runningApps = runningApps
        self.clock = clock
        self.signal = signal
        self.isTheAgent = isTheAgent
    }

    /// Whether the system has MenuBarAgent under this process ID now.
    @Sendable
    public static func systemSaysItIsTheAgent(_ pid: pid_t) -> Bool {
        guard pid > 0 else { return false }
        return NSRunningApplication(processIdentifier: pid)?.bundleIdentifier == MenuBarReader.menuBarAgentBundleID
    }

    public func restart() async throws(RestartError) {
        guard let old = agentPID(), old > 0, old != getpid() else { throw .notRunning }
        // The list can be a moment behind: the process ID may belong to something else by now.
        guard isTheAgent(old) else {
            Log.warning("session", "the process that was MenuBarAgent isn't any more; nothing was signalled")
            throw .notRunning
        }
        Log.info("session", "restarting MenuBarAgent")
        if signal(old) != 0 {
            Log.warning("session", "MenuBarAgent wasn't told to quit: the system refused the signal")
        }

        var waited: Duration = .zero
        while waited < Self.timeout {
            do {
                try await clock.sleep(for: Self.pollInterval)
            } catch {
                // Whoever waits for this has gone: what is there now is what there is to say.
                break
            }
            waited += Self.pollInterval
            if let now = agentPID(), now != old {
                Log.info("session", "MenuBarAgent is running again")
                return
            }
        }
        Log.warning("session", "MenuBarAgent didn't come back within \(Self.timeout.components.seconds) seconds")
        throw .didNotComeBack
    }

    /// The agent's process ID, if the list has it as a real process (above 0).
    private func agentPID() -> pid_t? {
        runningApps().first { $0.bundleID == MenuBarReader.menuBarAgentBundleID && $0.pid > 0 }?.pid
    }
}
