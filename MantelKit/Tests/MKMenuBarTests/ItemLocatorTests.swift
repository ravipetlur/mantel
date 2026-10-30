import CoreGraphics
import Foundation
import MKCore
import MKTestSupport
import Synchronization
import Testing

@testable import MKMenuBar

private let agentPID: pid_t = 50
private let weatherPID: pid_t = 1001
private let notesPID: pid_t = 1002
private let weather = "com.example.weather"
private let notes = "com.example.notes"
private let main = DisplayFixtures.deskMain.uuid
private let desk = DisplayLayout(displays: [DisplayFixtures.deskMain])
private let bar = CGRect(x: 0, y: 0, width: 3360, height: 30)

/// Where a concealed app's own frames are while macOS isn't drawing its icons: the left edge of the display, a dozen points above its
/// bottom edge.
private let parked = CGRect(x: 7, y: 1878, width: 24, height: 24)

/// The slots macOS isn't drawing: a slot that is concealed has no frame, which the fake tree says by failing the reads of its place.
private final class Hidden: Sendable {
    private let ids = Mutex<Set<Int>>([])

    func set(_ slots: [Int]) { ids.withLock { $0 = Set(slots) } }
    func contains(_ id: Int) -> Bool { ids.withLock { $0.contains(id) } }
}

/// The process the weather app runs as: another one after it is started again.
private final class WeatherProcess: Sendable {
    private let pid = Mutex<pid_t>(weatherPID)

    var current: pid_t { pid.withLock { $0 } }
    func set(_ new: pid_t) { pid.withLock { $0 = new } }
}

/// One display's menu bar drawn by a fake MenuBarAgent, right-aligned, with the clock and Wi-Fi and the notes app's icon on it, and two
/// apps that list their items: the weather app, with two items (or one), and the notes app, with one.
private struct World {
    let ax: FakeAX
    let window: Int
    /// The weather app's first item (`weather.temp`), and its second (`weather.alerts`; 0 when the app has one).
    let temp: Int
    let alerts: Int
    let notesItem: Int
    /// The notes app's slot in the bar (its node in the fake tree).
    let notesSlotElement: Int
    let hidden = Hidden()
    private let process = WeatherProcess()

    static let clockSlot = CGRect(x: 3268, y: 0, width: 80, height: 30)
    static let wifiSlot = CGRect(x: 3226, y: 0, width: 36, height: 30)
    static let notesSlot = CGRect(x: 3140, y: 0, width: 36, height: 30)
    /// Where the weather app's icons are when they are drawn at the left of the notes app's: two slots of 40, four points apart.
    static let firstNew = CGRect(x: 3052, y: 0, width: 40, height: 30)
    static let secondNew = CGRect(x: 3096, y: 0, width: 40, height: 30)

    /// The weather app's items report these frames; by default they are concealed. The app lists its items left to right, or (`rightToLeft`)
    /// the other way round, as some apps do; and gives them names (`weather.temp`, `weather.alerts`), or (`unnamed`) none. The notes app's
    /// slot carries its app's name, or (`notesNamed` false) none, as the slots of apps on macOS 27 don't.
    init(tempFrame: CGRect? = parked, alertsFrame: CGRect? = parked, items: Int = 2, rightToLeft: Bool = false, unnamed: Bool = false,
         notesNamed: Bool = true) {
        ax = FakeAX()
        window = ax.addAgentWindow(agent: agentPID, frame: bar)
        ax.addSlot(in: window, identifier: "com.apple.menuextra.clock", description: "Clock", frame: Self.clockSlot)
        ax.addSlot(in: window, identifier: "com.apple.menuextra.wifi", description: "Wi-Fi", frame: Self.wifiSlot)
        notesSlotElement = ax.addSlot(in: window, identifier: notesNamed ? "notes.main" : nil, frame: Self.notesSlot)
        var extras: [FakeAX.Extra] = [.init(title: "Weather", identifier: unnamed ? nil : "weather.temp", frame: tempFrame)]
        if items == 2 { extras.append(.init(title: "Alerts", identifier: unnamed ? nil : "weather.alerts", frame: alertsFrame)) }
        if rightToLeft { extras.reverse() }
        let weatherItems = ax.addApp(pid: weatherPID, extras: extras)
        if items == 2 {
            temp = weatherItems[rightToLeft ? 1 : 0]
            alerts = weatherItems[rightToLeft ? 0 : 1]
        } else {
            temp = weatherItems[0]
            alerts = 0
        }
        notesItem = ax.addApp(pid: notesPID, extras: [.init(title: "Notes", identifier: "notes.main", frame: Self.notesSlot.insetBy(dx: 6, dy: 1))])[0]
        let hidden = hidden
        ax.setOverride { id, name in
            (name == AXName.position || name == AXName.size) && hidden.contains(id) ? .failure(.noValue) : nil
        }
    }

    /// A slot appears in the window.
    @discardableResult
    func addSlot(_ frame: CGRect, identifier: String? = nil) -> Int {
        ax.addSlot(in: window, identifier: identifier, frame: frame)
    }

    /// Where the weather app's items say they are now.
    func move(_ item: Int, to frame: CGRect?) {
        if let frame {
            for (name, value) in FakeAX.frameAttributes(frame) { ax.setAttribute(name, value, on: item) }
        }
    }

    var running: [RunningApp] {
        [.fake(agentPID, MenuBarReader.menuBarAgentBundleID, "MenuBarAgent"), .fake(process.current, weather, "Weather"), .fake(notesPID, notes, "Notes")]
    }

    func scanner(trusted: Bool = true) -> MenuBarScanner {
        let process = process
        return MenuBarScanner(ax: ax, runningApps: {
            [.fake(agentPID, MenuBarReader.menuBarAgentBundleID, "MenuBarAgent"), .fake(process.current, weather, "Weather"),
             .fake(notesPID, notes, "Notes")]
        }, layout: { desk }, ownBundleID: InventoryFixtures.ownBundleID, isTrusted: { trusted }, clock: FakeClock(), readLimit: 8)
    }

    /// The weather app is started again as another process, with the same two items (their frames are where macOS parks icons).
    func relaunchWeather(as pid: pid_t) {
        ax.addApp(pid: pid, extras: [.init(title: "Weather", identifier: "weather.temp", frame: parked), .init(title: "Alerts", identifier: "weather.alerts", frame: parked)])
        process.set(pid)
    }
}

/// A reveal, in the moments that matter to the locator: the weather app drawn (its slots in the bar, its items in them) and scanned, which is
/// when the scanner learns where each of its items is among them; then concealed, which is when the snapshot is taken (the slots have no
/// frame, and its items say they are where macOS parks icons); and then drawn again, with its items still saying so (`show`).
private struct Reveal {
    let world: World
    let scanner: MenuBarScanner
    let before: SlotSnapshot
    /// The weather app's slots, left to right.
    let slots: [Int]
    /// The weather app's items whose app reports no frame for them.
    let withoutFrames: [Int]

    /// The weather app's slots are drawn again, all of them or these. Its items still say where macOS parks icons.
    func show(_ shown: [Int]? = nil) {
        let showing = shown ?? slots
        world.hidden.set(slots.filter { !showing.contains($0) } + withoutFrames)
    }

    /// - Parameters:
    ///   - frames: the weather app's slots, left to right: the first for `temp`, the second for `alerts`.
    ///   - identifiers: the names those slots carry (none by default, as on macOS 27).
    ///   - beforeSnapshot: what else is in the bar when the snapshot is taken.
    ///   - parkedWidth: how wide the frame is that the weather app's items report while they are concealed (an icon's frame is a little wider
    ///     than its slot: 42 for a slot of 40), or nil for no frame at all.
    ///   - concealed: the apps the plan conceals, as the scanner is told when it learns (the weather app's, in the probe's real state).
    static func make(_ world: World = World(), frames: [CGRect] = [World.firstNew, World.secondNew], identifiers: [String?] = [],
                     learning: Bool = true, concealed: Set<String> = [], parkedWidth: CGFloat? = 42,
                     beforeSnapshot: (World) -> Void = { _ in }) async throws -> Reveal {
        let slots = frames.enumerated().map { world.addSlot($1, identifier: identifiers.indices.contains($0) ? identifiers[$0] : nil) }
        world.move(world.temp, to: frames[0].insetBy(dx: 6, dy: 1))
        if frames.count > 1, world.alerts != 0 { world.move(world.alerts, to: frames[1].insetBy(dx: 6, dy: 1)) }
        let scanner = world.scanner()
        if learning { _ = await scanner.scan(concealed: concealed) }
        let items = [world.temp] + (world.alerts != 0 ? [world.alerts] : [])
        let parkedFrame = CGRect(x: 7, y: 1878, width: parkedWidth ?? 24, height: 24)
        for item in items { world.move(item, to: parkedFrame) }
        let withoutFrames = parkedWidth == nil ? items : []
        world.hidden.set(slots + withoutFrames)
        beforeSnapshot(world)
        let before = try #require(await scanner.slotSnapshot(on: nil))
        world.hidden.set(withoutFrames)
        return Reveal(world: world, scanner: scanner, before: before, slots: slots, withoutFrames: withoutFrames)
    }
}

private let temp = ItemID(bundleID: weather, key: .identifier("weather.temp"))
private let alerts = ItemID(bundleID: weather, key: .identifier("weather.alerts"))

/// Where an item is now: the slot its app says, or the slot that appeared for it.
@Suite("Item locator", .timeLimit(.minutes(1)))
struct ItemLocatorTests {
    // MARK: The tie

    @Test func tiedItemIsLocated() async throws {
        let world = World(tempFrame: World.firstNew.insetBy(dx: 6, dy: 1))
        world.addSlot(World.firstNew, identifier: "weather.temp")

        let location = try #require(await world.scanner().locate(temp, on: nil, since: nil))

        #expect(location == ItemLocation(item: temp, displayUUID: main, slotFrame: World.firstNew, tiedBy: .tie, slotWasInBaseline: false,
                                         widthAgrees: true, frameMinusSlotWidth: -12), "its frame is narrower than the slot, as macOS 27's are")
    }

    @Test func theDisplayCanBeNamed() async throws {
        let world = World(tempFrame: World.firstNew.insetBy(dx: 6, dy: 1))
        world.addSlot(World.firstNew)
        let scanner = world.scanner()

        #expect(await scanner.locate(temp, on: main, since: nil)?.slotFrame == World.firstNew)
        #expect(await scanner.locate(temp, on: "no-such-display", since: nil) == nil)
    }

    @Test func appFrameWiderBySixPointsStillTies() async throws {
        // An icon's own frame is two to five points wider than its slot on a real bar; six is the most that still is its.
        let slot = World.firstNew
        let six = CGRect(x: slot.midX - 23, y: 1, width: slot.width + 6, height: 28)
        let world = World(tempFrame: six)
        world.addSlot(slot)
        #expect(await world.scanner().locate(temp, on: nil, since: nil)?.slotFrame == slot)

        let seven = CGRect(x: slot.midX - 23.5, y: 1, width: slot.width + 7, height: 28)
        let tooWide = World(tempFrame: seven)
        tooWide.addSlot(slot)
        #expect(await tooWide.scanner().locate(temp, on: nil, since: nil) == nil, "a frame wider than that is not the slot's")
    }

    @Test func systemSlotNeverGoesToAnApp() async throws {
        // An app whose frame lies in the Wi-Fi slot is not the Wi-Fi item: no app's frame is a system slot.
        let world = World(tempFrame: World.wifiSlot.insetBy(dx: 4, dy: 1))
        let scanner = world.scanner()

        #expect(await scanner.locate(temp, on: nil, since: nil) == nil)
        #expect(await scanner.locate(.system("wifi"), on: nil, since: nil)?.slotFrame == World.wifiSlot, "the slot is the system's")
        #expect(await scanner.locate(.system("wifi"), on: nil, since: nil)?.tiedBy == .tie)
    }

    @Test func unnamedItemsAreToldByPlace() async throws {
        // Two items that name themselves nothing are told apart as the inventory tells them: by where they are, left to right.
        let ax = FakeAX()
        let window = ax.addAgentWindow(agent: agentPID, frame: bar)
        let right = CGRect(x: 3100, y: 0, width: 36, height: 30), left = CGRect(x: 3056, y: 0, width: 36, height: 30)
        ax.addSlot(in: window, frame: right)
        ax.addSlot(in: window, frame: left)
        // The app lists its items right to left.
        ax.addApp(pid: weatherPID, extras: [.init(title: "B", frame: right.insetBy(dx: 6, dy: 1)), .init(title: "A", frame: left.insetBy(dx: 6, dy: 1))])
        let running: [RunningApp] = [.fake(agentPID, MenuBarReader.menuBarAgentBundleID), .fake(weatherPID, weather)]
        let scanner = MenuBarScanner(ax: ax, runningApps: { running }, layout: { desk }, ownBundleID: InventoryFixtures.ownBundleID,
                                     isTrusted: { true }, clock: FakeClock(), readLimit: 8)
        // As the scans name them: an item with no name is what they saw it be.
        let scanned = await scanner.scan()
        #expect(scanned.items(ofApp: weather).map(\.id.string) == ["\(weather)#0", "\(weather)#1"])

        #expect(await scanner.locate(ItemID(bundleID: weather, key: .index(0)), on: nil, since: nil)?.slotFrame == left)
        #expect(await scanner.locate(ItemID(bundleID: weather, key: .index(1)), on: nil, since: nil)?.slotFrame == right)
        #expect(await scanner.locate(ItemID(bundleID: weather, key: .index(2)), on: nil, since: nil) == nil)
    }

    @Test func anAppThatIsNotRunningIsNotLocated() async throws {
        let world = World(tempFrame: World.firstNew.insetBy(dx: 6, dy: 1))
        world.addSlot(World.firstNew)
        let ghost = ItemID(bundleID: "com.example.ghost", key: .identifier("ghost.main"))
        #expect(await world.scanner().locate(ghost, on: nil, since: nil) == nil)
    }

    @Test func withoutAccessibilityNothingIsLocated() async throws {
        let world = World(tempFrame: World.firstNew.insetBy(dx: 6, dy: 1))
        world.addSlot(World.firstNew)
        let scanner = world.scanner(trusted: false)
        #expect(await scanner.locate(temp, on: nil, since: nil) == nil)
        #expect(await scanner.slotSnapshot(on: nil) == nil)
    }

    // MARK: Slots that appeared

    /// The slots before the weather app is shown: the clock, Wi-Fi and the notes app's.
    private func baseline(of world: World) async -> SlotSnapshot? {
        await world.scanner().slotSnapshot(on: nil)
    }

    @Test func slotSnapshotListsTheDrawnSlotsByX() async throws {
        let world = World()
        let extra = CGRect(x: 3000, y: 0, width: 36, height: 30)
        world.addSlot(extra)
        world.addSlot(CGRect(x: 100, y: 1848, width: 36, height: 30), identifier: "com.apple.menuextra.battery")  // parked off the bar
        world.ax.addSlot(in: world.window, role: "AXButton", subrole: nil, description: "chevron", frame: CGRect(x: 2900, y: 0, width: 18, height: 30))
        world.ax.addSlot(in: world.window)  // no frame: macOS isn't drawing it

        let snapshot = try #require(await baseline(of: world))

        #expect(snapshot.displayUUID == main)
        let expected: [CGRect] = [extra, World.notesSlot, World.wifiSlot, World.clockSlot]
        #expect(snapshot.slots == expected, "the slots that are on the bar, by x; not the «, the one macOS parked, or the one with no frame")
    }

    @Test func newSlotsFallbackPicksIndex() async throws {
        let reveal = try await Reveal.make()
        let scanner = reveal.scanner

        // Both of the weather app's items are concealed (their own frames are where macOS parks them), and two slots appeared: the item's
        // place among its app's items is the new slot's place by x.
        let first = try #require(await scanner.locate(temp, on: nil, since: reveal.before))
        let second = try #require(await scanner.locate(alerts, on: nil, since: reveal.before))
        #expect(first == ItemLocation(item: temp, displayUUID: main, slotFrame: World.firstNew, tiedBy: .newSlots, slotWasInBaseline: false,
                                      widthAgrees: true, frameMinusSlotWidth: 2))
        #expect(second == ItemLocation(item: alerts, displayUUID: main, slotFrame: World.secondNew, tiedBy: .newSlots, slotWasInBaseline: false,
                                       widthAgrees: true, frameMinusSlotWidth: 2))
        #expect(!first.isPostable(drawnAtSnapshot: false) && !second.isPostable(drawnAtSnapshot: false),
                "the slot that appeared and the width agree, and a concealed item still needs its app to say the slot too")
        #expect(await scanner.locate(temp, on: nil, since: nil) == nil, "without a snapshot there is nothing to tell the new slots from")
    }

    @Test func newSlotsFallbackNeverTakesTheAppsListForLeftToRight() async throws {
        // An app that lists its items right to left: the first it lists (`alerts`) is the right-hand one. The place of each is what the scan
        // learned while they were drawn, and the new slot is picked by that: `temp`, the app's second, is the left one.
        let world = World(rightToLeft: true)
        let reveal = try await Reveal.make(world)

        let left = try #require(await reveal.scanner.locate(temp, on: nil, since: reveal.before))
        let right = try #require(await reveal.scanner.locate(alerts, on: nil, since: reveal.before))
        #expect(left.slotFrame == World.firstNew, "never the right-hand slot")
        #expect(right.slotFrame == World.secondNew)
        #expect(left.tiedBy == .newSlots && right.tiedBy == .newSlots)
    }

    @Test func newSlotsFallbackRefusesWhenTheOrderIsNotKnown() async throws {
        // An app with two items whose places among each other were never seen (no scan found them drawn): which new slot is which can't be
        // told, and the answer is none, whichever way the app lists them.
        for rightToLeft in [false, true] {
            let reveal = try await Reveal.make(World(rightToLeft: rightToLeft), learning: false)
            #expect(await reveal.scanner.locate(temp, on: nil, since: reveal.before) == nil, "right to left: \(rightToLeft)")
            #expect(await reveal.scanner.locate(alerts, on: nil, since: reveal.before) == nil, "right to left: \(rightToLeft)")
        }
    }

    @Test func anAppWithOneItemNeedsNoOrder() async throws {
        let reveal = try await Reveal.make(World(items: 1), frames: [World.firstNew], learning: false)

        let found = try #require(await reveal.scanner.locate(temp, on: nil, since: reveal.before))

        #expect(found == ItemLocation(item: temp, displayUUID: main, slotFrame: World.firstNew, tiedBy: .newSlots, slotWasInBaseline: false,
                                      widthAgrees: true, frameMinusSlotWidth: 2))
    }

    @Test func newSlotsFallbackRefusesWhenCountDiffers() async throws {
        let reveal = try await Reveal.make()
        let scanner = reveal.scanner

        reveal.show([reveal.slots[0]])
        #expect(await scanner.locate(temp, on: nil, since: reveal.before) == nil, "one slot appeared for an app that has two items")

        reveal.show()
        #expect(await scanner.locate(temp, on: nil, since: reveal.before)?.slotFrame == World.firstNew, "two did")

        reveal.world.addSlot(CGRect(x: 3008, y: 0, width: 40, height: 30))
        #expect(await scanner.locate(temp, on: nil, since: reveal.before) == nil, "and with a third, something else came as well")
        #expect(await scanner.locate(alerts, on: nil, since: reveal.before) == nil)
    }

    @Test func slotsThatMovedLeftAreNotNew() async throws {
        // The bar is right-aligned: slots that appear push the slots left of them further left. Those aren't new.
        var leftOfThem = 0
        let reveal = try await Reveal.make { leftOfThem = $0.addSlot(CGRect(x: 3100, y: 0, width: 36, height: 30)) }

        // The weather app's two slots (40 wide, 4 apart) come in at the notes app's left, where the slot was; it goes 88 points left.
        reveal.world.ax.setAttribute(AXName.position, .point(CGPoint(x: 3012, y: 0)), on: leftOfThem)

        let first = try #require(await reveal.scanner.locate(temp, on: nil, since: reveal.before))
        let second = try #require(await reveal.scanner.locate(alerts, on: nil, since: reveal.before))
        #expect(first.slotFrame == World.firstNew)
        #expect(second.slotFrame == World.secondNew)
        #expect(first.tiedBy == .newSlots)
    }

    @Test func aNewSlotAsWideAsItsOldNeighbourIsNotGuessed() async throws {
        // Two of the weather app's slots, 36 wide as the notes app's is, appear at its left. Which of the slots there is the new one can't be
        // told by where they are (the one that takes the notes app's place, or the one that went left): the answer is none, not a guess.
        let reveal = try await Reveal.make(World(notesNamed: false),
                                           frames: [CGRect(x: 3056, y: 0, width: 36, height: 30), CGRect(x: 3100, y: 0, width: 36, height: 30)])
        let scanner = reveal.scanner

        #expect(await scanner.locate(temp, on: nil, since: reveal.before) == nil)
        #expect(await scanner.locate(alerts, on: nil, since: reveal.before) == nil)
        // The app's own frames, when they say where its icons are, are still the tie.
        reveal.world.move(reveal.world.temp, to: CGRect(x: 3062, y: 1, width: 24, height: 28))
        let tied = try #require(await scanner.locate(temp, on: nil, since: reveal.before))
        #expect(tied.tiedBy == .tie)
        #expect(tied.slotFrame == CGRect(x: 3056, y: 0, width: 36, height: 30))
    }

    @Test func ambiguousLabellingCountsAsBaseline() async throws {
        // With no telling the new slots from the old ones, a slot may be one that was there: it is taken to be one, whatever the tie says.
        let reveal = try await Reveal.make(World(notesNamed: false),
                                           frames: [CGRect(x: 3056, y: 0, width: 36, height: 30), CGRect(x: 3100, y: 0, width: 36, height: 30)])
        reveal.world.move(reveal.world.temp, to: CGRect(x: 3062, y: 1, width: 24, height: 28))

        let found = try #require(await reveal.scanner.locate(temp, on: nil, since: reveal.before))

        #expect(found.slotFrame == CGRect(x: 3056, y: 0, width: 36, height: 30))
        #expect(found.slotWasInBaseline, "it can't be told to be new")
    }

    @Test func shiftedOldSlotCountsAsBaseline() async throws {
        // One slot of the weather app's two appears, and the slot that was left of it goes left. The app's item says it is in that slot (a
        // frame it left behind, where the slot is now: its frame is no frame of the snapshot's, but the slot was there).
        var leftOfThem = 0
        let reveal = try await Reveal.make { leftOfThem = $0.addSlot(CGRect(x: 3100, y: 0, width: 36, height: 30)) }
        reveal.show([reveal.slots[1]])
        // Left of the notes app's slot there is now the new one (40 wide, 3096 to 3136), and the old one went 44 points left.
        reveal.world.ax.setAttribute(AXName.position, .point(CGPoint(x: 3056, y: 0)), on: leftOfThem)
        reveal.world.move(reveal.world.temp, to: CGRect(x: 3062, y: 1, width: 24, height: 28))

        let found = try #require(await reveal.scanner.locate(temp, on: nil, since: reveal.before))

        #expect(found.slotFrame == CGRect(x: 3056, y: 0, width: 36, height: 30), "the tie is the slot that was moved")
        #expect(found.tiedBy == .tie, "one slot appeared for an app with two items")
        #expect(!reveal.before.slots.contains(found.slotFrame), "by its frame it is no slot of the snapshot's")
        #expect(found.slotWasInBaseline, "but it was one")
    }

    @Test func aNewSlotIsNotInBaseline() async throws {
        let reveal = try await Reveal.make()
        reveal.world.move(reveal.world.temp, to: World.firstNew.insetBy(dx: 6, dy: 1))

        let found = try #require(await reveal.scanner.locate(temp, on: nil, since: reveal.before))

        #expect(found.tiedBy == .tieAndNewSlots)
        #expect(!found.slotWasInBaseline)
    }

    @Test func aNewSlotBesideAnOldOneOfAnotherWidthIsTold() {
        // 40 wide beside 36: the new one is the 40.
        let old = [CGRect(x: 3140, y: 0, width: 36, height: 30)]
        let after = [CGRect(x: 3096, y: 0, width: 36, height: 30), CGRect(x: 3136, y: 0, width: 40, height: 30)]
        #expect(ItemLocator.appearedSlots(since: old, in: after) == [CGRect(x: 3136, y: 0, width: 40, height: 30)], "one new, widths differ")
        // The same width as the old one beside it: the new one takes the old one's place and the old one goes left, or the old one stays and
        // the new one is left of it. Nothing says which.
        #expect(ItemLocator.appearedSlots(since: old, in: [CGRect(x: 3100, y: 0, width: 36, height: 30), CGRect(x: 3140, y: 0, width: 36, height: 30)]) == nil,
                "one new, the same width as its neighbour")
    }

    /// Slots of these widths, right-aligned with 4 points between them, the right-most ending at `end`; by x.
    private func slots(_ widths: [CGFloat], endingAt end: CGFloat = 1000) -> [CGRect] {
        var frames: [CGRect] = []
        var right = end
        for width in widths.reversed() {
            frames.append(CGRect(x: right - width, y: 0, width: width, height: 30))
            right -= width + 4
        }
        return frames.reversed()
    }

    @Test func twoNewSlotsLeftOfAllAreTold() {
        let old = slots([36])
        let after = slots([40, 40, 36])
        #expect(ItemLocator.appearedSlots(since: old, in: after) == [after[0], after[1]])
    }

    @Test func twoNewSlotsInTheMiddleAreTold() {
        // 20 and 36 before; two of 40 between them after: the 20 went left by 88.
        let old = slots([20, 36])
        let after = slots([20, 40, 40, 36])
        #expect(ItemLocator.appearedSlots(since: old, in: after) == [after[1], after[2]])
    }

    @Test func twoNewSlotsBeforeAnotherAppsSlotsAreNotItsShiftedSlot() {
        // Right-aligned widths 20, 30, 40; a two-item app appears between the 30 and the 40 with widths 25 and 30. The 30 that went left is
        // as wide as the new 30, and a match from the right takes the new one for the old one. The new slots are the 25 and the 30 beside
        // the 40, and not the 30 that went left: the two ways of matching say different things, so nothing is said.
        let old = slots([20, 30, 40])
        let after = slots([20, 30, 25, 30, 40])
        #expect(ItemLocator.appearedSlots(since: old, in: after) == nil)
        for slot in ItemLocator.appearedSlots(since: old, in: after) ?? [] {
            #expect(slot != after[1], "never the other app's slot")
        }
    }

    @Test func aSlotThatWentAwayBreaksTheAnswer() {
        // Something else changed between the two looks: the new slots can't be told.
        let old = [CGRect(x: 100, y: 0, width: 30, height: 30), CGRect(x: 140, y: 0, width: 30, height: 30)]
        #expect(ItemLocator.appearedSlots(since: old, in: [CGRect(x: 140, y: 0, width: 30, height: 30)]) == nil)
        #expect(ItemLocator.appearedSlots(since: old, in: old) == [])
        #expect(ItemLocator.appearedSlots(since: [], in: old) == old)
    }

    @Test func aSlotThatMovedRightIsNotTheOldOne() {
        // Slots only move left when others appear: one that is right of where it was is not it.
        let old = [CGRect(x: 100, y: 0, width: 30, height: 30)]
        #expect(ItemLocator.appearedSlots(since: old, in: [CGRect(x: 120, y: 0, width: 30, height: 30)]) == nil)
    }

    @Test func tieAndNewSlotsAgree() async throws {
        let reveal = try await Reveal.make()
        // The app's items now say where they are, and it is where the slots appeared.
        reveal.world.move(reveal.world.temp, to: World.firstNew.insetBy(dx: 6, dy: 1))
        reveal.world.move(reveal.world.alerts, to: World.secondNew.insetBy(dx: 6, dy: 1))

        let first = try #require(await reveal.scanner.locate(temp, on: nil, since: reveal.before))
        #expect(first.tiedBy == .tieAndNewSlots)
        #expect(first.slotFrame == World.firstNew)
        #expect(first.slotWasInBaseline == false)
        #expect(await reveal.scanner.locate(alerts, on: nil, since: reveal.before)?.tiedBy == .tieAndNewSlots)
    }

    @Test(arguments: [true, false]) func disagreeingTieLosesToNewSlots(notesNamed: Bool) async throws {
        let reveal = try await Reveal.make(World(notesNamed: notesNamed))
        // The weather app's first item says it is in the notes app's slot (a frame it left behind), which was drawn before the snapshot; a
        // slot appeared for it all the same.
        reveal.world.move(reveal.world.temp, to: World.notesSlot.insetBy(dx: 6, dy: 1))

        let found = try #require(await reveal.scanner.locate(temp, on: nil, since: reveal.before))
        #expect(found.slotFrame == World.firstNew, "the slot that appeared is the item's, and the notes app's slot never is")
        #expect(found.tiedBy == .newSlots, "the tie disagreed, and isn't counted as agreeing")
        #expect(found.slotWasInBaseline == false)

        // Without the new slots the stale frame is all there is: the tie is the notes app's slot, which was there already.
        let stale = World(notesNamed: notesNamed)
        stale.move(stale.temp, to: World.notesSlot.insetBy(dx: 6, dy: 1))
        let scanner = stale.scanner()
        let staleBefore = try #require(await scanner.slotSnapshot(on: nil))
        let alone = try #require(await scanner.locate(temp, on: nil, since: staleBefore))
        #expect(alone.slotFrame == World.notesSlot)
        #expect(alone.tiedBy == .tie)
        #expect(alone.slotWasInBaseline, "so that the caller can tell that this is a frame left behind")
    }

    @Test func slotInBaselineIsReported() async throws {
        let world = World(tempFrame: World.firstNew.insetBy(dx: 6, dy: 1))
        world.addSlot(World.firstNew)
        let before = try #require(await baseline(of: world))
        #expect(before.slots.contains(World.firstNew))

        let found = try #require(await world.scanner().locate(temp, on: nil, since: before))

        #expect(found == ItemLocation(item: temp, displayUUID: main, slotFrame: World.firstNew, tiedBy: .tie, slotWasInBaseline: true,
                                      widthAgrees: true, frameMinusSlotWidth: -12))
    }

    @Test(arguments: [true, false]) func staleParkedFrameIsNotLocated(notesNamed: Bool) async throws {
        // x 7, y below the bar: where a concealed app's icons are reported. No slot is there, so no slot is the item's.
        let world = World(notesNamed: notesNamed)
        let before = try #require(await baseline(of: world))
        let scanner = world.scanner()

        #expect(await scanner.locate(temp, on: nil, since: nil) == nil)
        #expect(await scanner.locate(temp, on: nil, since: before) == nil)
        #expect(await scanner.locate(alerts, on: nil, since: before) == nil)
    }

    // MARK: Two signals before a click

    @Test(arguments: [true, false]) func aLiveTieAndAStaleTieNeverSwapTheItems(notesNamed: Bool) async throws {
        // The scan learned `temp` is the left one and `alerts` the right one. While they are revealed `temp`'s frame is still one it left
        // behind, in the notes app's slot (which makes it right of `alerts` when the places are read off the ties), and `alerts`'s is live, in
        // its own new slot. The places are what the scans learned, and not what this read makes of the ties.
        let reveal = try await Reveal.make(World(notesNamed: notesNamed))
        reveal.world.move(reveal.world.temp, to: World.notesSlot.insetBy(dx: 6, dy: 1))
        reveal.world.move(reveal.world.alerts, to: World.secondNew.insetBy(dx: 6, dy: 1))

        let first = try #require(await reveal.scanner.locate(temp, on: nil, since: reveal.before))
        let second = try #require(await reveal.scanner.locate(alerts, on: nil, since: reveal.before))

        #expect(first.slotFrame == World.firstNew)
        #expect(first.tiedBy == .newSlots, "the tie is the notes app's slot, which isn't the one that appeared for it")
        #expect(second.slotFrame == World.secondNew)
        #expect(second.tiedBy == .tieAndNewSlots)
        #expect(!first.isPostable(drawnAtSnapshot: false), "the app says another slot, so the slot and the width don't agree")
        #expect(second.isPostable(drawnAtSnapshot: false))
    }

    @Test func aTieToANewSlotThatThePlaceDoesNotGiveTheItemRefusesTheNewSlotsAnswer() async throws {
        // The app's items changed places while they were concealed (as they can when the order is changed, with the app's items out of the
        // bar): `alerts`, which the scans learned is the right one, is live in the left slot. Either what was learned or the tie is wrong,
        // and nothing says which: no item of the app is told by the slots that appeared.
        let reveal = try await Reveal.make()
        reveal.world.move(reveal.world.alerts, to: World.firstNew.insetBy(dx: 6, dy: 1))

        let moved = try #require(await reveal.scanner.locate(alerts, on: nil, since: reveal.before))
        #expect(moved.slotFrame == World.firstNew, "where the app puts it")
        #expect(moved.tiedBy == .tie)
        #expect(!moved.isPostable(drawnAtSnapshot: false), "a tie alone is not enough for an item that was concealed")
        #expect(await reveal.scanner.locate(temp, on: nil, since: reveal.before) == nil, "and nothing says where the other is")

        // Both of them live, swapped: each is where its app puts it, and neither is told by the order that was learned.
        reveal.world.move(reveal.world.temp, to: World.secondNew.insetBy(dx: 6, dy: 1))
        let swappedTemp = try #require(await reveal.scanner.locate(temp, on: nil, since: reveal.before))
        let swappedAlerts = try #require(await reveal.scanner.locate(alerts, on: nil, since: reveal.before))
        #expect(swappedTemp.slotFrame == World.secondNew && swappedTemp.tiedBy == .tie)
        #expect(swappedAlerts.slotFrame == World.firstNew && swappedAlerts.tiedBy == .tie)
        #expect(!swappedTemp.isPostable(drawnAtSnapshot: false) && !swappedAlerts.isPostable(drawnAtSnapshot: false))
        #expect(swappedTemp.isPostable(drawnAtSnapshot: true), "an item that was drawn at the snapshot is where its app puts it")
    }

    @Test func theWidthAgreesWhenTheFrameIsSixteenNarrowerToSixWider() async throws {
        // The slot is 40 wide.
        for (width, agrees) in [(40.0, true), (42.0, true), (46.0, true), (46.5, false), (39.5, true), (26.0, true), (24.0, true),
                                (23.5, false)] as [(CGFloat, Bool)] {
            let reveal = try await Reveal.make(parkedWidth: width)
            let found = try #require(await reveal.scanner.locate(temp, on: nil, since: reveal.before))
            #expect(found.tiedBy == .newSlots)
            #expect(found.widthAgrees == agrees, "\(width) wide")
            #expect(found.frameMinusSlotWidth == width - 40, "what the judgment is of: the frame's width less the slot's, \(width) wide")
            #expect(!found.isPostable(drawnAtSnapshot: false), "recorded, and no ground for a click: \(width) wide")
        }
        let none = try await Reveal.make(parkedWidth: nil)
        let found = try #require(await none.scanner.locate(temp, on: nil, since: none.before))
        #expect(found.tiedBy == .newSlots)
        #expect(!found.widthAgrees, "no frame, no width")
        #expect(found.frameMinusSlotWidth == nil, "and nothing to subtract")
        #expect(!found.isPostable(drawnAtSnapshot: false))
    }

    @Test func frameFourteenNarrowerAgrees() async throws {
        // macOS 27: the test item's frames are 24, 26, 28 and 30 in slots of 38, 40, 42 and 44.
        for (slot, frame) in [(38.0, 24.0), (40.0, 26.0), (42.0, 28.0), (44.0, 30.0)] as [(CGFloat, CGFloat)] {
            let slotFrame = CGRect(x: 3052, y: 0, width: slot, height: 30)
            let reveal = try await Reveal.make(World(items: 1), frames: [slotFrame], parkedWidth: frame)
            let found = try #require(await reveal.scanner.locate(temp, on: nil, since: reveal.before))
            #expect(found.slotFrame == slotFrame)
            #expect(found.widthAgrees, "\(frame) in \(slot)")
            #expect(found.frameMinusSlotWidth == -14)
            #expect(!found.isPostable(drawnAtSnapshot: false), "recorded, and no ground for a click")
        }
    }

    @Test func frameSeventeenNarrowerDisagrees() async throws {
        let reveal = try await Reveal.make(parkedWidth: 23)
        let found = try #require(await reveal.scanner.locate(temp, on: nil, since: reveal.before))
        #expect(found.frameMinusSlotWidth == -17)
        #expect(!found.widthAgrees)
    }

    @Test func aTieToAnotherSlotMakesTheWidthDisagree() async throws {
        // The app puts the item in the slot of an app that isn't asked with a frame 42 wide, which is the width of the new slot's icon (40)
        // all the same. A frame that says the item is somewhere else is no sign it is here.
        let reveal = try await Reveal.make { $0.addSlot(CGRect(x: 3000, y: 0, width: 36, height: 30)) }
        reveal.world.move(reveal.world.temp, to: CGRect(x: 3018 - 21, y: 1, width: 42, height: 28))

        let found = try #require(await reveal.scanner.locate(temp, on: nil, since: reveal.before))

        #expect(found.slotFrame == World.firstNew)
        #expect(found.tiedBy == .newSlots, "the slot that appeared wins over the tie, which says another slot")
        #expect(!found.widthAgrees)
        #expect(!found.isPostable(drawnAtSnapshot: false))
    }

    @Test func aFrameInTheSlotOfAnAppThatAnswersMakesTheWidthDisagree() async throws {
        // The app puts the item in the notes app's slot with a frame 42 wide, the width of the new slot's icon (40). The notes app's own
        // frame has that slot, so the item has no tie; what the app says of where it is is still not this slot.
        let reveal = try await Reveal.make()
        reveal.world.move(reveal.world.temp, to: CGRect(x: World.notesSlot.midX - 21, y: 1, width: 42, height: 28))

        let found = try #require(await reveal.scanner.locate(temp, on: nil, since: reveal.before))

        #expect(found.slotFrame == World.firstNew)
        #expect(found.tiedBy == .newSlots, "no tie: the notes app's frame has its slot")
        #expect(found.frameMinusSlotWidth == 2)
        #expect(!found.widthAgrees)
    }

    @Test func aMeterThatGrowsAsAnAppAppearsIsNotPostable() async throws {
        // A meter 30 wide, left of the notes app's slot, grows to 40 as a 30-wide app's icon appears right of it. The meter goes left, the
        // new icon takes the place it had (30 wide: the one old slot of its width), and the slots left of that are the meter's, 40 wide: the
        // two ways of matching agree that the meter's is the new one. Frames alone can't tell the two apart; the answer is no ground for a click.
        let world = World(items: 1)
        var meter = 0
        let reveal = try await Reveal.make(world, frames: [CGRect(x: 3106, y: 0, width: 30, height: 30)], learning: false, parkedWidth: 33) {
            meter = $0.addSlot(CGRect(x: 3106, y: 0, width: 30, height: 30))
        }
        reveal.world.ax.setAttribute(AXName.position, .point(CGPoint(x: 3062, y: 0)), on: meter)
        reveal.world.ax.setAttribute(AXName.size, .size(CGSize(width: 40, height: 30)), on: meter)

        let found = try #require(await reveal.scanner.locate(temp, on: nil, since: reveal.before))

        #expect(found.slotFrame == CGRect(x: 3062, y: 0, width: 40, height: 30), "the meter's slot is the one that is new, by the frames")
        #expect(found.tiedBy == .newSlots)
        #expect(found.widthAgrees, "the app's icon is 33 wide, and that slot is 40: within the band, which is no ground for a click")
        #expect(!found.isPostable(drawnAtSnapshot: false))
    }

    @Test func aMeterThatGrowsByThreeAsAnAppAppearsIsNotPostable() async throws {
        // As above, but the meter grows by 3 points (30 to 33): the new slot is the meter's, and its width is the app's icon's.
        let world = World(items: 1)
        var meter = 0
        let reveal = try await Reveal.make(world, frames: [CGRect(x: 3106, y: 0, width: 30, height: 30)], learning: false, parkedWidth: 33) {
            meter = $0.addSlot(CGRect(x: 3106, y: 0, width: 30, height: 30))
        }
        reveal.world.ax.setAttribute(AXName.position, .point(CGPoint(x: 3069, y: 0)), on: meter)
        reveal.world.ax.setAttribute(AXName.size, .size(CGSize(width: 33, height: 30)), on: meter)

        let found = try #require(await reveal.scanner.locate(temp, on: nil, since: reveal.before))

        #expect(found.slotFrame == CGRect(x: 3069, y: 0, width: 33, height: 30), "the meter's slot is the one the frames say is new")
        #expect(found.widthAgrees, "and it is as wide as the app's icon")
        #expect(!found.isPostable(drawnAtSnapshot: false), "which is no ground for a click")
    }

    @Test func unnamedItemsAreWhatTheScansCalledThem() async throws {
        // An app whose two items have no names: the scans called the left one `.index(0)` and the right one `.index(1)` while they were drawn.
        // During the reveal the first the app lists (the left one) still has a frame it left behind, in the slot of an app that isn't asked
        // (so that no frame of another app's has the slot), and the other is live in the right-hand slot. Read from those ties alone
        // `.index(0)` would be the right one: it is nobody's.
        let someoneElses = CGRect(x: 3182, y: 0, width: 36, height: 30)
        let reveal = try await Reveal.make(World(unnamed: true)) { $0.addSlot(someoneElses) }
        let left = ItemID(bundleID: weather, key: .index(0))
        let right = ItemID(bundleID: weather, key: .index(1))
        reveal.world.move(reveal.world.temp, to: someoneElses.insetBy(dx: 6, dy: 1))
        reveal.world.move(reveal.world.alerts, to: World.secondNew.insetBy(dx: 6, dy: 1))

        #expect(await reveal.scanner.locate(left, on: nil, since: reveal.before) == nil)
        #expect(await reveal.scanner.locate(right, on: nil, since: reveal.before) == nil)

        // With the ties as they are when nothing is stale, they are the left and the right one.
        reveal.world.move(reveal.world.temp, to: World.firstNew.insetBy(dx: 6, dy: 1))
        let first = try #require(await reveal.scanner.locate(left, on: nil, since: reveal.before))
        let second = try #require(await reveal.scanner.locate(right, on: nil, since: reveal.before))
        #expect(first.slotFrame == World.firstNew && first.tiedBy == .tieAndNewSlots)
        #expect(second.slotFrame == World.secondNew && second.tiedBy == .tieAndNewSlots)
        #expect(first.isPostable(drawnAtSnapshot: false) && second.isPostable(drawnAtSnapshot: false))
    }

    @Test func aRelaunchedAppHasNoPlaceUntilTheScansSeeItDrawn() async throws {
        // The scans learned which of the app's two items is the left one. The app is started again (another process) while its items are
        // concealed, and may make them in another order: what was learned is of the run before, and says nothing of this one.
        let reveal = try await Reveal.make()
        #expect(await reveal.scanner.locate(temp, on: nil, since: reveal.before)?.slotFrame == World.firstNew, "before it")

        reveal.world.relaunchWeather(as: 2001)

        #expect(await reveal.scanner.locate(temp, on: nil, since: reveal.before) == nil)
        #expect(await reveal.scanner.locate(alerts, on: nil, since: reveal.before) == nil)
    }

    @Test func namedItemsAreNotAskedForTheirPlace() async throws {
        // The same stale tie with names of their own: an item is what its app calls it, whatever the ties say.
        let reveal = try await Reveal.make()
        reveal.world.move(reveal.world.temp, to: World.notesSlot.insetBy(dx: 6, dy: 1))
        reveal.world.move(reveal.world.alerts, to: World.secondNew.insetBy(dx: 6, dy: 1))

        #expect(await reveal.scanner.locate(temp, on: nil, since: reveal.before)?.slotFrame == World.firstNew)
        #expect(await reveal.scanner.locate(alerts, on: nil, since: reveal.before)?.slotFrame == World.secondNew)
    }

    @Test func anItemThatTheScansNeverSawHasNoNameToLocateItBy() async throws {
        // No scan has seen the app's two nameless items, so `.index(0)` is whichever the app lists first; the read, which finds them by their
        // frames, may say another. Without the scans' word there is no answer.
        let world = World(items: 2, unnamed: true)
        world.addSlot(World.firstNew)
        world.addSlot(World.secondNew)
        world.move(world.temp, to: World.secondNew.insetBy(dx: 6, dy: 1))
        world.move(world.alerts, to: World.firstNew.insetBy(dx: 6, dy: 1))
        #expect(await world.scanner().locate(ItemID(bundleID: weather, key: .index(0)), on: nil, since: nil) == nil)
    }

    @Test func aNeighbourThatShrinksAsAnAppAppearsIsNotPostable() async throws {
        // The same the other way: a 40-wide app appears while its neighbour (40 wide) shrinks to 30. The new icon takes the neighbour's place,
        // and the neighbour's 30-wide slot is the one that looks new.
        let world = World(items: 1)
        var neighbour = 0
        let reveal = try await Reveal.make(world, frames: [CGRect(x: 3096, y: 0, width: 40, height: 30)], learning: false, parkedWidth: 43) {
            neighbour = $0.addSlot(CGRect(x: 3096, y: 0, width: 40, height: 30))
        }
        reveal.world.ax.setAttribute(AXName.position, .point(CGPoint(x: 3062, y: 0)), on: neighbour)
        reveal.world.ax.setAttribute(AXName.size, .size(CGSize(width: 30, height: 30)), on: neighbour)

        let found = try #require(await reveal.scanner.locate(temp, on: nil, since: reveal.before))

        #expect(found.slotFrame == CGRect(x: 3062, y: 0, width: 30, height: 30))
        #expect(found.tiedBy == .newSlots)
        #expect(!found.widthAgrees, "the app's icon is 43 wide, and that slot is 30")
        #expect(!found.isPostable(drawnAtSnapshot: false))
    }

    @Test func noBaselineIsNeverPostableForAConcealedItem() async throws {
        // Without a snapshot the only evidence is the app's frame, and a concealed item's is one it left behind.
        let reveal = try await Reveal.make()
        reveal.world.move(reveal.world.temp, to: World.firstNew.insetBy(dx: 6, dy: 1))

        let found = try #require(await reveal.scanner.locate(temp, on: nil, since: nil))

        #expect(found.tiedBy == .tie)
        #expect(!found.isPostable(drawnAtSnapshot: false))
        #expect(found.isPostable(drawnAtSnapshot: true), "an item that is drawn is where its app puts it")
    }

    @Test func isPostableNeedsTheTieAndTheNewSlotForAConcealedItem() {
        func location(_ tiedBy: ItemLocation.TiedBy, widthAgrees: Bool, wasThere: Bool = false) -> ItemLocation {
            ItemLocation(item: temp, displayUUID: main, slotFrame: World.firstNew, tiedBy: tiedBy, slotWasInBaseline: wasThere, widthAgrees: widthAgrees)
        }
        // Concealed at the snapshot.
        #expect(location(.tieAndNewSlots, widthAgrees: false).isPostable(drawnAtSnapshot: false), "the app and the slot that appeared agree")
        #expect(!location(.newSlots, widthAgrees: true).isPostable(drawnAtSnapshot: false),
                "a slot that appeared and a width that agrees: a neighbour that changes by a few points has both")
        #expect(!location(.newSlots, widthAgrees: false).isPostable(drawnAtSnapshot: false), "a slot that appeared says only that something did")
        #expect(!location(.tie, widthAgrees: true).isPostable(drawnAtSnapshot: false), "a tie alone is a frame left behind")
        #expect(!location(.tie, widthAgrees: true, wasThere: false).isPostable(drawnAtSnapshot: false))
        // Drawn at the snapshot: where its app says.
        #expect(location(.tie, widthAgrees: false, wasThere: true).isPostable(drawnAtSnapshot: true))
        #expect(location(.tieAndNewSlots, widthAgrees: false).isPostable(drawnAtSnapshot: true))
        #expect(!location(.newSlots, widthAgrees: true).isPostable(drawnAtSnapshot: true), "its app puts it elsewhere than the slot that appeared")
    }

    @Test func aSnapshotOfAnotherDisplayIsNoBaseline() async throws {
        let reveal = try await Reveal.make()
        let elsewhere = SlotSnapshot(displayUUID: "another-display", slots: [])
        #expect(await reveal.scanner.locate(temp, on: nil, since: elsewhere) == nil)
        #expect(await reveal.scanner.locate(temp, on: nil, since: reveal.before)?.slotFrame == World.firstNew, "which it is with its own")
    }

    // MARK: A concealed app's frames

    @Test(arguments: [true, false]) func aConcealedAppsLeftBehindFrameNeverTiesAnotherAppsSlot(notesNamed: Bool) async throws {
        // The weather app is concealed, and the frame it left behind lies in the notes app's slot, where the notes app's own is.
        // Its frame is at the slot's centre, and the notes app's a little off it.
        let world = World(tempFrame: World.notesSlot.insetBy(dx: 6, dy: 1), notesNamed: notesNamed)
        for (name, value) in FakeAX.frameAttributes(World.notesSlot.insetBy(dx: 6, dy: 1).offsetBy(dx: 3, dy: 0)) {
            world.ax.setAttribute(name, value, on: world.notesItem)
        }
        let scanner = world.scanner()
        _ = await scanner.scan()
        let notesItem = ItemID(bundleID: notes, key: .identifier("notes.main"))
        // A slot that carries the notes app's own name for its item is whose it is whatever frame lies in it; with no name on it (as on
        // macOS 27), the weather app's frame is the closer one, and believed.
        let first = await scanner.locate(temp, on: nil, since: nil)
        if notesNamed {
            #expect(first == nil, "the slot is named for the notes app's item")
        } else {
            #expect(first?.slotFrame == World.notesSlot, "believed, its frame is the closer one")
        }

        _ = await scanner.scan(concealed: [weather])

        #expect(await scanner.locate(temp, on: nil, since: nil) == nil, "the notes app's own frame has the slot")
        #expect(await scanner.locate(notesItem, on: nil, since: nil)?.slotFrame == World.notesSlot)
    }

    @Test func aRevealedAppsFreshFrameStillTies() async throws {
        // The scanner still has the weather app among the concealed (the probe's own assertion has revealed it since): its frame is in a new
        // slot that no other app's frame is in, and ties; the slot that appeared agrees.
        let world = World(tempFrame: parked, items: 1)
        let scanner = world.scanner()
        _ = await scanner.scan(concealed: [weather])
        let before = try #require(await scanner.slotSnapshot(on: nil))
        world.addSlot(World.firstNew)
        world.move(world.temp, to: World.firstNew.insetBy(dx: 6, dy: 1))

        let found = try #require(await scanner.locate(temp, on: nil, since: before))

        #expect(found.slotFrame == World.firstNew)
        #expect(found.tiedBy == .tieAndNewSlots)
    }

    @Test func aConcealedAppsFrameIsNeverTiedOnItsOwn() async throws {
        // Its frame lies in a slot of the bar, which is nobody's (a nameless one of 32 points) or somebody's left over: what a concealed app
        // says of where it is says nothing, and `locate` finds no icon (the click probe's precheck asks the same, and would say it is drawn).
        let nobodys = CGRect(x: 3000, y: 0, width: 32, height: 30)
        let world = World(tempFrame: nobodys.insetBy(dx: 4, dy: 1), items: 1)
        world.addSlot(nobodys)
        let scanner = world.scanner()
        #expect(await scanner.locate(temp, on: nil, since: nil)?.slotFrame == nobodys, "an app that is drawn has the slot")

        _ = await scanner.scan(concealed: [weather])

        #expect(await scanner.locate(temp, on: nil, since: nil) == nil)
        // The slot that appears for it, with its frame in it, is what shows it is back.
        let before = try #require(await scanner.slotSnapshot(on: nil))
        world.addSlot(World.firstNew)
        world.move(world.temp, to: World.firstNew.insetBy(dx: 6, dy: 1))
        #expect(await scanner.locate(temp, on: nil, since: before)?.tiedBy == .tieAndNewSlots)
    }

    @Test func theItemsOwnAppClaimsLast() async throws {
        // the weather app is no longer among the scanner's concealed apps (the plan was lifted), and its frame, left behind, lies in the notes
        // app's slot, nearer that slot's centre than the notes app's own frame. The notes app answers for its slot: the weather item has none.
        let reveal = try await Reveal.make()
        reveal.world.move(reveal.world.temp, to: World.notesSlot.insetBy(dx: 5, dy: 1))
        reveal.world.move(reveal.world.notesItem, to: World.notesSlot.insetBy(dx: 6, dy: 1).offsetBy(dx: 2, dy: 0))

        let found = await reveal.scanner.locate(temp, on: nil, since: nil)

        #expect(found == nil, "the notes app's frame has its own slot; \(String(describing: found))")
    }

    @Test func aSnapshotFromAnotherWindowSaysNothingOfNewSlots() async throws {
        // the snapshot was read from one window of MenuBarAgent's; a later read settles on another (the first repeats a name), whose slots
        // are not comparable. The slot that carries the item's name there is no new one: the answer is a tie at most, which isn't postable.
        let reveal = try await Reveal.make(identifiers: ["weather.temp", "weather.alerts"], learning: false)
        let snapshot = SlotSnapshot(displayUUID: reveal.before.displayUUID, slots: reveal.before.slots, names: reveal.before.names,
                                    identifiers: reveal.before.identifiers, window: (reveal.before.window ?? 0) + 1)
        reveal.world.move(reveal.world.temp, to: World.firstNew.insetBy(dx: 6, dy: 1))

        let same = try #require(await reveal.scanner.locate(temp, on: nil, since: reveal.before))
        #expect(same.tiedBy == .tieAndNewSlots, "the window the snapshot came from: the name is new and its frame agrees")

        let other = await reveal.scanner.locate(temp, on: nil, since: snapshot)
        #expect(other?.tiedBy == .tie)
        #expect(other?.isPostable(drawnAtSnapshot: false) == false)
        #expect(other?.slotWasInBaseline == true, "taken to be an old slot when the new ones can't be told")
    }

    @Test func aNameThatRepeatedAtTheSnapshotIsNeverNew() async throws {
        // two slots of the bar carried "weather.temp" at the snapshot (one is a stale one), so the name told nothing then, and the snapshot
        // has it among its identifiers. It is on one slot only now: that slot is an old one, and no slot appeared for the item.
        let reveal = try await Reveal.make(identifiers: ["weather.temp", "weather.alerts"], learning: false)
        let snapshot = SlotSnapshot(displayUUID: reveal.before.displayUUID, slots: reveal.before.slots, names: reveal.before.names,
                                    identifiers: reveal.before.identifiers.union(["weather.temp"]), window: reveal.before.window)
        reveal.world.move(reveal.world.temp, to: World.firstNew.insetBy(dx: 6, dy: 1))

        let found = try #require(await reveal.scanner.locate(temp, on: nil, since: snapshot))

        #expect(found.tiedBy == .tie, "the name is no sign of a new slot: the slot was there")
        #expect(!found.isPostable(drawnAtSnapshot: false))
    }

    @Test func aSlotWhoseNameWasOnTheBarAtTheSnapshotIsNeverNewEvenWhenItIsTheOnlyExtraOne() {
        // Two slots carried "dup" at the snapshot (the name told nothing then). Now a third does too: by widths and order it is the slot that
        // appeared, but its name was on the bar, so it is an old slot (with no name to tell it by) and no slot appeared.
        func slot(_ x: CGFloat, _ width: CGFloat) -> AgentSlot {
            AgentSlot(frame: CGRect(x: x, y: 0, width: width, height: 30), identifier: "dup", role: nil, subrole: nil, description: nil,
                      ownerPID: nil, isOverflowChevron: false)
        }
        let snapshot = SlotSnapshot(displayUUID: main, slots: [CGRect(x: 100, y: 0, width: 40, height: 30), CGRect(x: 150, y: 0, width: 30, height: 30)],
                                    names: [nil, nil], identifiers: ["dup"])
        let bar = MatchBar(displayUUID: main, rect: CGRect(x: 0, y: 0, width: 1000, height: 30), slots: [slot(100, 40), slot(150, 30), slot(190, 36)])

        let appeared = ItemLocator.appeared(since: snapshot, in: bar)

        #expect(appeared.all == [], "the third slot is no new one")
        #expect(!appeared.includes(CGRect(x: 190, y: 0, width: 36, height: 30)))
    }

    @Test func aFrameLeftBehindAtTheEdgeOfAnotherAppsSlotDoesNotReachTheNeighboursEmptySlot() async throws {
        // The weather app's frame lies in the notes app's slot, half a point from its right edge, and within reach of the next slot, which is
        // nobody's. The notes app's own frame has the slot; the weather app's item claims after it, finds its slot taken and has none: it
        // doesn't take the next one, which would be a tie to a slot that isn't its.
        let nobodys = CGRect(x: 3176, y: 0, width: 36, height: 30)
        let world = World(tempFrame: CGRect(x: World.notesSlot.maxX - 12.5, y: 3, width: 24, height: 24), items: 1)
        world.addSlot(nobodys)
        let scanner = world.scanner()
        _ = await scanner.scan()

        #expect(await scanner.locate(temp, on: nil, since: nil) == nil)
    }

    @Test func theSlotOfAnAppThatIsStillOnItsWayOffTheBarIsNoSlotThatAppeared() {
        // The notes app is concealed for room, and its plan is applied, but its slot is drawn still. The baseline has it gone, and the slot
        // left of it moved right by its width: the bar as it is fits that (the slot to the left is "pushed left"), and the notes app's slot
        // is left over, as if it had appeared.
        func slot(_ x: CGFloat, _ width: CGFloat, name: String? = nil) -> AgentSlot {
            AgentSlot(frame: CGRect(x: x, y: 0, width: width, height: 30), identifier: name, role: nil, subrole: nil, description: nil,
                      ownerPID: nil, isOverflowChevron: false)
        }
        let snapshot = SlotSnapshot(displayUUID: main, slots: [CGRect(x: 800, y: 0, width: 30, height: 30), CGRect(x: 830, y: 0, width: 40, height: 30)],
                                    owners: ["a", notes])
        let bar = MatchBar(displayUUID: main, rect: CGRect(x: 0, y: 0, width: 1000, height: 30), slots: [slot(800, 30), slot(830, 40)])
        let without = snapshot.removing(apps: [notes])
        #expect(without?.slots == [CGRect(x: 840, y: 0, width: 30, height: 30)])

        let appeared = ItemLocator.appeared(since: without ?? snapshot, in: bar)

        #expect(appeared.all == [], "the slot that is still drawn is the notes app's, and none appeared")
        #expect(!appeared.includes(CGRect(x: 830, y: 0, width: 40, height: 30)))
    }

    @Test func theSlotOfAnAppConcealedInALaterRoundIsNoSlotThatAppearedWhereTheEarlierRoundMovedIt() {
        // Round 0 conceals b, and a slides right into its room; round 1 conceals a, whose slot is drawn still at that new place. Taken out
        // of the snapshot itself, a and b are kept as never new where they were at the snapshot, and a's slot now is neither: it would be
        // the slot that appeared. Taken out of round 0's baseline, a is kept where round 0 moved it.
        func slot(_ x: CGFloat, _ width: CGFloat) -> AgentSlot {
            AgentSlot(frame: CGRect(x: x, y: 0, width: width, height: 30), identifier: nil, role: nil, subrole: nil, description: nil,
                      ownerPID: nil, isOverflowChevron: false)
        }
        let snapshot = SlotSnapshot(displayUUID: main, slots: [CGRect(x: 760, y: 0, width: 40, height: 30), CGRect(x: 800, y: 0, width: 30, height: 30),
                                                               CGRect(x: 830, y: 0, width: 40, height: 30)], owners: ["z", "a", "b"])
        let bar = MatchBar(displayUUID: main, rect: CGRect(x: 0, y: 0, width: 1000, height: 30), slots: [slot(800, 40), slot(840, 30)])
        let fromTheSnapshot = snapshot.removing(apps: ["a", "b"])
        let fromRoundZero = snapshot.removing(apps: ["b"])?.removing(apps: ["a", "b"])
        #expect(fromRoundZero?.slots == fromTheSnapshot?.slots, "the slots kept are the same either way")

        #expect(ItemLocator.appeared(since: fromTheSnapshot ?? snapshot, in: bar).all == [CGRect(x: 840, y: 0, width: 30, height: 30)],
                "from the snapshot, a's slot on its way off looks like one that appeared")
        #expect(ItemLocator.appeared(since: fromRoundZero ?? snapshot, in: bar).all == [], "from round 0's baseline, none appeared")
    }

    @Test func aFrameLeftInTheSlotOfAnAppOnItsWayOffTheBarIsNotTheSlotThatAppearedForTheItem() async throws {
        // The weather app is concealed and has one item, whose frame lies in the notes app's slot (it was the weather app's place before the
        // notes app slid right into it). The notes app is concealed for room: the snapshot without it has no slot there, but the slot is
        // drawn still, and a scan in the meantime took the notes app out of those that claim slots. The tie and the slot that "appeared"
        // agree, and the click would land on the notes app's icon.
        let world = World(tempFrame: World.notesSlot.insetBy(dx: 6, dy: 1), items: 1, notesNamed: false)
        let scanner = world.scanner()
        _ = await scanner.scan(concealed: [weather])
        let snapshot = try #require(await scanner.slotSnapshot(on: nil))
        let without = try #require(snapshot.removing(apps: [notes]))
        _ = await scanner.scan(concealed: [weather, notes])

        let found = await scanner.locate(temp, on: nil, since: without)

        #expect(found?.isPostable(drawnAtSnapshot: false) != true, "\(String(describing: found))")
        #expect(found?.slotFrame != World.notesSlot || found?.tiedBy != .tieAndNewSlots)
    }

    @Test func anyFrameTheAppReportsInANewSlotThatIsntItsPlacesVoidsTheOrderAnswer() async throws {
        // the app has two items and each ends in the slot its place gives it, by the scan's learning. But the frame of the second is
        // in the first's new slot, though another app's frame wins that slot (so the second has no tie there): the places can't be trusted.
        let reveal = try await Reveal.make()
        reveal.world.move(reveal.world.temp, to: World.firstNew.insetBy(dx: 6, dy: 1))
        reveal.world.move(reveal.world.alerts, to: World.firstNew.insetBy(dx: 7, dy: 1))

        let first = await reveal.scanner.locate(temp, on: nil, since: reveal.before)
        let second = await reveal.scanner.locate(alerts, on: nil, since: reveal.before)

        #expect(first?.tiedBy == .tie, "the tie alone: no new slot is told, since the places can't be trusted")
        #expect(first?.isPostable(drawnAtSnapshot: false) == false)
        #expect(second == nil, "no slot of its own, and its frame is nobody's")
    }

    // MARK: Whose slot it was

    @Test func theSnapshotNamesTheAppWhoseIconIsInEachSlot() async throws {
        let world = World(tempFrame: World.firstNew.insetBy(dx: 6, dy: 1), items: 1)
        world.addSlot(World.firstNew)
        let scanner = world.scanner()
        _ = await scanner.scan()

        let snapshot = try #require(await scanner.slotSnapshot(on: nil))

        #expect(snapshot.slots.count == snapshot.owners.count)
        let owners = Dictionary(uniqueKeysWithValues: zip(snapshot.slots.map(\.minX), snapshot.owners))
        #expect(owners[World.firstNew.minX] == weather)
        #expect(owners[World.notesSlot.minX] == notes)
        #expect(owners[World.clockSlot.minX] == .some(nil), "a system slot is no app's")
    }

    @Test func removingAnAppsSlotsClosesTheBarUpAgainstTheRightEdge() {
        // Four slots, right-aligned, four points apart: the second and third are the sync app's and the VPN app's.
        func slot(_ minX: CGFloat, _ width: CGFloat) -> CGRect { CGRect(x: minX, y: 0, width: width, height: 30) }
        let snapshot = SlotSnapshot(displayUUID: main, slots: [slot(100, 36), slot(140, 30), slot(174, 44), slot(222, 36)],
                                    owners: ["a", "vpn", "sync", "own"])

        let without = snapshot.removing(apps: ["vpn", "sync"])

        // The two that went took 82 points, from the first's right edge to their own: the first closes up against the last.
        #expect(without?.slots == [slot(182, 36), slot(222, 36)])
        #expect(without?.owners == ["a", "own"])
        // An app at the right end takes 40 points, and the slots left of it close up; one at the left end moves nothing.
        #expect(snapshot.removing(apps: ["own"])?.slots == [slot(140, 36), slot(180, 30), slot(214, 44)])
        #expect(snapshot.removing(apps: ["a"])?.slots == [slot(140, 30), slot(174, 44), slot(222, 36)])
        // An app with no slot takes nothing, and nothing is removed from a snapshot that doesn't say whose slots are whose.
        #expect(snapshot.removing(apps: ["nobody"]) == snapshot)
        #expect(SlotSnapshot(displayUUID: main, slots: snapshot.slots).removing(apps: ["vpn"]) == nil)
        #expect(SlotSnapshot(displayUUID: main, slots: snapshot.slots).removing(apps: []) != nil)
    }

    // MARK: New slots, told by name and by order

    @Test func aNamedSlotThatAppearedIsNewWhateverItsNeighboursDid() async throws {
        // The notes app's slot (named, and there at the snapshot) is 4 points wider now, which no geometry of the old slots could match.
        // The item's slot carries its name, which the snapshot's didn't: it is the new one, with no learned place needed.
        let reveal = try await Reveal.make(identifiers: ["weather.temp", "weather.alerts"], learning: false)
        reveal.world.ax.setAttribute(AXName.position, .point(CGPoint(x: 3136, y: 0)), on: reveal.world.notesSlotElement)
        reveal.world.ax.setAttribute(AXName.size, .size(CGSize(width: 40, height: 30)), on: reveal.world.notesSlotElement)
        reveal.world.move(reveal.world.temp, to: World.firstNew.insetBy(dx: 6, dy: 1))

        let found = try #require(await reveal.scanner.locate(temp, on: nil, since: reveal.before))

        #expect(found.slotFrame == World.firstNew)
        #expect(found.tiedBy == .tieAndNewSlots)
        #expect(!found.slotWasInBaseline)
        #expect(found.isPostable(drawnAtSnapshot: false))
        let second = try #require(await reveal.scanner.locate(alerts, on: nil, since: reveal.before))
        #expect(second.slotFrame == World.secondNew && second.tiedBy == .tieAndNewSlots, "each by its own name")
    }

    @Test func aNamedSlotThatWasThereIsNeverNew() async throws {
        // The notes app's slot has its name in the snapshot: whatever the item's app says of it, it is an old one.
        let world = World(tempFrame: World.notesSlot.insetBy(dx: 6, dy: 1))
        let scanner = world.scanner()
        let before = try #require(await scanner.slotSnapshot(on: nil))
        #expect(before.names.compactMap { $0 }.contains("notes.main"))

        let found = try #require(await scanner.locate(temp, on: nil, since: before))

        #expect(found.slotFrame == World.notesSlot)
        #expect(found.slotWasInBaseline)
        #expect(!found.isPostable(drawnAtSnapshot: false))
    }

    @Test func aNamedOldSlotIsNeverTakenForANewOne() async throws {
        // Two slots as wide as the notes app's, left of it. With no names the old slot can't be told from the new ones (see
        // aNewSlotAsWideAsItsOldNeighbourIsNotGuessed); it carries its name, so they are.
        let reveal = try await Reveal.make(frames: [CGRect(x: 3056, y: 0, width: 36, height: 30), CGRect(x: 3100, y: 0, width: 36, height: 30)])

        let first = try #require(await reveal.scanner.locate(temp, on: nil, since: reveal.before))
        let second = try #require(await reveal.scanner.locate(alerts, on: nil, since: reveal.before))

        #expect(first.slotFrame == CGRect(x: 3056, y: 0, width: 36, height: 30))
        #expect(second.slotFrame == CGRect(x: 3100, y: 0, width: 36, height: 30))
        #expect(!first.slotWasInBaseline && !second.slotWasInBaseline)
    }

    @Test func aSnapshotsNamesAreThoseThatDoNotRepeat() async throws {
        // A window of a Space that isn't on screen gives every slot of an app its first item's name: such a name tells nothing.
        let world = World()
        world.addSlot(CGRect(x: 3052, y: 0, width: 40, height: 30), identifier: "weather.temp")
        world.addSlot(CGRect(x: 3096, y: 0, width: 40, height: 30), identifier: "weather.temp")
        let snapshot = try #require(await world.scanner().slotSnapshot(on: nil))

        #expect(snapshot.slots.count == snapshot.names.count)
        #expect(!snapshot.names.contains("weather.temp"))
        #expect(snapshot.names.compactMap { $0 }.sorted() == ["com.apple.menuextra.clock", "com.apple.menuextra.wifi", "notes.main"])
    }

    @Test func aNeighbourThatOnlyChangedWidthDoesNotVoidTheNewSlots() async throws {
        // Three slots with no names (apps' on macOS 27): the middle one has live text and grows by 4 points between the snapshot and now,
        // and a slot of the weather app's appears left of them. The two outer old slots match, and what is between them is the one that
        // grew: the new slot is the one left over.
        let item = CGRect(x: 2978, y: 0, width: 40, height: 30)
        var live = 0, left = 0
        let reveal = try await Reveal.make(World(items: 1), frames: [item], learning: false) {
            left = $0.addSlot(CGRect(x: 3026, y: 0, width: 36, height: 30))
            live = $0.addSlot(CGRect(x: 3066, y: 0, width: 30, height: 30))
            $0.addSlot(CGRect(x: 3100, y: 0, width: 36, height: 30))
        }
        reveal.world.ax.setAttribute(AXName.position, .point(CGPoint(x: 3022, y: 0)), on: left)
        reveal.world.ax.setAttribute(AXName.position, .point(CGPoint(x: 3062, y: 0)), on: live)
        reveal.world.ax.setAttribute(AXName.size, .size(CGSize(width: 34, height: 30)), on: live)
        reveal.world.move(reveal.world.temp, to: item.insetBy(dx: 6, dy: 1))

        let found = try #require(await reveal.scanner.locate(temp, on: nil, since: reveal.before))

        #expect(found.slotFrame == item)
        #expect(found.tiedBy == .tieAndNewSlots)
        #expect(!found.slotWasInBaseline)
        #expect(found.isPostable(drawnAtSnapshot: false))
    }

    @Test func aSlotThatGrewBetweenTwoMatchedOnesIsNotNew() {
        let old = slots([36, 30, 36])
        let after = slots([40, 36, 34, 36])
        #expect(ItemLocator.appearedSlots(since: old, in: after) == [after[0]])
    }

    @Test func aSlotThatChangedWidthAtAnEndVoidsTheAnswer() {
        // Nothing says whether the last slot grew or a slot went and another came.
        #expect(ItemLocator.appearedSlots(since: slots([36, 30]), in: slots([40, 36, 34])) == nil)
        #expect(ItemLocator.appearedSlots(since: slots([30, 36]), in: slots([34, 36, 40])) == nil)
    }

    @Test func aGrownSlotWithANewOneBesideItIsNotGuessed() {
        // The slot between the two that matched has room for two, and which is the old one that grew isn't told.
        #expect(ItemLocator.appearedSlots(since: slots([36, 30, 36]), in: slots([36, 40, 34, 36])) == nil)
    }

    @Test func aSlotThatGrewAndMovedRightIsNotTheOldOne() {
        // Slots only move left when others appear: one whose right edge is right of where it was is not it.
        let old = slots([36, 30, 36])
        var after = slots([40, 36, 34, 36])
        after[2] = after[2].offsetBy(dx: 6, dy: 0)
        #expect(ItemLocator.appearedSlots(since: old, in: after) == nil)
    }

    // MARK: Named slots as anchors

    @Test func aGrownSlotAcrossANamedSlotIsNotTheItemsNewSlot() async throws {
        // Before: [dot (named) 20, 30, 36]. Now: [30, dot, 34, 36]. The slot of 30 left of the dot is new, and the slot of 30 right of it grew
        // to 34. Without the dot between them, the grown slot could be matched to the new one, leaving the 34 as the one that appeared.
        let new = CGRect(x: 3044, y: 0, width: 30, height: 30)
        var dot = 0, grown = 0
        let reveal = try await Reveal.make(World(items: 1, notesNamed: false), frames: [new], learning: false) {
            dot = $0.addSlot(CGRect(x: 3082, y: 0, width: 20, height: 30), identifier: "com.example.dot")
            grown = $0.addSlot(CGRect(x: 3106, y: 0, width: 30, height: 30))
        }
        reveal.world.ax.setAttribute(AXName.position, .point(CGPoint(x: 3078, y: 0)), on: dot)
        reveal.world.ax.setAttribute(AXName.position, .point(CGPoint(x: 3102, y: 0)), on: grown)
        reveal.world.ax.setAttribute(AXName.size, .size(CGSize(width: 34, height: 30)), on: grown)
        let grownSlot = CGRect(x: 3102, y: 0, width: 34, height: 30)

        // The frame the app left behind lies in the slot that grew, which no app that answers claims.
        reveal.world.move(reveal.world.temp, to: grownSlot.insetBy(dx: 0, dy: 1))
        let stale = await reveal.scanner.locate(temp, on: nil, since: reveal.before)
        #expect(stale?.slotFrame == new, "the slot that appeared, never the one that grew")
        #expect(stale?.tiedBy == .newSlots)
        #expect(stale?.isPostable(drawnAtSnapshot: false) == false, "the stale frame and the wrong slot would have agreed")

        // Its own frame in the new slot: the same slot, both ways.
        reveal.world.move(reveal.world.temp, to: new.insetBy(dx: 0, dy: 1))
        let fresh = try #require(await reveal.scanner.locate(temp, on: nil, since: reveal.before))
        #expect(fresh.slotFrame == new && fresh.tiedBy == .tieAndNewSlots && fresh.isPostable(drawnAtSnapshot: false))
    }

    @Test func aSlotThatAnotherAppsFrameIsInIsNeverTakenForTheItems() async throws {
        // No anchor here to stop it: the notes app's slot (nameless) grows from 36 to 40 as a slot of 36 appears left of it, and the
        // geometry takes the new slot for the old one and the grown one for the new. The notes app's own frame is in the grown slot.
        let new = CGRect(x: 3096, y: 0, width: 36, height: 30)
        let reveal = try await Reveal.make(World(items: 1, notesNamed: false), frames: [new])
        let notesSlot = CGRect(x: 3136, y: 0, width: 40, height: 30)
        reveal.world.ax.setAttribute(AXName.position, .point(notesSlot.origin), on: reveal.world.notesSlotElement)
        reveal.world.ax.setAttribute(AXName.size, .size(notesSlot.size), on: reveal.world.notesSlotElement)
        reveal.world.move(reveal.world.notesItem, to: notesSlot.insetBy(dx: 6, dy: 1))
        reveal.world.move(reveal.world.temp, to: new.insetBy(dx: 6, dy: 1))

        let found = try #require(await reveal.scanner.locate(temp, on: nil, since: reveal.before))

        #expect(found.slotFrame == new, "the slot its own app's frame is in")
        #expect(found.tiedBy == .tie, "the slot that grew is the notes app's, whatever the order says")
        #expect(!found.isPostable(drawnAtSnapshot: false))
    }

    @Test func aNameAnotherAppListsIsNotTheItemsAlone() async throws {
        // The notes app lists an item with the weather app's identifier: a slot that carries it is not the weather app's for the name.
        let reveal = try await Reveal.make(identifiers: ["weather.temp", "weather.alerts"])
        reveal.world.ax.setAttribute(AXName.identifier, .string("weather.temp"), on: reveal.world.notesItem)
        reveal.world.move(reveal.world.temp, to: World.firstNew.insetBy(dx: 6, dy: 1))

        let found = try #require(await reveal.scanner.locate(temp, on: nil, since: reveal.before))

        #expect(found.slotFrame == World.firstNew)
        #expect(found.tiedBy == .tie, "the name tells nothing: its own frame does")
        #expect(!found.isPostable(drawnAtSnapshot: false))
    }

    // MARK: A slot that shrank

    @Test func aNeighbourThatShrinksAsTheItemsSlotAppearsRightOfItDoesNotVoidTheNewSlots() async throws {
        // Before: [36, 34 (live text), 36] left of the notes app's (named) slot. Now the live slot is 30 and the item's slot (40) is right of
        // them all: everything left of it is pushed left, the live slot by more at its right edge than at its left.
        let item = CGRect(x: 3096, y: 0, width: 40, height: 30)
        var left = 0, live = 0, right = 0
        let reveal = try await Reveal.make(World(items: 1), frames: [item], learning: false) {
            left = $0.addSlot(CGRect(x: 3022, y: 0, width: 36, height: 30))
            live = $0.addSlot(CGRect(x: 3062, y: 0, width: 34, height: 30))
            right = $0.addSlot(CGRect(x: 3100, y: 0, width: 36, height: 30))
        }
        reveal.world.ax.setAttribute(AXName.position, .point(CGPoint(x: 2982, y: 0)), on: left)
        reveal.world.ax.setAttribute(AXName.position, .point(CGPoint(x: 3022, y: 0)), on: live)
        reveal.world.ax.setAttribute(AXName.size, .size(CGSize(width: 30, height: 30)), on: live)
        reveal.world.ax.setAttribute(AXName.position, .point(CGPoint(x: 3056, y: 0)), on: right)
        reveal.world.move(reveal.world.temp, to: item.insetBy(dx: 6, dy: 1))

        let found = try #require(await reveal.scanner.locate(temp, on: nil, since: reveal.before))

        #expect(found.slotFrame == item)
        #expect(found.tiedBy == .tieAndNewSlots)
        #expect(!found.slotWasInBaseline)
        #expect(found.isPostable(drawnAtSnapshot: false))
    }

    @Test func aSlotThatShrankBetweenTwoMatchedOnesIsNotNew() {
        // The middle slot lost 4 points and the new one (40) appeared right of all of them: the slot left of the shrunk one moved by the
        // move of the edge they share, which is less than the move of the shrunk slot's right edge.
        let old = slots([36, 34, 36])
        let after = slots([36, 30, 36, 40])
        #expect(ItemLocator.appearedSlots(since: old, in: after) == [after[3]])
    }

    @Test func aSlotLeftOfAShrinkThatNothingPushedBackIsNotMatched() {
        // The slots left of a slot that shrank move right, and a slot is never taken for one that moved right: nil, never a guess.
        #expect(ItemLocator.appearedSlots(since: slots([36, 34, 36]), in: slots([36, 30, 36])) == nil)
        // The slot of 36 that appeared left of everything pushes nothing: the same.
        #expect(ItemLocator.appearedSlots(since: slots([36, 34, 36]), in: slots([40, 36, 30, 36])) == nil)
    }

    @Test func aSlotNextToAnAnchorHasANeighbour() {
        // The first slot of a run is next to an anchor, and grew; the item's slot (40) appeared right of the run.
        #expect(ItemLocator.appearedSlots(since: slots([30, 36]), in: slots([34, 36, 40]), anchoredLeft: true) == [slots([34, 36, 40])[2]])
        #expect(ItemLocator.appearedSlots(since: slots([30, 36]), in: slots([34, 36, 40])) == nil, "with no anchor it is at the end of the bar")
        // The same at the other end of a run.
        #expect(ItemLocator.appearedSlots(since: slots([36, 30]), in: slots([40, 36, 34]), anchoredRight: true) == [slots([40, 36, 34])[0]])
        #expect(ItemLocator.appearedSlots(since: slots([36, 30]), in: slots([40, 36, 34])) == nil)
    }

    // MARK: What is read

    @Test func locateReadsOneWindowAndOneApp() async throws {
        let world = World(tempFrame: World.firstNew.insetBy(dx: 6, dy: 1))
        let slot = world.addSlot(World.firstNew)
        // A second window of the agent for the same display, whose slots are read by nobody, and an app that isn't asked.
        let other = world.ax.addAgentWindow(agent: agentPID, frame: bar)
        let otherSlot = world.ax.addSlot(in: other, identifier: "weather.temp", frame: World.firstNew)
        let scanner = world.scanner()

        #expect(await scanner.locate(temp, on: nil, since: nil)?.slotFrame == World.firstNew)

        #expect(world.ax.attributeReads(on: slot) > 0)
        #expect(world.ax.attributeReads(on: otherSlot) == 0, "one window of the display is read")
        #expect(world.ax.attributeReads(on: world.notesItem) == 0, "and only the item's app is asked")
        #expect(world.ax.attributeReads(on: world.temp) > 0)
    }

    @Test func locateAsksTheAppsOnTheBarAndNotTheConcealedOnesOrThoseWithNothingDrawn() async throws {
        let world = World(tempFrame: World.firstNew.insetBy(dx: 6, dy: 1))
        world.addSlot(World.firstNew)
        // A third app, concealed by the plan, with a slot on the bar; a fourth, whose items aren't drawn anywhere.
        let other = world.ax.addApp(pid: 1003, extras: [.init(title: "Other", identifier: "other.main", frame: CGRect(x: 3006, y: 1, width: 24, height: 28))])[0]
        world.addSlot(CGRect(x: 3000, y: 0, width: 36, height: 30), identifier: "other.main")
        let idle = world.ax.addApp(pid: 1004, extras: [.init(title: "Idle", identifier: "idle.main", frame: parked)])[0]
        let running = world.running + [.fake(1003, "com.example.other", "Other"), .fake(1004, "com.example.idle", "Idle")]
        let scanner = MenuBarScanner(ax: world.ax, runningApps: { running }, layout: { desk }, ownBundleID: InventoryFixtures.ownBundleID,
                                     isTrusted: { true }, clock: FakeClock(), readLimit: 8)
        _ = await scanner.scan(concealed: ["com.example.other"])
        let notesBefore = world.ax.attributeReads(on: world.notesItem)
        let otherBefore = world.ax.attributeReads(on: other)
        let idleBefore = world.ax.attributeReads(on: idle)

        #expect(await scanner.locate(temp, on: nil, since: nil)?.slotFrame == World.firstNew)

        #expect(world.ax.attributeReads(on: world.notesItem) > notesBefore, "an app with an item on the bar is asked, for the slot it claims")
        #expect(world.ax.attributeReads(on: other) == otherBefore, "a concealed app isn't")
        #expect(world.ax.attributeReads(on: idle) == idleBefore, "nor one with nothing drawn on this bar")
    }

    @Test func aNamedSlotIsToldWhileItsAppIsAmongTheConcealed() async throws {
        // The probe's real state: the item's app is the one the last scan was told the plan conceals.
        let reveal = try await Reveal.make(identifiers: ["weather.temp", "weather.alerts"], concealed: [weather])
        reveal.world.move(reveal.world.temp, to: World.firstNew.insetBy(dx: 6, dy: 1))

        let found = try #require(await reveal.scanner.locate(temp, on: nil, since: reveal.before))

        #expect(found.slotFrame == World.firstNew)
        #expect(found.tiedBy == .tieAndNewSlots)
        #expect(found.isPostable(drawnAtSnapshot: false))
    }

    @Test func aSlotToldByOrderIsFoundWhileItsAppIsAmongTheConcealed() async throws {
        let reveal = try await Reveal.make(World(items: 1), frames: [World.firstNew], concealed: [weather])
        reveal.world.move(reveal.world.temp, to: World.firstNew.insetBy(dx: 6, dy: 1))

        let found = try #require(await reveal.scanner.locate(temp, on: nil, since: reveal.before))

        #expect(found.slotFrame == World.firstNew)
        #expect(found.tiedBy == .tieAndNewSlots)
        #expect(!found.slotWasInBaseline)
        #expect(found.isPostable(drawnAtSnapshot: false))
    }
}
