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
private let testItem = SessionWorld.testItem
private let own = SessionWorld.own

@Suite("Menu bar session", .timeLimit(.minutes(1)))
struct MenuBarSessionTests {
    /// The bundle IDs an allowlist is given for a plan that conceals these: everything that runs, less them (Mantel's own stays).
    private func allowed(_ rig: SessionRig, concealing concealed: Set<String>) -> [String] {
        Set(rig.world.runningBundleIDs).subtracting(concealed.subtracting([own])).sorted()
    }

    // MARK: Starting

    @Test func startAppliesCollapsedPlan() async throws {
        let rig = SessionRig.withAllowlist(sections: sections(hidden: [weather], alwaysHidden: [notes]))
        await rig.session.start()

        // The menu bar was read before anything was hidden, then the plan was applied (one assertion that names what stays), and the bar
        // was read again, collapsed.
        #expect(rig.events.all == ["scan", "apply", "scan"])
        let allowlist = try #require(rig.allowlist)
        #expect(allowlist.calls.map(\.bundleIDs) == [allowed(rig, concealing: [weather, notes])])
        #expect(rig.world.concealed == [weather, notes])

        let state = try #require(await rig.state)
        #expect(state.plan.source == .sections)
        #expect(state.plan.concealedBundleIDs == [weather, notes])
        #expect(state.plan.concealedSections == [.hidden, .alwaysHidden])
        #expect(state.engine.kind == .allowlist)
        #expect(state.engine.lastError == nil)
        // What was read is what the bar had before anything was hidden; the apps' icons are all there.
        #expect(state.inventory.items(ofApp: weather).count == 2)
        #expect(state.inventory.appsWithItems.sorted() == [notes, sync, vpn, weather].sorted())
        // The one who subscribes after it is up is given where things stand.
        var states = await rig.session.states().makeAsyncIterator()
        #expect(await states.next() == state)
    }

    @Test func startAfterCrashBeginsCollapsed() async throws {
        // A session that was showing everything is gone without putting anything back (macOS lets go of its allowlist by itself).
        let before = SessionRig.withAllowlist(sections: sections(hidden: [weather], alwaysHidden: [notes]))
        await before.session.start()
        #expect(await before.session.setReveal(.allShown) == .none)
        #expect(before.world.concealed.isEmpty, "everything is showing")
        #expect(try #require(await before.state).plan.source == .reveal(.all))

        // The next one starts on the bar the first left: fully shown, with no allowlist made live. It starts from what was saved, and
        // nothing of the reveal is: it begins collapsed, and hides what the sections say.
        let after = SessionRig.withAllowlist(world: before.world,
                                             sections: before.saved.latest ?? sections(hidden: [weather], alwaysHidden: [notes]))
        let allowlist = try #require(after.allowlist)
        #expect(after.world.concealed.isEmpty, "the bar is as the first session left it")
        #expect(allowlist.live == 0 && allowlist.calls.isEmpty)
        await after.session.start()
        #expect(after.world.concealed == [weather, notes])
        let state = try #require(await after.state)
        #expect(state.plan.source == .sections)
        #expect(state.plan.concealedSections == [.hidden, .alwaysHidden])
        #expect(allowlist.calls.count == 1, "one plan, the collapsed one")
        #expect(allowlist.calls.first?.bundleIDs == allowed(after, concealing: [weather, notes]))
        #expect(!state.inventory.items(ofApp: weather).isEmpty, "the weather app's icons are in the read")
        #expect(state.inventory.items(ofApp: weather).allSatisfy { $0.isConcealed }, "and the bar it reads is collapsed")
    }

    // MARK: Apps that start

    @Test func appLaunchedWhileHiddenJoinsNewItemsSection() async throws {
        // The new items go to Shown here: an app that starts while others are hidden is on the bar at once, within the rebuild that its
        // start causes and before anything is read, and the read that lists its icons only records where it is.
        var initial = sections(shown: [weather, notes, vpn, sync], newItems: .shown)
        initial.move(app: SessionWorld.agent, to: .shown)
        initial.move(app: weather, to: .hidden)
        let rig = SessionRig.withAllowlist(sections: initial)
        await rig.session.start()
        let allowlist = try #require(rig.allowlist)
        #expect(allowlist.calls.count == 1)
        #expect(rig.world.concealed == [weather])

        rig.world.setTestItemRunning(true)
        await rig.session.runningAppsChanged(RunningAppsChange(launched: [rig.world.app(testItem)], quit: []))
        // Before any read: the allowlist has been made again, with the new app on it, and the app isn't concealed.
        #expect(allowlist.calls.count == 2)
        #expect(allowlist.calls.last?.bundleIDs.contains(testItem) == true)
        #expect(rig.world.concealed == [weather], "the new app is not concealed, not even for a moment")
        #expect(await rig.session.sections.apps[testItem] == nil, "it hasn't been placed: nothing has been read")

        // The read that comes for the change lists its icons, and the app is put where new apps go.
        #expect(await rig.letTheCoalescedReadGo())
        #expect(await rig.waitForReads(SessionRig.readsAtStart + 1))
        let placed = AppPlacement(section: .shown, isAuto: false)
        #expect(await rig.session.sections.apps[testItem] == placed)
        #expect(rig.saved.latest?.apps[testItem] == placed, "and saved")
        #expect(allowlist.calls.count == 2, "knowing where it is changes nothing that is applied")
        #expect(try #require(await rig.state).inventory.items(ofApp: testItem).count == 2)
    }

    @Test func newItemsHiddenKeepsLaunchedAppConcealed() async throws {
        var initial = sections(shown: [weather, notes, vpn, sync], newItems: .hidden)
        initial.move(app: SessionWorld.agent, to: .shown)
        let rig = SessionRig.withAllowlist(sections: initial)
        await rig.session.start()
        let allowlist = try #require(rig.allowlist)
        #expect(rig.world.concealed.isEmpty)

        rig.world.setTestItemRunning(true)
        await rig.session.runningAppsChanged(RunningAppsChange(launched: [rig.world.app(testItem)], quit: []))
        // It is concealed from the moment it runs: it was never on an allowlist, and isn't now.
        #expect(rig.world.concealed == [testItem])
        #expect(try #require(await rig.state).plan.concealedBundleIDs == [testItem])
        #expect(allowlist.calls.allSatisfy { !$0.bundleIDs.contains(testItem) }, "it was never allowed, so it never flashed")

        #expect(await rig.letTheCoalescedReadGo())
        #expect(await rig.waitForReads(SessionRig.readsAtStart + 1))
        let placed = AppPlacement(section: .hidden, isAuto: false)
        #expect(await rig.session.sections.apps[testItem] == placed)
        #expect(rig.saved.latest?.apps[testItem] == placed)
        // The read saw its icons concealed; it stays so, and nothing more was made live.
        let state = try #require(await rig.state)
        #expect(state.inventory.items(ofApp: testItem).allSatisfy { $0.isConcealed })
        #expect(rig.world.concealed == [testItem])
        #expect(allowlist.calls.allSatisfy { !$0.bundleIDs.contains(testItem) })
    }

    @Test func launchThatChangesNothingActivatesNothing() async throws {
        // An app that starts and is hidden changes nothing in what the allowlist names, so no assertion is made for it.
        var initial = sections(shown: [weather, notes, vpn, sync], newItems: .hidden)
        initial.move(app: SessionWorld.agent, to: .shown)
        let rig = SessionRig.withAllowlist(sections: initial)
        await rig.session.start()
        let allowlist = try #require(rig.allowlist)
        // Something to hide, so that an assertion exists to be changed or not.
        await rig.session.move(app: weather, to: .hidden)
        let before = allowlist.calls.count
        #expect(before == 1)

        rig.world.setTestItemRunning(true)
        await rig.session.runningAppsChanged(RunningAppsChange(launched: [rig.world.app(testItem)], quit: []))
        #expect(await rig.letTheCoalescedReadGo())
        #expect(await rig.waitForReads(SessionRig.readsAtStart + 1))
        #expect(allowlist.calls.count == before, "no new assertion")
        #expect(allowlist.invalidations == 0, "and none was let go either: the one that was live still is")
        #expect(allowlist.live == 1)
        #expect(try #require(await rig.state).plan.concealedBundleIDs.contains(testItem))
    }

    @Test func launchesAtTheSameMomentAreOneRead() async throws {
        let rig = SessionRig.withAllowlist()
        await rig.session.start()
        #expect(await rig.session.scansIngested == SessionRig.readsAtStart)
        let apps = [rig.world.app(weather), rig.world.app(notes), rig.world.app(vpn)]
        for app in apps {
            await rig.session.runningAppsChanged(RunningAppsChange(launched: [app], quit: []))
        }
        #expect(await rig.letTheCoalescedReadGo())
        #expect(await rig.waitForReads(SessionRig.readsAtStart + 1))
        // The three changes were asked for within 100 ms of one another: one read answers them.
        #expect(rig.events.count("scan") == SessionRig.readsAtStart + 1)
        #expect(await rig.session.scansIngested == SessionRig.readsAtStart + 1)
        #expect(rig.clock.sleeperCount == 2, "nothing else is waiting to read")
    }

    // MARK: Revealing

    @Test func revealAppliesThenScans() async throws {
        let rig = SessionRig.withAllowlist(sections: sections(hidden: [weather], alwaysHidden: [notes]))
        await rig.session.start()
        let allowlist = try #require(rig.allowlist)
        #expect(rig.world.concealed == [weather, notes])
        let first = rig.events.all.count

        let answer = await rig.session.setReveal(.hiddenShown)
        #expect(answer == .none)
        // The reveal is made live first; then the revealed app is looked for, and the whole bar is read.
        #expect(Array(rig.events.all.dropFirst(first)) == ["apply", "scan", "scan"])
        #expect(allowlist.calls.last?.bundleIDs.contains(weather) == true)
        #expect(allowlist.calls.last?.bundleIDs.contains(notes) == false, "Always Hidden stays hidden")
        #expect(rig.world.concealed == [notes])
        let state = try #require(await rig.state)
        #expect(state.plan.source == .reveal(.hidden))
        #expect(state.inventory.items(ofApp: weather).allSatisfy { !$0.isConcealed }, "the read saw the revealed icons")

        // Collapsing hides them again and has nothing left to do.
        #expect(await rig.session.setReveal(.collapsed) == .none)
        #expect(rig.world.concealed == [weather, notes])
        #expect(try #require(await rig.state).plan.source == .sections)
    }

    @Test func aRevealThatIsNotSeenIsWaitedForTwoSecondsAndNoLonger() async throws {
        // The bar never shows the weather app's icons, whatever is applied (the app's own view of the bar often misses a change that
        // did happen): not seeing them is no failure. The look is repeated every 250 ms for two seconds, and then the whole bar is read.
        let engine = FakeEngine(.allowlist, log: CallLog())
        let rig = SessionRig.withEngines([.allowlist: engine], sections: sections(hidden: [weather]))
        rig.world.setHiddenProvider { [weather] }
        await rig.session.start()
        let started = rig.clock.now()

        let answer = Mutex<NoRoomAction?>(nil)
        let reveal = Task {
            let result = await rig.session.setReveal(.hiddenShown)
            answer.withLock { $0 = result }
        }
        #expect(await rig.driveClock(step: MenuBarSession.confirmationInterval) { answer.withLock { $0 } != nil }, "setReveal returned")
        reveal.cancel()
        #expect(answer.withLock { $0 } == NoRoomAction.none)
        let waited = rig.clock.now().timeIntervalSince(started)
        #expect(waited >= 2 && waited < 2.2, "it waited \(waited) seconds")
        // The look that never succeeded is not the engine's failure, and the reveal was applied.
        #expect(engine.applied.count == 2)
        #expect(try #require(await rig.state).engine.lastError == nil)
        #expect(await rig.session.scansIngested == SessionRig.readsAtStart + 1, "and the whole bar was read at the end")
    }

    @Test func aRevealIsLookedForOnceWhenItIsThereAtOnce() async throws {
        // The look succeeds at the first try: nothing sleeps on the clock for it.
        let rig = SessionRig.withAllowlist(sections: sections(hidden: [weather]))
        await rig.session.start()
        let started = rig.clock.now()
        #expect(await rig.session.setReveal(.hiddenShown) == .none)
        #expect(rig.clock.now() == started, "no time went by")
    }

    @Test func focusModeOverridesReveal() async throws {
        let rig = SessionRig.withAllowlist(sections: sections(hidden: [weather]))
        await rig.session.start()
        let allowlist = try #require(rig.allowlist)
        #expect(await rig.session.setReveal(.allShown) == .none)
        #expect(rig.world.concealed.isEmpty)

        #expect(await rig.session.setReveal(.focusMode) == .none)
        let state = try #require(await rig.state)
        #expect(state.plan.source == .focusMode)
        #expect(state.plan.visibleBundleIDs == [own], "only Mantel's icons stay")
        #expect(state.plan.visibleSystemItems == Set(VisibilityPlan.allSystemItems).subtracting([0, 1, 5, 6]), "and the clock and Control Center")
        #expect(allowlist.calls.last?.bundleIDs == [own])
        #expect(rig.world.concealed == Set(rig.world.runningBundleIDs).subtracting([own]))

        // Leaving it is a collapse.
        #expect(await rig.session.setReveal(.collapsed) == .none)
        #expect(try #require(await rig.state).plan.source == .sections)
        #expect(rig.world.concealed == [weather])
    }

    // MARK: Room

    /// The laptop's full bar, which has room for five of the third-party icons: Hidden holds the weather app (two icons) and the notes
    /// app (one), Shown holds the VPN app and the sync app (two), and Mantel's two dots.
    private func laptop(settings: HidingSettings = HidingSettings(), policy: NoRoomPolicy) -> SessionRig {
        var configured = settings
        configured.automaticOverflow = false
        configured.noRoomPolicy = policy
        return SessionRig.withAllowlist(shape: .laptop, capacity: 5, sections: sections(shown: [vpn, sync], hidden: [weather, notes]),
                                        settings: configured)
    }

    @Test func secondBarPolicyAnswersOpenSecondBarWhenRevealedIconsOverflow() async throws {
        let rig = laptop(policy: .secondBar)
        await rig.session.start()
        #expect(rig.world.concealed == [weather, notes])

        // Three icons are revealed and the bar has room for five: the revealed apps are piled in the « overflow. Policy: show them in the
        // second bar, every time, with nothing to say in the log of icons left in the « menu.
        let first = await rig.session.setReveal(.hiddenShown)
        #expect(first == .openSecondBar)
        let state = try #require(await rig.state)
        #expect(state.lists.overflow.map(\.bundleID).sorted() == [notes, weather, weather].sorted())

        #expect(await rig.session.setReveal(.collapsed) == .none)
        #expect(await rig.session.setReveal(.hiddenShown) == .openSecondBar)
        #expect(await rig.session.setReveal(.allShown) == .openSecondBar)
    }

    @Test func swapConcealsRightMostShownWithinThreeRounds() async throws {
        let rig = laptop(policy: .swap)
        await rig.session.start()
        let allowlist = try #require(rig.allowlist)
        #expect(rig.world.concealed == [weather, notes])
        let before = allowlist.calls.count

        let answer = await rig.session.setReveal(.hiddenShown)
        #expect(answer == .none, "everything fits in the end")

        // The reveal itself conceals nothing, so it holds no assertion. Round one: the revealed icons need 72 points (what they were
        // seen to take, piled), and the right-most Shown app, the sync app, takes that much. Round two: the weather app's icons still
        // don't fit, and the VPN app, the next one to the left, is concealed too. The revealed apps are never concealed to make room
        // for one another.
        let calls = Array(allowlist.calls.dropFirst(before))
        try #require(calls.count == 2, "one assertion for each round")
        #expect(!calls[0].bundleIDs.contains(sync) && calls[0].bundleIDs.contains(vpn))
        #expect(calls[0].bundleIDs.contains(weather) && calls[0].bundleIDs.contains(notes))
        #expect(!calls[1].bundleIDs.contains(sync) && !calls[1].bundleIDs.contains(vpn))
        #expect(calls[1].bundleIDs.contains(weather) && calls[1].bundleIDs.contains(notes))
        #expect(rig.world.concealed == [sync, vpn])
        let state = try #require(await rig.state)
        #expect(state.plan.concealedBundleIDs == [sync, vpn])
        #expect(state.lists.overflow.isEmpty)

        // Collapsing clears the swap: the apps that were concealed come back, and the revealed ones go.
        #expect(await rig.session.setReveal(.collapsed) == .none)
        #expect(rig.world.concealed == [weather, notes])
        #expect(try #require(await rig.state).plan.concealedBundleIDs == [weather, notes])
    }

    @Test func swapGivesUpWhenNothingMoreCanBeConcealed() async throws {
        // Room for three icons: Mantel's two and one more. Every Shown app is concealed and the revealed ones still don't fit.
        var settings = HidingSettings()
        settings.automaticOverflow = false
        settings.noRoomPolicy = .swap
        let rig = SessionRig.withAllowlist(shape: .laptop, capacity: 3, sections: sections(shown: [vpn, sync], hidden: [weather, notes]),
                                           settings: settings)
        await rig.session.start()
        let answer = await rig.session.setReveal(.hiddenShown)
        #expect(answer == .giveUp(NoRoomResponse.giveUpText))
        // It tried as far as it could: both Shown apps were concealed on the way.
        let state = try #require(await rig.state)
        #expect(state.plan.concealedBundleIDs.isSuperset(of: [vpn, sync]))
        #expect(state.plan.concealedBundleIDs.isDisjoint(with: [weather, notes]), "the apps that were revealed are not concealed to make room")
    }

    @Test func swapStopsAfterThreeRoundsEvenWithShownAppsLeft() async throws {
        // Nothing the session conceals changes the bar here (the engine is a fake that only notes what it was asked), so the revealed
        // weather app stays piled at the «. The apps to conceal are the Shown ones that are on the bar, right-most first: the test item,
        // the sync app and the VPN app, one for each round (each takes more room than the weather app needs). After three rounds the
        // session gives up, though the notes app is Shown and still could be.
        var settings = HidingSettings()
        settings.automaticOverflow = false
        settings.noRoomPolicy = .swap
        let engine = FakeEngine(.allowlist, log: CallLog())
        let rig = SessionRig.withEngines([.allowlist: engine], shape: .laptop, testItem: true, capacity: 7,
                                         sections: sections(shown: [notes, vpn, sync, testItem], hidden: [weather]), settings: settings)
        await rig.session.start()
        let applied = engine.applied.count

        let answer = await rig.session.setReveal(.hiddenShown)
        #expect(answer == .giveUp(NoRoomResponse.giveUpText))
        let state = try #require(await rig.state)
        #expect(state.plan.concealedBundleIDs == [testItem, sync, vpn], "one more app in each of the three rounds, the right-most first")
        // The reveal itself, and a plan for each round.
        try #require(engine.applied.count == applied + 4)
        let rounds = engine.applied.dropFirst(applied + 1).map(\.concealedBundleIDs)
        #expect(rounds == [[testItem], [testItem, sync], [testItem, sync, vpn]].map(Set.init))
        #expect(!state.plan.concealedBundleIDs.contains(notes))
    }

    @Test func hideAppMenusAsksTheAppToTakeTheMenuBarOver() async throws {
        let rig = laptop(policy: .hideAppMenus)
        await rig.session.start()
        #expect(await rig.session.setReveal(.hiddenShown) == .takeOverMenuBar)
        // The app took the menu bar over: the room is looked at again. The revealed apps are still piled here (the world has no
        // change to make), so it is left to the « menu, and logged.
        #expect(await rig.session.recheckRoom(menuBarTakenOver: true) == .leaveOverflow(logOnce: true))
        #expect(await rig.session.recheckRoom(menuBarTakenOver: true) == .leaveOverflow(logOnce: false))
        // And when it does fit, there is nothing left to do.
        rig.world.setCapacity(10)
        #expect(await rig.session.recheckRoom(menuBarTakenOver: true) == .none)
    }

    @Test func recheckRoomMakesTheRoomItselfWhenThePolicyBecameSwap() async throws {
        // The policy was to hide the app's menus, and the app took the menu bar over; then the person chose to swap. The room is looked at
        // again, and the swap is made there: the app is never told to swap.
        var settings = HidingSettings()
        settings.automaticOverflow = false
        settings.noRoomPolicy = .hideAppMenus
        let rig = SessionRig.withAllowlist(shape: .laptop, capacity: 5, sections: sections(shown: [vpn, sync], hidden: [weather, notes]),
                                           settings: settings)
        await rig.session.start()
        #expect(await rig.session.setReveal(.hiddenShown) == .takeOverMenuBar)

        settings.noRoomPolicy = .swap
        await rig.session.setSettings(settings)
        #expect(await rig.session.recheckRoom(menuBarTakenOver: true) == .none, "everything fits in the end")
        #expect(rig.world.concealed == [sync, vpn])
        #expect(try #require(await rig.state).plan.concealedBundleIDs == [sync, vpn])
    }

    // MARK: Automatic overflow

    @Test func overflowedShownAppMovesToHiddenWhileCollapsed() async throws {
        // The laptop's bar has room for five icons: the weather app's two and the notes app's are piled at the « when the first read is
        // taken, and the apps move to Hidden by themselves.
        let rig = SessionRig.withAllowlist(shape: .laptop, capacity: 5)
        await rig.session.start()
        let moved = AppPlacement(section: .hidden, isAuto: true)
        let sections = await rig.session.sections
        // The first read, with everything on the bar, only placed them: they were moved by the second, of the bar as it is collapsed.
        #expect(rig.saved.all.first?.apps[weather] == AppPlacement(section: .shown, isAuto: false))
        #expect(await rig.session.scansIngested == SessionRig.readsAtStart)
        #expect(sections.apps[weather] == moved)
        #expect(sections.apps[notes] == moved)
        // The apps that fit are where new apps go, by their own choice, and were saved with the others.
        #expect(sections.apps[vpn] == AppPlacement(section: .shown, isAuto: false))
        #expect(rig.saved.latest?.apps[weather] == moved)
        // And the bar now hides them.
        #expect(rig.world.concealed == [weather, notes])
        let state = try #require(await rig.state)
        #expect(state.plan.concealedBundleIDs == [weather, notes])

        // Read again with them concealed: nothing is piled any more, and nothing moves.
        await rig.session.refresh()
        #expect(try #require(await rig.state).lists.overflow.isEmpty)
        #expect(await rig.session.sections.apps[weather] == moved)
        #expect(await rig.session.sections.apps[vpn] == AppPlacement(section: .shown, isAuto: false))
    }

    @Test func aHiddenAppVisibleBeforeTheFirstHideDoesNotPushShownAppsToHidden() async throws {
        // The VPN app and the sync app (three icons, to the right of the weather app's and the notes app's) are Hidden. The bar has room for
        // six icons. The first read is taken with all of them on it, and the weather app's icons are pushed out of the bar by the ones
        // that are about to be hidden: that is not the weather app's doing, and it is not moved. Collapsed, everything fits.
        let rig = SessionRig.withAllowlist(shape: .laptop, capacity: 6, sections: sections(shown: [weather, notes], hidden: [vpn, sync]))
        await rig.session.start()
        #expect(rig.world.concealed == [vpn, sync])
        let kept = AppPlacement(section: .shown, isAuto: false)
        #expect(await rig.session.sections.apps[weather] == kept)
        #expect(await rig.session.sections.apps[notes] == kept)
        #expect(rig.saved.all.allSatisfy { $0.apps[weather] != AppPlacement(section: .hidden, isAuto: true) })
        #expect(await rig.session.scansIngested == SessionRig.readsAtStart)
        let state = try #require(await rig.state)
        #expect(state.lists.overflow.isEmpty, "the bar that was read last has nothing piled")
        #expect(state.plan.concealedBundleIDs == [vpn, sync])
    }

    @Test func noAutoOverflowWhileRevealed() async throws {
        // The sync app (two icons, at the right end of the bar) is Hidden, and the weather app, the notes app and the VPN app are Shown.
        // The bar has room for six icons: while the sync app is concealed that is all of them, and revealing it brings two more, which push
        // the weather app's icons out of the bar. That is for the reveal's sake, so the weather app is not moved to Hidden, and the
        // revealed app, which has room, is not asked about.
        var settings = HidingSettings()
        settings.noRoomPolicy = .secondBar
        let rig = SessionRig.withAllowlist(shape: .laptop, capacity: nil,
                                           sections: sections(shown: [weather, notes, vpn], hidden: [sync]), settings: settings)
        await rig.session.start()
        // The first read was taken with every icon on a bar that has room for them.
        rig.world.setCapacity(6)
        #expect(rig.world.concealed == [sync])

        let answer = await rig.session.setReveal(.hiddenShown)
        #expect(answer == .none, "the revealed app has room; another one doesn't, and that is not the reveal's to answer")
        let state = try #require(await rig.state)
        #expect(state.lists.overflow.contains { $0.bundleID == weather }, "the weather app's icons are piled")
        #expect(!state.lists.overflow.contains { $0.bundleID == sync })
        let kept = AppPlacement(section: .shown, isAuto: false)
        #expect(await rig.session.sections.apps[weather] == kept, "and it stays where the person put it")
        #expect(await rig.session.sections.apps[notes] == kept)

        // Collapsed again they fit, and still nothing moved.
        #expect(await rig.session.setReveal(.collapsed) == .none)
        await rig.session.refresh()
        #expect(try #require(await rig.state).lists.overflow.isEmpty)
        #expect(await rig.session.sections.apps[weather] == kept)
        #expect(rig.saved.all.allSatisfy { $0.apps[weather] == kept })
    }

    @Test func displayChangeTriggersTrial() async throws {
        let rig = SessionRig.withAllowlist(shape: .laptop, capacity: 5)
        await rig.session.start()
        let allowlist = try #require(rig.allowlist)
        let moved = AppPlacement(section: .hidden, isAuto: true)
        #expect(await rig.session.sections.apps[weather] == moved)
        let before = allowlist.calls.count
        let reads = await rig.session.scansIngested

        // A bigger display comes: the bar has room for eight icons.
        rig.world.setCapacity(8)
        let changed = Task { await rig.session.displaysChanged(rig.world.layout) }
        #expect(await rig.letTheCoalescedReadGo())
        await changed.value
        // The apps that were moved out are shown again, for a trial: they fit, going by what they were seen to take.
        let trial = AppPlacement(section: .shown, isAuto: true)
        #expect(await rig.session.sections.apps[weather] == trial)
        #expect(await rig.session.sections.apps[notes] == trial)
        // Nothing is concealed for the trial: the assertion is let go.
        #expect(allowlist.calls.count == before)
        #expect(allowlist.live == 0)
        #expect(rig.world.concealed.isEmpty)
        #expect(try #require(await rig.state).plan.concealedBundleIDs.isEmpty)

        // The read of the trial is taken after the trial's assertion was made live, and says they fit: they stay.
        #expect(await rig.pumpUntilReads(reads + 2))
        let kept = AppPlacement(section: .shown, isAuto: false)
        #expect(await rig.session.sections.apps[weather] == kept)
        #expect(await rig.session.sections.apps[notes] == kept)
        #expect(rig.world.concealed.isEmpty)
    }

    // MARK: Refreshing

    @Test func refreshForcesReactivation() async throws {
        // macOS can let go of an assertion without Mantel hearing of it (MenuBarAgent started again, say), and then the bar shows
        // everything while Mantel thinks it is hiding. Refresh makes the plan live again, though it is the plan that is applied.
        let rig = SessionRig.withAllowlist(sections: sections(hidden: [weather], alwaysHidden: [notes]))
        await rig.session.start()
        let allowlist = try #require(rig.allowlist)
        let names = allowed(rig, concealing: [weather, notes])
        #expect(allowlist.calls.map(\.bundleIDs) == [names])
        #expect(allowlist.live == 1)

        await rig.session.refresh()

        #expect(allowlist.calls.map(\.bundleIDs) == [names, names], "the same allowlist, made live once more")
        #expect(allowlist.live == 1, "and the first one let go of")
        #expect(allowlist.invalidations == 1)
        #expect(rig.world.concealed == [weather, notes])
        #expect(await rig.session.engineStatus().lastError == nil)
        // An ordinary rebuild of the same plan makes nothing live.
        await rig.session.setNewItemsSection(.shown)
        #expect(allowlist.calls.count == 2)
    }

    // MARK: Failing

    @Test func engineFailureShowsEverything() async throws {
        let log = CallLog()
        let engine = FakeEngine(.allowlist, log: log)
        engine.failNext(2)
        let rig = SessionRig.withEngines([.allowlist: engine], sections: sections(hidden: [weather]), events: log)
        await rig.session.start()

        // The engine threw, at the first plan and when it was sent again at the second read: each time it was told to show everything,
        // and the state says what went wrong.
        #expect(engine.applied.count == 2)
        #expect(engine.tornDown >= 2)
        let state = try #require(await rig.state)
        #expect(state.engine.lastError?.contains("couldn't hide icons") == true)
        #expect(state.plan.concealedBundleIDs == [weather], "the plan is still what the sections say")
        #expect(await rig.session.engineStatus().lastError != nil)

        // The next plan, the same one even, is tried with the same engine, and it works.
        await rig.session.setNewItemsSection(.shown)
        #expect(engine.applied.count == 3)
        #expect(try #require(await rig.state).engine.lastError == nil)
        #expect(await rig.session.engineStatus().lastError == nil)
    }

    // MARK: The person's changes

    @Test func sectionMovePersistsDefaultProfile() async throws {
        // The sections are kept as the Default profile of profiles.json, as the app keeps them.
        let folder = TemporaryFolder(prefix: "mantel-session")
        let paths = MantelPaths(root: folder.url.appending(path: "Mantel", directoryHint: .isDirectory),
                                logs: folder.url.appending(path: "Logs", directoryHint: .isDirectory))
        try paths.createDirectories()
        let store = SettingsStore(paths: paths, clock: SystemClock(), debounce: .seconds(3600))

        let world = SessionWorld()
        let clock = FakeClock()
        let engine = FakeEngine(.allowlist, log: CallLog())
        let hiding = HidingController(engines: [.allowlist: engine], clock: clock, confirm: { _ in .seen })
        let scanner = MenuBarScanner(ax: world.ax, extrasReader: HoldableExtras(world: world), runningApps: { world.scannerApps },
                                     layout: { world.layout }, ownBundleID: own, isTrusted: { true }, clock: clock, readLimit: 8)
        let session = MenuBarSession(
            scanner: scanner, hiding: hiding, runningApps: { world.sessionApps },
            loadSections: { await store.load(ProfilesDocument.self).active },
            saveSections: { model in
                var document = await store.load(ProfilesDocument.self)
                document.active = model
                await store.save(document)
            },
            turnedOff: { .apps([]) }, settings: HidingSettings(), ownBundleID: own, clock: clock, windows: world.windowList)
        await session.start()
        await session.move(app: weather, to: .alwaysHidden)
        await session.move(item: ItemID(bundleID: notes, key: .index(0)), to: .hidden)
        await session.setNewItemsSection(.hidden)
        await store.flush()

        // A new store over the same folder reads what was written: the Default profile, the active one, holds the sections.
        let reread = SettingsStore(paths: paths, clock: SystemClock(), debounce: .seconds(3600))
        let document = await reread.load(ProfilesDocument.self)
        #expect(document.activeProfileName == "Default")
        #expect(document.profiles.map(\.name) == ["Default"])
        let kept = document.active
        #expect(kept.apps[weather] == AppPlacement(section: .alwaysHidden, isAuto: false))
        #expect(kept.apps[notes] == AppPlacement(section: .hidden, isAuto: false))
        #expect(kept.newItems == .hidden)
        #expect(kept.order[.alwaysHidden]?.contains { $0.bundleID == weather } == true)
        withExtendedLifetime(folder) {}
    }

    @Test func wideScreenShowsEverything() async throws {
        var settings = HidingSettings()
        settings.showEverythingOnWideScreens = true
        settings.wideScreenThreshold = 3000
        let rig = SessionRig.withAllowlist(sections: sections(hidden: [weather], alwaysHidden: [notes]), settings: settings)
        await rig.session.start()
        let allowlist = try #require(rig.allowlist)
        #expect(rig.world.concealed == [weather, notes])

        // The screen the person is working on is 3360 points wide: everything shows, and nothing needs an allowlist.
        await rig.session.frontAppChanged(pid: 1234, activeScreenWidth: 3360)
        #expect(try #require(await rig.state).plan.source == .wideScreen)
        #expect(rig.world.concealed.isEmpty)
        #expect(allowlist.live == 0, "a plan that conceals nothing holds no assertion")

        // On the laptop's 1728 it hides again.
        await rig.session.frontAppChanged(pid: 1234, activeScreenWidth: 1728)
        #expect(try #require(await rig.state).plan.source == .sections)
        #expect(rig.world.concealed == [weather, notes])
        // A screen exactly as wide as the threshold is not wide.
        await rig.session.frontAppChanged(pid: 1234, activeScreenWidth: 3000)
        #expect(try #require(await rig.state).plan.source == .sections)
    }

    @Test func alwaysHiddenEmptyHidesSecondDot() async throws {
        let rig = SessionRig.withAllowlist(sections: sections(hidden: [weather]))
        await rig.session.start()
        #expect(try #require(await rig.state).alwaysHiddenHasApps == false, "Hidden has an app; Always Hidden has none")

        await rig.session.move(app: notes, to: .alwaysHidden)
        #expect(try #require(await rig.state).alwaysHiddenHasApps)
        // Taken out again, the dot goes.
        await rig.session.move(app: notes, to: .shown)
        #expect(try #require(await rig.state).alwaysHiddenHasApps == false)

        // An app that was put there and isn't running has nothing to show.
        await rig.session.move(app: "com.example.ghost", to: .alwaysHidden)
        #expect(try #require(await rig.state).alwaysHiddenHasApps == false)
        // A system item can be put there too.
        await rig.session.move(item: .system("wifi"), to: .alwaysHidden)
        #expect(try #require(await rig.state).alwaysHiddenHasApps)
        await rig.session.move(item: .system("wifi"), to: .shown)
        // The clock can't be, unless the person allows it: it stays on the bar, so it doesn't make the dot.
        await rig.session.move(item: .system("clock"), to: .alwaysHidden)
        #expect(try #require(await rig.state).alwaysHiddenHasApps == false)
    }
}
