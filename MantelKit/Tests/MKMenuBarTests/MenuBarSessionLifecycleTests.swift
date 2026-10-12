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
    private func started(sections initial: SectionModel = sections(hidden: [weather])) async -> (rig: SessionRig, engine: FakeEngine, log: CallLog) {
        let log = CallLog()
        let engine = FakeEngine(.allowlist, log: log)
        let rig = SessionRig.withEngines([.allowlist: engine], sections: initial, events: log)
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
        // A read now, and one every 250 ms for five seconds, and the one that ends the reset.
        #expect(await rig.session.scansIngested == reads + 1 + 20 + 1)
        #expect(engine.applied.count > applied, "hiding is tried anyway")
        #expect(await rig.session.isResetting == false)
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
        try await Task.sleep(for: .milliseconds(50))
        #expect(engine.reapplied == reapplied + 1, "the reset's own forced plan, and no refresh of the session's")
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
        try await Task.sleep(for: .milliseconds(50))

        // The reset begins, and stops at the restart.
        let restartGate = Gate()
        let restarter = FakeRestarter(log: log)
        restarter.whileRestarting { await restartGate.wait() }
        let reset = Task { await rig.session.resetIfIdle(restarter: restarter, replayJournal: replay(log)) }
        try await Task.sleep(for: .milliseconds(50))
        let applies = engine.applies

        gate.open()
        #expect(await waitUntil { restarter.restarts == 1 }, "the reset is waiting for the menu bar to restart")
        try await Task.sleep(for: .milliseconds(50))

        // The refresh that was under way, and the one behind it, found a reset and did nothing: nothing is applied while the menu bar is
        // being restarted, and so nothing is in charge.
        #expect(engineCalls(after: "allowlist.tearDown", in: log) == [], "nothing was applied between the teardown and the restart")
        #expect(engine.applies == applies)

        restartGate.open()
        #expect(await reset.value == .done)
        await first.value
        await second.value
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
        await refreshing.value
        try await Task.sleep(for: .milliseconds(50))
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
        try await Task.sleep(for: .milliseconds(50))
        let applies = engine.applies

        let restartGate = Gate()
        let restarter = FakeRestarter(log: log)
        restarter.whileRestarting { await restartGate.wait() }
        let reset = Task { await rig.session.resetIfIdle(restarter: restarter, replayJournal: replay(log)) }
        try await Task.sleep(for: .milliseconds(30))
        gate.open()
        #expect(await waitUntil { restarter.restarts == 1 })
        try await Task.sleep(for: .milliseconds(30))

        #expect(engine.applies == applies, "the plan that was waiting was never given to the engine")
        #expect(engineCalls(after: "allowlist.tearDown", in: log) == [])

        restartGate.open()
        #expect(await reset.value == .done)
        await applying.value
        await waiting.value
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
        try await Task.sleep(for: .milliseconds(30))
        #expect(engine.reapplied == 0, "two reads in a row are not three")
        #expect(await pollOnce(rig))
        #expect(await waitUntil { engine.reapplied == 1 }, "the third makes a refresh: the plan is applied again, by force")

        // Further reads that find nothing, within the minute: no second one.
        #expect(await pollOnce(rig))
        #expect(await pollOnce(rig))
        #expect(await pollOnce(rig))
        try await Task.sleep(for: .milliseconds(50))
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
        try await Task.sleep(for: .milliseconds(50))
        #expect(engine.reapplied == 0, "two and two, with an answer between, are not three in a row")
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
        try await Task.sleep(for: .milliseconds(50))

        #expect(engine.reapplied == 0)
        // It isn't counted at any later change either, while it has never had a bar.
        let again = Task { await rig.session.displaysChanged(layout) }
        #expect(await rig.letTheCoalescedReadGo())
        await again.value
        try await Task.sleep(for: .milliseconds(50))
        #expect(engine.reapplied == 0)
    }

    @Test func aDisplayChangeThatLeavesEveryBarWithSlotsIsNotRefreshed() async throws {
        let (rig, engine, _) = await started()
        let changed = Task { await rig.session.displaysChanged(rig.world.layout) }
        #expect(await rig.letTheCoalescedReadGo())
        await changed.value
        try await Task.sleep(for: .milliseconds(50))
        #expect(engine.reapplied == 0)
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
        rig.clock.advance(by: .seconds(120))
        try await Task.sleep(for: .milliseconds(30))
        #expect(engine.applied.count == applied)
        #expect(engine.tornDown == 1)
        #expect(await rig.session.scansIngested == reads)
        #expect(rig.clock.sleeperCount == 0, "the polling is over")
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

        rig.clock.advance(by: .seconds(120))
        try await Task.sleep(for: .milliseconds(30))
        #expect(await rig.session.scansIngested == 0, "nothing was read")
        #expect(rig.clock.sleeperCount == 0, "no polling, no check every minute")
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

        rig.clock.advance(by: .seconds(120))
        try await Task.sleep(for: .milliseconds(30))
        #expect(rig.clock.sleeperCount == 0, "no polling, no check every minute")
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
        try await Task.sleep(for: .milliseconds(20))
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
        try await Task.sleep(for: .milliseconds(30))
        let appliesBefore = engine.applies

        let result = Mutex<Bool?>(nil)
        let quit = Task {
            let finished = await rig.session.tearDownEngineForQuit()
            result.withLock { $0 = finished }
        }
        #expect(await waitUntil { rig.clock.sleeperCount == 1 }, "only the bound is waiting on the clock")
        rig.clock.advance(by: .milliseconds(1499))
        try await Task.sleep(for: .milliseconds(20))
        #expect(result.withLock { $0 } == nil, "1.499 seconds is inside the bound")
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
