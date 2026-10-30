import CoreGraphics
import Foundation
import MKCore
import MKLayout
import MKTestSupport
import Synchronization
import Testing

@testable import MKMenuBar

private let weather = SessionWorld.weather
private let notes = SessionWorld.notes
private let vpn = SessionWorld.vpn
private let sync = SessionWorld.sync
private let own = SessionWorld.own

/// An engine that takes its time over a plan while a test holds a gate: a switch to it, which applies the plan with it, is under way
/// for as long.
private final class GatedEngine: HidingEngine {
    let kind: HidingEngineKind
    private let gate = Mutex<Gate?>(nil)
    private let entered = Mutex(0)

    init(_ kind: HidingEngineKind) { self.kind = kind }

    /// Plans that are applied from now on wait at the gate (none wait for nil).
    func hold(at gate: Gate?) { self.gate.withLock { $0 = gate } }
    /// How many plans have come to it.
    var applies: Int { entered.withLock { $0 } }

    func availability() async -> EngineAvailability { .available }

    func apply(_ plan: VisibilityPlan) async throws {
        entered.withLock { $0 += 1 }
        if let gate = gate.withLock({ $0 }) { await gate.wait() }
    }

    func tearDown() async {}
}

/// The rules the session keeps that the plan's tests don't reach: what is asked of the engines and the scheduler, and in what order.
@Suite("Menu bar session rules", .serialized, .timeLimit(.minutes(1)))
struct MenuBarSessionRulesTests {
    /// Waits, in real time and for at most five seconds, until the session's newest plan says so.
    private func waitForSubmitted(_ session: MenuBarSession, _ holds: @escaping @Sendable (VisibilityPlan) -> Bool) async -> Bool {
        await withinTimeLimit(.seconds(5)) {
            while true {
                if let plan = await session.lastSubmitted, holds(plan) { return true }
                guard (try? await Task.sleep(for: .milliseconds(1))) != nil else { return false }
            }
        } ?? false
    }

    // MARK: Plans to the engine

    @Test func plansToTheControllerCoalesceLatestWins() async throws {
        let rig = SessionRig.withAllowlist(sections: sections(shown: [weather, notes, vpn, sync]))
        await rig.session.start()
        let allowlist = try #require(rig.allowlist)
        #expect(allowlist.calls.isEmpty, "nothing is concealed, so nothing is held")

        // The allowlist is slow to take the first plan (a preferences service that disagrees costs seconds).
        let gate = Gate()
        allowlist.holdActivations(until: gate)
        defer { gate.open() }
        let first = Task { await rig.session.move(app: weather, to: .hidden) }
        await allowlist.entered.wait()

        // Three more changes come in while it is being applied, one after the other (each plan is made before the next change). Their
        // plans are not queued up behind it: the session keeps the newest only.
        var others: [Task<Void, Never>] = []
        var concealed: Set<String> = [weather]
        for app in [notes, vpn, sync] {
            others.append(Task { await rig.session.move(app: app, to: .hidden) })
            concealed.insert(app)
            let wanted = concealed
            #expect(await waitForSubmitted(rig.session) { $0.concealedBundleIDs == wanted }, "the session asked for the plan that conceals \(wanted.count)")
        }
        gate.open()
        await first.value
        for task in others { await task.value }

        // The one that was being applied, and the newest: nothing in between reached the allowlist.
        try #require(allowlist.calls.count == 2, "the first plan and the newest")
        #expect(allowlist.calls[0].bundleIDs.contains(notes), "the first plan concealed the weather app only")
        #expect(!allowlist.calls[0].bundleIDs.contains(weather))
        #expect(Set(allowlist.calls[1].bundleIDs).isDisjoint(with: [weather, notes, vpn, sync]))
        #expect(rig.world.concealed == [weather, notes, vpn, sync])
    }

    @Test func aCancelledCallerNeverDropsTheNewestPlan() async throws {
        let rig = SessionRig.withAllowlist(sections: sections(shown: [weather, notes, vpn, sync]))
        await rig.session.start()
        let allowlist = try #require(rig.allowlist)
        #expect(allowlist.calls.isEmpty)
        // An activation that is made on a task that is cancelled gives up, as the real one does.
        allowlist.failWhenCancelled(true)
        let gate = Gate()
        allowlist.holdActivations(until: gate)
        defer { gate.open() }

        // A plan is being applied, and the person who asked for it goes away (a cancelled task). A newer plan is made meanwhile.
        let asker = Task { await rig.session.move(app: weather, to: .hidden) }
        #expect(await waitUntil { allowlist.calls.count == 1 }, "the first plan is being applied")
        let other = Task { await rig.session.move(app: notes, to: .hidden) }
        #expect(await waitForSubmitted(rig.session) { $0.concealedBundleIDs == [weather, notes] }, "the newest is kept")
        asker.cancel()
        gate.open()
        await asker.value
        await other.value

        // The engine was never cancelled, and the newest plan is the one that is live.
        #expect(allowlist.live == 1)
        #expect(Set(try #require(allowlist.calls.last).bundleIDs).isDisjoint(with: [weather, notes]))
        #expect(rig.world.concealed == [weather, notes])
        // And the session knows what was applied: asking for the same plan again sends nothing.
        let calls = allowlist.calls.count
        await rig.session.setNewItemsSection(.shown)
        #expect(allowlist.calls.count == calls)
    }

    @Test func aCancelledSettingsCallerStillSwitchesEngines() async throws {
        // The wide spacer is in charge, and the person chooses Automatic: the allowlist takes over, applying the plan before the spacer is
        // taken down. Whoever asked is cancelled while the allowlist is being activated (an activation made on a task that is cancelled
        // gives up, as the real one does), and the switch is carried out all the same: it doesn't run on the caller's task.
        let allowlist = FakeAllowlist(hidden: HiddenApps(), everyApp: { [weather, notes, vpn, sync, own] })
        let spacer = FakeEngine(.spacer, log: CallLog())
        let engines: [HidingEngineKind: any HidingEngine] = [
            .allowlist: AllowlistEngine(allowlist: allowlist, ownBundleID: own, isInstalledCopy: true), .spacer: spacer,
        ]
        var settings = HidingSettings()
        settings.method = .wideSpacer
        let rig = SessionRig.withEngines(engines, sections: sections(shown: [notes, vpn, sync], hidden: [weather]), settings: settings)
        await rig.session.start()
        #expect(await rig.session.engineStatus().kind == .spacer)
        #expect(allowlist.calls.isEmpty && allowlist.live == 0)

        allowlist.failWhenCancelled(true)
        let gate = Gate()
        allowlist.holdActivations(until: gate)
        defer { gate.open() }
        settings.method = .automatic
        let asker = Task { await rig.session.setSettings(settings) }
        await allowlist.entered.wait()
        asker.cancel()
        gate.open()
        await asker.value

        // The allowlist is live with the plan, and it is the one in charge; the spacer was taken down after it.
        #expect(allowlist.live == 1, "the activation wasn't cut short")
        #expect(try #require(allowlist.calls.last).bundleIDs.contains(weather) == false)
        #expect(await rig.session.engineStatus().kind == .allowlist)
        #expect(await rig.session.engineStatus().lastError == nil)
        #expect(spacer.tornDown >= 1)
    }

    @Test func aPlanThatAnEngineFailedToApplyIsSentAgainEvenIfItIsTheSame() async throws {
        let log = CallLog()
        let engine = FakeEngine(.allowlist, log: log)
        engine.failNext(2)
        let rig = SessionRig.withEngines([.allowlist: engine], sections: sections(hidden: [weather]), events: log)
        await rig.session.start()
        // The plan went to the engine twice and failed twice: at the first read, and again at the second, which made the same plan.
        #expect(engine.applied.count == 2)
        #expect(Set(engine.applied.map(\.concealedBundleIDs)) == [[weather]], "the same plan both times")
        #expect(try #require(await rig.state).engine.lastError != nil)

        // Asking for what is so already (no change at all) makes the same plan, and it is sent: the engine takes it now.
        await rig.session.setNewItemsSection(.shown)
        #expect(engine.applied.count == 3)
        #expect(try #require(await rig.state).engine.lastError == nil)
        // Once it has taken it, an equal plan isn't sent again.
        await rig.session.setNewItemsSection(.shown)
        #expect(engine.applied.count == 3)
        // A refresh sends it whatever it is.
        await rig.session.refresh()
        #expect(engine.applied.count == 4)
    }

    @Test func aReadTakenInTheMiddleOfASwitchOfEngineIsNotJudged() async throws {
        // The bar has room for five icons, the weather app's and the notes app's are piled, and no automatic move has been made (the bar
        // had room for them when it was read). The person chooses the wide spacer, which takes its time over the plan. The read that
        // comes in the middle of the switch shows a bar in transition: nothing is moved for it. A read after it does.
        let log = CallLog()
        let gated = GatedEngine(.spacer)
        let rig = SessionRig.withEngines([.allowlist: FakeEngine(.allowlist, log: log), .spacer: gated], shape: .laptop, capacity: nil,
                                         events: log)
        await rig.session.start()
        rig.world.setCapacity(5)
        let kept = AppPlacement(section: .shown, isAuto: false)
        #expect(await rig.session.sections.apps[weather] == kept)

        let gate = Gate()
        gated.hold(at: gate)
        defer { gate.open() }
        var settings = HidingSettings()
        settings.method = .wideSpacer
        let switching = Task { await rig.session.setSettings(settings) }
        #expect(await waitUntil { gated.applies == 1 }, "the switch is under way, applying the plan with the new engine")

        #expect(await rig.clock.waitForSleepers(2, within: .seconds(5)))
        rig.clock.advance(by: .seconds(10))
        #expect(await rig.letTheCoalescedReadGo())
        #expect(await rig.waitForReads(SessionRig.readsAtStart + 1), "the read was taken and taken in")
        #expect(await rig.session.sections.apps[weather] == kept, "but not judged: the bar was changing")

        gated.hold(at: nil)
        gate.open()
        await switching.value
        // The next read is of the bar as it is, and the weather app is moved.
        #expect(await rig.clock.waitForSleepers(2, within: .seconds(5)))
        rig.clock.advance(by: .seconds(10))
        #expect(await rig.letTheCoalescedReadGo())
        #expect(await rig.waitForReads(SessionRig.readsAtStart + 2))
        #expect(await rig.session.sections.apps[weather] == AppPlacement(section: .hidden, isAuto: true))
    }

    // MARK: Reads

    @Test func aReadThatSaysNothingStillHidesWhatTheSectionsSay() async throws {
        // Accessibility isn't granted: the read finds no bar. Nothing is made up of it, and the sections are applied all the same.
        let trusted = Switch(false)
        let rig = SessionRig.withAllowlist(sections: sections(hidden: [weather]), trusted: trusted)
        await rig.session.start()
        let allowlist = try #require(rig.allowlist)
        #expect(allowlist.calls.count == 1)
        #expect(rig.world.concealed == [weather])
        let state = try #require(await rig.state)
        #expect(state.inventory.problems == [.accessibilityNotGranted])
        #expect(state.sections.apps.keys.sorted() == [weather], "no app was placed from a read that found none")
        #expect(state.plan.concealedBundleIDs == [weather])
    }

    @Test func aReadAfterAFailedApplyIsNotJudged() async throws {
        // The laptop's bar has room for five icons and the engine hides nothing here, so the weather app's and the notes app's icons are
        // piled at the « in every read. When the engine has failed to apply the plan, the bar is fully shown and the pile says nothing of
        // whether they fit once the plan is applied: the apps are not moved to Hidden for it.
        let failing = FakeEngine(.allowlist, log: CallLog())
        failing.failNext(2)
        let rig = SessionRig.withEngines([.allowlist: failing], shape: .laptop, capacity: 5, sections: sections(hidden: [vpn]))
        await rig.session.start()
        #expect(try #require(await rig.state).engine.lastError != nil, "the engine failed at both plans")
        // Both reads placed the apps where new ones go (nothing was judged), and neither was moved by itself.
        let kept = AppPlacement(section: .shown, isAuto: false)
        #expect(await rig.session.sections.apps[weather] == kept)
        #expect(await rig.session.sections.apps[notes] == kept)
        #expect(rig.saved.all.allSatisfy { $0.apps[weather]?.isAuto != true && $0.apps[notes]?.isAuto != true })

        // The engine takes the plan now: the next read is of the bar as the plan leaves it, and is judged as the others are.
        await rig.session.setNewItemsSection(.shown)
        #expect(try #require(await rig.state).engine.lastError == nil)
        await rig.session.refresh()
        #expect(await rig.session.sections.apps[weather] == AppPlacement(section: .hidden, isAuto: true))
        #expect(await rig.session.sections.apps[notes] == AppPlacement(section: .hidden, isAuto: true))
    }

    // MARK: Trials of the apps that were moved out

    /// The laptop's full bar, with room for five icons: the weather app and the notes app are moved to Hidden by themselves at the first
    /// read.
    private func movedOutRig() async -> SessionRig {
        let rig = SessionRig.withAllowlist(shape: .laptop, capacity: 5)
        await rig.session.start()
        return rig
    }

    @Test func aReadTakenBeforeTheTrialsPlanWasAppliedIsNotItsVerdict() async throws {
        let rig = await movedOutRig()
        let allowlist = try #require(rig.allowlist)
        let moved = AppPlacement(section: .hidden, isAuto: true)
        #expect(await rig.session.sections.apps[weather] == moved)
        #expect(allowlist.live == 1)

        // A read of the bar begins and is held up: it is taken now, with the apps still concealed.
        let gate = Gate()
        rig.extras.holdReads(at: gate)
        defer { gate.open() }
        #expect(await rig.clock.waitForSleepers(2, within: .seconds(5)))
        rig.clock.advance(by: .seconds(10))
        #expect(await rig.letTheCoalescedReadGo())
        let extras = rig.extras
        #expect(await waitUntil { extras.readsHeld > 0 }, "the read is under way")

        // Time goes by, the front app changes, and the apps are put on trial: their plan is applied.
        rig.clock.advance(by: .seconds(1))
        await rig.session.frontAppChanged(pid: 4321, activeScreenWidth: 1728)
        let trial = AppPlacement(section: .shown, isAuto: true)
        #expect(await rig.session.sections.apps[weather] == trial)
        #expect(allowlist.live == 0, "they are shown")

        // The read that was held up is over. It was taken before the plan was applied, so it says nothing of how the trial went: the
        // apps are still on trial, and haven't been taken to fit or to overflow. (The read that judges the trial follows it at once, and
        // is held up in its turn, so that this can be looked at in between.)
        let held = extras.readsHeld
        let second = Gate()
        rig.extras.holdReads(at: second)
        defer { second.open() }
        gate.open()
        #expect(await rig.waitForReads(SessionRig.readsAtStart + 1))
        #expect(await waitUntil { extras.readsHeld > held }, "the read that judges the trial has begun")
        #expect(await rig.session.sections.apps[weather] == trial)
        #expect(await rig.session.sections.apps[notes] == trial)

        // The read that was asked for after the plan was applied is the one that judges: the bar has room for five and there are eight
        // icons now, so the apps are piled again, and go back to Hidden.
        rig.extras.holdReads(at: nil)
        second.open()
        #expect(await rig.waitForReads(SessionRig.readsAtStart + 2))
        #expect(await rig.session.sections.apps[weather] == moved)
        #expect(await rig.session.sections.apps[notes] == moved)
        #expect(allowlist.live == 1)
    }

    @Test func aReadTakenDuringARevealIsNotJudgedAfterTheCollapse() async throws {
        // A read of the bar begins while the sync app is revealed, which pushes the weather app's icons out of the bar. The person
        // collapses before it is over. It shows the bar as the reveal left it, not as the sections do: the weather app is not moved to
        // Hidden for it.
        var settings = HidingSettings()
        settings.noRoomPolicy = .secondBar
        let rig = SessionRig.withAllowlist(shape: .laptop, capacity: nil,
                                           sections: sections(shown: [weather, notes, vpn], hidden: [sync]), settings: settings)
        await rig.session.start()
        rig.world.setCapacity(6)
        #expect(await rig.session.setReveal(.hiddenShown) == .none)

        let gate = Gate()
        rig.extras.holdReads(at: gate)
        defer { gate.open() }
        #expect(await rig.clock.waitForSleepers(2, within: .seconds(5)))
        rig.clock.advance(by: .seconds(10))
        #expect(await rig.letTheCoalescedReadGo())
        let extras = rig.extras
        #expect(await waitUntil { extras.readsHeld > 0 }, "the read is under way, with the sync app revealed")

        rig.clock.advance(by: .seconds(1))
        #expect(await rig.session.setReveal(.collapsed) == .none)
        rig.extras.holdReads(at: nil)
        gate.open()
        #expect(await rig.waitForReads(SessionRig.readsAtStart + 2), "the read is over (those of the start, and the reveal's, came before it)")
        let kept = AppPlacement(section: .shown, isAuto: false)
        #expect(await rig.session.sections.apps[weather] == kept)
        #expect(await rig.session.sections.apps[notes] == kept)
    }

    // MARK: Reveals that are overtaken

    @Test func aRevealThatIsOvertakenStops() async throws {
        // The first reveal is looking for an app that never shows, asleep on the clock. A second one, a collapse, comes in: the first
        // returns at once with nothing left to do, and doesn't go on to read the bar for a reveal that is over.
        let engine = FakeEngine(.allowlist, log: CallLog())
        let rig = SessionRig.withEngines([.allowlist: engine], sections: sections(hidden: [weather]))
        rig.world.setHiddenProvider { [weather] }
        await rig.session.start()
        let reads = await rig.session.scansIngested

        let answer = Mutex<NoRoomAction?>(nil)
        let reveal = Task {
            let result = await rig.session.setReveal(.hiddenShown)
            answer.withLock { $0 = result }
        }
        // It is looking: asleep on the clock for the next look.
        #expect(await rig.clock.waitForSleepers(3, within: .seconds(5)))
        #expect(await rig.session.setReveal(.collapsed) == .none)
        rig.clock.advance(by: MenuBarSession.confirmationInterval)
        #expect(await waitUntil { answer.withLock { $0 } != nil }, "the first call returned")
        reveal.cancel()
        #expect(answer.withLock { $0 } == NoRoomAction.none)
        #expect(await rig.session.scansIngested == reads, "no read of the bar was taken for the reveal that was over")
        #expect(try #require(await rig.state).plan.source == .sections)
    }
}
