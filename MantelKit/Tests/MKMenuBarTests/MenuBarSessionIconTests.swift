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

private let temp = ItemID(bundleID: weather, key: .identifier("weather.temp"))
private let notesIcon = ItemID(bundleID: notes, key: .index(0))

/// Icons that something asked to have shown, and the room made for them.
@Suite("Menu bar session: icons asked for", .timeLimit(.minutes(1)))
struct MenuBarSessionIconTests {
    /// The laptop's bar has room for five of the icons that aren't concealed, counted from the right: the VPN app's, the sync app's two and
    /// Mantel's two. Hidden holds the weather app (two icons) and the notes app (one).
    private func laptop(capacity: Int? = 5, automaticOverflow: Bool = false) -> SessionRig {
        var settings = HidingSettings()
        settings.automaticOverflow = automaticOverflow
        settings.noRoomPolicy = .secondBar
        return SessionRig.withAllowlist(shape: .laptop, capacity: capacity,
                                        sections: sections(shown: [vpn, sync], hidden: [weather, notes]), settings: settings)
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

    // MARK: The plan

    @Test func anIconAskedForIsShownUntilTheTicketEnds() async throws {
        let rig = SessionRig.withAllowlist(sections: sections(hidden: [weather]))
        await rig.session.start()
        #expect(rig.world.concealed == [weather])

        let ticket = await rig.session.revealIcons([temp])
        #expect(rig.world.concealed.isEmpty, "the plan was applied before the call returned")
        let state = try #require(await rig.state)
        #expect(state.plan.source == .iconReveal)
        #expect(state.plan.visibleBundleIDs.contains(weather))

        await rig.session.endIconReveal(ticket)
        #expect(rig.world.concealed == [weather])
        #expect(try #require(await rig.state).plan.source == .sections)
        // A ticket that has ended ends no more.
        let applies = rig.events.all.filter { $0 == "apply" }.count
        await rig.session.endIconReveal(ticket)
        #expect(rig.events.all.filter { $0 == "apply" }.count == applies)
    }

    @Test func twoTicketsKeepAnIconUntilTheLastEnds() async throws {
        let rig = SessionRig.withAllowlist(sections: sections(hidden: [weather]))
        await rig.session.start()
        let first = await rig.session.revealIcons([temp])
        let second = await rig.session.revealIcons([temp])
        await rig.session.endIconReveal(first)
        #expect(rig.world.concealed.isEmpty, "the second ticket still asks for it")
        await rig.session.endIconReveal(second)
        #expect(rig.world.concealed == [weather])
    }

    @Test func iconRevealIsNeverJudgedForOverflow() async throws {
        // with an icon asked for, the bar is as full as the request makes it and says nothing of whether the sections fit.
        // Hidden's apps are drawn beside the Shown ones on a bar that has room for the Shown ones only: automatic overflow would move
        // an app to Hidden for the dots if it took the read for a verdict on the sections.
        var settings = HidingSettings()
        settings.automaticOverflow = true
        let rig = SessionRig.withAllowlist(shape: .laptop, capacity: nil, ownFirst: true,
                                           sections: sections(shown: [vpn, sync], hidden: [weather, notes]), settings: settings)
        await rig.session.start()
        rig.world.setCapacity(nil)
        let ticket = await rig.session.revealIcons([temp])
        rig.world.setCapacity(4)
        #expect(try #require(await rig.state).plan.source == .iconReveal)

        for _ in 0..<6 {
            guard await rig.clock.waitForSleepers(2, within: .seconds(5)) else { break }
            rig.clock.advance(by: .seconds(10))
            #expect(await rig.pumpUntilReads(await rig.session.scansIngested + 1))
        }
        #expect(await rig.session.sections.apps[vpn] == AppPlacement(section: .shown, isAuto: false), "no app was moved for the dots")
        #expect(await rig.session.sections.apps[sync] == AppPlacement(section: .shown, isAuto: false))
        #expect(await rig.session.dotsLogLines.isEmpty, "nothing was said of the dots")
        #expect(rig.saved.all.allSatisfy { $0.apps.values.allSatisfy { !$0.isAuto } }, "and nothing was saved")
        await rig.session.endIconReveal(ticket)
    }

    // MARK: Room

    @Test func roomPredictedUsesCachedWidths() async throws {
        let rig = laptop()
        await rig.session.start()
        // The front app's menus run on to 1100: 54 points are free left of the VPN app's icon. The weather app's two icons took 48 when they
        // were last on the bar, and the notes app's 24.
        try await bringToFront(vpn, menusTo: 1100, in: rig)

        let weatherOnly = await rig.session.revealIcons([temp])
        let both = await rig.session.revealIcons([temp, notesIcon])
        let events = rig.events.all
        let reads = await rig.session.scansIngested
        #expect(await rig.session.roomPredicted(for: weatherOnly), "48 points in 54")
        #expect(!(await rig.session.roomPredicted(for: both)), "72 points are not")
        #expect(rig.events.all == events, "nothing is looked at")
        #expect(await rig.session.scansIngested == reads, "and nothing is read")

        // A ticket that has ended has nothing to fit.
        await rig.session.endIconReveal(both)
        #expect(await rig.session.roomPredicted(for: both))
        await rig.session.endIconReveal(weatherOnly)
    }

    @Test func makeRoomConcealsRightMostShown() async throws {
        let rig = laptop()
        await rig.session.start()
        #expect(rig.world.concealed == [weather, notes])
        let ticket = await rig.session.revealIcons([temp])
        // The weather app's icons are drawn at the left of the bar, which has room for five: they are piled in the « menu.
        #expect(rig.world.concealed == [notes])

        #expect(await rig.session.makeRoom(for: ticket, round: 0))
        // The right-most Shown app that isn't Mantel's goes: the sync app (the VPN app is left of it).
        let room = await rig.session.iconRoomByTicket[ticket.id] ?? []
        #expect(room.contains(sync), "right-most first: \(room)")
        #expect(!room.contains(own), "never Mantel")
        #expect(!room.contains(weather), "never the app the room is for")
        #expect(rig.world.concealed.isSuperset(of: room))
        let state = try #require(await rig.state)
        #expect(state.plan.source == .iconReveal)
        #expect(!state.plan.visibleBundleIDs.contains(sync))
        // The sections are as they were: the room is the ticket's, and not the person's.
        #expect(await rig.session.sections.apps[sync] == AppPlacement(section: .shown, isAuto: false))
        #expect(rig.saved.all.allSatisfy { $0.apps[sync]?.section == .shown }, "nothing was saved for it")

        // Nothing more to make once the icon has room.
        #expect(!(await rig.session.makeRoom(for: ticket, round: 1)))
        // The rounds are three.
        #expect(!(await rig.session.makeRoom(for: ticket, round: 3)))
        await rig.session.endIconReveal(ticket)
    }

    @Test func endRestoresPlan() async throws {
        let rig = laptop()
        await rig.session.start()
        let ticket = await rig.session.revealIcons([temp])
        #expect(await rig.session.makeRoom(for: ticket, round: 0))
        #expect(rig.world.concealed.contains(sync))

        await rig.session.endIconReveal(ticket)

        let state = try #require(await rig.state)
        #expect(state.plan.source == .sections)
        #expect(state.plan.visibleBundleIDs.isSuperset(of: [vpn, sync]), "every app that was concealed for room is shown again")
        #expect(rig.world.concealed == [weather, notes])
        #expect(await rig.session.iconRoomByTicket.isEmpty)
        #expect(await rig.session.iconTickets.isEmpty)
    }

    @Test func roomMadeForOneTicketEndsWithIt() async throws {
        let rig = laptop()
        await rig.session.start()
        let first = await rig.session.revealIcons([temp])
        #expect(await rig.session.makeRoom(for: first, round: 0))
        let second = await rig.session.revealIcons([notesIcon])

        await rig.session.endIconReveal(first)

        #expect(try #require(await rig.state).plan.visibleBundleIDs.contains(sync), "the room made for the first is given back with it")
        await rig.session.endIconReveal(second)
    }

    // MARK: Ending for good

    @Test func resetEndsTickets() async throws {
        let rig = laptop()
        await rig.session.start()
        let ticket = await rig.session.revealIcons([temp])
        #expect(await rig.session.makeRoom(for: ticket, round: 0))

        try await rig.session.reset(restarter: FakeRestarter(), replayJournal: {})

        #expect(await rig.session.iconTickets.isEmpty, "the session clears what was asked for in step 1")
        #expect(await rig.session.iconRoomByTicket.isEmpty)
        let state = try #require(await rig.state)
        #expect(state.plan.source == .sections)
        #expect(rig.world.concealed == [weather, notes])
        // The caller's end of the ticket, later, changes nothing.
        let applies = rig.events.all.filter { $0 == "apply" }.count
        await rig.session.endIconReveal(ticket)
        #expect(rig.events.all.filter { $0 == "apply" }.count == applies)
    }

    @Test func quitEndsTicketsAndTheRoomMadeForThem() async throws {
        let rig = laptop()
        await rig.session.start()
        let ticket = await rig.session.revealIcons([temp])
        #expect(await rig.session.makeRoom(for: ticket, round: 0))

        await rig.session.tearDownForQuit()

        #expect(await rig.session.iconTickets.isEmpty)
        #expect(await rig.session.iconRoomByTicket.isEmpty)
        // No ticket reveals anything once the quit has begun, and none makes room.
        let late = await rig.session.revealIcons([temp])
        #expect(await rig.session.iconTickets.isEmpty)
        #expect(!(await rig.session.makeRoom(for: late, round: 0)))
    }

    @Test func aPlanChangeDuringATicketKeepsTheIconShown() async throws {
        // A dot click, Focus Mode and the rest change the plan: the layer is independent of them, and survives them.
        let rig = SessionRig.withAllowlist(sections: sections(hidden: [weather], alwaysHidden: [notes]))
        await rig.session.start()
        let ticket = await rig.session.revealIcons([temp])
        _ = await rig.session.applyReveal(.focusMode)
        #expect(rig.world.concealed.contains(sync) || rig.world.concealed.contains(vpn), "Focus Mode conceals the Shown apps")
        #expect(!rig.world.concealed.contains(weather), "and the icon that was asked for stays")
        #expect(try #require(await rig.state).plan.source == .focusMode)
        _ = await rig.session.applyReveal(.collapsed)
        #expect(!rig.world.concealed.contains(weather))
        await rig.session.endIconReveal(ticket)
        #expect(rig.world.concealed.contains(weather))
    }

    // MARK: What the click path asks of the session

    @Test func aClickMayBePostedOnlyWhileTheBarIsStillAndNothingHoldsIt() async throws {
        let rig = laptop()
        await rig.session.start()
        let changes = await rig.session.barChanges
        #expect(await rig.session.clickFence(since: changes) == .clear)

        // A plan was applied since the look: the bar is looked at again.
        _ = await rig.session.applyReveal(.hiddenShown)
        #expect(await rig.session.clickFence(since: changes) == .barChanged)
        let now = await rig.session.barChanges
        #expect(await rig.session.clickFence(since: now) == .clear)

        // A layout write that settles or is pending, a ⌘-drag under way: nothing is posted.
        await rig.session.hold(settling: true)
        #expect(await rig.session.clickFence(since: now) == .blocked, "the bar is being re-sorted")
        await rig.session.hold(settling: false)
        await rig.session.hold(pending: true)
        #expect(await rig.session.clickFence(since: now) == .blocked, "a write is pending")
        await rig.session.hold(pending: false)
        await rig.session.hold(dragging: true)
        #expect(await rig.session.clickFence(since: now) == .blocked, "a ⌘-drag is under way")
        await rig.session.hold(dragging: false)
        #expect(await rig.session.clickFence(since: now) == .clear)

        await rig.session.tearDownForQuit()
        #expect(await rig.session.clickFence(since: await rig.session.barChanges) == .blocked, "the quit has begun")
    }

    @Test func aClickMayNotBePostedInTheSecondsAfterAChangeOfDisplays() async throws {
        // MenuBarAgent's other windows keep the old slots for a while after the displays change, and no plan need follow for the bar to move.
        let rig = laptop()
        await rig.session.start()
        let changed = Task { await rig.session.displaysChanged(rig.world.layout) }
        #expect(await rig.letTheCoalescedReadGo())
        await changed.value

        #expect(await rig.session.clickFence(since: await rig.session.barChanges) == .blocked, "a change of displays has just happened")
        rig.clock.advance(by: .milliseconds(2500))
        #expect(await rig.session.clickFence(since: await rig.session.barChanges) == .blocked, "still within three seconds")
        rig.clock.advance(by: .milliseconds(600))
        #expect(await rig.session.clickFence(since: await rig.session.barChanges) == .clear)
    }

    @Test func aClickMayNotBePostedWhileAResetIsUnderWay() async throws {
        let rig = laptop()
        await rig.session.start()
        let gate = Gate()
        let restarter = FakeRestarter()
        restarter.whileRestarting { await gate.wait() }
        let reset = Task { try await rig.session.reset(restarter: restarter, replayJournal: {}) }
        #expect(await waitUntil { restarter.restarts == 1 })
        #expect(await rig.session.isResetting)

        #expect(await rig.session.clickFence(since: await rig.session.barChanges) == .blocked, "the menu bar is being restarted")

        gate.open()
        try await reset.value
        #expect(await rig.session.clickFence(since: await rig.session.barChanges) == .clear)
    }

    @Test func theProcessThatOwnsAnAppsItemsIsTheOneTheScansFoundThemOn() async throws {
        // The weather app runs a helper that has no item, and whose process ID is the lower: the menu of the icon is the app's own process's.
        let rig = SessionRig.withAllowlist(sections: sections(shown: [notes], hidden: [weather]))
        rig.world.addHelper(of: weather, pid: 900)
        await rig.session.start()

        #expect(await rig.session.extrasOwnerPID(ofApp: weather) == rig.world.app(weather).pid)
        #expect(await rig.session.extrasOwnerPID(ofApp: notes) == rig.world.app(notes).pid, "one process: that one")
        #expect(await rig.session.extrasOwnerPID(ofApp: "com.example.gone") == nil)
    }
}

extension MenuBarSession {
    /// What a layout write or a ⌘-drag holds while it is under way, as a test says it is.
    func hold(settling: Bool? = nil, pending: Bool? = nil, dragging: Bool? = nil) {
        if let settling { layoutSettling = settling }
        if let pending { layoutPending = pending }
        if let dragging { dragBefore = dragging ? ObservedOrder(tokens: [], source: .table) : nil }
    }
}
