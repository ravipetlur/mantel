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

/// Whether a restart of the menu bar puts the world right (the apps that had no slot have one again).
private final class Cure: Sendable {
    private let works = Mutex(true)
    var isWorking: Bool { works.withLock { $0 } }
    func set(_ works: Bool) { self.works.withLock { $0 = works } }
}

/// A menu bar that a lid cycle left stuck: apps that were drawn under the allowlist have no slot, with room on the bar, from the first
/// read after a change of displays, and a restart of MenuBarAgent (the fake restarter) puts them back.
@Suite("Menu bar session: a bar a change of displays left stuck", .serialized, .timeLimit(.minutes(2)))
struct MenuBarSessionStuckBarTests {
    private struct World {
        let rig: SessionRig
        let restarter: FakeRestarter
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
        let activity = ResetActivity()
        if recovery {
            await rig.session.setStuckBarRecovery(StuckBarRecovery(restarter: restarter, activity: activity))
        }
        await rig.session.start()
        return World(rig: rig, restarter: restarter, cure: cure, activity: activity, log: log)
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

    // MARK: The limits

    enum Limit: String, CaseIterable, Sendable, CustomTestStringConvertible {
        case appReset, sessionReset, pendingWrite, settlingWrite, locked, asleep

        var testDescription: String { rawValue }
    }

    /// Puts the condition in place, and takes it away.
    private func begin(_ limit: Limit, _ world: World) async {
        let session = world.rig.session
        switch limit {
        case .appReset: #expect(world.activity.begin())
        case .sessionReset: break
        case .pendingWrite: await session.setLayoutPhase(pending: true, settling: false)
        case .settlingWrite: await session.setLayoutPhase(pending: false, settling: true)
        case .locked: await session.sessionChanged(.screenLocked(true))
        case .asleep: await session.sessionChanged(.displaysAsleep(true))
        }
    }

    private func end(_ limit: Limit, _ world: World) async {
        let session = world.rig.session
        switch limit {
        case .appReset: world.activity.end()
        case .sessionReset: break
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
        if limit == .appReset {
            #expect(await rig.session.stuckRecoveriesDecided >= 1, "the recovery was decided and couldn't begin")
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
        } else if limit == .appReset {
            // A recovery that couldn't begin ends the run of looks: the first look after it is the first of two, not a decision.
            #expect(await poll(&world))
            #expect(await finishRecovery(&world))
            #expect(world.restarter.restarts == 0, "one look after a recovery that couldn't begin isn't two in a row")
            #expect(await pollUntilRestarted(&world, polls: 3), "\(limit.rawValue)")
        } else {
            #expect(await pollUntilRestarted(&world, polls: 6), "\(limit.rawValue)")
        }
    }

    /// What stops a recovery that is decided is looked at again right before MenuBarAgent is asked: a condition that begins while the
    /// recovery waits for the list of the apps that are off. (Before it is decided, the scan's own gates keep the looks from deciding.)
    @Test(arguments: [Limit.sessionReset, .pendingWrite, .settlingWrite, .locked, .asleep]) func aConditionThatBeginsAfterTheDecisionStopsTheRestart(_ limit: Limit) async throws {
        var world = await started()
        let rig = world.rig
        #expect(await lidCycle(&world, missing: [vpn, sync]))
        #expect(await poll(&world))
        // The decision is made by the second look; the recovery waits for the list of the apps that are off.
        let gate = Gate()
        rig.turnedOff.holdQuestions(at: gate)
        #expect(await poll(&world))
        let turnedOff = rig.turnedOff
        #expect(await waitUntil { turnedOff.questionsHeld == 1 })

        var reset: Task<ResetOutcome, Never>?
        if limit == .sessionReset {
            let resetRestarter = FakeRestarter(log: world.log)
            reset = Task { await rig.session.resetIfIdle(restarter: resetRestarter, replayJournal: {}) }
            #expect(await waitUntil { resetRestarter.restarts == 1 })
        } else {
            await begin(limit, world)
        }
        gate.open()
        #expect(await finishRecovery(&world))
        #expect(world.restarter.restarts == 0, "\(limit.rawValue)")
        if let reset { #expect(await reset.value == .done) }
    }

    // MARK: Interruptions

    enum Interruption: String, CaseIterable, Sendable, CustomTestStringConvertible {
        case displaysChange, quit

        var testDescription: String { rawValue }
    }

    @Test(arguments: Interruption.allCases) func aChangeOrAQuitWhileTheRecoveryWaitsStopsTheRestart(_ interruption: Interruption) async throws {
        var world = await started()
        let rig = world.rig
        #expect(await lidCycle(&world, missing: [vpn, sync]))
        #expect(await poll(&world))
        // The recovery waits for the list of the apps that are off.
        let gate = Gate()
        rig.turnedOff.holdQuestions(at: gate)
        #expect(await poll(&world))
        let turnedOff = rig.turnedOff
        #expect(await waitUntil { turnedOff.questionsHeld == 1 })

        switch interruption {
        case .displaysChange:
            await changeDisplays(&world)
        case .quit:
            _ = await rig.session.tearDownForQuit()
        }
        gate.open()
        #expect(await finishRecovery(&world))
        #expect(world.restarter.restarts == 0, "\(interruption.rawValue)")
        #expect(await world.notRecovered == false, "a restart that wasn't made isn't one that failed")
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
