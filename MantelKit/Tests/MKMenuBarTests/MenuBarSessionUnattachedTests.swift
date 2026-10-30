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
@Suite("Menu bar session: icons macOS doesn't tie to their app", .timeLimit(.minutes(1)))
struct MenuBarSessionUnattachedTests {
    private let gotNoSlot = "\(notes): its icon gets no slot while the allowlist is live; macOS hasn't tied it to the app"

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

    @Test func aNoteOnAnAppWithASlotSaysNothing() async throws {
        var world = await started(unattached: [])
        #expect(await poll(&world, 3))
        #expect(await world.flagged.isEmpty)
        #expect(await world.engine == .allowlist)
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

    @Test func notFlaggedWhileAnOrderWriteIsPendingOrSettling() async throws {
        var world = await started(switches: .broken("not set up"))
        let rig = world.rig

        // The order table is being written, then the bar is being re-sorted: what the reads show is the bar in motion, and is no evidence.
        await rig.session.setLayoutPhase(pending: true, settling: false)
        #expect(await poll(&world, 3))
        #expect(await world.flagged.isEmpty)
        await rig.session.setLayoutPhase(pending: true, settling: true)
        #expect(await poll(&world, 3))
        #expect(await world.flagged.isEmpty)

        // Once it is over, the first read is the first of a run, and the second flags.
        await rig.session.setLayoutPhase(pending: false, settling: false)
        #expect(await poll(&world))
        #expect(await world.flagged.isEmpty)
        #expect(await poll(&world))
        #expect(await world.flagged == [notes])
    }

    @Test func notFlaggedWhileTheAssertionIsLifted() async throws {
        var world = await started(switches: .broken("not set up"))
        let rig = world.rig
        let engine = try #require(rig.hiding.allowlist)

        // A click on the clock lifts the assertion: everything is drawn, the app too, and the reads in the meantime are no evidence.
        #expect(engine.liftNow())
        #expect(await poll(&world, 3))
        #expect(await world.flagged.isEmpty)

        // Put back, the first read is the first of a run, and the second flags.
        await engine.restoreAfterLift()
        #expect(await poll(&world))
        #expect(await world.flagged.isEmpty)
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

    @Test func anOverflowMoveOfAFlaggedAppDoesNotSwitchBack() async throws {
        // The laptop's bar holds five of the icons that aren't concealed: with the notes app's icon concealed by the allowlist, they are the
        // VPN app's, the sync app's two and Mantel's two. Under the switches the weather app's two and the notes app's are on the bar too, and
        // the left-most three don't fit: the notes app (in Shown) is moved to Hidden for room.
        let log = CallLog()
        let approvals = FakeEngine(.approvals, log: log)
        let rig = SessionRig.withAllowlist(shape: .laptop, capacity: 5, sections: sections(shown: [notes, vpn, sync], hidden: [weather]),
                                           otherEngines: [.approvals: approvals])
        rig.world.setUnattached([notes])
        await rig.session.start()
        var world = Rig(rig: rig, switches: approvals, log: log)
        #expect(await flag(&world))
        #expect(await world.engine == .approvals)
        let choices = world.choices

        var moved = false
        for _ in 0..<6 where !moved {
            #expect(await poll(&world))
            moved = await rig.session.sections.apps[notes] == AppPlacement(section: .hidden, isAuto: true)
        }
        #expect(moved, "automatic overflow moved it")
        #expect(await world.engine == .approvals, "an app moved for room still counts as Shown")
        #expect(world.choices == choices)
        #expect(await world.flagged == [notes])
    }

    // MARK: Turned off

    @Test func grantingTheFileClearsAFlagOnATurnedOffApp() async throws {
        // The list of turned-off apps can't be read, so the app is flagged only because it was seen drawn with no assertion live.
        var world = await started(turnedOff: .unavailable("Choose the file."))
        let rig = world.rig
        #expect(await flag(&world))
        #expect(await world.engine == .approvals)

        // The file is chosen: the app's switch is off, which is why macOS never drew its icon.
        rig.turnedOff.set(.apps([notes]))
        await rig.session.permissionsChanged()
        #expect(await world.flagged.isEmpty)
        #expect(await world.engine == .allowlist, "chosen again with the list, before the engine")
    }

    @Test func aSwitchTurnedOffWhileRunningIsCheckedBeforeFlagging() async throws {
        // Under the sync app, so that the lines of other tests (which flag the notes app) aren't taken for this one's.
        var world = await started(unattached: [sync])
        let rig = world.rig
        let choices = world.choices
        let flaggedLine = "\(sync): its icon gets no slot while the allowlist is live; macOS hasn't tied it to the app"
        #expect(await poll(&world))

        // Its switch is turned off between the reads: the second read would flag it, and the list is read again first.
        rig.turnedOff.set(.apps([sync]))
        let beforeTheRead = world
        let lines = await LogCapture.lines {
            var inside = beforeTheRead
            _ = await self.poll(&inside)
        }
        world.reads += 1
        #expect(await world.flagged.isEmpty)
        #expect(await world.engine == .allowlist)
        #expect(world.choices == choices, "no switch")
        #expect(!lines.contains { $0.contains(flaggedLine) }, "no flag line")
        #expect(!lines.contains { $0.contains("\(sync) is off in System Settings") }, "and none for the clear that followed")
    }

    // MARK: Reveals

    @Test func focusModeNeitherSwitchesNorBreaksARun() async throws {
        // The switches can't be used, so the allowlist stays in charge and Focus Mode has a bar to be read.
        var world = await started(unattached: [vpn], switches: .broken("not set up"))
        let rig = world.rig
        // The first read of a run of the VPN app's, and Focus Mode, which says nothing, comes next.
        #expect(await poll(&world))
        #expect(await world.flagged.isEmpty)
        let choices = world.choices

        _ = await rig.session.applyReveal(.focusMode)
        #expect(await poll(&world, 2))
        #expect(world.choices == choices, "no choice reached the controller")
        #expect(await world.flagged.isEmpty)

        // The run goes on at the next read of the collapsed bar.
        _ = await rig.session.applyReveal(.collapsed)
        #expect(await poll(&world))
        #expect(await world.flagged == [vpn])
    }

    // MARK: A stuck bar

    @Test func anAppThatHadASlotBeforeADisplayChangeIsNotFlaggedAfterIt() async throws {
        // After a lid cycle MenuBarAgent can keep an older layout: an app that was drawn under the allowlist is one that macOS tied to it,
        // and it is missing now with Mantel's dots drawn again and room to spare (the same read as an icon that is never tied).
        var world = await started(unattached: [], switches: .broken("not set up"))
        let rig = world.rig
        #expect(await poll(&world, 2), "the VPN app is drawn in the reads of the allowlist")
        let changed = Task { await rig.session.displaysChanged(rig.world.layout) }
        #expect(await rig.letTheCoalescedReadGo())
        await changed.value
        world.reads = await rig.session.scansIngested

        rig.world.setUnattached([vpn])
        #expect(await poll(&world, 4))
        #expect(await world.flagged.isEmpty)
        #expect(await world.engine == .allowlist)

        // Started again, it is another process, and the allowlist has never drawn that one.
        rig.world.relaunch(vpn)
        #expect(await poll(&world))
        #expect(await world.flagged.isEmpty)
        #expect(await poll(&world))
        #expect(await world.flagged == [vpn])
    }

    @Test func aFlagAndAnotherAppMissingIsNoNewFlag() async throws {
        // The allowlist can't be left (the switches are broken), the notes app is flagged, and then the VPN app is missing too, in reads
        // with the allowlist live: two apps missing at once is a bar that isn't drawing, and not a second icon macOS doesn't tie.
        var world = await started(switches: .broken("not set up"))
        let rig = world.rig
        #expect(await flag(&world))
        rig.world.setUnattached([notes, vpn])
        #expect(await poll(&world, 4))
        #expect(await world.flagged == [notes])
        // The VPN app is back, and the notes app, flagged, is the only one that is missing.
        rig.world.setUnattached([notes])
        #expect(await poll(&world, 3))
        #expect(await world.flagged == [notes])
    }

    @Test func aStuckReadEndsARunAndHoldsNewFlagsUntilAReset() async throws {
        // The allowlist can't be left (the switches are broken). The VPN app is missing alone for one read, then the sync app is missing
        // too for one read (a bar that isn't drawing what it can), then the VPN app is missing alone again.
        var world = await started(unattached: [vpn], switches: .broken("not set up"))
        let rig = world.rig
        #expect(await poll(&world), "the first read of the VPN app's run")
        rig.world.setUnattached([vpn, sync])
        #expect(await poll(&world), "a stuck read")
        rig.world.setUnattached([vpn])
        // Without the stuck read ending the run, this is its second read 20 s on, and the VPN app is flagged.
        #expect(await poll(&world, 5))
        #expect(await world.flagged.isEmpty)
        #expect(await world.engine == .allowlist)

        // A Refresh doesn't restart MenuBarAgent: the bar is as stuck as it was, and there is still no flag.
        #expect(await rig.session.refresh() == .done)
        world.reads = await rig.session.scansIngested
        #expect(await poll(&world, 4))
        #expect(await world.flagged.isEmpty)

        // A Reset does, and an app with no slot is flagged again, by a run of its own.
        let restarter = FakeRestarter(log: world.log)
        #expect(await rig.session.resetIfIdle(restarter: restarter, replayJournal: {}) == .done)
        world.reads = await rig.session.scansIngested
        var flagged = false
        for _ in 0..<4 where !flagged {
            #expect(await poll(&world))
            flagged = await world.flagged == [vpn]
        }
        #expect(flagged)
    }

    @Test func aRefreshKeepsWhatHadASlotAndAResetForgetsIt() async throws {
        // As `anAppThatHadASlotBeforeADisplayChangeIsNotFlaggedAfterIt`, with the person pressing Refresh, which doesn't unstick the bar.
        var world = await started(unattached: [], switches: .broken("not set up"))
        let rig = world.rig
        #expect(await poll(&world, 2), "the VPN app is drawn in the reads of the allowlist")
        let changed = Task { await rig.session.displaysChanged(rig.world.layout) }
        #expect(await rig.letTheCoalescedReadGo())
        await changed.value
        world.reads = await rig.session.scansIngested

        rig.world.setUnattached([vpn])
        #expect(await poll(&world, 2))
        #expect(await rig.session.refresh() == .done)
        world.reads = await rig.session.scansIngested
        // More than the 10 s a run needs, and the app is still missing alone, with the dots drawn: no flag.
        #expect(await poll(&world, 4))
        #expect(await world.flagged.isEmpty)
        #expect(await world.engine == .allowlist)

        // A Reset restarts MenuBarAgent: what was known of the app is gone, and it is flagged by a run of its own.
        let restarter = FakeRestarter(log: world.log)
        #expect(await rig.session.resetIfIdle(restarter: restarter, replayJournal: {}) == .done)
        world.reads = await rig.session.scansIngested
        var flagged = false
        for _ in 0..<4 where !flagged {
            #expect(await poll(&world))
            flagged = await world.flagged == [vpn]
        }
        #expect(flagged)
    }

    @Test func aRunDoesNotSpanAWake() async throws {
        var world = await started(switches: .broken("not set up"))
        let rig = world.rig
        #expect(await poll(&world), "the first read of a run")
        await rig.session.sessionChanged(.systemWoke)
        // The read that would have flagged it is the first of a new run.
        #expect(await poll(&world))
        #expect(await world.flagged.isEmpty)
        #expect(await poll(&world))
        #expect(await world.flagged == [notes])
    }

    // MARK: What the switches' look expects

    @Test func lookForHidingExpectsAFlaggedAppsIcon() async throws {
        func everyAppDrawn(_ world: SessionWorld) -> VisibilityPlan {
            VisibilityPlan(visibleBundleIDs: Set(world.runningBundleIDs), concealedBundleIDs: [],
                           visibleSystemItems: Set(VisibilityPlan.allSystemItems), concealedSections: [], source: .sections)
        }

        // Control: an icon that was found with no slot while the plan asked for it isn't waited for, and when it is drawn after all (with no
        // assertion live) the look finds one slot too many. That is the wait of 2 s that the switch would have for nothing.
        var control = await started(switches: .broken("not set up"))
        #expect(await poll(&control))
        control.rig.world.setUnattached([])
        let inForce = try #require(await control.rig.session.lastSubmitted)
        #expect(await control.rig.session.lookForHiding(of: inForce) == .notYet)

        // Flagged, the app is expected again, and the look at the switch's bar is confirmed at once.
        var world = await started()
        let rig = world.rig
        #expect(await flag(&world))
        #expect(await world.engine == .approvals)
        #expect(rig.allowlist?.live == 0, "no assertion is live under the switches: everything is drawn")
        #expect(await rig.session.lookForHiding(of: everyAppDrawn(rig.world)) == .seen)
    }

    // MARK: Refreshing

    @Test func manualRefreshForgetsAutoRefreshDoesNot() async throws {
        var world = await started()
        let rig = world.rig
        #expect(await flag(&world))
        #expect(await world.engine == .approvals)

        // The agent stops answering, and the session refreshes by itself: the flag stays, and so does the switch.
        rig.world.setAgentRunning(false)
        var tries = 0
        while await rig.session.autoRefreshLogLines.filter({ $0.hasPrefix("refreshing the menu bar:") }).isEmpty, tries < 8 {
            #expect(await poll(&world))
            tries += 1
        }
        #expect(await rig.session.autoRefreshLogLines.contains { $0.hasPrefix("refreshing the menu bar:") }, "auto-refresh made a refresh")
        rig.world.setAgentRunning(true)
        #expect(await poll(&world))
        #expect(await world.flagged == [notes])
        #expect(await world.engine == .approvals)

        // A refresh the person asks for starts over.
        #expect(await rig.session.refresh() == .done)
        #expect(await world.flagged.isEmpty)
        #expect(await world.engine == .allowlist, "the app has to be found again")
    }

    @Test func aRefreshRefusedDuringAResetForgetsNothing() async throws {
        var world = await started()
        let rig = world.rig
        #expect(await flag(&world))
        let gate = Gate()
        let restarter = FakeRestarter(log: world.log)
        restarter.whileRestarting { await gate.wait() }
        let reset = Task { await rig.session.resetIfIdle(restarter: restarter, replayJournal: {}) }
        #expect(await waitUntil { restarter.restarts == 1 })

        let outcome = await rig.session.refresh()
        #expect(outcome != .done)
        // What is published now is what the session holds: the flag is still there.
        await rig.session.setSettingsOpen(true)
        #expect(await rig.session.lastPublished?.unattachedApps == [notes])

        gate.open()
        #expect(await reset.value == .done)
    }

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

    @Test func aQuitIsCountedWhileMenuBarAgentIsDown() async throws {
        var world = await started()
        let rig = world.rig
        #expect(await flag(&world))
        #expect(await world.engine == .approvals)

        // With no menu bar to read, the quit is still counted: two reads, and the allowlist is back.
        rig.world.setAgentRunning(false)
        rig.world.setPlanRunning(Set(rig.world.runningBundleIDs).subtracting([notes]))
        #expect(await poll(&world, 2))
        #expect(await world.engine == .allowlist)
    }

    // MARK: The log

    @Test func eachChangeLogsOneLine() async throws {
        // The switches can't be used, so the allowlist stays in charge and every change is made by a read.
        let world = await started(switches: .broken("not set up"))
        let rig = world.rig

        let lines = await LogCapture.lines {
            var world = world
            func flagged() async -> Bool {
                for _ in 0..<4 where await world.flagged != [notes] { _ = await self.poll(&world) }
                return await world.flagged == [notes]
            }
            // Flagged, and then its icon has a slot.
            #expect(await flagged())
            rig.world.setUnattached([])
            _ = await self.poll(&world)
            #expect(await world.flagged.isEmpty)
            // Flagged again, and then it quits.
            rig.world.setUnattached([notes])
            #expect(await flagged())
            let running = Set(rig.world.runningBundleIDs)
            rig.world.setPlanRunning(running.subtracting([notes]))
            _ = await self.poll(&world, 2)
            rig.world.setPlanRunning(running)
            // Flagged again, and then it lists no icon.
            #expect(await flagged())
            rig.world.setWithoutItems([notes])
            _ = await self.poll(&world, 2)
            rig.world.setWithoutItems([])
            // Flagged again, and then its switch is found off.
            #expect(await flagged())
            rig.turnedOff.set(.apps([notes]))
            await rig.session.permissionsChanged()
            #expect(await world.flagged.isEmpty)
        }

        for expected in [
            "\(notes): its icon gets no slot while the allowlist is live; macOS hasn't tied it to the app",
            "\(notes): its icon has a slot under the allowlist again",
            "\(notes) quit; its icon is no longer watched",
            "\(notes) lists no icon now; it is no longer watched",
            "\(notes) is off in System Settings; its icon is no longer watched",
        ] {
            #expect(lines.contains { $0.hasSuffix("[session] \(expected)") }, "\(expected)")
        }
    }
}
