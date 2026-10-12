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
}
