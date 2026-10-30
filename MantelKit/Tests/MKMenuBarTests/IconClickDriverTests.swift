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
private let main = DisplayFixtures.deskMain.uuid

/// The weather app's first item, which the plan has in Hidden, and the notes app's, which is Shown.
private let hiddenItem = ItemID(bundleID: weather, key: .identifier("weather.temp"))
private let shownItem = ItemID(bundleID: notes, key: .index(0))

/// Where the item's slot is in these tests: on the main display's bar, clear of the front app's menus, with another app's slot beside it.
private let slot = CGRect(x: 3000, y: 0, width: 36, height: 30)
private let neighbour = CGRect(x: 3040, y: 0, width: 36, height: 30)

/// Reads the clock a test moves, for what a click records.
private final class Passed: Sendable {
    private let items = Mutex<[ItemLocation]>([])
    func add(_ location: ItemLocation) { items.withLock { $0.append(location) } }
    var all: [ItemLocation] { items.withLock { $0 } }
}

/// The rehide delay a test turns over.
private final class Rehide: Sendable {
    private let delay = Mutex<RehideDelay>(.seconds(10))
    var current: RehideDelay { delay.withLock { $0 } }
    func set(_ new: RehideDelay) { delay.withLock { $0 = new } }
}

/// A driver over a session that has started, with fakes for everything else.
private struct Rig {
    let world: SessionRig
    let clock = FakeClock()
    let locator = FakeItemLocator()
    let presser = FakeItemPresser()
    let poster = FakeClickPoster()
    let windows = FakeWindowList()
    let pointerInBar = Switch(false)
    let rehide = Rehide()
    let passed = Passed()
    let driver: IconClickDriver
    /// The display the apps' frames are on, and the one an icon is looked for on: the main display of the desk, the laptop's own display.
    let display: String

    static func make(_ world: SessionRig, rules: ClickRouteRules = .measured, presser custom: (any ItemPressing)? = nil,
                     shape: SessionWorld.Shape = .desk, locator real: (any ItemLocating)? = nil) -> Rig {
        Rig(world: world, rules: rules, custom: custom, display: shape == .laptop ? DisplayFixtures.laptopAlone.uuid : main, real: real)
    }

    private init(world: SessionRig, rules: ClickRouteRules, custom: (any ItemPressing)?, display: String, real: (any ItemLocating)?) {
        self.display = display
        self.world = world
        let weatherPID = world.world.app(weather).pid, notesPID = world.world.app(notes).pid
        let clock = clock, passed = passed, rehide = rehide, pointer = pointerInBar
        driver = IconClickDriver(
            session: world.session, locator: real ?? locator, presser: custom ?? presser, poster: poster, windows: windows,
            pidOf: { ["com.apple.controlcenter": 600, weather: weatherPID, notes: notesPID][$0] }, pointerInBar: { pointer.isOn },
            clock: clock, rules: rules, rehide: { rehide.current }, captured: { passed.add($0) })
    }

    /// A world with the weather app in Hidden, started: its first item is concealed and the notes app's is Shown.
    static func started(rules: ClickRouteRules = .measured, shape: SessionWorld.Shape = .desk, capacity: Int? = nil,
                        sections model: SectionModel? = nil, presser custom: (any ItemPressing)? = nil) async -> Rig {
        // Automatic overflow is off: what the laptop's bar has room for is the test's to say, and no app is moved on its own.
        var settings = HidingSettings()
        settings.automaticOverflow = false
        let world = SessionRig.withAllowlist(shape: shape, capacity: capacity,
                                             sections: model ?? sections(shown: [notes, vpn, sync], hidden: [weather]), settings: settings)
        await world.session.start()
        let rig = Rig.make(world, rules: rules, presser: custom, shape: shape)
        rig.locator.setSnapshot(SlotSnapshot(displayUUID: rig.display, slots: [slot, neighbour], owners: [notes, vpn]))
        return rig
    }

    func location(of item: ItemID, tiedBy: ItemLocation.TiedBy = .tieAndNewSlots, in frame: CGRect = slot, wasInBaseline: Bool = false)
        -> ItemLocation {
        FakeItemLocator.location(of: item, slot: frame, display: display, tiedBy: tiedBy, wasInBaseline: wasInBaseline)
    }

    /// The weather app's menu, as it is at 10 points below the bar.
    func menu(of app: String = weather, number: Int = 500, below: CGFloat = 10) -> WindowInfo {
        WindowInfo(number: number, ownerPID: world.world.app(app).pid, ownerBundleID: app, layer: WindowLevels.popUpMenu,
                   bounds: CGRect(x: slot.minX + 2, y: 30 + below, width: 220, height: 300), alpha: 1)
    }

    var tickets: Int { get async { await world.session.iconTickets.count } }
    var concealed: Set<String> { world.world.concealed }

    /// Clicks, moving the driver's clock on by 50 ms each time something sleeps on it, until the click is answered.
    @discardableResult
    func click(_ item: ItemID, _ kind: ClickKind = .left, display: String? = nil, sessionMoves: Bool = true,
               beforeClick: @escaping @Sendable () async -> Void = {}) async -> IconClickOutcome {
        let driver = driver
        let request = IconClickRequest(item: item, kind: kind, display: display, origin: .commandBar)
        let done = Switch(false)
        let task = Task {
            let outcome = await driver.click(request, beforeClick: beforeClick)
            done.set(true)
            return outcome
        }
        let finished = await pump(until: done, sessionMoves: sessionMoves)
        #expect(finished == true, "the click was answered")
        return await task.value
    }

    /// Moves the driver's clock on by 50 ms each time something sleeps on it, until `done` is on. The session's clock goes on with it: a plan
    /// that is applied is drawn some time later, on the one clock a real click has. The driver's other tasks are given their turns before each
    /// step: on a slow machine the clock would otherwise move past a wait (the time a press is given) before a task that was ready to answer
    /// (the watch for a menu) had run.
    func pump(until done: Switch, sessionMoves: Bool = true) async -> Bool? {
        let clock = clock, sessionClock = world.clock
        return await withinTimeLimit(.seconds(10)) {
            while !done.isOn, !Task.isCancelled {
                await letTasksRun(turns: 100)
                if await clock.waitForSleepers(1, within: .milliseconds(5)) {
                    clock.advance(by: .milliseconds(50))
                    if sessionMoves { sessionClock.advance(by: .milliseconds(50)) }
                }
            }
            return true
        }
    }

    /// Moves the driver's clock on in steps of `step` until `done` holds (the watch and the delay of a click that was sent, on their own).
    /// **Only the driver's clock moves**, not the session's: a click that is driven by `advance` or `pass` while a plan was applied lately
    /// never sees the bar settle, gives up after `settleLimit` and takes the route that doesn't look. `click` and `pump` move both.
    @discardableResult
    func advance(by step: Duration = .milliseconds(200), until done: @escaping @Sendable () async -> Bool) async -> Bool {
        let clock = clock
        let result = await withinTimeLimit(.seconds(10)) {
            while !Task.isCancelled, await !done() {
                if await clock.waitForSleepers(1, within: .milliseconds(5)) { clock.advance(by: step) }
                try? await Task.sleep(for: .milliseconds(1))
            }
            return true
        }
        return result ?? false
    }

    /// Moves the clock on by this much, a step at a time, with the driver's tasks given the time to run in between. As `advance`, it moves
    /// only the driver's clock.
    func pass(_ total: Duration, step: Duration = .milliseconds(200)) async {
        var passed: Duration = .zero
        var idle = 0
        while passed < total {
            // Only a step that something was sleeping through is time that passed: a sleeper that hasn't registered yet on a busy Mac
            // isn't passed over. When nothing has slept for a good while (a test of what is not done), the time passes all the same.
            if await clock.waitForSleepers(1, within: .milliseconds(20)) {
                idle = 0
                clock.advance(by: step)
                passed += step
            } else {
                idle += 1
                if idle >= Self.idlePolls {
                    clock.advance(by: step)
                    passed += step
                }
            }
            try? await Task.sleep(for: .milliseconds(2))
        }
    }

    /// How many polls in a row find nothing asleep before `pass` takes it that nothing is going to be.
    private static let idlePolls = 50

    func waitFor(_ condition: @escaping @Sendable () async -> Bool) async -> Bool {
        let result = await withinTimeLimit(.seconds(10)) {
            while !Task.isCancelled, await !condition() { try? await Task.sleep(for: .milliseconds(1)) }
            return true
        }
        return result ?? false
    }
}

/// Clicking an icon wherever it is: drawn, with no room, hidden, or where it can't be told.
@Suite("Icon click driver", .timeLimit(.minutes(2)))
struct IconClickDriverTests {
    // MARK: A drawn icon

    @Test(arguments: [false, true]) func aDrawnLeftClickPressesOrPostsAsRuled(posts: Bool) async throws {
        var rules = ClickRouteRules.measured
        if posts { rules.leftClick = .post }
        let rig = await Rig.started(rules: rules)
        rig.locator.place(rig.location(of: shownItem, tiedBy: .tie, wasInBaseline: true))

        let outcome = await rig.click(shownItem)

        #expect(outcome == .clicked(posts ? .postedDrawn : .pressedDrawn))
        #expect(rig.presser.pressed == (posts ? [] : [shownItem]))
        #expect(rig.poster.clicks == (posts ? [.init(kind: .left, point: CGPoint(x: slot.midX, y: slot.midY))] : []))
    }

    @Test func drawnRightPostsAtSlotCentre() async throws {
        let rig = await Rig.started()
        rig.locator.place(rig.location(of: shownItem, tiedBy: .tie, wasInBaseline: true))

        let outcome = await rig.click(shownItem, .right)

        #expect(outcome == .clicked(.postedDrawn))
        #expect(rig.poster.clicks == [.init(kind: .right, point: CGPoint(x: slot.midX, y: slot.midY))])
        #expect(rig.presser.pressed.isEmpty)
    }

    @Test func postsOnlyAtTheItemsOwnSlot() async throws {
        // another app's slot lies right beside the item's, and that app's icon is drawn and located. The click lands at the
        // slot that was told to be the item's, and never at the neighbour's.
        let rig = await Rig.started()
        rig.locator.place(rig.location(of: hiddenItem, tiedBy: .tieAndNewSlots))
        rig.locator.place(rig.location(of: shownItem, tiedBy: .tie, in: neighbour, wasInBaseline: true))

        let outcome = await rig.click(hiddenItem, .right)

        #expect(outcome == .clicked(.postedDrawn))
        #expect(rig.poster.clicks == [.init(kind: .right, point: CGPoint(x: slot.midX, y: slot.midY))])
        #expect(!rig.poster.clicks.contains { neighbour.contains($0.point) })
    }

    @Test func staleFrameInAnUntiedSlotNeverPosts() async throws {
        // the item was concealed at the snapshot, and what the locator finds is its own app's frame tied to a slot that
        // was there before (a frame it left behind): nothing says the slot is its, so nothing is posted. The slot is drawn, so room
        // wouldn't be what is lacking: a right click couldn't be reached.
        let rig = await Rig.started()
        rig.locator.place(rig.location(of: hiddenItem, tiedBy: .tie, wasInBaseline: true))

        let right = await rig.click(hiddenItem, .right)
        #expect(right == .failed(.unreachable))
        #expect(rig.poster.clicks.isEmpty)
        #expect(await rig.tickets == 0)
        #expect(rig.concealed == [weather], "no room was made for it")

        // An option click arrives as a left click here: it is pressed where it is, as a left click is (Accessibility finds the item by its
        // own list).
        let option = await rig.click(hiddenItem, .option)
        #expect(option == .clicked(.pressedInPlace))
        let left = await rig.click(hiddenItem, .left)
        #expect(left == .clicked(.pressedInPlace))
        #expect(rig.presser.pressed == [hiddenItem, hiddenItem])
        #expect(rig.poster.clicks.isEmpty)
    }

    @Test func aTieAloneIsNotEnoughEvenWhenTheSlotLooksNew() async throws {
        // `newSlots` alone (a slot appeared and the app's frame says nothing of it) is not postable either, and there is room: the
        // icon can't be told, and the answer is that it couldn't be reached.
        let rig = await Rig.started()
        rig.locator.place(rig.location(of: hiddenItem, tiedBy: .newSlots))

        #expect(await rig.click(hiddenItem, .right) == .failed(.unreachable))
        #expect(rig.poster.clicks.isEmpty)
    }

    @Test func newSlotsFallbackPosts() async throws {
        // The item is nowhere for the first three looks (macOS is drawing it), then in a slot that appeared and that its frame agrees with.
        let rig = await Rig.started()
        rig.locator.appear(rig.location(of: hiddenItem, tiedBy: .tieAndNewSlots), afterCalls: 3)

        let outcome = await rig.click(hiddenItem, .right)

        #expect(outcome == .clicked(.postedDrawn))
        #expect(rig.poster.clicks == [.init(kind: .right, point: CGPoint(x: slot.midX, y: slot.midY))])
        #expect(rig.locator.calls(of: hiddenItem).count == 4, "the first look is the snapshot's; then every 50 ms")
    }

    // MARK: No room, and a hidden bar

    @Test func notDrawnPressInPlace() async throws {
        // Hidden, and no slot is ever found: a left click presses the item where it is (the platform opens its menu on screen).
        let rig = await Rig.started()
        rig.locator.remove(hiddenItem)

        let outcome = await rig.click(hiddenItem)

        #expect(outcome == .clicked(.pressedInPlace))
        #expect(rig.presser.pressed == [hiddenItem])
        #expect(rig.poster.clicks.isEmpty)
        // Nothing is concealed for a left click.
        #expect(await rig.world.session.iconRoomByTicket.values.allSatisfy(\.isEmpty))
    }

    @Test func notDrawnMakesRoomUpToThreeRounds() async throws {
        // The laptop's bar has room for four icons: the weather app's two, drawn at the left, are piled; the sync app and then the VPN app
        // are concealed for them, right-most first, a round each, and the item is looked for after each. It is never drawn (the fake
        // locator has nothing to say), so a right click can't be reached (the room was made: it isn't "no room"), and everything that was
        // concealed comes back.
        let rig = await Rig.started(shape: .laptop, capacity: 4)
        let seen = Mutex<[Set<String>]>([])
        let world = rig.world.world
        rig.locator.answer(for: hiddenItem) { _ in
            let now = world.concealed
            seen.withLock { if $0.last != now { $0.append(now) } }
            return nil
        }

        let outcome = await rig.click(hiddenItem, .right)

        let rounds = seen.withLock { $0 }
        #expect(outcome == .failed(.unreachable), "\(outcome) after \(rounds)")
        #expect(rounds.count == 3, "looked at with no room made, after one round and after two: \(rounds)")
        #expect(rounds.dropFirst().first?.contains(sync) == true && rounds.dropFirst().first?.contains(vpn) == false, "the right-most first")
        #expect(rounds.last?.isSuperset(of: [sync, vpn]) == true, "and then the next")
        #expect(rig.poster.clicks.isEmpty)
        #expect(await rig.tickets == 0, "the reveal ended on failure, and the room with it")
        #expect(await rig.waitFor { rig.concealed == [weather] }, "the apps concealed for the click are shown again: \(rig.concealed)")
    }

    /// A bar with room for three icons, nothing Shown but Mantel's own to conceal, and the weather app's two icons piled: no room can be made.
    private func aBarWithNoRoomToMake(rules: ClickRouteRules = .measured) async -> Rig {
        await Rig.started(rules: rules, shape: .laptop, capacity: 3, sections: sections(hidden: [weather, notes, vpn, sync]))
    }

    @Test func noRoomLeftClickReportsNoRoomWhenPressingUndrawnIsNotTrusted() async throws {
        var rules = ClickRouteRules.measured
        rules.whenNotDrawn = .makeRoom
        rules.pressWorksUndrawn = false
        let rig = await aBarWithNoRoomToMake(rules: rules)
        rig.locator.remove(hiddenItem)

        let outcome = await rig.click(hiddenItem)

        #expect(outcome == .failed(.noRoom))
        #expect(rig.presser.pressed.isEmpty, "no silent press")
        #expect(rig.poster.clicks.isEmpty)
        #expect(await rig.tickets == 0)
    }

    @Test func noRoomRightClickFails() async throws {
        let rig = await aBarWithNoRoomToMake()
        rig.locator.remove(hiddenItem)

        #expect(await rig.click(hiddenItem, .right) == .failed(.noRoom))
        #expect(rig.poster.clicks.isEmpty)
        #expect(rig.presser.pressed.isEmpty)
        // An option click is a left click here: it is pressed where it is, and no room is made for it.
        #expect(await rig.click(hiddenItem, .option) == .clicked(.pressedInPlace))
        #expect(rig.presser.pressed == [hiddenItem])
    }

    @Test func aBarWithRoomAndNoSlotToldIsUnreachableNotNoRoom() async throws {
        // The bar has room (the desk's), and the locator finds nothing (no Accessibility, an app macOS has turned off): there is room, so
        // "no room" isn't the answer.
        let rig = await Rig.started()
        rig.locator.remove(hiddenItem)

        #expect(await rig.click(hiddenItem, .right) == .failed(.unreachable))
        #expect(rig.poster.clicks.isEmpty)
        #expect(await rig.tickets == 0)
    }

    @Test func hiddenBarLeftPressesRightFails() async throws {
        // A full-screen app has the display: its bar isn't on screen, and nothing is drawn there.
        let rig = await Rig.started()
        rig.world.world.setBarShown(0, false)
        rig.locator.place(rig.location(of: hiddenItem, tiedBy: .tieAndNewSlots))

        #expect(await rig.click(hiddenItem, .right) == .failed(.hiddenBar))
        #expect(rig.poster.clicks.isEmpty)
        #expect(await rig.click(hiddenItem, .left) == .clicked(.pressedInPlace))
        #expect(await rig.click(hiddenItem, .option) == .clicked(.pressedInPlace), "an option click is a left click here")
        #expect(rig.presser.pressed == [hiddenItem, hiddenItem])

        // Where pressing an item with no room can't be trusted, a left click says so too.
        var rules = ClickRouteRules.measured
        rules.pressWorksUndrawn = false
        let careful = Rig.make(rig.world, rules: rules)
        careful.locator.setSnapshot(SlotSnapshot(displayUUID: main, slots: [slot], owners: [notes]))
        careful.locator.place(careful.location(of: hiddenItem, tiedBy: .tieAndNewSlots))
        #expect(await careful.click(hiddenItem, .left) == .failed(.hiddenBar))
        #expect(careful.presser.pressed.isEmpty)
    }

    // MARK: Where an item can't be located (an item that can't be located)

    private var locatingIsOff: ClickRouteRules {
        var rules = ClickRouteRules.measured
        rules.locateWorks = false
        return rules
    }

    @Test func withoutLocatingALeftClickPressesInPlace() async throws {
        let rig = await Rig.started(rules: locatingIsOff)

        #expect(await rig.click(hiddenItem) == .clicked(.pressedInPlace))
        #expect(rig.presser.pressed == [hiddenItem])
        #expect(rig.locator.calls.isEmpty, "nothing was located")
        #expect(rig.locator.snapshotCallCount == 0)
        #expect(rig.poster.clicks.isEmpty, "and nothing is posted")
    }

    /// The laptop's bar with the front app's menus run on to within `free` points of the left-most icon that is drawn.
    private func crowd(_ rig: Rig, leaving free: CGFloat) async throws {
        let session = rig.world.session
        let leftMost = try #require(OverflowInputs.occupiedFrames(in: await session.inventory).map(\.minX).min())
        let pid = try #require(rig.world.world.fixture().pid(of: vpn))
        let ax = rig.world.world.fixture().ax
        let bar = ax.addNode(attributes: [AXName.role: .string("AXMenuBar")])
        ax.addNode(attributes: FakeAX.frameAttributes(CGRect(x: 0, y: 0, width: leftMost - free, height: 30)), under: bar)
        ax.setAttribute(AXName.menuBar, .elements([ax.ref(bar)]), on: ax.root(ofApp: pid))
        await session.frontAppChanged(pid: pid, activeScreenWidth: 1728)
    }

    @Test func withoutLocatingALeftClickMakesRoomThenPressesWherePressingUndrawnIsNotTrusted() async throws {
        // The laptop's bar has room for five: the weather app's two icons (48 points) don't fit in the 24 that are free, and concealing the
        // sync app, which the cached widths count, makes room enough.
        var rules = locatingIsOff
        rules.whenNotDrawn = .makeRoom
        rules.pressWorksUndrawn = false
        let rig = await Rig.started(rules: rules, shape: .laptop, capacity: 5)
        try await crowd(rig, leaving: 24)

        let outcome = await rig.click(hiddenItem)

        #expect(outcome == .clicked(.madeRoomThenPressed))
        #expect(rig.presser.pressed == [hiddenItem])
        #expect(rig.locator.calls.isEmpty)
        #expect(await rig.tickets == 1, "the room stays for as long as the menu is out, and then goes")
        #expect(rig.concealed.contains(sync), "the sync app was concealed for it")
        #expect(await rig.advance(until: { await rig.tickets == 0 }))
        #expect(await rig.waitFor { rig.concealed == [weather] }, "and it is shown again: \(rig.concealed)")
    }

    @Test func withoutLocatingARightClickShowsTheMenu() async throws {
        var rules = locatingIsOff
        rules.showMenuWorks = true
        let rig = await Rig.started(rules: rules)

        #expect(await rig.click(hiddenItem, .right) == .clicked(.shownMenu))
        #expect(rig.presser.menusShown == [hiddenItem])
        #expect(rig.poster.clicks.isEmpty)
    }

    @Test func withoutLocatingARightClickWithNoShowMenuIsUnreachable() async throws {
        let rig = await Rig.started(rules: locatingIsOff)

        #expect(await rig.click(hiddenItem, .right) == .failed(.unreachable), "showMenu is refused here")
        #expect(rig.presser.menusShown.isEmpty)
        // An option click is a left click here, and a left click presses in place.
        #expect(await rig.click(hiddenItem, .option) == .clicked(.pressedInPlace))
        #expect(rig.poster.clicks.isEmpty)
    }

    // MARK: Who and what

    @Test func aClickOnARecordThatIsNotCurrentRevealsNothingAndFailsAtOnce() async throws {
        let rig = await Rig.started()
        // The weather app is running and was read whole: it lists `weather.temp` and `weather.alerts`, and a record of another icon is none.
        let phantom = ItemID(bundleID: weather, key: .identifier("x.phantom"))
        #expect(await rig.world.session.hasNoSuchIcon(phantom))
        #expect(await rig.world.session.hasNoSuchIcon(hiddenItem) == false)

        let outcome = await rig.driver.click(IconClickRequest(item: phantom, kind: .left, display: nil, origin: .secondBar))

        #expect(outcome == .failed(.unreachable))
        #expect(rig.presser.pressed.isEmpty, "nothing is pressed")
        #expect(rig.locator.calls.isEmpty, "nothing is looked for")
        #expect(await rig.tickets == 0, "no icon is asked for: nothing is revealed")
        #expect(rig.locator.snapshotCallCount == 0, "and the bar isn't looked at")
    }

    @Test func aHiddenSystemIconIsUnreachableAtOnce() async throws {
        // A reveal never draws a hidden system icon: nothing is waited for, and no icon is asked for.
        var model = sections(shown: [notes, vpn, sync], hidden: [weather])
        model.move(item: .system("wifi"), to: .hidden)
        let rig = await Rig.started(sections: model)
        let before = rig.clock.now()

        let outcome = await rig.driver.click(IconClickRequest(item: .system("wifi"), kind: .left, display: nil, origin: .secondBar))

        #expect(outcome == .failed(.unreachable))
        #expect(rig.clock.now() == before, "no time passed on the driver's clock")
        #expect(rig.locator.calls.isEmpty)
        #expect(rig.presser.pressed.isEmpty)
        #expect(await rig.tickets == 0)
        // A system icon that is shown is clicked as any other.
        rig.locator.place(rig.location(of: .system("battery"), tiedBy: .tie, wasInBaseline: true))
        #expect(await rig.click(.system("battery"), .left) == .clicked(.pressedDrawn))
    }

    /// A started session that has flagged the notes app: macOS doesn't tie its icon to it.
    static func flaggedWorld() async -> SessionRig {
        let approvals = FakeEngine(.approvals, log: CallLog())
        approvals.setAvailability(.available)
        var settings = HidingSettings()
        settings.automaticOverflow = false
        let world = SessionRig.withAllowlist(sections: sections(shown: [notes, vpn, sync], hidden: [weather]), settings: settings,
                                             otherEngines: [.approvals: approvals])
        world.world.setUnattached([notes])
        await world.session.start()
        var reads = SessionRig.readsAtStart
        for _ in 0..<3 where !(await world.session.isUnattached(notes)) {
            reads += 1
            #expect(await world.clock.waitForSleepers(2, within: .seconds(5)))
            world.clock.advance(by: .seconds(10))
            #expect(await world.pumpUntilReads(reads))
        }
        #expect(await world.session.isUnattached(notes), "the session has flagged the notes app")
        return world
    }

    @Test func anAppWhoseIconMacOSDoesntTieToItIsPressedInPlace() async throws {
        // Such an icon never draws under the allowlist, so no room is made for it (concealing Shown apps would be for nothing): a left
        // click presses it where it is, anything else can't be reached. Nothing is located, and nothing is posted.
        let world = await Self.flaggedWorld()
        let rig = Rig.make(world)
        rig.locator.place(rig.location(of: shownItem, tiedBy: .tie, wasInBaseline: true))

        #expect(await rig.click(shownItem, .left) == .clicked(.pressedInPlace))
        #expect(rig.presser.pressed == [shownItem])
        #expect(await rig.click(shownItem, .right) == .failed(.unreachable))
        #expect(await rig.click(shownItem, .option) == .clicked(.pressedInPlace), "an option click is a left click here")
        #expect(rig.presser.pressed == [shownItem, shownItem])
        #expect(rig.poster.clicks.isEmpty)
        #expect(rig.locator.calls.isEmpty, "it was not looked for")
        #expect(await world.session.iconRoomByTicket.values.allSatisfy(\.isEmpty))

        // Where pressing an icon with no room can't be trusted, the answer is that it couldn't be reached.
        var rules = ClickRouteRules.measured
        rules.pressWorksUndrawn = false
        let careful = Rig.make(world, rules: rules)
        #expect(await careful.click(shownItem, .left) == .failed(.unreachable))
        #expect(careful.presser.pressed.isEmpty)
    }

    @Test func capturesTheDrawnSlot() async throws {
        let rig = await Rig.started()
        let location = rig.location(of: hiddenItem, tiedBy: .tieAndNewSlots)
        rig.locator.place(location)

        #expect(await rig.click(hiddenItem, .right) == .clicked(.postedDrawn))

        let passed = rig.passed
        #expect(await rig.waitFor { passed.all == [location] }, "the capture is asked for the slot that was drawn, on a task of its own")
        // An icon that wasn't drawn is not captured.
        let none = await Rig.started()
        none.locator.remove(hiddenItem)
        #expect(await none.click(hiddenItem) == .clicked(.pressedInPlace))
        #expect(none.passed.all.isEmpty)
    }

    // MARK: The reveal ends

    @Test func concealsAgainAfterTheMenuClosesAndTheDelay() async throws {
        let rig = await Rig.started()
        rig.locator.place(rig.location(of: hiddenItem, tiedBy: .tieAndNewSlots))
        rig.presser.onPress { [windows = rig.windows, menu = rig.menu()] _ in windows.set([menu]) }
        #expect(await rig.click(hiddenItem) == .clicked(.pressedDrawn))

        // The menu is open for a while.
        await rig.pass(.seconds(3))
        #expect(await rig.tickets == 1)
        rig.windows.set([])
        // The delay is ten seconds from when it was seen to be closed.
        await rig.pass(.seconds(5))
        #expect(await rig.tickets == 1, "five seconds into the delay")
        #expect(!rig.concealed.contains(weather))
        #expect(await rig.advance(until: { await rig.tickets == 0 }))
        #expect(await rig.waitFor { rig.concealed.contains(weather) }, "concealed again")
    }

    @Test func neverConcealsUnderAnOpenMenu() async throws {
        let rig = await Rig.started()
        rig.locator.place(rig.location(of: hiddenItem, tiedBy: .tieAndNewSlots))
        rig.presser.onPress { [windows = rig.windows, menu = rig.menu()] _ in windows.set([menu]) }
        #expect(await rig.click(hiddenItem) == .clicked(.pressedDrawn))
        await rig.pass(.seconds(1))

        // The item's menu is gone and another is open (the person went to another icon): the icon isn't put away under it, however long.
        let other = rig.menu(of: notes, number: 501)
        rig.windows.set([other])
        let reads = rig.windows.readCount
        await rig.pass(.seconds(40))
        #expect(rig.windows.readCount > reads, "the driver looked at the window list while it held")
        #expect(await rig.tickets == 1)
        #expect(!rig.concealed.contains(weather))

        rig.windows.set([])
        #expect(await rig.advance(until: { await rig.tickets == 0 }))
    }

    // MARK: A newer click

    @Test func overtakenClickPostsNothing() async throws {
        // the first click is still waiting for its icon to be drawn when another comes. When the icon turns up the first
        // click has been overtaken, and posts nothing.
        let rig = await Rig.started()
        rig.locator.appear(rig.location(of: hiddenItem, tiedBy: .tieAndNewSlots), afterCalls: 4)
        let driver = rig.driver, clock = rig.clock
        let firstDone = Switch(false)
        let first = Task {
            let outcome = await driver.click(IconClickRequest(item: hiddenItem, kind: .right, display: nil, origin: .commandBar))
            firstDone.set(true)
            return outcome
        }
        // Its look is under way: the bar was still, and the icon hasn't been found.
        let sessionClock = rig.world.clock, locator = rig.locator
        let looking = await withinTimeLimit(.seconds(10)) {
            while locator.calls(of: hiddenItem).count < 2, !Task.isCancelled {
                if await clock.waitForSleepers(1, within: .milliseconds(5)) {
                    clock.advance(by: .milliseconds(50))
                    sessionClock.advance(by: .milliseconds(50))
                }
            }
            return true
        }
        #expect(looking == true)
        #expect(await clock.waitForSleepers(1, within: .seconds(5)))

        // The second click is for another icon, which is drawn at once.
        rig.locator.place(rig.location(of: shownItem, tiedBy: .tie, in: neighbour, wasInBaseline: true))
        let second = await rig.click(shownItem, .left)
        #expect(second == .clicked(.pressedDrawn))

        // Time passes: the hidden item would be found where the first click looks for it by now. It posts nothing.
        #expect(await rig.pump(until: firstDone) == true)
        let outcome = await first.value
        #expect(outcome == .overtaken)
        #expect(rig.poster.clicks.isEmpty, "nothing was posted: the icon was found after the click was overtaken")
        #expect(rig.locator.calls(of: hiddenItem).count <= 5, "and it was looked for no more")
    }

    @Test func newerClickEndsEarlierRevealAtOnce() async throws {
        let rig = await Rig.started()
        rig.locator.place(rig.location(of: hiddenItem, tiedBy: .tieAndNewSlots))
        rig.presser.onPress { [windows = rig.windows, menu = rig.menu()] _ in windows.set([menu]) }
        #expect(await rig.click(hiddenItem) == .clicked(.pressedDrawn))
        #expect(await rig.tickets == 1)
        #expect(!rig.concealed.contains(weather))

        // Another click, with the first's menu still open and its delay not begun: the first icon is put away at once.
        rig.windows.set([])
        rig.locator.place(rig.location(of: shownItem, tiedBy: .tie, in: neighbour, wasInBaseline: true))
        let session = rig.world.session
        let observed = Mutex<Int?>(nil)
        let outcome = await rig.click(shownItem) { observed.withLock { $0 = nil }; let count = await session.iconTickets.count; observed.withLock { $0 = count } }

        #expect(outcome == .clicked(.pressedDrawn))
        #expect(observed.withLock { $0 } == 1, "when the second click's reveal was applied, the first's was already gone")
        #expect(await rig.waitFor { rig.concealed.contains(weather) })
    }

    @Test func pressRefusedEndsRevealAtOnce() async throws {
        let rig = await Rig.started()
        rig.locator.place(rig.location(of: hiddenItem, tiedBy: .tieAndNewSlots))
        rig.presser.failPress(with: .refused("it said no"))

        let outcome = await rig.click(hiddenItem)

        #expect(outcome == .failed(.refused("it said no")))
        #expect(await rig.waitFor { await rig.tickets == 0 }, "no delay: nothing was sent")
        #expect(await rig.waitFor { rig.concealed.contains(weather) })
        // An item that isn't in its app's list any more can't be reached.
        rig.presser.failPress(with: .notFound)
        #expect(await rig.click(hiddenItem) == .failed(.unreachable))
        #expect(await rig.tickets == 0)
    }
}

/// The bar has to be still and drawn before the click looks at it, and nothing is posted while it moves.
@Suite("Icon click driver: the bar and the click", .timeLimit(.minutes(2)))
struct IconClickDriverBarTests {
    // MARK: Waiting for the bar

    @Test func aClickRightAfterARevealNeverPostsOnAFrameThatMayBeLeftBehind() async throws {
        // A reveal has just been applied, so the weather app is on its way to the bar, and a frame it left behind may lie in another icon's
        // slot. The locator says "tie" (the frame is in a slot, and nobody else claims it): the bar isn't drawn yet, so nothing is posted.
        let rig = await Rig.started()
        _ = await rig.world.session.applyReveal(.hiddenShown)
        rig.locator.place(rig.location(of: hiddenItem, tiedBy: .tie, wasInBaseline: true))

        // The session's clock stands still: what the reveal applied is never drawn, and the bar is never looked at.
        let outcome = await rig.click(hiddenItem, .right, sessionMoves: false)

        #expect(outcome == .failed(.unreachable))
        #expect(rig.poster.clicks.isEmpty)
        #expect(rig.locator.calls.isEmpty, "the bar wasn't looked at while it wasn't still")
        #expect(await rig.tickets == 0)

        // Once what was applied is drawn, the tie is the icon's.
        #expect(await rig.click(hiddenItem, .right) == .clicked(.postedDrawn))
        #expect(rig.poster.clicks.count == 1)
    }

    @Test func aSecondClickLooksAtTheBarOnlyOnceTheFirstsPlanIsDrawn() async throws {
        // The first click's menu is open when the second comes: ending the first's reveal conceals its app, which takes the app's slots off the
        // bar up to a drawn-wait later, and a snapshot taken at once would lose them during the second's look.
        let rig = await Rig.started()
        let session = rig.world.session
        let seen = Mutex<[ApplyProgress]>([])
        rig.locator.onSnapshot {
            let progress = await session.applyProgress
            seen.withLock { $0.append(progress) }
        }
        rig.locator.place(rig.location(of: hiddenItem, tiedBy: .tieAndNewSlots))
        rig.poster.onClick { [windows = rig.windows, menu = rig.menu()] _, _ in windows.set([menu]) }
        #expect(await rig.click(hiddenItem, .right) == .clicked(.postedDrawn))
        #expect(await rig.tickets == 1, "the first's menu is open")

        rig.locator.place(rig.location(of: shownItem, tiedBy: .tie, in: neighbour, wasInBaseline: true))
        #expect(await rig.click(shownItem, .right) == .clicked(.postedDrawn))

        let progress = try #require(seen.withLock { $0.last })
        #expect(!progress.underway)
        #expect(try #require(progress.since) >= ClickRouteRules.measured.drawnWait, "the first's plan had been drawn: \(progress)")
        #expect(rig.poster.clicks.last == .init(kind: .right, point: CGPoint(x: neighbour.midX, y: neighbour.midY)), "at its own slot")
    }

    @Test func anAppTheLastPlanJustShowedIsWaitedOnForLongerThanADrawnWait() async throws {
        // A reveal has been applied and drawn (452 ms), but an app that came back is the slowest to be drawn, and what it left behind lies in
        // a slot, on a display that isn't the active one too, until it is: its frame is tied to a nameless slot there. Nothing is posted
        // until the longer wait (1.5 s since the plan was applied) has passed.
        let rig = await Rig.started(shape: .deskWithLaptopOpen)
        let session = rig.world.session, sessionClock = rig.world.clock
        let active = try #require(await session.activeDisplay)
        let other = try #require(rig.world.world.layout.displays.map(\.uuid).first { $0 != active })
        rig.locator.place(FakeItemLocator.location(of: hiddenItem, slot: slot, display: other, tiedBy: .tie, wasInBaseline: true))
        _ = await session.applyReveal(.hiddenShown)

        // The clock stands still 500 ms after the reveal was applied, then 1450.
        sessionClock.advance(by: .milliseconds(500))
        #expect(await rig.click(hiddenItem, .right, display: other, sessionMoves: false) == .failed(.unreachable))
        sessionClock.advance(by: .milliseconds(950))
        #expect(await rig.click(hiddenItem, .right, display: other, sessionMoves: false) == .failed(.unreachable))
        #expect(rig.poster.clicks.isEmpty)
        #expect(rig.locator.calls.isEmpty, "the bar wasn't looked at before it was still")

        // 1.5 s have passed.
        sessionClock.advance(by: .milliseconds(100))
        #expect(await rig.click(hiddenItem, .right, display: other, sessionMoves: false) == .clicked(.postedDrawn))
        #expect(rig.poster.clicks == [.init(kind: .right, point: CGPoint(x: slot.midX, y: slot.midY))])
    }

    // MARK: Room

    @Test func aLookAfterARoundOfRoomWaitsUntilTheRoomHasBeenDrawn() async throws {
        // The icon has no room, and the sync app is concealed for it. For as long as that plan is being drawn the bar is as it was, and the
        // locator finds the icon in the neighbour's slot (the sync app's own, on its way off); once it is drawn it is in its own. The look
        // comes after the plan is drawn, so the click lands at the icon's.
        let started = await Rig.started(shape: .laptop, capacity: 4)
        let locator = DrawingLocator(session: started.world.session, world: started.world.world, display: started.display)
        let rig = Rig.make(started.world, shape: .laptop, locator: locator)

        let outcome = await rig.click(hiddenItem, .right)

        #expect(outcome == .clicked(.madeRoomThenPosted), "\(outcome)")
        #expect(rig.poster.clicks == [.init(kind: .right, point: CGPoint(x: slot.midX, y: slot.midY))], "at the icon's slot, not the neighbour's")
    }

    @Test func aRoundOfRoomThatTheBarDoesNotSettleFromIsUnreachable() async throws {
        let started = await Rig.started(shape: .laptop, capacity: 4)
        let locator = DrawingLocator(session: started.world.session, world: started.world.world, display: started.display)
        let rig = Rig.make(started.world, shape: .laptop, locator: locator)
        let driver = rig.driver, clock = rig.clock, sessionClock = rig.world.clock, world = rig.world.world
        let done = Switch(false)
        let task = Task {
            let outcome = await driver.click(IconClickRequest(item: hiddenItem, kind: .right, display: nil, origin: .commandBar))
            done.set(true)
            return outcome
        }

        // The session's clock stands still once the sync app has been concealed: the room's plan is never drawn.
        let finished = await withinTimeLimit(.seconds(10)) {
            while !done.isOn, !Task.isCancelled {
                if await clock.waitForSleepers(1, within: .milliseconds(5)) {
                    clock.advance(by: .milliseconds(50))
                    if !world.concealed.contains(sync) { sessionClock.advance(by: .milliseconds(50)) }
                }
            }
            return true
        }

        #expect(finished == true)
        let outcome = await task.value
        #expect(outcome == .failed(.unreachable), "\(outcome)")
        #expect(rig.poster.clicks.isEmpty)
    }

    // MARK: A bar that moves

    @Test func aBarThatChangedSinceTheLookIsLookedAtAgainBeforeAnythingIsPosted() async throws {
        let rig = await Rig.started()
        let session = rig.world.session
        rig.locator.place(rig.location(of: shownItem, tiedBy: .tie, in: neighbour, wasInBaseline: true))
        // The bar changes during the first look (the call after the snapshot's own).
        rig.locator.onLocate { item, number in
            if item == shownItem, number == 2 { _ = await session.applyReveal(.hiddenShown) }
        }

        #expect(await rig.click(shownItem, .right) == .clicked(.postedDrawn))

        #expect(rig.locator.calls(of: shownItem).count == 3, "the snapshot's look, the one the bar changed during, and the one after")
        #expect(rig.poster.clicks.count == 1)
    }

    @Test func aPlanThatCameBeforeTheIconWasFoundDrawnIsLookedAtAgainToo() async throws {
        // The icon wasn't drawn at the snapshot. A plan is applied during the first look (an app launching into Hidden, say), and the icon is
        // found a look or two later: the plan's redraw is under way, so the bar is looked at once more after it has settled, and only
        // then is anything posted.
        let rig = await Rig.started()
        let session = rig.world.session
        let location = rig.location(of: hiddenItem, tiedBy: .tieAndNewSlots)
        rig.locator.answer(for: hiddenItem) { number in number >= 3 ? location : nil }
        rig.locator.onLocate { item, number in
            if item == hiddenItem, number == 1 { _ = await session.applyReveal(.hiddenShown) }
        }

        #expect(await rig.click(hiddenItem, .right) == .clicked(.postedDrawn))

        #expect(rig.locator.calls(of: hiddenItem).count == 4, "the look that found it, and one more after the bar was still")
        #expect(rig.poster.clicks == [.init(kind: .right, point: CGPoint(x: slot.midX, y: slot.midY))])
    }

    // MARK: Without a bar to look at

    @Test func withoutASnapshotARightClickIsUnreachableBeforeAnythingIsRevealed() async throws {
        // No grant, or no MenuBarAgent: no display gives a snapshot, so nothing could be posted. The icon isn't revealed, the panel isn't
        // closed and nothing is waited for.
        let rig = await Rig.started()
        rig.locator.setSnapshot(nil)
        let applies = rig.world.events.all.filter { $0 == "apply" }.count
        let closed = Switch(false)

        let outcome = await rig.click(hiddenItem, .right) { closed.set(true) }

        #expect(outcome == .failed(.unreachable))
        #expect(!closed.isOn, "beforeClick wasn't called")
        #expect(rig.world.events.all.filter { $0 == "apply" }.count == applies, "nothing was revealed")
        #expect(rig.poster.clicks.isEmpty)

        // A left click presses where the icon is, as before.
        #expect(await rig.click(hiddenItem, .left) == .clicked(.pressedInPlace))
    }

    // MARK: Pressing

    /// The quit begins during the first look at the bar: nothing is posted. A left click that is ruled to be posted is pressed in place instead.
    @Test(arguments: [(ClickKind.right, false), (.left, true)]) func nothingIsPostedOnceTheQuitHasBegun(kind: ClickKind, postsLeft: Bool) async throws {
        var rules = ClickRouteRules.measured
        if postsLeft { rules.leftClick = .post }
        let rig = await Rig.started(rules: rules)
        let session = rig.world.session
        rig.locator.place(rig.location(of: shownItem, tiedBy: .tie, in: neighbour, wasInBaseline: true))
        rig.locator.onLocate { item, number in
            if item == shownItem, number == 2 { await session.tearDownForQuit() }
        }

        #expect(await rig.click(shownItem, kind) == (kind == .right ? .failed(.unreachable) : .clicked(.pressedInPlace)))
        #expect(rig.poster.clicks.isEmpty)
        #expect(rig.presser.pressed == (kind == .right ? [] : [shownItem]))
    }

    @Test func aClickThatFailedCapturesNothing() async throws {
        let rig = await Rig.started()
        rig.locator.place(rig.location(of: hiddenItem, tiedBy: .tieAndNewSlots))
        rig.poster.fail(with: .notTrusted)

        #expect(await rig.click(hiddenItem, .right) == .failed(.refused(ClickPostError.notTrusted.localizedDescription)))
        await rig.pass(.seconds(1))

        #expect(rig.passed.all.isEmpty, "a picture is taken for a click that was sent")
    }

    // MARK: The caller and the watch

    @Test func aCallerThatIsCancelledSendsNothingAndTheRevealEnds() async throws {
        let rig = await Rig.started()
        rig.locator.place(rig.location(of: hiddenItem, tiedBy: .tieAndNewSlots))
        let driver = rig.driver
        let box = Mutex<Task<IconClickOutcome, Never>?>(nil)
        let done = Switch(false)
        let task = Task {
            let outcome = await driver.click(IconClickRequest(item: hiddenItem, kind: .right, display: nil, origin: .commandBar)) {
                // The panel closes here, and the view's task goes with it.
                box.withLock { $0 }?.cancel()
            }
            done.set(true)
            return outcome
        }
        box.withLock { $0 = task }

        #expect(await rig.pump(until: done) == true)

        #expect(await task.value == .overtaken)
        #expect(rig.poster.clicks.isEmpty)
        #expect(rig.presser.pressed.isEmpty)
        #expect(await rig.tickets == 0)
    }

    @Test func aMenuThatIsNeverSeenToCloseHoldsTheRevealForTenMinutesAtMost() async throws {
        let rig = await Rig.started()
        rig.locator.place(rig.location(of: hiddenItem, tiedBy: .tieAndNewSlots))
        rig.presser.onPress { [windows = rig.windows, menu = rig.menu()] _ in windows.set([menu]) }
        #expect(await rig.click(hiddenItem) == .clicked(.pressedDrawn))
        let started = rig.clock.now()

        #expect(await rig.advance(by: .seconds(10), until: { await rig.tickets == 0 }), "it ends though the menu never closes")

        #expect(rig.clock.now().timeIntervalSince(started) >= 600)
        #expect(await rig.waitFor { rig.concealed.contains(weather) })
    }

    @Test func aSlotThatCantBeToldToBeTheItemsDoesNotMakeRoom() async throws {
        // On a bar where room could be made, an icon found in a drawn slot that isn't known to be its (a frame its app left behind) is
        // refused, and no Shown app is concealed for it: room is not what it lacks.
        let rig = await Rig.started(shape: .laptop, capacity: 4)
        rig.locator.place(rig.location(of: hiddenItem, tiedBy: .tie, wasInBaseline: true))
        let concealed = Mutex<[Set<String>]>([])
        let world = rig.world.world
        rig.locator.answer(for: hiddenItem) { [location = rig.location(of: hiddenItem, tiedBy: .tie, wasInBaseline: true)] _ in
            concealed.withLock { $0.append(world.concealed) }
            return location
        }

        #expect(await rig.click(hiddenItem, .right) == .failed(.unreachable))

        #expect(concealed.withLock { $0 }.allSatisfy { !$0.contains(sync) && !$0.contains(vpn) }, "no room was made")
        #expect(rig.poster.clicks.isEmpty)
    }

    // MARK: Room goes back with the menu

    @Test func theRoomMadeForAClickGoesBackWhenItsMenuClosesAndTheIconStaysForTheDelay() async throws {
        let rig = await Rig.started(shape: .laptop, capacity: 4)
        let world = rig.world.world
        let location = rig.location(of: hiddenItem, tiedBy: .tieAndNewSlots)
        // The icon is drawn once the sync app has been concealed for it.
        rig.locator.answer(for: hiddenItem) { _ in world.concealed.contains(sync) ? location : nil }
        rig.poster.onClick { [windows = rig.windows, menu = rig.menu()] _, _ in windows.set([menu]) }

        let outcome = await rig.click(hiddenItem, .right)
        #expect(outcome == .clicked(.madeRoomThenPosted), "\(outcome)")
        #expect(rig.concealed.contains(sync))

        rig.windows.set([])
        await rig.pass(.seconds(1))
        #expect(await rig.waitFor { !rig.concealed.contains(sync) }, "the room went back with the menu: \(rig.concealed)")
        #expect(await rig.tickets == 1, "the icon stays for the rehide delay")
        #expect(!rig.concealed.contains(weather))
        #expect(await rig.advance(until: { await rig.tickets == 0 }))
        #expect(await rig.waitFor { rig.concealed == [weather] })
    }

    // MARK: The real locator

    @Test func aRoundOfRoomForAnAppWithNamelessSlotsPostsAtItsOwnSlot() async throws {
        // The laptop's bar has room for four icons, and the weather app's two (Hidden) are piled when it is revealed. Every slot is nameless
        // (as on macOS 27), so a slot that appeared can only be told by its width and order, and the sync app that is concealed for room
        // takes its slot off the bar since the snapshot: the locator is told which app it was and which slot that had at the snapshot.
        var settings = HidingSettings()
        settings.automaticOverflow = false
        let world = SessionRig.withAllowlist(shape: .laptop, capacity: nil, undrawn: true,
                                             sections: sections(shown: [notes, vpn, sync], hidden: [weather]), settings: settings)
        // The first read has every icon drawn (the sessions' scans learn nothing here, the locator's own scanner does); then the bar has room
        // for four.
        await world.session.start()
        world.world.setCapacity(4)
        let bar = RoomBar()
        let locator = await bar.learned(following: world.world)
        let rig = Rig.make(world, shape: .laptop, locator: locator)
        let temp = ItemID(bundleID: weather, key: .identifier("weather.temp"))

        let outcome = await rig.click(temp, .right)

        #expect(outcome == .clicked(.madeRoomThenPosted), "\(outcome)")
        let click = try #require(rig.poster.clicks.first)
        let slots = bar.slots(of: weather)
        #expect(slots.count == 2)
        #expect(click.kind == .right)
        #expect(click.point == CGPoint(x: slots[0].midX, y: slots[0].midY), "at the temperature's slot, the left one: \(click.point) \(slots)")
        #expect(rig.poster.clicks.count == 1)
    }

    @Test func aFlaggedAppsRightClickIsRefusedBeforeAnythingIsRevealed() async throws {
        let world = await IconClickDriverTests.flaggedWorld()
        let rig = Rig.make(world)
        let applies = world.events.all.filter { $0 == "apply" }.count
        let closed = Switch(false)

        let outcome = await rig.click(shownItem, .right) { closed.set(true) }

        #expect(outcome == .failed(.unreachable))
        #expect(!closed.isOn, "the panel wasn't closed for an answer known before")
        #expect(world.events.all.filter { $0 == "apply" }.count == applies, "no plan was applied")
    }
}

/// The laptop's bar as MenuBarAgent draws it, with the slots of the apps nameless and of widths of their own (the notes app's 36, the VPN
/// app's 30, the sync app's 44, the weather app's two 40 each), right-aligned left of Wi-Fi and the clock, four points apart. An app that
/// is concealed has no slot, and the weather app's two are drawn only when they fit left of `limit`. The apps' frames are six points in from
/// their slots, and where macOS parks icons when they aren't drawn.
private final class RoomBar: Sendable {
    private static let apps: [(bundle: String, pid: pid_t, widths: [CGFloat])] = [
        (SessionWorld.weather, 1001, [40, 40]), (SessionWorld.notes, 1002, [36]), (SessionWorld.vpn, 1003, [30]), (SessionWorld.sync, 1004, [44]),
    ]
    private static let agent: pid_t = 50
    private static let parked = CGRect(x: 7, y: 1878, width: 24, height: 24)
    static let layout = DisplayLayout(displays: [DisplayFixtures.laptopAlone])

    let ax: FakeAX
    /// The slot and the item of each app's icons, left to right.
    private let nodes: [String: [(slot: Int, item: Int)]]
    private let hidden: Hidden
    private let drawn = Mutex<[String: [CGRect]]>([:])

    /// The slots macOS isn't drawing.
    private final class Hidden: Sendable {
        private let ids = Mutex<Set<Int>>([])
        func set(_ new: Set<Int>) { ids.withLock { $0 = new } }
        func contains(_ id: Int) -> Bool { ids.withLock { $0.contains(id) } }
    }

    init() {
        let ax = FakeAX()
        let window = ax.addAgentWindow(agent: Self.agent, frame: CGRect(x: 0, y: 0, width: 1728, height: 33))
        ax.addSlot(in: window, identifier: "com.apple.menuextra.clock", description: "Clock", frame: CGRect(x: 1648, y: 0, width: 80, height: 33))
        ax.addSlot(in: window, identifier: "com.apple.menuextra.wifi", description: "Wi-Fi", frame: CGRect(x: 1608, y: 0, width: 36, height: 33))
        var nodes: [String: [(slot: Int, item: Int)]] = [:]
        for app in Self.apps {
            let slots = app.widths.map { _ in ax.addSlot(in: window, identifier: nil, frame: nil) }
            let extras = app.widths.indices.map { index in
                FakeAX.Extra(title: "Icon", identifier: app.bundle == SessionWorld.weather ? ["weather.temp", "weather.alerts"][index] : nil,
                             frame: Self.parked)
            }
            let items = ax.addApp(pid: app.pid, extras: extras)
            nodes[app.bundle] = Array(zip(slots, items)).map { (slot: $0, item: $1) }
        }
        self.ax = ax
        self.nodes = nodes
        let hidden = Hidden()
        self.hidden = hidden
        ax.setOverride { id, name in
            (name == AXName.position || name == AXName.size) && hidden.contains(id) ? .failure(.noValue) : nil
        }
        lay(concealed: [], limit: 0)
    }

    /// The slots an app's icons are drawn in now, left to right.
    func slots(of bundle: String) -> [CGRect] { drawn.withLock { $0[bundle] ?? [] } }

    /// Draws the apps that aren't concealed, right-aligned; the weather app's two only when they fit left of `limit`.
    func lay(concealed: Set<String>, limit: CGFloat) {
        var frames: [String: [CGRect]] = [:]
        var cursor: CGFloat = 1604
        for app in Self.apps.reversed() where !concealed.contains(app.bundle) {
            var placed: [CGRect] = []
            for width in app.widths.reversed() {
                placed.insert(CGRect(x: cursor - width, y: 0, width: width, height: 33), at: 0)
                cursor -= width + 4
            }
            if app.bundle == SessionWorld.weather, (placed.first?.minX ?? 0) < limit { continue }
            frames[app.bundle] = placed
        }
        var hiding: Set<Int> = []
        for app in Self.apps {
            for (index, node) in (nodes[app.bundle] ?? []).enumerated() {
                if let frame = frames[app.bundle]?[index] {
                    for (name, value) in FakeAX.frameAttributes(frame) { ax.setAttribute(name, value, on: node.slot) }
                    for (name, value) in FakeAX.frameAttributes(frame.insetBy(dx: 6, dy: 1)) { ax.setAttribute(name, value, on: node.item) }
                } else {
                    hiding.insert(node.slot)
                    for (name, value) in FakeAX.frameAttributes(Self.parked) { ax.setAttribute(name, value, on: node.item) }
                }
            }
        }
        hidden.set(hiding)
        drawn.withLock { $0 = frames }
    }

    func scanner() -> MenuBarScanner {
        let running: [RunningApp] = [.fake(Self.agent, MenuBarReader.menuBarAgentBundleID, "MenuBarAgent")]
            + Self.apps.map { .fake($0.pid, $0.bundle, $0.bundle) }
        return MenuBarScanner(ax: ax, runningApps: { running }, layout: { Self.layout }, ownBundleID: InventoryFixtures.ownBundleID,
                              isTrusted: { true }, clock: FakeClock(), readLimit: 8)
    }

    /// A locator over this bar that the scans have learned: every icon drawn once (so that the places of the weather app's two are known),
    /// then the weather app concealed, and the bar following what the session's world conceals from then on.
    func learned(following world: SessionWorld) async -> RoomLocator {
        let scanner = scanner()
        lay(concealed: [], limit: 0)
        _ = await scanner.scan(concealed: [])
        lay(concealed: [SessionWorld.weather], limit: 1440)
        _ = await scanner.scan(concealed: [SessionWorld.weather])
        return RoomLocator(bar: self, scanner: scanner, world: world)
    }
}

/// The real scanner as the locator, over a bar that is laid out again as the session's world conceals apps.
private struct RoomLocator: ItemLocating {
    let bar: RoomBar
    let scanner: MenuBarScanner
    let world: SessionWorld

    func slotSnapshot(on display: String?) async -> SlotSnapshot? {
        bar.lay(concealed: world.concealed, limit: 1440)
        return await scanner.slotSnapshot(on: display)
    }

    func locate(_ item: ItemID, on display: String?, since baseline: SlotSnapshot?) async -> ItemLocation? {
        bar.lay(concealed: world.concealed, limit: 1440)
        return await scanner.locate(item, on: display, since: baseline)
    }
}

/// A locator for a round of room, over the session's clock: once the sync app has been concealed for the icon, the icon is in the sync app's
/// slot (a neighbour's) for as long as that plan is being drawn, which is what a look at the bar finds while the app is on its way off it,
/// and in its own slot after. Before the room is made the icon is nowhere.
private struct DrawingLocator: ItemLocating {
    let session: MenuBarSession
    let world: SessionWorld
    let display: String

    func slotSnapshot(on display: String?) async -> SlotSnapshot? {
        SlotSnapshot(displayUUID: self.display, slots: [slot, neighbour], owners: [notes, sync])
    }

    func locate(_ item: ItemID, on display: String?, since baseline: SlotSnapshot?) async -> ItemLocation? {
        guard baseline != nil, world.concealed.contains(sync) else { return nil }
        let progress = await session.applyProgress
        let drawing = progress.underway || (progress.since.map { $0 < ClickRouteRules.measured.drawnWait } ?? true)
        return FakeItemLocator.location(of: item, slot: drawing ? neighbour : slot, display: self.display, tiedBy: .tieAndNewSlots)
    }
}
