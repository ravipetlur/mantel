import CoreGraphics
import Foundation
import MKCore
import MKLayout
import MKTestSupport
import Testing

@testable import MKMenuBar

private let weather = SessionWorld.weather
private let notes = SessionWorld.notes
private let vpn = SessionWorld.vpn
private let sync = SessionWorld.sync

/// An app whose icon macOS doesn't tie to it, from the session's side: the world gives such an app no slot while an assertion is live
/// (and draws it with none), and the session says so after two reads of the bar 10 seconds apart, with the allowlist live through both.
@Suite("Menu bar session: icons macOS doesn't tie to their app", .serialized, .timeLimit(.minutes(1)))
struct MenuBarSessionUnattachedTests {
    /// A session over the allowlist and, unless said otherwise, switches that can be used. The weather app is in Hidden (an allowlist that
    /// names every app isn't made at all), and the notes app's icon has no slot under the allowlist.
    private struct Rig {
        let rig: SessionRig
        let switches: FakeEngine
        let log: CallLog
        /// How many reads the session has taken in, as far as the test has waited for them.
        var reads = SessionRig.readsAtStart

        /// How many times the controller was asked to choose (it asks each engine whether it can be used, and the switches say so).
        var choices: Int { log.count("approvals.availability") }
        var state: MenuBarState? { get async { await rig.state } }
        var engine: HidingEngineKind? { get async { await rig.state?.engine.kind } }
        var flagged: Set<String> { get async { await rig.state?.unattachedApps ?? [] } }
    }

    private func started(unattached: Set<String> = [notes], switches: EngineAvailability = .available,
                         sections initial: SectionModel? = nil, settings: HidingSettings = HidingSettings(),
                         sessionState: any SessionStateSource = SteadySessionState(), turnedOff: TurnedOffList = .apps([])) async -> Rig {
        let log = CallLog()
        let approvals = FakeEngine(.approvals, log: log)
        approvals.setAvailability(switches)
        let rig = SessionRig.withAllowlist(sections: initial ?? sections(shown: [notes, vpn, sync], hidden: [weather]), settings: settings,
                                           sessionState: sessionState, otherEngines: [.approvals: approvals])
        rig.world.setUnattached(unattached)
        rig.turnedOff.set(turnedOff)
        await rig.session.start()
        return Rig(rig: rig, switches: approvals, log: log)
    }

    /// Lets the polling (every 10 seconds) have `count` more reads, and waits for each.
    private func poll(_ world: inout Rig, _ count: Int = 1) async -> Bool {
        for _ in 0..<count {
            world.reads += 1
            guard await world.rig.clock.waitForSleepers(2, within: .seconds(5)) else { return false }
            world.rig.clock.advance(by: .seconds(10))
            guard await world.rig.pumpUntilReads(world.reads) else { return false }
        }
        return true
    }

    /// Waits for something the session says, up to five seconds.
    private func settled(_ condition: @escaping @Sendable () async -> Bool) async -> Bool {
        for _ in 0..<500 {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return false
    }

    // MARK: Flagging

    @Test func aShownAppWithNoSlotUnderTheAllowlistIsFlagged() async throws {
        var world = await started(switches: .broken("not set up"))
        #expect(await world.flagged.isEmpty, "the reads of the launch say nothing")

        // The first read that can say is the first of a run, and the second, 10 seconds on, flags.
        #expect(await poll(&world))
        #expect(await world.flagged.isEmpty)
        #expect(await poll(&world))
        #expect(await world.flagged == [notes])
        #expect(await world.engine == .allowlist, "the switches can't be used: the allowlist stays")
    }

    @Test func notFlaggedFromLaunchRevealDisplayChangeOrLockedReads() async throws {
        let locked = FakeSessionState()
        // The weather app is in Always Hidden, so an assertion stays live while Hidden is revealed: only the reveal keeps the notes app
        // from being flagged.
        var world = await started(switches: .broken("not set up"), sections: sections(shown: [notes, vpn, sync], alwaysHidden: [weather]),
                                  sessionState: locked)
        let rig = world.rig

        // A bar that is shown by a reveal says nothing: three reads, 20 seconds, and no flag.
        _ = await rig.session.applyReveal(.hiddenShown)
        #expect(rig.allowlist?.live ?? 0 > 0, "an assertion is live through the reveal")
        #expect(await poll(&world, 3))
        #expect(await world.flagged.isEmpty)
        _ = await rig.session.applyReveal(.collapsed)

        // The screen is locked: it draws its own bar, and the reads in the meantime say nothing.
        locked.send(.screenLocked(true))
        #expect(await settled { await rig.session.sessionNow.isAwake == false })
        #expect(await poll(&world, 3))
        #expect(await world.flagged.isEmpty)
        locked.send(.screenLocked(false))
        #expect(await settled { await rig.session.sessionNow.isAwake })

        // The first read now is the first of a run, and a change of displays between ends it: no flag at the second.
        #expect(await poll(&world))
        let changed = Task { await rig.session.displaysChanged(rig.world.layout) }
        #expect(await rig.letTheCoalescedReadGo())
        await changed.value
        world.reads = await rig.session.scansIngested
        #expect(await poll(&world))
        #expect(await world.flagged.isEmpty, "the read that began the run was before the change")
        #expect(await poll(&world))
        #expect(await world.flagged == [notes])
    }

    // MARK: Switching

    /// Flags the notes app (two reads, 10 seconds apart, with the allowlist live through both).
    private func flag(_ world: inout Rig) async -> Bool {
        guard await poll(&world, 2) else { return false }
        return await world.flagged == [notes]
    }

    @Test func automaticSwitchesToTheSwitchesAndBackWhenTheAppQuits() async throws {
        var world = await started()
        let rig = world.rig
        let before = world.choices
        #expect(await flag(&world))
        #expect(await world.engine == .approvals)
        #expect(world.choices > before, "the controller was told")
        let reason = try #require(await world.state?.engine.reason)
        #expect(reason.hasPrefix("1 app in Shown has an icon macOS can't tie to it, so Mantel uses System Settings switches, which keep it shown."))
        #expect(!reason.contains(notes), "no app is named in the reason")

        // The app quits: one read without it changes nothing, and the second switches back.
        rig.world.setPlanRunning(Set(rig.world.runningBundleIDs).subtracting([notes]))
        #expect(await poll(&world))
        #expect(await world.engine == .approvals)
        #expect(await poll(&world))
        #expect(await world.engine == .allowlist)
        #expect(await world.flagged.isEmpty)
    }

    @Test func aQuickRelaunchDoesNotSwitchEngines() async throws {
        var world = await started()
        let rig = world.rig
        #expect(await flag(&world))
        let choices = world.choices

        // Gone for one read, and back by the next.
        let running = Set(rig.world.runningBundleIDs)
        rig.world.setPlanRunning(running.subtracting([notes]))
        #expect(await poll(&world))
        rig.world.setPlanRunning(running)
        #expect(await poll(&world, 2))

        #expect(await world.flagged == [notes])
        #expect(await world.engine == .approvals)
        #expect(world.choices == choices, "no choice reached the controller")
    }

    @Test func movingTheAppOutOfShownSwitchesBack() async throws {
        var world = await started()
        let rig = world.rig
        #expect(await flag(&world))
        #expect(await world.engine == .approvals)

        await rig.session.move(app: notes, to: .hidden)
        #expect(await world.engine == .allowlist, "in Hidden the allowlist hides it with its section")
        await rig.session.move(app: notes, to: .shown)
        #expect(await world.engine == .approvals)
    }

    // MARK: Refreshing

    @Test func aResetForgetsTheFlags() async throws {
        var world = await started()
        let rig = world.rig
        #expect(await flag(&world))
        #expect(await world.engine == .approvals)

        let restarter = FakeRestarter(log: world.log)
        #expect(await rig.session.resetIfIdle(restarter: restarter, replayJournal: {}) == .done)
        // Before the next read: the flags went with the reset, and the engine is chosen again without them.
        await rig.session.setSettingsOpen(true)
        #expect(await rig.session.lastPublished?.unattachedApps.isEmpty == true)
        #expect(await world.engine == .allowlist)
    }
}
