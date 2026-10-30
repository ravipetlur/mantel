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
///   ones, counted from the right (Mantel's own two dots among them); the others are piled at the «. A concealed app keeps its room and has
///   no slot (`InventoryFixtures`), so what slides when it comes back is nothing: it comes back into its own room.
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
        /// No third-party app names its items or its slots, as on macOS 27; Mantel and the test item do (`InventoryFixtures.Options.unnamedApps`).
        var nameless = false
        /// Apps that say they are left of the notch whatever is done to them (`InventoryFixtures.Options.staleApps`).
        var staleApps: Set<String> = []
        var stalePlaceX: CGFloat = 484
        /// Apps whose frames are reported this many points right of where their icons are (`InventoryFixtures.Options.frameShifts`).
        var frameShifts: [String: CGFloat] = [:]
        /// The items left to right (`InventoryFixtures.Options.itemOrder`).
        var itemOrder: [String]?
        /// Items of Mantel's own the app lists besides the dots, and dots it doesn't (`InventoryFixtures.Options.ownExtras`, `ownOmitted`).
        var ownExtras: [String] = []
        var ownOmitted: Set<String> = []
        /// The bars (by their place among the displays) that a full-screen app has hidden.
        var hiddenBars: Set<Int> = []
        /// Apps whose icons macOS doesn't tie to them: while an assertion is live they get no slot, whatever it names; with none live they
        /// are drawn.
        var unattached: Set<String> = []
        /// Apps that are running and aren't asked by the scanner, so that they list no item and don't fail to answer.
        var withoutItems: Set<String> = []
        /// How many times each app was relaunched: the session is told another process ID for it (the scanner asks by the fixture's).
        var relaunches: [String: Int] = [:]
        /// Other processes of an app that run under its bundle ID and list no item (a helper), by bundle ID.
        var helpers: [String: pid_t] = [:]
        /// MenuBarAgent doesn't answer the list of its windows (a busy Mac): a read finds no bar.
        var windowsHung = false
        var slotsHung = false
        /// The slot of this item (by its app and its title) doesn't say where it is: its position and size time out.
        var hungSlotFrame: (bundleID: String, title: String)?
        /// MenuBarAgent has been started again: it is another process.
        var agentRestarted = false
        /// How many times the readers were told the app is quitting.
        var stopWaitingCalls = 0
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
    /// The apps' own frames are reported this far right of their icons from now on (the slots don't move): stale ones, or one app's in
    /// the place of its neighbour's.
    func setFrameShifts(_ shifts: [String: CGFloat]) { state.withLock { $0.frameShifts = shifts } }
    /// The items are drawn in this order from now on (`InventoryFixtures.Options.itemOrder`); nil is the fixture's own.
    func setItemOrder(_ order: [String]?) { state.withLock { $0.itemOrder = order } }
    /// Mantel's own items the app lists from now on: the spacers, groups and divider that are on the bar (by name), and the dots that aren't.
    func setOwnItems(listed: [String], omitted: Set<String> = []) { state.withLock { $0.ownExtras = listed; $0.ownOmitted = omitted } }
    func setShape(_ shape: Shape) { state.withLock { $0.shape = shape } }
    /// No third-party app names its items, in its own list or on its slots, from now on (every app on macOS 27 is like that); Mantel's items
    /// and the test item's keep their names.
    func setNameless(_ nameless: Bool) { state.withLock { $0.nameless = nameless } }
    /// Whether the bar of the display (by its place among the displays) is on screen: a full-screen app hides it.
    func setBarShown(_ index: Int, _ shown: Bool) {
        state.withLock { if shown { $0.hiddenBars.remove(index) } else { $0.hiddenBars.insert(index) } }
    }
    /// The apps whose icons get no slot while an assertion is live (`SessionRig.withAllowlist` makes them concealed then).
    func setUnattached(_ apps: Set<String>) { state.withLock { $0.unattached = apps } }
    var unattachedApps: Set<String> { state.withLock { $0.unattached } }
    /// The app quits and starts again: from now on the session sees it as another process.
    func relaunch(_ bundleID: String) { state.withLock { $0.relaunches[bundleID, default: 0] += 1 } }
    func setTestItemRunning(_ running: Bool) { state.withLock { $0.testItemRunning = running } }
    /// Whether MenuBarAgent is running as far as the scanner can tell: without it a read finds no bar, and says the agent isn't there.
    func setAgentRunning(_ running: Bool) { state.withLock { $0.agentRunning = running } }
    /// Whether MenuBarAgent doesn't answer the list of its windows, though it runs: a read finds no bar, as one that timed out does.
    func setWindowsHung(_ hung: Bool) { state.withLock { $0.windowsHung = hung } }
    var windowsHung: Bool { state.withLock { $0.windowsHung } }
    var slotsHung: Bool { state.withLock { $0.slotsHung } }
    var hungSlotFrame: (bundleID: String, title: String)? { state.withLock { $0.hungSlotFrame } }
    /// MenuBarAgent is started again (a reset, or the system doing it): the scanner sees another process by its name, and the windows it
    /// draws are the new process's (`ownerPID(of:)`, and `WorldAX.application(pid:)` for the new process ID).
    func restartAgent() { state.withLock { $0.agentRestarted = true } }
    /// How far a restarted MenuBarAgent's process ID is from the first one's.
    private static let restartedAgentShift: pid_t = 7000
    func noteStopWaiting() { state.withLock { $0.stopWaitingCalls += 1 } }
    var stopWaitingCalls: Int { state.withLock { $0.stopWaitingCalls } }
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
        let (agentRunning, withoutItems, helpers, restarted) = state.withLock { ($0.agentRunning, $0.withoutItems, $0.helpers, $0.agentRestarted) }
        return fixture().running.filter { (agentRunning || $0.bundleID != Self.agent) && !($0.bundleID.map(withoutItems.contains) ?? false) }
            .map { app in
                guard restarted, app.bundleID == Self.agent else { return app }
                return RunningApp(pid: app.pid + Self.restartedAgentShift, bundleID: app.bundleID, name: app.name, bundleURL: app.bundleURL,
                                  isBackgroundOnly: app.isBackgroundOnly)
            }
            + helpers.map { RunningApp.fake($0.value, $0.key, "Helper") }
    }

    /// The apps the session is told are running.
    var sessionApps: [RunningApp] {
        let ids = Set(runningBundleIDs)
        let (relaunches, helpers) = state.withLock { ($0.relaunches, $0.helpers) }
        return helpers.map { RunningApp.fake($0.value, $0.key, "Helper") } + fixture().running.filter { $0.bundleID.map(ids.contains) ?? false }.map { app in
            guard let count = app.bundleID.flatMap({ relaunches[$0] }) else { return app }
            return RunningApp(pid: app.pid + 1000 * pid_t(count), bundleID: app.bundleID, name: app.name, bundleURL: app.bundleURL,
                              isBackgroundOnly: app.isBackgroundOnly)
        }
    }

    func app(_ bundleID: String) -> RunningApp {
        fixture().running.first { $0.bundleID == bundleID }!
    }

    var ax: any AXReading { WorldAX(world: self) }

    /// The process whose tree the element is in (`FakeAX.ownerPID(of:)`); once MenuBarAgent was started again, the new process for the
    /// elements of its windows and slots.
    func ownerPID(of element: AXElementRef) -> pid_t? {
        let tree = fixture().ax
        guard let pid = tree.ownerPID(of: element) else { return nil }
        return pid == agentTreePID && agentRestarted ? pid + Self.restartedAgentShift : pid
    }

    /// The application element of the process, in the tree: MenuBarAgent's own once it was started again, whose windows are the same
    /// ones as before (the process draws the bars again, as they were). The first process is gone then, and has nothing of the tree.
    func treeApplication(pid: pid_t, in tree: FakeAX) -> AXElementRef {
        guard agentRestarted, let agent = agentTreePID else { return tree.application(pid: pid) }
        if pid == agent { return tree.application(pid: Self.goneProcessPID) }
        return pid == agent + Self.restartedAgentShift ? tree.application(pid: agent) : tree.application(pid: pid)
    }

    /// A process ID that no app has: its application element in the tree is an empty one.
    private static let goneProcessPID: pid_t = -1

    private var agentRestarted: Bool { state.withLock { $0.agentRestarted } }
    private var agentTreePID: pid_t? { fixture().pid(of: Self.agent) }

    /// The apps that are concealed now.
    var concealed: Set<String> {
        let provider = state.withLock { $0.hiddenNow }
        return provider()
    }

    func fixture() -> InventoryFixtures.Fixture {
        // Asked outside the lock: it reads the allowlist, which asks the world which apps run.
        let hidden = concealed
        return state.withLock { state in
            let key = "\(state.nameless)|\(state.shape)|\(state.ownFirst)|\(state.undrawn)|\(state.staleConcealed)|\(state.staleApps.sorted().joined(separator: ","))|\(state.stalePlaceX)|\(state.frameShifts.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ","))|\(state.itemOrder?.joined(separator: ",") ?? "-")|\(state.ownExtras.joined(separator: ","))|\(state.ownOmitted.sorted().joined(separator: ","))|\(state.testItemRunning)|\(state.capacity.map(String.init) ?? "-")|\(hidden.sorted().joined(separator: ","))|\(state.parkedModules.sorted().joined(separator: ","))"
            if let cached = state.cache, cached.key == key { return cached.fixture }

            let leftToRight = state.ownFirst
                ? [Self.own, Self.own, Self.weather, Self.weather, Self.notes, Self.vpn, Self.sync, Self.sync]
                : [Self.weather, Self.weather, Self.notes, Self.vpn, Self.sync, Self.sync, Self.own, Self.own]
            let order = leftToRight + (state.testItemRunning ? [Self.testItem, Self.testItem] : [])
            let visible = Self.slotsOnAFullBar(order: order, concealed: hidden, capacity: state.capacity)
            let options = InventoryFixtures.Options(concealed: hidden, includeTestItem: state.testItemRunning, visibleOnPileBar: visible,
                                                    parkedSystemModules: state.parkedModules, ownItemsFirst: state.ownFirst,
                                                    undrawnOverflow: state.undrawn, concealedKeepTheirPlace: state.staleConcealed,
                                                    staleApps: state.staleApps, stalePlaceX: state.stalePlaceX, frameShifts: state.frameShifts,
                                                    itemOrder: state.itemOrder, ownExtras: state.ownExtras, ownOmitted: state.ownOmitted,
                                                    unnamedApps: state.nameless)
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
        if name == AXName.windows, world.windowsHung { throw .timeout }
        if name == AXName.description, world.slotsHung { throw .timeout }
        if name == AXName.position || name == AXName.size, hangsFrame(of: element) { throw .timeout }
        return try current.attribute(name, of: element)
    }

    /// Whether this is the slot that is told not to say where it is: the one at the place its app's item of that title is, six points to the
    /// left (the apps list their items about six points inside their slots, as the fixture has it). Other displays' slots are elsewhere.
    private func hangsFrame(of element: AXElementRef) -> Bool {
        guard let (bundleID, title) = world.hungSlotFrame, let pid = current.ownerPID(of: element) else { return false }
        let fixture = world.fixture()
        guard pid == fixture.pid(of: SessionWorld.agent) else { return false }
        for node in fixture.extrasNodes(of: bundleID) {
            let item = current.ref(node)
            guard case .string(title)? = try? current.attribute(AXName.title, of: item),
                  case .point(let itemOrigin)? = try? current.attribute(AXName.position, of: item),
                  case .point(let origin)? = try? current.attribute(AXName.position, of: element) else { continue }
            return abs(origin.x - (itemOrigin.x - 6)) < 1
        }
        return false
    }

    func children(of element: AXElementRef) throws(AXReadError) -> [AXElementRef] {
        try current.children(of: element)
    }

    func application(pid: pid_t) -> AXElementRef { world.treeApplication(pid: pid, in: current) }
    func press(_ element: AXElementRef) throws(AXReadError) { try current.press(element) }
    func attributeNames(of element: AXElementRef) throws(AXReadError) -> [String] { try current.attributeNames(of: element) }
    func stopWaiting() { world.noteStopWaiting() }
}

/// Reads an app's items, after waiting at a gate while a test holds one: a read of the menu bar that is under way and doesn't finish.
///
/// An app's items are read from the world as it is when the read begins, whatever it has become by the time the gate is open: the read
/// that was held up is of a bar that has since changed, as a read that took its time is.
final class HoldableExtras: AppExtrasReading {
    private let world: SessionWorld
    private let hold = Mutex<Gate?>(nil)
    private let held = Mutex(0)
    private let asked = Mutex<[String]>([])
    private let rewrite = Mutex<(@Sendable (ExtrasOutcome, RunningApp) -> ExtrasOutcome)?>(nil)

    /// What an app's answer is made into before the scanner has it (a name that didn't come in time, a second process listing): nil
    /// leaves them as they are.
    func rewriteAnswers(_ body: (@Sendable (ExtrasOutcome, RunningApp) -> ExtrasOutcome)?) { rewrite.withLock { $0 = body } }

    /// The apps that don't answer, by bundle ID, and for how many more reads (nil for as long as they are told to).
    private let silent = Mutex<[String: Int?]>([:])

    init(world: SessionWorld) {
        self.world = world
    }

    /// The app doesn't answer in time for its next `reads` reads (for ever with nil): a busy Mac.
    func stopAnswering(_ bundleID: String, forReads reads: Int? = nil) { silent.withLock { $0[bundleID] = .some(reads) } }
    func startAnswering(_ bundleID: String) { silent.withLock { $0[bundleID] = nil } }

    /// Reads that begin from now on wait at the gate (none wait for nil).
    func holdReads(at gate: Gate?) { hold.withLock { $0 = gate } }

    /// How many reads have come to a gate, whether they have been let through since or not.
    var readsHeld: Int { held.withLock { $0 } }

    /// The apps asked (by bundle ID) since the last time this was asked to forget.
    var appsAsked: [String] { asked.withLock { $0 } }
    func forgetAppsAsked() { asked.withLock { $0 = [] } }

    private let onNextRead = Mutex<(@Sendable () -> Void)?>(nil)

    /// Runs this once, as the next read of an app begins (before it reads the world): the bar changes while the apps are being asked.
    func runOnNextRead(_ body: @escaping @Sendable () -> Void) { onNextRead.withLock { $0 = body } }

    private let slowApp = Mutex<(seconds: TimeInterval, clock: FakeClock, bundleID: String)?>(nil)

    /// This app takes this long, on the clock, to answer each read: a read whose scope has less time left than that is cut where its time
    /// ends, and comes back timed out (a busy Mac, as `PatientAX` makes of it).
    func answerAfter(_ seconds: TimeInterval, on clock: FakeClock, app bundleID: String) {
        slowApp.withLock { $0 = (seconds, clock, bundleID) }
    }

    func read(_ app: RunningApp) async -> ExtrasOutcome {
        if let slow = slowApp.withLock({ $0 }), app.bundleID == slow.bundleID {
            let left = AXReadScope.current?.timeLeft ?? .infinity
            if left < slow.seconds {
                slow.clock.advance(by: .seconds(left))
                return .timedOut
            }
            slow.clock.advance(by: .seconds(slow.seconds))
        }
        onNextRead.withLock { hook -> (@Sendable () -> Void)? in defer { hook = nil }; return hook }?()
        asked.withLock { $0.append(app.bundleID ?? "") }
        let doesntAnswer = silent.withLock { silent -> Bool in
            guard let bundleID = app.bundleID, let entry = silent[bundleID] else { return false }
            if let left = entry {
                silent[bundleID] = left > 1 ? .some(left - 1) : nil
            }
            return true
        }
        if doesntAnswer { return .timedOut }
        let tree = world.fixture().ax
        if let gate = hold.withLock({ $0 }) {
            held.withLock { $0 += 1 }
            await gate.wait()
        }
        let outcome = AppExtrasReader(ax: tree).read(app)
        return rewrite.withLock { $0 }?(outcome, app) ?? outcome
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
                              trusted: Switch = Switch(true), sessionState: any SessionStateSource = SteadySessionState(),
                              otherEngines: [HidingEngineKind: any HidingEngine] = [:],
                              recordsChecked: @escaping @Sendable (String, SectionModel.Reconciled) async -> SettingsMoved = { _, _ in SettingsMoved() },
                              reading: ((SessionWorld, FakeClock) -> any AXReading)? = nil) -> SessionRig {
        let world = existing ?? SessionWorld(shape: shape, testItem: testItem, capacity: capacity, ownFirst: ownFirst, undrawn: undrawn,
                                                   staleConcealed: staleConcealed)
        let events = CallLog()
        let fake = FakeAllowlist(hidden: HiddenApps(), everyApp: { world.runningBundleIDs })
        world.setHiddenProvider { [world] in
            // An assertion hides whatever isn't on it, apps that start later included.
            guard fake.live > 0, let last = fake.calls.last else { return [] }
            return Set(world.runningBundleIDs).subtracting(last.bundleIDs).union(world.unattachedApps)
        }
        fake.onActivated { events.add("apply") }
        let engine = AllowlistEngine(allowlist: fake, ownBundleID: SessionWorld.own, isInstalledCopy: true)
        let clock = FakeClock()
        let engines: [HidingEngineKind: any HidingEngine] = otherEngines.merging([.allowlist: engine]) { _, new in new }
        let hiding = HidingController(engines: engines, clock: clock, confirm: { _ in .seen })
        return make(world: world, clock: clock, events: events, allowlist: fake, hiding: hiding, sections: initial, settings: settings,
                    confirmationWait: confirmationWait, trusted: trusted, sessionState: sessionState, recordsChecked: recordsChecked,
                    reading: reading)
    }

    /// A session over engines that only note what they were asked, and the world in which nothing is ever concealed.
    static func withEngines(_ engines: [HidingEngineKind: any HidingEngine], shape: SessionWorld.Shape = .desk, testItem: Bool = false,
                            capacity: Int? = nil, ownFirst: Bool = false, sections initial: SectionModel = SectionModel(),
                            settings: HidingSettings = HidingSettings(), events: CallLog = CallLog(),
                            sessionState: any SessionStateSource = SteadySessionState()) -> SessionRig {
        let world = SessionWorld(shape: shape, testItem: testItem, capacity: capacity, ownFirst: ownFirst)
        let clock = FakeClock()
        let hiding = HidingController(engines: engines, clock: clock, confirm: { _ in .seen })
        return make(world: world, clock: clock, events: events, allowlist: nil, hiding: hiding, sections: initial, settings: settings,
                    confirmationWait: .seconds(2), trusted: Switch(true), sessionState: sessionState)
    }

    private static func make(world: SessionWorld, clock: FakeClock, events: CallLog, allowlist: FakeAllowlist?, hiding: HidingController,
                             sections initial: SectionModel, settings: HidingSettings, confirmationWait: Duration,
                             trusted: Switch, sessionState: any SessionStateSource,
                             recordsChecked: @escaping @Sendable (String, SectionModel.Reconciled) async -> SettingsMoved = { _, _ in SettingsMoved() },
                             reading: ((SessionWorld, FakeClock) -> any AXReading)? = nil) -> SessionRig {
        let extras = HoldableExtras(world: world)
        let scanner = MenuBarScanner(ax: reading?(world, clock) ?? world.ax, extrasReader: extras, runningApps: { world.scannerApps }, layout: { world.layout },
                                     ownBundleID: SessionWorld.own, isTrusted: {
            events.add("scan")
            return trusted.isOn
        }, clock: clock, readLimit: 8)
        let saved = SavedSections()
        let turnedOff = TurnedOffBox()
        let session = MenuBarSession(scanner: scanner, hiding: hiding, runningApps: { world.sessionApps },
                                     loadSections: { initial }, saveSections: { saved.save($0) },
                                     turnedOff: { await turnedOff.answer() },
                                     settings: settings, ownBundleID: SessionWorld.own, clock: clock, windows: world.windowList,
                                     confirmationWait: confirmationWait, sessionState: sessionState, recordsChecked: recordsChecked)
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
