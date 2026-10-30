import CoreGraphics
import Foundation
import MKCommands
import MKCore
import MKLayout
import MKTestSupport
import Synchronization
import Testing

@testable import MKMenuBar

private let weather = SessionWorld.weather
private let notes = SessionWorld.notes
private let own = SessionWorld.own

/// An engine that can be made to take its time: a plan it is applying, or the teardown it is asked for, waits at a gate a test holds.
private final class HeldEngine: HidingEngine {
    let kind: HidingEngineKind
    private let log: CallLog
    private let applyGate = Mutex<Gate?>(nil)
    private let tearDownGate = Mutex<Gate?>(nil)
    private let counts = Mutex((applies: 0, tornDown: 0))
    /// Opened when an apply (or a teardown) arrives at a gate that is held.
    let applyEntered = Gate()
    let tearDownEntered = Gate()

    init(_ kind: HidingEngineKind, log: CallLog) {
        self.kind = kind
        self.log = log
    }

    var applies: Int { counts.withLock { $0.applies } }
    var tornDown: Int { counts.withLock { $0.tornDown } }
    func holdApplies(at gate: Gate?) { applyGate.withLock { $0 = gate } }
    func holdTearDown(at gate: Gate?) { tearDownGate.withLock { $0 = gate } }

    func availability() async -> EngineAvailability { .available }

    func apply(_ plan: VisibilityPlan) async throws {
        log.add("\(kind.rawValue).apply")
        counts.withLock { $0.applies += 1 }
        if let gate = applyGate.withLock({ $0 }) {
            applyEntered.open()
            await gate.wait()
        }
    }

    func tearDown() async {
        if let gate = tearDownGate.withLock({ $0 }) {
            tearDownEntered.open()
            await gate.wait()
        }
        log.add("\(kind.rawValue).tearDown")
        counts.withLock { $0.tornDown += 1 }
    }
}

/// Resetting the menu bar, quitting, and the refreshes the session makes by itself.
@Suite("Menu bar session: reset, quit and auto-refresh", .serialized, .timeLimit(.minutes(1)))
struct MenuBarSessionLifecycleTests {
    private func replay(_ log: CallLog) -> @Sendable () async -> Void {
        { log.add("replay") }
    }

    /// An engine, a session over it that has started, and the log both write to.
    private func started(sections initial: SectionModel = sections(hidden: [weather]),
                         sessionState: any SessionStateSource = SteadySessionState()) async -> (rig: SessionRig, engine: FakeEngine, log: CallLog) {
        let log = CallLog()
        let engine = FakeEngine(.allowlist, log: log)
        let rig = SessionRig.withEngines([.allowlist: engine], sections: initial, events: log, sessionState: sessionState)
        await rig.session.start()
        return (rig, engine, log)
    }

    // MARK: Reset

    @Test func resetTearsDownReplaysRestartsAndReapplies() async throws {
        let (rig, engine, log) = await started()
        let mark = log.all.count
        let applied = engine.applied.count

        try await rig.session.reset(restarter: FakeRestarter(log: log), replayJournal: replay(log))

        // The order: everything is shown, what the journal holds is put back, the menu bar's process starts again. Nothing is applied
        // until it is back.
        let after = Array(log.all.dropFirst(mark)).filter { !$0.hasSuffix(".availability") }
        #expect(Array(after.prefix(3)) == ["allowlist.tearDown", "replay", "restart"])
        #expect(after.dropFirst(3).first == "scan", "then the menu bar is read until the agent answers")
        #expect(after.dropFirst(4).contains("allowlist.apply"), "and then the plan is applied again")
        #expect(after.last == "scan", "and read once more")
        #expect(engine.applied.count > applied)
        let state = try #require(await rig.state)
        #expect(state.plan.source == .sections)
        #expect(engine.applied.last?.concealedBundleIDs == [weather], "the plan the sections make")
        #expect(state.engine.lastError == nil)
        #expect(await rig.session.isResetting == false)
    }

    @Test func resetFailureLeavesEverythingShown() async throws {
        let rig = SessionRig.withAllowlist(sections: sections(hidden: [weather], alwaysHidden: [notes]))
        await rig.session.start()
        let allowlist = try #require(rig.allowlist)
        #expect(await rig.session.setReveal(.hiddenShown) == .none)
        #expect(rig.world.concealed == [notes])
        let restarter = FakeRestarter()
        restarter.fail(with: .didNotComeBack)
        let calls = allowlist.calls.count

        let error = await #expect(throws: RestartError.self) {
            try await rig.session.reset(restarter: restarter, replayJournal: {})
        }

        #expect(error == .didNotComeBack)
        #expect(error?.errorDescription == "macOS's menu bar didn't restart. Log out and back in to restart it.")
        #expect(rig.world.concealed.isEmpty, "everything is shown, and stays so")
        #expect(allowlist.live == 0)
        #expect(allowlist.calls.count == calls, "no plan was made live")
        #expect(await rig.session.isResetting == false)
        // The reveal is collapsed all the same, and what comes next applies nothing: nothing is in charge until a refresh.
        let state = try #require(await rig.state)
        #expect(state.plan.source == .sections)
        await rig.session.setNewItemsSection(.shown)
        await rig.session.move(app: notes, to: .alwaysHidden)
        #expect(allowlist.calls.count == calls)
        #expect(rig.world.concealed.isEmpty)

        // A refresh starts it again.
        await rig.session.refresh()
        #expect(rig.world.concealed == [weather, notes])
        #expect(allowlist.live == 1)
    }

    // MARK: A reset that a refresh could undo

    @Test func aSecondResetWhileOneRunsIsRefused() async throws {
        let (rig, _, log) = await started()
        let gate = Gate()
        let restarter = FakeRestarter(log: log)
        restarter.whileRestarting { await gate.wait() }
        let first = Task { await rig.session.resetIfIdle(restarter: restarter, replayJournal: replay(log)) }
        #expect(await waitUntil { restarter.restarts == 1 })

        let second = await rig.session.resetIfIdle(restarter: restarter, replayJournal: replay(log))

        #expect(second == .alreadyUnderWay)
        #expect(second.result == .failure(code: .unavailable, message: "A reset is already under way."))
        #expect(restarter.restarts == 1, "it started nothing")
        #expect(log.count("replay") == 1)

        gate.open()
        #expect(await first.value == .done)
        // Once it is over, another can be made.
        #expect(await rig.session.resetIfIdle(restarter: FakeRestarter(), replayJournal: {}) == .done)
    }

    @Test func readsDuringAResetDoNotMoveAppsToHidden() async throws {
        // Everything is shown while the reset waits, on a bar that has room for five of the icons: a read of it is not a judgment of
        // which apps fit.
        let rig = SessionRig.withAllowlist(shape: .laptop, capacity: 5)
        await rig.session.start()
        let before = await rig.session.sections
        let restarter = FakeRestarter()
        restarter.whileRestarting {
            // The bar is full while nothing is hidden: the read below sees the weather app's icons piled at the «.
            rig.world.setCapacity(3)
            await rig.session.setSettingsOpen(true)
        }

        try await rig.session.reset(restarter: restarter, replayJournal: {})

        // Whatever the reset's reads found, the sections are what they were: no app was put in Hidden by the reads that came during it.
        let after = await rig.session.sections
        #expect(after.apps.filter { $0.value.isAuto } == before.apps.filter { $0.value.isAuto })
    }

    // MARK: Auto-refresh

    /// Lets the polling of an open Settings window (every 2 seconds) have one read, and waits for it.
    private func pollOnce(_ rig: SessionRig) async -> Bool {
        guard await rig.clock.waitForSleepers(2, within: .seconds(5)) else { return false }
        let reads = await rig.session.scansIngested
        rig.clock.advance(by: .seconds(2))
        return await rig.pumpUntilReads(reads + 1)
    }

    @Test func threeAgentFailuresRefreshOnceThroughTheSession() async throws {
        let (rig, engine, _) = await started()
        #expect(engine.reapplied == 0)
        rig.world.setAgentRunning(false)
        await rig.session.setSettingsOpen(true)

        #expect(await pollOnce(rig))
        #expect(await pollOnce(rig))
        #expect(await rig.session.autoRefreshesStarted == 0, "two reads in a row are not three")
        #expect(engine.reapplied == 0)
        #expect(await pollOnce(rig))
        #expect(await waitUntil { engine.reapplied == 1 }, "the third makes a refresh: the plan is applied again, by force")

        // Further reads that find nothing, within the minute: no second one.
        #expect(await pollOnce(rig))
        #expect(await pollOnce(rig))
        #expect(await pollOnce(rig))
        #expect(await rig.session.autoRefreshesStarted == 1, "three more failures in a row start no second refresh yet")
        #expect(engine.reapplied == 1)
    }

    @Test func anEmptyBarAfterADisplayChangeRefreshes() async throws {
        // The desk has two bars. The portrait display stays, the main one goes, and the agent has no window for the portrait one now:
        // a display that had a bar has none.
        let (rig, engine, _) = await started()
        let had = try #require(await rig.state).inventory.bars.map(\.displayUUID)
        #expect(had.contains(DisplayFixtures.deskPortrait.uuid), "the portrait display had a bar")
        rig.world.setShape(.laptop)
        let layout = DisplayLayout(displays: rig.world.layout.displays + [DisplayFixtures.deskPortrait])

        let changed = Task { await rig.session.displaysChanged(layout) }
        #expect(await rig.letTheCoalescedReadGo())
        await changed.value

        #expect(await waitUntil { engine.reapplied == 1 }, "refreshed once, and the reason is logged")
    }

    // MARK: Holding auto-refresh back

    /// Lets the polling (every 10 seconds, with Settings closed) have one read, and waits for it.
    private func pollIdle(_ rig: SessionRig) async -> Bool {
        guard await rig.clock.waitForSleepers(2, within: .seconds(5)) else { return false }
        let reads = await rig.session.scansIngested
        rig.clock.advance(by: ScanScheduler.idleInterval)
        return await rig.pumpUntilReads(reads + 1)
    }

    /// Polls until `minutes` of the clock's time have gone, and gives the clock's time, in seconds from the first poll, at which each
    /// refresh of the session's own was decided. Stops short, with a failure, if a poll doesn't come.
    private func poll(_ rig: SessionRig, forMinutes minutes: Int) async -> [Double] {
        let began = rig.clock.now()
        var refreshedAt: [Double] = []
        var counted = await refreshLines(rig).count
        while rig.clock.now().timeIntervalSince(began) < Double(minutes * 60) {
            let polled = await pollIdle(rig)
            #expect(polled, "a poll was read")
            guard polled else { break }
            let lines = await refreshLines(rig)
            if lines.count > counted { refreshedAt += Array(repeating: rig.clock.now().timeIntervalSince(began), count: lines.count - counted) }
            counted = lines.count
        }
        return refreshedAt
    }

    /// The refreshes the session has decided on, each as it was logged. The line is written when the refresh is decided, before the
    /// refresh itself is started on a task of its own: a test that finds no new line knows there is no refresh on its way, and needn't
    /// wait to see none happen.
    private func refreshLines(_ rig: SessionRig) async -> [String] {
        await rig.session.autoRefreshLogLines.filter { $0.hasPrefix("refreshing the menu bar: ") }
    }

    /// Whether `engine` has been refreshed this many times (the forced applies), once the refresh the session started on a task of its
    /// own has got to it.
    private func refreshed(_ engine: FakeEngine, _ times: Int) async -> Bool {
        await waitUntil { engine.reapplied == times }
    }

    private let firstStep = "MenuBarAgent didn't answer 3 times in a row; refreshing (1 of 4); if it still doesn't answer, the next is in at least 1 minute"
    private let secondStep = "MenuBarAgent didn't answer 3 times in a row; refreshing (2 of 4); if it still doesn't answer, the next is in at least 5 minutes"
    private let thirdStep = "MenuBarAgent didn't answer 3 times in a row; refreshing (3 of 4); if it still doesn't answer, the next is in at least 15 minutes"
    private let lastStep = "MenuBarAgent didn't answer 3 times in a row; refreshing (4 of 4); no more until it answers"

    @Test func noAutoRefreshWhileTheScreenIsLocked() async throws {
        let (rig, engine, _) = await started()
        rig.world.setAgentRunning(false)
        await rig.session.sessionChanged(.screenLocked(true))
        let reads = await rig.session.scansIngested

        // Half an hour of a MenuBarAgent that says nothing, read every ten seconds: as the 88 minutes that were the bug, with no refresh.
        for _ in 0..<180 { #expect(await pollIdle(rig)) }

        #expect(await rig.session.scansIngested >= reads + 180, "the reads go on: they are what notices the agent answering again")
        #expect(await refreshLines(rig).isEmpty)
        #expect(engine.reapplied == 0)
        #expect(await rig.session.autoRefreshLogLines == ["auto-refresh paused: the screen is locked"])
    }

    @Test func twentyFiveSilentMinutesRefreshFourTimes() async throws {
        let (rig, engine, _) = await started()
        rig.world.setAgentRunning(false)
        let times = Mutex<[Double]>([])

        let lines = await LogCapture.lines {
            let found = await self.poll(rig, forMinutes: 25)
            times.withLock { $0 = found }
        }

        #expect(await refreshed(engine, 4), "the plan is applied again, by force, four times and no more")
        let steps = await refreshLines(rig)
        #expect(steps == [firstStep, secondStep, thirdStep, lastStep].map { "refreshing the menu bar: \($0)" })
        // Each one is in the log (lines other tests log at the same time may be there too, so these are looked for, not counted).
        let logged = lines.filter { $0.contains("refreshing the menu bar: ") }
        #expect(logged.count >= 4)
        for step in [firstStep, secondStep, thirdStep, lastStep] {
            #expect(logged.contains { $0.hasSuffix("[session] refreshing the menu bar: \(step)") }, "\(step)")
        }
        // At 30 seconds or a little after, then the waits of the back-off at the least (the clock goes in steps of ten and a tenth).
        let found = times.withLock { $0 }
        #expect(found.count == 4)
        #expect(found.first.map { $0 >= 30 && $0 < 45 } == true)
        for (index, wait) in AutoRefreshPolicy.backOff.enumerated() where index + 1 < found.count {
            #expect(found[index + 1] - found[index] >= Double(wait.components.seconds) - 0.5, "step \(index + 2)")
        }
        #expect(found.last.map { $0 < 25 * 60 } == true)
    }

    // MARK: Quit

    @Test func quitTearsDownBeforeReplay() async throws {
        let (rig, engine, log) = await started()
        let reads = await rig.session.scansIngested

        await rig.session.tearDownForQuit()
        // What comes next is the journal's replay, which finds what the engine put back already put back.
        log.add("replay")

        #expect(log.all.suffix(2) == ["allowlist.tearDown", "replay"])
        #expect(engine.tornDown == 1)

        // From here on nothing reaches the engine, and nothing is read.
        let applied = engine.applied.count
        await rig.session.setNewItemsSection(.hidden)
        await rig.session.move(app: notes, to: .hidden)
        #expect(await rig.session.refresh() == .refused("Mantel is quitting."))
        #expect(await rig.session.setReveal(.allShown) == .none)
        // Nothing sleeps on the clock, so no length of time can wake anything: the polling is over.
        #expect(rig.clock.sleeperCount == 0, "the polling is over")
        rig.clock.advance(by: .seconds(120))
        #expect(engine.applied.count == applied)
        #expect(engine.tornDown == 1)
        #expect(await rig.session.scansIngested == reads)
    }

    @Test func nothingPutsAnEngineBackInChargeAfterQuitting() async throws {
        // Choosing a way of hiding applies the plan with it, and a choice that was made after the quit would hide again.
        let log = CallLog()
        let allowlist = FakeEngine(.allowlist, log: log)
        let spacer = FakeEngine(.spacer, log: log)
        let rig = SessionRig.withEngines([.allowlist: allowlist, .spacer: spacer], sections: sections(hidden: [weather]), events: log)
        await rig.session.start()
        await rig.session.tearDownForQuit()
        let applied = (allowlist.applied.count, spacer.applied.count)

        var settings = HidingSettings()
        settings.method = .wideSpacer
        await rig.session.setSettings(settings)
        #expect(await rig.session.resetIfIdle(restarter: FakeRestarter(), replayJournal: {}) == .refused("Mantel is quitting."))

        #expect(allowlist.applied.count == applied.0)
        #expect(spacer.applied.count == applied.1, "the spacer was never made the engine in charge")
        #expect(log.all.suffix(1) == ["allowlist.tearDown"])
    }

    @Test func quitLetsGoOfAReadThatIsBeingWaitedFor() async throws {
        // A refresh is waiting for a read, which is held up; the scheduler is stopped for the quit and the read is dropped: the caller
        // goes on instead of waiting for ever.
        let (rig, _, _) = await started()
        let gate = Gate()
        rig.extras.holdReads(at: gate)
        let returned = Switch(false)
        let refreshing = Task {
            await rig.session.refresh()
            returned.set(true)
        }
        #expect(await waitUntil { rig.extras.readsHeld > 0 }, "the read is under way")

        await rig.session.tearDownForQuit()

        #expect(await waitUntil { returned.isOn }, "the refresh came back")
        gate.open()
        await refreshing.value
    }

    @Test func quitDuringStartDoesNotStartTheReadsOrTheMinutesCheckOfRoom() async throws {
        // The session is still starting (it waits for the list of apps macOS has turned off) when quitting begins. What start does next
        // would read the bar and poll it, and check for room every minute, all after the quit stopped them.
        let log = CallLog()
        let engine = FakeEngine(.allowlist, log: log)
        let rig = SessionRig.withEngines([.allowlist: engine], sections: sections(hidden: [weather]), events: log)
        let gate = Gate()
        rig.turnedOff.holdQuestions(at: gate)
        let starting = Task { await rig.session.start() }
        #expect(await waitUntil { rig.turnedOff.questionsHeld > 0 }, "start is waiting")

        await rig.session.tearDownForQuit()
        gate.open()
        await starting.value

        // What start sets going is set in the stretch of the call that starts it: nothing has to have reached the clock for this to show.
        #expect(await rig.session.isPollingTheBar == false, "the bar isn't polled")
        #expect(await rig.session.checksForRoomEveryMinute == false, "and there is no check for room every minute")
        rig.clock.advance(by: .seconds(120))
        #expect(await rig.session.scansIngested == 0, "nothing was read")
        #expect(engine.applied.isEmpty, "and nothing was applied")
    }

    @Test func quitDuringTheFirstReadsOfStartDoesNotStartThePollingEither() async throws {
        let log = CallLog()
        let engine = FakeEngine(.allowlist, log: log)
        let rig = SessionRig.withEngines([.allowlist: engine], sections: sections(hidden: [weather]), events: log)
        let gate = Gate()
        rig.extras.holdReads(at: gate)
        let starting = Task { await rig.session.start() }
        #expect(await waitUntil { rig.extras.readsHeld > 0 }, "the first read is under way")

        await rig.session.tearDownForQuit()
        gate.open()
        await starting.value

        #expect(await rig.session.isPollingTheBar == false, "no polling")
        #expect(await rig.session.checksForRoomEveryMinute == false, "no check every minute")
        rig.clock.advance(by: .seconds(120))
        #expect(rig.clock.sleeperCount == 0)
    }

    @Test func quitWaitsForATeardownThatIsUnderWay() async throws {
        let log = CallLog()
        let engine = HeldEngine(.allowlist, log: log)
        let rig = SessionRig.withEngines([.allowlist: engine], sections: sections(hidden: [weather]), events: log)
        await rig.session.start()
        let gate = Gate()
        engine.holdTearDown(at: gate)
        let finished = Switch(false)
        let quit = Task {
            await rig.session.tearDownForQuit()
            finished.set(true)
        }
        await engine.tearDownEntered.wait()
        // The quit is waiting: its bound (1.5 s on the clock) is the one sleeper, and the engine's teardown is held.
        #expect(await waitUntil { rig.clock.sleeperCount == 1 })
        #expect(!finished.isOn, "the journal's replay doesn't begin until the engine is down")

        gate.open()
        await quit.value
        #expect(engine.tornDown == 1)
        #expect(rig.clock.sleeperCount == 0, "the bound's timer is gone")
    }

    @Test func quitDoesNotWaitLongerThanOneAndAHalfSecondsForABusyEngine() async throws {
        let log = CallLog()
        let engine = HeldEngine(.allowlist, log: log)
        let rig = SessionRig.withEngines([.allowlist: engine], sections: sections(hidden: [weather]), events: log)
        await rig.session.start()
        #expect(MenuBarSession.quitTeardownLimit == .milliseconds(1500))

        // A plan is being applied, and takes its time (a preferences service that disagrees: seconds). Another is waiting behind it.
        let gate = Gate()
        engine.holdApplies(at: gate)
        let applying = Task { await rig.session.move(app: weather, to: .shown) }
        await engine.applyEntered.wait()
        let waiting = Task { await rig.session.move(app: notes, to: .hidden) }
        await letTasksRun()
        let appliesBefore = engine.applies

        let result = Mutex<Bool?>(nil)
        let quit = Task {
            let finished = await rig.session.tearDownEngineForQuit()
            result.withLock { $0 = finished }
        }
        #expect(await waitUntil { rig.clock.sleeperCount == 1 }, "only the bound is waiting on the clock")
        rig.clock.advance(by: .milliseconds(1499))
        #expect(rig.clock.sleeperCount == 1, "the bound hasn't gone off: 1.499 seconds is inside it")
        #expect(result.withLock { $0 } == nil)
        rig.clock.advance(by: .milliseconds(1))
        await quit.value
        #expect(result.withLock { $0 } == false, "and at 1.5 seconds it goes on: the journal's replay is next")
        #expect(engine.tornDown == 0, "the teardown is still queued behind the plan that is being applied")

        // The plan is let finish; the teardown follows it, and the plan that was waiting is never applied.
        gate.open()
        await applying.value
        await waiting.value
        #expect(await waitUntil { engine.tornDown == 1 }, "the teardown wasn't dropped")
        #expect(engine.applies == appliesBefore, "no plan was delivered after quitting began")
    }
}
