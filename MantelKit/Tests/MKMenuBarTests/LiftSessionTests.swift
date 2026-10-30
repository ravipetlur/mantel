import Foundation
import MKCore
import MKLayout
import MKTestSupport
import Synchronization
import Testing

@testable import MKMenuBar

/// When the lifted allowlist is put back, as plain values: the time is a date each event brings, and nothing sleeps.
@Suite("Lift session", .timeLimit(.minutes(1)))
struct LiftSessionTests {
    private let start = Date(timeIntervalSince1970: 1_700_000_000)

    private func at(_ milliseconds: Int) -> Date { start.addingTimeInterval(Double(milliseconds) / 1000) }

    /// A lift that began at `start`, the replay having been posted then.
    private func begun() -> LiftSession {
        var session = LiftSession(startedAt: start)
        #expect(session.handle(.replayed, now: start) == .keepPolling)
        return session
    }

    // MARK: Review focus: the lift ends when the panel closes

    @Test func restoresAfterOneSecondIfNeverOpened() {
        var session = begun()
        for milliseconds in [200, 400, 600, 800] {
            #expect(session.handle(.poll(open: false), now: at(milliseconds)) == .keepPolling)
        }
        #expect(session.handle(.poll(open: false), now: at(999)) == .keepPolling, "a second is a second")
        #expect(session.handle(.poll(open: false), now: at(1000)) == .restore)
    }

    @Test func restoresAtEightSeconds() {
        var session = begun()
        for milliseconds in stride(from: 200, through: 7800, by: 200) {
            #expect(session.handle(.poll(open: true), now: at(milliseconds)) == .keepPolling)
        }
        #expect(session.handle(.poll(open: true), now: at(7999)) == .keepPolling)
        #expect(session.handle(.poll(open: true), now: at(8000)) == .restore, "open still, and the cap is the end")
    }

    @Test func clickOutsideBeforeTheOpenStillRestores() {
        var session = begun()
        // The panel hasn't been seen open: a click anywhere else restores 300 ms later, without waiting out the second.
        #expect(session.handle(.poll(open: false), now: at(200)) == .keepPolling)
        #expect(session.handle(.clickOutside, now: at(300)) == .keepPolling, "the click goes through first")
        #expect(session.handle(.timerFired, now: at(599)) == .keepPolling)
        #expect(session.handle(.timerFired, now: at(600)) == .restore)
    }

    // MARK: A click on the open panel

    @Test func clickInsideOpenNotificationCenterDoesNotRestore() {
        // A click on a notification or a widget is a click away from the clock, and is on the open panel: the icons behind it stay shown.
        var session = begun()
        #expect(session.handle(.poll(open: true), now: at(200)) == .keepPolling)
        #expect(session.handle(.clickOutside, now: at(2000)) == .keepPolling)
        #expect(session.handle(.timerFired, now: at(2300)) == .keepPolling, "300 ms on: nothing")
        #expect(session.handle(.poll(open: true), now: at(2400)) == .keepPolling)
        for milliseconds in stride(from: 2600, through: 6000, by: 200) {
            #expect(session.handle(.poll(open: true), now: at(milliseconds)) == .keepPolling)
        }
        // Only its close restores, found by the next look.
        #expect(session.handle(.poll(open: false), now: at(6200)) == .restore)
    }
}

/// The runner that polls and restores, on a clock a test moves.
@Suite("Lift runner", .serialized, .timeLimit(.minutes(1)))
struct LiftRunnerTests {
    /// What the panel is doing and how often it was looked at, and what was restored.
    private final class Stage: Sendable {
        private struct State {
            var open = false
            var looks = 0
            var restores = 0
        }

        private let state = Mutex(State())
        var looks: Int { state.withLock { $0.looks } }
        var restores: Int { state.withLock { $0.restores } }

        func setOpen(_ open: Bool) { state.withLock { $0.open = open } }

        func look() -> Bool {
            state.withLock { state in
                state.looks += 1
                return state.open
            }
        }

        func restored() { state.withLock { $0.restores += 1 } }
    }

    private func make(_ stage: Stage, clock: FakeClock) -> LiftRunner {
        LiftRunner(clock: clock, isOpen: { stage.look() }, restore: { stage.restored() })
    }

    /// Waits until this many tasks sleep on the clock and this many restores have been made.
    private func settle(_ clock: FakeClock, _ stage: Stage, sleepers: Int, restores: Int) async -> Bool {
        await waitUntil { clock.sleeperCount == sleepers && stage.restores == restores }
    }

    /// Lets 200 ms pass and waits for what the poll that wakes does.
    private func tick(_ clock: FakeClock, _ stage: Stage, sleepers: Int = 1, restores: Int = 0) async -> Bool {
        clock.advance(by: LiftSession.pollInterval)
        return await settle(clock, stage, sleepers: sleepers, restores: restores)
    }

    @Test func restoresWhenNotificationCenterCloses() async {
        let clock = FakeClock()
        let stage = Stage()
        let runner = make(stage, clock: clock)
        runner.replayed()
        #expect(runner.isRunning)
        #expect(await clock.waitForSleepers(1, within: .seconds(5)))

        #expect(await tick(clock, stage), "the panel isn't open yet, and the first second is waited out")
        stage.setOpen(true)
        #expect(await tick(clock, stage))
        #expect(await tick(clock, stage))
        #expect(await tick(clock, stage), "open: the lift goes on")
        #expect(stage.restores == 0)
        #expect(runner.isRunning)

        stage.setOpen(false)
        #expect(await tick(clock, stage, sleepers: 0, restores: 1), "the first look that finds it closed restores, and the polling ends")
        #expect(!runner.isRunning)

        // Nothing goes on after that.
        clock.advance(by: .seconds(30))
        #expect(await settle(clock, stage, sleepers: 0, restores: 1))
        #expect(stage.restores == 1)
    }

    @Test func aReplayThatComesDuringALiftTakesItsPlace() async {
        let clock = FakeClock()
        let stage = Stage()
        let runner = make(stage, clock: clock)
        runner.replayed()
        #expect(await clock.waitForSleepers(1, within: .seconds(5)))
        #expect(await tick(clock, stage))
        #expect(await tick(clock, stage))

        // The clock was clicked again and replayed: a new lift, counted from now. The old one doesn't restore.
        runner.replayed()
        #expect(await settle(clock, stage, sleepers: 1, restores: 0))
        for _ in 0..<4 { #expect(await tick(clock, stage)) }
        #expect(stage.restores == 0, "a second from the new replay isn't up yet; the old lift's would have been")
        #expect(await tick(clock, stage, sleepers: 0, restores: 1))
        clock.advance(by: .seconds(30))
        #expect(await settle(clock, stage, sleepers: 0, restores: 1), "restored once, for the two lifts")
    }

    @Test func stopEndsTheLiftAndDoesNotRestore() async {
        let clock = FakeClock()
        let stage = Stage()
        stage.setOpen(true)
        let runner = make(stage, clock: clock)
        runner.replayed()
        #expect(await clock.waitForSleepers(1, within: .seconds(5)))
        #expect(await tick(clock, stage))

        // The allowlist is no longer wanted (another engine took over, or the app is quitting): putting it back is not the lift's to do.
        runner.stop()
        #expect(!runner.isRunning)
        #expect(await settle(clock, stage, sleepers: 0, restores: 0), "the polling ended")
        runner.stop()
        clock.advance(by: .seconds(30))
        #expect(await settle(clock, stage, sleepers: 0, restores: 0))
        try? await Task.sleep(for: .milliseconds(20))
        #expect(stage.restores == 0)
    }

    @Test func aSlowRestoreDoesNotHoldTheNextLift() async {
        let clock = FakeClock()
        let stage = Stage()
        let gate = Gate()
        let restores = Mutex(0)
        let runner = LiftRunner(clock: clock, isOpen: { stage.look() }, restore: {
            restores.withLock { $0 += 1 }
            await gate.wait()
        })
        runner.replayed()
        #expect(await clock.waitForSleepers(1, within: .seconds(5)))
        for index in 0..<5 {
            clock.advance(by: LiftSession.pollInterval)
            if index < 4 { #expect(await clock.waitForSleepers(1, within: .seconds(5))) }
        }
        #expect(await waitUntil { restores.withLock { $0 } == 1 })
        #expect(!runner.isRunning, "the lift is over while its restore is still being made")

        runner.replayed()
        #expect(runner.isRunning)
        #expect(await clock.waitForSleepers(1, within: .seconds(5)))
        gate.open()
        for index in 0..<5 {
            clock.advance(by: LiftSession.pollInterval)
            if index < 4 { #expect(await clock.waitForSleepers(1, within: .seconds(5))) }
        }
        #expect(await waitUntil { restores.withLock { $0 } == 2 })
    }
}

/// The lift against an engine whose activation fails, and the one that goes on holding: the restore finds the latest plan live.
@Suite("Lift and the allowlist engine", .serialized, .timeLimit(.minutes(1)))
struct LiftEngineTests {
    private let own = EngineFixtures.own
    private let everyApp = ["com.example.a", "com.example.b", "com.example.c"]

    private func planA() -> VisibilityPlan {
        EngineFixtures.plan(visible: ["com.example.a"], concealed: ["com.example.b", "com.example.c"])
    }

    private func planB() -> VisibilityPlan {
        EngineFixtures.plan(visible: ["com.example.a", "com.example.b"], concealed: ["com.example.c"])
    }

    private func make() -> (engine: AllowlistEngine, allowlist: FakeAllowlist, hidden: HiddenApps) {
        let hidden = HiddenApps()
        let allowlist = FakeAllowlist(hidden: hidden, everyApp: { [everyApp] in everyApp })
        return (AllowlistEngine(allowlist: allowlist, ownBundleID: own, isInstalledCopy: true), allowlist, hidden)
    }

    /// A lift that waits out the second it gives a panel that never opens, and then restores the engine; returns when the restore is done.
    private func runLift(on engine: AllowlistEngine, clock: FakeClock) async {
        let done = Gate()
        let runner = LiftRunner(clock: clock, isOpen: { false }, restore: {
            await engine.restoreAfterLift()
            done.open()
        })
        runner.replayed()
        for _ in 0..<5 {
            _ = await clock.waitForSleepers(1, within: .seconds(5))
            clock.advance(by: LiftSession.pollInterval)
        }
        await done.wait()
    }

    /// Lifts the engine while it is making the live assertion for `planB`, which fails.
    private func liftDuringAFailingActivation(_ engine: AllowlistEngine, _ allowlist: FakeAllowlist) async throws {
        try await engine.apply(planA())
        #expect(engine.isArmed)
        let gate = Gate()
        allowlist.holdActivations(until: gate)
        let inFlight = Task { try await engine.apply(planB()) }
        #expect(await waitUntil { allowlist.calls.count == 2 }, "the second activation is under way")

        #expect(engine.liftNow(), "the click lifts")
        allowlist.fail(with: .failed("macOS refused"))
        gate.open()
        let error = await #expect(throws: HidingError.self) { try await inFlight.value }
        #expect(error == .failed(.allowlist, "macOS refused"))
        allowlist.holdActivations(until: nil)
        allowlist.fail(with: nil)
    }

    @Test func aFailedApplyDuringALiftIsRestoredAfterwards() async throws {
        let (engine, allowlist, hidden) = make()
        try await liftDuringAFailingActivation(engine, allowlist)
        // The failed activation let go of everything, and with it the lift: nothing is held, and nothing is waiting to be put back.
        #expect(!engine.isArmed)
        #expect(allowlist.live == 0)
        #expect(hidden.all.isEmpty)

        // The lift's end: the restore puts the latest plan (the one that failed) live.
        await runLift(on: engine, clock: FakeClock())

        #expect(engine.isArmed)
        #expect(allowlist.live == 1)
        #expect(allowlist.calls.last?.bundleIDs == ["com.example.a", "com.example.b", own], "the latest plan, and not the one before it")
        #expect(hidden.all == ["com.example.c"])
    }

    @Test func aPlanThatRearmedDuringTheLiftIsNotActivatedAgain() async throws {
        let (engine, allowlist, _) = make()
        try await liftDuringAFailingActivation(engine, allowlist)
        // The next plan found nothing lifted, and made the allowlist live while the panel may still be open.
        let latest = EngineFixtures.plan(visible: ["com.example.a", "com.example.c"], concealed: ["com.example.b"])
        try await engine.apply(latest)
        #expect(engine.isArmed)
        let calls = allowlist.calls.count

        await runLift(on: engine, clock: FakeClock())

        #expect(engine.isArmed, "the restore finds it already live")
        #expect(allowlist.calls.count == calls, "and activates nothing a second time")
        #expect(allowlist.live == 1)
        #expect(allowlist.calls.last?.bundleIDs == ["com.example.a", "com.example.c", own])
    }

    @Test func aRestoreThatFailsLeavesNothingHeldUntilTheNextPlan() async throws {
        let (engine, allowlist, hidden) = make()
        try await engine.apply(planA())
        #expect(engine.liftNow())
        allowlist.fail(with: .failed("macOS refused"))

        await runLift(on: engine, clock: FakeClock())

        #expect(!engine.isArmed, "nothing is held: everything shows rather than what is stale")
        #expect(hidden.all.isEmpty)

        // The next plan is applied as usual, and hides again.
        allowlist.fail(with: nil)
        try await engine.apply(planB())
        #expect(engine.isArmed)
        #expect(allowlist.live == 1)
    }

    @Test func aTearDownDuringALiftLeavesNothingWaitingToBeRestored() async throws {
        let (engine, allowlist, hidden) = make()
        try await engine.apply(planA())
        #expect(engine.liftNow())

        // Another engine took over, or the app is quitting, and the lift's runner was stopped without restoring: the teardown is what ends it.
        await engine.tearDown()
        #expect(!engine.isArmed)
        #expect(hidden.all.isEmpty)

        // A plan applied after that is applied as usual: the lift isn't left in force.
        try await engine.apply(planB())
        #expect(engine.isArmed)
        #expect(allowlist.live == 1)
    }
}
