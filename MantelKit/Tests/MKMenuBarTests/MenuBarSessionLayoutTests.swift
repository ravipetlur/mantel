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
@Suite("Menu bar session: layout", .serialized, .timeLimit(.minutes(1)))
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

    // MARK: ⌘-drags

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
