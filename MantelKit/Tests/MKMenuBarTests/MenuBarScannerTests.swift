import CoreGraphics
import Foundation
import MKCore
import MKTestSupport
import Synchronization
import Testing

@testable import MKMenuBar

private typealias Fixture = InventoryFixtures.Fixture

private let mainUUID = DisplayFixtures.deskMain.uuid
private let laptopUUID = DisplayFixtures.laptopRightOfDesk.uuid

/// An app's items are read after the app has taken its time, on the test's clock.
private struct LatentExtrasReader: AppExtrasReading {
    let base: AppExtrasReader
    let clock: any Clock
    let latency: [String: Duration]

    func read(_ app: RunningApp) async -> ExtrasOutcome {
        if let wait = app.bundleID.flatMap({ latency[$0] }) { try? await clock.sleep(for: wait) }
        return base.read(app)
    }
}

/// Accessibility that reads one fake tree or another, whichever is current: for a test where the menu bar changes between two scans.
/// Elements are only passed on within a scan, and a scan makes its own, so each scan sees one tree whole.
private struct SwitchingAX: AXReading {
    let first: FakeAX
    let second: FakeAX
    let useFirst: Switch

    private var current: FakeAX { useFirst.isOn ? first : second }

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

/// An app's items are read when the test lets them be: every read waits at a gate, and is counted when it begins.
private struct GatedExtrasReader: AppExtrasReading {
    let base: AppExtrasReader
    let gate: Gate
    let started: ReadCounter

    func read(_ app: RunningApp) async -> ExtrasOutcome {
        started.increment()
        await gate.wait()
        return base.read(app)
    }
}

private final class ReadCounter: Sendable {
    private let count = Mutex(0)
    func increment() { count.withLock { $0 += 1 } }
    var value: Int { count.withLock { $0 } }
}

/// Notes which apps were asked, and answers as the fixture does unless an outcome was given for the app.
private final class RecordingExtrasReader: AppExtrasReading {
    private let base: AppExtrasReader
    private let outcomes: [String: ExtrasOutcome]
    private let asked = Mutex<[String]>([])

    init(_ fixture: Fixture, outcomes: [String: ExtrasOutcome] = [:]) {
        base = AppExtrasReader(ax: fixture.ax)
        self.outcomes = outcomes
    }

    var askedApps: [String] { asked.withLock { $0 } }

    func read(_ app: RunningApp) async -> ExtrasOutcome {
        let bundleID = app.bundleID ?? ""
        asked.withLock { $0.append(bundleID) }
        return outcomes[bundleID] ?? base.read(app)
    }
}

private func makeScanner(_ fixture: Fixture, running: (@Sendable () -> [RunningApp])? = nil, clock: any Clock = FakeClock(),
                         trusted: @escaping @Sendable () -> Bool = { true },
                         latency: [String: Duration]? = nil) -> MenuBarScanner {
    let apps = running ?? { fixture.running }
    let layout = fixture.layout
    if let latency {
        return MenuBarScanner(ax: fixture.ax, extrasReader: LatentExtrasReader(base: AppExtrasReader(ax: fixture.ax), clock: clock, latency: latency),
                              runningApps: apps, layout: { layout }, ownBundleID: InventoryFixtures.ownBundleID,
                              isTrusted: trusted, clock: clock, readLimit: 8)
    }
    return MenuBarScanner(ax: fixture.ax, runningApps: apps, layout: { layout },
                          ownBundleID: InventoryFixtures.ownBundleID, isTrusted: trusted, clock: clock)
}

/// The agent and the apps with these bundle IDs.
private func running(_ fixture: Fixture, only bundleIDs: Set<String>) -> [RunningApp] {
    fixture.running.filter { $0.bundleID == MenuBarReader.menuBarAgentBundleID || ($0.bundleID.map(bundleIDs.contains) ?? false) }
}

/// One scan of the desk in which only this app is asked, taking `latency` of the test's clock to answer; and what the scan says of the
/// app's reach. Alone, so that what the clock says is what its own read took.
private func reachOfAloneApp(_ bundleID: String, latency: Duration? = nil, prepare: (Fixture) -> Void = { _ in }) async -> AppReach? {
    let fixture = InventoryFixtures.desk()
    prepare(fixture)
    let clock = FakeClock()
    let list = running(fixture, only: [bundleID])
    let scanner = makeScanner(fixture, running: { list }, clock: clock, latency: latency.map { [bundleID: $0] } ?? [:])
    let scan = Task { await scanner.scan() }
    if let latency {
        guard await clock.waitForSleepers(1, within: .seconds(5)) else {
            scan.cancel()
            return nil
        }
        clock.advance(by: latency)
    }
    return await scan.value.reach.first { $0.bundleID == bundleID }
}

@Suite("Menu bar scanner", .timeLimit(.minutes(1)))
struct MenuBarScannerTests {
    @Test func aScanReadsTheMenuBarIntoAnInventory() async throws {
        let fixture = InventoryFixtures.desk()
        let scanner = makeScanner(fixture)
        let inventory = await scanner.scan()
        #expect(inventory.problems.isEmpty)
        #expect(inventory.items.count == 17)
        #expect(inventory.bars.map(\.displayUUID) == [mainUUID, DisplayFixtures.deskPortrait.uuid])
        #expect(inventory.agentAnswered)
        #expect(await scanner.agentFailureStreak == 0)
        // The same as the matcher makes of a snapshot, which is what a probe sees.
        let read = await MenuBarReader(ax: fixture.ax, runningApps: { fixture.running }, clock: FakeClock())
            .snapshot(layout: fixture.layout, includeRawTree: false)
        var memory = IndexMemory()
        let viaSnapshot = InventoryMatcher.match(read.matchInput(ownBundleID: InventoryFixtures.ownBundleID), memory: &memory)
        #expect(inventory.items == viaSnapshot.items)
        // Each app that answered is in the reach, none of them slow: Mantel's and the test item's among them.
        #expect(inventory.reach.map(\.bundleID).sorted() == [InventoryFixtures.ownBundleID, InventoryFixtures.testItemBundleID, InventoryFixtures.notes,
                                                             InventoryFixtures.sync, InventoryFixtures.vpn, InventoryFixtures.weather].sorted())
        #expect(inventory.reach.allSatisfy { $0.status == .fine })
        #expect(inventory.items(ofApp: InventoryFixtures.ownBundleID).allSatisfy { $0.isMantel })
    }

    @Test func namesSurviveAnIdentifierTimeout() async {
        // The slots carry no names, so the weather app's items are told by what the app itself calls them. One scan in which it is slow to
        // say them leaves them what they were: not items told by their place instead, which are other items to the layout and to the pictures.
        let fixture = InventoryFixtures.desk(.init(stripThirdPartyNames: true))
        let scanner = makeScanner(fixture)
        let named = await scanner.scan().items(ofApp: InventoryFixtures.weather).map(\.id)
        #expect(named == [ItemID(bundleID: InventoryFixtures.weather, key: .identifier("weather.temp")),
                          ItemID(bundleID: InventoryFixtures.weather, key: .identifier("weather.alerts"))])

        let nodes = Set(fixture.extrasNodes(of: InventoryFixtures.weather))
        fixture.ax.setOverride { id, name in nodes.contains(id) && name == AXName.identifier ? .failure(.timeout) : nil }
        let slow = await scanner.scan()
        #expect(slow.items(ofApp: InventoryFixtures.weather).map(\.id) == named)
        #expect(slow.reach.first { $0.bundleID == InventoryFixtures.weather }?.status == .slow, "it is slow all the same")
    }

    // MARK: Which apps are asked

    @Test func helperBundlesAreNeverAsked() async {
        let fixture = InventoryFixtures.desk()
        // Apps that would each cost a wait for an answer: nothing in them answers.
        let helpers: [RunningApp] = [.fake(2001, "com.apple.WebKit.WebContent", "Web Content"), .fake(2002, "com.apple.WebKit.Networking", "Networking"),
                                     .fake(2003, "com.apple.Virtualization.VirtualMachine", "Virtual Machine"),
                                     .fake(2004, "com.apple.universalcontrol", "Universal Control")]
        let quiet = RunningApp.fake(2005, "com.example.quiet", "Quiet")
        for app in helpers + [quiet] { fixture.ax.failReads(on: fixture.ax.root(ofApp: app.pid), with: .timeout) }
        let all = fixture.running + helpers + [quiet]
        let scanner = makeScanner(fixture, running: { all })

        let inventory = await scanner.scan()
        for helper in helpers {
            #expect(fixture.ax.attributeReads(on: fixture.ax.root(ofApp: helper.pid)) == 0, "\(helper.bundleID ?? "") wasn't asked")
        }
        #expect(fixture.ax.attributeReads(on: fixture.ax.root(ofApp: quiet.pid)) > 0, "an app that isn't a helper is")
        #expect(!inventory.reach.contains { $0.bundleID.hasPrefix("com.apple.") })
        #expect(HelperBundles.isHelper("com.apple.WebKit.GPU"))
        #expect(HelperBundles.isHelper("com.apple.Virtualization.Installation"))
        #expect(HelperBundles.isHelper("com.apple.universalcontrol"))
        #expect(!HelperBundles.isHelper("com.apple.Safari"))
        #expect(!HelperBundles.isHelper("com.apple.WebKit"))
        #expect(!HelperBundles.isHelper("com.example.universalcontrol"))
    }

    @Test func noExtrasIsCachedThenRecheckedAfterAMinute() async {
        let fixture = InventoryFixtures.desk()
        let quiet = RunningApp.fake(2005, "com.example.quiet", "Quiet")
        let root = fixture.ax.root(ofApp: quiet.pid)
        let all = fixture.running + [quiet]
        let clock = FakeClock()
        let scanner = makeScanner(fixture, running: { all }, clock: clock)

        _ = await scanner.scan()
        let first = fixture.ax.attributeReads(on: root)
        #expect(first > 0)
        _ = await scanner.scan()
        #expect(fixture.ax.attributeReads(on: root) == first, "asked once")
        clock.advance(by: .seconds(59))
        _ = await scanner.scan()
        #expect(fixture.ax.attributeReads(on: root) == first, "still not, at 59 seconds")
        clock.advance(by: .seconds(2))
        _ = await scanner.scan()
        #expect(fixture.ax.attributeReads(on: root) > first, "asked again after a minute")

        // The answer is kept for the process: when the app gets a menu bar item, it is found at the next check.
        fixture.ax.addApp(pid: quiet.pid, extras: [.init(title: "Late", identifier: "late.item", frame: CGRect(x: 3000, y: 0, width: 30, height: 30))])
        clock.advance(by: .seconds(61))
        let inventory = await scanner.scan()
        #expect(inventory.reach.contains { $0.bundleID == "com.example.quiet" })
    }

    @Test func anAppThatQuitIsForgotten() async {
        let fixture = InventoryFixtures.desk()
        let quiet = RunningApp.fake(2005, "com.example.quiet", "Quiet")
        let root = fixture.ax.root(ofApp: quiet.pid)
        let alone = fixture.running
        let both = fixture.running + [quiet]
        let apps = Switch(true)
        let scanner = makeScanner(fixture, running: { apps.isOn ? both : alone })
        _ = await scanner.scan()
        let first = fixture.ax.attributeReads(on: root)
        apps.set(false)
        _ = await scanner.scan()
        apps.set(true)
        _ = await scanner.scan()
        #expect(fixture.ax.attributeReads(on: root) > first, "what was kept of the process went with it")
    }

    @Test func threeTimeoutsSkipForThirtySeconds() async {
        let fixture = InventoryFixtures.desk()
        let hung = RunningApp.fake(2006, "com.example.hung", "Hung")
        let root = fixture.ax.root(ofApp: hung.pid)
        fixture.ax.failReads(on: root, with: .timeout)
        let all = fixture.running + [hung]
        let clock = FakeClock()
        let scanner = makeScanner(fixture, running: { all }, clock: clock)
        func reach(_ inventory: Inventory) -> ReachStatus? { inventory.reach.first { $0.bundleID == "com.example.hung" }?.status }

        // Asked each time, and each time it timed out.
        var reads = 0
        for attempt in 1...3 {
            let inventory = await scanner.scan()
            #expect(reach(inventory) == .timedOut, "scan \(attempt)")
            #expect(fixture.ax.attributeReads(on: root) > reads, "asked in scan \(attempt)")
            reads = fixture.ax.attributeReads(on: root)
            #expect(inventory.items(ofApp: "com.example.hung").isEmpty)
        }
        // Three in a row: left alone.
        let fourth = await scanner.scan()
        #expect(reach(fourth) == .skipped)
        #expect(fourth.reach.first { $0.bundleID == "com.example.hung" }?.readMs == 0)
        #expect(fixture.ax.attributeReads(on: root) == reads, "not asked")
        clock.advance(by: .seconds(29))
        #expect(reach(await scanner.scan()) == .skipped)
        #expect(fixture.ax.attributeReads(on: root) == reads)
        // Thirty seconds on, it is asked again, and is skipped again at once if it is still not answering.
        clock.advance(by: .seconds(2))
        let again = await scanner.scan()
        #expect(reach(again) == .timedOut)
        #expect(fixture.ax.attributeReads(on: root) > reads)
        reads = fixture.ax.attributeReads(on: root)
        #expect(reach(await scanner.scan()) == .skipped)
        #expect(fixture.ax.attributeReads(on: root) == reads)

        // The other apps are not slowed by it.
        #expect(fourth.items.count == 17)
    }

    @Test func aTimeoutThatIsFollowedByAnAnswerStartsTheCountAgain() async {
        let fixture = InventoryFixtures.desk()
        let flaky = RunningApp.fake(2006, "com.example.flaky", "Flaky")
        let root = fixture.ax.root(ofApp: flaky.pid)
        let all = fixture.running + [flaky]
        let scanner = makeScanner(fixture, running: { all })
        for _ in 1...2 {
            fixture.ax.failReads(on: root, with: .timeout)
            _ = await scanner.scan()
        }
        fixture.ax.failReads(on: root, with: nil)
        fixture.ax.addApp(pid: flaky.pid, extras: [.init(title: "Back", identifier: "flaky.item", frame: nil)])
        _ = await scanner.scan()
        // Two more timeouts after the answer are two in a row, not four.
        for _ in 1...2 {
            fixture.ax.failReads(on: root, with: .timeout)
            let inventory = await scanner.scan()
            #expect(inventory.reach.first { $0.bundleID == "com.example.flaky" }?.status == .timedOut)
        }
        let reads = fixture.ax.attributeReads(on: root)
        _ = await scanner.scan()
        #expect(fixture.ax.attributeReads(on: root) > reads, "a third one is asked: it isn't skipped until three in a row")
    }

    // MARK: Accessibility

    @Test func accessibilityCheckIsLive() async {
        // The grant can be given or taken away while Mantel runs: the check is made on every scan.
        let fixture = InventoryFixtures.desk()
        let trusted = Switch(true)
        let scanner = makeScanner(fixture, trusted: { trusted.isOn })
        let agentRoot = fixture.ax.root(ofApp: InventoryFixtures.agentPID)

        let first = await scanner.scan()
        #expect(first.problems.isEmpty)
        #expect(!first.items.isEmpty)

        trusted.set(false)
        let reads = fixture.ax.attributeReads(on: agentRoot)
        let second = await scanner.scan()
        #expect(second.problems == [.accessibilityNotGranted])
        #expect(second.items.isEmpty)
        #expect(second.bars.isEmpty)
        #expect(fixture.ax.attributeReads(on: agentRoot) == reads, "nothing is read without it")

        trusted.set(true)
        let third = await scanner.scan()
        #expect(third.problems.isEmpty)
        #expect(third.items == first.items)
    }

    @Test func accessibilityRefusedByTheSystemIsTheSameProblem() async {
        let fixture = InventoryFixtures.desk()
        fixture.ax.failReads(on: fixture.ax.root(ofApp: InventoryFixtures.agentPID), with: .notTrusted)
        let inventory = await makeScanner(fixture).scan()
        #expect(inventory.problems == [.accessibilityNotGranted])
        #expect(inventory.items.isEmpty)
    }

    @Test func oneAppRefusingIsNotMantelUngranted() async {
        // Apple's authentication agent answers every read with "API disabled", whoever asks. Mantel has the grant: that app refuses.
        let fixture = InventoryFixtures.desk()
        let refuser = RunningApp.fake(2007, "com.example.refuser", "Refuser")
        let root = fixture.ax.root(ofApp: refuser.pid)
        fixture.ax.failReads(on: root, with: .notTrusted)
        let all = fixture.running + [refuser]
        let clock = FakeClock()
        let scanner = makeScanner(fixture, running: { all }, clock: clock)
        func reach(_ inventory: Inventory) -> AppReach? { inventory.reach.first { $0.bundleID == "com.example.refuser" } }

        let first = await scanner.scan()
        #expect(first.problems.isEmpty, "no problem is Mantel's")
        #expect(reach(first)?.status == .refused)
        #expect(first.unansweredApps.contains("com.example.refuser"), "what it has or hasn't says nothing")
        #expect(first.items.count == 17, "the other apps are read")
        let reads = fixture.ax.attributeReads(on: root)
        #expect(reads > 0)

        // Left alone as an app with no items is, and still said to refuse while it is.
        let second = await scanner.scan()
        #expect(reach(second)?.status == .refused)
        #expect(reach(second)?.readMs == 0)
        #expect(fixture.ax.attributeReads(on: root) == reads, "not asked again")
        clock.advance(by: .seconds(59))
        #expect(reach(await scanner.scan())?.status == .refused)
        #expect(fixture.ax.attributeReads(on: root) == reads, "not at 59 seconds")
        clock.advance(by: .seconds(2))
        let third = await scanner.scan()
        #expect(fixture.ax.attributeReads(on: root) > reads, "asked again after a minute")
        #expect(third.problems.isEmpty)
    }

    @Test func untrustedStillReportsNotGranted() async {
        // The grant is checked before the apps are asked, and a read that says no after the grant was taken away is the grant.
        let fixture = InventoryFixtures.desk()
        let refuser = RunningApp.fake(2007, "com.example.refuser", "Refuser")
        fixture.ax.failReads(on: fixture.ax.root(ofApp: refuser.pid), with: .notTrusted)
        let all = fixture.running + [refuser]

        let gone = await makeScanner(fixture, running: { all }, trusted: { false }).scan()
        #expect(gone.problems == [.accessibilityNotGranted])
        #expect(gone.reach.isEmpty)

        let asked = Mutex(0)
        let revoked = makeScanner(fixture, running: { all }, trusted: { asked.withLock { $0 += 1; return $0 == 1 } })
        let during = await revoked.scan()
        #expect(during.problems == [.accessibilityNotGranted], "taken away while the apps were asked")
        #expect(!during.reach.contains { $0.status == .refused })
    }

    // MARK: Bars

    @Test func barGeometryComesFromAgentWindow() async throws {
        // 30 points on the externals and 33 on the notched built-in screen, which is what MenuBarAgent's windows are and not what the
        // displays' visible frames leave (31 and 34).
        let fixture = InventoryFixtures.deskWithLaptopOpen()
        let layout = fixture.layout
        #expect(try #require(layout.main).frame.maxY - DisplayFixtures.deskMain.visibleFrame.maxY == 31)
        #expect(DisplayFixtures.laptopRightOfDesk.frame.maxY - DisplayFixtures.laptopRightOfDesk.visibleFrame.maxY == 34)

        let inventory = await makeScanner(fixture).scan()
        #expect(inventory.bars.map(\.height) == [30, 30, 33])
        #expect(inventory.bars.map(\.rect) == fixture.bars)
        #expect(inventory.bars[0].rect == CGRect(x: 0, y: 0, width: 3360, height: 30))
        #expect(inventory.bars[1].rect == CGRect(x: -1800, y: -491, width: 1800, height: 30))
        #expect(inventory.bars[2].rect == CGRect(x: 3360, y: 773, width: 1728, height: 33))
        // The notch is the display's, in CoreGraphics points: 185 by 32, at the top of the laptop's bar.
        #expect(inventory.bars[2].notch == CGRect(x: 4131.5, y: 773, width: 185, height: 32))
        #expect(inventory.bars[0].notch == nil && inventory.bars[1].notch == nil)
    }

    @Test func aDisplayWithoutAWindowHasNoBar() async {
        let fixture = InventoryFixtures.desk()
        // MenuBarAgent has windows for the main display only: the portrait one has none (as when its bar is gone).
        let layout = DisplayLayout(displays: [DisplayFixtures.deskMain])
        let scanner = MenuBarScanner(ax: fixture.ax, runningApps: { fixture.running }, layout: { layout },
                                     ownBundleID: InventoryFixtures.ownBundleID, isTrusted: { true }, clock: FakeClock())
        let inventory = await scanner.scan()
        #expect(inventory.bars.map(\.displayUUID) == [mainUUID])
        #expect(inventory.problems.isEmpty)
    }

    @Test func ambiguousSpaceNeedsTwoThoroughScansInARow() async throws {
        let fixture = InventoryFixtures.desk(.init(windowsPerDisplay: 2))
        let scanner = makeScanner(fixture)
        // A slot of the main display's second window is moved, so that its two windows no longer agree about where their slots are.
        let slot = try #require(try fixture.ax.children(of: fixture.ax.ref(fixture.windows[0][1])).first.map(fixture.ax.id(of:)))
        guard case .point(let original)? = try? fixture.ax.attribute(AXName.position, of: fixture.ax.ref(slot)) else {
            Issue.record("the slot has a position")
            return
        }
        func move() { fixture.ax.setAttribute(AXName.position, .point(CGPoint(x: original.x + 40, y: original.y)), on: slot) }
        func putBack() { fixture.ax.setAttribute(AXName.position, .point(original), on: slot) }

        // They disagree once and agree again: a clock tick that moved the slots of one window a moment before the other's. No doubt.
        move()
        #expect(await scanner.scan(reasons: [.refresh]).problems.isEmpty)
        putBack()
        #expect(await scanner.scan(reasons: [.refresh]).problems.isEmpty)

        // They disagree at two thorough scans in a row: it is a doubt, and the first of the windows is used all the same.
        move()
        #expect(await scanner.scan(reasons: [.refresh]).problems.isEmpty)
        let second = await scanner.scan(reasons: [.displaysChanged])
        #expect(second.problems == [.ambiguousSpace])
        #expect(second.items.count == 17)
        // An ordinary scan doesn't look: it says what the last thorough one found.
        #expect(await scanner.scan(reasons: [.poll]).problems == [.ambiguousSpace])
        // They agree at the next thorough scan, and it is over.
        putBack()
        #expect(await scanner.scan(reasons: [.refresh]).problems.isEmpty)
        #expect(await scanner.scan(reasons: [.poll]).problems.isEmpty)
    }

    @Test func deficientFirstWindowIsNotUsed() async {
        // The first window of each display has no names on its third-party slots, and the apps' own lists give no identifiers either.
        // The scan uses the window that has the names (the items are `#n` whichever it is: a slot's name is no item's).
        let full = await makeScanner(InventoryFixtures.desk(.init(windowsWithoutNames: [], appsReportIdentifiers: false))).scan()
        let deficient = InventoryFixtures.desk(.init(windowsWithoutNames: [0], appsReportIdentifiers: false))
        let result = await makeScanner(deficient).scan()
        #expect(slotNames(of: result).contains("weather.temp"))
        #expect(result == full)
        #expect(deficient.slotReads(ofWindow: deficient.windows[0][1]) > 0, "it read on to the second window")
    }

    /// The names the slots of the bars carry in a read: what the window that was used has. (An item's ID doesn't come from them.)
    private func slotNames(of inventory: Inventory) -> Set<String> {
        Set(inventory.barSlots.values.joined().compactMap(\.name))
    }

    /// How many times the slots of each of a display's windows have been read, for the windows in the order MenuBarAgent lists them.
    private func slotReads(_ fixture: Fixture, display: Int = 0) -> [Int] {
        fixture.windows[display].map { fixture.slotReads(ofWindow: $0) }
    }

    /// The windows of a display whose slots were read between two counts.
    private func windowsRead(_ before: [Int], _ after: [Int]) -> Set<Int> {
        Set(zip(before, after).enumerated().filter { $0.element.1 > $0.element.0 }.map(\.offset))
    }

    @Test func anOrdinaryScanReadsTheBestWindowAndOneMoreInTurn() async {
        // The best window of a display is read at every ordinary scan, and one other, a different one each time, so that none is left
        // unlooked at for long. A scan that has all the windows to choose from compares nothing.
        let fixture = InventoryFixtures.desk(.init(windowsPerDisplay: 5, windowsWithoutNames: []))
        let scanner = makeScanner(fixture)
        _ = await scanner.scan(reasons: [.refresh])
        var last = slotReads(fixture)
        #expect(last.allSatisfy { $0 > 0 }, "the thorough scan read every window")
        // All the windows are as good, so the first is the best; the others are looked at in order, and then again from the first.
        for other in [1, 2, 3, 4, 1] {
            _ = await scanner.scan(reasons: [.poll])
            let now = slotReads(fixture)
            #expect(windowsRead(last, now) == [0, other], "looked at \(other)")
            last = now
        }
    }

    @Test func theReasonsForAThoroughScanReadEveryWindow() async {
        let fixture = InventoryFixtures.desk(.init(windowsPerDisplay: 5))
        let scanner = makeScanner(fixture)
        _ = await scanner.scan(reasons: [.refresh])
        // Each of the reasons for a thorough scan reads them all again, however the others in it ask.
        for reason in [ScanScheduler.Reason.displaysChanged, .refresh] {
            let before = slotReads(fixture) + slotReads(fixture, display: 1)
            _ = await scanner.scan(reasons: [reason, .poll])
            #expect(zip(before, slotReads(fixture) + slotReads(fixture, display: 1)).allSatisfy { $1 > $0 }, "\(reason)")
        }
        // And a scan that says nothing of why is a thorough one.
        let before = slotReads(fixture)
        _ = await scanner.scan()
        #expect(zip(before, slotReads(fixture)).allSatisfy { $1 > $0 })
    }

    @Test func appsChangedScanReadsEveryWindow() async throws {
        // An app launching or quitting is when the slots gain or lose their names, so the scan for it looks at every window, though it
        // doesn't compare them.
        let fixture = InventoryFixtures.desk(.init(windowsPerDisplay: 4, windowsWithoutNames: [0, 1, 2, 3], appsReportIdentifiers: false))
        let scanner = makeScanner(fixture)
        let launch = await scanner.scan(reasons: [.refresh])
        #expect(launch.items.contains { $0.id.string == "com.example.weather#0" }, "no window has the names yet")

        // The last window of each display gains them: an ordinary scan would take up to three more scans to get to it.
        for display in fixture.windows { fixture.giveNames(toWindow: display[3]) }
        let before = slotReads(fixture) + slotReads(fixture, display: 1)
        let appsChanged = await scanner.scan(reasons: [.appsChanged, .poll])
        #expect(zip(before, slotReads(fixture) + slotReads(fixture, display: 1)).allSatisfy { $1 > $0 }, "every window was read")
        #expect(slotNames(of: appsChanged).contains("weather.temp"))

        // Not a comparison: two scans in a row that find a window's slots moved are no doubt for this reason.
        let slot = try #require(try fixture.ax.children(of: fixture.ax.ref(fixture.windows[0][1])).first.map(fixture.ax.id(of:)))
        guard case .point(let original)? = try? fixture.ax.attribute(AXName.position, of: fixture.ax.ref(slot)) else {
            Issue.record("the slot has a position")
            return
        }
        fixture.ax.setAttribute(AXName.position, .point(CGPoint(x: original.x + 40, y: original.y)), on: slot)
        #expect(await scanner.scan(reasons: [.appsChanged]).problems.isEmpty)
        #expect(await scanner.scan(reasons: [.appsChanged]).problems.isEmpty)
    }

    @Test func namesThatAppearLaterInAnotherWindowAreFoundWithinAFewPolls() async {
        // At launch no window of a display has the names of the third-party slots, and the apps' own lists give no identifiers, so the
        // weather app's items are told by their place. Then some of the windows gain the names, and the first does not: ordinary scans
        // find them in a window that isn't the first, within as many scans as the display has other windows.
        let full = await makeScanner(InventoryFixtures.desk(.init(windowsPerDisplay: 3, windowsWithoutNames: [], appsReportIdentifiers: false))).scan()
        for (windows, gaining) in [(3, [1, 2]), (5, [4]), (5, [2, 3])] {
            let fixture = InventoryFixtures.desk(.init(windowsPerDisplay: windows, windowsWithoutNames: Set(0..<windows), appsReportIdentifiers: false))
            let scanner = makeScanner(fixture)
            let launch = await scanner.scan(reasons: [.refresh])
            #expect(launch.items.contains { $0.id.string == "com.example.weather#0" })
            for display in fixture.windows {
                for position in gaining { fixture.giveNames(toWindow: display[position]) }
            }

            var polls = 0
            var found: Inventory?
            while found == nil, polls < windows - 1 {
                polls += 1
                let inventory = await scanner.scan(reasons: [.poll])
                if slotNames(of: inventory).contains("weather.temp") { found = inventory }
            }
            #expect(found != nil, "\(windows) windows, names in \(gaining): not found in \(windows - 1) polls")
            #expect(found?.items.map(\.id) == full.items.map(\.id), "\(windows) windows, names in \(gaining)")
            // It goes on being found: the window that has the names is the one tried first from then on.
            #expect(await scanner.scan(reasons: [.poll]).items.map(\.id) == full.items.map(\.id))
        }
    }

    @Test func displayWithoutCachedCountIsReadThoroughly() async {
        // The first scan a scanner makes isn't a thorough one, if it is asked for another reason; but nothing is known of the windows
        // yet, so every window of every display is read, and the one with the names is found.
        let fixture = InventoryFixtures.desk(.init(windowsPerDisplay: 4, windowsWithoutNames: [0, 1], appsReportIdentifiers: false))
        let first = await makeScanner(fixture).scan(reasons: [.poll])
        #expect((slotReads(fixture) + slotReads(fixture, display: 1)).allSatisfy { $0 > 0 })
        #expect(slotNames(of: first).contains("weather.temp"))

        // A display that wasn't there at the last scan has nothing remembered either. Its windows are all read, and the main
        // display's are not.
        let later = InventoryFixtures.desk(.init(windowsPerDisplay: 4))
        let displays = Mutex(DisplayLayout(displays: [DisplayFixtures.deskMain]))
        let scanner = MenuBarScanner(ax: later.ax, runningApps: { later.running }, layout: { displays.withLock { $0 } },
                                     ownBundleID: InventoryFixtures.ownBundleID, isTrusted: { true }, clock: FakeClock())
        _ = await scanner.scan(reasons: [.refresh])
        displays.withLock { $0 = .desk }
        let before = slotReads(later)
        let beforeNew = slotReads(later, display: 1)
        let inventory = await scanner.scan(reasons: [.poll])
        #expect(zip(beforeNew, slotReads(later, display: 1)).allSatisfy { $1 > $0 }, "all of the new display's windows")
        #expect(windowsRead(before, slotReads(later)).count == 2, "and two of the main display's")
        #expect(inventory.bars.count == 2)
    }

    @Test func bestWindowIsTriedFirst() async {
        // The first window lacks the names; the second, the first of those that have them, is the best. An ordinary scan reads it,
        // and the one it is next to look at, and not the first.
        let fixture = InventoryFixtures.desk(.init(windowsPerDisplay: 5, windowsWithoutNames: [0], appsReportIdentifiers: false))
        let full = await makeScanner(InventoryFixtures.desk(.init(windowsPerDisplay: 5, windowsWithoutNames: [], appsReportIdentifiers: false))).scan()
        let scanner = makeScanner(fixture)
        _ = await scanner.scan(reasons: [.refresh])
        let before = slotReads(fixture)
        let ordinary = await scanner.scan(reasons: [.poll])
        #expect(windowsRead(before, slotReads(fixture)) == [1, 2], "the best, and the next to look at; not the first, which has no names")
        #expect(ordinary == full)
        // The first is looked at in its turn: after the others.
        var looked: [Int] = []
        for _ in 0..<3 {
            let last = slotReads(fixture)
            _ = await scanner.scan(reasons: [.poll])
            looked.append(contentsOf: windowsRead(last, slotReads(fixture)).subtracting([1]))
        }
        #expect(looked == [3, 4, 0])
    }

    @Test func aRememberedWindowThatIsGoneIsReplacedByTheFirst() async {
        // The windows that remembered one was the best are fewer when the Spaces are gone: the one that was best isn't there to try
        // first, and the first of those there are is read in its place.
        let before = InventoryFixtures.desk(.init(windowsPerDisplay: 5, windowsWithoutNames: [0, 1, 2, 3], appsReportIdentifiers: false))
        let after = InventoryFixtures.desk(.init(windowsPerDisplay: 2, windowsWithoutNames: [], appsReportIdentifiers: false))
        let phase = Switch(true)
        let layout = before.layout
        let scanner = MenuBarScanner(ax: SwitchingAX(first: before.ax, second: after.ax, useFirst: phase), runningApps: { before.running },
                                     layout: { layout }, ownBundleID: InventoryFixtures.ownBundleID,
                                     isTrusted: { true }, clock: FakeClock())
        let first = await scanner.scan(reasons: [.refresh])
        #expect(slotNames(of: first).contains("weather.temp"), "the fifth window was the best")
        phase.set(false)
        let second = await scanner.scan(reasons: [.poll])
        #expect(slotNames(of: second).contains("weather.temp"))
        #expect(slotReads(after)[0] > 0, "the first window of the display was read in its place")
    }

    @Test func aScanReadsOnWhileNoWindowHasAsManyNamesAsIsKnown() async {
        // The best window and the one looked at lost their names: the scan goes on to the next, and stops at the first that has them.
        let fixture = InventoryFixtures.desk(.init(windowsPerDisplay: 5, windowsWithoutNames: [], appsReportIdentifiers: false))
        let full = await makeScanner(InventoryFixtures.desk(.init(windowsPerDisplay: 5, windowsWithoutNames: [], appsReportIdentifiers: false))).scan()
        let scanner = makeScanner(fixture)
        _ = await scanner.scan(reasons: [.refresh])
        for display in fixture.windows {
            for position in [0, 1] { fixture.takeNames(fromWindow: display[position]) }
        }
        let before = slotReads(fixture)
        let ordinary = await scanner.scan(reasons: [.poll])
        #expect(windowsRead(before, slotReads(fixture)) == [0, 1, 2], "the best, the one looked at, and the first that has the names")
        #expect(ordinary == full)
        // The window that has them is the best from now on, and nothing is read on.
        let last = slotReads(fixture)
        _ = await scanner.scan(reasons: [.poll])
        #expect(windowsRead(last, slotReads(fixture)) == [2, 3], "the best, and the next to look at")
    }

    @Test func missingAgentAndWindowsAreProblemsAndCounted() async {
        let fixture = InventoryFixtures.desk()
        let apps = Mutex<[RunningApp]>(fixture.running.filter { $0.bundleID != MenuBarReader.menuBarAgentBundleID })
        let scanner = makeScanner(fixture, running: { apps.withLock { $0 } })

        let noAgent = await scanner.scan()
        #expect(noAgent.problems == [.agentNotRunning])
        #expect(noAgent.items.isEmpty)
        #expect(!noAgent.agentAnswered)
        #expect(await scanner.agentFailureStreak == 1)
        _ = await scanner.scan()
        #expect(await scanner.agentFailureStreak == 2)

        // It runs but has no window.
        let silent = InventoryFixtures.desk(.init(windowsPerDisplay: 0))
        // The read is asked for again a few times before it is taken as it is (`EmptyReadRetry`), each after a wait: a clock that moves by itself.
        let quiet = makeScanner(silent, clock: SteppingClock())
        let noWindows = await quiet.scan()
        #expect(noWindows.problems == [.agentHasNoWindows])
        #expect(!noWindows.agentAnswered)
        #expect(await quiet.agentFailureStreak == 1)

        // Back, and the count starts again.
        apps.withLock { $0 = fixture.running }
        let back = await scanner.scan()
        #expect(back.problems.isEmpty)
        #expect(back.agentAnswered)
        #expect(await scanner.agentFailureStreak == 0)
        #expect(InventoryProblem.agentNotRunning.message == "MenuBarAgent isn't running.")
        #expect(InventoryProblem.accessibilityNotGranted.message == "Device control and data access isn't granted to Mantel.")
        #expect(InventoryProblem.ambiguousSpace.message
            == "Mantel couldn't tell which copy of the menu bar is current, so it used the one with the most names. If icons look wrong, choose Refresh Menu Bar.")
    }

    // MARK: Reach

    @Test func reachIsFineSlowTimedOut() async throws {
        // An app that takes 50 ms is fine and one that takes 150 is slow. One whose reads of its items time out, but not too many of
        // them, is slow too; one that doesn't answer, or whose reads time out three times, is timed out.
        let weather = InventoryFixtures.weather

        let fine = try #require(await reachOfAloneApp(weather, latency: .milliseconds(50)))
        #expect(fine.status == .fine)
        #expect(abs(fine.readMs - 50) < 1)
        #expect(fine.name == "Weather")

        let slow = try #require(await reachOfAloneApp(weather, latency: .milliseconds(150)))
        #expect(slow.status == .slow)
        #expect(abs(slow.readMs - 150) < 1)

        let flaky = try #require(await reachOfAloneApp(weather) { fixture in
            let first = Set(fixture.extrasNodes(of: weather).prefix(1))
            fixture.ax.setOverride { id, name in first.contains(id) && name == AXName.title ? .failure(.timeout) : nil }
        })
        #expect(flaky.status == .slow, "it answered, but one read of an item didn't come")

        let hung = try #require(await reachOfAloneApp(weather) { fixture in
            fixture.ax.failReads(on: fixture.ax.root(ofApp: fixture.pid(of: weather) ?? 0), with: .timeout)
        })
        #expect(hung.status == .timedOut)
        #expect(hung.readMs < 1)

        let tooMany = try #require(await reachOfAloneApp(weather) { fixture in
            let items = Set(fixture.extrasNodes(of: weather))
            fixture.ax.setOverride { id, name in items.contains(id) && (name == AXName.title || name == AXName.identifier) ? .failure(.timeout) : nil }
        })
        #expect(tooMany.status == .timedOut, "three reads of its items timed out")
    }

    @Test func scanReadsAppsConcurrently() async {
        // Sixteen apps that each take a second to answer: eight at a time, so two seconds in all, not sixteen.
        let fixture = InventoryFixtures.desk()
        var slow: [RunningApp] = []
        var latency: [String: Duration] = [:]
        for index in 0..<16 {
            let app = RunningApp.fake(pid_t(3000 + index), "com.example.slow\(index)", "Slow \(index)")
            fixture.ax.addApp(pid: app.pid, extras: [.init(title: "Slow", identifier: "slow.\(index)", frame: nil)])
            slow.append(app)
            latency[app.bundleID ?? ""] = .seconds(1)
        }
        let apps = [fixture.running[0]] + slow
        let clock = FakeClock()
        let started = clock.now()
        let scanner = makeScanner(fixture, running: { apps }, clock: clock, latency: latency)
        let scan = Task { await scanner.scan() }

        // (A wait that doesn't end in a few seconds is a failure, and not a test that hangs until its time limit.)
        let first = await clock.waitForSleepers(8, within: .seconds(5))
        #expect(first, "eight are asked at once")
        guard first else { return scan.cancel() }
        #expect(clock.sleeperCount == 8, "no more than eight are asked at once")
        clock.advance(by: .seconds(1))
        let second = await clock.waitForSleepers(8, within: .seconds(5))
        #expect(second, "the next eight began as these finished")
        guard second else { return scan.cancel() }
        #expect(clock.sleeperCount == 8)
        clock.advance(by: .seconds(1))
        let inventory = await scan.value

        #expect(abs(clock.now().timeIntervalSince(started) - 2) < 0.001, "two seconds of the clock's time")
        #expect(inventory.reach.count == 16)
        #expect(inventory.reach.allSatisfy { $0.status == .slow }, "each took a second")
    }

    @Test func readStopsAtTheItemTimeoutThresholdInAScan() async {
        // An app whose items all time out costs three timeouts and not one for each of the items it has.
        let fixture = InventoryFixtures.desk()
        let hung = RunningApp.fake(2007, "com.example.slowitems", "Slow Items")
        let items = fixture.ax.addApp(pid: hung.pid, extras: (0..<20).map { FakeAX.Extra(title: "Item \($0)", identifier: "item.\($0)", frame: CGRect(x: 10 * CGFloat($0), y: 0, width: 8, height: 30)) })
        let slow = Set(items)
        fixture.ax.setOverride { id, _ in slow.contains(id) ? .failure(.timeout) : nil }
        let all = fixture.running + [hung]
        let inventory = await makeScanner(fixture, running: { all }).scan()
        #expect(items.map { fixture.ax.attributeReads(on: $0) }.reduce(0, +) == 3, "three reads of items, and then it stops")
        #expect(inventory.reach.first { $0.bundleID == "com.example.slowitems" }?.status == .timedOut)
        #expect(inventory.items(ofApp: "com.example.slowitems").isEmpty)
    }

    // MARK: Apps that don't answer, and apps that are new

    @Test func timedOutAppIsUnansweredNotGone() async {
        // An app that doesn't answer has no items in the inventory, which says nothing of whether it has them: the inventory says
        // which apps those are.
        let fixture = InventoryFixtures.desk()
        let hung = RunningApp.fake(2006, "com.example.hung", "Hung")
        fixture.ax.failReads(on: fixture.ax.root(ofApp: hung.pid), with: .timeout)
        let all = fixture.running + [hung]
        let clock = FakeClock()
        let scanner = makeScanner(fixture, running: { all }, clock: clock)

        let first = await scanner.scan()
        #expect(first.unansweredApps == ["com.example.hung"])
        #expect(first.items(ofApp: "com.example.hung").isEmpty)
        #expect(first.reach.first { $0.bundleID == "com.example.hung" }?.status == .timedOut)
        // After three in a row it is left alone, and is still one that didn't answer.
        _ = await scanner.scan()
        _ = await scanner.scan()
        let skipped = await scanner.scan()
        #expect(skipped.reach.first { $0.bundleID == "com.example.hung" }?.status == .skipped)
        #expect(skipped.unansweredApps == ["com.example.hung"])
        // The apps that answered are not in it.
        #expect(!first.unansweredApps.contains(InventoryFixtures.weather))

        // It answers: it is no longer one.
        fixture.ax.failReads(on: fixture.ax.root(ofApp: hung.pid), with: nil)
        fixture.ax.addApp(pid: hung.pid, extras: [.init(title: "Back", identifier: "hung.item", frame: nil)])
        clock.advance(by: .seconds(31))
        let back = await scanner.scan()
        #expect(back.unansweredApps.isEmpty)
        #expect(back.items(ofApp: "com.example.hung").count == 1)
    }

    @Test func overlappingScansAreOneScan() async throws {
        // A scan asked for while another is under way is given that one's result, and doesn't read everything again.
        let fixture = InventoryFixtures.desk()
        let gate = Gate()
        let counter = ReadCounter()
        let apps = fixture.running
        let layout = fixture.layout
        let scanner = MenuBarScanner(ax: fixture.ax, extrasReader: GatedExtrasReader(base: AppExtrasReader(ax: fixture.ax), gate: gate, started: counter),
                                     runningApps: { apps }, layout: { layout },
                                     ownBundleID: InventoryFixtures.ownBundleID, isTrusted: { true }, clock: FakeClock(), readLimit: 8)
        let first = Task { await scanner.scan(reasons: [.poll]) }
        let begun = await waitUntil { counter.value > 0 }
        #expect(begun, "the first scan began to read")
        // Neither asks for more than the quiet read that is under way covers.
        let second = Task { await scanner.scan(reasons: [.poll]) }
        let third = Task { await scanner.scan(reasons: [.trial]) }
        #expect(await reaches(scanner, waiting: [.poll, .trial]), "they reached the scanner")
        #expect(counter.value == 6, "six apps, asked once")
        gate.open()
        let results = await [first.value, second.value, third.value]
        #expect(results[0] == results[1])
        #expect(results[0] == results[2])
        #expect(counter.value == 6, "and still once")
        // Once it is over, the next scan is a scan of its own.
        _ = await scanner.scan()
        #expect(counter.value == 12)
    }

    /// Returns once the scanner has been asked, while a scan runs, for all of these reasons.
    private func reaches(_ scanner: MenuBarScanner, waiting reasons: Set<ScanScheduler.Reason>) async -> Bool {
        await withinTimeLimit(.seconds(5)) {
            while await scanner.waitingReasons != reasons, !Task.isCancelled { await Task.yield() }
            return true
        } ?? false
    }

    /// Returns once one more scan waits for the one under way.
    private func followUpWaits(_ scanner: MenuBarScanner) async -> Bool {
        await withinTimeLimit(.seconds(5)) {
            while await scanner.hasFollowUp == false, !Task.isCancelled { await Task.yield() }
            return true
        } ?? false
    }

    @Test func overlappingScanKeepsBothReasons() async throws {
        // A scan under way, and calls that come while it runs: one for apps that came or went, which wants every window read (the quiet read
        // that is under way reads two), and one for a change of displays, which wants every window read and compared. The reasons of
        // both are kept, and the one more scan has them, and covers the most either asked; a call for a refresh that comes after joins it.
        let fixture = InventoryFixtures.desk()
        let gate = Gate()
        let counter = ReadCounter()
        let apps = fixture.running
        let layout = fixture.layout
        let scanner = MenuBarScanner(ax: fixture.ax, extrasReader: GatedExtrasReader(base: AppExtrasReader(ax: fixture.ax), gate: gate, started: counter),
                                     runningApps: { apps }, layout: { layout },
                                     ownBundleID: InventoryFixtures.ownBundleID, isTrusted: { true }, clock: FakeClock(), readLimit: 8)
        let first = Task { await scanner.scan(reasons: [.poll]) }
        #expect(await waitUntil { counter.value > 0 }, "the first scan began to read")

        let second = Task { await scanner.scan(reasons: [.appsChanged]) }
        #expect(await reaches(scanner, waiting: [.appsChanged]))
        let third = Task { await scanner.scan(reasons: [.displaysChanged]) }
        #expect(await reaches(scanner, waiting: [.appsChanged, .displaysChanged]), "both are kept")
        let fourth = Task { await scanner.scan(reasons: [.refresh]) }
        #expect(await reaches(scanner, waiting: [.appsChanged, .displaysChanged, .refresh]))
        #expect(counter.value == 6, "nothing is read again while the first scan is under way")

        gate.open()
        _ = await [first.value, second.value, third.value, fourth.value]

        #expect(counter.value == 12, "one scan more, for the three of them")
        #expect(await scanner.scanReasons == [[.poll], [.appsChanged, .displaysChanged, .refresh]])
        #expect(await scanner.scanCoverages == ["steady", "thorough"], "the one more reads what the most demanding of them asked")
        #expect(await scanner.waitingReasons.isEmpty, "and nothing is left over")
        // Once it is over, the next scan is a scan of its own.
        _ = await scanner.scan(reasons: [.poll])
        #expect(counter.value == 18)
        #expect(await scanner.scanReasons.last == [.poll])
    }

    @Test func appsChangedDuringAQuietScanIsReadAgainInEveryWindow() async throws {
        // The quiet read that is under way reads two windows of each display. A call for apps that came or went wants every window read (to
        // find the one that has gained or lost the names of the slots), which that read doesn't cover: it is read again, with the reason.
        let fixture = InventoryFixtures.desk()
        let gate = Gate()
        let counter = ReadCounter()
        let apps = fixture.running
        let layout = fixture.layout
        let scanner = MenuBarScanner(ax: fixture.ax, extrasReader: GatedExtrasReader(base: AppExtrasReader(ax: fixture.ax), gate: gate, started: counter),
                                     runningApps: { apps }, layout: { layout },
                                     ownBundleID: InventoryFixtures.ownBundleID, isTrusted: { true }, clock: FakeClock(), readLimit: 8)
        let first = Task { await scanner.scan(reasons: [.poll]) }
        #expect(await waitUntil { counter.value > 0 })
        let second = Task { await scanner.scan(reasons: [.appsChanged]) }
        #expect(await followUpWaits(scanner), "one more scan waits for the quiet one")
        #expect(counter.value == 6)

        gate.open()
        _ = await [first.value, second.value]

        #expect(counter.value == 12)
        #expect(await scanner.scanReasons == [[.poll], [.appsChanged]])
        #expect(await scanner.scanCoverages == ["steady", "allWindows"])
    }

    @Test func theAppsThatDontVoteOfACallThatJoinsAScanReachTheOneMore() async throws {
        // The apps' own frames are on the second display's bar, and the scan under way (asked with no apps left out) says so. A call that
        // comes while it runs, for apps that came or went, was made by a session that has just drawn the apps again: they don't vote, and the
        // one more scan, which is the answer to that call, doesn't count them.
        let fixture = InventoryFixtures.desk(.init(listingDisplay: 1))
        let gate = Gate()
        let counter = ReadCounter()
        let apps = fixture.running
        let layout = fixture.layout
        let scanner = MenuBarScanner(ax: fixture.ax, extrasReader: GatedExtrasReader(base: AppExtrasReader(ax: fixture.ax), gate: gate, started: counter),
                                     runningApps: { apps }, layout: { layout },
                                     ownBundleID: InventoryFixtures.ownBundleID, isTrusted: { true }, clock: FakeClock(), readLimit: 8)
        let first = Task { await scanner.scan(reasons: [.poll]) }
        #expect(await waitUntil { counter.value > 0 })
        let second = Task { await scanner.scan(reasons: [.appsChanged], notVoting: Set(apps.compactMap(\.bundleID))) }
        #expect(await followUpWaits(scanner), "one more scan waits for the one under way")

        gate.open()
        let (under, more) = await (first.value, second.value)

        #expect(under.activeDisplay == layout.displays[1].uuid, "the scan under way counted the apps' frames")
        #expect(more.activeDisplay == nil, "the one more scan was asked with every app left out of the vote")
    }

    @Test func whatTheScanUnderWayCoversIsNotReadAgain() async throws {
        // A call that asks for no more than the scan under way reads (for the same, for less) is given its result, and its reasons are kept,
        // in case one more comes.
        let cases: [(running: Set<ScanScheduler.Reason>, newcomers: [Set<ScanScheduler.Reason>])] = [
            ([.appsChanged], [[.appsChanged], [.poll]]),
            ([.displaysChanged], [[.appsChanged], [.displaysChanged], [.refresh], [.poll]]),
            ([.refresh], [[.appsChanged], [.displaysChanged], []]),
            ([.poll], [[.poll], [.trial], [.reveal]]),
        ]
        for (running, newcomers) in cases {
            let fixture = InventoryFixtures.desk()
            let gate = Gate()
            let counter = ReadCounter()
            let apps = fixture.running
            let layout = fixture.layout
            let scanner = MenuBarScanner(ax: fixture.ax, extrasReader: GatedExtrasReader(base: AppExtrasReader(ax: fixture.ax), gate: gate, started: counter),
                                         runningApps: { apps }, layout: { layout },
                                         ownBundleID: InventoryFixtures.ownBundleID, isTrusted: { true }, clock: FakeClock(), readLimit: 8)
            let first = Task { await scanner.scan(reasons: running) }
            #expect(await waitUntil { counter.value > 0 })
            let calls = newcomers.map { reasons in Task { await scanner.scan(reasons: reasons) } }
            #expect(await reaches(scanner, waiting: newcomers.reduce(into: Set<ScanScheduler.Reason>()) { $0.formUnion($1) }), "\(running)")
            #expect(await scanner.hasFollowUp == false, "\(running)")

            gate.open()
            var results = [await first.value]
            for call in calls { results.append(await call.value) }

            #expect(results.allSatisfy { $0 == results[0] }, "\(running)")
            #expect(counter.value == 6, "one scan: \(running)")
            #expect(await scanner.scanReasons == [running], "\(running)")
        }
    }

    @Test func aThoroughCallThatComesWhileAScanRunsIsReadAgain() async throws {
        // A call that asks for a thorough read (no reason given, a change of displays or a refresh) while a quiet read is under way isn't
        // covered by it: it is read again, and the answer it is given is of the second read.
        let fixture = InventoryFixtures.desk()
        let gate = Gate()
        let counter = ReadCounter()
        let apps = fixture.running
        let layout = fixture.layout
        let scanner = MenuBarScanner(ax: fixture.ax, extrasReader: GatedExtrasReader(base: AppExtrasReader(ax: fixture.ax), gate: gate, started: counter),
                                     runningApps: { apps }, layout: { layout },
                                     ownBundleID: InventoryFixtures.ownBundleID, isTrusted: { true }, clock: FakeClock(), readLimit: 8)
        let first = Task { await scanner.scan(reasons: [.poll]) }
        #expect(await waitUntil { counter.value > 0 })
        let second = Task { await scanner.scan() }
        #expect(await followUpWaits(scanner), "one more scan waits for the first")

        gate.open()
        _ = await [first.value, second.value]

        #expect(counter.value == 12)
        #expect(await scanner.scanReasons.count == 2)
        #expect(await scanner.scanReasons.last == [], "a call that gave no reason is a thorough one: the one more is too")
        #expect(await scanner.scanCoverages == ["steady", "thorough"])
    }

    @Test func aNewAppWithNoExtrasIsRecheckedAfterTwoSeconds() async {
        // An app that started a moment ago may not have made its items yet: it is asked again at two seconds, until it is ten seconds
        // old, and then once a minute like the others (which were there when the scanner began, and are asked once a minute).
        let fixture = InventoryFixtures.desk()
        let newcomer = RunningApp.fake(2008, "com.example.newcomer", "Newcomer")
        let root = fixture.ax.root(ofApp: newcomer.pid)
        let present = Mutex(false)
        let clock = FakeClock()
        let scanner = makeScanner(fixture, running: { present.withLock { $0 } ? fixture.running + [newcomer] : fixture.running }, clock: clock)
        _ = await scanner.scan()
        present.withLock { $0 = true }

        _ = await scanner.scan()
        var reads = fixture.ax.attributeReads(on: root)
        #expect(reads > 0, "asked at once")
        clock.advance(by: .seconds(1))
        _ = await scanner.scan()
        #expect(fixture.ax.attributeReads(on: root) == reads, "not at one second")
        clock.advance(by: .milliseconds(1100))
        _ = await scanner.scan()
        #expect(fixture.ax.attributeReads(on: root) > reads, "again at two")
        reads = fixture.ax.attributeReads(on: root)

        // It makes its item while it is new, and is found at the next check.
        fixture.ax.addApp(pid: newcomer.pid, extras: [.init(title: "Late", identifier: "late.item", frame: CGRect(x: 3000, y: 0, width: 30, height: 30))])
        clock.advance(by: .milliseconds(2100))
        let found = await scanner.scan()
        #expect(found.reach.contains { $0.bundleID == "com.example.newcomer" })
        #expect(fixture.ax.attributeReads(on: root) > reads)

        // A new app that has none at ten seconds is left for a minute.
        let other = RunningApp.fake(2009, "com.example.other", "Other")
        let otherRoot = fixture.ax.root(ofApp: other.pid)
        let both = Mutex(false)
        let scannerTwo = makeScanner(fixture, running: { both.withLock { $0 } ? fixture.running + [other] : fixture.running }, clock: clock)
        _ = await scannerTwo.scan()
        both.withLock { $0 = true }
        _ = await scannerTwo.scan()
        clock.advance(by: .seconds(11))
        _ = await scannerTwo.scan()
        let atEleven = fixture.ax.attributeReads(on: otherRoot)
        clock.advance(by: .seconds(5))
        _ = await scannerTwo.scan()
        #expect(fixture.ax.attributeReads(on: otherRoot) == atEleven, "old enough now: a minute")
        clock.advance(by: .seconds(56))
        _ = await scannerTwo.scan()
        #expect(fixture.ax.attributeReads(on: otherRoot) > atEleven)
    }

    // MARK: Looking at the bar

    @Test func aLookCountsTheSlotsThatHaveAPlaceOnTheMainBar() async throws {
        // Seven of the system's slots and ten of the others, on the main display's bar.
        let fixture = InventoryFixtures.desk()
        let look = try #require(await makeScanner(fixture).lookAtBar())
        #expect(look.displayUUID == mainUUID)
        #expect(look.drawnSlots == 17)
    }

    @Test func aSlotMacOSIsNotDrawingIsNotCounted() async throws {
        // The sync app's two icons are concealed: their slots have no frame.
        let fixture = InventoryFixtures.desk(.init(concealed: [InventoryFixtures.sync]))
        #expect(try #require(await makeScanner(fixture).lookAtBar()).drawnSlots == 15)

        // A slot whose frame is somewhere that isn't the bar is one that isn't drawn either (the frame macOS reports is a stale one).
        let parked = InventoryFixtures.desk()
        let window = parked.windows[0][0]
        let slot = try #require(try parked.ax.children(of: parked.ax.ref(window)).first)
        parked.ax.setAttribute(AXName.position, .point(CGPoint(x: 7, y: 1878)), on: parked.ax.id(of: slot))
        #expect(try #require(await makeScanner(parked).lookAtBar()).drawnSlots == 16)
    }

    @Test func theChevronOfAFullBarIsNotASlotThatIsCounted() async throws {
        // The laptop's bar is full: the first eight icons are piled at the «, with frames, and the « is a button. The seven of the
        // system's slots and the eight are counted: the piled ones are drawn, in their way, and the « is not an icon.
        let fixture = InventoryFixtures.laptop()
        let look = try #require(await makeScanner(fixture).lookAtBar())
        #expect(look.displayUUID == DisplayFixtures.laptopAlone.uuid)
        #expect(look.drawnSlots == 15)
    }

    @Test func aLookReadsOneWindowAndNoApp() async throws {
        let fixture = InventoryFixtures.desk()
        _ = await makeScanner(fixture).lookAtBar()

        // The slots of the main display's first window were read, three reads each at most (the role, and the two of the frame); the
        // slots of no other window of either display were.
        func slotReads(_ window: Int) throws -> [Int] {
            try fixture.ax.children(of: fixture.ax.ref(window)).map { fixture.ax.attributeReads(on: fixture.ax.id(of: $0)) }
        }
        let read = try slotReads(fixture.windows[0][0])
        #expect(read.count == 17 && read.allSatisfy { (1...3).contains($0) }, "\(read)")
        for window in fixture.windows[0].dropFirst() + fixture.windows[1] {
            #expect(try slotReads(window).allSatisfy { $0 == 0 })
        }
        // And no app was asked for anything: not for its items, and not for its menus.
        for app in fixture.running where app.bundleID != MenuBarReader.menuBarAgentBundleID {
            #expect(fixture.ax.attributeReads(on: fixture.ax.root(ofApp: app.pid)) == 0, "\(app.bundleID ?? "")")
        }
    }

    @Test func aLookWhoseReadsTimedOutSaysItIsIncomplete() async throws {
        let whole = InventoryFixtures.desk()
        #expect(try #require(await makeScanner(whole).lookAtBar()).isComplete)

        // The role of every slot times out: the look stops at the first slot, and says that it saw less than is there.
        let slow = InventoryFixtures.desk()
        slow.ax.setOverride { _, name in name == AXName.role ? .failure(.timeout) : nil }
        let look = try #require(await makeScanner(slow).lookAtBar())
        #expect(!look.isComplete)
        #expect(look.drawnSlots == 0, "a slot whose role didn't come isn't counted, and nothing after it is read")

        // A read that was refused for another reason is not a timeout.
        let refused = InventoryFixtures.desk()
        refused.ax.setOverride { _, name in name == AXName.role ? .failure(.noValue) : nil }
        #expect(try #require(await makeScanner(refused).lookAtBar()).isComplete)

        // The list of windows that timed out says nothing at all.
        let silent = InventoryFixtures.desk()
        silent.ax.setOverride { _, name in name == AXName.windows ? .failure(.timeout) : nil }
        #expect(await makeScanner(silent).lookAtBar() == nil)
    }

    @Test func aLookStopsAtTheFirstTimeoutInTheWindowItReads() async throws {
        let fixture = InventoryFixtures.desk()
        let slots = try fixture.ax.children(of: fixture.ax.ref(fixture.windows[0][0])).map(fixture.ax.id(of:))
        #expect(slots.count == 17)

        // The role of the sixth slot times out: the five before it were counted, and not one after it was read at all.
        let slow = slots[5]
        fixture.ax.setOverride { id, name in id == slow && name == AXName.role ? .failure(.timeout) : nil }
        let look = try #require(await makeScanner(fixture).lookAtBar())
        #expect(!look.isComplete)
        #expect(look.drawnSlots == 5)
        for later in slots[6...] {
            #expect(fixture.ax.attributeReads(on: later) == 0)
        }

        // The same for the frame of a slot: its position, here.
        let framed = InventoryFixtures.desk()
        let framedSlots = try framed.ax.children(of: framed.ax.ref(framed.windows[0][0])).map(framed.ax.id(of:))
        let hung = framedSlots[9]
        framed.ax.setOverride { id, name in id == hung && name == AXName.position ? .failure(.timeout) : nil }
        let second = try #require(await makeScanner(framed).lookAtBar())
        #expect(!second.isComplete)
        #expect(second.drawnSlots == 9)
        for later in framedSlots[10...] {
            #expect(framed.ax.attributeReads(on: later) == 0)
        }
        #expect(framed.ax.attributeReads(on: hung) == 2, "its role, and the position that timed out; not its size")
    }

    @Test func aTimeoutOnAWindowThatIsPassedOverIsNothingToTheLook() async throws {
        // Accessibility lists the portrait display's windows first, so that the look passes over one of them to get to the main display's.
        for failing in [AXName.size, AXName.position] {
            let fixture = InventoryFixtures.desk()
            let agent = fixture.ax.root(ofApp: InventoryFixtures.agentPID)
            let listed = fixture.windows[1] + fixture.windows[0]
            fixture.ax.setAttribute(AXName.windows, .elements(listed.map(fixture.ax.ref)), on: agent)
            let passedOver = fixture.windows[1][0]
            fixture.ax.setOverride { id, name in id == passedOver && name == failing ? .failure(.timeout) : nil }

            let look = try #require(await makeScanner(fixture).lookAtBar(), "\(failing)")
            #expect(look.isComplete, "\(failing) of a window on another display timing out says nothing about the main display's")
            #expect(look.displayUUID == mainUUID)
            #expect(look.drawnSlots == 17)
            #expect(fixture.ax.attributeReads(on: passedOver) == 1, "a window is placed by one read, and not read on when it is another display's")
        }
    }

    @Test func theFirstWindowOfTheDisplayIsTheOneTheLookStopsAtWhenItsSizeTimesOut() async throws {
        // The display's second window shows one slot fewer, so that using it in the first one's place could be told.
        let fixture = InventoryFixtures.desk()
        let first = fixture.windows[0][0], second = fixture.windows[0][1]
        let moved = try #require(try fixture.ax.children(of: fixture.ax.ref(second)).first)
        fixture.ax.setAttribute(AXName.position, .point(CGPoint(x: 7, y: 1878)), on: fixture.ax.id(of: moved))
        #expect(try #require(await makeScanner(fixture).lookAtBar()).drawnSlots == 17, "the first window, as it is")

        // Its size can't be read: it still starts on the main display, so it is the one the chooser takes. The look stops there; it
        // doesn't go on to the second window and say that is what the bar shows.
        fixture.ax.setOverride { id, name in id == first && name == AXName.size ? .failure(.timeout) : nil }
        let look = try #require(await makeScanner(fixture).lookAtBar())
        #expect(!look.isComplete)
        #expect(look.drawnSlots == 0)
        #expect(look.displayUUID == mainUUID)
        #expect(fixture.slotReads(ofWindow: second) == 0)
    }

    @Test func aWindowThatCantBePlacedIsPassedOver() async throws {
        // The first window's position can't be read: it can't be told to be the display's, and the next window that is takes its place.
        let fixture = InventoryFixtures.desk()
        let first = fixture.windows[0][0]
        let moved = try #require(try fixture.ax.children(of: fixture.ax.ref(fixture.windows[0][1])).first)
        fixture.ax.setAttribute(AXName.position, .point(CGPoint(x: 7, y: 1878)), on: fixture.ax.id(of: moved))
        fixture.ax.setOverride { id, name in id == first && name == AXName.position ? .failure(.timeout) : nil }
        let look = try #require(await makeScanner(fixture).lookAtBar())
        #expect(look.isComplete)
        #expect(look.drawnSlots == 16, "the second window's")
        #expect(fixture.slotReads(ofWindow: first) == 0)
    }

    @Test func aSlotWhoseRoleTimedOutIsNotCountedAsDrawn() async throws {
        // The laptop's bar is full, and the « is a button among the slots. If its role times out it may be that, and it has a frame on
        // the bar: it isn't counted, and the look stops there.
        let fixture = InventoryFixtures.laptop()
        let slots = try fixture.ax.children(of: fixture.ax.ref(fixture.windows[0][0]))
        let chevron = try #require(slots.firstIndex { slot in
            if case .string(let role)? = try? fixture.ax.attribute(AXName.role, of: slot) { return role == "AXButton" }
            return false
        })
        #expect(chevron > 0, "slots come before it")
        let id = fixture.ax.id(of: slots[chevron])
        fixture.ax.setOverride { slot, name in slot == id && name == AXName.role ? .failure(.timeout) : nil }

        let look = try #require(await makeScanner(fixture).lookAtBar())
        #expect(!look.isComplete)
        #expect(look.drawnSlots == chevron, "the slots before it, each with a frame on the bar; not the « and not those after it")
    }

    @Test func aWindowWhoseSlotsCantBeListedIsNoLookAtAll() async throws {
        // The window's element is gone (MenuBarAgent restarted): listing its slots fails. That is not a bar with no slots, which a
        // hide would read as everything hidden.
        for error in [AXReadError.failure(-25202), .noValue, .notTrusted] {
            let fixture = InventoryFixtures.desk()
            let window = fixture.windows[0][0]
            fixture.ax.setOverride { id, name in id == window && name == AXName.children ? .failure(error) : nil }
            #expect(await makeScanner(fixture).lookAtBar() == nil, "\(error)")
        }
        // A timeout is the incomplete look it always was.
        let slow = InventoryFixtures.desk()
        let window = slow.windows[0][0]
        slow.ax.setOverride { id, name in id == window && name == AXName.children ? .failure(.timeout) : nil }
        let look = try #require(await makeScanner(slow).lookAtBar())
        #expect(!look.isComplete)
        #expect(look.drawnSlots == 0)
    }

    @Test func aLookSeesAChangeAtOnce() async throws {
        // What the bar shows is read each time: nothing is kept between looks.
        let shown = InventoryFixtures.desk()
        let hidden = InventoryFixtures.desk(.init(concealed: [InventoryFixtures.weather, InventoryFixtures.notes]))
        let phase = Switch(true)
        let layout = shown.layout
        let scanner = MenuBarScanner(ax: SwitchingAX(first: shown.ax, second: hidden.ax, useFirst: phase), runningApps: { shown.running },
                                     layout: { layout }, ownBundleID: InventoryFixtures.ownBundleID, isTrusted: { true }, clock: FakeClock())
        #expect(await scanner.lookAtBar()?.drawnSlots == 17)
        phase.set(false)
        #expect(await scanner.lookAtBar()?.drawnSlots == 14)
        phase.set(true)
        #expect(await scanner.lookAtBar()?.drawnSlots == 17)
    }

    @Test func aLookIsNilWithoutAccessibilityTheAgentAWindowOrADisplay() async {
        let fixture = InventoryFixtures.desk()
        #expect(await makeScanner(fixture, trusted: { false }).lookAtBar() == nil)
        let noAgent = makeScanner(fixture, running: { fixture.running.filter { $0.bundleID != MenuBarReader.menuBarAgentBundleID } })
        #expect(await noAgent.lookAtBar() == nil)
        // MenuBarAgent has no window at all, or there is no display to look at.
        #expect(await makeScanner(InventoryFixtures.desk(.init(windowsPerDisplay: 0))).lookAtBar() == nil)
        let noDisplay = MenuBarScanner(ax: fixture.ax, runningApps: { fixture.running }, layout: { DisplayLayout(displays: []) },
                                       ownBundleID: InventoryFixtures.ownBundleID, isTrusted: { true }, clock: FakeClock())
        #expect(await noDisplay.lookAtBar() == nil)
    }

    // MARK: The app's own menus

    @Test func appMenuFramesAreTheMenusOfTheApp() async {
        let fixture = InventoryFixtures.desk()
        let pid = fixture.pid(of: InventoryFixtures.notes) ?? 0
        let root = fixture.ax.root(ofApp: pid)
        let bar = fixture.ax.addNode(attributes: [AXName.role: .string("AXMenuBar")])
        let frames = [CGRect(x: 0, y: 0, width: 30, height: 30), CGRect(x: 30, y: 0, width: 60, height: 30), CGRect(x: 90, y: 0, width: 50, height: 30)]
        for frame in frames { fixture.ax.addNode(attributes: FakeAX.frameAttributes(frame), under: bar) }
        fixture.ax.addNode(attributes: [:], under: bar)  // an item with no frame is left out
        fixture.ax.setAttribute(AXName.menuBar, .elements([fixture.ax.ref(bar)]), on: root)

        let scanner = makeScanner(fixture)
        #expect(await scanner.appMenuFrames(pid: pid) == frames)
        #expect(await scanner.appMenuFrames(pid: 99_999).isEmpty, "an app with no menu bar")
        fixture.ax.failReads(on: root, with: .timeout)
        #expect(await scanner.appMenuFrames(pid: pid).isEmpty, "an app that doesn't answer")
    }

    // MARK: The frames of some apps

    private func scanner(_ fixture: Fixture, reader: any AppExtrasReading, trusted: @escaping @Sendable () -> Bool = { true }) -> MenuBarScanner {
        let apps = fixture.running
        let layout = fixture.layout
        return MenuBarScanner(ax: fixture.ax, extrasReader: reader, runningApps: { apps }, layout: { layout },
                              ownBundleID: InventoryFixtures.ownBundleID, isTrusted: trusted, clock: FakeClock(), readLimit: 8)
    }

    @Test func theFramesOfTheAppsAskedAreTheirItemsFramesAndNoOtherAppIsAsked() async throws {
        let fixture = InventoryFixtures.desk()
        let reader = RecordingExtrasReader(fixture)
        let scanner = scanner(fixture, reader: reader)

        let frames = await scanner.itemFrames(ofApps: [InventoryFixtures.notes, InventoryFixtures.weather])

        #expect(Set(reader.askedApps) == [InventoryFixtures.notes, InventoryFixtures.weather], "only the apps that were named")
        #expect(reader.askedApps.count == 2)
        #expect(frames[InventoryFixtures.notes]?.count == 1)
        #expect(frames[InventoryFixtures.weather]?.count == 2, "every item of an app")
        #expect(frames[InventoryFixtures.vpn] == nil)
        // The frame is where the apps list it on the bar: six points inside the slot.
        let inventory = await scanner.scan()
        let slot = try #require(inventory.items(ofApp: InventoryFixtures.notes).first?.frames[mainUUID])
        #expect(frames[InventoryFixtures.notes] == [slot.insetBy(dx: 6, dy: 1)])
    }

    @Test func anAppThatDoesntAnswerInFullIsNotInTheAnswer() async {
        let fixture = InventoryFixtures.desk()
        let reader = RecordingExtrasReader(fixture, outcomes: [InventoryFixtures.vpn: .timedOut, InventoryFixtures.sync: .noExtras])
        let scanner = scanner(fixture, reader: reader)

        let frames = await scanner.itemFrames(ofApps: [InventoryFixtures.notes, InventoryFixtures.vpn, InventoryFixtures.sync, "com.example.gone"])

        #expect(Set(frames.keys) == [InventoryFixtures.notes], "one that timed out, one with no items now and one that isn't running say nothing")
    }

    @Test func anAppWhoseReadsTimedOutSaysNothing() async {
        let fixture = InventoryFixtures.desk()
        let partial = AppExtras(pid: 1, bundleID: InventoryFixtures.vpn, name: nil, items: [ExtraItem(index: 0, frame: nil, identifier: nil, title: nil, description: nil)],
                                timedOut: false, itemTimeouts: 1)
        let scanner = scanner(fixture, reader: RecordingExtrasReader(fixture, outcomes: [InventoryFixtures.vpn: .items(partial)]))

        #expect(await scanner.itemFrames(ofApps: [InventoryFixtures.vpn]).isEmpty, "a frame that wasn't read is not one that isn't there")
    }

    @Test func noFramesAreAskedForWithoutAccessibility() async {
        let fixture = InventoryFixtures.desk()
        let reader = RecordingExtrasReader(fixture)
        let scanner = scanner(fixture, reader: reader, trusted: { false })

        #expect(await scanner.itemFrames(ofApps: [InventoryFixtures.notes]).isEmpty)
        #expect(reader.askedApps.isEmpty)
    }

    @Test func theAppsAreAskedTogether() async {
        // All four reads are under way before any of them has an answer.
        let fixture = InventoryFixtures.desk()
        let gate = Gate()
        let counter = ReadCounter()
        let scanner = scanner(fixture, reader: GatedExtrasReader(base: AppExtrasReader(ax: fixture.ax), gate: gate, started: counter))
        let asking = Task {
            await scanner.itemFrames(ofApps: [InventoryFixtures.notes, InventoryFixtures.weather, InventoryFixtures.vpn, InventoryFixtures.sync])
        }
        let together = await waitUntil { counter.value == 4 }
        gate.open()
        let frames = await asking.value

        #expect(together, "four apps, under the scanner's limit of \(MenuBarReader.concurrency)")
        #expect(frames.count == 4)
    }

    // MARK: Over several scans

    @Test func anItemKeepsItsIDWhileItsAppIsConcealedAndComesBack() async {
        // The same scanner over a menu bar whose sync app is concealed and then back: the second scan can't see where its items are,
        // and says what the first one did.
        let fixture = InventoryFixtures.desk()
        let hidden = InventoryFixtures.desk(.init(concealed: [InventoryFixtures.sync]))
        let phase = Switch(true)
        let layout = fixture.layout
        // Both fixtures' trees are the same shape: the scanner is given the one that is current.
        let scanner = MenuBarScanner(ax: SwitchingAX(first: fixture.ax, second: hidden.ax, useFirst: phase), runningApps: { fixture.running },
                                     layout: { layout }, ownBundleID: InventoryFixtures.ownBundleID,
                                     isTrusted: { true }, clock: FakeClock())
        let shown = await scanner.scan()
        phase.set(false)
        let concealed = await scanner.scan()
        let ids: (Inventory) -> [String] = { $0.items(ofApp: InventoryFixtures.sync).map(\.id.string).sorted() }
        #expect(ids(shown) == ["com.example.sync#0", "com.example.sync#1"])
        #expect(ids(concealed) == ids(shown))
        #expect(concealed.items(ofApp: InventoryFixtures.sync).allSatisfy { $0.isConcealed })
        #expect(concealed.items(ofApp: InventoryFixtures.sync).first { $0.label == "Sync B" }?.id.string == "com.example.sync#0")
    }
}
