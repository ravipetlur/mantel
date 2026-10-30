import Foundation
import MKCommands
import MKCore
import MKTestSupport
import Synchronization
import Testing

@testable import MKMenuBar

/// The list of running apps a test changes, and the signals it was asked to send. Nothing here signals a real process: the restarter is
/// given this list and this signal.
private final class FakeProcesses: Sendable {
    private let state = Mutex<[RunningApp]>([])
    private let sent = Mutex<[pid_t]>([])

    init(_ apps: [RunningApp]) {
        state.withLock { $0 = apps }
    }

    var apps: [RunningApp] { state.withLock { $0 } }
    var signalled: [pid_t] { sent.withLock { $0 } }

    func set(_ apps: [RunningApp]) { state.withLock { $0 = apps } }
    func noteSignal(_ pid: pid_t) { sent.withLock { $0.append(pid) } }

    static let agentBundleID = "com.apple.MenuBarAgent"
    static func agent(_ pid: pid_t) -> RunningApp { .fake(pid, agentBundleID, "MenuBarAgent") }
    static let others: [RunningApp] = [.fake(10, "com.example.weather"), .fake(11, "com.apple.MenuBarAgentHelper"), .fake(12, "com.apple.dock")]
}

/// A clock that moves by itself, notes each sleep, and runs something at each one (so that the list of processes can change while the
/// restarter waits).
private final class PollingClock: Clock {
    private let base = SteppingClock()
    private let slept = Mutex<[Duration]>([])
    private let hook = Mutex<(@Sendable (Int) -> Void)?>(nil)

    var durations: [Duration] { slept.withLock { $0 } }
    var total: Duration { durations.reduce(.zero, +) }
    /// Runs at the start of each sleep, with how many there have been (this one included).
    func onSleep(_ body: (@Sendable (Int) -> Void)?) { hook.withLock { $0 = body } }
    func now() -> Date { base.now() }

    func sleep(for duration: Duration) async throws {
        let count = slept.withLock { state -> Int in
            state.append(duration)
            return state.count
        }
        hook.withLock { $0 }?(count)
        try await base.sleep(for: duration)
    }
}

@Suite("MenuBarAgent restarter", .timeLimit(.minutes(1)))
struct MenuBarAgentRestarterTests {
    /// A restarter over the fake list and the fake signal. `isTheAgent` answers the check that is made just before the signal (the real
    /// one asks the system who has that process ID, which a test never does).
    private func restarter(_ processes: FakeProcesses, clock: PollingClock = PollingClock(), signalResult: Int32 = 0,
                           isTheAgent: @escaping @Sendable (pid_t) -> Bool = { _ in true }) -> MenuBarAgentRestarter {
        MenuBarAgentRestarter(runningApps: { processes.apps }, clock: clock, signal: { pid in
            processes.noteSignal(pid)
            return signalResult
        }, isTheAgent: isTheAgent)
    }

    @Test func sendsTermToAgentPid() async throws {
        let processes = FakeProcesses(FakeProcesses.others + [FakeProcesses.agent(50)])
        let clock = PollingClock()
        // launchd starts it again as soon as it is told to stop.
        clock.onSleep { _ in processes.set(FakeProcesses.others + [FakeProcesses.agent(51)]) }

        try await restarter(processes, clock: clock).restart()

        #expect(processes.signalled == [50], "the agent's, and nobody else's, once")
    }

    @Test func findsThePidAtTheMomentOfSending() async throws {
        // The agent was started again since the restarter was made, and has another process ID: the list is read when it is asked to
        // restart, not before.
        let processes = FakeProcesses(FakeProcesses.others + [FakeProcesses.agent(50)])
        let clock = PollingClock()
        clock.onSleep { _ in processes.set(FakeProcesses.others + [FakeProcesses.agent(61)]) }
        let restarter = restarter(processes, clock: clock)
        processes.set(FakeProcesses.others + [FakeProcesses.agent(60)])

        try await restarter.restart()

        #expect(processes.signalled == [60])
    }

    @Test func waitsForNewPid() async throws {
        let processes = FakeProcesses(FakeProcesses.others + [FakeProcesses.agent(50)])
        let clock = PollingClock()
        // It goes for three looks, and then is back with another process ID.
        clock.onSleep { count in
            switch count {
            case 1: processes.set(FakeProcesses.others)
            case 4: processes.set(FakeProcesses.others + [FakeProcesses.agent(77)])
            default: break
            }
        }

        try await restarter(processes, clock: clock).restart()

        #expect(clock.durations == Array(repeating: .milliseconds(100), count: 4), "every 100 ms, and until the new one is there")
    }

    @Test func theOldProcessStillThereIsNotARestart() async throws {
        // The first looks find the agent as it was (it hasn't stopped yet); the process that is there later is the new one.
        let processes = FakeProcesses(FakeProcesses.others + [FakeProcesses.agent(50)])
        let clock = PollingClock()
        clock.onSleep { count in
            if count == 5 { processes.set(FakeProcesses.others + [FakeProcesses.agent(51)]) }
        }

        try await restarter(processes, clock: clock).restart()

        #expect(clock.durations.count == 5)
    }

    @Test func timesOutWithMessage() async throws {
        // It never goes, or never comes back: ten seconds, and then the words.
        let processes = FakeProcesses(FakeProcesses.others + [FakeProcesses.agent(50)])
        let clock = PollingClock()

        let error = await #expect(throws: RestartError.self) { try await restarter(processes, clock: clock).restart() }

        #expect(error == .didNotComeBack)
        #expect(error?.errorDescription == "macOS's menu bar didn't restart. Log out and back in to restart it.")
        #expect(clock.total == .seconds(10))
        #expect(clock.durations.allSatisfy { $0 == .milliseconds(100) })
        #expect(processes.signalled == [50], "it asked once and didn't ask again")
    }

    @Test func anAgentThatWentAndNeverCameBackIsTheSameTimeout() async throws {
        let processes = FakeProcesses(FakeProcesses.others + [FakeProcesses.agent(50)])
        let clock = PollingClock()
        clock.onSleep { _ in processes.set(FakeProcesses.others) }

        let error = await #expect(throws: RestartError.self) { try await restarter(processes, clock: clock).restart() }

        #expect(error == .didNotComeBack)
        #expect(clock.total == .seconds(10))
    }

    @Test func aSignalThatFailedIsStillWaitedOutAndNeverRetried() async throws {
        // The system said no (the process was already gone, or isn't Mantel's to signal): the list is what says whether it came back.
        let processes = FakeProcesses(FakeProcesses.others + [FakeProcesses.agent(50)])
        let clock = PollingClock()
        clock.onSleep { count in
            if count == 2 { processes.set(FakeProcesses.others + [FakeProcesses.agent(52)]) }
        }

        try await restarter(processes, clock: clock, signalResult: -1).restart()
        #expect(processes.signalled == [50])

        let stuck = FakeProcesses(FakeProcesses.others + [FakeProcesses.agent(50)])
        let error = await #expect(throws: RestartError.self) { try await restarter(stuck, signalResult: -1).restart() }
        #expect(error == .didNotComeBack)
        #expect(stuck.signalled == [50])
    }

    @Test func notRunningMessage() async throws {
        // A helper with a name that starts the same is not the agent.
        let processes = FakeProcesses(FakeProcesses.others)
        let clock = PollingClock()

        let error = await #expect(throws: RestartError.self) { try await restarter(processes, clock: clock).restart() }

        #expect(error == .notRunning)
        #expect(error?.errorDescription == "macOS's menu bar isn't running. Log out and back in to start it.")
        #expect(processes.signalled.isEmpty, "nothing was signalled")
        #expect(clock.durations.isEmpty, "and nothing was waited for")
    }

    @Test func aPidThatIsNotAProcessIsNeverSignalled() async throws {
        // `NSRunningApplication.processIdentifier` can be -1, and `kill(-1, ...)` signals every process the person owns; 0 and below name a
        // process group. None of them is a process to stop.
        for pid in [pid_t(-1), 0, -50] {
            let processes = FakeProcesses(FakeProcesses.others + [FakeProcesses.agent(pid)])
            let clock = PollingClock()

            let error = await #expect(throws: RestartError.self) { try await restarter(processes, clock: clock).restart() }

            #expect(error == .notRunning, "pid \(pid)")
            #expect(processes.signalled.isEmpty, "nothing was signalled for pid \(pid)")
            #expect(clock.durations.isEmpty)
        }
    }

    @Test func mantelItselfIsNeverSignalled() async throws {
        let processes = FakeProcesses(FakeProcesses.others + [FakeProcesses.agent(getpid())])

        let error = await #expect(throws: RestartError.self) { try await restarter(processes).restart() }

        #expect(error == .notRunning)
        #expect(processes.signalled.isEmpty)
    }

    @Test func aPidThatIsNoLongerTheAgentIsNeverSignalled() async throws {
        // The list says the agent has that process ID, and the system, asked just before the signal, says another program has it now (the
        // agent went, and the number was given to something else).
        let processes = FakeProcesses(FakeProcesses.others + [FakeProcesses.agent(50)])
        let asked = Mutex<[pid_t]>([])
        let clock = PollingClock()

        let error = await #expect(throws: RestartError.self) {
            try await restarter(processes, clock: clock, isTheAgent: { pid in
                asked.withLock { $0.append(pid) }
                return false
            }).restart()
        }

        #expect(error == .notRunning)
        #expect(asked.withLock { $0 } == [50], "it asked about the one it was going to signal")
        #expect(processes.signalled.isEmpty, "and sent nothing")
        #expect(clock.durations.isEmpty)
    }

    @Test func aPidThatIsNotAProcessNeverCountsAsComingBack() async throws {
        // The agent is gone, and what the list shows later is an entry with the process ID -1: that isn't the agent running again.
        let processes = FakeProcesses(FakeProcesses.others + [FakeProcesses.agent(50)])
        let clock = PollingClock()
        clock.onSleep { _ in processes.set(FakeProcesses.others + [FakeProcesses.agent(-1)]) }

        let error = await #expect(throws: RestartError.self) { try await restarter(processes, clock: clock).restart() }

        #expect(error == .didNotComeBack)
        #expect(processes.signalled == [50])
    }

    @Test func theSystemCheckSaysNoToAnythingThatIsNotAProcessWithoutAskingTheSystem() {
        #expect(!MenuBarAgentRestarter.systemSaysItIsTheAgent(-1))
        #expect(!MenuBarAgentRestarter.systemSaysItIsTheAgent(0))
    }

    @Test func theTimesAreTenSecondsAndAHundredMilliseconds() {
        #expect(MenuBarAgentRestarter.timeout == .seconds(10))
        #expect(MenuBarAgentRestarter.pollInterval == .milliseconds(100))
    }
}

@Suite("Reset copy", .timeLimit(.minutes(1)))
struct ResetCopyTests {
    @Test func theQuestionIsAskedInTheWordsTheOwnerChose() {
        #expect(ResetCopy.alertTitle == "Reset the menu bar?")
        #expect(ResetCopy.alertText == "Mantel shows every icon, puts back its temporary changes, and restarts macOS's menu bar. Your sections and the order of your icons stay as they are.")
        #expect(ResetCopy.confirmButton == "Reset")
        #expect(ResetCopy.cancelButton == "Cancel")
    }

    @Test func theCommandLineAsksTheSameThing() {
        // The tool's question is the alert's title and the first sentence of its text, then that the order stays, and a prompt.
        let firstSentence = "Mantel shows every icon, puts back its temporary changes, and restarts macOS's menu bar."
        #expect(ResetCopy.alertText.hasPrefix(firstSentence))
        #expect(CLIConfirmation.resetQuestion == "\(ResetCopy.alertTitle) \(firstSentence) The order of your icons stays. [y/N] ")
    }

    @Test func bothTextsSayTheOrderStays() {
        #expect(ResetCopy.alertText.contains("the order of your icons stay as they are"))
        #expect(CLIConfirmation.resetQuestion.contains("The order of your icons stays."))
        // What a reset puts back is the temporary changes only; the arrangement is kept (the person's, until Restore original layout).
        #expect(ResetCopy.alertText.contains("its temporary changes"))
        #expect(CLIConfirmation.resetQuestion.contains("its temporary changes"))
        #expect(!ResetCopy.alertText.contains("what it changed"))
        #expect(!CLIConfirmation.resetQuestion.contains("what it changed"))
    }
}
