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
private let own = SessionWorld.own

/// Room for Mantel's dots, from the session's side: a world in which the dots are the left-most icons (as they are on a real bar, where
/// Hidden and Always Hidden apps take no room) and the bar is a little too narrow, so that macOS puts a dot in the « menu.
///
/// The laptop's bar has room for four of the icons that aren't concealed, counted from the right. Hidden holds the weather app and the
/// notes app, so with the VPN app and the sync app (two icons) Shown, five icons want the bar: the left-most one is a dot.
@Suite("Menu bar session: room for the dots", .timeLimit(.minutes(1)))
struct MenuBarSessionDotsTests {
    private let moved = AppPlacement(section: .hidden, isAuto: true)
    private let leftAlone = AppPlacement(section: .shown, isAuto: false)

    private func rig(shape: SessionWorld.Shape = .laptop, capacity: Int? = 4, automaticOverflow: Bool = true,
                     undrawn: Bool = false, wide: Bool = false) -> SessionRig {
        var settings = HidingSettings()
        settings.automaticOverflow = automaticOverflow
        if wide {
            settings.showEverythingOnWideScreens = true
            settings.wideScreenThreshold = 3000
        }
        return SessionRig.withAllowlist(shape: shape, capacity: capacity, ownFirst: true, undrawn: undrawn,
                                        sections: sections(shown: [vpn, sync], hidden: [weather, notes]), settings: settings)
    }

    /// The reads of a session that starts short of room for a dot. The second of the start is the first to judge the bar, and sees the dot;
    /// the one it asks for confirms it, and makes the room (a dot is made room for only when two reads in a row have it out of the way); and
    /// the one after that is taken after the plan that made the room was applied.
    private static let confirmingRead = SessionRig.readsAtStart + 1
    private static let followUpRead = SessionRig.readsAtStart + 2

    /// Moves the clock on, so that the polling asks for a read, and returns once `reads` reads are in.
    private func pass(_ time: Duration, rig: SessionRig, reads: Int) async -> Bool {
        guard await rig.clock.waitForSleepers(2, within: .seconds(5)) else { return false }
        rig.clock.advance(by: time)
        return await rig.pumpUntilReads(reads)
    }

    private func dotsOverflowedOn(_ state: MenuBarState?) -> Set<String> {
        Set((state?.inventory.items ?? []).filter(\.isMantel).flatMap(\.overflowedOn))
    }

    @Test func trappedDotsMoveTheLeftmostShownAppToHidden() async throws {
        let rig = rig()
        await rig.session.start()

        // The read of the bar once it was collapsed found a dot in the « menu, and no app, and asked for another: nothing was moved on the
        // one sighting. The second had it too: the VPN app is the left-most of the Shown ones on the bar, and it went to Hidden for the
        // dot, as an automatic move. The sync app stays.
        #expect(await rig.waitForReads(Self.confirmingRead))
        #expect(await rig.session.sections.apps[vpn] == moved)
        #expect(await rig.session.sections.apps[sync] == leftAlone)
        let allowlist = try #require(rig.allowlist)
        #expect(allowlist.calls.last?.bundleIDs.contains(vpn) == false, "the plan that was applied conceals it")
        #expect(rig.world.concealed == [weather, notes, vpn])
        #expect(await rig.session.dotsLogLines == [DotsRoomLog.moved(vpn, kind: .builtIn)])
        #expect(DotsRoomLog.moved(vpn, kind: .builtIn)
            == "Mantel's dots were in the « menu on the built-in display; moved com.example.vpn to Hidden to make room")

        // The read that comes after the plan was applied has the dots on the bar.
        #expect(await rig.waitForReads(Self.followUpRead))
        #expect(dotsOverflowedOn(await rig.state).isEmpty)
        #expect(await rig.session.sections.apps[sync] == leftAlone)
    }

    @Test func aSingleSightingOfTheDotsMovesNothing() async throws {
        // The first read to judge the bar has the dot out of the way, and the room is back before the read that would confirm it (the
        // display change's glitch, a timer that went): nothing is moved, and nothing said.
        let rig = rig(capacity: nil)
        await rig.session.start()
        let gate = Gate()
        rig.world.setCapacity(4)
        rig.extras.holdReads(at: gate)
        defer { gate.open() }
        let refreshing = Task { await rig.session.refresh() }
        let extras = rig.extras
        #expect(await waitUntil { extras.readsHeld > 0 }, "the read of the narrow bar is under way")
        rig.world.setCapacity(nil)
        rig.extras.holdReads(at: nil)
        gate.open()
        _ = await refreshing.value
        #expect(await rig.waitForReads(SessionRig.readsAtStart + 2), "the read that was asked for to confirm it has been")
        #expect(await rig.session.sections.apps[vpn] == leftAlone)
        #expect(await rig.session.sections.apps[sync] == leftAlone)
        #expect(await rig.session.dotsLogLines.isEmpty)
    }

    @Test func dotsLeftOfTheNotchTriggerAMove() async throws {
        // As on macOS 27: the icon that doesn't fit has no slot, the bar has no «, and the dot says it is where it would be, left of the
        // notch. That is enough: the left-most Shown app goes to Hidden, and the log says the dots were behind the notch or the menus.
        // The bar has room at first, so what the dots take is known; then it has room for one icon less.
        let rig = rig(capacity: nil, undrawn: true)
        await rig.session.start()
        #expect(await rig.session.dotsLogLines.isEmpty)
        rig.world.setCapacity(4)
        await rig.session.refresh()
        #expect(await rig.waitForReads(SessionRig.readsAtStart + 2), "the refresh's read saw it, and the one it asked for confirmed it")
        #expect(try #require(await rig.state).inventory.chevrons.isEmpty, "no « to go by")
        #expect(await rig.session.sections.apps[vpn] == moved)
        #expect(await rig.session.sections.apps[sync] == leftAlone)
        #expect(await rig.session.dotsLogLines == [DotsRoomLog.moved(vpn, kind: .builtIn, inferred: true)])
        #expect(DotsRoomLog.moved(vpn, kind: .builtIn, inferred: true)
            == "Mantel's dots were behind the notch or the menus on the built-in display; moved com.example.vpn to Hidden to make room")

        // The read that follows has the dots drawn, and nothing more is moved.
        #expect(await rig.waitForReads(SessionRig.readsAtStart + 3))
        #expect(dotsOverflowedOn(await rig.state).isEmpty)
        #expect(await rig.session.sections.apps[sync] == leftAlone)
        #expect(await rig.session.dotsLogLines.count == 1)
    }

    @Test func shownAppLeftOfTheNotchIsAutoMovedOnASingleDisplay() async throws {
        // One display, no « and no slot for the apps that don't fit, and no other bar to line anything up with: the apps say where they
        // would be, left of the notch, and the automatic overflow moves them.
        let rig = SessionRig.withAllowlist(shape: .laptop, capacity: 5, undrawn: true,
                                           sections: sections(shown: [weather, notes, vpn, sync]))
        await rig.session.start()
        // Told by where they say they are, so the first read to see them asks for a second, which moves them.
        #expect(await rig.waitForReads(Self.confirmingRead))
        let inventory = try #require(await rig.state).inventory
        #expect(inventory.chevrons.isEmpty)
        #expect(inventory.bars.count == 1)
        #expect(await rig.session.sections.apps[weather] == moved)
        #expect(await rig.session.sections.apps[notes] == moved)
        #expect(await rig.session.sections.apps[vpn] == leftAlone)
        #expect(await rig.session.sections.apps[sync] == leftAlone)
        // The dots are drawn, so there is nothing to say of them.
        #expect(await rig.session.dotsLogLines.isEmpty)
    }

    @Test func aDotWithNoSlotAndNoMenuIsSaidOnceAndNothingMoves() async throws {
        // As on macOS 27: no « is listed. The dots have no slot on the bar and no place that says where they are (they are not on it at all
        // here), so nothing is moved, and the log says so, once.
        let rig = rig(capacity: 3, undrawn: true)
        rig.world.setHiddenProvider { [weather, notes, own] }
        await rig.session.start()
        let said = [DotsRoomLog.cantTell(kind: .builtIn, reason: .dotHasNoSlot)]
        #expect(await rig.session.dotsLogLines.isEmpty, "the reads of the launch say nothing of it: macOS may not have placed the dots yet")
        #expect(said == ["Mantel's dot has no place on the built-in display's bar (no slot on that bar is one of Mantel's)"])
        #expect(try #require(await rig.state).inventory.chevrons.isEmpty)
        var reads = SessionRig.readsAtStart
        reads += 1
        #expect(await pass(.seconds(10), rig: rig, reads: reads))
        #expect(await rig.session.dotsLogLines.isEmpty, "the dots have had no place on a bar since the launch: not yet")
        reads += 1
        #expect(await pass(MenuBarSession.dotsPlacementWait, rig: rig, reads: reads))
        #expect(await rig.session.dotsLogLines == said, "the wait is over, and the next read says it")
        for _ in 0..<3 {
            reads += 1
            #expect(await pass(.seconds(10), rig: rig, reads: reads))
        }
        #expect(await rig.session.dotsLogLines == said)
        #expect(await rig.session.sections.apps[vpn] == leftAlone)
        #expect(await rig.session.sections.apps[sync] == leftAlone)
    }

    @Test func anAppTurnedOffInSystemSettingsIsNeverJudgedByItsPlace() async throws {
        // macOS doesn't draw an app whose switch is off, whatever the plan says: its icons report places left of the notch (here, as the ones
        // of the apps that don't fit do), and are no sign that it is out of room. The weather app is turned off and isn't moved; the notes
        // app, which is the same to the eye, is.
        let rig = SessionRig.withAllowlist(shape: .laptop, capacity: 5, undrawn: true,
                                           sections: sections(shown: [weather, notes, vpn, sync]))
        rig.turnedOff.set(.apps([weather]))
        await rig.session.start()
        #expect(await rig.waitForReads(Self.confirmingRead))
        #expect(await rig.session.sections.apps[notes] == moved)
        #expect(await rig.session.sections.apps[weather] == leftAlone)
        let inventory = try #require(await rig.state).inventory
        #expect(inventory.items(ofApp: weather).allSatisfy { !$0.isOverflowed })
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

    @Test(arguments: [false, true]) func theFrontAppsMenusMakeAnAppOutOfTheWayAndTheNextFrontAppsGiveItBack(unnamed: Bool) async throws {
        // The weather app says it is at x 1000, right of the notch (it ends at 956.5), where nothing is drawn. With no menus read, nothing
        // says it is out of the way; once the front app is known to have menus out to 1100, its icons are under them.
        let rig = SessionRig.withAllowlist(shape: .laptop, capacity: nil, sections: sections(shown: [weather, notes, vpn, sync]))
        // With no names on the slots (as on macOS 27) the app's place is what its frame says. With names, a slot that names the item is the
        // item's whatever place the app says it is at: it is on the bar, and no menus are over it.
        rig.world.setNameless(unnamed)
        rig.world.setStaleApps([weather], from: 1000)
        await rig.session.start()
        #expect(await rig.session.sections.apps[weather] == leftAlone, "no menus have been read: nothing says it is in the way")
        try await bringToFront(notes, menusTo: 1100, in: rig)
        guard unnamed else {
            // Its slot names it, so it is where the slot is and the menus are not over it: the front app changes nothing.
            #expect(await rig.session.frontAppMenuFrames().map(\.maxX) == [1100])
            #expect(await rig.session.sections.apps[weather] == leftAlone)
            return
        }
        // The read that comes with the front app sees it, and the one it asks for confirms it.
        #expect(await pass(.seconds(10), rig: rig, reads: SessionRig.readsAtStart + 2))
        #expect(await rig.session.sections.apps[weather] == moved)
        #expect(await rig.session.frontAppMenuFrames().map(\.maxX) == [1100])

        // Another app comes to the front, with short menus: the old ones are not kept, and the weather app is tried again.
        try await bringToFront(vpn, menusTo: 600, in: rig)
        #expect(await rig.session.frontAppMenuFrames().map(\.maxX) == [600])
        let allowlist = try #require(rig.allowlist)
        rig.clock.advance(by: .seconds(11))
        #expect(await waitUntil { allowlist.live == 0 }, "the trial's plan conceals nothing")
        #expect(await rig.pumpUntilReads(SessionRig.readsAtStart + 3))
        #expect(await rig.session.sections.apps[weather] == leftAlone, "its place is no longer under any menu: the trial passed")
    }

    @Test func aBarThatAFullScreenAppHasHiddenIsNotJudgedByPlaces() async throws {
        let rig = SessionRig.withAllowlist(shape: .laptop, capacity: 5, undrawn: true,
                                           sections: sections(shown: [weather, notes, vpn, sync]))
        rig.world.setBarShown(0, false)
        await rig.session.start()
        #expect(await rig.session.sections.apps[weather] == leftAlone)
        #expect(await rig.session.sections.apps[notes] == leftAlone)
        // The bar comes back: the next read sees the apps that are out of the way, and the one it asks for moves them.
        rig.world.setBarShown(0, true)
        #expect(await pass(.seconds(10), rig: rig, reads: SessionRig.readsAtStart + 2))
        #expect(await rig.session.sections.apps[weather] == moved)
    }

    @Test func theWindowListIsReadOnlyWhenAReadHasPlacesOrDotsToSayOf() async throws {
        // The desk: the dots and every icon have their slots, and nothing is out of the way. Nothing asks which bars are shown.
        let quiet = rig(shape: .desk, capacity: nil)
        await quiet.session.start()
        #expect(quiet.world.windowReads == 0)
        // The laptop with icons that don't fit: the places are judged on the bars that are shown.
        let narrow = rig(undrawn: true)
        await narrow.session.start()
        #expect(narrow.world.windowReads > 0)
    }

    @Test(arguments: [false, true]) func aHiddenAppsStalePlaceOnTheBarIsNeverJudged(unnamed: Bool) async throws {
        // The weather app and the notes app are Hidden, and concealed by the allowlist, and they go on reporting the places they had on the
        // bar. The plan says they are concealed, and the session tells the scanner, so their places are no places: they are concealed, not
        // overflowed, and the apps that are drawn are as they were.
        let rig = SessionRig.withAllowlist(shape: .laptop, capacity: nil, undrawn: true, staleConcealed: true,
                                           sections: sections(shown: [vpn, sync], hidden: [weather, notes]))
        rig.world.setNameless(unnamed)
        await rig.session.start()
        #expect(rig.world.concealed == [weather, notes])
        let inventory = try #require(await rig.state).inventory
        for app in [weather, notes] {
            #expect(inventory.items(ofApp: app).allSatisfy { $0.isConcealed && !$0.isOverflowed }, "\(app)")
        }
        #expect(try #require(await rig.state).lists.overflow.isEmpty)
        #expect(await rig.session.sections.apps[vpn] == leftAlone)
        #expect(await rig.session.sections.apps[sync] == leftAlone)
        #expect(await rig.session.dotsLogLines.isEmpty)
    }

    @Test(arguments: [false, true]) func aTrialIsNotFailedByAPlaceThatIsWhatItWasBeforeIt(unnamed: Bool) async throws {
        // The weather app is Hidden for want of room, and concealed; its icon says it is left of the notch, and goes on saying so (an app's
        // frames often don't change when it is hidden or shown). A minute on it is put on the bar to see whether it fits: it does, and the
        // place it says is the one it said before, which is no sign that it doesn't.
        var model = sections(shown: [vpn, sync])
        model.apps[weather] = AppPlacement(section: .hidden, isAuto: true)
        let rig = SessionRig.withAllowlist(shape: .laptop, capacity: nil, undrawn: true, sections: model)
        rig.world.setNameless(unnamed)
        rig.world.setStaleApps([weather])
        await rig.session.start()
        let allowlist = try #require(rig.allowlist)
        #expect(rig.world.concealed.contains(weather))
        #expect(await rig.session.sections.apps[weather] == moved, "concealed, and its place isn't judged")

        #expect(await rig.clock.waitForSleepers(2, within: .seconds(5)))
        rig.clock.advance(by: .seconds(60))
        #expect(await waitUntil { allowlist.live == 0 }, "the trial's plan conceals nothing: the allowlist is let go")
        #expect(await rig.pumpUntilReads(SessionRig.readsAtStart + 1))
        #expect(await rig.session.sections.apps[weather] == leftAlone, "the trial passed: it is an ordinary Shown app now")
        // And it stays where it is, read after read.
        var reads = SessionRig.readsAtStart + 1
        for _ in 0..<3 {
            reads += 1
            #expect(await pass(.seconds(60), rig: rig, reads: reads))
        }
        #expect(await rig.session.sections.apps[weather] == leftAlone)
    }

    @Test(arguments: [false, true]) func aTrialIsNotFailedByAPlaceThatMovedAFractionOfAPoint(unnamed: Bool) async throws {
        // As the test before, but the place the app says after the trial began is half a point from the one it said before: that is the
        // same place, as far as what was kept of it goes, and the trial passes on the first read.
        var model = sections(shown: [vpn, sync])
        model.apps[weather] = AppPlacement(section: .hidden, isAuto: true)
        let rig = SessionRig.withAllowlist(shape: .laptop, capacity: nil, undrawn: true, sections: model)
        rig.world.setNameless(unnamed)
        rig.world.setStaleApps([weather])
        await rig.session.start()
        let allowlist = try #require(rig.allowlist)
        #expect(await rig.session.sections.apps[weather] == moved)

        #expect(await rig.clock.waitForSleepers(2, within: .seconds(5)))
        rig.clock.advance(by: .seconds(60))
        #expect(await waitUntil { allowlist.live == 0 }, "the trial has begun")
        rig.world.setStaleApps([weather], from: 484.5)
        #expect(await rig.pumpUntilReads(SessionRig.readsAtStart + 1))
        #expect(await rig.session.sections.apps[weather] == leftAlone, "the trial passed on its first read")
    }

    @Test func theReadTakenForAChangeOfDisplaysDoesNotSayWhereTheDotsCantBePlaced() async throws {
        // A dot with no place on the bar is what a bar that is being made again shows. The read taken for the change doesn't say it in the
        // log; the next read, which agrees, does, and once.
        let rig = rig(capacity: nil)
        await rig.session.start()
        #expect(await rig.session.dotsLogLines.isEmpty)
        rig.world.setCapacity(3)
        rig.world.setHiddenProvider { [weather, notes, own] }

        let changed = Task { await rig.session.displaysChanged(rig.world.layout) }
        #expect(await rig.letTheCoalescedReadGo())
        await changed.value
        #expect(await rig.session.dotsLogLines.isEmpty, "the read taken for the change says nothing of it")

        let said = [DotsRoomLog.cantTell(kind: .builtIn, reason: .ownIconsNotPlaced)]
        var reads = await rig.session.scansIngested
        for _ in 0..<2 {
            reads += 1
            #expect(await pass(.seconds(10), rig: rig, reads: reads))
        }
        #expect(await rig.session.dotsLogLines == said, "the next read agrees, and it is said once")
    }

    @Test func launchReadDoesNotSayNoPlace() async throws {
        // At launch macOS may not have placed Mantel's dots when the bar is first read, and a dot with no place is no finding yet: what the
        // launch's reads (the one before anything is hidden and the one of the bar once it is collapsed) find of the dots isn't said. The
        // next read, if it agrees, says it, and once.
        let rig = rig(capacity: 3, undrawn: true)
        rig.world.setHiddenProvider { [weather, notes, own] }

        await rig.session.start()

        #expect(await rig.session.dotsLogLines.isEmpty, "nothing was said at launch")
        var reads = await rig.session.scansIngested
        #expect(reads == SessionRig.readsAtStart, "both reads of the launch were taken")
        let said = [DotsRoomLog.cantTell(kind: .builtIn, reason: .dotHasNoSlot)]
        reads += 1
        #expect(await pass(.seconds(10), rig: rig, reads: reads))
        #expect(await rig.session.dotsLogLines.isEmpty, "the first read after it finds no dot on a bar either: macOS may still be placing them")
        reads += 1
        #expect(await pass(MenuBarSession.dotsPlacementWait, rig: rig, reads: reads))
        #expect(await rig.session.dotsLogLines == said, "said once the wait for the dots is over")
        for _ in 0..<2 {
            reads += 1
            #expect(await pass(.seconds(10), rig: rig, reads: reads))
        }
        #expect(await rig.session.dotsLogLines == said, "and not again")
    }

    @Test func aDotThatHasNoPlaceIsNotSaidUntilARealReadHasHadTheDotsOnABar() async throws {
        // macOS places the dots some seconds after the launch: while no read has them on a bar, a dot with no place is no finding (it was
        // said at every launch). Once a read has them, one that hasn't is said at once. Nothing else waits: the reads go on as ever.
        let rig = rig(capacity: 3, undrawn: true)
        rig.world.setHiddenProvider { [weather, notes, own] }
        await rig.session.start()
        var reads = await rig.session.scansIngested
        for _ in 0..<2 {
            reads += 1
            #expect(await pass(.seconds(10), rig: rig, reads: reads))
        }
        #expect(await rig.session.dotsLogLines.isEmpty, "twenty seconds on, the dots are not on the bar yet")

        rig.world.setCapacity(nil)
        rig.world.setHiddenProvider { [weather, notes] }
        reads += 1
        #expect(await pass(.seconds(10), rig: rig, reads: reads))
        #expect(await rig.session.dotsLogLines.isEmpty, "the read that has the dots on the bar finds nothing to say")

        rig.world.setCapacity(3)
        rig.world.setHiddenProvider { [weather, notes, own] }
        reads += 1
        #expect(await pass(.seconds(10), rig: rig, reads: reads))
        #expect(await rig.session.dotsLogLines == [DotsRoomLog.cantTell(kind: .builtIn, reason: .dotHasNoSlot)],
                "thirty seconds on, before the wait is over: the dots were placed once, so one that has none now is said")
    }

    @Test func wideScreenPlanNeverMovesShownApps() async throws {
        // "Show every icon on wide screens" is on, and the screen the person works on is wide: the plan draws the Hidden apps too, so the bar
        // is as full as it is when everything shows, and Shown apps and the dots are out of the way on the laptop's bar. That is the wide
        // screen's doing, and nothing says the sections don't fit: no Shown app is moved to Hidden, and none is moved for the dots.
        var settings = HidingSettings()
        settings.showEverythingOnWideScreens = true
        settings.wideScreenThreshold = 3000
        let rig = SessionRig.withAllowlist(shape: .laptop, capacity: nil, ownFirst: true,
                                           sections: sections(shown: [weather, vpn, sync], hidden: [notes]), settings: settings)
        await rig.session.start()
        rig.world.setCapacity(4)
        await rig.session.frontAppChanged(pid: 1234, activeScreenWidth: 3360)
        #expect(try #require(await rig.state).plan.source == .wideScreen)
        #expect(rig.world.concealed.isEmpty, "everything is drawn")

        for _ in 0..<5 {
            #expect(await pass(.seconds(10), rig: rig, reads: await rig.session.scansIngested + 1))
        }
        let crowded = try #require(await rig.state)
        #expect(!dotsOverflowedOn(crowded).isEmpty || crowded.lists.overflow.contains { $0.bundleID == weather },
                "the bar is too full: that is what is not judged")
        for app in [weather, vpn, sync] { #expect(await rig.session.sections.apps[app] == leftAlone, "\(app)") }
        #expect(await rig.session.dotsLogLines.isEmpty, "nothing is said of the dots either")
        #expect(rig.saved.all.allSatisfy { $0.apps.values.allSatisfy { !$0.isAuto } }, "nothing was moved")

        // On the laptop's own width the sections are in force again, and the same bar is judged.
        await rig.session.frontAppChanged(pid: 1234, activeScreenWidth: 1728)
        #expect(try #require(await rig.state).plan.source == .sections)
        var moves = false
        for _ in 0..<8 where !moves {
            #expect(await pass(.seconds(10), rig: rig, reads: await rig.session.scansIngested + 1))
            moves = await rig.session.sections.apps.values.contains { $0.isAuto }
        }
        #expect(moves, "an app is moved once the sections are what the bar shows")
    }

    @Test func wideScreenPlanStartsNoTrial() async throws {
        // The VPN app was moved to Hidden for the dots, and the bar has room again. A wide screen's plan draws it like every other app, so
        // whether it fits the sections' bar is not told by that bar: no trial is started under it (the trial's own read would judge
        // nothing). On the laptop's width one is.
        let rig = rig(wide: true)
        await rig.session.start()
        #expect(await rig.waitForReads(Self.followUpRead))
        #expect(await rig.session.sections.apps[vpn] == moved)
        let allowlist = try #require(rig.allowlist)

        rig.world.setCapacity(nil)
        await rig.session.frontAppChanged(pid: 1234, activeScreenWidth: 3360)
        #expect(try #require(await rig.state).plan.source == .wideScreen)
        var reads = await rig.session.scansIngested
        for _ in 0..<3 {
            #expect(await rig.clock.waitForSleepers(2, within: .seconds(5)))
            reads += 1
            rig.clock.advance(by: .seconds(60))
            #expect(await rig.pumpUntilReads(reads))
            try await Task.sleep(for: .milliseconds(30))
            #expect(await rig.session.sections.apps[vpn] == moved, "no trial under a wide screen's plan")
        }

        await rig.session.frontAppChanged(pid: 1234, activeScreenWidth: 1728)
        #expect(try #require(await rig.state).plan.source == .sections)
        // The bar as the sections make it is read, which is what the room for the app is worked out from.
        #expect(await pass(.seconds(10), rig: rig, reads: await rig.session.scansIngested + 1))
        #expect(await rig.clock.waitForSleepers(2, within: .seconds(5)))
        rig.clock.advance(by: .seconds(60))
        #expect(await waitUntil { allowlist.calls.last?.bundleIDs.contains(vpn) == true }, "the trial's plan shows it")
    }

    @Test func underTheWideSpacerNoAppIsMovedForTheDots() async throws {
        // The spacer pushes icons off the bar on purpose, and its invisible items are Mantel's too: where the dots are is its doing. The
        // dots are in the « menu here, and the left-most Shown app (the notes app) stays; the log says so once.
        let rig = SessionRig.withEngines([.spacer: FakeEngine(.spacer, log: CallLog())], shape: .laptop, capacity: 4, ownFirst: true,
                                         sections: sections(shown: [notes, vpn, sync], hidden: [weather]))
        await rig.session.start()
        #expect(await rig.session.engineStatus().kind == .spacer)
        #expect(!dotsOverflowedOn(await rig.state).isEmpty, "a dot is in the menu")
        let said = [DotsRoomLog.spacerIsInForce(kind: .builtIn)]
        #expect(await rig.session.dotsLogLines == said)
        #expect(said == ["Mantel's dots are in the « menu on the built-in display, and the wide spacer is hiding icons, so no app was moved to make room"])

        var reads = SessionRig.readsAtStart
        for _ in 0..<5 {
            reads += 1
            #expect(await pass(.seconds(10), rig: rig, reads: reads))
        }
        for app in [notes, vpn, sync] { #expect(await rig.session.sections.apps[app] == leftAlone, "\(app)") }
        #expect(await rig.session.dotsLogLines == said)
    }

    @Test func dotsBackOnTheBarStopsMoving() async throws {
        let rig = rig()
        await rig.session.start()
        #expect(await rig.waitForReads(Self.followUpRead))
        #expect(await rig.session.sections.apps[vpn] == moved)
        #expect(dotsOverflowedOn(await rig.state).isEmpty)

        // Read after read, for most of a minute (a trial of the app that was moved is a minute away), with nothing changed: nothing
        // else moves, and nothing more is said.
        let allowlist = try #require(rig.allowlist)
        let applied = allowlist.calls.count
        var reads = Self.followUpRead
        for _ in 0..<5 {
            reads += 1
            #expect(await pass(.seconds(10), rig: rig, reads: reads))
        }
        #expect(await rig.session.sections.apps[sync] == leftAlone)
        #expect(await rig.session.sections.apps[vpn] == moved)
        #expect(await rig.session.dotsLogLines == [DotsRoomLog.moved(vpn, kind: .builtIn)])
        #expect(allowlist.calls.count == applied, "no plan was applied")
    }

    @Test func roomBackReturnsTheAutoAppWithoutFlapping() async throws {
        let rig = rig()
        await rig.session.start()
        #expect(await rig.waitForReads(Self.followUpRead))
        #expect(await rig.session.sections.apps[vpn] == moved)
        let allowlist = try #require(rig.allowlist)

        // The bar has room again (a wider display, say): a minute on, the VPN app is tried on the bar again, and it fits, with the dots.
        rig.world.setCapacity(nil)
        #expect(await rig.clock.waitForSleepers(2, within: .seconds(5)))
        rig.clock.advance(by: .seconds(60))
        #expect(await waitUntil { allowlist.calls.last?.bundleIDs.contains(vpn) == true }, "the trial's plan shows it")
        #expect(await rig.session.sections.apps[vpn] == AppPlacement(section: .shown, isAuto: true))
        #expect(await rig.pumpUntilReads(Self.followUpRead + 1))
        #expect(await rig.session.sections.apps[vpn] == leftAlone, "it fits: it is an ordinary Shown app now")
        #expect(await rig.session.dotsLogLines == [
            DotsRoomLog.moved(vpn, kind: .builtIn), "room is back on the built-in display; com.example.vpn is in Shown again",
        ])

        // No flap afterwards: nothing is applied or said, however long it is.
        let applied = allowlist.calls.count
        var reads = Self.followUpRead + 1
        for _ in 0..<12 {
            reads += 1
            #expect(await pass(.seconds(60), rig: rig, reads: reads))
        }
        #expect(await rig.session.sections.apps[vpn] == leftAlone)
        #expect(await rig.session.dotsLogLines.count == 2)
        #expect(allowlist.calls.count == applied)
    }

    @Test func aTrialThatPushesTheDotsOutAgainIsNotRepeated() async throws {
        let rig = rig()
        await rig.session.start()
        #expect(await rig.waitForReads(Self.followUpRead))
        #expect(await rig.session.sections.apps[vpn] == moved)
        let allowlist = try #require(rig.allowlist)

        // The bar is as narrow as before, but what the app took is less than the room that seems to be there, so it is tried: and the
        // dot goes into the « menu again. The app goes back to Hidden, and it is the one flap there is.
        #expect(await rig.clock.waitForSleepers(2, within: .seconds(5)))
        rig.clock.advance(by: .seconds(60))
        #expect(await waitUntil { allowlist.calls.last?.bundleIDs.contains(vpn) == true })
        // The read that judges the trial has the dot out of the way and leaves the app on trial; the one it asks for says so again, and the
        // app goes back.
        #expect(await rig.pumpUntilReads(Self.followUpRead + 2))
        #expect(await rig.session.sections.apps[vpn] == moved)
        let lines = await rig.session.dotsLogLines
        #expect(lines.count == 2)
        #expect(lines.last == DotsRoomLog.pushedOutAgain(vpn, kind: .builtIn))

        // Not tried again, a minute or ten minutes on.
        let applied = allowlist.calls.count
        var reads = Self.followUpRead + 2
        for _ in 0..<10 {
            reads += 1
            #expect(await pass(.seconds(60), rig: rig, reads: reads))
        }
        #expect(await rig.session.sections.apps[vpn] == moved)
        #expect(allowlist.calls.count == applied)
        #expect(await rig.session.dotsLogLines.count == 2)
    }

    @Test func aSecondaryNotchedBarCounts() async throws {
        // The lid is open beside the desk: the desk's bars have room and the laptop's, the third, doesn't. A dot in its « menu is a dot
        // in a « menu, whichever display is the main one.
        let rig = rig(shape: .deskWithLaptopOpen)
        await rig.session.start()
        #expect(await rig.waitForReads(Self.confirmingRead))
        #expect(await rig.session.sections.apps[vpn] == moved)
        #expect(await rig.session.sections.apps[sync] == leftAlone)
        #expect(await rig.session.dotsLogLines == [DotsRoomLog.moved(vpn, kind: .builtIn)])
        // The menu was the laptop's.
        #expect(await rig.waitForReads(Self.followUpRead))
        #expect(dotsOverflowedOn(await rig.state).isEmpty)
    }

    @Test func aBarThatAFullScreenAppHasHiddenHasNoDotsToMakeRoomFor() async throws {
        let rig = rig(shape: .deskWithLaptopOpen)
        rig.world.setBarShown(2, false)
        await rig.session.start()
        #expect(await rig.session.sections.apps[vpn] == leftAlone)
        #expect(await rig.session.sections.apps[sync] == leftAlone)
        #expect(await rig.session.dotsLogLines.isEmpty)

        // The bar comes back, and with the next two reads the dot is made room for.
        rig.world.setBarShown(2, true)
        #expect(await pass(.seconds(10), rig: rig, reads: SessionRig.readsAtStart + 2))
        #expect(await rig.session.sections.apps[vpn] == moved)
    }

    @Test func cantTellIsLoggedOnceAndDoesNothing() async throws {
        // The « shows, nothing in it is an app, and Mantel's own icons are nowhere on the bar (they have no place on it): they could be in
        // the menu, and that can't be told. It is said once for as long as Mantel runs, and nothing moves.
        let rig = rig(capacity: 3)
        rig.world.setHiddenProvider { [weather, notes, own] }
        await rig.session.start()
        let said = [DotsRoomLog.cantTell(kind: .builtIn, reason: .ownIconsNotPlaced)]
        #expect(await rig.session.dotsLogLines.isEmpty, "not by the reads of the launch")
        #expect(said == ["the « menu is showing on the built-in display but Mantel can't tell what is in it (Mantel's own icons couldn't be placed on that bar)"])

        var reads = SessionRig.readsAtStart
        reads += 1
        #expect(await pass(.seconds(10), rig: rig, reads: reads))
        #expect(await rig.session.dotsLogLines.isEmpty, "nor by the next, while no read has had the dots on a bar")
        reads += 1
        #expect(await pass(MenuBarSession.dotsPlacementWait, rig: rig, reads: reads))
        #expect(await rig.session.dotsLogLines == said)
        for _ in 0..<4 {
            reads += 1
            #expect(await pass(.seconds(10), rig: rig, reads: reads))
        }
        #expect(await rig.session.dotsLogLines == said)
        #expect(await rig.session.sections.apps[vpn] == leftAlone)
        #expect(await rig.session.sections.apps[sync] == leftAlone)
        #expect(rig.saved.all.allSatisfy { $0.apps.values.allSatisfy { !$0.isAuto } }, "nothing was moved")
    }

    @Test func automaticOverflowOffOnlyLogs() async throws {
        let rig = rig(automaticOverflow: false)
        await rig.session.start()
        #expect(await rig.session.sections.apps[vpn] == leftAlone)
        #expect(await rig.session.sections.apps[sync] == leftAlone)
        #expect(rig.world.concealed == [weather, notes])
        let said = [DotsRoomLog.automaticOverflowIsOff(kind: .builtIn)]
        #expect(await rig.session.dotsLogLines == said)

        // The dot stays in the « menu, and every read finds it: it is said once.
        var reads = SessionRig.readsAtStart
        for _ in 0..<4 {
            reads += 1
            #expect(await pass(.seconds(10), rig: rig, reads: reads))
        }
        #expect(!dotsOverflowedOn(await rig.state).isEmpty, "the dot is still in the menu")
        #expect(await rig.session.dotsLogLines == said)
        #expect(await rig.session.sections.apps[vpn] == leftAlone)
        #expect(rig.saved.all.allSatisfy { $0.apps.values.allSatisfy { !$0.isAuto } }, "nothing was moved")
    }

    @Test func dotsAreNotMadeRoomForWhileRevealed() async throws {
        // A reveal moves icons for a reason of its own: what a read finds then is not a verdict on the sections.
        let rig = rig()
        rig.world.setCapacity(nil)
        await rig.session.start()
        rig.world.setCapacity(4)
        _ = await rig.session.setReveal(.hiddenShown)
        #expect(await rig.session.sections.apps[vpn] == leftAlone)
        #expect(await rig.session.dotsLogLines.isEmpty)
    }
}
