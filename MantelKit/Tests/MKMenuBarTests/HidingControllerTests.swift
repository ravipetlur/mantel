import Foundation
import MKCore
import MKLayout
import MKTestSupport
import Synchronization
import Testing

@testable import MKMenuBar

@Suite("Hiding controller", .timeLimit(.minutes(1)))
struct HidingControllerTests {
    /// Three fake engines, a clock that moves when a test says so, and what the controller said it did.
    private final class Rig: Sendable {
        let log: CallLog
        let allowlist: FakeEngine
        let approvals: FakeEngine
        let spacer: FakeEngine
        let clock: FakeClock
        let notes: CallLog
        let controller: HidingController

        /// - Parameters:
        ///   - confirms: what the menu bar says to a plan: seen at once, or never.
        ///   - answers: what each look says instead, by how many looks there have been (from 0), when a test needs more than that.
        ///   - eachLookTakes: how much of the clock a look takes, the way a read of a slow bar does.
        init(confirms: Bool = true, answers: (@Sendable (Int) -> PlanConfirmation)? = nil, eachLookTakes: Duration = .zero) {
            let log = CallLog()
            let notes = CallLog()
            let clock = FakeClock()
            let engines = (FakeEngine(.allowlist, log: log), FakeEngine(.approvals, log: log), FakeEngine(.spacer, log: log))
            self.log = log
            self.notes = notes
            self.clock = clock
            (allowlist, approvals, spacer) = engines
            controller = HidingController(
                engines: [.allowlist: engines.0, .approvals: engines.1, .spacer: engines.2], clock: clock,
                confirm: { _ in
                    let looks = log.count("confirm")
                    log.add("confirm")
                    if eachLookTakes > .zero { clock.advance(by: eachLookTakes) }
                    return answers?(looks) ?? (confirms ? .seen : .notYet)
                },
                note: { line in notes.add(line) })
        }

        /// What the engines were asked, without the questions about availability.
        var calls: [String] { log.all.filter { !$0.hasSuffix(".availability") } }
        var said: [String] { notes.all }
        var confirmations: Int { log.count("confirm") }

        /// Runs `body` while the clock is moved on by a look's interval every time the controller is waiting on it, until `body` is done:
        /// the wait for a confirmation that doesn't come takes no real time.
        func driven(_ body: @escaping @Sendable () async -> Void) async {
            let finished = Switch(false)
            let work = Task {
                await body()
                finished.set(true)
            }
            while !finished.isOn {
                if await clock.waitForSleepers(1, within: .milliseconds(20)) { clock.advance(by: HidingController.confirmationInterval) }
            }
            await work.value
        }
    }

    private let plan = EngineFixtures.plan(visible: ["com.example.a"], concealed: ["com.example.b"])
    private let otherPlan = EngineFixtures.plan(visible: ["com.example.a", "com.example.b"], concealed: ["com.example.c"])

    // MARK: Switching

    @Test func switchAppliesNewConfirmsThenTearsDownOld() async {
        let rig = Rig()
        await rig.controller.choose(method: .automatic)
        await rig.controller.apply(plan)
        #expect(rig.calls == ["allowlist.apply"], "the first choice has no plan to apply, and nothing to tear down")

        await rig.controller.choose(method: .wideSpacer)

        #expect(rig.calls == ["allowlist.apply", "spacer.apply", "confirm", "allowlist.tearDown"], "new, confirmed, then old")
        #expect(rig.spacer.applied == [plan], "the plan that is in force is the one the new engine is given")
        #expect(rig.clock.sleeperCount == 0)
        let status = await rig.controller.status()
        #expect(status.kind == .spacer)

        // Plans go to the new engine from then on.
        await rig.controller.apply(otherPlan)
        #expect(rig.spacer.applied == [plan, otherPlan])
        #expect(rig.allowlist.applied == [plan])
    }

    @Test func confirmationTimeoutStillTearsDownOld() async {
        let rig = Rig(confirms: false)
        await rig.controller.choose(method: .automatic)
        await rig.controller.apply(plan)
        let started = rig.clock.now()

        await rig.driven { await rig.controller.choose(method: .wideSpacer) }

        #expect(rig.confirmations == 9, "asked at once, and every 250 ms for 2 s")
        #expect(rig.clock.now().timeIntervalSince(started) == 2, "and no longer")
        #expect(rig.calls.suffix(2) == ["confirm", "allowlist.tearDown"], "the old engine goes all the same")
        #expect(rig.said == ["engine switch not confirmed within 2 s; tearing down Allowlist anyway"])
        #expect(HidingController.confirmationTimeout == .seconds(2))
    }

    @Test func theOldEngineIsTornDownOnlyOnceTheLookSaysThePlanIsOnTheBar() async {
        // Two looks that don't see it yet, and a third that does: the old engine goes after that one, and nothing is logged.
        let rig = Rig(answers: { $0 < 2 ? .notYet : .seen })
        await rig.controller.choose(method: .automatic)
        await rig.controller.apply(plan)
        let started = rig.clock.now()

        await rig.driven { await rig.controller.choose(method: .wideSpacer) }

        #expect(rig.calls == ["allowlist.apply", "spacer.apply", "confirm", "confirm", "confirm", "allowlist.tearDown"])
        #expect(rig.clock.now().timeIntervalSince(started) == 0.5, "two quarter seconds")
        #expect(rig.said.isEmpty)
    }

    @Test func aLookThatCantTellEndsTheWaitAtOnce() async {
        let rig = Rig(answers: { _ in .cantTell })
        await rig.controller.choose(method: .automatic)
        await rig.controller.apply(plan)

        // Not driven: the controller doesn't sleep at all.
        await rig.controller.choose(method: .wideSpacer)

        #expect(rig.calls == ["allowlist.apply", "spacer.apply", "confirm", "allowlist.tearDown"], "one look, then the old engine goes")
        #expect(rig.clock.sleeperCount == 0)
        #expect(rig.said == ["engine switch couldn't be confirmed on the bar; tearing down Allowlist anyway"])
        let status = await rig.controller.status()
        #expect(status.lastError == nil, "not an error of the engine")
        #expect(status.kind == .spacer)
    }

    @Test func theWaitIsTwoSecondsOfClockTimeWhateverTheLooksTake() async {
        // Each look takes three seconds: the first is the last, and the old engine goes after it.
        let rig = Rig(confirms: false, eachLookTakes: .seconds(3))
        await rig.controller.choose(method: .automatic)
        await rig.controller.apply(plan)

        await rig.controller.choose(method: .wideSpacer)

        #expect(rig.confirmations == 1)
        #expect(rig.clock.sleeperCount == 0)
        #expect(rig.calls.suffix(2) == ["confirm", "allowlist.tearDown"])
        #expect(rig.said == ["engine switch not confirmed within 2 s; tearing down Allowlist anyway"])
    }

    @Test func theLooksAreAQuarterOfASecondApart() {
        #expect(HidingController.confirmationInterval == .milliseconds(250))
        #expect(HidingController.confirmationTimeout == .seconds(2))
    }

    @Test func aStatusNamesTheChoiceItWasMadeForOnlyOnceTheSwitchIsDone() async {
        let rig = Rig(confirms: false)
        #expect(await rig.controller.status().decidedFor == nil, "nothing has been chosen")
        await rig.controller.choose(method: .automatic)
        await rig.controller.apply(plan)
        #expect(await rig.controller.status().decidedFor == .automatic)

        // In the middle of a switch the new engine is in charge, but the choice isn't done: the status still names the one before.
        let switching = Task { await rig.controller.choose(method: .wideSpacer) }
        #expect(await rig.clock.waitForSleepers(1, within: .seconds(5)), "the switch is waiting for its confirmation")
        let during = await rig.controller.status()
        #expect(during.kind == .spacer)
        #expect(during.decidedFor == .automatic)

        await rig.driven { await switching.value }
        #expect(await rig.controller.status().decidedFor == .wideSpacer)

        await rig.controller.tearDown()
        #expect(await rig.controller.status().decidedFor == nil)
    }

    @Test func anEngineThatFellBackStillSaysWhatItWasChosenFor() async {
        // The person chose the switches, which can't be used: the allowlist is in use, and it settled for that choice.
        let log = CallLog()
        let approvals = FakeEngine(.approvals, log: log)
        approvals.setAvailability(.broken("no list"))
        let controller = HidingController(
            engines: [.allowlist: FakeEngine(.allowlist, log: log), .approvals: approvals, .spacer: FakeEngine(.spacer, log: log)],
            clock: FakeClock(), confirm: { _ in .seen }, note: { _ in })
        await controller.choose(method: .systemSettingsSwitches)
        let status = await controller.status()
        #expect(status.kind == .allowlist)
        #expect(status.decidedFor == .systemSettingsSwitches)
    }

    @Test func confirmationTimeoutIsNotAFailure() async {
        let rig = Rig(confirms: false)
        await rig.controller.choose(method: .automatic)
        await rig.controller.apply(plan)

        // Three switches in a row that are never confirmed: the engines are no worse for it.
        await rig.driven { await rig.controller.choose(method: .wideSpacer) }
        await rig.driven { await rig.controller.choose(method: .automatic) }
        await rig.driven { await rig.controller.choose(method: .wideSpacer) }
        #expect(rig.said.count == 3)

        var status = await rig.controller.status()
        #expect(status.lastError == nil, "a confirmation that doesn't come is not an error")
        #expect(status.kind == .spacer)
        // The allowlist wasn't failed out by it: automatic goes back to it.
        await rig.driven { await rig.controller.choose(method: .automatic) }
        status = await rig.controller.status()
        #expect(status.kind == .allowlist)
        #expect(status.reason == "Chosen automatically: macOS's allowlist works.")
        // And the engines took plans all along: three more applies on the current one are as many as were sent.
        await rig.controller.apply(otherPlan)
        #expect(rig.allowlist.applied.last == otherPlan)
        #expect(await rig.controller.status().lastError == nil)
    }

    @Test func noOldEngineMeansNoWait() async {
        let rig = Rig(confirms: false)
        await rig.controller.apply(plan)
        await rig.controller.choose(method: .automatic)
        // The plan was waiting for an engine: it is applied, with nothing to tear down and so nothing to confirm.
        #expect(rig.calls == ["allowlist.apply"])
        #expect(rig.confirmations == 0)
        #expect(rig.clock.sleeperCount == 0)
        #expect(rig.said.isEmpty)
    }

    @Test func aSwitchThatFailsStillTearsDownOldAndShowsEverything() async {
        let rig = Rig()
        await rig.controller.choose(method: .automatic)
        await rig.controller.apply(plan)
        rig.spacer.failNext(1)

        await rig.controller.choose(method: .wideSpacer)

        // The new engine threw, so it was torn down (everything shows) and nothing was waited for; the old one goes too, so that two
        // engines never hold changes at once.
        #expect(rig.calls == ["allowlist.apply", "spacer.apply", "spacer.tearDown", "allowlist.tearDown"])
        let status = await rig.controller.status()
        #expect(status.kind == .spacer)
        #expect(status.lastError == "Wide spacer couldn't hide icons: it was made to fail.")
        // The next plan tries the same engine.
        await rig.controller.apply(otherPlan)
        #expect(rig.spacer.applied.count == 2)
        #expect(await rig.controller.status().lastError == nil)
    }

    @Test func tearDownDuringAConfirmationLetsGoOfTheWait() async {
        let rig = Rig(confirms: false)
        await rig.controller.choose(method: .automatic)
        await rig.controller.apply(plan)
        let started = rig.clock.now()
        let switching = Task { await rig.controller.choose(method: .wideSpacer) }
        #expect(await rig.clock.waitForSleepers(1, within: .seconds(5)), "the switch is waiting for its confirmation")

        let ending = Task { await rig.controller.tearDown() }
        // Once the tear-down has said so (it can't go on until the switch is through), one tick of the clock is all the wait needs to
        // see that it is let go of: it doesn't go on to 2 s.
        var tries = 0
        while !(await rig.controller.isAbandoningConfirmation), tries < 2000 {
            try? await Task.sleep(for: .milliseconds(2))
            tries += 1
        }
        #expect(await rig.controller.isAbandoningConfirmation)
        rig.clock.advance(by: HidingController.confirmationInterval)
        await switching.value
        await ending.value

        #expect(abs(rig.clock.now().timeIntervalSince(started) - 0.25) < 0.001)
        #expect(Set(rig.calls.suffix(2)) == ["allowlist.tearDown", "spacer.tearDown"])
    }

    // MARK: Failing open

    @Test func applyErrorShowsEverything() async {
        let rig = Rig()
        await rig.controller.choose(method: .automatic)
        rig.allowlist.failNext(1)

        await rig.controller.apply(plan)

        #expect(rig.calls == ["allowlist.apply", "allowlist.tearDown"], "the engine that threw is torn down: everything shows")
        var status = await rig.controller.status()
        #expect(status.lastError == "Allowlist couldn't hide icons: it was made to fail.")
        #expect(status.kind == .allowlist, "and it is still the engine in charge")

        // The next plan tries the same engine, and an engine that works again clears the error.
        await rig.controller.apply(otherPlan)
        #expect(rig.calls.suffix(1) == ["allowlist.apply"])
        status = await rig.controller.status()
        #expect(status.lastError == nil)
        #expect(rig.approvals.applied.isEmpty)
    }

    @Test func threeFailuresFallBack() async {
        let rig = Rig()
        await rig.controller.choose(method: .automatic)
        rig.allowlist.failNext(-1)

        await rig.controller.apply(plan)
        await rig.controller.apply(otherPlan)
        #expect(await rig.controller.status().kind == .allowlist, "two in a row is still the allowlist")
        #expect(rig.approvals.applied.isEmpty)
        await rig.controller.apply(plan)

        // The third throw: the allowlist is failed out, the choice is made again, and the next engine takes the plan.
        #expect(rig.said == ["Allowlist failed 3 times; using System Settings switches"])
        let status = await rig.controller.status()
        #expect(status.kind == .approvals)
        #expect(status.reason == "Allowlist can't be used (it failed 3 times in a row; Refresh Menu Bar tries it again), so Mantel uses System Settings switches.")
        #expect(rig.approvals.applied == [plan], "the plan that failed is the one the next engine is given")
        #expect(rig.allowlist.applied.count == 3)
        #expect(status.lastError == nil, "the engine that took over has not failed")

        // Later plans don't go to the allowlist again.
        await rig.controller.apply(otherPlan)
        #expect(rig.allowlist.applied.count == 3)
        #expect(rig.approvals.applied == [plan, otherPlan])
        // And choosing again doesn't bring it back: it is failed out until Refresh.
        await rig.controller.choose(method: .automatic)
        #expect(await rig.controller.status().kind == .approvals)
    }

    @Test func failuresMustBeInARow() async {
        let rig = Rig()
        await rig.controller.choose(method: .automatic)
        func unique(_ number: Int) -> VisibilityPlan {
            EngineFixtures.plan(visible: ["com.example.x\(number)"], concealed: ["com.example.y"])
        }
        // Two throws and then a plan that works, three times over: six throws in all, never three in a row.
        var number = 0
        for _ in 0..<3 {
            rig.allowlist.failNext(2)
            for _ in 0..<3 {
                number += 1
                await rig.controller.apply(unique(number))
            }
        }
        #expect(rig.allowlist.applied.count == 9)
        #expect(await rig.controller.status().kind == .allowlist)
        #expect(rig.said.isEmpty)
        #expect(rig.approvals.applied.isEmpty)
    }

    @Test func unsettledPreferencesAreNotCountedAsFailures() async {
        let rig = Rig()
        await rig.controller.choose(method: .automatic)
        rig.allowlist.failNext(-1, unsettled: true)

        // Six plans that come to nothing because the preferences service lags: everything is shown each time, and the engine stays.
        for number in 0..<6 {
            await rig.controller.apply(EngineFixtures.plan(visible: ["com.example.x\(number)"], concealed: ["com.example.y"]))
        }

        #expect(rig.allowlist.applied.count == 6)
        #expect(rig.allowlist.tornDown == 6, "each time everything was shown")
        #expect(rig.said.isEmpty, "and it never failed out")
        var status = await rig.controller.status()
        #expect(status.kind == .allowlist)
        #expect(status.lastError == "Allowlist couldn't hide icons: it was made to lag.")
        // The next plan that is kept clears the error.
        rig.allowlist.failNext(0)
        await rig.controller.apply(plan)
        status = await rig.controller.status()
        #expect(status.lastError == nil)
        #expect(rig.approvals.applied.isEmpty)

        // A real failure still counts, and the unsettled ones before it were not added to it.
        rig.allowlist.failNext(2)
        await rig.controller.apply(otherPlan)
        await rig.controller.apply(EngineFixtures.plan(visible: ["com.example.z"], concealed: ["com.example.y"]))
        #expect(await rig.controller.status().kind == .allowlist, "two failures in a row are not three")
    }

    @Test func aForcedPlanIsReappliedByTheEngineInCharge() async {
        let rig = Rig()
        await rig.controller.choose(method: .automatic)
        await rig.controller.apply(plan)
        #expect(rig.allowlist.applied.count == 1)

        // The same plan again is nothing, unless it is forced (Refresh): then the engine is told to apply it as if it were new.
        await rig.controller.apply(plan)
        #expect(rig.allowlist.applied.count == 1)
        await rig.controller.apply(plan, force: true)
        #expect(rig.allowlist.applied.count == 2)
        #expect(rig.allowlist.reapplied == 1)
        #expect(await rig.controller.status().lastError == nil)
    }

    @Test func aTornDownControllerIsNotPutBackInChargeByAForcedPlan() async {
        // Refresh asks for plans by force, and a forced plan chooses the engine again. After a teardown only an explicit choice does that: a
        // refresh that was under way when a reset took everything down must not hide again.
        let rig = Rig()
        await rig.controller.choose(method: .automatic)
        await rig.controller.apply(plan)
        await rig.controller.tearDown()
        let calls = rig.calls

        await rig.controller.apply(plan, force: true)
        await rig.controller.apply(otherPlan, force: true)
        #expect(rig.calls == calls, "nothing was applied, and nothing was switched to")

        // An explicit choice puts an engine in charge, with the plan that was given last.
        await rig.controller.choose(method: .automatic)
        #expect(rig.calls.suffix(1) == ["allowlist.apply"])
        #expect(rig.allowlist.applied.last == otherPlan)
        await rig.controller.apply(plan, force: true)
        #expect(rig.allowlist.applied.last == plan, "and a forced plan reaches it again")
    }

    @Test func forceClearsFailedOut() async {
        let rig = Rig()
        await rig.controller.choose(method: .automatic)
        rig.allowlist.failNext(-1)
        for _ in 0..<3 { await rig.controller.apply(plan) }
        #expect(await rig.controller.status().kind == .approvals)

        // The allowlist works again, and Refresh asks for the plan again, forced.
        rig.allowlist.failNext(0)
        await rig.controller.apply(plan, force: true)

        let status = await rig.controller.status()
        #expect(status.kind == .allowlist, "the allowlist isn't failed out any more")
        #expect(status.reason == "Chosen automatically: macOS's allowlist works.")
        #expect(rig.allowlist.applied.count == 4, "and it was given the plan")
        #expect(rig.calls.suffix(3) == ["allowlist.apply", "confirm", "approvals.tearDown"], "by a switch: new, confirmed, old torn down")
        #expect(await rig.controller.status().lastError == nil)
    }

    // MARK: Plans

    @Test func equalPlanIsNotAppliedAgainUnlessForced() async {
        let rig = Rig()
        await rig.controller.choose(method: .automatic)
        await rig.controller.apply(plan)
        await rig.controller.apply(plan)
        #expect(rig.allowlist.applied.count == 1, "an equal plan again is nothing to do")
        await rig.controller.apply(plan, force: true)
        #expect(rig.allowlist.applied.count == 2, "forced, it is applied again")
        await rig.controller.apply(otherPlan)
        #expect(rig.allowlist.applied.count == 3)
        #expect(rig.calls.filter { $0.hasSuffix("tearDown") }.isEmpty, "none of it switched anything")
    }

    @Test func tearDownTearsDownTheEngineInChargeAndStopsApplying() async {
        let rig = Rig()
        await rig.controller.choose(method: .automatic)
        await rig.controller.apply(plan)

        await rig.controller.tearDown()
        #expect(rig.calls == ["allowlist.apply", "allowlist.tearDown"])
        // Nothing is in charge: a plan that comes is kept, and applied when an engine is chosen.
        await rig.controller.apply(otherPlan)
        #expect(rig.allowlist.applied == [plan])
        await rig.controller.choose(method: .automatic)
        #expect(rig.allowlist.applied == [plan, otherPlan])
        // Tearing down with nothing in charge is harmless, and tears nothing down again.
        await rig.controller.tearDown()
        await rig.controller.tearDown()
        await rig.controller.tearDown()
        #expect(rig.allowlist.tornDown == 2, "once for each time it was in charge")
    }

    // MARK: Ending is final

    @Test func aChoiceDecidedOnBeforeATearDownIsNotCarriedOutAfterIt() async {
        // A reset takes the engines down while a choice that was decided on before it is still on its way: it would put an engine back in
        // charge in the middle of the reset.
        let rig = Rig()
        await rig.controller.choose(method: .automatic)
        await rig.controller.apply(plan)
        let before = rig.controller.epoch

        await rig.controller.tearDown()
        #expect(rig.controller.epoch == before + 1)
        await rig.controller.choose(method: .wideSpacer, expectedEpoch: before)
        #expect(rig.calls == ["allowlist.apply", "allowlist.tearDown"], "nothing was chosen")
        #expect(await rig.controller.status().decidedFor == nil, "no method is settled")

        // A choice decided on after it is carried out, as the reset's own is.
        await rig.controller.choose(method: .automatic, expectedEpoch: rig.controller.epoch)
        #expect(rig.calls.last == "allowlist.apply")
        #expect(rig.allowlist.applied == [plan, plan])
    }

    @Test func aChoiceThatWaitsForItsTurnThroughATearDownIsDropped() async {
        // A switch holds the controller (it waits for its confirmation), a choice is asked for behind it, and the engines are taken down
        // before the choice has its turn: it finds the teardown has come, and does nothing, rather than switching back to the engine
        // the switch left.
        let rig = Rig(confirms: false)
        await rig.controller.choose(method: .automatic)
        await rig.controller.apply(plan)
        let switching = Task { await rig.controller.choose(method: .wideSpacer) }
        #expect(await rig.clock.waitForSleepers(1, within: .seconds(5)), "the switch is waiting for its confirmation")
        let waiting = Task { await rig.controller.choose(method: .automatic) }
        try? await Task.sleep(for: .milliseconds(30))

        let ending = Task { await rig.controller.tearDown() }
        var tries = 0
        while !(await rig.controller.isAbandoningConfirmation), tries < 2000 {
            try? await Task.sleep(for: .milliseconds(2))
            tries += 1
        }
        rig.clock.advance(by: HidingController.confirmationInterval)
        // (Driven by the clock, so that a choice that is carried out and waits for a confirmation fails the test and doesn't hang it.)
        await rig.driven {
            await switching.value
            await waiting.value
            await ending.value
        }

        #expect(rig.calls.filter { $0 == "allowlist.apply" }.count == 1, "the engine the switch left wasn't put back in charge")
        #expect(await rig.controller.status().decidedFor == nil, "no method is settled")
    }

    @Test func shutDownIsFinal() async {
        let rig = Rig()
        await rig.controller.choose(method: .automatic)
        await rig.controller.apply(plan)

        await rig.controller.shutDown()
        #expect(rig.calls == ["allowlist.apply", "allowlist.tearDown"])
        // Whatever was asked for before it, or after, finds nothing to do: no engine is chosen and no plan is applied.
        await rig.controller.choose(method: .automatic, expectedEpoch: rig.controller.epoch)
        await rig.controller.choose(method: .wideSpacer)
        await rig.controller.apply(otherPlan)
        await rig.controller.apply(otherPlan, force: true)
        #expect(rig.calls == ["allowlist.apply", "allowlist.tearDown"])
        #expect(await rig.controller.status().decidedFor == nil, "no method is settled")
        // Taking down again is harmless.
        await rig.controller.tearDown()
        #expect(rig.allowlist.tornDown == 1)
    }

    // MARK: Status

    @Test func statusReportsEngineReasonAndDegraded() async {
        let rig = Rig()
        // Nothing chosen yet.
        #expect(await rig.controller.status().reason == "No way of hiding icons has been chosen yet.")

        rig.allowlist.setAvailability(.broken("Mantel has to run from the Applications folder for this"))
        rig.approvals.setAvailability(.needsPermission("Choose the “Allow in the Menu Bar” file in Settings › Permissions"))
        await rig.controller.choose(method: .automatic)

        let status = await rig.controller.status()
        #expect(status.kind == .spacer)
        #expect(status.degraded)
        #expect(status.reason == "Allowlist can't be used (Mantel has to run from the Applications folder for this), so Mantel uses Wide spacer.")
        #expect(status.availability == [
            .allowlist: "broken: Mantel has to run from the Applications folder for this",
            .approvals: "needs permission: Choose the “Allow in the Menu Bar” file in Settings › Permissions",
            .spacer: "available",
        ])
        #expect(status.lastError == nil)

        // The allowlist is not degraded, and what an engine has to say about its plan is added to the reason.
        let working = Rig()
        await working.controller.choose(method: .systemSettingsSwitches)
        working.approvals.setNote("2 apps with icons aren't in macOS's list, so they stay visible.")
        let better = await working.controller.status()
        #expect(better.kind == .approvals)
        #expect(!better.degraded)
        #expect(better.reason == "Chosen in Settings › Advanced. 2 apps with icons aren't in macOS's list, so they stay visible.")
    }

    @Test func chooseAsksEveryEnginesAvailability() async {
        let rig = Rig()
        await rig.controller.choose(method: .automatic)
        #expect(rig.log.all.filter { $0.hasSuffix(".availability") } == ["allowlist.availability", "approvals.availability", "spacer.availability"])
        // An unavailable allowlist is found the next time the choice is made: the switch goes to the next engine.
        await rig.controller.apply(plan)
        rig.allowlist.setAvailability(.broken("gone"))
        await rig.controller.choose(method: .automatic)
        #expect(await rig.controller.status().kind == .approvals)
        #expect(rig.calls.suffix(3) == ["approvals.apply", "confirm", "allowlist.tearDown"])
    }

    @Test func theAllowlistEngineIsReachableWithoutWaiting() {
        let hidden = HiddenApps()
        let engine = AllowlistEngine(allowlist: FakeAllowlist(hidden: hidden, everyApp: { [] }), ownBundleID: EngineFixtures.own, isInstalledCopy: true)
        let controller = HidingController(engines: [.allowlist: engine], clock: FakeClock(), confirm: { _ in .seen })
        #expect(controller.allowlist === engine)
        let without = HidingController(engines: [:], clock: FakeClock(), confirm: { _ in .seen })
        #expect(without.allowlist == nil)
    }

    // MARK: What can't be used

    @Test func statusHoldsTheBareReasonOfEveryEngineThatCantBeUsed() async {
        let rig = Rig()
        rig.approvals.setAvailability(.needsPermission("Choose the file in Settings › Permissions"))
        rig.spacer.setAvailability(.broken("no menu bar is shown"))
        await rig.controller.choose(method: .automatic)

        let status = await rig.controller.status()
        // The sentence is for Diagnostics to show as it is, and the bare reason is for anything that has to say it again.
        #expect(status.availability[.approvals] == "needs permission: Choose the file in Settings › Permissions")
        #expect(status.unavailableReasons == [.approvals: "Choose the file in Settings › Permissions", .spacer: "no menu bar is shown"])
        #expect(status.unavailableReasons[.allowlist] == nil, "an engine that can be used has no reason")
    }

    @Test func choosingAgainWhenTheChoiceIsUnchangedSwitchesNothingButAsksAvailabilityAgain() async {
        let rig = Rig()
        rig.approvals.setAvailability(.needsPermission("Choose the file"))
        await rig.controller.choose(method: .automatic)
        await rig.controller.apply(plan)
        let before = rig.calls
        #expect(await rig.controller.status().unavailableReasons == [.approvals: "Choose the file"])

        // The person chooses the file: availability is asked again, and the engine in charge stays in charge.
        rig.approvals.setAvailability(.available)
        await rig.controller.choose(method: .automatic)

        #expect(rig.calls == before, "no engine was applied to, confirmed, switched to or torn down")
        let status = await rig.controller.status()
        #expect(status.kind == .allowlist)
        #expect(status.unavailableReasons.isEmpty)
        #expect(status.availability[.approvals] == "available")
        #expect(rig.confirmations == 0)
    }

    @Test func nothingIsUnavailableWhenEveryEngineCanBeUsed() async {
        let rig = Rig()
        await rig.controller.choose(method: .automatic)
        #expect(await rig.controller.status().unavailableReasons.isEmpty)
    }

    // MARK: An icon macOS doesn't tie to its app

    @Test func unattachedInputSwitchesThereAndBack() async {
        let rig = Rig()
        await rig.controller.choose(method: .automatic)
        await rig.controller.apply(plan)
        #expect(await rig.controller.status().kind == .allowlist)

        await rig.controller.choose(method: .automatic, unattachedShownApps: ["com.example.a"])
        #expect(rig.calls == ["allowlist.apply", "approvals.apply", "confirm", "allowlist.tearDown"], "new, confirmed, then old")
        let status = await rig.controller.status()
        #expect(status.kind == .approvals)
        #expect(status.reason.hasPrefix("1 app in Shown has an icon macOS can't tie to it"))

        // The same set again changes nothing.
        let before = rig.calls
        await rig.controller.choose(method: .automatic, unattachedShownApps: ["com.example.a"])
        #expect(rig.calls == before)

        await rig.controller.choose(method: .automatic, unattachedShownApps: [])
        #expect(await rig.controller.status().kind == .allowlist)
        #expect(rig.calls.suffix(3) == ["allowlist.apply", "confirm", "approvals.tearDown"])
    }

    @Test func forcedApplyKeepsTheUnattachedInput() async {
        let rig = Rig()
        await rig.controller.choose(method: .automatic, unattachedShownApps: ["com.example.a"])
        await rig.controller.apply(plan)
        #expect(await rig.controller.status().kind == .approvals)

        // A refresh's forced apply chooses again from what was last asked: it stays on the switches.
        await rig.controller.apply(plan, force: true)
        #expect(await rig.controller.status().kind == .approvals)
        #expect(rig.allowlist.applied.isEmpty)
        #expect(rig.approvals.reapplied == 1)
    }
}
