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

/// A reveal is applied at once, and followed up (looked for on the bar, and the room read) apart from the next change.
@Suite("Menu bar session: reveals", .timeLimit(.minutes(1)))
struct MenuBarSessionRevealTests {
    /// A session over an engine that changes nothing on the bar, with the weather app's icons never drawn: its follow-up looks for them
    /// for as long as it may, asleep on the clock.
    private func neverDrawn(turnedOff: [String] = []) -> (rig: SessionRig, engine: FakeEngine) {
        let engine = FakeEngine(.allowlist, log: CallLog())
        let rig = SessionRig.withEngines([.allowlist: engine], sections: sections(hidden: [weather]))
        rig.world.setHiddenProvider { [weather] }
        rig.turnedOff.set(.apps(turnedOff))
        return (rig, engine)
    }

    /// Waits, in real time, until the session has been asked for this plan last.
    private func waitUntilAsked(for source: PlanSource, _ session: MenuBarSession) async -> Bool {
        let asked = await withinTimeLimit(.seconds(5)) {
            while await session.lastSubmitted?.source != source {
                guard (try? await Task.sleep(for: .milliseconds(1))) != nil else { return false }
            }
            return true
        }
        return asked ?? false
    }

    // MARK: Applying

    @Test func applyingARevealLooksAtNothingAndSaysWhatWasApplied() async throws {
        let rig = SessionRig.withAllowlist(sections: sections(hidden: [weather], alwaysHidden: [notes]))
        await rig.session.start()
        let allowlist = try #require(rig.allowlist)
        let before = rig.events.all.count
        let reads = await rig.session.scansIngested

        let applied = await rig.session.applyReveal(.hiddenShown)
        #expect(applied.state == .hiddenShown)
        // The plan is on the bar, and that is all: the bar was not looked at and not read.
        #expect(Array(rig.events.all.dropFirst(before)) == ["apply"])
        #expect(rig.world.concealed == [notes], "Hidden is shown and Always Hidden is not")
        #expect(allowlist.calls.last?.bundleIDs.contains(weather) == true)
        #expect(await rig.session.scansIngested == reads)
        #expect(try #require(await rig.state).plan.source == .reveal(.hidden))

        // The follow-up is what looks and reads.
        #expect(await rig.session.followUp(applied) == .none)
        #expect(Array(rig.events.all.dropFirst(before)) == ["apply", "scan", "scan"])
        #expect(await rig.session.scansIngested == reads + 1)
    }

    @Test func aCollapseHasNothingToFollowUp() async throws {
        let rig = SessionRig.withAllowlist(sections: sections(hidden: [weather], alwaysHidden: [notes]))
        await rig.session.start()
        #expect(await rig.session.setReveal(.hiddenShown) == .none)
        let before = rig.events.all.count
        let reads = await rig.session.scansIngested

        let applied = await rig.session.applyReveal(.collapsed)
        #expect(rig.world.concealed == [weather, notes])
        #expect(await rig.session.followUp(applied) == .none)
        #expect(Array(rig.events.all.dropFirst(before)) == ["apply"], "nothing was looked at, and nothing was read")
        #expect(await rig.session.scansIngested == reads)
    }

    // MARK: A follow-up never holds up the next change

    @Test func aRevealsFollowUpDoesNotHoldUpTheNextChange() async throws {
        // The weather app never shows on the bar, so the reveal's follow-up is looking for it, asleep on the clock for its next look.
        // A collapse comes in: its plan reaches the engine at once, with the follow-up still asleep.
        let (rig, engine) = neverDrawn()
        await rig.session.start()
        let applied = engine.applied.count
        let reads = await rig.session.scansIngested

        let reveal = await rig.session.applyReveal(.hiddenShown)
        #expect(engine.applied.count == applied + 1)
        let finished = Mutex<NoRoomAction?>(nil)
        let followUp = Task {
            let answer = await rig.session.followUp(reveal)
            finished.withLock { $0 = answer }
        }
        #expect(await rig.clock.waitForSleepers(3, within: .seconds(5)), "the follow-up is looking, asleep on the clock")

        _ = await rig.session.applyReveal(.collapsed)
        #expect(engine.applied.count == applied + 2, "the collapse was applied")
        #expect(engine.applied.last?.concealedBundleIDs == [weather])
        #expect(finished.withLock { $0 } == nil, "while the follow-up is still waiting")
        #expect(try #require(await rig.state).plan.source == .sections)

        // When the follow-up wakes it finds it is stale, and ends without reading the bar for a reveal that is over.
        rig.clock.advance(by: MenuBarSession.confirmationInterval)
        await followUp.value
        #expect(finished.withLock { $0 } == NoRoomAction.none)
        #expect(await rig.session.scansIngested == reads)
    }

    @Test func aRevealsRoomReadDoesNotHoldUpTheNextChange() async throws {
        // The reveal is on the bar at once, and the follow-up's read of the whole bar is under way and doesn't finish. The collapse is
        // applied meanwhile, and the read that was held up is no verdict on a reveal that is over.
        let rig = SessionRig.withAllowlist(sections: sections(hidden: [weather]))
        await rig.session.start()
        let allowlist = try #require(rig.allowlist)

        let gate = Gate()
        rig.extras.holdReads(at: gate)
        defer { gate.open() }
        let reveal = await rig.session.applyReveal(.hiddenShown)
        let finished = Mutex<NoRoomAction?>(nil)
        let followUp = Task {
            let answer = await rig.session.followUp(reveal)
            finished.withLock { $0 = answer }
        }
        let extras = rig.extras
        #expect(await waitUntil { extras.readsHeld > 0 }, "the read of the whole bar is under way")
        #expect(rig.world.concealed.isEmpty)

        let applied = allowlist.calls.count
        _ = await rig.session.applyReveal(.collapsed)
        #expect(allowlist.calls.count == applied + 1, "the collapse reached the allowlist")
        #expect(rig.world.concealed == [weather], "and the bar is hidden again")
        #expect(finished.withLock { $0 } == nil, "while the read is held")

        rig.extras.holdReads(at: nil)
        gate.open()
        await followUp.value
        #expect(finished.withLock { $0 } == NoRoomAction.none)
        #expect(rig.world.concealed == [weather])
    }

    @Test func anOvertakenFollowUpStops() async throws {
        let rig = SessionRig.withAllowlist(sections: sections(hidden: [weather], alwaysHidden: [notes]))
        await rig.session.start()
        let reads = await rig.session.scansIngested
        let looks = rig.events.count("scan")

        // A newer change was applied before the first one's follow-up began: it returns nothing, and looks at nothing.
        let first = await rig.session.applyReveal(.hiddenShown)
        let second = await rig.session.applyReveal(.allShown)
        #expect(await rig.session.followUp(first) == .none)
        #expect(rig.events.count("scan") == looks, "the bar wasn't looked at")
        #expect(await rig.session.scansIngested == reads, "and wasn't read")

        // The newer one's follow-up is the one that does it.
        #expect(await rig.session.followUp(second) == .none)
        #expect(rig.events.count("scan") == looks + 2, "a look, and a read")
        #expect(await rig.session.scansIngested == reads + 1)
        #expect(rig.world.concealed.isEmpty)

        // A follow-up of a reveal that has been collapsed since is as stale.
        let third = await rig.session.applyReveal(.hiddenShown)
        _ = await rig.session.applyReveal(.collapsed)
        #expect(await rig.session.followUp(third) == .none)
        #expect(rig.events.count("scan") == looks + 2)
    }

    @Test func revealsAskedForWhileAnApplyRunsAreAppliedAsTheNewest() async throws {
        // The first reveal is being applied (an engine that takes its time). Two changes come in behind it, one after the other. Only
        // the newest is applied after the first: the one between isn't made live for a moment and put away again.
        let rig = SessionRig.withAllowlist(sections: sections(hidden: [weather], alwaysHidden: [notes]))
        await rig.session.start()
        let allowlist = try #require(rig.allowlist)
        let before = allowlist.calls.count

        let gate = Gate()
        allowlist.holdActivations(until: gate)
        defer { gate.open() }
        let first = Task { await rig.session.applyReveal(.hiddenShown) }
        #expect(await waitUntil { allowlist.calls.count == before + 1 }, "the first is being applied")
        let second = Task { await rig.session.applyReveal(.allShown) }
        #expect(await waitUntilAsked(for: .reveal(.all), rig.session))
        let third = Task { await rig.session.applyReveal(.collapsed) }
        #expect(await waitUntilAsked(for: .sections, rig.session))

        gate.open()
        let applied = [await first.value, await second.value, await third.value]
        #expect(applied.map(\.state) == [.hiddenShown, .allShown, .collapsed])
        let calls = Array(allowlist.calls.dropFirst(before))
        try #require(calls.count == 2, "the first, and the newest")
        #expect(calls[0].bundleIDs.contains(weather) && !calls[0].bundleIDs.contains(notes), "Hidden was shown")
        #expect(!calls[1].bundleIDs.contains(weather) && !calls[1].bundleIDs.contains(notes), "and then everything was put away")
        #expect(rig.world.concealed == [weather, notes])
        #expect(try #require(await rig.state).plan.source == .sections)
    }

    // MARK: Looking for the reveal

    @Test func theBarIsLookedAtNoMoreOftenThanEveryQuarterOfASecondForTwoSeconds() async throws {
        let (rig, _) = neverDrawn()
        await rig.session.start()
        let looks = rig.events.count("scan")

        let answer = Mutex<NoRoomAction?>(nil)
        let reveal = Task {
            let result = await rig.session.setReveal(.hiddenShown)
            answer.withLock { $0 = result }
        }
        #expect(await rig.driveClock(step: MenuBarSession.confirmationInterval) { answer.withLock { $0 } != nil }, "setReveal returned")
        reveal.cancel()
        // The first look is at once, and one more for each quarter of a second of the two: nine, and the read of the whole bar after
        // them (which asks too).
        #expect(rig.events.count("scan") - looks == 9 + 1)
    }

    @Test func aRevealThatMacOSDoesNotDrawIsWaitedForOnce() async throws {
        let (rig, _) = neverDrawn()
        await rig.session.start()
        let answer = Mutex<NoRoomAction?>(nil)
        let first = Task {
            let result = await rig.session.setReveal(.hiddenShown)
            answer.withLock { $0 = result }
        }
        #expect(await rig.driveClock(step: MenuBarSession.confirmationInterval) { answer.withLock { $0 } != nil })
        first.cancel()

        // The read that came at the end found the weather app's icons with no place on the bar, though the reveal drew them: macOS isn't
        // drawing them, and the next reveal doesn't wait for them.
        #expect(await rig.session.setReveal(.collapsed) == .none)
        let started = rig.clock.now()
        #expect(await rig.session.setReveal(.hiddenShown) == .none)
        #expect(rig.clock.now() == started, "no time went by")
    }

    @Test func anAppTurnedOffInSystemSettingsIsNotWaitedFor() async throws {
        // The weather app's switch is off: macOS doesn't draw its icons, whatever is revealed. The look knows that from the first
        // reveal.
        let (rig, _) = neverDrawn(turnedOff: [weather])
        await rig.session.start()
        let started = rig.clock.now()
        #expect(await rig.session.setReveal(.hiddenShown) == .none)
        #expect(rig.clock.now() == started, "no time went by")
    }

    @Test func anIconMacOSParksOffTheBarIsNotWaitedFor() async throws {
        // AirDrop's slot has a frame, but it is far below the bar (as it is under any allowlist hold). The plan always draws it, since
        // Mantel has no number to take it away by. The look doesn't count a slot that is off the bar, and neither does the count of
        // what there should be: the read of the collapsed bar found it there, and a reveal doesn't wait for it.
        let rig = SessionRig.withAllowlist(sections: sections(hidden: [weather], alwaysHidden: [notes]))
        rig.world.setParked(["airdrop"])
        await rig.session.start()
        let started = rig.clock.now()
        let answer = await withinTimeLimit(.seconds(5)) { await rig.session.setReveal(.hiddenShown) }
        #expect(answer == NoRoomAction.none, "setReveal came back without the clock being driven")
        #expect(rig.clock.now() == started, "no time went by")
        #expect(rig.world.concealed == [notes])
    }

    @Test func aLookThatCantTellIsNotWaitedFor() async throws {
        // Accessibility is taken away: there is nothing to look at the bar with, and waiting wouldn't change that. The follow-up goes
        // on to the read of the whole bar at once, with nothing sleeping on the clock.
        let trusted = Switch(true)
        let rig = SessionRig.withAllowlist(sections: sections(hidden: [weather]), trusted: trusted)
        await rig.session.start()
        trusted.set(false)
        let reads = await rig.session.scansIngested
        let looks = rig.events.count("scan")
        let started = rig.clock.now()

        let reveal = await rig.session.applyReveal(.hiddenShown)
        let answer = await withinTimeLimit(.seconds(5)) { await rig.session.followUp(reveal) }
        #expect(answer == NoRoomAction.none, "the follow-up came back without the clock having moved")
        #expect(rig.clock.now() == started)
        #expect(rig.events.count("scan") - looks == 2, "one look, which couldn't tell, and the read of the whole bar")
        #expect(await rig.session.scansIngested == reads + 1)
        #expect(rig.clock.sleeperCount == 2, "nothing waits for another look")
    }

    @Test func aLookThatTimedOutEndsTheConfirmationAtOnce() async throws {
        // The reads of the slots time out: what the look saw is short of what is there, and another look would meet the same.
        let (rig, _) = neverDrawn()
        await rig.session.start()
        rig.world.fixture().ax.setOverride { _, name in name == AXName.role ? .failure(.timeout) : nil }
        let reads = await rig.session.scansIngested
        let looks = rig.events.count("scan")
        let started = rig.clock.now()

        let reveal = await rig.session.applyReveal(.hiddenShown)
        let answer = await withinTimeLimit(.seconds(5)) { await rig.session.followUp(reveal) }
        #expect(answer == NoRoomAction.none)
        #expect(rig.clock.now() == started, "it didn't wait")
        #expect(rig.events.count("scan") - looks == 2, "one look, and the read of the whole bar")
        #expect(await rig.session.scansIngested == reads + 1)
    }

    @Test func aLookThatTakesLongerThanTheWaitEndsTheConfirmationAfterThatLook() async throws {
        // Each look at MenuBarAgent's windows takes three seconds on the clock: longer than the two the reveal may be waited for. The
        // wait is time on the clock, from the first look, so that look is the last: nothing sleeps for the next.
        let (rig, _) = neverDrawn()
        await rig.session.start()
        let clock = rig.clock
        rig.world.fixture().ax.setOverride { _, name in
            if name == AXName.windows { clock.advance(by: .seconds(3)) }
            return nil
        }
        let looks = rig.events.count("scan")
        let started = rig.clock.now()

        let answer = await withinTimeLimit(.seconds(5)) { await rig.session.setReveal(.hiddenShown) }
        #expect(answer == NoRoomAction.none, "setReveal came back without the clock being driven")
        #expect(rig.events.count("scan") - looks == 2, "one look, and the read of the whole bar")
        #expect(rig.clock.now().timeIntervalSince(started) >= 3)
        #expect(rig.clock.sleeperCount == 2, "no look waits for another")
    }

    @Test func theLineForARevealThatWasNotSeenSaysHowManyIconsAndNamesNone() {
        #expect(MenuBarSession.notSeenLogLine(drawn: 14, expected: 17)
            == "the reveal wasn't seen on the bar within the wait (14 of 17 icons on the main bar); going on")
        #expect(MenuBarSession.notSeenLogLine(drawn: 0, expected: 0)
            == "the reveal wasn't seen on the bar within the wait (0 of 0 icons on the main bar); going on")
    }

    @Test func aRevealIsSeenWhenTheBarHasAPlaceForEveryIconThePlanDraws() async throws {
        // The weather app's icons are concealed while collapsed, and come back with the reveal: the look sees them at once.
        let rig = SessionRig.withAllowlist(sections: sections(hidden: [weather]))
        await rig.session.start()
        #expect(rig.world.concealed == [weather])
        let started = rig.clock.now()
        #expect(await rig.session.setReveal(.hiddenShown) == .none)
        #expect(rig.clock.now() == started, "no time went by")
        #expect(rig.world.concealed.isEmpty)
    }

    // MARK: Confirming a switch of engine

    @Test func aPlanThatHidesIsSeenWhenTheBarDrawsNoMoreSlotsThanItDoes() async throws {
        // The weather app's icons are concealed by the allowlist: the bar has no slot for them, and the plan doesn't draw them.
        let rig = SessionRig.withAllowlist(sections: sections(hidden: [weather]))
        await rig.session.start()
        #expect(rig.world.concealed == [weather])
        let plan = try #require(await rig.session.lastSubmitted)

        let started = rig.clock.now()
        #expect(await rig.session.lookForHiding(of: plan) == .seen)
        #expect(rig.clock.now() == started, "one look, and no time went by")
    }

    @Test func aPlanThatHidesIsNotYetSeenWhileItsIconsAreOnTheBar() async throws {
        // An engine that changes nothing: the weather app's icons stay on the bar, though the plan hides them.
        let rig = SessionRig.withEngines([.allowlist: FakeEngine(.allowlist, log: CallLog())], sections: sections(hidden: [weather]))
        await rig.session.start()
        #expect(rig.world.concealed.isEmpty)
        let plan = try #require(await rig.session.lastSubmitted)
        #expect(plan.concealedBundleIDs.contains(weather))

        #expect(await rig.session.lookForHiding(of: plan) == .notYet)
    }

    @Test func aPlanThatHidesNothingIsSeenAtOnce() async throws {
        let rig = SessionRig.withAllowlist(sections: sections())
        await rig.session.start()
        let plan = try #require(await rig.session.lastSubmitted)
        #expect(await rig.session.lookForHiding(of: plan) == .seen)
    }

    @Test func aWindowThatCantBeListedIsNotAHideThatWasSeen() async throws {
        // MenuBarAgent restarts, and the window's element is gone: the slots can't be listed. A bar with none would read as everything
        // hidden; it isn't a look at all.
        let rig = SessionRig.withAllowlist(sections: sections(hidden: [weather]))
        await rig.session.start()
        let plan = try #require(await rig.session.lastSubmitted)
        let window = rig.world.fixture().windows[0][0]
        rig.world.fixture().ax.setOverride { id, name in id == window && name == AXName.children ? .failure(.failure(-25202)) : nil }
        #expect(await rig.session.lookForHiding(of: plan) == .cantTell)
    }

    @Test func aLookThatCantTellIsNoConfirmationOfAHide() async throws {
        let trusted = Switch(true)
        let rig = SessionRig.withAllowlist(sections: sections(hidden: [weather]), trusted: trusted)
        await rig.session.start()
        let plan = try #require(await rig.session.lastSubmitted)
        trusted.set(false)
        #expect(await rig.session.lookForHiding(of: plan) == .cantTell, "no Accessibility, nothing to look with")

        // Reads that time out are no better: what such a look saw is short of what is there, whichever way it points.
        trusted.set(true)
        #expect(await rig.session.lookForHiding(of: plan) == .seen)
        rig.world.fixture().ax.setOverride { _, name in name == AXName.role ? .failure(.timeout) : nil }
        #expect(await rig.session.lookForHiding(of: plan) == .cantTell)
    }

    // MARK: The second bar

    /// The laptop's full bar, which has room for five of the third-party icons: Hidden holds the weather app (two icons) and the notes
    /// app (one), whose icons were piled 24 points wide when the bar was first read (72 points in all); Shown holds the VPN app and the
    /// sync app. Left of the VPN app's icon, the bar is free from the notch (956.5) to 1154. The policy is the second bar.
    private func laptop() -> SessionRig {
        var settings = HidingSettings()
        settings.automaticOverflow = false
        settings.noRoomPolicy = .secondBar
        return SessionRig.withAllowlist(shape: .laptop, capacity: 5,
                                        sections: sections(shown: [vpn, SessionWorld.sync], hidden: [weather, notes]), settings: settings)
    }

    /// Gives an app menus that run from the left edge to `right`, as an app that is in front has, and has the session told it is in front.
    private func bringToFront(_ app: String, menusTo right: CGFloat, in rig: SessionRig) async throws {
        let pid = try #require(rig.world.fixture().pid(of: app))
        let ax = rig.world.fixture().ax
        let bar = ax.addNode(attributes: [AXName.role: .string("AXMenuBar")])
        ax.addNode(attributes: FakeAX.frameAttributes(CGRect(x: 0, y: 0, width: right, height: 30)), under: bar)
        ax.setAttribute(AXName.menuBar, .elements([ax.ref(bar)]), on: ax.root(ofApp: pid))
        await rig.session.frontAppChanged(pid: pid, activeScreenWidth: 1728)
    }

    @Test func predictedNoRoomOpensSecondBarAtOnce() async throws {
        let rig = laptop()
        await rig.session.start()
        #expect(await rig.session.predictedFits(.hiddenShown), "197 points are free, and the three icons took 72")
        let roomy = await rig.session.predictedFits(.hiddenShown)
        #expect(RevealPresentationPolicy.presentation(opens: .whenNoRoom, trigger: .dot, predictedFits: roomy) == .inline)

        // The front app's menus run on to 1100: 54 points are free, and the revealed icons don't fit.
        try await bringToFront(vpn, menusTo: 1100, in: rig)
        let fits = await rig.session.predictedFits(.hiddenShown)
        #expect(!fits)
        let presentation = RevealPresentationPolicy.presentation(opens: .whenNoRoom, trigger: .dot, predictedFits: fits)
        #expect(presentation == .secondBar)

        // The reveal goes to the second bar at once: nothing is put on the menu bar, nothing is looked at, nothing is read and no time
        // goes by, so there is no moment when the icons are piled in the « menu.
        let events = rig.events.all
        let reads = await rig.session.scansIngested
        let started = rig.clock.now()
        let applied = await rig.session.applyReveal(.hiddenShown, presentation: presentation)
        let answer = await withinTimeLimit(.seconds(5)) { await rig.session.followUp(applied) }
        #expect(answer == NoRoomAction.none)
        #expect(rig.events.all == events, "no apply, no look, no read")
        #expect(await rig.session.scansIngested == reads)
        #expect(rig.clock.now() == started)
        #expect(rig.world.concealed == [weather, notes], "the bar is as the sections make it")
        let state = try #require(await rig.state)
        #expect(state.plan.source == .sections)
        #expect(state.lists.overflow.isEmpty, "the « menu holds nothing of Mantel's")
    }

    @Test func predictionReadsNothingAndIsTrueForAStateThatRevealsNothing() async throws {
        let rig = laptop()
        await rig.session.start()
        try await bringToFront(vpn, menusTo: 1100, in: rig)
        let events = rig.events.all
        let reads = await rig.session.scansIngested
        #expect(await rig.session.predictedFits(.collapsed))
        #expect(await rig.session.predictedFits(.focusMode))
        #expect(!(await rig.session.predictedFits(.allShown)))
        #expect(rig.events.all == events, "nothing is looked at")
        #expect(await rig.session.scansIngested == reads, "and nothing is read")
    }

    @Test func predictionLeavesOutAppsMacOSHasTurnedOff() async throws {
        let rig = laptop()
        await rig.session.start()
        try await bringToFront(vpn, menusTo: 1100, in: rig)
        #expect(!(await rig.session.predictedFits(.hiddenShown)))
        // The weather app's switch is off in System Settings: its icons take no room, and the notes app's (24 points) fit in 54.
        rig.turnedOff.set(.apps([weather]))
        await rig.session.setSettingsOpen(true)
        #expect(await rig.session.predictedFits(.hiddenShown))
    }

    @Test func widthsArePublishedWithTheState() async throws {
        let rig = SessionRig.withAllowlist(sections: sections(hidden: [weather]))
        await rig.session.start()
        let state = try #require(await rig.state)
        // The weather app is concealed in the read that was last, and its icons' widths are what they were when they were on the bar.
        let icons = state.inventory.items(ofApp: weather)
        #expect(icons.count == 2 && icons.allSatisfy(\.isConcealed))
        #expect(icons.map { state.widths.slotWidth(of: $0.id) } == [36, 36])
        #expect(state.widths.slotWidth(of: ItemID.system("wifi")) == 36)
        // And a new state is published when they change: the state is what the panels and the layout editor read.
        let notesIcon = try #require(state.inventory.items(ofApp: notes).first)
        #expect(state.widths.slotWidth(of: notesIcon.id) == 36)
        #expect(try #require(await rig.session.lastPublished).widths == state.widths)
    }

    @Test func secondBarPresentationAppliesCollapsedPlan() async throws {
        let rig = SessionRig.withAllowlist(sections: sections(hidden: [weather], alwaysHidden: [notes]))
        await rig.session.start()
        let before = rig.events.all.count

        let applied = await rig.session.applyReveal(.hiddenShown, presentation: .secondBar)
        #expect(applied.state == .hiddenShown)
        #expect(applied.presentation == .secondBar)
        // The plan is the sections' plan, which is the plan that is applied: nothing is made live, and the bar is as it was.
        #expect(Array(rig.events.all.dropFirst(before)).isEmpty)
        #expect(rig.world.concealed == [weather, notes])
        let state = try #require(await rig.state)
        #expect(state.plan.source == .sections)
        #expect(state.plan.concealedBundleIDs == [weather, notes])
        #expect(state.plan.concealedSections == [.hidden, .alwaysHidden])

        // Everything and a second look are the same; the reveal in the second bar is the state's, though, and not the plan's.
        let all = await rig.session.applyReveal(.allShown, presentation: .secondBar)
        #expect(all.presentation == .secondBar)
        #expect(try #require(await rig.state).plan.source == .sections)
        #expect(Array(rig.events.all.dropFirst(before)).isEmpty)

        // The next reveal is its own: inline, it is on the bar, and what is shown in no second bar isn't any more.
        let inline = await rig.session.applyReveal(.hiddenShown)
        #expect(inline.presentation == .inline)
        #expect(try #require(await rig.state).plan.source == .reveal(.hidden))
        #expect(rig.world.concealed == [notes])

        // A state that reveals nothing has no second bar, whatever it is asked for.
        let focus = await rig.session.applyReveal(.focusMode, presentation: .secondBar)
        #expect(focus.presentation == .inline)
        #expect(try #require(await rig.state).plan.source == .focusMode)
        let collapsed = await rig.session.applyReveal(.collapsed, presentation: .secondBar)
        #expect(collapsed.presentation == .inline)
        #expect(try #require(await rig.state).plan.source == .sections)
    }

    @Test func secondBarPresentationFollowUpIsNone() async throws {
        // On the laptop's full bar the revealed icons wouldn't fit inline: shown in the second bar, nothing is looked for.
        let rig = laptop()
        await rig.session.start()
        let events = rig.events.all
        let reads = await rig.session.scansIngested
        let started = rig.clock.now()

        let applied = await rig.session.applyReveal(.hiddenShown, presentation: .secondBar)
        let answer = await withinTimeLimit(.seconds(5)) { await rig.session.followUp(applied) }
        #expect(answer == NoRoomAction.none)
        #expect(await rig.session.recheckRoom(menuBarTakenOver: false) == .none)
        #expect(await rig.session.setReveal(.allShown, presentation: .secondBar) == .none)
        #expect(rig.events.all == events, "no look, no read")
        #expect(await rig.session.scansIngested == reads)
        #expect(rig.clock.now() == started, "and no waiting")
        #expect(try #require(await rig.state).lists.overflow.isEmpty)
    }

    @Test func wrongPredictionIsCorrectedByTheFollowUp() async throws {
        // Nothing is in the way of the revealed icons that the prediction knows of, so it says they fit, and they are revealed inline...
        let rig = laptop()
        await rig.session.start()
        let fits = await rig.session.predictedFits(.hiddenShown)
        #expect(fits)
        let presentation = RevealPresentationPolicy.presentation(opens: .whenNoRoom, trigger: .dot, predictedFits: fits)
        #expect(presentation == .inline)

        // ...but the bar has room for five icons, and the follow-up finds the revealed ones piled in the « menu: it corrects the
        // prediction by answering that the second bar is to open.
        let applied = await rig.session.applyReveal(.hiddenShown, presentation: presentation)
        #expect(await rig.session.followUp(applied) == .openSecondBar)
        let piled = try #require(await rig.state).lists.overflow.map(\.bundleID).sorted()
        #expect(piled == [notes, weather, weather].sorted())

        // The app answers it by showing the same reveal in the second bar: the menu bar is put back as the sections make it, and the
        // icons leave the « menu.
        let corrected = await rig.session.applyReveal(.hiddenShown, presentation: .secondBar)
        #expect(await rig.session.followUp(corrected) == .none)
        #expect(rig.world.concealed == [weather, notes])
        #expect(try #require(await rig.state).plan.source == .sections)
        await rig.session.refresh()
        #expect(try #require(await rig.state).lists.overflow.isEmpty)
    }

    @Test func secondBarPresentationReadsAreJudged() async throws {
        // The VPN, notes and weather apps are Shown and the sync app is Hidden. The bar has room for four icons: Mantel's two and two more,
        // so with the sync app concealed the weather app's icons don't fit.
        func rig() -> SessionRig {
            SessionRig.withAllowlist(shape: .laptop, capacity: nil,
                                     sections: sections(shown: [weather, notes, vpn], hidden: [SessionWorld.sync]))
        }
        let kept = AppPlacement(section: .shown, isAuto: false)

        // The reveal is on the bar: what a read finds is for the reveal's sake, and nothing is moved (the sync app takes the room).
        let inline = rig()
        await inline.session.start()
        inline.world.setCapacity(4)
        _ = await inline.session.applyReveal(.hiddenShown)
        await inline.session.refresh()
        #expect(await inline.session.sections.apps[weather] == kept)

        // The reveal is in the second bar: the menu bar is as the sections make it, and a read of it is judged as a collapsed bar's is.
        // The weather app doesn't fit, and moves to Hidden.
        let second = rig()
        await second.session.start()
        second.world.setCapacity(4)
        _ = await second.session.applyReveal(.hiddenShown, presentation: .secondBar)
        await second.session.refresh()
        #expect(await second.session.sections.apps[weather] == AppPlacement(section: .hidden, isAuto: true))
        #expect(await second.session.sections.apps[notes] == kept)
        #expect(await second.session.sections.apps[vpn] == kept)
    }
}
