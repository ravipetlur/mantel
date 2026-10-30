import CoreGraphics
import Foundation
import MKCommands
import MKCore
import MKLayout
import MKTestSupport
import Synchronization
import Testing

@testable import MKMenuBar

private let notes = SessionWorld.notes
private let vpn = SessionWorld.vpn
private let sync = SessionWorld.sync
private let weather = SessionWorld.weather
private let own = SessionWorld.own

/// Why the menu bar can't be restarted now (a platform test is changing it), and when that is asked.
private final class Refusal: Sendable {
    private struct State {
        var reason: String?
        var gate: Gate?
        var asked = 0
    }

    private let state = Mutex(State())

    func set(_ reason: String?) { state.withLock { $0.reason = reason } }
    /// The question waits at the gate from now on (not for nil).
    func hold(at gate: Gate?) { state.withLock { $0.gate = gate } }
    var asked: Int { state.withLock { $0.asked } }

    func answer() async -> String? {
        let gate = state.withLock { state -> Gate? in
            state.asked += 1
            return state.gate
        }
        await gate?.wait()
        return state.withLock { $0.reason }
    }
}

/// Whether a restart of the menu bar puts the world right (the apps that had no slot have one again).
private final class Cure: Sendable {
    private let works = Mutex(true)
    var isWorking: Bool { works.withLock { $0 } }
    func set(_ works: Bool) { self.works.withLock { $0 = works } }
}

/// A menu bar that a lid cycle left stuck: apps that were drawn under the allowlist have no slot, with room on the bar, from the first
/// read after a change of displays, and a restart of MenuBarAgent (the fake restarter) puts them back.
@Suite("Menu bar session: a bar a change of displays left stuck", .timeLimit(.minutes(2)))
struct MenuBarSessionStuckBarTests {
    private struct World {
        let rig: SessionRig
        let restarter: FakeRestarter
        let refusal: Refusal
        let cure: Cure
        let activity: ResetActivity
        let log: CallLog
        var reads = SessionRig.readsAtStart

        var state: MenuBarState? { get async { await rig.state } }
        var flagged: Set<String> { get async { await rig.state?.unattachedApps ?? [] } }
        var notRecovered: Bool { get async { await rig.state?.stuckBarNotRecovered ?? false } }
    }

    private func started(recovery: Bool = true, unattached: Set<String> = [], turnedOff: TurnedOffList = .apps([]),
                         shape: SessionWorld.Shape = .desk, undrawn: Bool = false, automaticOverflow: Bool = true) async -> World {
        let log = CallLog()
        let approvals = FakeEngine(.approvals, log: log)
        approvals.setAvailability(.broken("not set up"))
        var settings = HidingSettings()
        settings.automaticOverflow = automaticOverflow
        let rig = SessionRig.withAllowlist(shape: shape, undrawn: undrawn, sections: sections(shown: [notes, vpn, sync], hidden: [weather]),
                                           settings: settings, otherEngines: [.approvals: approvals])
        rig.world.setUnattached(unattached)
        rig.turnedOff.set(turnedOff)
        let restarter = FakeRestarter(log: log)
        let cure = Cure()
        let world = rig.world
        restarter.whileRestarting { if cure.isWorking { world.setUnattached([]) } }
        let refusal = Refusal()
        let activity = ResetActivity()
        if recovery {
            await rig.session.setStuckBarRecovery(StuckBarRecovery(restarter: restarter, refusal: { await refusal.answer() },
                                                                   activity: activity))
        }
        await rig.session.start()
        return World(rig: rig, restarter: restarter, refusal: refusal, cure: cure, activity: activity, log: log)
    }

    /// Lets the polling (every 10 seconds) have `count` more reads, and waits for each.
    private func poll(_ world: inout World, _ count: Int = 1) async -> Bool {
        for _ in 0..<count {
            world.reads += 1
            guard await world.rig.clock.waitForSleepers(2, within: .seconds(5)) else { return false }
            world.rig.clock.advance(by: .seconds(10))
            guard await world.rig.pumpUntilReads(world.reads) else { return false }
        }
        return true
    }

    /// Drives the clock the reads wait on until a recovery that was decided is over, whether it restarted or not (nothing is waited for
    /// if none was). False when it isn't over within ten seconds.
    private func finishRecovery(_ world: inout World) async -> Bool {
        let rig = world.rig
        let session = rig.session
        let over = await withinTimeLimit(.seconds(10)) {
            while await session.recoveryUnderWay {
                if await rig.clock.waitForSleepers(3, within: .milliseconds(20)) { rig.clock.advance(by: SessionRig.flush) }
            }
            return true
        }
        world.reads = await session.scansIngested
        return over ?? false
    }

    /// Lets the polling go until the restarter has been asked `count` times, up to `polls` reads. A recovery is decided by the read, on a
    /// task of its own, and is waited for before the next.
    private func pollUntilRestarted(_ world: inout World, _ count: Int = 1, polls: Int = 4) async -> Bool {
        for _ in 0..<polls where world.restarter.restarts < count {
            guard await poll(&world) else { return false }
            guard await finishRecovery(&world) else { return false }
        }
        return world.restarter.restarts == count
    }

    /// The apps are drawn in the reads of the allowlist (the allowlist ties them), and then the displays change; from then on `missing`
    /// have no slot.
    private func lidCycle(_ world: inout World, missing: Set<String>) async -> Bool {
        guard await poll(&world, 2) else { return false }
        await changeDisplays(&world)
        world.rig.world.setUnattached(missing)
        return true
    }

    /// The apps the session would blame a stuck bar on right now (`UnattachedIconTracker.stuckBarSuspects`).
    private func suspects(_ world: World) async -> Set<String> {
        Set(await world.rig.session.unattached.stuckBarSuspects.keys)
    }

    private func changeDisplays(_ world: inout World) async {
        let rig = world.rig
        let changed = Task { await rig.session.displaysChanged(rig.world.layout) }
        _ = await rig.letTheCoalescedReadGo()
        await changed.value
        world.reads = await rig.session.scansIngested
    }

    // MARK: Recovering

    @Test(arguments: [[vpn, sync], [notes, vpn, sync]]) func aStuckBarAfterADisplayChangeIsRestartedOnceAndTheFlagsAreForgotten(missing: [String]) async throws {
        var world = await started()
        let rig = world.rig
        #expect(await lidCycle(&world, missing: Set(missing)))

        // The first look is of a run, and the second, 10 seconds on, restarts.
        #expect(await poll(&world))
        #expect(world.restarter.restarts == 0)
        let before = world
        let lines = await LogCapture.lines {
            var inside = before
            #expect(await self.pollUntilRestarted(&inside))
        }
        world.reads = await rig.session.scansIngested
        #expect(world.restarter.restarts == 1)
        // Once: the watch says so once (`StuckBarWatchTests`), and the restarter was asked once. Other tests log the same line meanwhile.
        #expect(lines.contains { line in
            line.contains("is stuck after a change of displays") && missing.allSatisfy { line.contains($0) } && line.contains("seconds on")
        }, "logged with the apps and how long after the change")

        // The tracker forgot what it knew, and the bar isn't judged stuck any more.
        #expect(await rig.session.unattached.tiedBeforeAChange.isEmpty)
        #expect(await poll(&world, 4))
        #expect(world.restarter.restarts == 1, "not again for the same change")
        #expect(await !world.notRecovered)
        #expect(await world.flagged.isEmpty)

        // B1's hold on new flags lifted (the stuck read of two missing apps had set it): an icon that is never tied is flagged again.
        rig.world.setUnattached([notes])
        for _ in 0..<5 where await world.flagged.isEmpty { _ = await poll(&world) }
        #expect(await world.flagged == [notes])
        #expect(world.restarter.restarts == 1)
    }

    @Test func aWakeCountsAsAChange() async throws {
        var world = await started()
        #expect(await poll(&world, 2))
        await world.rig.session.sessionChanged(.systemWoke)
        world.rig.world.setUnattached([vpn, sync])
        #expect(await poll(&world))
        #expect(world.restarter.restarts == 0)
        #expect(await pollUntilRestarted(&world))
    }

    @Test func aDotWithNoSlotAndRoomAfterAChangeIsRestarted() async throws {
        var world = await started()
        #expect(await lidCycle(&world, missing: [own]))
        #expect(await poll(&world))
        #expect(world.restarter.restarts == 0)
        #expect(await pollUntilRestarted(&world))
    }

    // MARK: Not recovering

    @Test func aBarThatIsntStuckIsNeverRestarted() async throws {
        // An app that never had a slot is B1's case, with a change of displays or none, and with a slot but no change.
        var never = await started(unattached: [vpn])
        #expect(await poll(&never, 2))
        await changeDisplays(&never)
        #expect(await poll(&never, 6))
        #expect(never.restarter.restarts == 0)
        #expect(await never.flagged == [vpn], "B1's flag instead")

        var noChange = await started(unattached: [vpn])
        #expect(await poll(&noChange, 8))
        #expect(noChange.restarter.restarts == 0)

        var hadASlot = await started()
        #expect(await poll(&hadASlot, 2))
        hadASlot.rig.world.setUnattached([vpn])
        #expect(await poll(&hadASlot, 8))
        #expect(hadASlot.restarter.restarts == 0, "no change of displays, no stuck bar")
        #expect(await hadASlot.flagged == [vpn])
    }

    @Test func aPatternThatClearsByItselfIsNotRestarted() async throws {
        var world = await started()
        #expect(await lidCycle(&world, missing: [vpn, sync]))
        // Seen on one read, gone on the next, and again: never on two in a row.
        for _ in 0..<3 {
            world.rig.world.setUnattached([vpn, sync])
            #expect(await poll(&world))
            world.rig.world.setUnattached([])
            #expect(await poll(&world))
        }
        #expect(world.restarter.restarts == 0)
        #expect(await world.flagged.isEmpty)
    }

    @Test func aSessionWithNothingToRestartWithRestartsNothing() async throws {
        var world = await started(recovery: false)
        #expect(await lidCycle(&world, missing: [vpn, sync]))
        #expect(await poll(&world, 6))
        #expect(world.restarter.restarts == 0)
    }

    // MARK: One app alone

    @Test(arguments: [Change.displays, .wake, .unlock]) func aSingleAppWithNoSlotAndTheDotsDrawnIsNeverRestartedByItself(_ kind: Change) async throws {
        // It may be an app switched off in System Settings, or one that hides its own icon, with nothing in the read to say so: the
        // person's Reset covers it, as it did before the restart existed. Not decided at all, and nothing is said of it in Diagnostics.
        var world = await started()
        #expect(await poll(&world, 2))
        await change(kind, &world)
        world.rig.world.setUnattached([vpn])
        #expect(await poll(&world, 8))
        #expect(await finishRecovery(&world))
        #expect(world.restarter.restarts == 0, "\(kind.rawValue)")
        #expect(await world.rig.session.stuckRecoveriesDecided == 0)
        #expect(await !world.notRecovered)
    }

    // MARK: An app that lost its slot for a reason of its own

    @Test(arguments: [Change.wake, .unlock]) func anAppFlaggedByTheOtherCheckAfterItHadASlotIsNoReasonAtTheNextChange(_ kind: Change) async throws {
        // The list of the apps that are off is known and names none, so nothing says why the app has no slot but that macOS doesn't tie it.
        // It had a slot at the start and is missing in every read since B1 flagged it, so it isn't one the last read before the change
        // placed. (That a flagged app is no suspect in itself, whatever the reads say, is pinned in `UnattachedIconTrackerTests`: here it
        // is a second guard.)
        var world = await started()
        #expect(await poll(&world, 2))
        world.rig.world.setUnattached([vpn])
        for _ in 0..<5 where await world.flagged.isEmpty { _ = await poll(&world) }
        #expect(await world.flagged == [vpn])
        #expect(await poll(&world))

        await change(kind, &world)
        #expect(await suspects(world).isDisjoint(with: [vpn]))
        #expect(await poll(&world, 6))
        #expect(await finishRecovery(&world))
        #expect(world.restarter.restarts == 0, "\(kind.rawValue)")
        #expect(await world.flagged == [vpn])
        #expect(await world.rig.session.stuckRecoveriesDecided == 0, "not even decided")
    }

    @Test(arguments: [Change.wake, .unlock, .displays], [TurnedOffList.apps([]), .unavailable("Mantel can't read this list on this Mac.")])
    func appsSwitchedOffTogetherAreNoReasonAtTheNextChange(_ kind: Change, _ list: TurnedOffList) async throws {
        // Two at once: the read of the bar says the bar is stuck, nothing is flagged, and the list of the apps that are off is as it was
        // (empty, or not readable). They are no suspects of the change: the last read before it had no slot for them. Two apps are the
        // shape that would be restarted, so this is pinned by who the suspects are, not by the count.
        var world = await started(turnedOff: list)
        #expect(await poll(&world, 2))
        world.rig.world.setUnattached([vpn, sync])
        #expect(await poll(&world, 3))
        #expect(await world.flagged.isEmpty)

        await change(kind, &world)
        #expect(await suspects(world).isDisjoint(with: [vpn, sync]))
        #expect(await poll(&world, 6))
        #expect(await finishRecovery(&world))
        #expect(world.restarter.restarts == 0, "\(kind.rawValue)")
        #expect(await world.rig.session.stuckRecoveriesDecided == 0, "not even decided")
    }

    @Test(arguments: [Change.wake, .unlock]) func anAppSwitchedOffWhileTheListCantBeReadIsNoReasonAtTheNextChange(_ kind: Change) async throws {
        // One app, so nothing flagged is needed to keep it out: it isn't a suspect, and B1 hasn't flagged it before the change.
        var world = await started(turnedOff: .unavailable("Mantel can't read this list on this Mac."))
        #expect(await poll(&world, 2))
        world.rig.world.setUnattached([vpn])
        #expect(await poll(&world, 1))
        #expect(await world.flagged.isEmpty, "B1 hasn't flagged it yet")

        await change(kind, &world)
        #expect(await suspects(world).isDisjoint(with: [vpn]))
        #expect(await poll(&world, 6))
        #expect(await finishRecovery(&world))
        #expect(world.restarter.restarts == 0)
        #expect(await world.rig.session.stuckRecoveriesDecided == 0)
    }

    @Test func appsThatHadNoSlotOfTheirOwnWhenTheChangeCameAreNoReasonAfterIt() async throws {
        // The route of an app switched off whose neighbour of its width slid into its slot: its frame is in the neighbour's, both are
        // contested, and neither has a slot of its own that a read can find. Then the displays change and the frames are nowhere: both
        // have no slot, with room. The last read before the change placed neither (a contested frame says nothing), so the change took
        // nothing from them, though both had a slot at the start.
        var world = await started()
        let rig = world.rig
        #expect(await poll(&world, 2))
        rig.world.setFrameShifts([sync: -44])
        #expect(await poll(&world, 3))
        #expect(await rig.session.inventory.contestedApps.isSuperset(of: [vpn, sync]), "the frames are each other's")
        #expect(await rig.session.unattached.flagged.isEmpty)

        rig.world.setFrameShifts([:])
        rig.world.setUnattached([vpn, sync])
        await changeDisplays(&world)
        #expect(await suspects(world).isDisjoint(with: [vpn, sync]))
        #expect(await poll(&world, 6))
        #expect(await finishRecovery(&world))
        #expect(world.restarter.restarts == 0)
        #expect(await rig.session.stuckRecoveriesDecided == 0)
    }

    @Test func twoAppsSwitchedOffAfterAChangeAreNoReasonAtTheNextOne() async throws {
        // The bar is already called stuck by B1's check (two apps are off), so no evidence comes: what was true of the apps at the first
        // change must not carry to the next. Notes is switched off with sync after the first change; vpn is placed in every read.
        var world = await started()
        let rig = world.rig
        #expect(await poll(&world, 2))
        await world.rig.session.sessionChanged(.systemWoke)
        #expect(await poll(&world, 2))
        rig.world.setUnattached([notes, sync])
        #expect(await poll(&world, 3))
        #expect(await rig.session.unattached.stuckBarSuspects.isEmpty, "the first change's suspects were placed since, and aren't any more")
        #expect(await finishRecovery(&world))
        #expect(world.restarter.restarts == 0, "a change long ago, and apps that were switched off since")
        #expect(await rig.session.stuckRecoveriesDecided == 0)

        await world.rig.session.sessionChanged(.systemWoke)
        #expect(await poll(&world, 6))
        #expect(await finishRecovery(&world))
        #expect(world.restarter.restarts == 0)
        #expect(await rig.session.stuckRecoveriesDecided == 0)
    }

    @Test func aSwitchThatTheListDoesntShowYetIsLookedForBeforeTheRestart() async throws {
        // The apps had a slot just before the change, were switched off with it, and the list was read before the switch: nothing
        // re-reads it until the recovery does.
        var world = await started()
        #expect(await poll(&world, 2))
        await changeDisplays(&world)
        world.rig.world.setUnattached([vpn, sync])
        world.rig.turnedOff.set(.apps([vpn, sync]))
        let asked = world.rig.turnedOff.timesAsked

        #expect(await poll(&world))
        #expect(world.rig.turnedOff.timesAsked == asked, "nothing has read the list since")
        #expect(await poll(&world, 3))
        #expect(await finishRecovery(&world))
        #expect(await world.rig.session.stuckRecoveriesDecided == 1, "the pattern was found, twice")
        #expect(world.rig.turnedOff.timesAsked > asked, "and the list was read again before the restart")
        #expect(world.restarter.restarts == 0)
        #expect(await poll(&world, 4))
        #expect(await finishRecovery(&world))
        #expect(world.restarter.restarts == 0, "the apps are off, and nothing is missing from the bar that should be there")
        #expect(await world.rig.session.stuckRecoveriesDecided == 1, "not decided again")
    }

    @Test func aRefusalHoldsWhenTheListThatItRestedOnCantBeReadAgain() async throws {
        // The recovery read the list, found both apps off, and didn't restart. Then the list can't be read (Settings opens, say): the
        // apps are no longer known to be off, and the looks have them with no slot again. Only the refusal keeps the decision from being
        // made again, and the restart from going ahead, before the next change.
        var world = await started()
        #expect(await poll(&world, 2))
        await changeDisplays(&world)
        world.rig.world.setUnattached([vpn, sync])
        world.rig.turnedOff.set(.apps([vpn, sync]))
        #expect(await poll(&world, 3))
        #expect(await finishRecovery(&world))
        #expect(await world.rig.session.stuckRecoveriesDecided == 1, "decided, and refused")
        #expect(world.restarter.restarts == 0)

        world.rig.turnedOff.set(.unavailable("Mantel can't read this list on this Mac."))
        await world.rig.session.permissionsChanged()
        world.reads = await world.rig.session.scansIngested
        #expect(await poll(&world, 6))
        #expect(await finishRecovery(&world))
        #expect(await world.rig.session.stuckRecoveriesDecided == 1, "not decided again")
        #expect(world.restarter.restarts == 0)
    }

    @Test func aListThatNamesOneOfTwoLeavesTooFewAndIsNotDecidedAgainBeforeTheNextChange() async throws {
        var world = await started()
        #expect(await poll(&world, 2))
        await changeDisplays(&world)
        world.rig.world.setUnattached([vpn, sync])
        world.rig.turnedOff.set(.apps([vpn]))
        let before = world
        let lines = await LogCapture.lines {
            var inside = before
            _ = await self.poll(&inside, 4)
            _ = await self.finishRecovery(&inside)
        }
        world.reads = await world.rig.session.scansIngested
        #expect(world.restarter.restarts == 0, "one app is left, and one alone isn't restarted")
        #expect(await world.rig.session.stuckRecoveriesDecided == 1)
        #expect(lines.contains { $0.contains("only one app is left") && $0.contains(sync) })

        // It stays so: sync is still missing with room on every later look, and nothing is asked again.
        let asked = world.rig.turnedOff.timesAsked
        #expect(await poll(&world, 6))
        #expect(await finishRecovery(&world))
        #expect(await world.rig.session.stuckRecoveriesDecided == 1)
        #expect(world.rig.turnedOff.timesAsked == asked)
        #expect(world.restarter.restarts == 0)
    }

    @Test func aMantelKnownToBeSwitchedOffIsNotEvenDecided() async throws {
        // The list is read and names Mantel before the change: its items are listed and never drawn, and are no finding at all. Nothing
        // is decided, so no question is asked and no reset is held off, however long it stays so.
        var world = await started(turnedOff: .apps([own]))
        #expect(await lidCycle(&world, missing: [own]))
        let asked = world.rig.turnedOff.timesAsked
        #expect(await poll(&world, 8))
        #expect(await finishRecovery(&world))
        #expect(await world.rig.session.stuckRecoveriesDecided == 0, "nothing is decided, so nothing is said or asked")
        #expect(world.refusal.asked == 0, "no recovery was begun, so no reset was held off for one")
        #expect(world.rig.turnedOff.timesAsked == asked)
        #expect(world.restarter.restarts == 0)
    }

    @Test func aMantelThatTheListDoesntShowSwitchedOffYetIsDecidedOnceAndNotAgain() async throws {
        // The list was read before the switch: the recovery reads it again, finds Mantel off and doesn't restart; and nothing is
        // decided again, whatever the looks say, until the next change.
        var world = await started()
        #expect(await lidCycle(&world, missing: [own]))
        world.rig.turnedOff.set(.apps([own]))
        #expect(await poll(&world, 3))
        #expect(await finishRecovery(&world))
        #expect(await world.rig.session.stuckRecoveriesDecided == 1)
        #expect(world.restarter.restarts == 0)
        #expect(await poll(&world, 6))
        #expect(await finishRecovery(&world))
        #expect(await world.rig.session.stuckRecoveriesDecided == 1)
        #expect(world.restarter.restarts == 0)
    }

    @Test func anAppThatStillHasNoSlotWhenTheListIsReadAgainIsRestarted() async throws {
        // The list is read again, and names another app: what is missing is still a reason.
        var world = await started()
        #expect(await lidCycle(&world, missing: [vpn, sync]))
        world.rig.turnedOff.set(.apps([notes]))
        #expect(await poll(&world))
        #expect(await pollUntilRestarted(&world))
    }

    // MARK: The measured shape

    @Test func theLidOpenedAndClosedWithTheAppsBehindTheNotchInBetweenIsRestartedOnce() async throws {
        // What macOS 27 did: the apps were drawn; the lid opened (the notched bar is the main one: the apps are behind the notch, out of
        // the way); the lid closed, and the bar kept the notched bar's layout: they have no slot, with room. Two changes, and the
        // apps were placed, not missing, in the last read before the second.
        // Automatic overflow would move the apps to Hidden for room, and an app in Hidden is none of this: it is off here.
        var world = await started(shape: .laptop, undrawn: true, automaticOverflow: false)
        let rig = world.rig
        #expect(await poll(&world, 2))
        await changeDisplays(&world)
        rig.world.setStaleApps([vpn, sync])
        #expect(await poll(&world, 2))
        let items = await rig.session.inventory.items.filter { [vpn, sync].contains($0.ownerBundleID) }
        #expect(!items.isEmpty && items.allSatisfy(\.isOverflowed), "behind the notch")
        #expect(await rig.session.stuckRecoveriesDecided == 0, "out of the way is no loss")

        await changeDisplays(&world)
        rig.world.setStaleApps([])
        rig.world.setUnattached([vpn, sync])
        #expect(await poll(&world))
        #expect(world.restarter.restarts == 0)
        #expect(await pollUntilRestarted(&world))
        #expect(await poll(&world, 4))
        #expect(world.restarter.restarts == 1, "exactly one")
        #expect(await !world.notRecovered)
    }

    // MARK: Still stuck

    @Test func stillStuckAfterTheRestartIsSaidOnceAndNotRestartedAgain() async throws {
        var world = await started()
        let rig = world.rig
        world.cure.set(false)
        #expect(await lidCycle(&world, missing: [vpn, sync]))
        #expect(await poll(&world))
        #expect(await pollUntilRestarted(&world))
        #expect(await !world.notRecovered, "not before 10 seconds have passed")

        let before = world
        let lines = await LogCapture.lines {
            var inside = before
            for _ in 0..<6 { _ = await self.poll(&inside) }
        }
        world.reads = await rig.session.scansIngested
        #expect(world.restarter.restarts == 1)
        #expect(await world.notRecovered)
        #expect(await world.flagged.isEmpty, "B1's hold stays while the bar may still be stuck: the app isn't taken for one macOS doesn't tie")
        #expect(lines.contains { $0.contains("still stuck 10 seconds after MenuBarAgent restarted") && $0.contains(vpn) }, "said")

        // The row is the one the Diagnostics pane shows, and goes when the bar is whole.
        let checks = HidingDiagnostics.stuckBarChecks(notRecovered: await world.notRecovered)
        #expect(checks.map(\.detail) == ["The menu bar didn't come back after a change of displays. Choose Reset."])
        rig.world.setUnattached([])
        #expect(await poll(&world))
        #expect(await !world.notRecovered)
        #expect(world.restarter.restarts == 1)
    }

    enum Change: String, CaseIterable, Sendable, CustomTestStringConvertible {
        case wake, unlock, displays

        var testDescription: String { rawValue }
    }

    private func change(_ kind: Change, _ world: inout World) async {
        switch kind {
        case .wake: await world.rig.session.sessionChanged(.systemWoke)
        case .unlock:
            await world.rig.session.sessionChanged(.screenLocked(true))
            await world.rig.session.sessionChanged(.screenLocked(false))
        case .displays: await changeDisplays(&world)
        }
    }

    @Test(arguments: Change.allCases) func aRestartThatDidntHelpIsNotFollowedByAnotherAtTheNextChange(_ kind: Change) async throws {
        var world = await started()
        world.cure.set(false)
        #expect(await lidCycle(&world, missing: [vpn, sync]))
        #expect(await poll(&world))
        #expect(await pollUntilRestarted(&world))
        for _ in 0..<4 where await !world.notRecovered { _ = await poll(&world) }
        #expect(await world.notRecovered)

        // Every wake, unlock and change of displays after it finds the same pattern, and restarts nothing.
        for round in 1...3 {
            await change(kind, &world)
            #expect(await poll(&world, 5), "round \(round)")
            #expect(await finishRecovery(&world))
            #expect(world.restarter.restarts == 1, "\(kind.rawValue), round \(round)")
            #expect(await world.notRecovered)
        }

        // The bar is whole again, and a change after that is judged as the first was.
        world.rig.world.setUnattached([])
        #expect(await poll(&world, 2))
        #expect(await !world.notRecovered)
        await change(kind, &world)
        world.rig.world.setUnattached([vpn, sync])
        #expect(await pollUntilRestarted(&world, 2, polls: 6))
    }

    @Test func aResetTakesTheNoteAway() async throws {
        var world = await started()
        let rig = world.rig
        world.cure.set(false)
        #expect(await lidCycle(&world, missing: [vpn, sync]))
        #expect(await poll(&world))
        #expect(await pollUntilRestarted(&world))
        for _ in 0..<4 where await !world.notRecovered { _ = await poll(&world) }
        #expect(await world.notRecovered)

        let resetter = FakeRestarter(log: world.log)
        #expect(await rig.session.resetIfIdle(restarter: resetter, replayJournal: {}) == .done)
        #expect(await !world.notRecovered)
    }

    @Test func aRestartThatCantBeMadeSaysSo() async throws {
        var world = await started()
        world.restarter.fail(with: .didNotComeBack)
        world.cure.set(false)
        #expect(await lidCycle(&world, missing: [vpn, sync]))
        #expect(await poll(&world))
        #expect(await pollUntilRestarted(&world))
        #expect(await world.notRecovered)
    }

    // MARK: The limits

    enum Limit: String, CaseIterable, Sendable, CustomTestStringConvertible {
        case appReset, sessionReset, probe, pendingWrite, settlingWrite, locked, asleep

        var testDescription: String { rawValue }
    }

    /// Puts the condition in place, and takes it away.
    private func begin(_ limit: Limit, _ world: World) async {
        let session = world.rig.session
        switch limit {
        case .appReset: #expect(world.activity.begin())
        case .sessionReset: break
        case .probe: world.refusal.set("A platform test is changing the menu bar.")
        case .pendingWrite: await session.setLayoutPhase(pending: true, settling: false)
        case .settlingWrite: await session.setLayoutPhase(pending: true, settling: true)
        case .locked: await session.sessionChanged(.screenLocked(true))
        case .asleep: await session.sessionChanged(.displaysAsleep(true))
        }
    }

    private func end(_ limit: Limit, _ world: World) async {
        let session = world.rig.session
        switch limit {
        case .appReset: world.activity.end()
        case .sessionReset: break
        case .probe: world.refusal.set(nil)
        case .pendingWrite, .settlingWrite: await session.setLayoutPhase(pending: false, settling: false)
        case .locked: await session.sessionChanged(.screenLocked(false))
        case .asleep: await session.sessionChanged(.displaysAsleep(false))
        }
    }

    @Test(arguments: Limit.allCases) func noRecoveryWhile(_ limit: Limit) async throws {
        var world = await started()
        let rig = world.rig
        #expect(await poll(&world, 2))
        await changeDisplays(&world)
        rig.world.setUnattached([vpn, sync])

        // A session's own reset: held at its restart.
        let gate = Gate()
        let resetRestarter = FakeRestarter(log: world.log)
        var reset: Task<ResetOutcome, Never>?
        if limit == .sessionReset {
            resetRestarter.whileRestarting { await gate.wait() }
            reset = Task { await rig.session.resetIfIdle(restarter: resetRestarter, replayJournal: {}) }
            #expect(await waitUntil { resetRestarter.restarts == 1 })
        } else {
            await begin(limit, world)
        }
        #expect(await poll(&world, 4))
        // A recovery that was decided is on a task: it is over before it is said that nothing was restarted.
        #expect(await finishRecovery(&world))
        #expect(world.restarter.restarts == 0, "\(limit.rawValue)")
        let decided = await rig.session.stuckRecoveriesDecided
        switch limit {
        case .probe: #expect(world.refusal.asked >= 1 && decided >= 1, "the recovery was decided and refused")
        case .appReset: #expect(decided >= 1, "the recovery was decided and couldn't begin")
        default: break
        }

        if let reset {
            gate.open()
            #expect(await reset.value == .done)
        } else {
            await end(limit, world)
        }
        // Once it is over, the pattern is found again and the bar restarted (a lock or a sleep that ends is a wake: the run starts again).
        world.reads = await rig.session.scansIngested
        if limit == .sessionReset {
            #expect(await poll(&world, 4))
            #expect(world.restarter.restarts == 0, "a reset is its own restart, and with no change after it there is nothing to judge")
        } else if limit == .probe || limit == .appReset {
            // A recovery that couldn't begin ends the run of looks: the first look after it is the first of two, not a decision.
            #expect(await poll(&world))
            #expect(await finishRecovery(&world))
            #expect(world.restarter.restarts == 0, "one look after a refusal isn't two in a row (\(limit.rawValue))")
            #expect(await pollUntilRestarted(&world, polls: 3), "\(limit.rawValue)")
        } else {
            #expect(await pollUntilRestarted(&world, polls: 6), "\(limit.rawValue)")
        }
    }

    @Test(arguments: [Limit.pendingWrite, .settlingWrite, .locked, .asleep]) func aConditionThatBeginsAfterTheDecisionStopsTheRestart(_ limit: Limit) async throws {
        var world = await started()
        #expect(await lidCycle(&world, missing: [vpn, sync]))
        #expect(await poll(&world))
        // The decision is made by the second look; the recovery waits at the platform test's question.
        let gate = Gate()
        world.refusal.hold(at: gate)
        #expect(await poll(&world))
        let refusal = world.refusal
        #expect(await waitUntil { refusal.asked == 1 })
        await begin(limit, world)
        gate.open()
        #expect(await finishRecovery(&world))
        #expect(world.restarter.restarts == 0, "\(limit.rawValue)")
    }

    enum Interruption: String, CaseIterable, Sendable, CustomTestStringConvertible {
        case displaysChange, quit, reset

        var testDescription: String { rawValue }
    }

    /// Where the recovery waits for something besides the clock: the platform test's question, or the list of the apps that are off.
    enum Wait: String, CaseIterable, Sendable, CustomTestStringConvertible {
        case refusal, list

        var testDescription: String { rawValue }
    }

    /// What can come while the recovery waits: a reset can't be read for the list's gate (its own choice reads the list too).
    private static let interruptions: [(Wait, Interruption)] = [
        (.refusal, .displaysChange), (.refusal, .quit), (.refusal, .reset), (.list, .displaysChange), (.list, .quit)
    ]

    @Test(arguments: interruptions) func aChangeOrAQuitWhileTheRecoveryWaitsStopsTheRestart(_ wait: Wait, _ interruption: Interruption) async throws {
        var world = await started()
        let rig = world.rig
        #expect(await lidCycle(&world, missing: [vpn, sync]))
        #expect(await poll(&world))
        let gate = Gate()
        switch wait {
        case .refusal: world.refusal.hold(at: gate)
        case .list: rig.turnedOff.holdQuestions(at: gate)
        }
        #expect(await poll(&world))
        let (refusal, turnedOff) = (world.refusal, rig.turnedOff)
        switch wait {
        case .refusal: #expect(await waitUntil { refusal.asked == 1 })
        case .list: #expect(await waitUntil { turnedOff.questionsHeld == 1 })
        }

        switch interruption {
        case .displaysChange:
            await changeDisplays(&world)
        case .quit:
            _ = await rig.session.tearDownForQuit()
        case .reset:
            // A session's own reset, begun and over while the recovery waits.
            let resetter = FakeRestarter(log: world.log)
            #expect(await rig.session.resetIfIdle(restarter: resetter, replayJournal: {}) == .done)
            world.reads = await rig.session.scansIngested
        }
        gate.open()
        #expect(await finishRecovery(&world))
        #expect(world.restarter.restarts == 0, "\(wait.rawValue), \(interruption.rawValue)")
        #expect(await world.notRecovered == false, "a restart that wasn't made isn't one that failed")
    }

    @Test func quittingBeginningAfterTheDecisionStopsTheRestart() async throws {
        var world = await started()
        let rig = world.rig
        #expect(await lidCycle(&world, missing: [vpn, sync]))
        #expect(await poll(&world))
        let gate = Gate()
        world.refusal.hold(at: gate)
        #expect(await poll(&world))
        let refusal = world.refusal
        #expect(await waitUntil { refusal.asked == 1 })
        _ = await rig.session.tearDownForQuit()
        gate.open()
        #expect(await finishRecovery(&world))
        #expect(world.restarter.restarts == 0)
    }

    @Test func threeInAnHourAtMost() async throws {
        var world = await started()
        // Each cycle: the apps are drawn, the displays change, the apps are missing, and the restart puts them back.
        for cycle in 1...3 {
            #expect(await lidCycle(&world, missing: [vpn, sync]), "cycle \(cycle)")
            #expect(await poll(&world))
            #expect(await pollUntilRestarted(&world, cycle), "cycle \(cycle)")
        }
        #expect(await lidCycle(&world, missing: [vpn, sync]))
        let before = world
        let lines = await LogCapture.lines {
            var inside = before
            _ = await self.poll(&inside, 6)
        }
        #expect(world.restarter.restarts == 3)
        #expect(lines.contains { $0.contains("restarted 3 times in the last hour already") }, "said")
    }
}
