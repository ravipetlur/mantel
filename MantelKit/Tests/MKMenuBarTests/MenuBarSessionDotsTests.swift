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
@Suite("Menu bar session: room for the dots", .serialized, .timeLimit(.minutes(1)))
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
