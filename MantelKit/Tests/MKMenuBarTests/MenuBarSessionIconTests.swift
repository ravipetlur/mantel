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
/// Icons that something asked to have shown, and the room made for them.
@Suite("Menu bar session: icons asked for", .serialized, .timeLimit(.minutes(1)))
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
}

extension MenuBarSession {
    /// What a layout write or a ⌘-drag holds while it is under way, as a test says it is.
    func hold(settling: Bool? = nil, pending: Bool? = nil, dragging: Bool? = nil) {
        if let settling { layoutSettling = settling }
        if let pending { layoutPending = pending }
        if let dragging { dragBefore = dragging ? ObservedOrder(tokens: [], source: .table) : nil }
    }
}
