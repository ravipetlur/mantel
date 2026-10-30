import CoreGraphics
import Foundation
import MKCommands
import MKCore
import MKLayout
import MKTestSupport
import Synchronization
import Testing

@testable import MKMenuBar

private let weather = SessionWorld.weather
private let notes = SessionWorld.notes
private let own = SessionWorld.own
private let vpn = SessionWorld.vpn
private let sync = SessionWorld.sync
/// The owner of the system's items, which are told by the name of their slots and not by an app's frame.
private let system = ItemID.systemBundleID

/// What the bar had concealed each time a strip was taken.
private final class ConcealedLog: Sendable {
    private let taken = Mutex<[Set<String>]>([])

    var last: Set<String>? { taken.withLock { $0.last } }
    func add(_ concealed: Set<String>) { taken.withLock { $0.append(concealed) } }
}

/// A strip capture that notes in the session's log that it was asked, and what the world conceals at that moment, and otherwise is a
/// `FakeCapture`.
private struct LoggingCapture: StripCapturing {
    let inner: FakeCapture
    let events: CallLog
    let world: SessionWorld
    let concealedWhenTaken: ConcealedLog

    func capture(bar: MenuBarGeometry, display: DisplayInfo, layout: DisplayLayout) async throws -> CGImage {
        events.add("capture")
        let concealed = world.concealed
        concealedWhenTaken.add(concealed)
        return try await inner.capture(bar: bar, display: display, layout: layout)
    }
}

/// How many times something was asked.
private final class Counter: Sendable {
    private let count = Mutex(0)

    var value: Int { count.withLock { $0 } }
    func add() { count.withLock { $0 += 1 } }
}

/// A session, and what takes the pictures of its icons: a collector over a fake capture and a store in a temporary folder.
private struct CaptureRig {
    let rig: SessionRig
    let capture: FakeCapture
    let store: ItemImageStore
    let collector: ItemImageCollector
    let folder: TemporaryFolder
    /// The apps the bar had concealed each time a strip was taken.
    let concealedWhenTaken = ConcealedLog()
    /// How many times the collector was asked to capture, whether it took a strip or not (it asks `mayCapture` first, every time).
    let asked = Counter()

    var session: MenuBarSession { rig.session }

    init(_ rig: SessionRig, rules: CaptureRules = .measured, granted: Bool = true) async {
        self.rig = rig
        let capture = FakeCapture(clock: rig.clock)
        let folder = TemporaryFolder(prefix: "mantel-session-capture")
        let store = ItemImageStore(folder: folder.url.appending(path: "ItemImages", directoryHint: .isDirectory), clock: rig.clock)
        let world = rig.world
        let asked = asked
        collector = ItemImageCollector(store: store,
                                       capture: LoggingCapture(inner: capture, events: rig.events, world: world, concealedWhenTaken: concealedWhenTaken),
                                       layout: { world.layout }, windows: world.windowList, screenRecordingGranted: { granted },
                                       mayCapture: { asked.add(); return nil }, clock: rig.clock, rules: rules)
        self.capture = capture
        self.store = store
        self.folder = folder
        await rig.session.setImageCollector(collector)
        // A bar that changes under a capture is taken again when it is still; most of these tests are of the first try.
        await rig.session.setCaptureTries(1)
        await rig.session.setBarDrawnWait(.zero)
    }

    /// Every icon of every bar gets something to be cropped: discs along each bar, spaced closer than a slot is wide.
    func paintEverything() {
        var rects: [CGRect] = []
        for bar in rig.world.fixture().bars {
            var x = bar.minX
            while x < bar.maxX {
                rects.append(CGRect(x: x, y: bar.minY, width: 24, height: bar.height))
                x += 16
            }
        }
        capture.paint(rects)
    }

    /// The apps that have a picture kept.
    func appsWithPictures() async -> Set<String> {
        Set(await store.records().map(\.item.bundleID))
    }

    /// Returns when the captures the session started on tasks of their own are done.
    func capturesFinished() async {
        await session.capturesFinished()
    }

    /// A follow-up of the reveal, with the clock moved on for the look that doesn't see it: the follow-up waits for as long as the session
    /// allows, and that wait is on the clock.
    func followUpThroughTheWait(_ applied: AppliedReveal) async -> NoRoomAction {
        let clock = rig.clock
        let asleep = clock.sleeperCount
        let session = session
        let following = Task { await session.followUp(applied) }
        #expect(await clock.waitForSleepers(asleep + 1, within: .seconds(5)), "the look is waiting to look again")
        clock.advance(by: .seconds(10))
        return await following.value
    }
}

/// Where the session takes the pictures of the icons: at launch, when a reveal was seen, when Settings opens and when asked to
/// recapture.
@Suite("Menu bar session: capture moments", .timeLimit(.minutes(1)))
struct MenuBarSessionCaptureTests {
    // MARK: The check of the saved icons

    @Test func theCheckOfSeveralAppsDealsWithTheirPicturesInOneReconcile() async throws {
        // Two apps' saved icons are checked at the first read: the records they hold that the apps don't list are taken out, and the pictures
        // of them are dealt with in one go (one write of the index, one announcement), not one app after the other.
        // The notes app's dropped record is one by index (a second icon it doesn't list now): only such a record's picture is handed on.
        let phantom = ItemID(bundleID: weather, key: .identifier("x.phantom")), other = ItemID(bundleID: notes, key: .index(1))
        var initial = sections(shown: [weather, notes, vpn, sync])
        initial.noteIcons([phantom, other])
        initial.unchecked = [weather, notes]
        let rig = SessionRig.withAllowlist(sections: initial)
        let captures = await CaptureRig(rig, granted: false)
        try await captures.store.save(mattedDisc(), scale: 2, for: phantom, appItemCount: 2)
        try await captures.store.save(mattedDisc(), scale: 2, for: other, appItemCount: 1)

        let announced = Mutex<[Set<ItemID>]>([])
        let marker = ItemID(bundleID: "com.example.marker", key: .index(0))
        let done = Gate()
        let changes = await captures.store.changes()
        let listening = Task {
            for await changed in changes {
                if changed == [marker] { return done.open() }
                announced.withLock { $0.append(changed) }
            }
        }
        defer { listening.cancel() }
        await captures.session.start()
        try await captures.store.save(mattedDisc(), scale: 2, for: marker, appItemCount: 1)
        await done.wait()

        let seen = announced.withLock { $0 }
        #expect(seen.count == 1, "one reconcile: \(seen)")
        #expect(seen.first?.isSuperset(of: [phantom, other]) == true)
        #expect(await captures.store.record(for: phantom) == nil)
        #expect(await captures.store.record(for: other) == nil, "and the notes app's one icon has its picture")
        #expect(await captures.store.record(for: ItemID(bundleID: notes, key: .index(0))) != nil)
    }

    // MARK: Launch

    @Test func launchCaptureComesBeforeFirstApply() async throws {
        let rig = SessionRig.withAllowlist(sections: sections(hidden: [weather]))
        let captures = await CaptureRig(rig)

        await captures.session.start()

        let log = rig.events.all
        let firstCapture = try #require(log.firstIndex(of: "capture"))
        let firstApply = try #require(log.firstIndex(of: "apply"))
        #expect(firstCapture < firstApply, "the picture was taken while everything was on the bar: \(log)")
        #expect(log.filter { $0 == "capture" }.count == 1, "the launch is captured once, though it takes two reads")
    }

    /// Starts a session whose capture never comes back, and moves the clock to a millisecond short of `budget`, and then past it. The
    /// plan waits until then, and not longer.
    private func startWithACaptureThatNeverReturns(shape: SessionWorld.Shape, budget: Duration) async throws -> (CaptureRig, SessionRig) {
        let rig = SessionRig.withAllowlist(shape: shape, sections: sections(hidden: [weather]))
        let captures = await CaptureRig(rig)
        captures.capture.hang(true)
        let clock = rig.clock

        let starting = Task { await rig.session.start() }
        // The strip is being taken (and never comes), and the budget's timer, the collector's own and the capture itself are asleep.
        #expect(await clock.waitForSleepers(3, within: .seconds(5)))
        let asleep = clock.sleeperCount
        clock.advance(by: budget - .milliseconds(1))
        // Anything that was due has woken by now (the clock wakes sleepers as it moves): none was, so the budget isn't over.
        #expect(clock.sleeperCount == asleep, "a millisecond short of the budget the start is still waiting")
        #expect(!rig.events.all.contains("apply"), "and no plan was applied")

        clock.advance(by: .milliseconds(2))
        await starting.value
        #expect(rig.events.all.contains("apply"), "the plan applied though the capture never came back")
        captures.capture.hang(false)
        clock.advance(by: .seconds(11))
        return (captures, rig)
    }

    @Test func launchCaptureIsBounded() async throws {
        // Two bars are shown: the budget is 2 × 226 ms.
        let (captures, rig) = try await startWithACaptureThatNeverReturns(shape: .desk, budget: .milliseconds(452))

        #expect(try #require(await rig.state).plan.source == .sections)
        #expect(rig.events.all.contains("apply"))
        #expect(await captures.store.records().isEmpty)
    }

    @Test(arguments: [(SessionWorld.Shape.laptop, 226), (SessionWorld.Shape.desk, 452)])
    func launchBudgetFollowsTheShownBars(shape: SessionWorld.Shape, milliseconds: Int) async throws {
        _ = try await startWithACaptureThatNeverReturns(shape: shape, budget: .milliseconds(milliseconds))
    }

    @Test func launchBudgetIsEachBarsShareUpToTheCap() {
        let rules = CaptureRules.measured
        #expect(rules.budget(forShownBars: 1) == .milliseconds(226))
        #expect(rules.budget(forShownBars: 2) == .milliseconds(452))
        #expect(rules.budget(forShownBars: 3) == .milliseconds(678))
        #expect(rules.budget(forShownBars: 5) == .seconds(1), "never more than a second")
        #expect(rules.budget(forShownBars: 0) == .milliseconds(226), "a bar's share at the least")
        // Rules with one budget keep it whatever the bars.
        #expect(CaptureRules.provisional.budget(forShownBars: 1) == .seconds(1))
        #expect(CaptureRules.provisional.budget(forShownBars: 3) == .seconds(1))
    }

    @Test func measuredRulesTakeEveryMomentAndKeepNoQuietPeriod() {
        let rules = CaptureRules.measured
        #expect(rules.moments == Set(CaptureMomentKind.allCases))
        #expect(rules.indicatorQuietPeriod == nil)
        #expect(rules.perBarInterval == .seconds(2))
        #expect(rules.launchBudget == .seconds(1))
        #expect(CaptureRules.provisional.moments == Set(CaptureMomentKind.allCases))
    }

    @Test func launchCapturesTheActiveDisplaysBarOnly() async throws {
        // The apps' own frames are on the first display's bar: it is the active one, and the other draws its icons translucent.
        let rig = SessionRig.withAllowlist(sections: sections(hidden: [weather]))
        let captures = await CaptureRig(rig)

        await captures.session.start()

        let inventory = try #require(await rig.state).inventory
        let active = try #require(inventory.activeDisplay)
        #expect(inventory.bars.count == 2)
        #expect(captures.capture.displays == [active], "one strip, of the active display")
    }

    @Test func aLaunchStripPastTheBudgetIsNotCropped() async throws {
        // The strip comes back at 500 ms, and the budget of one bar is 226 ms: the first plan has applied by then, and the bar has
        // changed. Hidden apps' icons were pushed out, and the ones to their right slid left into their slots: cropping the launch's
        // slots from it would save one app's icon under another's.
        let rig = SessionRig.withAllowlist(shape: .laptop, sections: sections(hidden: [weather]))
        let captures = await CaptureRig(rig)
        captures.paintEverything()
        captures.capture.delay(.milliseconds(500))
        let clock = rig.clock

        let starting = Task { await rig.session.start() }
        // The budget's timer, the collector's own and the capture are asleep.
        #expect(await clock.waitForSleepers(3, within: .seconds(5)))
        clock.advance(by: .milliseconds(226))
        await starting.value
        #expect(rig.events.all.contains("apply"), "the plan was applied at the budget")

        // The strip comes back at 500 ms; nothing is looked at until the launch capture is over.
        clock.advance(by: .milliseconds(274))
        await captures.capturesFinished()
        #expect(await captures.collector.lastCaptureAt == nil)
        #expect(await captures.store.records().isEmpty, "nothing was cropped from the strip that came late")
        #expect(captures.capture.displays.count == 1, "the strip was taken, and it came back late")
    }

    @Test func aLaunchIsNotCapturedAfterThePlanApplied() async throws {
        // The first read has no bar (Accessibility isn't granted yet), so the first plan applies at once, and the second read of the
        // launch is taken just after it, while the bar is still moving. It is left to the moments that follow.
        let trusted = Switch(false)
        let rig = SessionRig.withAllowlist(sections: sections(hidden: [weather]), trusted: trusted)
        let captures = await CaptureRig(rig)
        captures.paintEverything()
        let allowlist = try #require(rig.allowlist)
        let events = rig.events
        allowlist.onActivated {
            events.add("apply")
            trusted.set(true)
        }

        await captures.session.start()

        let inventory = try #require(await rig.state).inventory
        #expect(!inventory.bars.isEmpty, "the second read had the bars")
        #expect(captures.capture.displays.isEmpty, "no strip was taken")
        #expect(await captures.store.records().isEmpty)
    }

    @Test func captureDropsPicturesWhoseIdentityMayHaveMoved() async throws {
        let rig = SessionRig.withAllowlist(sections: sections(hidden: [weather]))
        let captures = await CaptureRig(rig)
        // A picture of the notes app's item by its place, taken when the app had five items: it has one now.
        let moved = ItemID(bundleID: notes, key: .index(3))
        try await captures.store.save(mattedDisc(), scale: 2, for: moved, appItemCount: 5)
        #expect(await captures.store.record(for: moved) != nil)

        await captures.session.start()

        #expect(await captures.store.record(for: moved) == nil)
    }

    @Test func mantelsOwnItemsAreNeverCaptured() async throws {
        let rig = SessionRig.withAllowlist(ownFirst: true, sections: sections(hidden: [weather]))
        let captures = await CaptureRig(rig)
        captures.paintEverything()

        await captures.session.start()

        let apps = await captures.appsWithPictures()
        #expect(!apps.isEmpty, "the other icons were captured")
        #expect(!apps.contains(own), "Mantel draws its own")
        #expect(!apps.contains(OwnItems.owner))
    }

    // MARK: A reveal that was seen

    @Test func revealSeenCapturesRevealedApps() async throws {
        let rig = SessionRig.withAllowlist(sections: sections(hidden: [weather]))
        let captures = await CaptureRig(rig)
        await captures.session.start()
        #expect(await captures.store.records().isEmpty, "nothing could be cropped from the launch's flat strip")
        captures.paintEverything()
        rig.clock.advance(by: .seconds(3))

        let applied = await captures.session.applyReveal(.hiddenShown)
        #expect(await captures.session.followUp(applied) == .none)

        await captures.capturesFinished()
        #expect(await captures.appsWithPictures() == [weather], "the revealed apps, and no others")
    }

    @Test func revealNotSeenCapturesNothing() async throws {
        // The weather app never shows on the bar: the follow-up looks for it for as long as it may, and doesn't see it. A bar whose
        // icons haven't settled isn't captured: the collector isn't even asked (it asks `mayCapture` first, every time).
        let engine = FakeEngine(.allowlist, log: CallLog())
        let rig = SessionRig.withEngines([.allowlist: engine], sections: sections(hidden: [weather]))
        rig.world.setHiddenProvider { [weather] }
        let captures = await CaptureRig(rig)
        await captures.session.start()
        captures.paintEverything()
        rig.clock.advance(by: .seconds(3))
        let asked = captures.asked.value
        #expect(asked == 1, "the launch asked")

        let applied = await captures.session.applyReveal(.hiddenShown)
        _ = await captures.followUpThroughTheWait(applied)
        await captures.capturesFinished()

        #expect(captures.asked.value == asked, "no capture was asked for")
        #expect(captures.capture.displays.count == 1, "no strip was taken but the launch's")
        #expect(await captures.store.records().isEmpty)
    }

    @Test func aRevealThatMakesRoomIsCapturedAfterTheRoomIsMade() async throws {
        // The desk's bar draws every revealed icon, and the look at it says so; the laptop's bar has no room, and the policy is to make
        // it by concealing Shown apps. The icons on the desk's bar slide when that plan applies: the pictures are of the bar after it.
        var settings = HidingSettings()
        settings.automaticOverflow = false
        settings.noRoomPolicy = .swap
        let rig = SessionRig.withAllowlist(shape: .deskWithLaptopOpen, capacity: 5,
                                           sections: sections(shown: [vpn, sync], hidden: [weather, notes]), settings: settings)
        let captures = await CaptureRig(rig)
        await captures.session.start()
        captures.paintEverything()
        rig.clock.advance(by: .seconds(3))
        let strips = captures.capture.displays.count

        let applied = await captures.session.applyReveal(.hiddenShown)
        #expect(await captures.session.followUp(applied) == .none)
        await captures.capturesFinished()

        #expect(await captures.session.swapConcealed.contains(sync), "the right-most Shown app was concealed to make room")
        #expect(captures.capture.displays.count == strips + 1, "one strip for the reveal")
        #expect(captures.concealedWhenTaken.last?.contains(sync) == true, "taken after the room was made")
        #expect(await captures.appsWithPictures().isSuperset(of: [weather, notes]), "the revealed apps")
    }

    @Test func aStripThatComesBackAfterTheRevealEndedIsNotCropped() async throws {
        let rig = SessionRig.withAllowlist(sections: sections(hidden: [weather]))
        let captures = await CaptureRig(rig)
        await captures.session.start()
        captures.paintEverything()
        rig.clock.advance(by: .seconds(3))
        let gate = Gate(), entered = Gate()
        defer { gate.open() }
        captures.capture.hold(at: gate, entered: entered)

        let applied = await captures.session.applyReveal(.hiddenShown)
        #expect(await captures.session.followUp(applied) == .none)
        await entered.wait()
        // The reveal is over while the strip is being taken: the icons go back, and others slide into the places they were in.
        #expect(await captures.session.setReveal(.collapsed) == .none)
        gate.open()
        await captures.capturesFinished()

        #expect(await captures.store.records().isEmpty, "no picture was kept: the bar is not the one the slots were read from")
    }

    @Test func aStripThatComesBackAfterAPlanWasAppliedIsNotCropped() async throws {
        let rig = SessionRig.withAllowlist(sections: sections(hidden: [weather]))
        let captures = await CaptureRig(rig)
        await captures.session.start()
        captures.paintEverything()
        rig.clock.advance(by: .seconds(3))
        let gate = Gate(), entered = Gate()
        defer { gate.open() }
        captures.capture.hold(at: gate, entered: entered)

        await captures.session.setSettingsOpen(true)
        await entered.wait()
        // The read for Settings is of the bar as it was; a reveal is applied while its strip is being taken.
        _ = await captures.session.applyReveal(.hiddenShown)
        gate.open()
        await captures.capturesFinished()

        #expect(await captures.store.records().isEmpty)
        // Nothing was kept, so the bar isn't held to the throttle: it can be taken again at once.
        captures.capture.hold(at: nil)
        await captures.session.setSettingsOpen(true)
        await captures.capturesFinished()
        #expect(await captures.collector.lastCaptureAt != nil, "taken again")
    }


    // MARK: A bar that moves under a strip

    /// A started session over `rig`, whose bar is painted. Settings opens, and its strip is held while `reflow` changes the world in a way
    /// that is none of the session's plans; then the strip is let go. The apps that have a picture after, and the rig.
    private func settingsStrip(over rig: SessionRig, beforeTheRead: (SessionWorld) -> Void = { _ in },
                               reflow: (SessionWorld) -> Void) async -> (CaptureRig, Set<String>) {
        let captures = await CaptureRig(rig)
        await captures.session.start()
        captures.paintEverything()
        rig.clock.advance(by: .seconds(3))
        let gate = Gate(), entered = Gate()
        captures.capture.hold(at: gate, entered: entered)

        beforeTheRead(rig.world)
        await captures.session.setSettingsOpen(true)
        await entered.wait()
        rig.extras.forgetAppsAsked()
        reflow(rig.world)
        gate.open()
        await finishCapturing(captures)
        return (captures, await captures.appsWithPictures())
    }

    /// Returns when the captures the session started are over. The check that follows a strip asks the bar again after a pause when
    /// what is left of it isn't settled (`StillCurrentWatch`), and the pauses are on the session's clock: it is moved as they come.
    private func finishCapturing(_ captures: CaptureRig) async {
        let over = Mutex(false)
        let waiting = Task {
            await captures.capturesFinished()
            over.withLock { $0 = true }
        }
        #expect(await captures.rig.driveClock(step: StillCurrentWatch.settleWait) { over.withLock { $0 } }, "the captures were over")
        await waiting.value
    }

    private static let dots = [OwnItems.hiddenDotName, OwnItems.alwaysDotName]

    @Test func mantelsDotsThatComeLeftOfTheCroppedIconsCostThemNothing() async throws {
        // The bar is right-aligned: the dots, Mantel's own and told by their names, arrive at its left end and slide none of the others.
        let rig = SessionRig.withAllowlist(sections: sections())
        let dots = Self.dots
        let (_, apps) = await settingsStrip(over: rig, beforeTheRead: { $0.setItemOrder(dots); $0.setOwnItems(listed: [], omitted: Set(dots)) },
                                            reflow: { $0.setOwnItems(listed: [], omitted: []) })
        #expect(apps == [weather, notes, vpn, sync, system], "the dots are left of every one of them: \(apps)")
    }

    @Test(arguments: [false, true]) func mantelsDotsThatComeBetweenCostOnlyTheIconsLeftOfThem(unnamed: Bool) async throws {
        // The dots arrive between the weather app's icons and the notes app's (the launch's change): the weather app's slide left by what
        // they take, and the pictures of the others, right of them, are kept. The log says whose slots came, which icons moved, and by how
        // much. With `unnamed` the apps' slots have no names, as on macOS 27: each dot lies in the frame of a nameless icon that slid, and
        // the walk must not pair them (the owner's bar).
        let rig = SessionRig.withAllowlist(sections: sections())
        rig.world.setNameless(unnamed)
        let dots = Self.dots
        let order = ["weather.temp", "weather.alerts"] + dots
        let result = Mutex<Set<String>>([])
        let lines = await LogCapture.lines {
            let (_, apps) = await self.settingsStrip(over: rig, beforeTheRead: { $0.setItemOrder(order); $0.setOwnItems(listed: [], omitted: Set(dots)) },
                                                     reflow: { $0.setOwnItems(listed: [], omitted: []) })
            result.withLock { $0 = apps }
        }
        #expect(result.withLock { $0 } == [notes, vpn, sync, system], "not the weather app's: its icons are where others' were")
        // The lines other tests log meanwhile are in the capture too: this one's is the one that left the weather app's picture out, alone.
        let line = try #require(lines.first { $0.contains("[capture] captured") && $0.contains("not kept: \(weather) (slots ") })
        #expect(line.contains("the left end moved 88 pt left"), "\(line)")
        #expect(line.contains("Mantel's own came: mantel.dot.hidden, mantel.dot.always"), "\(line)")
    }

    @Test func aSlotOfAnAppsThatComesBackLeftOfTheCroppedIconsCostsEveryPicture() async throws {
        // The weather app's icons come back (the allowlist is lifted) left of the others. In the fixture a concealed app keeps its room, so
        // nothing slides: the two slots that came are an app's, not Mantel's, and that is all or nothing, whatever the slides would have been
        // (an icon of one width that came between two looks the same to the walk from the right as one at the left end).
        let rig = SessionRig.withAllowlist(sections: sections(hidden: [weather]))
        let lines = await LogCapture.lines {
            let (_, apps) = await self.settingsStrip(over: rig, reflow: { $0.setHiddenProvider { [] } })
            #expect(apps.isEmpty, "no picture, under an item that isn't the one in it: \(apps)")
        }
        let line = try #require(lines.first { $0.contains("nothing captured at settingsOpened") && $0.contains("slots that aren't Mantel's came or went") })
        #expect(line.contains("The bar changed while it was captured (slots "), "\(line)")
    }

    @Test(arguments: [false, true]) func aTestItemThatQuitsRightOfTwoAppsKeepsNothingWhoseverFramesFollow(lagging: Bool) async throws {
        // Unnamed icons of one width (the weather app's, the notes app's, the VPN app's) sit left of the test item's
        // two, which quit: each of them slides right into the frame of the one right of it, and the test item's own named slots are
        // matched by the walk from the right with the nameless slots that slid into their frames. The walk stops only at the weather app's
        // two. Where the apps' frames lag (they still say where the icons were), they lie in the slots the read gave them: only the slots
        // can tell, and they can't, so nothing is kept (the system's items too).
        let rig = SessionRig.withAllowlist(testItem: true, sections: sections(hidden: []))
        rig.world.setNameless(true)
        let order = ["weather.temp", "weather.alerts", "Notes", "_NS:93", "mantel.fixture.one", "mantel.fixture.two"]
        let lines = await LogCapture.lines {
            let (_, apps) = await self.settingsStrip(over: rig, beforeTheRead: { $0.setItemOrder(order) }, reflow: { world in
                world.setTestItemRunning(false)
                if lagging { world.setFrameShifts([notes: -88, vpn: -88]) }
            })
            #expect(apps.isEmpty, "nothing is kept: \(apps)")
        }
        let line = try #require(lines.first { $0.contains("nothing captured at settingsOpened") && $0.contains("slots 17 -> 15") })
        #expect(line.contains("slots 17 -> 15: 2 left of x 2646 differ (none there now)"), "the walk stopped at the weather app's two: \(line)")
    }

    @Test(arguments: [false, true]) func aShownIconThatGoesRightOfARunOfIconsThatReachesTheDotsKeepsNothingWhoseverFramesFollow(lagging: Bool) async throws {
        // The dots sit just left of the notes app's and the VPN app's icons, which sit left of the test item's two, and no app's slot has a
        // name (macOS 27). The test item quits: the VPN app's, the notes app's and each dot slide right into the frame of the one right of
        // it, and the walk, which would pair a dot with the nameless slot of its width, would run on to the left end and call what it
        // passed unmoved. It stops at the dot. Where the apps' frames lag, the notes app's and the VPN app's lie in the slots that hold
        // the dots now: nothing may be kept, whoever's frames those are.
        let rig = SessionRig.withAllowlist(testItem: true, sections: sections(hidden: []))
        rig.world.setNameless(true)
        let order = Self.dots + ["Notes", "_NS:93", "mantel.fixture.one", "mantel.fixture.two"]
        let lines = await LogCapture.lines {
            let (_, apps) = await self.settingsStrip(over: rig, beforeTheRead: { $0.setItemOrder(order) }, reflow: { world in
                world.setTestItemRunning(false)
                if lagging { world.setFrameShifts([notes: -88, vpn: -88]) }
            })
            #expect(apps.isEmpty, "nothing is kept: \(apps)")
        }
        let line = try #require(lines.first { $0.contains("nothing captured at settingsOpened") && $0.contains("slots 17 -> 15") })
        #expect(line.contains("slots that aren't Mantel's came or went"), "\(line)")
    }

    @Test func aMissSaysWhatMantelDidWhenItChangedTheBar() async throws {
        let rig = SessionRig.withAllowlist(sections: sections(hidden: [weather]))
        let captures = await started(rig)
        let result = Mutex<CaptureSummary?>(nil)
        let lines = await LogCapture.lines {
            let summary = try? await self.settingsCaptureSaying(captures, whileHeld: {}, afterRead: {}, whileTheStripIsOut: {
                _ = await captures.session.applyReveal(.hiddenShown)
            })
            result.withLock { $0 = summary }
        }
        #expect(result.withLock { $0 } == CaptureSummary(captured: 0, changed: 0, skipped: "The bar changed while it was captured"))
        #expect(lines.contains {
            $0.contains("nothing captured at settingsOpened: The bar changed while it was captured "
                + "(Mantel changed the bar after the read (2 times; the last: a plan was applied)); active")
        })
    }

    @Test func aBarThatMantelChangedUnderTheCaptureIsReadAgainOnceItIsDrawn() async throws {
        // The reveal is applied while Settings' strip is being taken: the read is of the bar before it. The capture waits for the plan to be
        // drawn, reads the bar again and takes it again, and the pictures are kept.
        let rig = SessionRig.withAllowlist(sections: sections(hidden: [weather]))
        let captures = await started(rig)
        await captures.session.setCaptureTries(3)
        await captures.session.setBarDrawnWait(.milliseconds(500))

        let gate = Gate(), entered = Gate()
        captures.capture.hold(at: gate, entered: entered)
        await captures.session.setSettingsOpen(true)
        await entered.wait()
        _ = await captures.session.applyReveal(.hiddenShown)
        gate.open()
        await finishCapturing(captures)

        let apps = await captures.appsWithPictures()
        #expect(apps == [weather, notes, vpn, sync, system], "the second try: \(apps)")
        #expect(captures.capture.displays.count == 3, "the launch's strip, Settings' that was thrown away, and the one that was kept")
    }

    @Test func aBarThatMantelChangedUnderTheCaptureIsTakenOnlyAsOftenAsTheTriesAllow() async throws {
        let rig = SessionRig.withAllowlist(sections: sections(hidden: [weather]))
        let captures = await started(rig)
        await captures.session.setCaptureTries(1)

        let gate = Gate(), entered = Gate()
        captures.capture.hold(at: gate, entered: entered)
        await captures.session.setSettingsOpen(true)
        await entered.wait()
        _ = await captures.session.applyReveal(.hiddenShown)
        gate.open()
        await finishCapturing(captures)

        #expect(await captures.appsWithPictures().isEmpty)
        #expect(captures.capture.displays.count == 2, "the launch's strip and Settings', and no other")
    }

    @Test func theBarIsReadOnlyOnceThePlanThatWasAppliedIsDrawn() async throws {
        let rig = SessionRig.withAllowlist(sections: sections(hidden: [weather]))
        let captures = await started(rig)
        let session = captures.session
        await session.setBarDrawnWait(.milliseconds(500))
        _ = await session.applyReveal(.hiddenShown)

        let over = Mutex(false)
        let clock = rig.clock
        let asleep = clock.sleeperCount
        let waiting = Task {
            await session.waitForTheBarToBeStill()
            over.withLock { $0 = true }
        }
        #expect(await clock.waitForSleepers(asleep + 1, within: .seconds(5)), "it waits for what the plan asked for to be drawn")
        clock.advance(by: .milliseconds(200))
        #expect(await clock.waitForSleepers(asleep + 1, within: .seconds(5)), "and for what is left of the time")
        #expect(!over.withLock { $0 })
        clock.advance(by: .milliseconds(400))
        await waiting.value
        #expect(over.withLock { $0 })
    }

    @Test func aBarThatNoPlanChangedIsReadAtOnce() async throws {
        let rig = SessionRig.withAllowlist(sections: sections(hidden: [weather]))
        let captures = await started(rig)
        await captures.session.setBarDrawnWait(.milliseconds(500))
        // Long enough ago (`started` moved the clock on by three seconds): nothing to wait for.
        await captures.session.waitForTheBarToBeStill()
    }

    @Test func aClickOnAnotherDisplaysBarKeepsThePictureOfAnAppWhoseFramesAreOnTheMainBar() async throws {
        // The apps list their icons on one bar (the main display's, which is the active one here): the portrait display's bar has the same
        // icons in slots of its own, and an app's frames are not in them. They are compared where they are.
        let rig = SessionRig.withAllowlist(sections: sections(hidden: [weather]))
        let captures = await started(rig)
        let layout = rig.world.layout
        let main = try #require(layout.main?.uuid)
        let other = try #require(layout.displays.first { $0.uuid != main }?.uuid)
        let item = try #require(await rig.state?.inventory.items(ofApp: notes).first)
        let slot = try #require(item.frames[other])
        let location = ItemLocation(item: item.id, displayUUID: other, slotFrame: slot, tiedBy: .tie, slotWasInBaseline: true, widthAgrees: true)

        let over = Mutex(false)
        let session = captures.session
        let lines = await LogCapture.lines {
            let capturing = Task {
                await session.captureClickedIcon(location)
                over.withLock { $0 = true }
            }
            _ = await rig.driveClock(step: .milliseconds(100)) { over.withLock { $0 } }
            await capturing.value
        }

        #expect(await captures.appsWithPictures() == [notes], "\(lines.filter { $0.contains("[capture]") })")
    }

    @Test func aClickCaptureOfABarThatMantelChangedUnderItIsTakenAgain() async throws {
        let rig = SessionRig.withAllowlist(sections: sections(hidden: [weather]))
        let captures = await started(rig)
        await captures.session.setCaptureTries(3)
        let item = try #require(await rig.state?.inventory.items(ofApp: notes).first)
        // The apps list their icons on the main display's bar, and that is the bar the click was on.
        let main = try #require(rig.world.layout.main?.uuid)
        let slot = try #require(item.frames[main])
        let location = ItemLocation(item: item.id, displayUUID: main, slotFrame: slot, tiedBy: .tie, slotWasInBaseline: true, widthAgrees: true)
        let gate = Gate(), entered = Gate()
        captures.capture.hold(at: gate, entered: entered)
        let over = Mutex(false), stripIsOut = Mutex(false)
        let session = captures.session
        let capturing = Task {
            await session.captureClickedIcon(location)
            over.withLock { $0 = true }
        }
        let waitingForTheStrip = Task {
            await entered.wait()
            stripIsOut.withLock { $0 = true }
        }
        // The read the click asks for is let go by the clock; then the strip is out, and a plan is applied while it is.
        #expect(await rig.driveClock(step: .milliseconds(100)) { stripIsOut.withLock { $0 } }, "the strip was taken")
        await waitingForTheStrip.value
        _ = await session.applyReveal(.hiddenShown)
        gate.open()
        // The second try reads the bar again, which the clock lets go too.
        #expect(await rig.driveClock(step: .milliseconds(100)) { over.withLock { $0 } }, "the capture was over")
        await capturing.value

        #expect(await captures.appsWithPictures() == [notes], "the click's icon, from the second strip")
    }

    // MARK: What a change of Mantel's costs, and what a still bar waits for

    @Test func theAppsConfirmedBeforeAChangeOfMantelsKeepTheirPictures() async throws {
        let rig = SessionRig.withAllowlist(sections: sections(hidden: [weather]))
        let captures = await started(rig)
        let clock = rig.clock

        // The first round confirms the system's items and the notes and sync apps; the VPN app never answers, and the check waits to ask again.
        await settingsStrip(captures) { rig.extras.stopAnswering(vpn) }
        #expect(await clock.waitForSleepers(3, within: .seconds(5)))
        // A plan is applied before the second round: the bar is not the read's any more, and what was confirmed was of the strip before it.
        _ = await captures.session.applyReveal(.hiddenShown)
        clock.advance(by: StillCurrentWatch.settleWait)
        await captures.capturesFinished()

        #expect(await captures.appsWithPictures() == [notes, sync, system], "the confirmed apps' pictures are kept, and the one never judged isn't")
    }

    @Test func aWriteOfTheOrderTableIsWaitedOutBeforeTheBarIsRead() async throws {
        let rig = SessionRig.withAllowlist(sections: sections(hidden: [weather]))
        let captures = await started(rig)
        let session = captures.session
        await session.setLayoutPhase(pending: true, settling: false)
        await expectTheWaitToLast(rig, session) { await session.setLayoutPhase(pending: false, settling: true) }
        // The write is over once the bar has been re-sorted: settling is waited out too.
        await expectTheWaitToLast(rig, session) { await session.setLayoutPhase(pending: false, settling: false) }
    }

    @Test func aCommandDragIsWaitedOutBeforeTheBarIsRead() async throws {
        let rig = SessionRig.withAllowlist(sections: sections(hidden: [weather]))
        let captures = await started(rig)
        let session = captures.session
        await session.commandDragBegan()
        await expectTheWaitToLast(rig, session) { await session.commandDragEnded() }
    }

    /// The wait for a still bar doesn't end while what holds it is on, and ends soon after `release`.
    private func expectTheWaitToLast(_ rig: SessionRig, _ session: MenuBarSession, release: @escaping @Sendable () async -> Void) async {
        let over = Mutex(false), released = Mutex(false)
        let clock = rig.clock
        let asleep = clock.sleeperCount
        let waiting = Task {
            await session.waitForTheBarToBeStill()
            over.withLock { $0 = true }
        }
        #expect(await clock.waitForSleepers(asleep + 1, within: .seconds(5)), "it waits for the bar to be re-sorted")
        clock.advance(by: .milliseconds(100))
        #expect(await clock.waitForSleepers(asleep + 1, within: .seconds(5)), "and goes on waiting")
        #expect(!over.withLock { $0 })
        // What follows the release (a read, say) waits on the clock too: it is moved as they come.
        let releasing = Task {
            await release()
            released.withLock { $0 = true }
        }
        #expect(await rig.driveClock(step: .milliseconds(100)) { over.withLock { $0 } && released.withLock { $0 } }, "it was over once the bar was still")
        await waiting.value
        await releasing.value
    }

    // MARK: A reveal's capture, taken again

    /// A reveal of the Hidden apps is applied, followed up, and its strip held: the capture of the revealed apps is out, with three tries.
    private func revealStripHeld(_ rig: SessionRig) async -> (CaptureRig, Gate, strips: Int) {
        let captures = await started(rig)
        await captures.session.setCaptureTries(3)
        let strips = captures.capture.displays.count
        let gate = Gate(), entered = Gate()
        captures.capture.hold(at: gate, entered: entered)
        let applied = await captures.session.applyReveal(.hiddenShown)
        #expect(await captures.session.followUp(applied) == .none)
        await entered.wait()
        return (captures, gate, strips)
    }

    @Test func aRevealCaptureThatMantelChangedTheBarUnderIsTakenAgainWhileTheRevealStands() async throws {
        let rig = SessionRig.withAllowlist(sections: sections(hidden: [weather]))
        let (captures, gate, strips) = await revealStripHeld(rig)
        defer { gate.open() }

        // The same plan is applied again: the count of Mantel's changes moves, and the reveal stands.
        await captures.session.rebuildAndApply(force: true)
        gate.open()
        await finishCapturing(captures)

        #expect(captures.capture.displays.count == strips + 2, "the reveal's strip that was thrown away, and the one taken again")
        #expect(await captures.appsWithPictures().contains(weather), "the revealed app's picture, from the second")
    }

    @Test func aRevealCaptureWhoseRevealEndedUnderItIsNotTakenAgain() async throws {
        let rig = SessionRig.withAllowlist(sections: sections(hidden: [weather]))
        let (captures, gate, strips) = await revealStripHeld(rig)
        defer { gate.open() }

        await captures.session.rebuildAndApply(force: true)
        #expect(await captures.session.setReveal(.collapsed) == .none)
        let reads = await captures.session.scansIngested
        gate.open()
        await finishCapturing(captures)

        #expect(captures.capture.displays.count == strips + 1, "one reveal strip")
        #expect(await captures.session.scansIngested == reads, "and the bar isn't read for another")
        #expect(await captures.store.records().isEmpty)
    }

    @Test func aRevealThatEndsWhileTheBarIsWaitedForIsNotRead() async throws {
        let rig = SessionRig.withAllowlist(sections: sections(hidden: [weather]))
        let (captures, gate, strips) = await revealStripHeld(rig)
        defer { gate.open() }
        let session = captures.session
        let allowlist = try #require(rig.allowlist)
        let applying = Gate()
        defer { applying.open() }

        // A plan is under way in the engine, and held there; the strip comes back and the capture waits for the bar to be drawn.
        allowlist.holdActivations(until: applying)
        let calls = allowlist.calls.count
        let rebuilding = Task { await session.move(app: sync, to: .alwaysHidden) }
        #expect(await waitUntil { allowlist.calls.count == calls + 1 })
        let clock = rig.clock
        let asleep = clock.sleeperCount
        gate.open()
        #expect(await clock.waitForSleepers(asleep + 1, within: .seconds(5)), "the capture waits for the plan to be drawn")
        // The reveal ends meanwhile; the plan that was held is let go.
        let generation = await session.revealGeneration
        let ending = Task { await session.setReveal(.collapsed) }
        var ended = false
        for _ in 0..<500 where !ended {
            ended = await session.revealGeneration > generation
            if !ended { try await Task.sleep(for: .milliseconds(10)) }
        }
        #expect(ended, "the reveal is over")
        let reads = await session.scansIngested
        applying.open()
        await rebuilding.value
        _ = await ending.value
        await finishCapturing(captures)

        #expect(await session.scansIngested == reads, "no read was asked for once the reveal was over")
        #expect(captures.capture.displays.count == strips + 1)
    }

    @Test func aClickOnABarTheAppsFramesAreNotOnTrustsNoSlotWhenTheDotsComeToIt() async throws {
        // The apps list their icons on the main bar; the click is on the portrait display's. The dots (Mantel's own) come at that bar's
        // left end while the strip is taken: on the bar the frames are on that keeps every picture, but here the frames can't see a slide
        // that only this bar had, and the old rule stands.
        let rig = SessionRig.withAllowlist(sections: sections(hidden: [weather]))
        let dots = Self.dots
        rig.world.setItemOrder(dots)
        rig.world.setOwnItems(listed: [], omitted: Set(dots))
        let captures = await started(rig)
        let layout = rig.world.layout
        let main = try #require(layout.main?.uuid)
        let other = try #require(layout.displays.first { $0.uuid != main }?.uuid)
        let item = try #require(await rig.state?.inventory.items(ofApp: notes).first)
        let slot = try #require(item.frames[other])
        let location = ItemLocation(item: item.id, displayUUID: other, slotFrame: slot, tiedBy: .tie, slotWasInBaseline: true, widthAgrees: true)

        let gate = Gate(), entered = Gate()
        captures.capture.hold(at: gate, entered: entered)
        let over = Mutex(false), stripIsOut = Mutex(false)
        let session = captures.session
        let capturing = Task {
            await session.captureClickedIcon(location)
            over.withLock { $0 = true }
        }
        let waitingForTheStrip = Task {
            await entered.wait()
            stripIsOut.withLock { $0 = true }
        }
        #expect(await rig.driveClock(step: .milliseconds(100)) { stripIsOut.withLock { $0 } }, "the strip was taken")
        await waitingForTheStrip.value
        rig.world.setOwnItems(listed: [], omitted: [])
        gate.open()
        #expect(await rig.driveClock(step: .milliseconds(100)) { over.withLock { $0 } }, "the capture was over")
        await capturing.value

        #expect(await captures.appsWithPictures().isEmpty, "no picture: the slots that came are Mantel's, but the frames aren't on this bar")
    }

    @Test func aStripThatSeesNothingMoveIsKept() async throws {
        // The same run as the ones below, with nothing changed while the strip is taken: the pictures are kept.
        let rig = SessionRig.withAllowlist(sections: sections(hidden: [weather]))
        let (_, apps) = await settingsStrip(over: rig) { _ in }
        #expect(apps == [notes, vpn, sync, system], "every Shown app that is cropped: Hidden is concealed, and the dots are Mantel's own")
    }

    @Test func anAppThatAppearsToTheRightWhileTheStripIsTakenSavesNothing() async throws {
        // Every icon to the left of the new app's two slides left by their width: a crop of a slot holds part of its neighbour. The hidden
        // provider is fixed before the test item starts: the allowlist would conceal an app that starts after it (and, in the fixture, a
        // concealed app keeps its room and has no slot), and then no slot would have come. Its two slots are an arrival of anyone else's:
        // nothing is kept.
        let rig = SessionRig.withAllowlist(sections: sections(hidden: [weather]))
        let (_, apps) = await settingsStrip(over: rig) { world in
            world.setHiddenProvider { [weather] }
            world.setTestItemRunning(true)
        }
        #expect(apps.isEmpty, "no app's picture, under an item that isn't the one in it; two slots of anyone else's came: \(apps)")
    }

    @Test func anAppThatQuitsWhileTheStripIsTakenSavesNothing() async throws {
        let rig = SessionRig.withAllowlist(testItem: true, sections: sections(hidden: [weather]))
        let (_, apps) = await settingsStrip(over: rig) { $0.setTestItemRunning(false) }
        #expect(apps.isEmpty, "no app's picture, under an item that isn't the one in it; two slots of anyone else's went, and that is all or nothing: \(apps)")
    }

    @Test func theLiftOfTheAllowlistWhileTheStripIsTakenSavesNothing() async throws {
        // The clock click lifts the allowlist inside the event tap, which doesn't go through the session: the Hidden apps are drawn
        // again. (In the fixture they come back into the room they kept: no icon slides, and the two slots that came are an app's.)
        let rig = SessionRig.withAllowlist(sections: sections(hidden: [weather]))
        // The notes app's icon is left of the weather app's, which comes back between it and the others.
        let (captures, apps) = await settingsStrip(over: rig, beforeTheRead: { $0.setItemOrder(["Notes"]) },
                                                   reflow: { world in world.setHiddenProvider { [] } })
        #expect(apps.isEmpty, "no picture: the slots of an app that came are all or nothing, as no slide can be placed: \(apps)")

        // The lift is over (the allowlist is put back) and the bar is as it was read: the next capture is taken at once, as the notes app's
        // picture wasn't kept, and it is kept.
        rig.world.setHiddenProvider { [weather] }
        captures.capture.hold(at: nil)
        // The bar's two seconds of throttle, held by the pictures that were kept, have passed.
        rig.clock.advance(by: .seconds(3))
        await captures.session.setSettingsOpen(true)
        await finishCapturing(captures)
        #expect(await captures.appsWithPictures().contains(notes))
    }

    @Test func aBarThatCatchesUpWithAnApplyWhileTheStripIsTakenSavesNothing() async throws {
        // The laptop's bar had room for every icon, and a plan that was applied a moment ago has it fit one fewer: it is drawn after the
        // read.
        let rig = SessionRig.withAllowlist(shape: .laptop, capacity: 6, sections: sections(hidden: [weather]))
        let (_, apps) = await settingsStrip(over: rig) { $0.setCapacity(5) }
        #expect(apps == [vpn, sync, system], "no picture of the icon that is piled up now, under an item that isn't the one in it: \(apps)")
    }

    @Test(arguments: [false, true]) func iconsThatSlideBetweenTheAppsAnswersAndTheSlotsOfTheReadSaveNothing(unnamed: Bool) async throws {
        // N3: the apps answered with frames from before the bar slid by a slot, and MenuBarAgent's window was read after it: the read ties
        // every app to its neighbour's slot, and the slots, looked at after the strip, are the read's. The apps' frames, asked again, are
        // each in the slot before the one the read gave.
        let rig = SessionRig.withAllowlist(sections: sections(hidden: [weather]))
        rig.world.setNameless(unnamed)
        let everyApp: [String: CGFloat] = [weather: 44, notes: 44, vpn: 44, sync: 44]
        let (captures, apps) = await settingsStrip(over: rig, beforeTheRead: { $0.setFrameShifts(everyApp) }, reflow: { $0.setFrameShifts([:]) })
        #expect(apps == [system], "no app's picture, under an item that isn't the one in it; the system's are told by their slots' names: \(apps)")
        #expect(captures.capture.displays.count == 2, "the launch's strip and Settings': it is the frames that turned the second away")
    }

    @Test(arguments: [false, true]) func aSlideThatIsUndoneWhileTheAppsAnswerSavesNothing(unnamed: Bool) async throws {
        // the read and the strip are of a bar with the test item's two icons on it, and the apps' frames (from before it came) lie two
        // slots right of the icons: each app is tied to the slot of its right neighbour. While the apps are asked once more, the test item
        // quits and the bar is as it was: every frame is now where its icon is, which is in the slot the read gave it. Asked after the look
        // the apps' answers pass; asked before it, the look sees the bar as it is and the read's slots are not that.
        let rig = SessionRig.withAllowlist(sections: sections(hidden: [weather]))
        rig.world.setNameless(unnamed)
        let everyApp: [String: CGFloat] = [weather: 88, notes: 88, vpn: 88, sync: 88]
        let extras = rig.extras
        let (_, apps) = await settingsStrip(over: rig, beforeTheRead: {
            $0.setTestItemRunning(true)
            $0.setFrameShifts(everyApp)
        }, reflow: { world in
            extras.runOnNextRead {
                world.setTestItemRunning(false)
                world.setFrameShifts([:])
            }
        })
        #expect(apps.isEmpty, "no picture under an item that isn't the one in it: \(apps)")
    }

    @Test func aClickCaptureIsTakenFromAReadTakenForTheClick() async throws {
        // The picture of the icon a click found drawn is cropped from the read the click asks for, never from an older one: the read is
        // taken when the capture is asked for (and only when something takes pictures).
        let rig = SessionRig.withAllowlist(sections: sections(hidden: [weather]))
        let captures = await CaptureRig(rig)
        await captures.session.start()
        await captures.capturesFinished()
        let reads = await rig.session.scansIngested
        let item = try #require(await rig.state?.inventory.items(ofApp: notes).first)
        let slot = try #require(item.frames.first)
        let location = ItemLocation(item: item.id, displayUUID: slot.key, slotFrame: slot.value, tiedBy: .tie, slotWasInBaseline: true,
                                    widthAgrees: true)

        let capturing = Task { await captures.session.captureClickedIcon(location) }
        // The read it asks for is one that begins after the request: the polling's clock lets it go.
        #expect(await rig.pumpUntilReads(reads + 1))
        await capturing.value
        await captures.capturesFinished()
        #expect(await rig.session.scansIngested == reads + 1, "one read, taken for the click")

        // With nothing that takes pictures, no read is taken for it.
        let plain = SessionRig.withAllowlist(sections: sections(hidden: [weather]))
        await plain.session.start()
        let before = await plain.session.scansIngested
        await plain.session.captureClickedIcon(location)
        #expect(await plain.session.scansIngested == before)
    }

    @Test(arguments: [false, true]) func iconsThatAreTiedToTheirNeighboursSlotsAtLaunchSaveNothing(unnamed: Bool) async throws {
        let rig = SessionRig.withAllowlist(sections: sections(hidden: [weather]))
        rig.world.setNameless(unnamed)
        let captures = await CaptureRig(rig)
        captures.paintEverything()
        rig.world.setFrameShifts([weather: 44, notes: 44, vpn: 44, sync: 44])
        let gate = Gate(), entered = Gate()
        defer { gate.open() }
        captures.capture.hold(at: gate, entered: entered)

        let starting = Task { await rig.session.start() }
        await entered.wait()
        rig.world.setFrameShifts([:])
        gate.open()
        await starting.value
        await captures.capturesFinished()

        #expect(captures.capture.displays.count == 1, "the strip was taken, and came back inside the budget")
        // With names, the weather app's slots carry its own names, and are its whatever frames lie in them: its pictures are its own. The apps
        // that are told by a frame alone (every app on macOS 27) are tied to their neighbours' slots by what they report: nothing of theirs is
        // kept under an item that isn't the one in the picture.
        #expect(await captures.appsWithPictures() == (unnamed ? [system] : [system, weather]), "only the icons whose slots are theirs by name")
    }

    @Test(arguments: [false, true]) func twoIconsOfOneWidthThatTradePlacesWhileTheStripIsTakenSaveNothing(unnamed: Bool) async throws {
        // The notes app's icon and the VPN app's are both 36 wide and have no name on their slots (AppKit's `_NS:` isn't one): the slots
        // are where they were. The apps' frames have traded places.
        let rig = SessionRig.withAllowlist(sections: sections(hidden: [weather]))
        rig.world.setNameless(unnamed)
        let (_, apps) = await settingsStrip(over: rig) { $0.setFrameShifts([notes: 44, vpn: -44]) }
        #expect(apps == [sync, system], "the two that traded places keep nothing; an app whose icon didn't move keeps its pictures: \(apps)")
    }

    @Test func onlyTheAppsThatAreCroppedAreAskedForTheirFramesAgain() async throws {
        // Hidden is concealed (not cropped), Mantel's own icons never are, and MenuBarAgent has no items: each cropped app is asked once.
        let rig = SessionRig.withAllowlist(sections: sections(hidden: [weather]))
        let captures = await CaptureRig(rig)
        await captures.session.start()
        captures.paintEverything()
        rig.clock.advance(by: .seconds(3))
        let gate = Gate(), entered = Gate()
        defer { gate.open() }
        captures.capture.hold(at: gate, entered: entered)
        await captures.session.setSettingsOpen(true)
        await entered.wait()
        rig.extras.forgetAppsAsked()

        gate.open()
        await captures.capturesFinished()

        #expect(rig.extras.appsAsked.sorted() == [notes, sync, vpn].sorted(), "asked after the strip, together, and no others")
    }


    @Test func aRevealStripThatSeesTheBarMoveSavesNothing() async throws {
        // A reveal's pictures are taken after the plan is applied, and the bar is changed by something else while the strip is taken.
        let rig = SessionRig.withAllowlist(sections: sections(hidden: [weather]))
        let captures = await CaptureRig(rig)
        await captures.session.start()
        captures.paintEverything()
        rig.clock.advance(by: .seconds(3))
        let gate = Gate(), entered = Gate()
        defer { gate.open() }
        captures.capture.hold(at: gate, entered: entered)

        let applied = await captures.session.applyReveal(.hiddenShown)
        #expect(await captures.session.followUp(applied) == .none)
        await entered.wait()
        rig.world.setTestItemRunning(true)
        gate.open()
        await captures.capturesFinished()

        #expect(await captures.store.records().isEmpty)
    }

    @Test func anAppThatStartsWhileTheLaunchStripIsTakenSavesNothing() async throws {
        // The test item's two icons arrive to the right of the others while the launch strip is taken: everything to their left slides.
        let rig = SessionRig.withAllowlist(sections: sections(hidden: [weather]))
        let captures = await CaptureRig(rig)
        captures.paintEverything()
        let gate = Gate(), entered = Gate()
        defer { gate.open() }
        captures.capture.hold(at: gate, entered: entered)

        let starting = Task { await rig.session.start() }
        await entered.wait()
        rig.world.setTestItemRunning(true)
        gate.open()
        await starting.value
        await captures.capturesFinished()

        #expect(captures.capture.displays.count == 1, "the strip was taken, and came back inside the budget")
        let kept = await captures.appsWithPictures()
        #expect(kept.isEmpty, "no app's picture under an item that isn't the one in it; two slots of anyone else's came, and that is all or nothing: \(kept)")
    }

    @Test func aLaunchStripThatSeesNothingMoveIsKept() async throws {
        let rig = SessionRig.withAllowlist(sections: sections(hidden: [weather]))
        let captures = await CaptureRig(rig)
        captures.paintEverything()

        await captures.session.start()
        await captures.capturesFinished()

        #expect(await captures.appsWithPictures().contains(notes))
    }

    @Test func theSlotsAreLookedAtOnceAgainAfterTheStrip() async throws {
        let rig = SessionRig.withAllowlist(sections: sections(hidden: [weather]))
        let captures = await CaptureRig(rig)
        await captures.session.start()
        let inventory = try #require(await rig.state).inventory
        let display = try #require(inventory.activeDisplay)
        let read = try #require(inventory.barSlots[display])
        let now = try #require(await captures.session.slotsNow(on: display))
        #expect(!read.isEmpty)
        #expect(BarSlotCheck.isSame(read: read, now: now), "a bar nothing has changed is the bar the read had")
        rig.world.setTestItemRunning(true)
        let later = try #require(await captures.session.slotsNow(on: display))
        #expect(!BarSlotCheck.isSame(read: read, now: later))
    }

    @Test func thePreviousPlansConcealedAppsAreHandedToTheActiveDisplaysVote() async throws {
        let rig = SessionRig.withAllowlist(sections: sections(hidden: [weather]))
        await rig.session.start()
        #expect(await rig.session.concealedBeforeThePlan.isEmpty, "nothing was concealed before the first plan")

        _ = await rig.session.applyReveal(.hiddenShown)

        #expect(await rig.session.concealedBeforeThePlan == [weather], "the apps that were concealed, and are drawn again: they don't vote")
    }

    // MARK: Settings opening

    @Test func settingsOpenedCapturesShown() async throws {
        let rig = SessionRig.withAllowlist(sections: sections(hidden: [weather]))
        let captures = await CaptureRig(rig)
        await captures.session.start()
        captures.paintEverything()
        rig.clock.advance(by: .seconds(3))

        await captures.session.setSettingsOpen(true)
        await captures.capturesFinished()

        let apps = await captures.appsWithPictures()
        #expect(apps.contains(notes), "the Shown apps")
        #expect(!apps.contains(weather), "Hidden is concealed, and not drawn to be cropped")
    }

    @Test func settingsOpenedWithNoCollectorReadsNothingMore() async throws {
        let rig = SessionRig.withAllowlist(sections: sections(hidden: [weather]))
        await rig.session.start()
        let reads = await rig.session.scansIngested

        await rig.session.setSettingsOpen(true)
        await rig.session.capturesFinished()

        #expect(await rig.session.scansIngested == reads)
    }

    // MARK: Recapture

    @Test func recaptureRevealsAllThenRestoresPlan() async throws {
        let rig = SessionRig.withAllowlist(sections: sections(hidden: [weather], alwaysHidden: [notes]))
        let captures = await CaptureRig(rig)
        await captures.session.start()
        let allowlist = try #require(rig.allowlist)
        captures.paintEverything()
        rig.clock.advance(by: .seconds(3))
        let planBefore = try #require(await rig.state).plan
        let applied = allowlist.calls.count

        let summary = await captures.session.recaptureIcons()

        #expect(summary.skipped == nil)
        #expect(summary.captured > 0)
        // Everything was shown for the capture (nothing concealed: the allowlist is lifted), and then the plan was as it had been.
        #expect(captures.concealedWhenTaken.last == [], "Hidden and Always Hidden were on the bar")
        let calls = Array(allowlist.calls.dropFirst(applied))
        #expect(calls.count == 1, "the plan was made live again")
        #expect(calls.last?.bundleIDs == allowlist.calls[applied - 1].bundleIDs, "as it was")
        #expect(try #require(await rig.state).plan == planBefore)
        #expect(rig.world.concealed == [weather, notes])
        // The pictures are of the apps that are hidden, which only a reveal could show.
        #expect(await captures.appsWithPictures().isSuperset(of: [weather, notes]))
    }

    @Test func recaptureKeepsAnInlineRevealThatWasInForce() async throws {
        let rig = SessionRig.withAllowlist(sections: sections(hidden: [weather], alwaysHidden: [notes]))
        let captures = await CaptureRig(rig)
        await captures.session.start()
        captures.paintEverything()
        rig.clock.advance(by: .seconds(3))
        #expect(await captures.session.setReveal(.hiddenShown) == .none)
        let planBefore = try #require(await rig.state).plan
        // The reveal's own capture holds the bar's throttle, which a recapture waits out on the session's clock.
        await captures.capturesFinished()
        rig.clock.advance(by: .seconds(3))

        _ = await captures.session.recaptureIcons()

        #expect(try #require(await rig.state).plan == planBefore, "Hidden is shown again, and Always Hidden is not")
        #expect(rig.world.concealed == [notes])
    }

    @Test func recaptureSkippedInFocusMode() async throws {
        let rig = SessionRig.withAllowlist(sections: sections(hidden: [weather]))
        let captures = await CaptureRig(rig)
        await captures.session.start()
        let allowlist = try #require(rig.allowlist)
        _ = await captures.session.applyReveal(.focusMode)
        let applied = allowlist.calls.count
        let strips = captures.capture.displays.count

        let summary = await captures.session.recaptureIcons()

        #expect(summary == CaptureSummary(captured: 0, changed: 0, skipped: CommandAnswers.focus(isOn: true)))
        #expect(allowlist.calls.count == applied, "no plan was applied")
        #expect(captures.capture.displays.count == strips)
    }

    @Test func recaptureSkippedDuringReset() async throws {
        let rig = SessionRig.withAllowlist(sections: sections(hidden: [weather]))
        let captures = await CaptureRig(rig)
        await captures.session.start()
        let allowlist = try #require(rig.allowlist)
        let gate = Gate(), restarting = Gate()
        defer { gate.open() }
        let restarter = FakeRestarter()
        restarter.whileRestarting {
            restarting.open()
            await gate.wait()
        }
        let resetting = Task { try? await rig.session.reset(restarter: restarter, replayJournal: {}) }
        await restarting.wait()
        let applied = allowlist.calls.count
        let strips = captures.capture.displays.count

        let summary = await captures.session.recaptureIcons()

        #expect(summary == CaptureSummary(captured: 0, changed: 0, skipped: CommandAnswers.resetUnderWay))
        #expect(allowlist.calls.count == applied)
        #expect(captures.capture.displays.count == strips)
        gate.open()
        await resetting.value
    }

    @Test func recaptureSkippedWhileTheBarIsBeingResorted() async throws {
        let rig = SessionRig.withAllowlist(sections: sections(hidden: [weather]))
        let captures = await CaptureRig(rig)
        await captures.session.start()
        let allowlist = try #require(rig.allowlist)
        await captures.session.setLayoutPhase(pending: true, settling: true)
        let applied = allowlist.calls.count
        let strips = captures.capture.displays.count
        let reads = await captures.session.scansIngested

        let summary = await captures.session.recaptureIcons()

        // Before the reveal: no icon is shown for a picture the collector would only refuse, and no plan is applied or put back.
        #expect(summary == CaptureSummary(captured: 0, changed: 0, skipped: LayoutWords.resorting))
        #expect(allowlist.calls.count == applied, "no plan was applied")
        #expect(captures.capture.displays.count == strips)
        #expect(await captures.session.scansIngested == reads, "and the bar wasn't read")
    }

    @Test func recaptureSkippedWhileACommandDragIsUnderWay() async throws {
        let rig = SessionRig.withAllowlist(sections: sections(hidden: [weather]))
        let captures = await CaptureRig(rig)
        await captures.session.start()
        let allowlist = try #require(rig.allowlist)
        await captures.session.commandDragBegan()
        let applied = allowlist.calls.count
        let strips = captures.capture.displays.count

        let summary = await captures.session.recaptureIcons()

        #expect(summary == CaptureSummary(captured: 0, changed: 0, skipped: LayoutWords.resorting))
        #expect(allowlist.calls.count == applied, "no plan was applied")
        #expect(captures.capture.displays.count == strips)
    }

    @Test func recaptureWithNoCollectorSaysSo() async throws {
        let rig = SessionRig.withAllowlist(sections: sections(hidden: [weather]))
        await rig.session.start()

        let summary = await rig.session.recaptureIcons()

        #expect(summary.captured == 0)
        #expect(summary.skipped != nil)
    }

    @Test func recaptureTakesThePicturesAgainThoughTheyAreRecent() async throws {
        let rig = SessionRig.withAllowlist(sections: sections(hidden: [weather], alwaysHidden: [notes]))
        let captures = await CaptureRig(rig)
        await captures.session.start()
        captures.paintEverything()
        rig.clock.advance(by: .seconds(3))
        let first = await captures.session.recaptureIcons()
        #expect(first.skipped == nil)
        #expect(first.captured > 0)

        // Three seconds later (the bar's throttle is two), well inside the hour a picture is left alone for at other moments.
        rig.clock.advance(by: .seconds(3))
        let second = await captures.session.recaptureIcons()

        #expect(second.skipped == nil, "the pictures that are recent are taken again")
        #expect(second.captured == first.captured)
        #expect(second.changed == 0, "the same icons: nothing changed")
        // A settings capture at the same time leaves them as they are.
        rig.clock.advance(by: .seconds(3))
        await captures.session.setSettingsOpen(true)
        await captures.capturesFinished()
        #expect(await captures.collector.lastCaptureAt != nil)
    }

    @Test func recaptureWaitsOutTheBarsThrottleBeforeRevealingAnything() async throws {
        let rig = SessionRig.withAllowlist(sections: sections(hidden: [weather]))
        let captures = await CaptureRig(rig)
        await captures.session.start()
        let allowlist = try #require(rig.allowlist)
        captures.paintEverything()
        rig.clock.advance(by: .seconds(3))
        let first = await captures.session.recaptureIcons()
        #expect(first.skipped == nil)
        let applied = allowlist.calls.count
        let strips = captures.capture.displays.count
        rig.clock.advance(by: .milliseconds(500))

        let sleepers = rig.clock.sleeperCount
        let again = Task { await captures.session.recaptureIcons() }
        #expect(await rig.clock.waitForSleepers(sleepers + 1, within: .seconds(20)), "the recapture is waiting out the throttle")
        rig.clock.advance(by: .milliseconds(1400))
        await letTasksRun()

        // 1.9 s after the last capture: the bar's two seconds haven't passed, and nothing was revealed.
        #expect(allowlist.calls.count == applied, "no plan was applied before the throttle was over")
        #expect(captures.capture.displays.count == strips)
        #expect(rig.world.concealed == [weather])
        rig.clock.advance(by: .milliseconds(200))
        let summary = await again.value

        #expect(summary.skipped == nil, "it waited, and then captured")
        #expect(summary.captured > 0)
        #expect(captures.capture.displays.count > strips)
        #expect(rig.world.concealed == [weather], "and the plan is as it was")
    }

    @Test func recaptureAnswersAtOnceWhenItCantRunInsteadOfWaiting() async throws {
        let rig = SessionRig.withAllowlist(sections: sections(hidden: [weather]))
        let captures = await CaptureRig(rig)
        await captures.session.start()
        captures.paintEverything()
        rig.clock.advance(by: .seconds(3))
        _ = await captures.session.recaptureIcons()
        rig.clock.advance(by: .milliseconds(500))
        _ = await rig.session.applyReveal(.focusMode)
        let sleepers = rig.clock.sleeperCount

        // The guard answers before the wait, on a clock that never moves (a wait would never end).
        let summary = await captures.session.recaptureIcons()

        #expect(summary == CaptureSummary(captured: 0, changed: 0, skipped: CommandAnswers.focus(isOn: true)))
        #expect(rig.clock.sleeperCount == sleepers, "it didn't go to sleep")
    }

    @Test func recaptureBeforeTheStartIsSkippedAndAppliesNothing() async throws {
        let rig = SessionRig.withAllowlist(sections: sections(hidden: [weather]))
        let captures = await CaptureRig(rig)
        let allowlist = try #require(rig.allowlist)

        let summary = await captures.session.recaptureIcons()

        #expect(summary == CaptureSummary(captured: 0, changed: 0, skipped: MenuBarSession.notStartedText))
        #expect(allowlist.calls.isEmpty, "no plan was applied before the launch's first read")
        await captures.session.start()
        #expect(captures.asked.value == 1, "the launch is still the first read")
        #expect(captures.concealedWhenTaken.last == [], "taken with nothing concealed: no plan came before it")
    }

    @Test func aRevealThatComesDuringARecaptureStandsAndNothingIsKept() async throws {
        let rig = SessionRig.withAllowlist(sections: sections(hidden: [weather], alwaysHidden: [notes]))
        let captures = await CaptureRig(rig)
        await captures.session.start()
        captures.paintEverything()
        rig.clock.advance(by: .seconds(3))
        let gate = Gate(), entered = Gate()
        defer { gate.open() }
        captures.capture.hold(at: gate, entered: entered)

        let session = captures.session
        let recapturing = Task { await session.recaptureIcons() }
        await entered.wait()
        // Focus Mode comes while the strip is being taken: everything is shown, and it stays so.
        _ = await session.applyReveal(.focusMode)
        let inFocusMode = try #require(await rig.state).plan
        gate.open()
        let summary = await recapturing.value

        #expect(summary.captured == 0, "the bar was changed while the strip was taken")
        #expect(await captures.store.records().isEmpty)
        #expect(await session.revealState == .focusMode, "the recapture didn't put the plan back over it")
        #expect(try #require(await rig.state).plan == inFocusMode)
    }

    @Test func aRecaptureThatCantTellPutsThePlanBack() async throws {
        let rig = SessionRig.withAllowlist(sections: sections(hidden: [weather]))
        let captures = await CaptureRig(rig)
        await captures.session.start()
        captures.paintEverything()
        rig.clock.advance(by: .seconds(3))
        let planBefore = try #require(await rig.state).plan
        let strips = captures.capture.displays.count
        // MenuBarAgent isn't there: the look can't tell, and a read finds no bar.
        rig.world.setAgentRunning(false)

        let summary = await captures.session.recaptureIcons()

        #expect(summary.captured == 0)
        #expect(summary.skipped != nil)
        #expect(captures.capture.displays.count == strips, "no strip was taken")
        rig.world.setAgentRunning(true)
        #expect(try #require(await rig.state).plan == planBefore, "the plan is as it was")
        #expect(await captures.session.revealState == .collapsed)
    }

    // MARK: The recording indicator

    @Test func indicatorIgnoredDuringQuietPeriod() async throws {
        // Branch C-B: the recording indicator can appear because of a capture, and is left out of what is judged for a while after one.
        let rules = CaptureRules(moments: [.launch, .settingsOpened, .recapture], launchBudget: .seconds(1),
                                 launchBudgetPerBar: .milliseconds(226), indicatorQuietPeriod: .seconds(2))
        let rig = SessionRig.withAllowlist(sections: sections(hidden: [weather]))
        let captures = await CaptureRig(rig, rules: rules)
        captures.paintEverything()
        let indicator = ItemID.system(MenuBarSession.recordingIndicatorModule)

        await captures.session.start()

        #expect(await captures.collector.lastCaptureAt != nil, "the launch captured")
        let during = try #require(await rig.state).inventory
        #expect(!during.items.contains { $0.id == indicator }, "the indicator is left out of the read taken just after a capture")
        #expect(during.items.contains { $0.id == ItemID.system("clock") }, "and nothing else is")
        #expect(await captures.session.indicatorQuietLogged)

        rig.clock.advance(by: .seconds(3))
        await captures.session.refresh()
        let after = try #require(await rig.state).inventory
        let item = try #require(after.items.first { $0.id == indicator }, "the quiet period is over")
        // Its slot is on the bar all the same: left out of the items, it is one that nobody's, and not room.
        for (display, frame) in item.frames {
            #expect(during.untiedSlots[display]?.contains(frame) == true)
        }
        // And in the list of slots the bar draws, which a capture's look is compared with: the indicator's slot is still on the bar.
        #expect(!during.barSlots.isEmpty, "the read still has its slots")
        #expect(during.barSlots == after.barSlots)
        // And what the matcher said of the apps: the processes that listed them, which the check of an app's icons goes by.
        #expect(!during.appProcesses.isEmpty, "the read still says which processes listed each app")
        #expect(during.appProcesses == after.appProcesses)
    }

    @Test func theQuietPeriodRunsFromTheStripEvenWhenNothingWasSaved() async throws {
        let rules = CaptureRules(moments: [.launch, .settingsOpened, .recapture], launchBudget: .seconds(1),
                                 launchBudgetPerBar: .milliseconds(226), indicatorQuietPeriod: .seconds(2))
        let rig = SessionRig.withAllowlist(sections: sections(hidden: [weather]))
        let captures = await CaptureRig(rig, rules: rules)
        // Nothing is painted: the strip is flat, and nothing in it can be cropped.
        let indicator = ItemID.system(MenuBarSession.recordingIndicatorModule)

        await captures.session.start()

        #expect(await captures.collector.lastCaptureAt == nil, "nothing was saved")
        #expect(await captures.collector.lastStripAt != nil, "but a strip was taken")
        let during = try #require(await rig.state).inventory
        #expect(!during.items.contains { $0.id == indicator })
    }

    @Test func indicatorKeptWhenTheRulesHaveNoQuietPeriod() async throws {
        let rig = SessionRig.withAllowlist(sections: sections(hidden: [weather]))
        let captures = await CaptureRig(rig)
        captures.paintEverything()

        await captures.session.start()

        #expect(await captures.collector.lastCaptureAt != nil)
        let read = try #require(await rig.state).inventory
        #expect(read.items.contains { $0.id == ItemID.system(MenuBarSession.recordingIndicatorModule) })
        #expect(await captures.session.indicatorQuietLogged == false)
    }
}

/// The pictures of the icons on a busy Mac: MenuBarAgent and the apps answer late, or not in time, and nothing that is only slow is taken for
/// a bar that changed.
extension MenuBarSessionCaptureTests {
    /// The weather app's and the notes app's and the others' pictures are painted, and the clock is moved on so that none is recent.
    private func started(_ rig: SessionRig) async -> CaptureRig {
        let captures = await CaptureRig(rig)
        await captures.session.start()
        captures.paintEverything()
        rig.clock.advance(by: .seconds(3))
        return captures
    }

    /// Opens Settings with the strip held, lets `whileHeld` change what the world answers, and lets the strip go.
    private func settingsStrip(_ captures: CaptureRig, whileHeld: () -> Void) async {
        let gate = Gate(), entered = Gate()
        defer { gate.open() }
        captures.capture.hold(at: gate, entered: entered)
        await captures.session.setSettingsOpen(true)
        await entered.wait()
        whileHeld()
        gate.open()
    }

    // MARK: The launch's budget

    @Test func aSlowReadGivesTheLaunchCaptureAsMuchTimeAgainUpToTwoSeconds() {
        let rules = CaptureRules.measured
        func extra(_ readTook: TimeInterval) -> Double {
            let difference = rules.launchBudget(forShownBars: 1, readTook: readTook) - rules.budget(forShownBars: 1)
            return Double(difference.components.seconds) + Double(difference.components.attoseconds) / 1e18
        }
        #expect(extra(0.05) == 0, "a read that wasn't slow changes nothing")
        #expect(extra(0) == 0)
        #expect(abs(extra(0.6) - 0.5) < 0.001, "the checks that follow the strip take about as long as the read did")
        #expect(abs(extra(30) - 2) < 0.001, "never more than two seconds more")
    }

    // MARK: A read with no bar

    @Test func aLaunchReadThatFindsNoBarIsReadAgainAndTheLaunchIsCaptured() async throws {
        let rig = SessionRig.withAllowlist(sections: sections(hidden: [weather]))
        let captures = await CaptureRig(rig)
        captures.paintEverything()
        rig.world.setWindowsHung(true)

        let starting = Task { await rig.session.start() }
        // MenuBarAgent didn't answer in time: the first read has no bar, and it is asked again after a moment, before anything acts on it.
        #expect(await rig.clock.waitForSleepers(1, within: .seconds(5)))
        #expect(!rig.events.all.contains("apply"), "no plan was applied on a read that was empty")
        rig.world.setWindowsHung(false)
        rig.clock.advance(by: EmptyReadRetry.waits[0])
        await starting.value
        await captures.capturesFinished()

        let log = rig.events.all
        let firstCapture = try #require(log.firstIndex(of: "capture"))
        let firstApply = try #require(log.firstIndex(of: "apply"))
        #expect(firstCapture < firstApply, "the launch was captured before the plan hid anything: \(log)")
        #expect(await captures.appsWithPictures().contains(notes))
    }

    @Test func aLaunchThatCouldNotBeCapturedIsCountedLostAndTheNextMomentTakesThePictures() async throws {
        let rig = SessionRig.withAllowlist(sections: sections(hidden: [weather]))
        let captures = await CaptureRig(rig)
        captures.paintEverything()
        // The bar comes back as the first plan is applied: the read after it is of a bar that has just been changed.
        let world = rig.world
        let events = rig.events
        let allowlist = try #require(rig.allowlist)
        allowlist.onActivated {
            events.add("apply")
            world.setWindowsHung(false)
        }
        world.setWindowsHung(true)
        let clock = rig.clock

        let lines = await LogCapture.lines {
            let starting = Task { await rig.session.start() }
            for wait in EmptyReadRetry.waits {
                guard await clock.waitForSleepers(1, within: .seconds(5)) else { return }
                clock.advance(by: wait)
            }
            await starting.value
        }
        #expect(lines.contains { $0.contains(MenuBarSession.launchCaptureLostLogLine) }, "counted as lost, in a line of its own")
        #expect(captures.capture.displays.isEmpty, "no strip of a bar that was being changed")
        #expect(await captures.store.records().isEmpty)

        // Settings opens, and no picture exists: it takes them.
        clock.advance(by: .seconds(3))
        await captures.session.setSettingsOpen(true)
        await captures.capturesFinished()
        #expect(await captures.appsWithPictures().contains(notes))
    }

    @Test func aLaunchWhoseReadsWereEmptyAndWhosePlanHidesNothingIsCapturedByTheFirstReadThatHasABar() async throws {
        let rig = SessionRig.withAllowlist(sections: sections(shown: [weather, notes, vpn, sync]))
        let captures = await CaptureRig(rig)
        captures.paintEverything()
        let world = rig.world
        let clock = rig.clock
        world.setWindowsHung(true)

        let lines = await LogCapture.lines {
            // Both of the launch's reads come back with no bar, three tries each; the plan that is applied hides nothing.
            let starting = Task { await rig.session.start() }
            for _ in 0..<(2 * EmptyReadRetry.waits.count) {
                guard await clock.waitForSleepers(1, within: .seconds(5)) else { return }
                clock.advance(by: .seconds(1))
            }
            await starting.value
            world.setWindowsHung(false)
            // The spacing of reads is over, so that nothing waits on the clock, which would run the launch capture's budget out.
            clock.advance(by: .seconds(3))
            let session = rig.session
            let done = Mutex(false)
            let reading = Task { _ = await session.readNow(.refresh); done.withLock { $0 = true } }
            defer { reading.cancel() }
            #expect(await waitUntil { done.withLock { $0 } }, "the read came back")
        }
        await captures.capturesFinished()

        // The log is the whole process's, and other tests log the "lost" line on purpose meanwhile (`LogCapture`): that the capture was
        // taken is what says it wasn't lost.
        _ = lines
        #expect(captures.capture.displays.count == 1, "the first read that has a bar takes the launch capture, and not only marks it done")
    }

    @Test func theLaunchCapturesStripOfABarThatAnotherMenuBarAgentHasDrawnSinceKeepsNothing() async throws {
        let rig = SessionRig.withAllowlist(sections: sections(hidden: [weather]))
        let captures = await CaptureRig(rig)
        captures.paintEverything()
        let gate = Gate(), entered = Gate()
        defer { gate.open() }
        captures.capture.hold(at: gate, entered: entered)

        let starting = Task { await rig.session.start() }
        defer { starting.cancel() }
        await entered.wait()
        // MenuBarAgent is started again while the strip is taken: the bar the read was of isn't the one that is drawn now. (The reads that
        // follow are of the new process, which draws the same bars: they answer at once, and nothing waits on the clock for them. The
        // closing wait is only a guard that the launch and its capture end.)
        rig.world.restartAgent()
        gate.open()
        // The check is over before the clock moves: a strip that came back past the launch's budget isn't cropped, whatever the process is,
        // and that would keep nothing without the check this test is of.
        await captures.capturesFinished()
        #expect(await captures.store.records().isEmpty, "the launch capture knows the process the read was taken from")
        let over = Mutex(false)
        let waiting = Task {
            await starting.value
            await captures.capturesFinished()
            over.withLock { $0 = true }
        }
        defer { waiting.cancel() }
        #expect(await rig.clock.advance(by: .seconds(1)) { over.withLock { $0 } }, "the launch and its capture ended")
    }

    @Test func aRecaptureWhoseReadHasNoBarSaysTheBarCouldntBeRead() async throws {
        let rig = SessionRig.withAllowlist(sections: sections(hidden: [weather]))
        let captures = await started(rig)
        rig.world.setWindowsHung(true)
        let session = captures.session
        let result = Mutex<CaptureSummary?>(nil)

        let recapturing = Task { result.withLock { $0 = nil }; let summary = await session.recaptureIcons(); result.withLock { $0 = summary } }
        // The read is asked again after a moment each time, and every time is empty.
        #expect(await rig.driveClock(step: .seconds(1)) { result.withLock { $0 != nil } })
        await recapturing.value

        let summary = try #require(result.withLock { $0 })
        #expect(summary.skipped == "The bar couldn't be read", "not \"No icon to capture\", which is a bar that was read and has none")
        #expect(summary.captured == 0)
    }

    // MARK: A strip whose check doesn't answer

    @Test func aLookThatDidNotAnswerIsAskedAgainAndTheStripIsKept() async throws {
        let rig = SessionRig.withAllowlist(sections: sections(hidden: [weather]))
        let captures = await started(rig)

        // MenuBarAgent doesn't answer the look at the slots after the strip; it does a moment later, and the bar is as it was.
        await settingsStrip(captures) { rig.world.setWindowsHung(true) }
        #expect(await rig.clock.waitForSleepers(3, within: .seconds(5)), "the check waits for the bar to settle")
        rig.world.setWindowsHung(false)
        // Two rounds that agree, after one that didn't answer.
        rig.clock.advance(by: StillCurrentWatch.settleWait)
        #expect(await rig.clock.waitForSleepers(3, within: .seconds(5)))
        rig.clock.advance(by: StillCurrentWatch.settleWait)
        await captures.capturesFinished()

        #expect(await captures.appsWithPictures() == [notes, vpn, sync, system], "slow is not changed")
    }

    @Test func aLaunchWhoseTwoReadsWereBothEmptyIsCountedLostByTheFirstReadThatHasABar() async throws {
        let rig = SessionRig.withAllowlist(sections: sections(hidden: [weather]))
        let captures = await CaptureRig(rig)
        captures.paintEverything()
        let world = rig.world
        let clock = rig.clock
        world.setWindowsHung(true)

        let lines = await LogCapture.lines {
            // Both of the launch's reads come back with no bar, three tries each; the plan is applied meanwhile.
            let starting = Task { await rig.session.start() }
            for _ in 0..<(2 * EmptyReadRetry.waits.count) {
                guard await clock.waitForSleepers(1, within: .seconds(5)) else { return }
                clock.advance(by: .seconds(1))
            }
            await starting.value
            // The bar is there now, after the launch's reads are over: the first read that has one is of a bar the plan has changed.
            world.setWindowsHung(false)
            let session = rig.session
            let done = Mutex(false)
            let reading = Task { _ = await session.readNow(.refresh); done.withLock { $0 = true } }
            _ = await rig.driveClock(step: .seconds(1)) { done.withLock { $0 } }
            await reading.value
        }

        #expect(lines.contains { $0.contains(MenuBarSession.launchCaptureLostLogLine) }, "the lost launch capture is counted: \(lines)")
        #expect(captures.capture.displays.isEmpty)
    }

    @Test func menuBarAgentThatIsNotRunningIsNotASlowOneAndKeepsNothing() async throws {
        let rig = SessionRig.withAllowlist(sections: sections(hidden: [weather]))
        let captures = await started(rig)

        // MenuBarAgent is gone while the strip is back: the bar was redrawn, or isn't there. That isn't a bar that is slow to answer.
        let lines = await LogCapture.lines {
            await self.settingsStrip(captures) { rig.world.setAgentRunning(false) }
            await captures.capturesFinished()
        }

        #expect(await captures.store.records().isEmpty)
        #expect(rig.clock.sleeperCount <= 2, "and nothing waits for it to settle")
        #expect(lines.contains { $0.contains("The bar changed while it was captured (MenuBarAgent isn't running); active") }, "and the log says what it was")
    }

    @Test func menuBarAgentThatWasStartedAgainIsAnotherBarAndKeepsNothing() async throws {
        let rig = SessionRig.withAllowlist(sections: sections(hidden: [weather]))
        let captures = await started(rig)

        let lines = await LogCapture.lines {
            await self.settingsStrip(captures) { rig.world.restartAgent() }
            await captures.capturesFinished()
        }

        #expect(await captures.store.records().isEmpty, "the read was of a bar that another process has drawn since")
        #expect(lines.contains { $0.contains("The bar changed while it was captured (MenuBarAgent is another process than the read's (") },
                "and the log says so")
    }

    @Test func aSlowTreeOfARestartedMenuBarAgentIsTheNewProcessesAndTheFirstIsGone() throws {
        let world = SessionWorld()
        let slow = SlowAX(world: world, clock: FakeClock())
        let first = try #require(world.fixture().pid(of: SessionWorld.agent))
        func windows(of pid: pid_t) -> Int {
            if case .elements(let list)? = try? slow.attribute(AXName.windows, of: slow.application(pid: pid)) { return list.count }
            return 0
        }
        let before = windows(of: first)
        #expect(before > 0)

        world.restartAgent()
        let restarted = try #require(world.scannerApps.first { $0.bundleID == SessionWorld.agent }?.pid)

        #expect(restarted != first)
        #expect(windows(of: restarted) == before, "the new process draws the same bars")
        #expect(windows(of: first) == 0, "the first process has nothing of the tree")
    }

    @Test func aLookThatNeverAnswersKeepsNothingAfterTheRoundsAreUsed() async throws {
        let rig = SessionRig.withAllowlist(sections: sections(hidden: [weather]))
        let captures = await started(rig)
        let clock = rig.clock

        await settingsStrip(captures) { rig.world.setWindowsHung(true) }
        for _ in 1..<StillCurrentWatch.maxRounds {
            #expect(await clock.waitForSleepers(3, within: .seconds(5)))
            clock.advance(by: StillCurrentWatch.settleWait)
        }
        await captures.capturesFinished()

        #expect(await captures.store.records().isEmpty, "when it can't be told that the slots are where they were, nothing is saved")
    }

    @Test func anAppThatDoesNotAnswerDoesNotCostTheOthersTheirPictures() async throws {
        let rig = SessionRig.withAllowlist(sections: sections(hidden: [weather]))
        let captures = await started(rig)
        let clock = rig.clock

        await settingsStrip(captures) { rig.extras.stopAnswering(vpn) }
        for _ in 1..<StillCurrentWatch.maxRounds {
            #expect(await clock.waitForSleepers(3, within: .seconds(5)))
            clock.advance(by: StillCurrentWatch.settleWait)
        }
        await captures.capturesFinished()

        let kept = await captures.appsWithPictures()
        #expect(kept == [notes, sync, system], "the apps whose frames were confirmed are kept, and the one that never answered isn't")
    }

    @Test func anAppThatAnswersOnTheSecondAskIsKept() async throws {
        let rig = SessionRig.withAllowlist(sections: sections(hidden: [weather]))
        let captures = await started(rig)
        let clock = rig.clock

        await settingsStrip(captures) { rig.extras.stopAnswering(vpn, forReads: 1) }
        // The first round confirms the others; the second asks the one that didn't answer, and only that one, again.
        #expect(await clock.waitForSleepers(3, within: .seconds(5)))
        rig.extras.forgetAppsAsked()
        clock.advance(by: StillCurrentWatch.settleWait)
        await captures.capturesFinished()

        #expect(rig.extras.appsAsked == [vpn], "only the app that didn't answer is asked again")
        #expect(await captures.appsWithPictures() == [notes, vpn, sync, system])
    }

    @Test func aBarThatChangedIsStillAChange() async throws {
        let rig = SessionRig.withAllowlist(sections: sections(hidden: [weather]))
        let captures = await started(rig)

        // The hidden provider is fixed first (see `anAppThatAppearsToTheRight…`): the test item gets slots of its own, a real arrival.
        await settingsStrip(captures) {
            rig.world.setHiddenProvider { [weather] }
            rig.world.setTestItemRunning(true)
        }
        await finishCapturing(captures)

        #expect(await captures.appsWithPictures().isEmpty, "an answer that says the slots of an app came throws every picture away, at once")
    }

    /// Takes the strip of a settings capture from a read taken for it, with the strip held while `whileHeld` changes what the world
    /// answers, and answers what the capture said. With a clock, the rounds that follow a look that didn't answer pause on it: it moves by
    /// `step` at each pause until the capture is over, which is at its rounds with the default step and at its bound with a longer one.
    private func settingsCaptureSaying(_ captures: CaptureRig, whileHeld: () -> Void, driving rig: SessionRig? = nil,
                                       by step: Duration = StillCurrentWatch.settleWait,
                                       afterRead: () -> Void = {},
                                       whileTheStripIsOut: @Sendable () async -> Void = {}) async throws -> CaptureSummary {
        let session = captures.session
        let taken = try #require(await session.requestRead(.refresh))
        afterRead()
        let gate = Gate(), entered = Gate()
        defer { gate.open() }
        captures.capture.hold(at: gate, entered: entered)
        let over = Mutex(false)
        let capturing = Task {
            let summary = await session.takePictures(.settingsOpened, taken: taken)
            over.withLock { $0 = true }
            return summary
        }
        await entered.wait()
        whileHeld()
        await whileTheStripIsOut()
        gate.open()
        if let rig {
            // The pauses of the rounds are given as they come (the clock moves only when the check sleeps on it, besides the session's
            // own two sleepers), within the helper's time limit.
            #expect(await rig.driveClock(step: step) { over.withLock { $0 } }, "the capture was over")
        }
        return await capturing.value
    }

    @Test func aCheckWhoseLookNeverAnsweredSaysTheCaptureRanOutOfTime() async throws {
        let rig = SessionRig.withAllowlist(sections: sections(hidden: [weather]))
        let captures = await started(rig)

        let summary = try await settingsCaptureSaying(captures, whileHeld: { rig.world.setWindowsHung(true) }, driving: rig)

        #expect(summary == CaptureSummary(captured: 0, changed: 0, skipped: "The capture ran out of time"), "nothing moved: the bar wasn't seen")
        #expect(await captures.store.records().isEmpty)
    }

    @Test func aCheckThatEndedByItsBoundBeforeItsRoundsSaysTheCaptureRanOutOfTime() async throws {
        let rig = SessionRig.withAllowlist(sections: sections(hidden: [weather]))
        let captures = await started(rig)

        // The look never answers, and each pause moves the clock by half the bound: the check is over at its bound, after two rounds,
        // with its rounds not used. (What the apps were asked is counted from after the read the capture is taken from.)
        let summary = try await settingsCaptureSaying(captures, whileHeld: { rig.world.setWindowsHung(true) }, driving: rig,
                                                      by: StillCurrentWatch.bound / 2, afterRead: { rig.extras.forgetAppsAsked() })

        let rounds = rig.extras.appsAsked.filter { $0 == notes }.count
        #expect(rounds == 2 && rounds < StillCurrentWatch.maxRounds, "the bound ended it, after two rounds: \(rounds) rounds")
        #expect(summary == CaptureSummary(captured: 0, changed: 0, skipped: "The capture ran out of time"))
        #expect(await captures.store.records().isEmpty)
    }

    @Test func anAppThatNeverAnswersIsOutOfTimeAtTheLastRoundEvenWhenTheLookAnsweredWhole() async throws {
        let rig = SessionRig.withAllowlist(sections: sections(hidden: [weather]))
        let captures = await started(rig)
        let session = captures.session
        let taken = try #require(await session.requestRead(.refresh))
        let display = try #require(taken.inventory.barSlots.keys.first)
        rig.extras.stopAnswering(vpn)
        rig.extras.forgetAppsAsked()

        // The look is the same in every round, and the one app asked never answers: nothing was seen to move.
        let over = Mutex(false)
        let checking = Task {
            let answer = await session.isStillCurrent(taken: taken, display: display, apps: [vpn], generation: nil)
            over.withLock { $0 = true }
            return answer
        }
        // The clock moves only when the check sleeps on it (besides the session's own two sleepers), within the helper's time limit.
        #expect(await rig.driveClock(step: StillCurrentWatch.settleWait) { over.withLock { $0 } }, "the check was over")
        let answer = await checking.value

        #expect(answer.kept.isEmpty)
        #expect(answer.outOfTime, "no look differed and the app wasn't judged: the check ran out of its rounds")
        #expect(rig.extras.appsAsked.filter { $0 == vpn }.count == StillCurrentWatch.maxRounds, "and it used its rounds")
    }

    @Test func aCheckThatSawTheBarDifferStillSaysTheBarChanged() async throws {
        let rig = SessionRig.withAllowlist(sections: sections(hidden: [weather]))
        let captures = await started(rig)

        // The clock's slot, at the bar's right edge, is gone: every slot is either it or left of it, and nothing is where it was known to be.
        let summary = try await settingsCaptureSaying(captures, whileHeld: { rig.world.setParked(["clock"]) })

        #expect(summary == CaptureSummary(captured: 0, changed: 0, skipped: "The bar changed while it was captured"))
        #expect(await captures.store.records().isEmpty)
    }

    // MARK: Quitting

    @Test func quittingTellsTheReadersToStopWaiting() async throws {
        let rig = SessionRig.withAllowlist(sections: sections(hidden: [weather]))
        await rig.session.start()
        #expect(rig.world.stopWaitingCalls == 0)

        await rig.session.tearDownForQuit()
        #expect(rig.world.stopWaitingCalls == 1)
    }

    @Test func aQuitWhoseEngineAnswersSlowlyIsAnsweredWithinItsBound() async throws {
        let rig = SessionRig.withAllowlist(sections: sections(hidden: [weather], alwaysHidden: [notes]))
        await rig.session.start()
        let allowlist = try #require(rig.allowlist)
        let before = allowlist.calls.count
        let gate = Gate()
        allowlist.holdActivations(until: gate)
        defer { gate.open() }
        // A plan is being applied by an engine that takes its time (the preferences service disagrees), and the quit comes behind it.
        let applying = Task { await rig.session.applyReveal(.hiddenShown) }
        #expect(await waitUntil { allowlist.calls.count == before + 1 })
        let clock = rig.clock
        let answered = Mutex(false)

        let quitting = Task {
            await rig.session.tearDownForQuit()
            answered.withLock { $0 = true }
        }
        // Something sleeps on the clock once the quit waits (the bound, or another wait that comes and goes: the polling until the quit
        // stops it), and the quit isn't answered while the clock stands still, since the engine still holds.
        #expect(await waitUntil { clock.sleeperCount > 0 })
        #expect(!answered.withLock { $0 }, "it waits for the engine")
        // The clock is moved by the bound each time something sleeps on it, until the quit is answered, with the engine still holding. One
        // move isn't enough on a busy Mac: a move that comes before the bound has begun to sleep wakes only the other sleeper.
        #expect(await clock.advance(by: MenuBarSession.quitTeardownLimit, until: { answered.withLock { $0 } }),
                "and is let go of at its bound, by the clock, with the engine still holding")
        // Let go of the engine before the quit is awaited: a quit that isn't bound then ends, and the test fails instead of hanging.
        gate.open()
        await quitting.value
        _ = await applying.value
    }

    // MARK: Over patient Accessibility

    /// What a session over `PatientAX` and a slow MenuBarAgent is given: the slow fake, to hold up or hang MenuBarAgent.
    private final class Patient: Sendable {
        private let made = Mutex<(slow: SlowAX, patient: PatientAX)?>(nil)
        private let patience: AXPatience
        var slow: SlowAX { made.withLock { $0!.slow } }

        init(patience: AXPatience = .standard) {
            self.patience = patience
        }

        func reading(_ world: SessionWorld, _ clock: FakeClock) -> any AXReading {
            let slow = SlowAX(world: world, clock: clock)
            let patient = PatientAX(inner: slow, patience: patience, clock: clock, pidOf: { [world] in world.ownerPID(of: $0) ?? 0 })
            made.withLock { $0 = (slow, patient) }
            return patient
        }
    }

    @Test func aBarThatIsLateIsNotAChangeWhenTheSessionIsPatient() async throws {
        let late = Patient()
        let rig = SessionRig.withAllowlist(sections: sections(hidden: [weather]), reading: late.reading)
        let captures = await started(rig)
        let agent = rig.world.app(SessionWorld.agent).pid

        // MenuBarAgent takes 1.3 s to answer the look after the strip: its third wait has the answer, and the first round decides.
        await settingsStrip(captures) { late.slow.setDelay(1.3, for: agent, forCalls: 2) }
        await captures.capturesFinished()

        #expect(await captures.appsWithPictures() == [notes, vpn, sync, system], "no round of waiting for the bar to settle was needed")
        #expect(late.slow.calls(to: agent).contains { $0.wait > 1 }, "it was waited for past the second wait, with what the round had left (1.75 s)")
    }

    @Test func aCheckWhoseBarNeverAnswersIsOverWithinItsBoundOnTheClockAndTheLookHasItsShare() async throws {
        let late = Patient()
        let rig = SessionRig.withAllowlist(sections: sections(hidden: [weather]), reading: late.reading)
        let captures = await started(rig)
        let agent = rig.world.app(SessionWorld.agent).pid
        let callsBefore = Mutex(0)

        // One app takes 2.5 s to say where its icons are (an answer at its third wait) and MenuBarAgent doesn't answer at all. Each round's
        // apps' frames are given half of what is left of the bound and the look the rest, whatever the apps took: the apps' frames are cut
        // at a second and a half, the look is asked with the second and a half that is left (a first wait of a quarter of a second, then a
        // second), and the check is over at its three seconds, with no pause of the clock. (A look given its own four seconds would take
        // the 3.25 s of the whole ladder, after the apps' 2.5.)
        await settingsStrip(captures) {
            callsBefore.withLock { $0 = late.slow.calls.count }
            rig.extras.answerAfter(2.5, on: rig.clock, app: vpn)
            late.slow.hang(agent)
        }
        let finished = Mutex(false)
        let waiting = Task {
            await captures.capturesFinished()
            finished.withLock { $0 = true }
        }
        defer { waiting.cancel() }
        // A check that goes on to another round pauses on a clock that nothing moves here: the test fails at the limit and doesn't hang.
        #expect(await waitUntil { finished.withLock { $0 } }, "the check was over at its bound")

        #expect(await captures.store.records().isEmpty)
        // The look is the first thing MenuBarAgent is asked after the strip (what is asked later is the session's own reads).
        let asked = late.slow.calls.dropFirst(callsBefore.withLock { $0 }).filter { $0.pid == agent }.prefix(2).map(\.wait)
        #expect(asked == [0.25, 1], "the look was asked with the half the apps left it, and no more: \(asked)")
    }

    @Test func aLookThatWasCutShortIsNotAChangeAndTheNextRoundsKeepThePictures() async throws {
        // A ladder of 0.25, 0.5 and 0.5 s: a query that misses all of it takes 1.25 s of the check's three seconds.
        let late = Patient(patience: AXPatience(waits: [0.25, 0.5, 0.5], unknownAppWaits: 2, silentAppWaits: 1, perAppBudget: 4, learnedFor: 30))
        let rig = SessionRig.withAllowlist(sections: sections(hidden: [weather]), reading: late.reading)
        let captures = await started(rig)
        let agent = rig.world.app(SessionWorld.agent).pid
        let clock = rig.clock

        // The look in the first round: the window's place is read (let through), and then the first slot's frame misses every wait. That
        // slot has no frame in the look, so the look has one slot fewer than the read had: it is cut, and it isn't a changed bar.
        await settingsStrip(captures) { late.slow.miss(AXName.position, of: agent, skipping: 1, calls: 3) }
        // The first round didn't confirm anything; the second and the third, with the bar answering, agree, and are the ones that confirm.
        for _ in 0..<2 {
            #expect(await clock.waitForSleepers(3, within: .seconds(5)))
            clock.advance(by: StillCurrentWatch.settleWait)
        }
        await captures.capturesFinished()

        #expect(await captures.appsWithPictures() == [notes, vpn, sync, system], "a look that was cut is no look, and the rounds that follow decide")
    }

    @Test func aQuitThatBeginsWhileAQueryIsInItsLadderEndsTheLadderAndTheRead() async throws {
        let late = Patient()
        let rig = SessionRig.withAllowlist(sections: sections(hidden: [weather]), reading: late.reading)
        await rig.session.start()
        let agent = rig.world.app(SessionWorld.agent).pid
        late.slow.hang(agent)
        let before = late.slow.calls(to: agent).count
        let scanner = await rig.session.scanner
        // The first wait is spent, and the quit begins: the readers are told, as the quit does at its very start.
        late.slow.onTimeout { scanner.stopWaiting() }

        // A scan that sleeps through its tries on a clock nothing moves is not waited for beyond the limit: the test fails, and doesn't hang.
        let result = Mutex<Inventory?>(nil)
        let scanning = Task { let taken = await scanner.scan(); result.withLock { $0 = taken } }
        defer { scanning.cancel() }
        #expect(await waitUntil { result.withLock { $0 } != nil }, "the scan didn't sleep through its tries")
        let read = try #require(result.withLock { $0 })

        #expect(late.slow.calls(to: agent).count - before == 1, "the 1 s and the 2 s weren't spent")
        #expect(read.problems == [.agentHasNoWindows])
        #expect(rig.clock.sleeperCount <= 2, "and the read didn't sleep through its tries again")
    }
}
