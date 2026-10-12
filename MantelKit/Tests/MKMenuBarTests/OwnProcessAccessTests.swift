import ApplicationServices
import Foundation
import MKCore
import MKTestSupport
import Synchronization
import Testing

@testable import MKMenuBar

/// A stand-in for moving a call to the main thread: it counts the calls it was given, and says whether the calling thread is inside one
/// (reads of other apps go on at the same time on other threads, and are not inside it).
private final class RecordedHops: Sendable {
    private let state = Mutex((count: 0, inside: Set<Int>()))

    private static var thisThread: Int { Int(bitPattern: pthread_self()) }

    private let held = Mutex(0)
    func noteHeldBack() { held.withLock { $0 += 1 } }
    var heldBack: Int { held.withLock { $0 } }

    var count: Int { state.withLock { $0.count } }
    var isInside: Bool { state.withLock { $0.inside.contains(Self.thisThread) } }

    var runner: OwnProcessAccess.MainThreadRunner {
        { work in
            let thread = Self.thisThread
            self.state.withLock { $0.count += 1; $0.inside.insert(thread) }
            work()
            self.state.withLock { _ = $0.inside.remove(thread) }
        }
    }
}

/// What a fake tree was asked, and whether each ask was made inside a hop.
private struct Ask: Sendable {
    let id: Int
    let inHop: Bool
}

private final class Asks: Sendable {
    private let state = Mutex<[Ask]>([])

    func note(_ id: Int, inHop: Bool) { state.withLock { $0.append(Ask(id: id, inHop: inHop)) } }
    var all: [Ask] { state.withLock { $0 } }
}

/// A fake tree read the way `AXClient` reads the real one: each call is made through `OwnProcessAccess`.
private struct RoutedFakeAX: AXReading {
    let base: FakeAX
    let access: OwnProcessAccess

    func attribute(_ name: String, of element: AXElementRef) throws(AXReadError) -> AXValueBox {
        try access.call(about: element) { () throws(AXReadError) -> AXValueBox in try base.attribute(name, of: element) }
    }

    func children(of element: AXElementRef) throws(AXReadError) -> [AXElementRef] {
        try access.call(about: element) { () throws(AXReadError) -> [AXElementRef] in try base.children(of: element) }
    }

    func application(pid: pid_t) -> AXElementRef { base.application(pid: pid) }

    func press(_ element: AXElementRef) throws(AXReadError) {
        try access.call(about: element) { () throws(AXReadError) in try base.press(element) }
    }

    func attributeNames(of element: AXElementRef) throws(AXReadError) -> [String] {
        try access.call(about: element) { () throws(AXReadError) -> [String] in try base.attributeNames(of: element) }
    }
}

/// Everything about Mantel's own process is asked on the main thread, and nothing about any other. Nothing here asks the Accessibility
/// API anything but about a process that doesn't exist, or about this one with the call held back: the trees are fakes.
@Suite("Own process Accessibility", .timeLimit(.minutes(1)))
struct OwnProcessAccessTests {
    /// A fake tree with one app that is "this one", and one that is not, each with an extras menu bar of one item.
    private struct World {
        let ax = FakeAX()
        let ownRoot: Int
        let ownItem: Int
        let otherRoot: Int
        let otherItem: Int
        let hops = RecordedHops()
        let asks = Asks()

        init() {
            ownRoot = ax.root(ofApp: 100)
            ownItem = ax.addApp(pid: 100, extras: [FakeAX.Extra(title: "own", frame: CGRect(x: 10, y: 0, width: 20, height: 24))])[0]
            otherRoot = ax.root(ofApp: 200)
            otherItem = ax.addApp(pid: 200, extras: [FakeAX.Extra(title: "other", frame: CGRect(x: 40, y: 0, width: 20, height: 24))])[0]
        }

        /// The elements that are Mantel's: the app's root, its menu bar and its item.
        var ownIDs: Set<Int> {
            var ids: Set<Int> = [ownRoot, ownItem]
            if case .elements(let bars)? = try? ax.attribute(AXName.extrasMenuBar, of: ax.ref(ownRoot)), let bar = bars.first {
                ids.insert(ax.id(of: bar))
            }
            return ids
        }

        func reader() -> some AXReading {
            let ids = ownIDs
            let ax = ax, hops = hops, asks = asks
            ax.setOverride { id, _ in
                asks.note(id, inHop: hops.isInside)
                return nil
            }
            return RoutedFakeAX(base: ax, access: OwnProcessAccess(belongsToThisApp: { ids.contains(ax.id(of: $0)) }, runOnMainThread: hops.runner))
        }
    }

    // MARK: Which calls move

    @Test func everyKindOfCallAboutThisAppIsMadeOnTheMainThread() throws {
        let world = World()
        let reader = world.reader()
        let item = world.ax.ref(world.ownItem)

        _ = try reader.attribute(AXName.title, of: item)
        #expect(world.hops.count == 1)
        _ = try reader.children(of: world.ax.ref(world.ownRoot))
        #expect(world.hops.count == 2)
        _ = try reader.attributeNames(of: item)
        #expect(world.hops.count == 3)
        try reader.press(item)
        #expect(world.hops.count == 4)
        #expect(world.ax.pressed == [world.ownItem], "and the press did reach the element")
    }

    @Test func theReadsOfThisAppAreMadeInsideTheHopAndNothingElseIs() throws {
        let world = World()
        let reader = world.reader()

        _ = try reader.attribute(AXName.title, of: world.ax.ref(world.ownItem))
        _ = try reader.attribute(AXName.title, of: world.ax.ref(world.otherItem))
        let asks = world.asks.all
        #expect(asks.filter { $0.id == world.ownItem }.allSatisfy { $0.inHop })
        #expect(asks.filter { $0.id == world.ownItem }.count == 1)
        #expect(asks.filter { $0.id == world.otherItem }.allSatisfy { !$0.inHop })
        #expect(asks.filter { $0.id == world.otherItem }.count == 1)
    }

    @Test func aCallAboutAnotherAppIsMadeWhereItIs() throws {
        let world = World()
        let reader = world.reader()
        let item = world.ax.ref(world.otherItem)

        #expect(try reader.attribute(AXName.title, of: item) == .string("other"))
        _ = try reader.children(of: world.ax.ref(world.otherRoot))
        _ = try reader.attributeNames(of: item)
        try reader.press(item)
        #expect(world.hops.count == 0)
        #expect(world.ax.pressed == [world.otherItem])
    }

    @Test func makingAnElementAsksNobodyAndIsNotMoved() {
        let world = World()
        let reader = world.reader()
        let element = reader.application(pid: 100)
        #expect(element == world.ax.application(pid: 100))
        #expect(world.hops.count == 0)
    }

    // MARK: What comes back

    @Test func whatTheCallAnswersComesBackAsItWas() throws {
        let world = World()
        let reader = world.reader()
        #expect(try reader.attribute(AXName.title, of: world.ax.ref(world.ownItem)) == .string("own"))
        #expect(try reader.attribute(AXName.position, of: world.ax.ref(world.ownItem)) == .point(CGPoint(x: 10, y: 0)))
        let bar = try reader.attribute(AXName.extrasMenuBar, of: world.ax.ref(world.ownRoot))
        guard case .elements(let bars) = bar else {
            Issue.record("no menu bar")
            return
        }
        #expect(try reader.children(of: #require(bars.first)) == [world.ax.ref(world.ownItem)])
    }

    @Test func anErrorOfTheCallComesBackAsItWasAndNotAsAnotherKind() {
        for error in [AXReadError.timeout, .notTrusted, .noValue, .failure(-25205)] {
            let world = World()
            world.ax.failReads(on: world.ownItem, with: error)
            let reader = world.reader()
            #expect(throws: error) { try reader.attribute(AXName.title, of: world.ax.ref(world.ownItem)) }
            #expect(throws: error) { try reader.children(of: world.ax.ref(world.ownItem)) }
            #expect(world.hops.count == 2, "\(error)")
        }
        let world = World()
        world.ax.failPress(on: world.ownItem, with: .timeout)
        let reader = world.reader()
        #expect(throws: AXReadError.timeout) { try reader.press(world.ax.ref(world.ownItem)) }
    }

    // MARK: The real client

    @Test func aClientBuiltWithTheDefaultProcessCheckRoutesCallsAboutThisProcessThroughTheRunner() {
        // The runner holds the call back: nothing reaches the Accessibility API, and the call is a failure, not a value.
        let hops = RecordedHops()
        let held: OwnProcessAccess.MainThreadRunner = { _ in hops.noteHeldBack() }
        let client = AXClient(ownProcess: OwnProcessAccess(runOnMainThread: held))
        let own = AXElementRef(AXUIElementCreateApplication(getpid()))

        #expect(throws: AXReadError.failure(AXError.cannotComplete.rawValue)) { try client.attribute(AXName.role, of: own) }
        #expect(throws: AXReadError.failure(AXError.cannotComplete.rawValue)) { try client.children(of: own) }
        #expect(throws: AXReadError.failure(AXError.cannotComplete.rawValue)) { try client.attributeNames(of: own) }
        #expect(throws: AXReadError.failure(AXError.cannotComplete.rawValue)) { try client.press(own) }
        #expect(hops.heldBack == 4, "each call about this process went to the runner, by the client's own default of what this process is")
        // Making an element is not a call.
        #expect(client.application(pid: getpid()) == own)
        #expect(hops.heldBack == 4)
    }

    @Test func aClientBuiltWithTheDefaultProcessCheckMakesCallsAboutAnotherProcessWhereItIs() {
        // A process ID no process has, so that the call reaches nobody and fails at once. The runner is never asked.
        let hops = RecordedHops()
        let held: OwnProcessAccess.MainThreadRunner = { _ in hops.noteHeldBack() }
        let client = AXClient(ownProcess: OwnProcessAccess(runOnMainThread: held))
        let nobody = AXElementRef(AXUIElementCreateApplication(2_000_000_000))
        _ = try? client.attribute(AXName.role, of: nobody)
        _ = try? client.attributeNames(of: nobody)
        #expect(hops.heldBack == 0)
    }

    // MARK: In a scan

    @Test func aScanReadsMantelsOwnItemsOnTheMainThreadAndNoOnesElse() async {
        let fixture = InventoryFixtures.desk()
        let ownPID = fixture.running.first { $0.bundleID == InventoryFixtures.ownBundleID }?.pid
        guard let ownPID else {
            Issue.record("the desk has no Mantel")
            return
        }
        // What is Mantel's: its root, its menu bar and the items in it.
        let root = fixture.ax.root(ofApp: ownPID)
        var ownIDs: Set<Int> = [root]
        if case .elements(let bars)? = try? fixture.ax.attribute(AXName.extrasMenuBar, of: fixture.ax.ref(root)), let bar = bars.first {
            ownIDs.insert(fixture.ax.id(of: bar))
            for item in (try? fixture.ax.children(of: bar)) ?? [] { ownIDs.insert(fixture.ax.id(of: item)) }
        }
        #expect(ownIDs.count == 4, "the root, the menu bar and Mantel's two dots")

        let hops = RecordedHops()
        let asks = Asks()
        fixture.ax.setOverride { id, _ in
            asks.note(id, inHop: hops.isInside)
            return nil
        }
        let ids = ownIDs, ax = fixture.ax
        let reader = RoutedFakeAX(base: fixture.ax,
                                  access: OwnProcessAccess(belongsToThisApp: { ids.contains(ax.id(of: $0)) }, runOnMainThread: hops.runner))
        let layout = fixture.layout
        let scanner = MenuBarScanner(ax: reader, runningApps: { fixture.running }, layout: { layout }, ownBundleID: InventoryFixtures.ownBundleID,
                                     isTrusted: { true }, clock: FakeClock())
        let inventory = await scanner.scan()

        #expect(inventory.items(ofApp: InventoryFixtures.ownBundleID).count == 2, "Mantel's items are still read")
        let own = asks.all.filter { ownIDs.contains($0.id) }
        let others = asks.all.filter { !ownIDs.contains($0.id) }
        #expect(!own.isEmpty)
        #expect(own.allSatisfy { $0.inHop }, "every read of Mantel's own items was made inside a hop")
        #expect(!others.isEmpty)
        #expect(others.allSatisfy { !$0.inHop }, "no read of anyone else's was")
    }

    // MARK: The real hop

    @Test func theRealRunnerRunsTheWorkOnTheMainThreadWhicheverThreadAsks() async {
        let ran = await Task.detached { () -> (ran: Bool, onMain: Bool, askedFromMain: Bool) in
            var ran = false
            var onMain = false
            let askedFromMain = pthread_main_np() != 0
            OwnProcessAccess.runOnMainThread {
                ran = true
                onMain = pthread_main_np() != 0
            }
            return (ran, onMain, askedFromMain)
        }.value
        #expect(ran.ran)
        #expect(!ran.askedFromMain)
        #expect(ran.onMain)
    }

    @MainActor
    @Test func theRealRunnerDoesNotWaitForItselfOnTheMainThread() {
        var ran = false
        OwnProcessAccess.runOnMainThread { ran = true }
        #expect(ran)
    }

    @Test func anElementOfAnotherProcessIsNotThisProcesses() {
        #expect(OwnProcessAccess.isThisProcess(AXElementRef(AXUIElementCreateApplication(getpid()))))
        #expect(!OwnProcessAccess.isThisProcess(AXElementRef(AXUIElementCreateApplication(getpid() + 1))))
    }
}
