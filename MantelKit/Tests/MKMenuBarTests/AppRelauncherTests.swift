import Foundation
import MKCore
import MKTestSupport
import Synchronization
import Testing

@testable import MKMenuBar

/// What a relaunch decides, with fakes in place of the system: no app is asked to quit, and nothing is opened. (`LiveAppRelauncher`, which
/// wires the real calls, is never made by a test.)
@Suite("App relauncher", .timeLimit(.minutes(1)))
struct AppRelauncherTests {
    private let candidate = RelaunchCandidate(id: "com.example.weather", name: "Weather", pid: 4242,
                                              bundleURL: URL(filePath: "/Applications/Weather.app"))

    /// What the fakes saw.
    private final class Calls: Sendable {
        private let state = Mutex<(terminated: [String], looks: Int, opened: [RelaunchOpening])>(([], 0, []))

        var terminated: [String] { state.withLock { $0.terminated } }
        var looks: Int { state.withLock { $0.looks } }
        var opened: [RelaunchOpening] { state.withLock { $0.opened } }

        func terminate(_ app: RelaunchCandidate) { state.withLock { $0.terminated.append(app.id) } }
        func noteOpened(_ opening: RelaunchOpening) { state.withLock { $0.opened.append(opening) } }

        /// Whether the app is still running: for the first `stays` looks, and gone after.
        func isRunning(stays: Int) -> Bool {
            state.withLock { state in
                state.looks += 1
                return state.looks <= stays
            }
        }
    }

    /// Whether something has happened.
    private final class Flag: Sendable {
        private let state = Mutex(false)

        var isSet: Bool { state.withLock { $0 } }
        func set() { state.withLock { $0 = true } }
    }

    private struct OpenFailure: Error, LocalizedError {
        var errorDescription: String? { "The app can't be opened." }
    }

    /// Starts a relaunch that waits on `clock` and returns the task, with a flag for whether it has finished.
    private func start(_ app: RelaunchCandidate, calls: Calls, clock: FakeClock, stays: Int,
                       open: @escaping @Sendable (RelaunchOpening) async throws -> Void = { _ in })
        -> (task: Task<RelaunchOutcome, Never>, finished: Flag) {
        let finished = Flag()
        let task = Task {
            let outcome = await AppRelauncher.relaunch(
                app, terminate: { calls.terminate($0) }, isRunning: { _ in calls.isRunning(stays: stays) },
                open: { opening in
                    calls.noteOpened(opening)
                    try await open(opening)
                },
                clock: clock)
            finished.set()
            return outcome
        }
        return (task, finished)
    }

    /// Lets 100 ms go by, `steps` times, each once the relauncher is waiting for it.
    private func tick(_ clock: FakeClock, steps: Int) async {
        for _ in 0..<steps {
            await clock.waitForSleepers(1)
            clock.advance(by: .milliseconds(100))
        }
    }

    @Test func didNotQuitAfterFiveSeconds() async {
        let calls = Calls()
        let clock = FakeClock()
        let run = start(candidate, calls: calls, clock: clock, stays: .max)

        // 4.9 seconds in, the app is still being waited for.
        await tick(clock, steps: 49)
        await clock.waitForSleepers(1)
        #expect(run.finished.isSet == false)
        #expect(calls.opened.isEmpty)

        await tick(clock, steps: 1)
        #expect(await run.task.value == .didNotQuit)
        #expect(calls.terminated == ["com.example.weather"], "asked once, politely")
        #expect(calls.opened.isEmpty, "and not opened again while it is still there")
    }

    @Test func anAppThatQuitsIsOpenedAgainAtOnce() async {
        let calls = Calls()
        let clock = FakeClock()
        // Gone at the third look: two waits of 100 ms.
        let run = start(candidate, calls: calls, clock: clock, stays: 2)

        await tick(clock, steps: 2)

        #expect(await run.task.value == .relaunched)
        #expect(calls.terminated == ["com.example.weather"])
        #expect(calls.opened.count == 1)
    }

    @Test func anAppAlreadyGoneIsOpenedWithoutWaiting() async {
        let calls = Calls()
        let clock = FakeClock()
        let run = start(candidate, calls: calls, clock: clock, stays: 0)

        #expect(await run.task.value == .relaunched)
        #expect(clock.sleeperCount == 0, "nothing was waited for")
    }

    @Test func opensWithoutActivating() async {
        let calls = Calls()
        let clock = FakeClock()
        let run = start(candidate, calls: calls, clock: clock, stays: 0)

        _ = await run.task.value

        #expect(calls.opened == [RelaunchOpening(url: URL(filePath: "/Applications/Weather.app"), arguments: [], activates: false)])
    }

    @Test func passesArguments() async {
        var app = candidate
        app.arguments = ["--extra", "6"]
        let calls = Calls()
        let clock = FakeClock()
        let run = start(app, calls: calls, clock: clock, stays: 0)

        _ = await run.task.value

        #expect(calls.opened.first?.arguments == ["--extra", "6"])
        #expect(calls.opened.first?.url == app.bundleURL)
    }

    @Test func aFailureToOpenCarriesItsText() async {
        let calls = Calls()
        let clock = FakeClock()
        let run = start(candidate, calls: calls, clock: clock, stays: 0, open: { _ in throw OpenFailure() })

        #expect(await run.task.value == .couldNotOpen("The app can't be opened."))
    }

    @Test func aCancelledWaitDoesNotOpenTheApp() async {
        let calls = Calls()
        let clock = FakeClock()
        let run = start(candidate, calls: calls, clock: clock, stays: .max)
        await clock.waitForSleepers(1)

        run.task.cancel()

        #expect(await run.task.value == .didNotQuit)
        #expect(calls.opened.isEmpty)
    }

    @Test func theWaitIsOnTheClockInStepsOf100Milliseconds() async {
        let calls = Calls()
        let clock = FakeClock()
        let run = start(candidate, calls: calls, clock: clock, stays: 1)
        await clock.waitForSleepers(1)

        // 99 ms isn't enough for the next look; the 100th is.
        clock.advance(by: .milliseconds(99))
        await Task.yield()
        #expect(calls.looks == 1)
        clock.advance(by: .milliseconds(1))

        #expect(await run.task.value == .relaunched)
        #expect(calls.looks == 2)
    }

    @Test func theRelaunchTimesAreTheOnesTheListPromises() {
        #expect(AppRelauncher.quitWait == .seconds(5))
        #expect(AppRelauncher.pollInterval == .milliseconds(100))
    }
}
