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
@Suite("Menu bar session: reset, quit and auto-refresh", .timeLimit(.minutes(1)))
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

    /// Runs `body` while the clock is moved on 100 ms every time the session is waiting on it, until `body` is done. `each` runs before
    /// every move, with the time that has passed since the call began (for a test that changes the world as time goes by).
    private func driven(_ rig: SessionRig, each: @escaping @Sendable (Duration) -> Void = { _ in }, _ body: @escaping @Sendable () async -> Void) async -> Bool {
        let finished = Switch(false)
        let began = rig.clock.now()
        let work = Task {
            await body()
            finished.set(true)
        }
        let ended = await rig.driveClock {
            each(.seconds(rig.clock.now().timeIntervalSince(began)))
            return finished.isOn
        }
        await work.value
        return ended
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

    @Test func resetEndsCollapsed() async throws {
        let rig = SessionRig.withAllowlist(sections: sections(hidden: [weather], alwaysHidden: [notes]))
        await rig.session.start()
        #expect(await rig.session.setReveal(.allShown) == .none)
        #expect(rig.world.concealed.isEmpty, "everything is showing")
        #expect(try #require(await rig.state).plan.source == .reveal(.all))

        try await rig.session.reset(restarter: FakeRestarter(), replayJournal: {})

        // Collapsed, and hiding what the sections say: a reset doesn't stop hiding.
        let state = try #require(await rig.state)
        #expect(state.plan.source == .sections)
        #expect(state.plan.concealedSections == [.hidden, .alwaysHidden])
        #expect(rig.world.concealed == [weather, notes])
        let allowlist = try #require(rig.allowlist)
        #expect(allowlist.live == 1)
        // And it stays so: the next plan is the collapsed one too.
        await rig.session.setNewItemsSection(.shown)
        #expect(try #require(await rig.state).plan.source == .sections)
        #expect(rig.world.concealed == [weather, notes])
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

    @Test func aRefreshThatRanSaysSo() async throws {
        let (rig, engine, _) = await started()
        let reapplied = engine.reapplied

        let outcome = await rig.session.refresh()

        #expect(outcome == .done)
        #expect(outcome.result == .ok(.string("Menu bar refreshed.")))
        #expect(engine.reapplied == reapplied + 1)
    }

    @Test func everyChoiceOfAnEngineAfterAFailedResetPutsOneInChargeExplicitly() async throws {
        // After the teardown the controller has forgotten its choice, so only a call that chooses brings an engine back: a refresh, and a
        // change of the hiding method, which are the person's.
        let log = CallLog()
        let allowlist = FakeEngine(.allowlist, log: log)
        let spacer = FakeEngine(.spacer, log: log)
        let rig = SessionRig.withEngines([.allowlist: allowlist, .spacer: spacer], sections: sections(hidden: [weather]), events: log)
        await rig.session.start()
        let restarter = FakeRestarter()
        restarter.fail(with: .didNotComeBack)
        _ = await rig.session.resetIfIdle(restarter: restarter, replayJournal: {})
        let applied = (allowlist.applied.count, spacer.applied.count)

        // A plan that isn't a choice does nothing.
        await rig.session.setNewItemsSection(.shown)
        await rig.session.move(app: notes, to: .hidden)
        #expect((allowlist.applied.count, spacer.applied.count) == applied)

        // A change of method is a choice.
        var settings = HidingSettings()
        settings.method = .wideSpacer
        await rig.session.setSettings(settings)
        #expect(await rig.session.engineStatus().kind == .spacer)
        #expect(spacer.applied.count > applied.1)
        // And so is a refresh, which chooses again from the settings as they are.
        settings.method = .automatic
        await rig.session.setSettings(settings)
        #expect(await rig.session.engineStatus().kind == .allowlist)
        #expect(await rig.session.refresh() == .done)
    }

    @Test func resetWhenTheMenuBarIsNotRunningSaysSo() async throws {
        let rig = SessionRig.withAllowlist(sections: sections(hidden: [weather]))
        await rig.session.start()
        let restarter = FakeRestarter()
        restarter.fail(with: .notRunning)

        let outcome = await rig.session.resetIfIdle(restarter: restarter, replayJournal: {})

        #expect(outcome == .failed("macOS's menu bar isn't running. Log out and back in to start it."))
        #expect(outcome.result == .failure(code: .failed, message: "macOS's menu bar isn't running. Log out and back in to start it."))
        #expect(rig.world.concealed.isEmpty)
    }

    @Test func resetWaitsForTheAgentToAnswer() async throws {
        let (rig, engine, log) = await started()
        let applied = engine.applied.count
        // The process is started again, and for a second it doesn't answer.
        let restarter = FakeRestarter(log: log)
        restarter.whileRestarting { rig.world.setAgentRunning(false) }
        let reads = await rig.session.scansIngested
        let began = rig.clock.now()

        let done = await driven(rig, each: { passed in
            if passed >= .seconds(1) { rig.world.setAgentRunning(true) }
        }, {
            try? await rig.session.reset(restarter: restarter, replayJournal: {})
        })

        #expect(done)
        let waited = rig.clock.now().timeIntervalSince(began)
        #expect(waited >= 1 && waited < 2, "it waited for \(waited) seconds")
        #expect(await rig.session.scansIngested >= reads + 5, "a read every 250 ms")
        #expect(engine.applied.count > applied, "and then the plan was applied")
        #expect(try #require(await rig.state).inventory.agentAnswered)
    }

    @Test func resetGoesOnWhenTheAgentStaysSilentForFiveSeconds() async throws {
        let (rig, engine, log) = await started()
        let applied = engine.applied.count
        let reads = await rig.session.scansIngested
        let restarter = FakeRestarter(log: log)
        restarter.whileRestarting { rig.world.setAgentRunning(false) }
        let began = rig.clock.now()

        let done = await driven(rig, {
            try? await rig.session.reset(restarter: restarter, replayJournal: {})
        })

        #expect(done)
        #expect(rig.clock.now().timeIntervalSince(began) >= 5, "five seconds of waiting, at the least")
        // A read now, one after each pause of 250 ms until five seconds of the clock's time are up (the time the reads take counts, and the
        // clock here moves 100 ms at a time), and the one that ends the reset.
        let taken = await rig.session.scansIngested - reads
        #expect((17...23).contains(taken), "\(taken) reads")
        #expect(engine.applied.count > applied, "hiding is tried anyway")
        #expect(await rig.session.isResetting == false)
    }

    @Test func resetGivesUpOnTheAgentByTheClockWhateverTheReadsTook() async throws {
        let (rig, engine, log) = await started()
        let applied = engine.applied.count
        let reads = await rig.session.scansIngested
        let restarter = FakeRestarter(log: log)
        restarter.whileRestarting { rig.world.setAgentRunning(false) }
        let jumped = Switch(false)

        // The reads take their time (the clock is ten seconds on after the first of them): the wait is over, whatever number of pauses it
        // has made, after the read that finds it so.
        let done = await driven(rig, each: { passed in
            if passed >= .seconds(1), !jumped.isOn {
                jumped.set(true)
                rig.clock.advance(by: .seconds(10))
            }
        }, {
            try? await rig.session.reset(restarter: restarter, replayJournal: {})
        })

        #expect(done)
        let taken = await rig.session.scansIngested - reads
        #expect(taken < 12, "\(taken) reads: not the twenty that counting the pauses would make")
        #expect(engine.applied.count > applied, "and hiding is tried anyway")
    }

    @Test func autoRefreshSkippedDuringReset() async throws {
        // The agent doesn't answer while the reset waits for it, read after read: that is the reset's doing, and none of it counts.
        let (rig, engine, log) = await started()
        let restarter = FakeRestarter(log: log)
        restarter.whileRestarting { rig.world.setAgentRunning(false) }
        let reapplied = engine.reapplied

        let done = await driven(rig, each: { passed in
            if passed >= .seconds(2) { rig.world.setAgentRunning(true) }
        }, {
            try? await rig.session.reset(restarter: restarter, replayJournal: {})
        })

        #expect(done)
        // A refresh is started inside the read that calls for it: the reset's reads are over, and none started one.
        #expect(await rig.session.autoRefreshesStarted == 0, "no refresh of the session's")
        #expect(engine.reapplied == reapplied + 1, "the reset's own forced plan")
        #expect(await rig.session.isResetting == false)

        // And nothing was counted: the reset's failed reads aren't the first of three, so three that come after it are the first three.
        rig.world.setAgentRunning(false)
        await rig.session.setSettingsOpen(true)
        for _ in 0..<3 {
            #expect(await pollOnce(rig))
        }
        #expect(await waitUntil { engine.reapplied == reapplied + 2 }, "a refresh now: no minute has been spent on one during the reset")
    }

    @Test func refreshDuringAResetDoesNothing() async throws {
        let (rig, engine, log) = await started()
        let gate = Gate()
        let restarter = FakeRestarter(log: log)
        restarter.whileRestarting { await gate.wait() }
        let reset = Task { await rig.session.resetIfIdle(restarter: restarter, replayJournal: {}) }
        #expect(await waitUntil { restarter.restarts == 1 })
        #expect(await rig.session.isResetting)
        let applied = engine.applied.count

        let outcome = await rig.session.refresh()

        #expect(outcome == .refused("A reset is already under way."), "it says so, and doesn't say that it refreshed")
        #expect(outcome.result == .failure(code: .unavailable, message: "A reset is already under way."))
        #expect(engine.applied.count == applied, "nothing is applied while the menu bar is being restarted")
        gate.open()
        #expect(await reset.value == .done)
        #expect(engine.applied.count > applied)
    }

    // MARK: A reset that a refresh could undo

    /// What was done to the engine after it was taken down, up to now: the engine's own calls, not the reads.
    private func engineCalls(after marker: String, in log: CallLog) -> [String] {
        guard let index = log.all.lastIndex(of: marker) else { return [] }
        return log.all.dropFirst(index + 1).filter { $0.hasPrefix("allowlist.") }
    }

    @Test func aRefreshAlreadyUnderWayDoesNotUndoAReset() async throws {
        let log = CallLog()
        let engine = HeldEngine(.allowlist, log: log)
        let rig = SessionRig.withEngines([.allowlist: engine], sections: sections(hidden: [weather]), events: log)
        await rig.session.start()

        // A refresh has its plan being applied, and takes its time. A second refresh asks which engine to use, and waits behind the apply.
        let gate = Gate()
        engine.holdApplies(at: gate)
        let first = Task { await rig.session.refresh() }
        await engine.applyEntered.wait()
        let second = Task { await rig.session.refresh() }
        await letTasksRun()

        // The reset begins, and stops at the restart.
        let restartGate = Gate()
        let restarter = FakeRestarter(log: log)
        restarter.whileRestarting { await restartGate.wait() }
        let reset = Task { await rig.session.resetIfIdle(restarter: restarter, replayJournal: replay(log)) }
        await letTasksRun()
        let applies = engine.applies

        gate.open()
        #expect(await waitUntil { restarter.restarts == 1 }, "the reset is waiting for the menu bar to restart")
        // Both refreshes have ended before anything is looked at: they don't wait for the restart.
        _ = await first.value
        _ = await second.value

        // The refresh that was under way, and the one behind it, found a reset and did nothing: nothing is applied while the menu bar is
        // being restarted, and so nothing is in charge.
        #expect(engineCalls(after: "allowlist.tearDown", in: log) == [], "nothing was applied between the teardown and the restart")
        #expect(engine.applies == applies)

        restartGate.open()
        #expect(await reset.value == .done)
        #expect(engine.applies > applies, "and the reset's own plan was applied when it was done")
        #expect(log.all.last(where: { $0.hasPrefix("allowlist.") }) == "allowlist.apply")
    }

    @Test func aRefreshWaitingForTheTurnedOffAppsDoesNotUndoAReset() async throws {
        let (rig, engine, log) = await started()
        let gate = Gate()
        rig.turnedOff.holdQuestions(at: gate)
        let refreshing = Task { await rig.session.refresh() }
        #expect(await waitUntil { rig.turnedOff.questionsHeld == 1 }, "the refresh is asking which apps are turned off")

        let restartGate = Gate()
        let restarter = FakeRestarter(log: log)
        restarter.whileRestarting { await restartGate.wait() }
        let reset = Task { await rig.session.resetIfIdle(restarter: restarter, replayJournal: replay(log)) }
        #expect(await waitUntil { restarter.restarts == 1 }, "the engine is down and the reset waits for the restart")
        let applied = engine.applied.count

        gate.open()
        _ = await refreshing.value
        #expect(engineCalls(after: "allowlist.tearDown", in: log) == [], "the answer came too late to choose an engine or apply a plan")
        #expect(engine.applied.count == applied)

        restartGate.open()
        #expect(await reset.value == .done)
        #expect(engine.applied.count > applied)
    }

    @Test func aPlanThatWaitsBehindAnApplyIsDroppedWhenAResetBegins() async throws {
        let log = CallLog()
        let engine = HeldEngine(.allowlist, log: log)
        let rig = SessionRig.withEngines([.allowlist: engine], sections: sections(hidden: [weather]), events: log)
        await rig.session.start()
        let gate = Gate()
        engine.holdApplies(at: gate)
        let applying = Task { await rig.session.move(app: weather, to: .shown) }
        await engine.applyEntered.wait()
        let waiting = Task { await rig.session.move(app: notes, to: .hidden) }
        await letTasksRun()
        let applies = engine.applies

        let restartGate = Gate()
        let restarter = FakeRestarter(log: log)
        restarter.whileRestarting { await restartGate.wait() }
        let reset = Task { await rig.session.resetIfIdle(restarter: restarter, replayJournal: replay(log)) }
        await letTasksRun()
        gate.open()
        #expect(await waitUntil { restarter.restarts == 1 })
        // The apply that was under way and the plan that waited behind it have both ended (neither waits for the restart).
        await applying.value
        await waiting.value

        #expect(engine.applies == applies, "the plan that was waiting was never given to the engine")
        #expect(engineCalls(after: "allowlist.tearDown", in: log) == [])

        restartGate.open()
        #expect(await reset.value == .done)
    }

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

    @Test func aResetThatItsCallerGivesUpOnIsStillFinished() async throws {
        let (rig, engine, log) = await started()
        let gate = Gate()
        let restarter = FakeRestarter(log: log)
        restarter.whileRestarting { await gate.wait() }
        let applied = engine.applied.count
        let caller = Task { try? await rig.session.reset(restarter: restarter, replayJournal: {}) }
        #expect(await waitUntil { restarter.restarts == 1 })

        caller.cancel()
        gate.open()
        await caller.value

        #expect(engine.applied.count > applied, "it went on to apply the plan")
        #expect(await rig.session.isResetting == false)
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

    @Test func aReadTheAgentAnsweredStartsTheCountAgain() async throws {
        let (rig, engine, _) = await started()
        await rig.session.setSettingsOpen(true)
        rig.world.setAgentRunning(false)
        #expect(await pollOnce(rig))
        #expect(await pollOnce(rig))
        rig.world.setAgentRunning(true)
        #expect(await pollOnce(rig))
        rig.world.setAgentRunning(false)
        #expect(await pollOnce(rig))
        #expect(await pollOnce(rig))
        #expect(await rig.session.autoRefreshesStarted == 0, "two and two, with an answer between, are not three in a row")
        #expect(engine.reapplied == 0)
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

    @Test func aDisplayThatNeverHadABarDoesNotTriggerARefresh() async throws {
        // With "Displays have separate Spaces" off the other displays have no menu bar at all: a display change that brings one is not a
        // bar that went empty.
        let (rig, engine, _) = await started()
        let ghost = DisplayInfo(uuid: "ghost-display", name: "Plugged in", frame: CGRect(x: 6000, y: 0, width: 1920, height: 1080),
                                visibleFrame: CGRect(x: 6000, y: 0, width: 1920, height: 1049), scale: 2, notch: nil, isBuiltIn: false,
                                isMain: false)
        let layout = DisplayLayout(displays: rig.world.layout.displays + [ghost])

        let changed = Task { await rig.session.displaysChanged(layout) }
        #expect(await rig.letTheCoalescedReadGo())
        await changed.value

        #expect(await rig.session.autoRefreshesStarted == 0)
        #expect(engine.reapplied == 0)
        // It isn't counted at any later change either, while it has never had a bar.
        let again = Task { await rig.session.displaysChanged(layout) }
        #expect(await rig.letTheCoalescedReadGo())
        await again.value
        #expect(await rig.session.autoRefreshesStarted == 0)
        #expect(engine.reapplied == 0)
    }

    @Test func aDisplayChangeThatLeavesEveryBarWithSlotsIsNotRefreshed() async throws {
        let (rig, engine, _) = await started()
        let changed = Task { await rig.session.displaysChanged(rig.world.layout) }
        #expect(await rig.letTheCoalescedReadGo())
        await changed.value
        #expect(await rig.session.autoRefreshesStarted == 0)
        #expect(engine.reapplied == 0)
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

    @Test func nothingIsRefreshedWhileTheDisplaysAreAsleepOrAnotherUserIsOnScreen() async throws {
        for held in [SessionChange.displaysAsleep(true), .sessionActive(false)] {
            let (rig, engine, _) = await started()
            rig.world.setAgentRunning(false)
            await rig.session.sessionChanged(held)
            for _ in 0..<30 { #expect(await pollIdle(rig)) }
            #expect(await refreshLines(rig).isEmpty, "\(held)")
            #expect(engine.reapplied == 0, "\(held)")
        }
    }

    @Test func unlockStartsTheCountAgain() async throws {
        let (rig, engine, _) = await started()
        rig.world.setAgentRunning(false)
        _ = await poll(rig, forMinutes: 25)
        #expect(await refreshed(engine, 4), "all four of an outage, and the stop")

        // Locked for a while: nothing, and nothing counted.
        await rig.session.sessionChanged(.screenLocked(true))
        for _ in 0..<12 { #expect(await pollIdle(rig)) }
        #expect(await refreshLines(rig).count == 4)
        #expect(engine.reapplied == 4)

        // Unlocked: it is a new outage, and the third read that the agent doesn't answer refreshes it (the minute since the last refresh
        // went by while the screen was locked).
        await rig.session.sessionChanged(.screenLocked(false))
        #expect(await pollIdle(rig))
        #expect(await pollIdle(rig))
        #expect(await refreshLines(rig).count == 4, "two reads aren't three")
        #expect(engine.reapplied == 4)
        #expect(await pollIdle(rig))
        #expect(await refreshed(engine, 5))
        let lines = await rig.session.autoRefreshLogLines
        #expect(lines.suffix(2) == ["auto-refresh resumed", "refreshing the menu bar: \(firstStep)"], "the first of four again")
    }

    @Test func systemWakeStartsOver() async throws {
        let (rig, engine, _) = await started()
        rig.world.setAgentRunning(false)
        _ = await poll(rig, forMinutes: 25)
        #expect(await refreshed(engine, 4))

        // The Mac wakes: the displays' own notification may come before or after, and either way this is a wake.
        await rig.session.sessionChanged(.systemWoke)
        #expect(await pollIdle(rig))
        #expect(await pollIdle(rig))
        #expect(await refreshLines(rig).count == 4, "two reads aren't three")
        #expect(engine.reapplied == 4)
        #expect(await pollIdle(rig))
        #expect(await refreshed(engine, 5), "the count was begun again by the wake alone")
        #expect(await refreshLines(rig).last == "refreshing the menu bar: \(firstStep)")
        #expect(!(await rig.session.autoRefreshLogLines.contains("auto-refresh resumed")), "the session was never held")
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

    @Test func manualRefreshWorksWhileLockedAndAfterTheLastStep() async throws {
        let (rig, engine, _) = await started()
        await rig.session.sessionChanged(.screenLocked(true))
        #expect(await rig.session.refresh() == .done)
        #expect(engine.reapplied == 1, "a refresh that is asked for is not held back")
        await rig.session.sessionChanged(.screenLocked(false))

        // Unlocking started everything over, and the manual one left nothing behind: the outage has its four.
        rig.world.setAgentRunning(false)
        _ = await poll(rig, forMinutes: 25)
        #expect(await refreshed(engine, 1 + 4))

        // After the last step nothing refreshes by itself, and a refresh that is asked for still works.
        #expect(await rig.session.refresh() == .done)
        #expect(engine.reapplied == 6)
        _ = await poll(rig, forMinutes: 5)
        #expect(await refreshLines(rig).count == 4, "no fifth: it was not a reset, either, while the agent still says nothing")
        #expect(engine.reapplied == 6)
    }

    @Test func aManualRefreshIsNeitherAStepNorAResetOfTheBackOff() async throws {
        let (rig, engine, _) = await started()
        rig.world.setAgentRunning(false)
        for _ in 0..<3 { #expect(await pollIdle(rig)) }
        #expect(await refreshed(engine, 1), "the first refresh of the outage")

        // Asked for in the middle of the outage, with the screen on: it is a refresh like any, and moves nothing of what is counted.
        #expect(await rig.session.refresh() == .done)
        #expect(engine.reapplied == 2)

        // The outage still has three more, 1, 5 and 15 minutes after the one before, and not the manual one.
        _ = await poll(rig, forMinutes: 25)
        #expect(await refreshed(engine, 2 + 3))
        #expect(await refreshLines(rig) == [firstStep, secondStep, thirdStep, lastStep].map { "refreshing the menu bar: \($0)" },
                "the numbers go one, two, three, four: the manual one has none")
    }

    @Test func aManualRefreshThatTheAgentAnswersThenAPollEndTheOutage() async throws {
        let (rig, engine, _) = await started()
        rig.world.setAgentRunning(false)
        _ = await poll(rig, forMinutes: 25)
        #expect(await refreshed(engine, 4))

        // The agent is back, and the refresh that is asked for reads the bar: that read is answered, as is the idle poll ten seconds later,
        // which ends the outage (answers that span less than a poll's interval are most likely the refresh's own read).
        rig.world.setAgentRunning(true)
        #expect(await rig.session.refresh() == .done)
        #expect(engine.reapplied == 5)
        #expect(await pollIdle(rig))
        rig.world.setAgentRunning(false)
        _ = await poll(rig, forMinutes: 1)
        #expect(await refreshed(engine, 6), "a new outage, with its first refresh (the second waits a minute more)")
    }

    @Test func pauseAndResumeAreLoggedOnce() async throws {
        let state = FakeSessionState()
        let (rig, engine, _) = await started(sessionState: state)
        rig.world.setAgentRunning(false)
        let session = rig.session

        let lines = await LogCapture.lines {
            // The changes come through the source, as the system's do, and every one of them is a change of the state.
            state.send(.displaysAsleep(true))
            state.send(.screenLocked(true))
            state.send(.sessionActive(false))
            state.send(.systemWoke)
            state.send(.displaysAsleep(false))
            state.send(.screenLocked(false))
            state.send(.sessionActive(true))
            _ = await waitUntilLines(session, count: 2)
        }

        #expect(await rig.session.autoRefreshLogLines == ["auto-refresh paused: the displays are asleep", "auto-refresh resumed"],
                "once when it was held back, and once when it was let go: the changes in between changed nothing")
        #expect(lines.contains { $0.hasSuffix("[session] auto-refresh paused: the displays are asleep") })
        #expect(lines.contains { $0.hasSuffix("[session] auto-refresh resumed") })
        #expect(await rig.session.sessionNow == .awake)
        #expect(engine.reapplied == 0)
    }

    @Test func aSessionThatStartsHeldBackSaysSoAndLetsGoWhenTheStateChanges() async throws {
        let state = FakeSessionState(SessionState(screenLocked: true))
        let (rig, engine, _) = await started(sessionState: state)
        #expect(await rig.session.sessionNow == SessionState(screenLocked: true))
        #expect(await rig.session.autoRefreshLogLines == ["auto-refresh paused: the screen is locked"])

        rig.world.setAgentRunning(false)
        for _ in 0..<12 { #expect(await pollIdle(rig)) }
        #expect(await refreshLines(rig).isEmpty, "held from the start")
        #expect(engine.reapplied == 0)

        state.send(.screenLocked(false))
        #expect(await waitUntilLines(rig.session, count: 2))
        #expect(await rig.session.autoRefreshLogLines.last == "auto-refresh resumed")
        for _ in 0..<3 { #expect(await pollIdle(rig)) }
        #expect(await refreshed(engine, 1))
    }

    @Test func quitStopsListeningToTheSession() async throws {
        let state = FakeSessionState()
        let (rig, _, _) = await started(sessionState: state)
        #expect(state.openStreams == 1)

        await rig.session.tearDownForQuit()

        #expect(await waitUntil { state.openStreams == 0 }, "the listener is ended with the polling")
        // Nobody is listening for it now; and if it did get to the session, the session takes no change after the quit.
        state.send(.screenLocked(true))
        await rig.session.sessionChanged(.screenLocked(true))
        #expect(await rig.session.sessionNow == .awake)
        #expect(await rig.session.autoRefreshLogLines.isEmpty)
    }

    /// Returns once the session's log of auto-refresh has this many lines; false if it doesn't within five seconds.
    private func waitUntilLines(_ session: MenuBarSession, count: Int) async -> Bool {
        let enough = await withinTimeLimit(.seconds(5)) {
            while await session.autoRefreshLogLines.count < count {
                guard !Task.isCancelled else { return false }
                await Task.yield()
            }
            return true
        }
        return enough ?? false
    }

    @Test func aDisplayChangeSeenWhileTheDisplaysAreAsleepIsJudgedAfterTheWake() async throws {
        // As anEmptyBarAfterADisplayChangeRefreshes, with the displays asleep when the change is read, and the notification that wakes
        // them after it: the bar is judged by the first read that may refresh, against the bars there were before the change.
        let (rig, engine, _) = await started()
        let had = try #require(await rig.state).inventory.bars.map(\.displayUUID)
        #expect(had.contains(DisplayFixtures.deskPortrait.uuid), "the portrait display had a bar")
        await rig.session.sessionChanged(.displaysAsleep(true))
        rig.world.setShape(.laptop)
        let layout = DisplayLayout(displays: rig.world.layout.displays + [DisplayFixtures.deskPortrait])

        let changed = Task { await rig.session.displaysChanged(layout) }
        #expect(await rig.letTheCoalescedReadGo())
        await changed.value
        #expect(await refreshLines(rig).isEmpty, "held: the displays are asleep")
        #expect(engine.reapplied == 0)

        await rig.session.sessionChanged(.displaysAsleep(false))
        #expect(await refreshLines(rig).isEmpty, "the wake itself reads nothing")
        #expect(engine.reapplied == 0)
        #expect(await pollIdle(rig))
        #expect(await refreshed(engine, 1), "the display that had a bar and has none: refreshed once")
        #expect(await refreshLines(rig) == ["refreshing the menu bar: a display change left the menu bar empty; refreshing once"])
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
