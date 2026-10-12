import CoreGraphics
import Foundation
import MKCommands
import MKCore
import MKLayout
import MKTestSupport
import Synchronization

@testable import MKMenuBar

/// A menu bar that changes as it is told to, for the tests of `MenuBarSession`: the synthetic desk (`InventoryFixtures`) in which what
/// an allowlist doesn't name is concealed, and, on the laptop's full bar, only so many icons fit.
///
/// - **Hiding.** The apps that the live allowlist doesn't name, among the ones that are running, have no frame in the bar (the way the
///   fixtures make a concealed app). It follows the allowlist at once, and for an app that starts after the allowlist was made too: an
///   assertion hides whatever isn't on it.
/// - **Room.** On a bar that is piled (the laptop's), the icons that are on the bar at once are at most `capacity` of the third-party
///   ones, counted from the right (Mantel's own two dots among them); the others are piled at the «. A concealed app takes no room.
/// - **Time.** Nothing here has a clock: a scan reads what the world is when it reads.
///
/// The slots are, left to right: the weather app's two, the notes app's, the VPN app's, the sync app's two, Mantel's two, and the test
/// item's two (while it is running).
final class SessionWorld: Sendable {
    enum Shape: Sendable {
        case desk, laptop, deskWithLaptopOpen
    }

    static let agent = MenuBarReader.menuBarAgentBundleID
    static let own = InventoryFixtures.ownBundleID
    static let weather = InventoryFixtures.weather
    static let notes = InventoryFixtures.notes
    static let vpn = InventoryFixtures.vpn
    static let sync = InventoryFixtures.sync
    static let testItem = InventoryFixtures.testItemBundleID

    private struct State {
        var shape: Shape
        var testItemRunning: Bool
        /// Whether MenuBarAgent is among the apps the scanner is told are running.
        var agentRunning = true
        var capacity: Int?
        /// The system modules whose slots macOS parks off the bar.
        var parkedModules: Set<String> = []
        var hiddenNow: @Sendable () -> Set<String> = { [] }
        /// The apps the session is told are running; nil for every one the fixture has.
        var planRunning: Set<String>?
        /// Mantel's dots are the left-most icons (`InventoryFixtures.Options.ownItemsFirst`).
        var ownFirst = false
        /// An icon that doesn't fit has no slot and there is no «, as on macOS 27 (`InventoryFixtures.Options.undrawnOverflow`).
        var undrawn = false
        /// An app that is concealed reports the place it had on the bar (`InventoryFixtures.Options.concealedKeepTheirPlace`).
        var staleConcealed = false
        /// Apps that say they are left of the notch whatever is done to them (`InventoryFixtures.Options.staleApps`).
        var staleApps: Set<String> = []
        var stalePlaceX: CGFloat = 484
        /// The bars (by their place among the displays) that a full-screen app has hidden.
        var hiddenBars: Set<Int> = []
        /// How many times the window list has been read.
        var windowReads = 0
        var cache: (key: String, fixture: InventoryFixtures.Fixture)?
    }

    private let state: Mutex<State>

    init(shape: Shape = .desk, testItem: Bool = false, capacity: Int? = nil, ownFirst: Bool = false, undrawn: Bool = false,
         staleConcealed: Bool = false) {
        state = Mutex(State(shape: shape, testItemRunning: testItem, capacity: capacity, ownFirst: ownFirst, undrawn: undrawn,
                            staleConcealed: staleConcealed))
    }

    // MARK: Changing the world

    /// Which apps the allowlist leaves out, among the ones that are running now.
    func setHiddenProvider(_ provider: @escaping @Sendable () -> Set<String>) {
        state.withLock { $0.hiddenNow = provider }
    }

    func setCapacity(_ capacity: Int?) { state.withLock { $0.capacity = capacity } }
    /// The system modules whose slots have a frame that is off the bar, whatever is applied (macOS parks an icon it isn't drawing).
    func setParked(_ modules: Set<String>) { state.withLock { $0.parkedModules = modules } }
    func setStaleApps(_ apps: Set<String>, from x: CGFloat = 484) { state.withLock { $0.staleApps = apps; $0.stalePlaceX = x } }
    func setShape(_ shape: Shape) { state.withLock { $0.shape = shape } }
    /// Whether the bar of the display (by its place among the displays) is on screen: a full-screen app hides it.
    func setBarShown(_ index: Int, _ shown: Bool) {
        state.withLock { if shown { $0.hiddenBars.remove(index) } else { $0.hiddenBars.insert(index) } }
    }
    func setTestItemRunning(_ running: Bool) { state.withLock { $0.testItemRunning = running } }
    /// Whether MenuBarAgent is running as far as the scanner can tell: without it a read finds no bar, and says the agent isn't there.
    func setAgentRunning(_ running: Bool) { state.withLock { $0.agentRunning = running } }
    /// The apps the session's list of running apps has (the fixture's own apps all keep their icons in the bar).
    func setPlanRunning(_ apps: Set<String>?) { state.withLock { $0.planRunning = apps } }

    // MARK: Reading it

    /// The bundle IDs of the apps that are running, MenuBarAgent and Mantel among them.
    var runningBundleIDs: [String] {
        let (testItem, planRunning) = state.withLock { ($0.testItemRunning, $0.planRunning) }
        let all = [Self.agent, Self.own, Self.weather, Self.notes, Self.vpn, Self.sync] + (testItem ? [Self.testItem] : [])
        return planRunning.map { running in all.filter(running.contains) } ?? all
    }

    var layout: DisplayLayout { fixture().layout }

    /// The windows on screen: the window server's own window at the main menu's level for each bar that isn't hidden.
    var windowList: any WindowListReading { WorldWindows(world: self) }

    /// How many times the window list has been read.
    var windowReads: Int { state.withLock { $0.windowReads } }

    fileprivate func shownBarWindows() -> [WindowInfo] {
        let hidden = state.withLock { state -> Set<Int> in
            state.windowReads += 1
            return state.hiddenBars
        }
        return fixture().bars.enumerated().filter { !hidden.contains($0.offset) }.map { index, rect in
            WindowInfo(number: 9000 + index, ownerPID: 1, ownerBundleID: nil, layer: WindowLevels.mainMenu, bounds: rect, alpha: 1)
        }
    }

    /// Every app the scanner is to ask: all of the fixture's (the agent too, while it is running).
    var scannerApps: [RunningApp] {
        let agentRunning = state.withLock { $0.agentRunning }
        return fixture().running.filter { agentRunning || $0.bundleID != Self.agent }
    }

    /// The apps the session is told are running.
    var sessionApps: [RunningApp] {
        let ids = Set(runningBundleIDs)
        return fixture().running.filter { $0.bundleID.map(ids.contains) ?? false }
    }

    func app(_ bundleID: String) -> RunningApp {
        fixture().running.first { $0.bundleID == bundleID }!
    }

    var ax: any AXReading { WorldAX(world: self) }

    /// The apps that are concealed now.
    var concealed: Set<String> {
        let provider = state.withLock { $0.hiddenNow }
        return provider()
    }

    func fixture() -> InventoryFixtures.Fixture {
        // Asked outside the lock: it reads the allowlist, which asks the world which apps run.
        let hidden = concealed
        return state.withLock { state in
            let key = "\(state.shape)|\(state.ownFirst)|\(state.undrawn)|\(state.staleConcealed)|\(state.staleApps.sorted().joined(separator: ","))|\(state.stalePlaceX)|\(state.testItemRunning)|\(state.capacity.map(String.init) ?? "-")|\(hidden.sorted().joined(separator: ","))|\(state.parkedModules.sorted().joined(separator: ","))"
            if let cached = state.cache, cached.key == key { return cached.fixture }

            let leftToRight = state.ownFirst
                ? [Self.own, Self.own, Self.weather, Self.weather, Self.notes, Self.vpn, Self.sync, Self.sync]
                : [Self.weather, Self.weather, Self.notes, Self.vpn, Self.sync, Self.sync, Self.own, Self.own]
            let order = leftToRight + (state.testItemRunning ? [Self.testItem, Self.testItem] : [])
            let visible = Self.slotsOnAFullBar(order: order, concealed: hidden, capacity: state.capacity)
            let options = InventoryFixtures.Options(concealed: hidden, includeTestItem: state.testItemRunning, visibleOnPileBar: visible,
                                                    parkedSystemModules: state.parkedModules, ownItemsFirst: state.ownFirst,
                                                    undrawnOverflow: state.undrawn, concealedKeepTheirPlace: state.staleConcealed,
                                                    staleApps: state.staleApps, stalePlaceX: state.stalePlaceX)
            let fixture: InventoryFixtures.Fixture = switch state.shape {
            case .desk: InventoryFixtures.desk(options)
            case .laptop: InventoryFixtures.laptop(options)
            case .deskWithLaptopOpen: InventoryFixtures.deskWithLaptopOpen(options)
            }
            state.cache = (key, fixture)
            return fixture
        }
    }

    /// How many slots, counted from the right, a full bar shows: as many as it takes to have `capacity` that aren't concealed.
    private static func slotsOnAFullBar(order: [String], concealed: Set<String>, capacity: Int?) -> Int {
        guard let capacity else { return order.count }
        var count = 0
        var counted = 0
        for owner in order.reversed() {
            count += 1
            if !concealed.contains(owner) {
                counted += 1
                if counted == capacity { break }
            }
        }
        return count
    }
}

/// The windows on screen in a world: a bar that isn't hidden has the window server's window for it.
struct WorldWindows: WindowListReading {
    let world: SessionWorld

    func onScreenWindows() -> [WindowInfo] { world.shownBarWindows() }
}

/// Accessibility that reads whichever tree the world has now. A scan makes its elements as it goes, so each one sees one tree whole as
/// long as the world doesn't change in the middle of it.
struct WorldAX: AXReading {
    let world: SessionWorld

    private var current: FakeAX { world.fixture().ax }

    func attribute(_ name: String, of element: AXElementRef) throws(AXReadError) -> AXValueBox {
        try current.attribute(name, of: element)
    }

    func children(of element: AXElementRef) throws(AXReadError) -> [AXElementRef] {
        try current.children(of: element)
    }

    func application(pid: pid_t) -> AXElementRef { current.application(pid: pid) }
    func press(_ element: AXElementRef) throws(AXReadError) { try current.press(element) }
    func attributeNames(of element: AXElementRef) throws(AXReadError) -> [String] { try current.attributeNames(of: element) }
}

/// Reads an app's items, after waiting at a gate while a test holds one: a read of the menu bar that is under way and doesn't finish.
///
/// An app's items are read from the world as it is when the read begins, whatever it has become by the time the gate is open: the read
/// that was held up is of a bar that has since changed, as a read that took its time is.
final class HoldableExtras: AppExtrasReading {
    private let world: SessionWorld
    private let hold = Mutex<Gate?>(nil)
    private let held = Mutex(0)

    init(world: SessionWorld) {
        self.world = world
    }

    /// Reads that begin from now on wait at the gate (none wait for nil).
    func holdReads(at gate: Gate?) { hold.withLock { $0 = gate } }

    /// How many reads have come to a gate, whether they have been let through since or not.
    var readsHeld: Int { held.withLock { $0 } }

    func read(_ app: RunningApp) async -> ExtrasOutcome {
        let tree = world.fixture().ax
        if let gate = hold.withLock({ $0 }) {
            held.withLock { $0 += 1 }
            await gate.wait()
        }
        return AppExtrasReader(ax: tree).read(app)
    }
}

/// The section models the session saved, in order.
final class SavedSections: Sendable {
    private let models = Mutex<[SectionModel]>([])

    var all: [SectionModel] { models.withLock { $0 } }
    var latest: SectionModel? { models.withLock { $0.last } }
    func save(_ model: SectionModel) { models.withLock { $0.append(model) } }
}

/// What the session is told about the apps macOS has turned off, which a test can change.
final class TurnedOffBox: Sendable {
    private let list = Mutex<TurnedOffList>(.apps([]))
    private let asked = Mutex(0)
    private let hold = Mutex<Gate?>(nil)
    private let held = Mutex(0)

    /// Questions that come from now on wait at the gate before they are answered (none wait for nil).
    func holdQuestions(at gate: Gate?) { hold.withLock { $0 = gate } }

    /// How many questions have come to a gate, whether they have been let through since or not.
    var questionsHeld: Int { held.withLock { $0 } }

    /// What the session's question waits at, if a test holds one.
    func passGate() async {
        guard let gate = hold.withLock({ $0 }) else { return }
        held.withLock { $0 += 1 }
        await gate.wait()
    }

    var current: TurnedOffList {
        asked.withLock { $0 += 1 }
        return list.withLock { $0 }
    }

    /// The answer to a question: the source's, when a test gave one (a real engine over a fake home folder), else the list.
    func answer() async -> TurnedOffList {
        await passGate()
        if let source = source.withLock({ $0 }) {
            asked.withLock { $0 += 1 }
            return await source()
        }
        return current
    }

    private let source = Mutex<(@Sendable () async -> TurnedOffList)?>(nil)

    /// Questions are answered by `source` from now on.
    func follow(_ source: @escaping @Sendable () async -> TurnedOffList) { self.source.withLock { $0 = source } }

    /// How many times the session has asked.
    var timesAsked: Int { asked.withLock { $0 } }
    func set(_ new: TurnedOffList) { list.withLock { $0 = new } }
}

/// A section model with these apps placed (each as the person's own choice), and where new apps go.
func sections(shown: [String] = [], hidden: [String] = [], alwaysHidden: [String] = [], newItems: MenuBarSection = .shown) -> SectionModel {
    var model = SectionModel()
    model.newItems = newItems
    for app in shown { model.move(app: app, to: .shown) }
    for app in hidden { model.move(app: app, to: .hidden) }
    for app in alwaysHidden { model.move(app: app, to: .alwaysHidden) }
    return model
}

/// A session over the world, with the allowlist fake in charge of hiding, so that what the allowlist is asked can be seen, and what the
/// bar then shows is the world's.
struct SessionRig {
    let world: SessionWorld
    let clock: FakeClock
    /// What happened, in order: `scan` for each read of the bar, `apply` for each allowlist made live.
    let events: CallLog
    let allowlist: FakeAllowlist?
    let extras: HoldableExtras
    let saved: SavedSections
    let turnedOff: TurnedOffBox
    let hiding: HidingController
    let session: MenuBarSession

    static let flush: Duration = .milliseconds(100)

    /// How many reads a started session has taken: the one with everything on the bar, and the one of the bar once it is collapsed.
    static let readsAtStart = 2

    /// A session whose engine is the allowlist, over a fake allowlist that conceals in the world what it doesn't name.
    ///
    /// With a `world` of an earlier rig, the bar is as that one left it, and the new allowlist is one that has never been made live:
    /// what a session that went without putting anything back left behind is gone with it.
    static func withAllowlist(world existing: SessionWorld? = nil, shape: SessionWorld.Shape = .desk, testItem: Bool = false,
                              capacity: Int? = nil, ownFirst: Bool = false, undrawn: Bool = false, staleConcealed: Bool = false,
                              sections initial: SectionModel = SectionModel(),
                              settings: HidingSettings = HidingSettings(), confirmationWait: Duration = .seconds(2),
                              trusted: Switch = Switch(true)) -> SessionRig {
        let world = existing ?? SessionWorld(shape: shape, testItem: testItem, capacity: capacity, ownFirst: ownFirst, undrawn: undrawn,
                                                   staleConcealed: staleConcealed)
        let events = CallLog()
        let fake = FakeAllowlist(hidden: HiddenApps(), everyApp: { world.runningBundleIDs })
        world.setHiddenProvider { [world] in
            // An assertion hides whatever isn't on it, apps that start later included.
            guard fake.live > 0, let last = fake.calls.last else { return [] }
            return Set(world.runningBundleIDs).subtracting(last.bundleIDs)
        }
        fake.onActivated { events.add("apply") }
        let engine = AllowlistEngine(allowlist: fake, ownBundleID: SessionWorld.own, isInstalledCopy: true)
        let clock = FakeClock()
        let hiding = HidingController(engines: [.allowlist: engine], clock: clock, confirm: { _ in .seen })
        return make(world: world, clock: clock, events: events, allowlist: fake, hiding: hiding, sections: initial, settings: settings,
                    confirmationWait: confirmationWait, trusted: trusted)
    }

    /// A session over engines that only note what they were asked, and the world in which nothing is ever concealed.
    static func withEngines(_ engines: [HidingEngineKind: any HidingEngine], shape: SessionWorld.Shape = .desk, testItem: Bool = false,
                            capacity: Int? = nil, ownFirst: Bool = false, sections initial: SectionModel = SectionModel(),
                            settings: HidingSettings = HidingSettings(), events: CallLog = CallLog()) -> SessionRig {
        let world = SessionWorld(shape: shape, testItem: testItem, capacity: capacity, ownFirst: ownFirst)
        let clock = FakeClock()
        let hiding = HidingController(engines: engines, clock: clock, confirm: { _ in .seen })
        return make(world: world, clock: clock, events: events, allowlist: nil, hiding: hiding, sections: initial, settings: settings,
                    confirmationWait: .seconds(2), trusted: Switch(true))
    }

    private static func make(world: SessionWorld, clock: FakeClock, events: CallLog, allowlist: FakeAllowlist?, hiding: HidingController,
                             sections initial: SectionModel, settings: HidingSettings, confirmationWait: Duration,
                             trusted: Switch) -> SessionRig {
        let extras = HoldableExtras(world: world)
        let scanner = MenuBarScanner(ax: world.ax, extrasReader: extras, runningApps: { world.scannerApps }, layout: { world.layout },
                                     ownBundleID: SessionWorld.own, isTrusted: {
            events.add("scan")
            return trusted.isOn
        }, clock: clock)
        let saved = SavedSections()
        let turnedOff = TurnedOffBox()
        let session = MenuBarSession(scanner: scanner, hiding: hiding, runningApps: { world.sessionApps },
                                     loadSections: { initial }, saveSections: { saved.save($0) },
                                     turnedOff: { await turnedOff.answer() },
                                     settings: settings, ownBundleID: SessionWorld.own, clock: clock, windows: world.windowList,
                                     confirmationWait: confirmationWait)
        return SessionRig(world: world, clock: clock, events: events, allowlist: allowlist, extras: extras, saved: saved,
                          turnedOff: turnedOff, hiding: hiding, session: session)
    }

    // MARK: Driving the session

    /// Lets a read that waits for the others that come with it (100 ms) go: waits until the clock has one more sleeper than the ones
    /// a started session always has (the polling, and the minute's trial), and moves the clock by the wait.
    func letTheCoalescedReadGo(sleepers: Int = 3) async -> Bool {
        guard await clock.waitForSleepers(sleepers, within: .seconds(5)) else { return false }
        clock.advance(by: Self.flush)
        return true
    }

    /// Returns once this many reads have been taken in; false if they aren't within five seconds.
    func waitForReads(_ count: Int) async -> Bool {
        let session = session
        let enough = await withinTimeLimit(.seconds(5)) {
            while await session.scansIngested < count {
                guard (try? await Task.sleep(for: .milliseconds(1))) != nil else { return false }
            }
            return true
        }
        return enough ?? false
    }

    /// Lets coalesced reads go, one after the other, until this many are in. For a step that asks for them without waiting.
    func pumpUntilReads(_ count: Int) async -> Bool {
        let session = session
        let result = await withinTimeLimit(.seconds(10)) {
            while await session.scansIngested < count {
                if clock.sleeperCount >= 3 { clock.advance(by: Self.flush) }
                guard (try? await Task.sleep(for: .milliseconds(1))) != nil else { return false }
            }
            return true
        }
        return result ?? false
    }

    /// Moves the clock by `step` (100 ms unless said) each time something sleeps on it besides the session's two (the polling, the
    /// minute's trial), until `done` holds. For a call that waits on the clock. False if it doesn't hold within ten seconds.
    func driveClock(step: Duration = SessionRig.flush, until done: @escaping @Sendable () -> Bool) async -> Bool {
        let clock = clock
        let result = await withinTimeLimit(.seconds(10)) {
            while !done() {
                if await clock.waitForSleepers(3, within: .milliseconds(20)) { clock.advance(by: step) }
            }
            return true
        }
        return result ?? false
    }

    /// The latest state the session published.
    var state: MenuBarState? {
        get async { await session.lastPublished }
    }
}
