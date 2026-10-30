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

/// The session and the layout writer: what asks for a write, what is never allowed to, and how the session follows the order macOS shows
/// (the table when it is granted and its keys cover the apps, else the bar), over a writer that touches no file.
///
/// The desk's bar, left to right: Mantel's two dots, the weather app's two items, the notes app's, the VPN app's and the sync app's two
/// (`SessionWorld.setItemOrder` changes it).
@Suite("Menu bar session: layout", .timeLimit(.minutes(1)))
struct MenuBarSessionLayoutTests {
    private typealias F = LayoutFixtures

    private let temp = ItemID(bundleID: weather, key: .identifier("weather.temp"))
    private let alerts = ItemID(bundleID: weather, key: .identifier("weather.alerts"))
    private let notes0 = ItemID(bundleID: notes, key: .index(0))
    private let vpn0 = ItemID(bundleID: vpn, key: .index(0))
    private let sync0 = ItemID(bundleID: sync, key: .index(0))
    private let sync1 = ItemID(bundleID: sync, key: .index(1))

    /// The items of the desk's bar, by the names the world draws them by, with Mantel's dots in the order the arrangement has them.
    private static let barOrder = ["mantel.dot.always", "mantel.dot.hidden", "weather.temp", "weather.alerts", "Notes", "_NS:93", "Sync B",
                                   "Sync A"]

    private struct Rig {
        let rig: SessionRig
        let writer: FakeLayoutWriter
        let phases: PhaseLog
        let applier: LayoutApplier
        var session: MenuBarSession { rig.session }
        var world: SessionWorld { rig.world }

        /// Moves the clock, a step at a time, until the condition holds (the applier's debounce and waits are on the session's clock).
        func drive(step: Duration = .milliseconds(250), until done: @escaping @Sendable () async -> Bool) async -> Bool {
            let clock = rig.clock
            return await withinTimeLimit(.seconds(10)) {
                while await !done() {
                    if await clock.waitForSleepers(3, within: .milliseconds(20)) { clock.advance(by: step) }
                }
                return true
            } ?? false
        }

        /// Until the applier has nothing pending.
        func settled() async -> Bool {
            let applier = applier
            return await drive { await !applier.status().isPending }
        }

        func sections() async -> SectionModel { await session.sections }

        func shownOrder() async -> [ItemID] { await session.sections.items(in: .shown).filter { !$0.isSystem } }
    }

    private func started(sections initial: SectionModel? = nil, rules: LayoutRules = F.rules(), settings: LayoutSettings = LayoutSettings(),
                         dots: DotSettings = DotSettings(), availability: LayoutWriterAvailability = .available,
                         shape: SessionWorld.Shape = .desk, capacity: Int? = nil, testItem testItemRunning: Bool = false,
                         ordered: Bool = true, settleFromTheStart: Bool = false, endGate: Gate? = nil,
                         staleConcealed: Bool = false) async -> Rig {
        let rig = SessionRig.withAllowlist(shape: shape, testItem: testItemRunning, capacity: capacity, staleConcealed: staleConcealed,
                                           sections: initial ?? sections(shown: [weather, notes, vpn, sync]))
        if ordered { rig.world.setItemOrder(Self.barOrder) }
        let writer = FakeLayoutWriter()
        writer.availabilityNow = availability
        let phases = PhaseLog()
        let session = rig.session
        let world = rig.world
        let applier = LayoutApplier(
            writer: writer, rules: rules, clock: rig.clock, read: { await session.readForCheck() },
            shownBars: { BarVisibility.shownBars(world.windowList.onScreenWindows(), bars: $0.bars) },
            phase: { pending, settling, revision in
                phases.add(pending, settling, revision)
                // The end of a request, held before the session is told: another request can come in meanwhile.
                if !pending { await endGate?.wait() }
                await session.setLayoutPhase(pending: pending, settling: settling, revision: revision)
            },
            held: { nil })
        await session.setLayout(applier, rules: rules, settings: settings, dots: dots)
        if settleFromTheStart { await session.setLayoutPhase(pending: true, settling: true) }
        await session.start()
        let made = Rig(rig: rig, writer: writer, phases: phases, applier: applier)
        // The status stream tells the session whether the table can be written.
        _ = await withinTimeLimit(.seconds(5)) {
            while await session.layoutStatus?.availability != availability { await Task.yield() }
            return true
        }
        return made
    }

    /// The bar drawn in this order from now on.
    private func draw(_ rig: Rig, _ order: [String]) {
        rig.world.setItemOrder(order)
    }

    // MARK: The settle window

    @Test func readDuringLayoutSettleIsNotJudged() async throws {
        // The laptop's bar has room for five icons: the weather app's two and the notes app's are piled at the « and, judged, move to Hidden.
        // Not while the bar is being re-sorted by a write: the pile says nothing then.
        let world = await started(shape: .laptop, capacity: 5, ordered: false, settleFromTheStart: true)
        #expect(await world.session.isLayoutSettling)
        let kept = AppPlacement(section: .shown, isAuto: false)
        #expect(await world.sections().apps[weather] == kept)
        #expect(await world.sections().apps[notes] == kept)

        // Once the bar is still, the next read is judged, as any is.
        await world.session.setLayoutPhase(pending: false, settling: false)
        #expect(await world.session.isLayoutSettling == false)
        await world.session.refresh()
        #expect(await world.sections().apps[weather] == AppPlacement(section: .hidden, isAuto: true))
        #expect(await world.sections().apps[notes] == AppPlacement(section: .hidden, isAuto: true))
    }

    @Test func settlingAndPendingBumpTheBarChanges() async {
        let world = await started()
        let session = world.session
        let before = await session.barChanges
        await session.setLayoutPhase(pending: true, settling: false)
        let pending = await session.barChanges
        #expect(pending == before + 1, "a write becomes pending")
        await session.setLayoutPhase(pending: true, settling: true)
        let settling = await session.barChanges
        #expect(settling == pending + 1, "and again when it starts settling: a strip that spans it isn't kept")
        await session.setLayoutPhase(pending: false, settling: false)
        #expect(await session.barChanges == settling + 1, "and when it is over")
    }

    @Test func capturesSkipWhileSettling() async throws {
        let world = await started()
        let session = world.session
        let clock = FakeClock()
        let windows = FakeWindowList([CollectorWorld.barWindow()])
        let folder = TemporaryFolder(prefix: "mantel-layout-capture")
        let store = ItemImageStore(folder: folder.url.appending(path: "ItemImages", directoryHint: .isDirectory), clock: clock)
        let capture = FakeCapture(clock: clock)
        capture.paint([CollectorWorld.slot(0), CollectorWorld.slot(1)])
        let collector = ItemImageCollector(store: store, capture: capture, layout: { CollectorWorld.displayLayout() }, windows: windows,
                                           screenRecordingGranted: { true }, mayCapture: { await session.layoutCaptureRefusal },
                                           clock: clock, rules: .provisional)
        let a = CollectorWorld.id("a")
        let read = CollectorWorld.inventory([CollectorWorld.item(a, bundleID: "com.example.a", slot: 0)])
        let location = ItemLocation(item: a, displayUUID: CollectorWorld.display, slotFrame: CollectorWorld.slot(0), tiedBy: .tie,
                                    slotWasInBaseline: true, widthAgrees: true)
        let moments: [CaptureMoment] = [.launch, .revealSeen(["com.example.a"]), .clickDrawn(location), .settingsOpened, .recapture]
        #expect(Set(moments.map(\.kind)) == Set(CaptureMomentKind.allCases), "every moment there is")

        await session.setLayoutPhase(pending: true, settling: true)
        for moment in moments {
            let summary = await collector.capture(moment, read: read, concealed: [])
            #expect(summary.captured == 0 && summary.skipped == "The menu bar is being re-sorted.", "\(moment.kind)")
        }
        #expect(capture.displays.count == 0, "no strip of the bar was taken")

        // Pending alone doesn't stop a picture: the bar isn't moving yet.
        await session.setLayoutPhase(pending: true, settling: false)
        #expect(await session.layoutCaptureRefusal == nil)
        await session.setLayoutPhase(pending: false, settling: false)
        #expect(await collector.capture(.settingsOpened, read: read, concealed: []).captured == 1)
    }

    @Test func theCollectorsRefusalIsTheSessionsWhileSettling() async {
        let world = await started()
        #expect(await world.session.layoutCaptureRefusal == nil)
        await world.session.setLayoutPhase(pending: true, settling: true)
        #expect(await world.session.layoutCaptureRefusal == LayoutWords.resorting)
        #expect(LayoutWords.resorting == "The menu bar is being re-sorted.")
        // `recaptureIcons` itself is skipped before it shows anything: `MenuBarSessionCaptureTests.recaptureSkippedWhileTheBarIsBeingResorted`.
    }

    // MARK: A drop waits to be written

    @Test func followDuringDebounceKeepsTheDrop() async throws {
        let world = await started()
        let order = await world.shownOrder()
        #expect(Array(order.prefix(3)) == [temp, alerts, notes0], "the bar's order is the sections'")

        // A read of the bar begins and is held up, as one that takes its time is: it is of the bar as it is before the drop.
        let gate = Gate()
        world.rig.extras.holdReads(at: gate)
        let session = world.session
        let stale = Task { await session.readNow(.layoutCheck) }
        #expect(await waitUntil { world.rig.extras.readsHeld >= 1 })

        // The person drops the notes app's icon first. The write waits for its second of quiet; the read is let go meanwhile.
        await session.insert(notes0, in: .shown, at: 0)
        gate.open()
        world.rig.extras.holdReads(at: nil)
        _ = await stale.value
        _ = await session.readNow(.layoutCheck)

        let dropped = await world.shownOrder()
        #expect(Array(dropped.prefix(3)) == [notes0, temp, alerts], "neither read put the bar's order back over the drop")
        #expect(world.writer.writeCount == 0, "and nothing was written yet")
        #expect(await world.applier.status().isPending)

        // It is written as dropped.
        #expect(await world.settled())
        let write = try #require(world.writer.writes.first)
        let tokens = write.arrangement.tokens
        #expect(try #require(tokens.firstIndex(of: .item(notes0))) < #require(tokens.firstIndex(of: .item(temp))))
    }

    @Test func pendingIsSetBeforeRequest() async throws {
        let world = await started()
        let session = world.session
        // The bar shows the notes app first; the person's change isn't at the applier yet (the session has begun to ask).
        draw(world, ["mantel.dot.always", "mantel.dot.hidden", "Notes", "weather.temp", "weather.alerts", "_NS:93", "Sync B", "Sync A"])
        #expect(await world.shownOrder().first == temp)
        let began = await session.beginLayoutRequest()
        #expect(began)
        #expect(await session.layoutIsPending, "pending already: no read between the change and the request is followed")
        #expect(await world.applier.status().isPending == false, "though the applier has heard nothing")

        _ = await session.readNow(.layoutCheck)
        #expect(await world.shownOrder().first == temp, "the read followed nothing")

        // Asked, and written: once it is verified (the world doesn't re-sort, so the order the bar shows is what is followed after).
        await session.sendLayoutRequest(.person, began: began)
        #expect(await world.settled())
        #expect(await session.layoutIsPending == false)
        _ = await session.readNow(.layoutCheck)
        #expect(await world.shownOrder().first == notes0, "followed again once it is over")
    }

    @Test func memoryFromTheReportIsKept() async throws {
        var rules = F.rules(.byDistance(tolerance: 10_000))
        rules.reference = .rightEdge
        let world = await started(rules: rules)
        let key = LayoutKey.status(bundleID: notes, autosaveName: "Item-0")
        world.writer.table = LayoutTableSnapshot(distances: [key: 150])

        await world.session.move(app: vpn, to: .hidden)
        #expect(await world.settled())

        // The resolver matched the notes app's only item to the one key it has; the report brought that back, and the session keeps it.
        #expect(try #require(await world.applier.status().lastReport).memory == [notes0: key])
        let kept = await withinTimeLimit(.seconds(5)) {
            while await world.session.layoutMemory[notes0] != key { await Task.yield() }
            return true
        }
        #expect(kept == true)
        #expect(await world.session.layoutMemory == [notes0: key])
    }

    @Test func writtenAppsForgetWhereTheirItemsSat() async throws {
        let world = await started(rules: F.rules(.autosaveIndex(prefix: "Item-")))
        let rig = world.rig
        // The sync app's two items have been seen drawn together: their places are known.
        _ = await world.session.readNow(.layoutCheck)
        #expect(await rig.session.scanner.memory.places(ofApp: sync, covering: [0, 1]) != nil)
        // Every app has its places in the table (an app whose place can't be told stops the write), the sync app's two at 100 and 90.
        func item(_ app: String, _ name: String) -> String { LayoutKey.status(bundleID: app, autosaveName: name) }
        world.writer.table = LayoutTableSnapshot(distances: [
            item(weather, "weather.temp"): 300, item(weather, "weather.alerts"): 290, item(notes, "Item-0"): 250, item(vpn, "Item-0"): 200,
            item(sync, "Item-0"): 100, item(sync, "Item-1"): 90])

        await world.session.move(app: vpn, to: .hidden)
        #expect(await world.settled())
        _ = await withinTimeLimit(.seconds(5)) {
            while await world.session.lastTakenReport == nil { await Task.yield() }
            return true
        }

        // Mantel wrote the order of its items: what was learned of where they sit is of the order they had.
        #expect(try #require(await world.session.lastTakenReport).appsWritten.contains(sync))
        #expect(await rig.session.scanner.memory.places(ofApp: sync, covering: [0, 1]) == nil)
    }

    // MARK: What asks for a write

    @Test func personMoveRequestsWrite() async throws {
        let world = await started()
        await world.session.move(app: notes, to: .hidden)
        #expect(await world.settled())
        #expect(world.writer.writeCount == 1)

        // The other things the person does ask too.
        let spacer = LayoutSpacer(width: 20)
        await world.session.addSpacer(spacer, in: .shown, at: 0)
        #expect(await world.settled())
        #expect(world.writer.writeCount == 2)
        await world.session.updateSpacer(LayoutSpacer(id: spacer.id, width: 40))
        #expect(await world.settled())
        #expect(world.writer.writeCount == 3)
        await world.session.removeOwnItem(OwnItems.itemID(spacer.id))
        #expect(await world.settled())
        #expect(world.writer.writeCount == 4)

        let group = IconGroup(title: "Work", members: [])
        await world.session.addGroup(group, in: .alwaysHidden, at: 0)
        #expect(await world.settled())
        #expect(world.writer.writeCount == 5)
        await world.session.move(app: vpn, toGroup: group.id, at: 0)
        #expect(await world.settled())
        #expect(world.writer.writeCount == 6)
        await world.session.setNewItemsMarker(section: .shown, index: 1)
        #expect(await world.settled())
        #expect(world.writer.writeCount == 7)
        await world.session.move(item: temp, to: .hidden)
        #expect(await world.settled())
        #expect(world.writer.writeCount == 8)
        await world.session.insert(temp, in: .shown, at: 0)
        #expect(await world.settled())
        #expect(world.writer.writeCount == 9)
    }

    @Test func aMoveThatChangesNothingRequestsNothing() async throws {
        let world = await started()
        await world.session.move(app: notes, to: .shown)
        for _ in 0..<20 { world.rig.clock.advance(by: .milliseconds(250)) }
        #expect(world.writer.writeCount == 0)
        #expect(await world.applier.status().isPending == false)
        #expect(await world.session.layoutIsPending == false)
    }

    @Test func ownItemVisibilityToggleRequestsNoWrite() async throws {
        // A spacer in Hidden, and the test item (not running) in Always Hidden.
        var model = sections(shown: [weather, notes, vpn, sync], hidden: [])
        let spacer = LayoutSpacer(width: 20)
        model.addSpacer(spacer, in: .hidden, at: 0)
        model.move(app: testItem, to: .alwaysHidden)
        let world = await started(sections: model)
        let spacerName = try #require(OwnItems.autosaveName(of: OwnItems.itemID(spacer.id)))
        let alwaysDot = OwnItems.alwaysDotName
        func shown() async throws -> OwnItemsShown {
            let state = try #require(await world.rig.state)
            return OwnItemsVisibility.shown(sections: state.sections, plan: state.plan, dots: DotSettings(),
                                            alwaysHiddenHasApps: state.alwaysHiddenHasApps)
        }
        /// What the last read lists of Mantel's own, as the app draws it: an own item that is off the bar (`isVisible` false) isn't listed.
        func listed(_ kind: OwnItemKind) async throws -> Bool {
            try #require(await world.rig.state).inventory.items.contains { $0.isMantel && $0.ownKind == kind }
        }
        // Collapsed: the spacer in Hidden and •• (nothing running in Always Hidden) are off the bar, so the reads don't list them.
        world.world.setOwnItems(listed: [], omitted: [alwaysDot])
        await world.session.refresh()
        let collapsed = try await shown()
        #expect(collapsed.spacers.isEmpty, "the spacer in Hidden is off the bar with Hidden")
        #expect(!collapsed.alwaysDot, "nothing running is in Always Hidden")
        #expect(try await !listed(.spacer))
        #expect(try await !listed(.alwaysDot))

        // A reveal shows the Hidden spacer (the read lists it from then on), and the collapse takes it off again (and the read drops it).
        world.world.setOwnItems(listed: [spacerName], omitted: [alwaysDot])
        _ = await world.session.applyReveal(.hiddenShown)
        await world.session.refresh()
        #expect(try await shown().spacers == [spacer.id])
        #expect(try await listed(.spacer), "the read has the spacer under Mantel's bundle ID")
        world.world.setOwnItems(listed: [], omitted: [alwaysDot])
        _ = await world.session.applyReveal(.collapsed)
        await world.session.refresh()
        #expect(try await shown().spacers.isEmpty)
        #expect(try await !listed(.spacer))

        // •• comes by itself when the app in Always Hidden starts, and goes when it quits.
        world.world.setTestItemRunning(true)
        world.world.setOwnItems(listed: [], omitted: [])
        await world.session.refresh()
        #expect(try await shown().alwaysDot)
        #expect(try await listed(.alwaysDot), "the read has •• under Mantel's bundle ID")
        world.world.setTestItemRunning(false)
        world.world.setOwnItems(listed: [], omitted: [alwaysDot])
        await world.session.refresh()
        #expect(try await !listed(.alwaysDot))

        for _ in 0..<20 { world.rig.clock.advance(by: .milliseconds(250)) }
        #expect(world.writer.writeCount == 0, "none of it asked the applier for a write")
        #expect(world.phases.count == 0, "the layout was never pending")
        #expect(await world.applier.status().isPending == false)
        #expect(await world.session.layoutIsPending == false)
    }

    @Test func aFollowWhoseReadHasNoBarsLeavesNoDragOpen() async throws {
        let world = await started()
        let session = world.session
        await session.commandDragBegan()
        #expect(await session.layoutCaptureRefusal == LayoutWords.resorting)
        // MenuBarAgent is restarting: the read finds no bar, so it is never followed.
        world.world.setAgentRunning(false)
        let ended = Task { await session.commandDragEnded() }
        #expect(await world.rig.clock.waitForSleepers(3, within: .seconds(5)))
        world.rig.clock.advance(by: LayoutFollower.commandDragFollowDelay)
        for wait in LayoutFollower.commandDragRetryWaits {
            #expect(await world.rig.clock.waitForSleepers(3, within: .seconds(5)))
            world.rig.clock.advance(by: wait)
        }
        await ended.value
        #expect(await session.layoutCaptureRefusal == nil, "the drag is over: captures and clicks are not blocked until the next drag")
        #expect(await session.dragBefore == nil)
    }

    @Test func capturesSkipBetweenACommandDragsBeginAndItsEnd() async throws {
        let world = await started()
        let session = world.session
        #expect(await session.layoutCaptureRefusal == nil)
        await session.commandDragBegan()
        #expect(await session.layoutCaptureRefusal == LayoutWords.resorting, "every capture moment asks this first")

        let ended = Task { await session.commandDragEnded() }
        #expect(await world.rig.clock.waitForSleepers(3, within: .seconds(5)))
        #expect(await session.layoutCaptureRefusal == LayoutWords.resorting, "still under way while the follow waits")
        world.rig.clock.advance(by: LayoutFollower.commandDragFollowDelay)
        await ended.value
        #expect(await session.layoutCaptureRefusal == nil, "the follow ended it")
    }

    @Test func autoOverflowMoveRequestsNoWrite() async throws {
        let world = await started(shape: .laptop, capacity: 5, ordered: false)
        #expect(await world.sections().apps[weather] == AppPlacement(section: .hidden, isAuto: true), "the bar moved them by itself")
        await world.session.refresh()
        for _ in 0..<20 { world.rig.clock.advance(by: .milliseconds(250)) }
        #expect(world.writer.writeCount == 0)
        #expect(world.phases.count == 0, "the layout was never pending")
        #expect(await world.applier.status().isPending == false)
    }

    @Test func launchReadNeverWrites() async throws {
        // The marker is placed, and apps that were never seen are found by the launch's reads: they are filed at it, and wait for the next
        // write.
        var model = sections(shown: [weather, notes])
        model.setNewItemsMarker(section: .shown, index: 1)
        #expect(model.newItemsIndex != nil)
        let world = await started(sections: model)
        #expect(await world.sections().apps[vpn] != nil, "the apps found at launch were placed")
        #expect(await world.applier.status().isPending == false, "no write was asked for")
        #expect(await world.session.layoutIsPending == false)
        for _ in 0..<20 { world.rig.clock.advance(by: .milliseconds(250)) }
        #expect(world.writer.writeCount == 0)
        #expect(world.phases.count == 0)
    }

    @Test func newAppsWhileRunningAtPlacedMarkerRequestWrite() async throws {
        var model = sections(shown: [weather, notes, vpn, sync])
        model.setNewItemsMarker(section: .shown, index: 1)
        let world = await started(sections: model)
        #expect(world.writer.writeCount == 0)

        // An app that starts while Mantel runs appears in a read.
        world.world.setTestItemRunning(true)
        await world.session.refresh()
        #expect(await world.sections().apps[testItem] != nil)
        #expect(await world.settled())
        #expect(world.writer.writeCount == 1)
    }

    @Test func newAppsWithoutPlacedMarkerRequestNoWrite() async throws {
        let world = await started()
        #expect(await world.sections().newItemsIndex == nil)
        world.world.setTestItemRunning(true)
        await world.session.refresh()
        #expect(await world.sections().apps[testItem] != nil, "it was placed")
        #expect(await world.applier.status().isPending == false, "no write was asked for")
        #expect(await world.session.layoutIsPending == false)
        for _ in 0..<20 { world.rig.clock.advance(by: .milliseconds(250)) }
        #expect(world.writer.writeCount == 0)
        #expect(world.phases.count == 0)
    }

    @Test func aChangeOfTheDotsPlacementOrTheDividerRequestsAWrite() async throws {
        // No wait for the bar: this is about what asks for a write, and a bar that still shows the old order would be written again.
        var offered = F.rules(.autosaveIndex(prefix: "Item-"), wait: .zero)
        offered.dotsPlacementOffered = true
        let world = await started(rules: offered)
        world.writer.table = fullTable()
        var settings = LayoutSettings()
        settings.dotsPlacement = .besideClock
        await world.session.setLayout(world.applier, rules: offered, settings: settings, dots: DotSettings())
        #expect(await world.settled())
        #expect(world.writer.writeCount == 1)
        #expect(world.writer.writes[0].arrangement.tokens.last == .dot(.hidden), "beside the clock: the dots are last")

        var dots = DotSettings()
        dots.showsDivider = true
        await world.session.setLayout(world.applier, rules: offered, settings: settings, dots: dots)
        #expect(await world.settled())
        #expect(world.writer.writeCount == 2)
        #expect(world.writer.writes[1].arrangement.tokens.contains(.divider))

        // The same settings again, and a dots' setting that only hides them, are not changes of the arrangement.
        var hidden = dots
        hidden.hideBothDots = true
        await world.session.setLayout(world.applier, rules: offered, settings: settings, dots: hidden)
        for _ in 0..<20 { world.rig.clock.advance(by: .milliseconds(250)) }
        #expect(world.writer.writeCount == 2)
    }

    @Test func besideClockIgnoredUnderDB() async throws {
        // This Mac can't keep the dots beside the clock: whatever the file says, they are between the sections.
        var settings = LayoutSettings()
        settings.dotsPlacement = .besideClock
        let world = await started(rules: F.rules(.autosaveIndex(prefix: "Item-")), settings: settings)
        world.writer.table = fullTable()
        await world.session.move(app: notes, to: .hidden)
        #expect(await world.settled())
        let tokens = try #require(world.writer.writes.first).arrangement.tokens
        #expect(try #require(tokens.firstIndex(of: .dot(.hidden))) < #require(tokens.firstIndex(of: .item(temp))), "between the sections")
        #expect(tokens.last != .dot(.hidden))
        #expect(await world.session.effectivePlacement == .betweenSections)

        // Where it can (D-A) the choice stands.
        var offered = F.rules(.autosaveIndex(prefix: "Item-"))
        offered.dotsPlacementOffered = true
        let other = await started(rules: offered, settings: settings)
        other.writer.table = fullTable()
        await other.session.move(app: notes, to: .hidden)
        #expect(await other.settled())
        #expect(try #require(other.writer.writes.first).arrangement.tokens.last == .dot(.hidden))
        #expect(await other.applier.status().dotsPlacementOffered)
    }

    // MARK: ⌘-drags

    @Test func commandDragFollowWaitsTheDelay() async throws {
        let world = await started()
        let session = world.session
        await session.commandDragBegan()
        let reads = await session.scansIngested

        let ended = Task { await session.commandDragEnded() }
        #expect(await world.rig.clock.waitForSleepers(3, within: .seconds(5)))
        let sleeping = world.rig.clock.sleeperCount
        world.rig.clock.advance(by: .milliseconds(599))
        #expect(world.rig.clock.sleeperCount == sleeping, "the drag's wait is still sleeping: 599 ms isn't 600")
        #expect(await session.scansIngested == reads, "no read yet")

        world.rig.clock.advance(by: .milliseconds(1))
        await ended.value
        #expect(await session.scansIngested == reads + 1)
        #expect(LayoutFollower.commandDragFollowDelay == .milliseconds(600))
    }

    /// The notes app dragged from the right of • to its left (Hidden's side), as macOS draws it.
    private func dragNotesLeft(_ world: Rig) {
        draw(world, ["mantel.dot.always", "Notes", "mantel.dot.hidden", "weather.temp", "weather.alerts", "_NS:93", "Sync B", "Sync A"])
    }

    @Test func commandDragReadMayChangeSections() async throws {
        let world = await started()
        let session = world.session
        await session.commandDragBegan()
        dragNotesLeft(world)

        let ended = Task { await session.commandDragEnded() }
        #expect(await world.rig.clock.waitForSleepers(3, within: .seconds(5)))
        world.rig.clock.advance(by: LayoutFollower.commandDragFollowDelay)
        await ended.value

        let placement = try #require(await world.sections().apps[notes])
        #expect(placement.section == .hidden, "the app that was dragged across • is in Hidden now")
        #expect(placement.isAuto == false, "a move found this way is the person's")
        #expect(await world.sections().apps[weather]?.section == .shown, "and only that one moved")
        #expect(await world.sections().apps[vpn]?.section == .shown)
        // A request sets both at once (the session before it asks, the applier when it has it), whatever the debounce has or hasn't done.
        #expect(await world.applier.status().isPending == false, "the follower asked for no write")
        #expect(await session.layoutIsPending == false)
        #expect(world.writer.writeCount == 0, "what was followed is never written back")
        #expect(world.phases.count == 0)
        #expect(world.rig.saved.latest?.apps[notes]?.section == .hidden, "it was saved")
    }

    @Test func routineReadNeverChangesSections() async throws {
        let world = await started()
        let session = world.session
        // A drag that no one told the session of, and one it was told of, but whose read is an ordinary one.
        await session.commandDragBegan()
        dragNotesLeft(world)
        _ = await session.readNow(.layoutCheck)
        await session.refresh()

        #expect(await world.sections().apps[notes]?.section == .shown, "the order follows; the section does not")
        #expect(await world.sections().apps[vpn]?.section == .shown)

        // The drag's read, once it comes, doesn't remember anything from before: it was never the one.
        let before = await world.sections()
        _ = await session.readNow(.layoutCheck)
        #expect(await world.sections().apps == before.apps)
        #expect(await world.applier.status().isPending == false, "and none of it asked for a write")
        #expect(await session.layoutIsPending == false)
        #expect(world.writer.writeCount == 0)
    }

    @Test func aCommandDragReadIsOneReadOnly() async throws {
        let world = await started()
        let session = world.session
        await session.commandDragBegan()
        dragNotesLeft(world)
        _ = await session.readNow(.layoutFollow)
        #expect(await world.sections().apps[notes]?.section == .hidden)

        // What was kept is used up: another read of that kind, with nothing stored, moves nothing.
        draw(world, ["mantel.dot.always", "mantel.dot.hidden", "Notes", "weather.temp", "weather.alerts", "_NS:93", "Sync B", "Sync A"])
        _ = await session.readNow(.layoutFollow)
        #expect(await world.sections().apps[notes]?.section == .hidden)
    }

    @Test func followedOrderNeverWrites() async throws {
        // From the bar (the rules can't match nameless items to keys): the order is followed, and a ⌘-drag changes a section.
        let fromTheBar = await started(rules: F.rules(.identifiersOnly))
        draw(fromTheBar, ["mantel.dot.always", "mantel.dot.hidden", "_NS:93", "weather.temp", "weather.alerts", "Notes", "Sync B", "Sync A"])
        _ = await fromTheBar.session.readNow(.layoutCheck)
        #expect(await fromTheBar.shownOrder().first == vpn0, "the order was followed")
        await fromTheBar.session.commandDragBegan()
        dragNotesLeft(fromTheBar)
        _ = await fromTheBar.session.readNow(.layoutFollow)
        #expect(await fromTheBar.sections().apps[notes]?.section == .hidden, "and the section")

        // From the table (the rules match them): the table's order is followed, and a ⌘-drag changes a section the same way.
        let fromTheTable = await started(rules: F.rules(.autosaveIndex(prefix: "Item-")))
        fromTheTable.writer.table = table([(notes0, 700), (vpn0, 600), (temp, 500), (alerts, 400), (sync0, 300), (sync1, 200)])
        fromTheTable.rig.clock.advance(by: .seconds(3))
        _ = await fromTheTable.session.readNow(.layoutCheck)
        #expect(Array(await fromTheTable.shownOrder().prefix(2)) == [notes0, vpn0], "the table's order was followed")
        await fromTheTable.session.commandDragBegan()
        fromTheTable.writer.table = table([(vpn0, 700), (temp, 600), (alerts, 500), (notes0, 400), (sync0, 300), (sync1, 200)])
        dragNotesLeft(fromTheTable)
        fromTheTable.rig.clock.advance(by: .seconds(3))
        _ = await fromTheTable.session.readNow(.layoutFollow)

        for world in [fromTheBar, fromTheTable] {
            // A request would have made the session pending in the same breath and the applier with it: neither is.
            #expect(await world.applier.status().isPending == false)
            #expect(await world.session.layoutIsPending == false)
            for _ in 0..<20 { world.rig.clock.advance(by: .milliseconds(250)) }
            #expect(world.writer.writeCount == 0)
            #expect(world.phases.count == 0)
        }
    }

    // MARK: Where the order comes from

    private func table(_ order: [(ItemID, Double)]) -> LayoutTableSnapshot {
        var distances: [String: Double] = [
            F.ownKey(OwnItems.alwaysDotName): 900, F.ownKey(OwnItems.hiddenDotName): 800,
        ]
        for (id, distance) in order {
            switch id.key {
            case .identifier(let name): distances[LayoutKey.status(bundleID: id.bundleID, autosaveName: name)] = distance
            case .index(let n): distances[LayoutKey.status(bundleID: id.bundleID, autosaveName: "Item-\(n)")] = distance
            case .system: break
            }
        }
        return LayoutTableSnapshot(distances: distances)
    }

    /// A table that has a key for every item on the desk, so that every app is written whole and Mantel's own items keep the arrangement's
    /// distances (what is asked of the placement is `OwnItemPlacementTests`).
    private func fullTable() -> LayoutTableSnapshot {
        table([(temp, 700), (alerts, 600), (notes0, 500), (vpn0, 400), (sync0, 300), (sync1, 200)])
    }

    @Test func followsTableOrderWhenGranted() async throws {
        let rules = F.rules(.autosaveIndex(prefix: "Item-"))
        let world = await started(rules: rules)
        // The table has the notes app and the VPN app left of the weather app; the bar (drawn from the table, as macOS does) hasn't been
        // read again, but the table is what is followed.
        world.writer.table = table([(notes0, 700), (vpn0, 600), (temp, 500), (alerts, 400), (sync0, 300), (sync1, 200)])
        // The table is read at most every two seconds: the one read at the start is old by now.
        world.rig.clock.advance(by: .seconds(3))
        _ = await world.session.readNow(.layoutCheck)

        let order = await world.shownOrder()
        #expect(Array(order.prefix(6)) == [notes0, vpn0, temp, alerts, sync0, sync1])
        #expect(world.writer.writeCount == 0)

        // Read again at once, the table isn't asked again.
        world.writer.table = table([(temp, 700), (alerts, 600), (notes0, 500), (vpn0, 400), (sync0, 300), (sync1, 200)])
        _ = await world.session.readNow(.layoutCheck)
        #expect(Array(await world.shownOrder().prefix(2)) == [notes0, vpn0], "the table was read less than two seconds ago")
    }

    @Test func followsBarOrderWithoutGrant() async throws {
        let rules = F.rules(.autosaveIndex(prefix: "Item-"))
        let world = await started(rules: rules, availability: .needsGrant)
        world.writer.table = table([(notes0, 700), (vpn0, 600), (temp, 500), (alerts, 400), (sync0, 300), (sync1, 200)])
        // The bar shows the VPN app first.
        draw(world, ["mantel.dot.always", "mantel.dot.hidden", "_NS:93", "weather.temp", "weather.alerts", "Notes", "Sync B", "Sync A"])
        _ = await world.session.readNow(.layoutCheck)

        let order = await world.shownOrder()
        #expect(Array(order.prefix(3)) == [vpn0, temp, alerts], "the bar's order, the table's being out of reach")
    }

    @Test func identifiersOnlyFollowsTheBarEvenWhenGranted() async throws {
        // Where nameless apps have no key, the table sees none of them, and a ⌘-drag of one would never be followed from it: the bar is.
        let world = await started(rules: F.rules(.identifiersOnly))
        world.writer.table = table([(temp, 500), (alerts, 400)])
        draw(world, ["mantel.dot.always", "mantel.dot.hidden", "_NS:93", "weather.temp", "weather.alerts", "Notes", "Sync B", "Sync A"])
        _ = await world.session.readNow(.layoutCheck)
        let order = await world.shownOrder()
        #expect(Array(order.prefix(3)) == [vpn0, temp, alerts])

        // And a ⌘-drag of the nameless notes app across • moves it, as it would from the bar.
        await world.session.commandDragBegan()
        draw(world, ["mantel.dot.always", "Notes", "mantel.dot.hidden", "_NS:93", "weather.temp", "weather.alerts", "Sync B", "Sync A"])
        _ = await world.session.readNow(.layoutFollow)
        #expect(await world.sections().apps[notes]?.section == .hidden)
    }

    @Test func rankMatchingFollowsTheBarEvenWhenGranted() async throws {
        // Apps that stay without a key (here the weather app's two items: one entry for two) would never be seen in the table, so the bar is
        // what is read, even though the notes app has a key of its own by rank and the table puts it first.
        let world = await started(rules: F.rules(.byRank))
        world.writer.table = table([(notes0, 700), (temp, 500)])
        world.rig.clock.advance(by: .seconds(3))
        draw(world, ["mantel.dot.always", "mantel.dot.hidden", "_NS:93", "weather.temp", "weather.alerts", "Notes", "Sync B", "Sync A"])
        _ = await world.session.readNow(.layoutCheck)
        let order = await world.shownOrder()
        #expect(Array(order.prefix(3)) == [vpn0, temp, alerts], "the bar's order, not the table's")

        // A ⌘-drag of the weather app (which has no key) across • is followed from the bar.
        await world.session.commandDragBegan()
        draw(world, ["mantel.dot.always", "weather.temp", "weather.alerts", "mantel.dot.hidden", "_NS:93", "Notes", "Sync B", "Sync A"])
        _ = await world.session.readNow(.layoutFollow)
        #expect(await world.sections().apps[weather]?.section == .hidden)
        #expect(world.writer.writeCount == 0, "following never writes")
    }

    @Test func theAppsThePlanConcealsAreNotMatchedByRankWhenTheyHaveSeveralItems() async throws {
        // The sync app's two items have two entries: moved by the person, they are matched (the notes app's move leaves them in the write)...
        let world = await started(rules: F.rules(.byRank))
        world.writer.table = table([(notes0, 700), (vpn0, 600), (temp, 500), (alerts, 400), (sync0, 300), (sync1, 200)])
        world.rig.clock.advance(by: .seconds(3))
        _ = await world.session.readNow(.layoutCheck)
        await world.session.move(app: notes, to: .hidden)
        #expect(await world.settled())
        let first = try #require(world.writer.writes.first)
        #expect(first.keys[.item(sync0)] != nil && first.keys[.item(sync1)] != nil)

        // ...and when the plan conceals the app, the frames of the read before it are of an app that isn't drawn: they say nothing.
        await world.session.move(app: sync, to: .hidden)
        #expect(await world.settled())
        let report = try #require(await world.applier.status().lastReport)
        #expect(report.unresolved.contains(sync0) && report.unresolved.contains(sync1))
        #expect(world.writer.writes.last?.keys[.item(sync0)] == nil)
    }

    @Test func anAppThePlanStoppedConcealingIsStillNotBelievedWhereTheReadFoundIt() async throws {
        // The read was taken while the plan concealed the sync app: its frames are where it was last drawn. The person then moves it to
        // Shown; the plan no longer conceals it, but the read the write is made from was taken under the plan that did.
        let hiddenSync = sections(shown: [weather, notes, vpn], hidden: [sync])
        let world = await started(sections: hiddenSync, rules: F.rules(.byRank), staleConcealed: true)
        world.writer.table = table([(notes0, 700), (vpn0, 600), (temp, 500), (alerts, 400), (sync0, 300), (sync1, 200)])
        world.rig.clock.advance(by: .seconds(3))
        _ = await world.session.readNow(.layoutCheck)
        #expect(await world.session.concealedAtRead.contains(sync))

        await world.session.move(app: sync, to: .shown)
        #expect(await world.session.appsNotDrawn().contains(sync) == false, "the plan in force draws it now")
        #expect(await world.session.appsNotDrawnForLayout().contains(sync), "the read the write is made from doesn't")
        #expect(await world.settled())
        let report = try #require(await world.applier.status().lastReport)
        #expect(report.unresolved.contains(sync0) && report.unresolved.contains(sync1))
    }

    @Test func anAppAmongTheStayingModulesStaysInCantReorderAcrossReads() async throws {
        // The notes app's one entry (100) is right of Sound (150): the app sits among the modules that stay, so a write leaves it alone.
        let world = await started(rules: F.rules(.byRank))
        var distances = table([(temp, 700), (alerts, 600), (notes0, 100), (vpn0, 400), (sync0, 300), (sync1, 200)]).distances
        distances["module:Sound"] = 150
        world.writer.table = LayoutTableSnapshot(distances: distances)
        world.rig.clock.advance(by: .seconds(3))
        _ = await world.session.readNow(.layoutCheck)
        await world.session.move(app: vpn, to: .hidden)
        #expect(await world.settled())
        let report = try #require(await world.applier.status().lastReport)
        #expect(report.unresolved.contains(notes0))
        #expect(world.writer.writes.first?.keys[.item(notes0)] == nil)

        // The next read follows the table again, and still lists it: the hint to ⌘-drag it isn't gone after a second.
        world.rig.clock.advance(by: .seconds(3))
        _ = await world.session.readNow(.layoutCheck)
        let state = try #require(await world.rig.state)
        #expect(state.lists.cantReorder.contains(notes0))
    }

    @Test func anAppAmongTheStayingModulesStaysInCantReorderUnderTheRulesThatFollowTheTable() async throws {
        // Under `.autosaveIndex` the table is what is followed, and the app's key is in it: the follower still sees it, and it is listed.
        let world = await started(rules: F.rules(.autosaveIndex(prefix: "Item-")))
        var distances = table([(temp, 700), (alerts, 600), (notes0, 100), (vpn0, 400), (sync0, 300), (sync1, 200)]).distances
        distances["module:Sound"] = 150
        world.writer.table = LayoutTableSnapshot(distances: distances)
        world.rig.clock.advance(by: .seconds(3))
        _ = await world.session.readNow(.layoutCheck)
        let state = try #require(await world.rig.state)
        #expect(state.lists.cantReorder.contains(notes0))
        #expect(Array(await world.shownOrder().prefix(6)) == [temp, alerts, vpn0, sync0, sync1, notes0], "and the table's order has the app")
    }

    @Test func anAppMovedOutOfHiddenIsComparedByTheReadsTakenAfterTheMove() async throws {
        // The VPN app's one entry is stale: macOS doesn't draw the icon by it. The read before the move was taken while the plan concealed
        // the app. Moved to Shown, the app is drawn, and the reads of the verification are taken under a plan that doesn't conceal it.
        let hiddenVpn = sections(shown: [weather, notes, sync], hidden: [vpn])
        let world = await started(sections: hiddenVpn, rules: F.rules(.byRank), staleConcealed: true)
        world.writer.table = table([(notes0, 700), (temp, 500), (alerts, 400), (sync0, 300), (sync1, 200), (vpn0, 650)])
        world.rig.clock.advance(by: .seconds(3))
        _ = await world.session.readNow(.layoutCheck)
        #expect(await world.session.concealedAtRead.contains(vpn))

        await world.session.move(app: vpn, to: .shown)
        // The bar draws the icon where the arrangement doesn't have it.
        let others = ["weather.temp", "weather.alerts", "Notes", "Sync B", "Sync A"]
        let vpnFirst = await world.shownOrder().first == vpn0
        draw(world, ["mantel.dot.always", "mantel.dot.hidden"] + (vpnFirst ? others + ["_NS:93"] : ["_NS:93"] + others))
        #expect(await world.settled())

        #expect(await world.applier.status().lastError == .notAccepted, "the icon isn't where the key says")
    }

    @Test func unresolvedReachTheReadOnlyLists() async throws {
        let world = await started(rules: F.rules(.identifiersOnly))
        _ = await world.session.readNow(.layoutCheck)
        let state = try #require(await world.rig.state)

        // Every nameless item is one whose order can't be written; the named ones have no key in this table either.
        #expect(Set(state.lists.cantReorder) == [notes0, vpn0, sync0, sync1, temp, alerts])
        #expect(state.layout?.availability == .available)
    }

    @Test func theStatusReachesTheState() async throws {
        let world = await started(availability: .needsGrant)
        let state = try #require(await world.rig.state)
        #expect(state.layout?.availability == .needsGrant)
        #expect(state.layout?.dotsPlacementOffered == false)
        #expect(state.layout?.isPending == false)
    }


    // MARK: Pending until its own end

    @Test func theEndOfAnEarlierRequestIsNotTheEndOfTheLastOne() async throws {
        let gate = Gate()
        let world = await started(endGate: gate)
        let session = world.session
        await session.move(app: notes, to: .hidden)
        // The applier has verified the first request and is telling the session so (held before the session hears it)...
        #expect(await world.drive { world.phases.all.contains("phase(false,false)") })

        // ...when the person's next change reaches it.
        await session.move(app: vpn, to: .hidden)
        gate.open()
        let heard = await withinTimeLimit(.seconds(5)) {
            while await session.layoutPhaseRevision < 1 { await Task.yield() }
            return true
        }
        #expect(heard == true)
        #expect(await session.layoutIsPending, "what the session was told is of the first request: the second isn't over")

        // A read now follows nothing: the bar shows the order before the second change.
        draw(world, ["mantel.dot.always", "mantel.dot.hidden", "weather.temp", "weather.alerts", "Notes", "_NS:93", "Sync B", "Sync A"])
        _ = await session.readNow(.layoutCheck)
        #expect(await world.sections().apps[vpn]?.section == .hidden, "the person's second change wasn't put back")

        #expect(await world.settled())
        #expect(await session.layoutIsPending == false, "and the end of the second is the end")
    }

    // MARK: Without the file and at quit

    @Test func aChangeWaitsWhileTheFileIsNotGrantedAndIsSentWhenItIs() async throws {
        let world = await started(rules: F.rules(.autosaveIndex(prefix: "Item-")), availability: .needsGrant)
        world.writer.table = fullTable()
        await world.session.move(app: notes, to: .hidden)

        // Nothing is asked of the applier, so no error is made of it, and nothing is pending.
        #expect(await world.session.layoutIsPending == false)
        let status = await world.applier.status()
        #expect(status.lastError == nil)
        #expect(status.isPending == false)
        for _ in 0..<20 { world.rig.clock.advance(by: .milliseconds(250)) }
        #expect(world.writer.writeCount == 0)
        #expect(await world.applier.status().lastError == nil)

        // The file is given: the change is sent, from the sections as they are now.
        await world.session.move(app: vpn, to: .hidden)
        world.writer.availabilityNow = .available
        await world.session.layoutAvailabilityChanged()
        #expect(await world.settled())
        #expect(world.writer.writeCount == 1)
        let tokens = try #require(world.writer.writes.first).arrangement.tokens
        let hiddenDot = try #require(tokens.firstIndex(of: .dot(.hidden)))
        #expect(try #require(tokens.firstIndex(of: .item(notes0))) < hiddenDot)
        #expect(try #require(tokens.firstIndex(of: .item(vpn0))) < hiddenDot, "both are in Hidden, the newest inputs")

        // And it is sent once: a second change of availability has nothing waiting.
        await world.session.layoutAvailabilityChanged()
        for _ in 0..<20 { world.rig.clock.advance(by: .milliseconds(250)) }
        #expect(world.writer.writeCount == 1)
    }

    @Test func aChangeIsAlsoHeldBackWhenReorderingIsOffOnThisMac() async throws {
        let world = await started(availability: .broken(LayoutWords.broken))
        await world.session.move(app: notes, to: .hidden)
        #expect(await world.session.layoutIsPending == false)
        #expect(await world.applier.status().lastError == nil)
        #expect(world.writer.writeCount == 0)
    }

    @Test func aChangeMadeWhileTheLastReadHasNoBarsWaitsForOneThatHasThem() async throws {
        let world = await started()
        let session = world.session
        // MenuBarAgent is down: the last read has no bar, no item and no word of which apps run.
        world.world.setAgentRunning(false)
        await session.refresh()
        #expect(await session.inventory.bars.isEmpty)

        await session.move(app: notes, to: .hidden)
        // Nothing is asked of the applier, no error is made of it, and nothing is pending.
        #expect(await session.layoutIsPending == false)
        for _ in 0..<20 { world.rig.clock.advance(by: .milliseconds(250)) }
        #expect(world.writer.writeCount == 0)
        let status = await world.applier.status()
        #expect(status.lastError == nil && status.lastReport == nil && !status.isPending)
        // A second change joins the first: one write, from the sections as they are then.
        await session.move(app: vpn, to: .hidden)

        // The next read that has the bars sends it.
        world.world.setAgentRunning(true)
        await session.refresh()
        #expect(await world.settled())
        #expect(world.writer.writeCount == 1)
        let tokens = try #require(world.writer.writes.first).arrangement.tokens
        let hiddenDot = try #require(tokens.firstIndex(of: .dot(.hidden)))
        #expect(try #require(tokens.firstIndex(of: .item(notes0))) < hiddenDot)
        #expect(try #require(tokens.firstIndex(of: .item(vpn0))) < hiddenDot)

        // And once: a later read has nothing waiting.
        await session.refresh()
        for _ in 0..<20 { world.rig.clock.advance(by: .milliseconds(250)) }
        #expect(world.writer.writeCount == 1)
    }

    @Test func aChangeHeldForAReadWithBarsIsDroppedByRestoreOriginalLayout() async throws {
        let world = await started()
        let session = world.session
        world.world.setAgentRunning(false)
        await session.refresh()
        #expect(await session.inventory.bars.isEmpty)
        await session.move(app: notes, to: .hidden)
        #expect(world.writer.writeCount == 0, "held: the last read has no bars")

        // The person restores the original layout before a read with bars came: the held change is from before it. The restore waits on
        // the clock for the bar to settle, so the clock is moved until it has ended.
        let finished = Mutex(false)
        let restoring = Task {
            _ = await session.restoreOriginalLayout()
            finished.withLock { $0 = true }
        }
        #expect(await world.drive { finished.withLock { $0 } }, "the restore ends")
        await restoring.value
        let afterRestore = world.writer.writeCount
        world.world.setAgentRunning(true)
        await session.refresh()
        #expect(await world.settled())
        for _ in 0..<20 { world.rig.clock.advance(by: .milliseconds(250)) }
        #expect(world.writer.writeCount == afterRestore, "nothing of the held change is written on top of the restore")
    }

    @Test func quittingWritesAChangeThatIsStillInItsDebounce() async throws {
        let world = await started(rules: F.rules(.autosaveIndex(prefix: "Item-")))
        world.writer.table = fullTable()
        await world.session.move(app: notes, to: .hidden)
        #expect(world.writer.writeCount == 0, "inside the second")

        await world.session.flushLayoutForQuit()

        #expect(world.writer.writeCount == 1, "written at once, without the clock moving")
        let tokens = try #require(world.writer.writes.first).arrangement.tokens
        #expect(try #require(tokens.firstIndex(of: .item(notes0))) < #require(tokens.firstIndex(of: .dot(.hidden))))
    }

    @Test func aWriteThatCantFinishInTheQuitTimersTimeIsLeftBehind() async throws {
        let world = await started()
        let gate = Gate()
        world.writer.holdWrites(at: gate)
        defer { gate.open() }
        await world.session.move(app: notes, to: .hidden)

        let session = world.session
        let flushed = Mutex(false)
        let flushing = Task {
            await session.flushLayoutForQuit()
            flushed.withLock { $0 = true }
        }
        #expect(await waitUntil { world.writer.writeCount == 1 }, "the write began at once")
        #expect(await world.rig.clock.waitForSleepers(1, within: .seconds(5)))
        let sleeping = world.rig.clock.sleeperCount
        world.rig.clock.advance(by: MenuBarSession.quitLayoutLimit - .milliseconds(1))
        #expect(world.rig.clock.sleeperCount == sleeping, "inside the limit, the write is waited for")
        #expect(flushed.withLock { $0 } == false)
        world.rig.clock.advance(by: .milliseconds(1))
        await flushing.value
        #expect(flushed.withLock { $0 }, "the quit goes on at the limit: the change is dropped and logged")
        #expect(MenuBarSession.quitLayoutLimit < QuitTimer.base)
    }

    @Test func aFlushThatTheLimitPassesBeforeItsWriteIsNotWrittenLater() async throws {
        let world = await started()
        await world.session.move(app: notes, to: .hidden)
        // The flush is still working out what to write (it reads the table) when the limit passes.
        let gate = Gate()
        world.writer.holdReads(at: gate)
        defer { gate.open() }

        let session = world.session
        let flushed = Mutex(false)
        let flushing = Task {
            await session.flushLayoutForQuit()
            flushed.withLock { $0 = true }
        }
        #expect(await waitUntil { world.writer.readsHeld == 1 })
        let limitPassed = await withinTimeLimit(.seconds(10)) {
            while !flushed.withLock({ $0 }), !Task.isCancelled {
                world.rig.clock.advance(by: MenuBarSession.quitLayoutLimit)
                await Task.yield()
            }
            return true
        }
        #expect(limitPassed == true, "the quit goes on at the limit")
        await flushing.value

        // The flush goes on after the limit and finds it was abandoned: it never writes.
        gate.open()
        let ended = await withinTimeLimit(.seconds(5)) {
            while await world.applier.abandonQuitFlush() != .finished, !Task.isCancelled { await Task.yield() }
            return true
        }
        #expect(ended == true, "the flush ends")
        #expect(world.writer.writeCount == 0, "a write that hadn't begun at the limit isn't begun after it")
    }

    // MARK: A drag whose follow is refused

    @Test func aDragThatEndsWhileTheBarIsBeingResortedIsFollowedWhenItIsStill() async throws {
        let world = await started()
        let session = world.session
        await session.commandDragBegan()
        dragNotesLeft(world)
        await session.setLayoutPhase(pending: true, settling: true)

        let ended = Task { await session.commandDragEnded() }
        #expect(await world.rig.clock.waitForSleepers(3, within: .seconds(5)))
        world.rig.clock.advance(by: LayoutFollower.commandDragFollowDelay)
        await ended.value
        #expect(await world.sections().apps[notes]?.section == .shown, "refused: the bar is being re-sorted")

        // The re-sort is over: the follow the drag was owed is taken, from what the drag moved.
        await session.setLayoutPhase(pending: false, settling: false)
        let followed = await withinTimeLimit(.seconds(5)) {
            while await world.sections().apps[notes]?.section != .hidden { await Task.yield() }
            return true
        }
        #expect(followed == true)
        #expect(world.writer.writeCount == 0, "and it is never written back")
    }

    @Test func aDragRefusedWhileAChangeIsHeldBackIsFollowedWhenTheChangeHasBeenHeld() async throws {
        // The file isn't granted, so a change is held back and no phase of a write will ever end. The change is in flight (pending) while
        // the drag's follow is asked for, which refuses it.
        let world = await started(availability: .needsGrant)
        let session = world.session
        await session.commandDragBegan()
        dragNotesLeft(world)
        let began = await session.beginLayoutRequest()

        let ended = Task { await session.commandDragEnded() }
        #expect(await world.rig.clock.waitForSleepers(3, within: .seconds(5)))
        world.rig.clock.advance(by: LayoutFollower.commandDragFollowDelay)
        await ended.value
        #expect(await world.sections().apps[notes]?.section == .shown, "refused: the change is in flight")

        await session.sendLayoutRequest(.person, began: began)
        let followed = await withinTimeLimit(.seconds(5)) {
            while await world.sections().apps[notes]?.section != .hidden, !Task.isCancelled { await Task.yield() }
            return true
        }
        #expect(followed == true, "the change was held back, nothing will end, and the drag is followed now")
        #expect(world.writer.writeCount == 0)
    }

    @Test func aFollowIsAnsweredOnlyByAReadTakenForIt() async throws {
        let world = await started()
        let session = world.session
        await session.commandDragBegan()
        dragNotesLeft(world)

        // A read that isn't for the follow is under way when the follow is asked for, and ends first.
        let gate = Gate()
        world.rig.extras.holdReads(at: gate)
        let first = Task { await session.readNow(.layoutCheck) }
        #expect(await waitUntil { world.rig.extras.readsHeld >= 1 })
        let follow = Task { await session.readNow(.layoutFollow) }
        let asked = await withinTimeLimit(.seconds(5)) {
            while await session.readsWaitedFor < 2 { await Task.yield() }
            return true
        }
        #expect(asked == true, "both reads are waited for, the follow's asked while the first is under way")
        gate.open()
        world.rig.extras.holdReads(at: nil)
        _ = await first.value
        _ = await follow.value

        #expect(await world.sections().apps[notes]?.section == .hidden, "the read that answered it was the follow's own")
    }

    // MARK: Restoring and resetting

    @Test func restoreThenFollowsTable() async throws {
        let rules = F.rules(.autosaveIndex(prefix: "Item-"))
        let world = await started(rules: rules)
        world.writer.kept = true
        // The table as it was before Mantel wrote: the weather app is left of the rest, and the notes app is not at the front.
        world.writer.table = table([(temp, 700), (alerts, 600), (vpn0, 500), (notes0, 400), (sync0, 300), (sync1, 200)])
        let session = world.session
        let restoring = Task { await session.restoreOriginalLayout() }
        #expect(await world.drive { world.writer.restoreCount == 1 })
        #expect(await session.isLayoutSettling, "the bar is being re-sorted meanwhile")
        #expect(await world.drive { await !session.isLayoutSettling })
        let result = await restoring.value

        #expect(result == .success(3))
        #expect(await session.layoutIsPending == false)
        // A read from the table followed it: the VPN app is before the notes app now, and no section changed.
        let order = await world.shownOrder()
        #expect(Array(order.prefix(6)) == [temp, alerts, vpn0, notes0, sync0, sync1])
        #expect(await world.sections().apps[notes]?.section == .shown)
        #expect(await world.applier.status().hasKeptChanges == false)
    }

    @Test func resetLeavesTheOrder() async throws {
        let world = await started()
        let folder = TemporaryFolder(prefix: "mantel-layout-reset")
        let journal = Journal(file: folder.url.appending(path: "journal.json"), clock: world.rig.clock)
        let place = JournalEntry.plistPath(filePath: "/Users/example/com.apple.MenuBar.plist", key: "TrailingItemPreferredPositions",
                                           path: [.key("status:com.example.a::Item-0")], original: .integer(5), strategy: .cfPreferences,
                                           codec: .none)
        let temporary = JournalEntry.plistPath(filePath: "/Users/example/com.apple.MenuBar.plist", key: "TrailingItemPreferredPositions",
                                               path: [.key("status:com.example.a::Item-1")], original: .integer(6), strategy: .cfPreferences,
                                               codec: .none)
        try await journal.record(place, lifetime: .kept)
        try await journal.record(temporary)
        let before = await world.sections()
        world.writer.kept = true

        // What Reset replays is what is temporary (`replay` takes `.untilQuit` unless it is told otherwise): the order is Mantel's own.
        let restorer = ResetRestorer()
        try await world.session.reset(restarter: FakeRestarter(), replayJournal: { _ = await journal.replay(using: restorer) })

        #expect(restorer.restored == [temporary], "only the temporary change was put back")
        #expect(await journal.keptRecords().map(\.entry) == [place], "the arrangement is still kept")
        #expect(world.writer.restoreCount == 0 && world.writer.writeCount == 0, "and nothing was written or restored in the table")
        #expect(await world.sections().apps == before.apps, "the sections stay as they are")
        #expect(await world.applier.status().hasKeptChanges)
    }
}

/// What a replay puts back, noted.
private final class ResetRestorer: JournalRestoring {
    private let entries = Mutex<[JournalEntry]>([])
    var restored: [JournalEntry] { entries.withLock { $0 } }

    func restore(_ entry: JournalEntry) async throws {
        entries.withLock { $0.append(entry) }
    }

    func stillHolds(_ written: WrittenValue, for entry: JournalEntry) async -> Bool? { nil }
}

/// ⌘-drags on a busy Mac: the order that is kept after a drop is the bar's, which a read that is empty or missing an app can't tell.
extension MenuBarSessionLayoutTests {
    @Test func aFollowWhoseReadIsMissingAnAppIsReadAgain() async throws {
        let world = await started()
        let session = world.session
        let clock = world.rig.clock
        await session.commandDragBegan()
        dragNotesLeft(world)
        // The VPN app doesn't answer the first read after the drop: its icon has a slot in the read and no item.
        world.rig.extras.stopAnswering(vpn, forReads: 1)

        let ended = Task { await session.commandDragEnded() }
        #expect(await clock.waitForSleepers(3, within: .seconds(5)))
        clock.advance(by: LayoutFollower.commandDragFollowDelay)
        #expect(await clock.waitForSleepers(3, within: .seconds(5)), "it waits to read again")
        #expect(await world.sections().apps[notes]?.section == .shown, "what a read that is missing an app says isn't followed")
        #expect(await session.layoutCaptureRefusal == LayoutWords.resorting, "the drag isn't over")

        clock.advance(by: LayoutFollower.commandDragRetryWaits[0])
        await ended.value
        let placement = try #require(await world.sections().apps[notes])
        #expect(placement.section == .hidden, "the read that had every app followed the drag: the order kept is the bar's")
        #expect(await session.layoutCaptureRefusal == nil)
    }

    @Test func aFollowWhoseReadHasNoBarIsReadAgain() async throws {
        let world = await started()
        let session = world.session
        let clock = world.rig.clock
        await session.commandDragBegan()
        dragNotesLeft(world)
        world.world.setAgentRunning(false)

        let ended = Task { await session.commandDragEnded() }
        #expect(await clock.waitForSleepers(3, within: .seconds(5)))
        clock.advance(by: LayoutFollower.commandDragFollowDelay)
        #expect(await clock.waitForSleepers(3, within: .seconds(5)))
        world.world.setAgentRunning(true)
        clock.advance(by: LayoutFollower.commandDragRetryWaits[0])
        await ended.value

        #expect(await world.sections().apps[notes]?.section == .hidden)
    }

    @Test func anAppThatHadAnIconAndNeverAnswersAgainIsNotTheBarAsItIs() async throws {
        let world = await started()
        let session = world.session
        let clock = world.rig.clock
        await session.commandDragBegan()
        dragNotesLeft(world)
        // The VPN app, which had an icon on the bar in the reads so far, doesn't answer in any read from now on: its icon has a slot and no
        // item, the same in every read. Two reads that agree on that aren't "the bar as it is": the order isn't followed from them.
        world.rig.extras.stopAnswering(vpn)
        let reads = await session.scansIngested

        let ended = Task { await session.commandDragEnded() }
        #expect(await clock.waitForSleepers(3, within: .seconds(5)))
        clock.advance(by: LayoutFollower.commandDragFollowDelay)
        for wait in LayoutFollower.commandDragRetryWaits {
            #expect(await clock.waitForSleepers(3, within: .seconds(5)))
            clock.advance(by: wait)
        }
        await ended.value

        #expect(await session.scansIngested - reads == 1 + LayoutFollower.commandDragRetryWaits.count, "it read as many times as it may")
        #expect(await world.sections().apps[notes]?.section == .shown, "and followed nothing: the order kept would not be the bar's")
        #expect(await session.layoutCaptureRefusal == nil, "the drag is over: clicks aren't refused")
    }

    @Test func aFollowThatIsTakingLongStartsNoReadPastItsLimitWhateverTheReadsTook() async throws {
        let world = await started()
        let session = world.session
        let clock = world.rig.clock
        await session.commandDragBegan()
        dragNotesLeft(world)
        world.rig.extras.stopAnswering(vpn)
        let reads = await session.scansIngested

        let over = Mutex(false)
        let ended = Task {
            await session.commandDragEnded()
            over.withLock { $0 = true }
        }
        defer { ended.cancel() }
        #expect(await clock.waitForSleepers(3, within: .seconds(5)))
        clock.advance(by: LayoutFollower.commandDragFollowDelay)
        // The read that came back partial took seconds, as a read on a busy Mac does: the wait before the next one is begun on a clock that
        // is already past what the follow may take.
        #expect(await clock.waitForSleepers(3, within: .seconds(5)))
        clock.advance(by: .seconds(3))
        // A follow that went on to another read is asleep on a clock nothing moves: the test fails at the limit and doesn't hang.
        #expect(await waitUntil { over.withLock { $0 } }, "the follow is over")

        #expect(await session.scansIngested - reads == 2, "no third read began")
        #expect(await session.layoutCaptureRefusal == nil)
    }
}

/// What the log says of a ⌘-drag: a line when it is seen to begin, and a line when its follow ends.
///
/// The log is the whole process's and other tests drag too (`LogCapture`): each test here is told the drop was a moment before the follow
/// began, by a time no other test uses, and looks for its own line by that time.
extension MenuBarSessionLayoutTests {
    private static func said(_ lines: [String], _ text: String) -> Bool {
        lines.contains { $0.hasSuffix("[layout] " + text) }
    }

    private func drag(_ world: Rig, droppedBefore: TimeInterval, showAll: CommandDragLog.ShowAll = .shown,
                      between: (@Sendable () async -> Void)? = nil) async -> [String] {
        let session = world.session
        let clock = world.rig.clock
        return await LogCapture.lines {
            await session.commandDragBegan(showAll: showAll)
            let ended = Task { await session.commandDragEnded(droppedAt: clock.now().addingTimeInterval(-droppedBefore)) }
            #expect(await clock.waitForSleepers(3, within: .seconds(5)))
            clock.advance(by: LayoutFollower.commandDragFollowDelay)
            if let between { await between() }
            await ended.value
        }
    }

    @Test func aFollowThatMovedAnAppSaysWhichAppToWhichSection() async throws {
        let world = await started()
        dragNotesLeft(world)
        let lines = await drag(world, droppedBefore: 0.3)
        #expect(Self.said(lines, "⌘-drag seen: began; everything shown for it"), "\(lines)")
        #expect(Self.said(lines, "⌘-drag followed 0.9 s after the drop: sections changed: \(notes) to Hidden"), "\(lines)")
    }

    @Test func aFollowThatMovedNothingSaysSo() async throws {
        let world = await started()
        let lines = await drag(world, droppedBefore: 0.2, showAll: .settingOff)
        #expect(Self.said(lines, "⌘-drag seen: began; everything not shown for it (the setting is off)"), "\(lines)")
        #expect(Self.said(lines, "⌘-drag followed 0.8 s after the drop: no section changed"), "\(lines)")
    }

    @Test func aFollowThatWasntTrustedNamesTheAppAndTheLimit() async throws {
        let world = await started()
        let clock = world.rig.clock
        dragNotesLeft(world)
        world.rig.extras.stopAnswering(vpn)
        // The read that came back partial took seconds: the next one isn't begun.
        let lines = await drag(world, droppedBefore: 0.5) {
            #expect(await clock.waitForSleepers(3, within: .seconds(5)))
            clock.advance(by: .seconds(3))
        }
        let expected = "⌘-drag not followed 4.1 s after the drop: a read not trusted: \(vpn) didn't answer, or answered in part; "
            + "the limit of 3.5 s was reached"
        #expect(Self.said(lines, expected), "\(lines)")
    }

    @Test func aFollowThatAWriteRefusedSaysSoAndSaysHowItEndedWhenTheWriteEnds() async throws {
        let world = await started()
        let session = world.session
        let clock = world.rig.clock
        dragNotesLeft(world)
        await session.setLayoutPhase(pending: true, settling: true)

        let lines = await LogCapture.lines {
            await session.commandDragBegan()
            let ended = Task { await session.commandDragEnded(droppedAt: clock.now().addingTimeInterval(-0.7)) }
            #expect(await clock.waitForSleepers(3, within: .seconds(5)))
            clock.advance(by: LayoutFollower.commandDragFollowDelay)
            await ended.value
            clock.advance(by: .seconds(5))
            await session.setLayoutPhase(pending: false, settling: false)
            // The follow that was taken has its line once its read is over: the session has no drag to report then.
            _ = await withinTimeLimit(.seconds(5)) {
                while await session.dragDrop != nil { await Task.yield() }
                return true
            }
        }
        let refused = "⌘-drag not followed 1.3 s after the drop: a write of the order was under way; it is followed when the write ends"
        #expect(Self.said(lines, refused), "\(lines)")
        #expect(Self.said(lines, "⌘-drag followed 6.3 s after the drop: sections changed: \(notes) to Hidden"), "\(lines)")
    }

    @Test func aFollowThatBeganLateSaysHowLate() async throws {
        let world = await started()
        let lines = await drag(world, droppedBefore: 58)
        #expect(Self.said(lines, "⌘-drag followed 58.6 s after the drop: no section changed; its wait began 58.0 s after the drop"), "\(lines)")
    }

    /// Until the condition holds, which is asked of the session (a wait that hangs ends at the limit).
    private func eventually(_ condition: @escaping @Sendable () async -> Bool) async -> Bool {
        await withinTimeLimit(.seconds(5)) {
            while await !condition() { await Task.yield() }
            return true
        } ?? false
    }

    @Test func aDragWhoseMouseUpWasNotSeenIsNotSaidToHaveBeenDropped() async throws {
        let world = await started()
        let session = world.session
        let clock = world.rig.clock
        dragNotesLeft(world)
        let lines = await LogCapture.lines {
            await session.commandDragBegan(showAll: .settingOff)
            // The monitor took the drag as ended at the cap, 10.4 s after it began, and the session was told a moment later.
            let ended = Task { await session.commandDragEnded(droppedAt: clock.now().addingTimeInterval(-0.4), end: .capReached(after: 10.4)) }
            #expect(await clock.waitForSleepers(3, within: .seconds(5)))
            clock.advance(by: LayoutFollower.commandDragFollowDelay)
            await ended.value
        }
        let expected = "⌘-drag followed 1.0 s after the cap: sections changed: \(notes) to Hidden; "
            + "no mouse-up seen, the drag was held 10.4 s"
        #expect(Self.said(lines, expected), "\(lines)")
    }

    @Test func aFollowThatAWriteDeferredLeavesALaterDragsLineToThatDrag() async throws {
        let world = await started()
        let session = world.session
        let clock = world.rig.clock
        let extras = world.rig.extras
        dragNotesLeft(world)
        await session.setLayoutPhase(pending: true, settling: true)

        let lines = await LogCapture.lines {
            // The first drag's follow is refused by the write under way.
            await session.commandDragBegan()
            let first = Task { await session.commandDragEnded(droppedAt: clock.now().addingTimeInterval(-0.5)) }
            #expect(await clock.waitForSleepers(3, within: .seconds(5)))
            clock.advance(by: LayoutFollower.commandDragFollowDelay)
            await first.value

            // The write ends: the follow it deferred is taken, and its read is held. Meanwhile another drag ends.
            let gate = Gate()
            extras.holdReads(at: gate)
            let held = extras.readsHeld
            await session.setLayoutPhase(pending: false, settling: false)
            #expect(await eventually { extras.readsHeld > held }, "the deferred follow's read is under way")
            await session.commandDragBegan()
            let second = Task { await session.commandDragEnded(droppedAt: clock.now().addingTimeInterval(-0.41)) }
            #expect(await eventually { await session.dragsEnded == 2 })
            let reads = await session.scansIngested
            extras.holdReads(at: nil)
            gate.open()
            #expect(await eventually { await session.scansIngested > reads }, "the deferred follow's read is over")
            for _ in 0..<50 { await Task.yield() }
            #expect(await session.dragDrop != nil, "the second drag's follow is still to be reported: the first didn't take its place")

            #expect(await clock.waitForSleepers(3, within: .seconds(5)))
            clock.advance(by: LayoutFollower.commandDragFollowDelay)
            await second.value
        }
        #expect(Self.said(lines, "⌘-drag not followed 1.1 s after the drop: a write of the order was under way; it is followed when the write ends"), "\(lines)")
        #expect(Self.said(lines, "⌘-drag followed 1.0 s after the drop: no section changed"), "the second drag's own line: \(lines)")
        #expect(!lines.contains { $0.contains("⌘-drag followed 0.4 s after the drop") }, "the deferred follow told nothing of the second drag: \(lines)")
    }

    @Test func aFollowThatMovedAnAppLeavesALineForTheSaveThatSaysItWasTheDrag() async throws {
        let world = await started()
        dragNotesLeft(world)
        let lines = await drag(world, droppedBefore: 0.35)
        #expect(Self.said(lines, "sections saved: \(notes) to Hidden (a ⌘-drag)"), "\(lines)")
    }
}
