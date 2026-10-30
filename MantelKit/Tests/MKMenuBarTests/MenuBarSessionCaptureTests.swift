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

/// A session, and what takes the pictures of its icons: a collector over a fake capture and a store in a temporary folder.
private struct CaptureRig {
    let rig: SessionRig
    let capture: FakeCapture
    let store: ItemImageStore
    let collector: ItemImageCollector
    let folder: TemporaryFolder
    /// The apps the bar had concealed each time a strip was taken.
    let concealedWhenTaken = ConcealedLog()

    var session: MenuBarSession { rig.session }

    init(_ rig: SessionRig) async {
        self.rig = rig
        let capture = FakeCapture(clock: rig.clock)
        let folder = TemporaryFolder(prefix: "mantel-session-capture")
        let store = ItemImageStore(folder: folder.url.appending(path: "ItemImages", directoryHint: .isDirectory), clock: rig.clock)
        let world = rig.world
        collector = ItemImageCollector(store: store,
                                       capture: LoggingCapture(inner: capture, events: rig.events, world: world, concealedWhenTaken: concealedWhenTaken),
                                       layout: { world.layout }, windows: world.windowList, screenRecordingGranted: { true },
                                       mayCapture: { nil }, clock: rig.clock, rules: .measured)
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
}

/// Where the session takes the pictures of the icons: at launch, when a reveal was seen, when Settings opens and when asked to
/// recapture.
@Suite("Menu bar session: capture moments", .timeLimit(.minutes(1)))
struct MenuBarSessionCaptureTests {
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

    @Test(arguments: [(SessionWorld.Shape.laptop, 226), (SessionWorld.Shape.desk, 452)])
    func launchBudgetFollowsTheShownBars(shape: SessionWorld.Shape, milliseconds: Int) async throws {
        _ = try await startWithACaptureThatNeverReturns(shape: shape, budget: .milliseconds(milliseconds))
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

    // MARK: A reveal's capture, taken again

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

    @Test(arguments: [false, true]) func twoIconsOfOneWidthThatTradePlacesWhileTheStripIsTakenSaveNothing(unnamed: Bool) async throws {
        // The notes app's icon and the VPN app's are both 36 wide and have no name on their slots (AppKit's `_NS:` isn't one): the slots
        // are where they were. The apps' frames have traded places.
        let rig = SessionRig.withAllowlist(sections: sections(hidden: [weather]))
        rig.world.setNameless(unnamed)
        let (_, apps) = await settingsStrip(over: rig) { $0.setFrameShifts([notes: 44, vpn: -44]) }
        #expect(apps == [sync, system], "the two that traded places keep nothing; an app whose icon didn't move keeps its pictures: \(apps)")
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

    // MARK: A strip whose check doesn't answer

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

    // MARK: Quitting

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
