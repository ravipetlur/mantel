import CoreGraphics
import Foundation
import MKCommands
import MKCore
import MKTestSupport
import Synchronization
import Testing

@testable import MKMenuBar

private let fixtureID = ProbeHarness.fixtureID
private let ownID = ProbeHarness.ownBundleID
private let otherID = ProbeHarness.otherID
private let trailing = LayoutKeys.trailingPositions

private let oneKey = "status:\(fixtureID)::mantel.fixture.one"
private let twoKey = "status:\(fixtureID)::mantel.fixture.two"
private let extraOneKey = "status:\(fixtureID)::mantel.fixture.extra.1"
private let extraTwoKey = "status:\(fixtureID)::mantel.fixture.extra.2"
private let otherKey = "status:\(otherID)::x"
private let hiddenDotKey = "status:\(ownID)::mantel.dot.hidden"
private let alwaysDotKey = "status:\(ownID)::mantel.dot.always"

private func id(_ name: String) -> ItemID {
    ItemID(bundleID: fixtureID, key: .identifier("mantel.fixture.\(name)"))
}

/// The distances the table holds to begin with: item one at 120 (so at x = 3100, which is 3220 less the distance) and item two at 70
/// (x = 3150), another app's item at 60, and the system's at 10 and 30.
private var startingTable: [String: Any] {
    [trailing: [oneKey: 120, twoKey: 70, otherKey: 60, "module:Clock": 10, "module:ControlCenter": 30], "keep": "this"]
}

/// Where the test item's slots are on the bar, and where its own frames are, as the order table says: either a distance is a place (an
/// item is `3220 - distance` from the left) or only an order (the two items of the test item are side by side, the one with the larger
/// distance on the left). The bar follows the table `lag` after it changes, and never does when the lag is nil; so do the test item's own
/// frames, with a lag of their own.
private final class TableBar: Sendable {
    enum Mode: Sendable {
        case places
        case order
    }

    private struct State {
        var pending: [String: Double] = [:]
        var applied: [String: Double]?
        var changedAt = Date()
    }

    private let url: URL
    private let clock: any Clock
    private let lag: Duration?
    private let mode: Mode
    private let pair: [String]
    private let state = Mutex(State())

    init(url: URL, clock: any Clock, lag: Duration?, mode: Mode, pair: [String] = []) {
        self.url = url
        self.clock = clock
        self.lag = lag
        self.mode = mode
        self.pair = pair
    }

    /// The table was written just now: the bar follows it `lag` from this moment, whether or not anyone has looked since.
    func noteWrite() {
        let table = Self.read(url)
        let now = clock.now()
        state.withLock { state in
            if state.applied == nil { state.applied = table }
            state.pending = table
            state.changedAt = now
        }
    }

    /// Where the item with this key is, when the table says: nil leaves it where the tree has it.
    func x(of key: String) -> Double? {
        let table = Self.read(url)
        let now = clock.now()
        let applied = state.withLock { state -> [String: Double] in
            if state.applied == nil {
                state.pending = table
                state.applied = table
                state.changedAt = now
            } else if table != state.pending {
                state.pending = table
                state.changedAt = now
            }
            if let lag, now >= state.changedAt.addingTimeInterval(Self.seconds(lag)) { state.applied = state.pending }
            return state.applied ?? table
        }
        switch mode {
        case .places:
            return applied[key].map { 3220 - $0 }
        case .order:
            guard pair.contains(key), applied[key] != nil else { return nil }
            let ordered = pair.compactMap { name in applied[name].map { (name, $0) } }.sorted { $0.1 > $1.1 }
            return ordered.firstIndex { $0.0 == key }.map { 3100 + 40 * Double($0) }
        }
    }

    private static func read(_ url: URL) -> [String: Double] {
        guard let data = try? Data(contentsOf: url),
              let top = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any],
              let positions = top[trailing] as? [String: Any] else { return [:] }
        return positions.compactMapValues { ($0 as? NSNumber)?.doubleValue }
    }

    private static func seconds(_ duration: Duration) -> TimeInterval {
        Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }
}

// The original is an immutable dictionary read once.
/// Who is told when the table is written.
private final class Writes: Sendable {
    private let listeners = Mutex<[@Sendable () -> Void]>([])

    func listen(_ body: @escaping @Sendable () -> Void) { listeners.withLock { $0.append(body) } }
    func fire() { for body in listeners.withLock({ $0 }) { body() } }
}

private struct World: @unchecked Sendable {
    let harness: ProbeHarness
    let url: URL
    let original: NSDictionary
    /// The slots of the extra items, and their own frames, when there are any.
    var extraSlots: [Int] = []
}

/// A desk for the probe: the order table in the layout file, the bar and the test item's own frames following it, and the locator saying
/// where the test item's items start.
///
/// - Parameters:
///   - extras: the widths of the slots of the extra items the test item has (`extra.1` first), which have no name on the bar. They are
///     at 320 and on, 50 apart.
private func world(table: [String: Any] = startingTable, barLag: Duration? = .zero, framesLag: Duration? = .zero,
                   mode: TableBar.Mode = .places, io: PlistIO = .filesOnly, clock: any Clock = SteppingClock(),
                   extras: [CGFloat] = [], configure: (inout ProbePlatform) -> Void = { _ in }) async throws -> World {
    let writes = Writes()
    var watching = io
    let write = io.write
    watching.write = { value, key, url, strategy in
        try write(value, key, url, strategy)
        writes.fire()
    }
    var table = table
    if !extras.isEmpty, var positions = table[trailing] as? [String: Any] {
        // The extras are in the table, from 320 and on.
        for index in extras.indices { positions[index == 0 ? extraOneKey : extraTwoKey] = 320 - 50 * index }
        table[trailing] = positions
    }
    let harness = try ProbeHarness.make(clock: clock, io: watching, configure: configure)
    let url = try await harness.installFile(.menuBarLayout, table)
    let original = try ProbeHarness.read(url)

    let fixtureSlots = harness.slotOwners.filter { $0.value == fixtureID }.keys.sorted()
    let mantelSlot = try #require(harness.slotOwners.first { $0.value == ownID }?.key)
    // Mantel's dot is told by what it is called for the accessibility tools.
    harness.ax.setAttribute(AXName.description, .string(DotsCopy.hiddenDotDescription), on: mantelSlot)
    var slotKeys: [Int: String] = [fixtureSlots[0]: oneKey, fixtureSlots[1]: twoKey, mantelSlot: hiddenDotKey]
    var frameKeys: [Int: String] = [harness.fixtureExtras[0]: oneKey, harness.fixtureExtras[1]: twoKey]

    var extraSlots: [Int] = []
    if !extras.isEmpty {
        // The extra items: slots with no name, and the test item lists them after its first two.
        var listed: [FakeAX.Extra] = [.init(title: "one", frame: CGRect(x: 3100, y: 0, width: 40, height: 31)),
                                      .init(title: "two", frame: CGRect(x: 3150, y: 0, width: 40, height: 31))]
        for (index, width) in extras.enumerated() {
            let key = index == 0 ? extraOneKey : extraTwoKey
            let frame = CGRect(x: 3220 - (320 - 50 * CGFloat(index)), y: 0, width: width, height: 31)
            let slot = harness.ax.addSlot(in: harness.window, frame: frame)
            extraSlots.append(slot)
            slotKeys[slot] = key
            listed.append(.init(title: "extra \(index + 1)", frame: frame))
        }
        let nodes = harness.ax.addApp(pid: 300, extras: listed)
        frameKeys = [nodes[0]: oneKey, nodes[1]: twoKey]
        for (index, node) in nodes.dropFirst(2).enumerated() { frameKeys[node] = index == 0 ? extraOneKey : extraTwoKey }
    }

    let names = [oneKey, twoKey]
    let bar = TableBar(url: url, clock: harness.clock, lag: barLag, mode: mode, pair: names)
    let frames = TableBar(url: url, clock: harness.clock, lag: framesLag, mode: mode, pair: names)
    writes.listen {
        bar.noteWrite()
        frames.noteWrite()
    }
    let slotKeysNow = slotKeys, frameKeysNow = frameKeys
    harness.ax.setOverride { node, name in
        guard name == AXName.position else { return nil }
        if let key = slotKeysNow[node], let x = bar.x(of: key) { return .success(.point(CGPoint(x: x, y: 0))) }
        if let key = frameKeysNow[node], let x = frames.x(of: key) { return .success(.point(CGPoint(x: x, y: 0))) }
        return nil
    }

    // Where the locator says the items are to begin with.
    let first = 3100.0
    let second = mode == .places ? 3150.0 : 3140.0
    harness.locator.place(FakeItemLocator.location(of: id("one"), slot: CGRect(x: first, y: 0, width: 40, height: 31), tiedBy: .tie))
    harness.locator.place(FakeItemLocator.location(of: id("two"), slot: CGRect(x: second, y: 0, width: 40, height: 31), tiedBy: .tie))
    for (index, width) in extras.enumerated() {
        let name = "extra.\(index + 1)"
        harness.locator.place(FakeItemLocator.location(of: id(name), slot: CGRect(x: 3220 - (320 - 50 * CGFloat(index)), y: 0, width: width, height: 31),
                                                      tiedBy: .tie))
    }
    return World(harness: harness, url: url, original: original, extraSlots: extraSlots)
}

/// What each write of the order table put in it, as numbers.
private final class WriteLog: Sendable {
    private let tables = Mutex<[[String: Double]]>([])

    var all: [[String: Double]] { tables.withLock { $0 } }

    func io() -> PlistIO {
        var io = PlistIO.filesOnly
        let write = io.write
        let log = self
        io.write = { value, key, url, strategy in
            if key == trailing, case .dictionary(let table)? = value {
                log.tables.withLock { $0.append(table.compactMapValues { value -> Double? in
                    switch value {
                    case .integer(let number): Double(number)
                    case .real(let number): number
                    default: nil
                    }
                }) }
            }
            try write(value, key, url, strategy)
        }
        return io
    }
}

/// Writes to the order table that fail, by number: the writes through it are counted from 1 (every write, the swap and the writes that put
/// places back alike). One whose number is in `failing` throws without writing, as a write the system refuses does; one in `afterWriting`
/// writes and then throws, as one that changed the file and could not say so does.
private final class FailingWrites: Sendable {
    private let failing: Set<Int>
    private let afterWriting: Set<Int>
    private let count = Mutex(0)

    init(failing: Set<Int> = [], afterWriting: Set<Int> = []) {
        self.failing = failing
        self.afterWriting = afterWriting
    }

    /// How many writes were tried, the failing ones included.
    var tried: Int { count.withLock { $0 } }

    func io() -> PlistIO {
        var io = PlistIO.filesOnly
        let write = io.write
        let writes = self
        io.write = { value, key, url, strategy in
            let number = writes.count.withLock { count -> Int in
                count += 1
                return count
            }
            if writes.failing.contains(number) { throw CocoaError(.fileWriteUnknown) }
            try write(value, key, url, strategy)
            if writes.afterWriting.contains(number) { throw CocoaError(.fileWriteUnknown) }
        }
        return io
    }
}

private func positions(_ url: URL) throws -> [String: Double] {
    let table = try #require(ProbeHarness.read(url)[trailing] as? [String: Any])
    return table.compactMapValues { ($0 as? NSNumber)?.doubleValue }
}

private func near(_ value: JSONValue?, _ expected: Double) -> Bool {
    if case .number(let number)? = value { return abs(number - expected) < 0.001 }
    return false
}

private func runs(_ report: ProbeReport) -> [[String: JSONValue]] {
    guard case .array(let list)? = report.measurements["runs"] else { return [] }
    return list.compactMap { if case .object(let object) = $0 { object } else { nil } }
}

@Suite("Layout-order probe", .timeLimit(.minutes(1)))
struct LayoutOrderProbeTests {
    // MARK: Refusals

    @Test func layoutOrderRefusesWithKeptRecords() async throws {
        let desk = try await world()
        // Somebody's arrangement is kept in the table: the probe won't write over it.
        try await desk.harness.plist.write([PathEdit(path: [.key(otherKey)], value: .integer(61))], key: trailing, in: desk.url, lifetime: .kept)
        let before = try Data(contentsOf: desk.url)

        let report = await desk.harness.run(.layoutOrder)

        #expect(report.errors == [LayoutOrderProbe.keptMessage])
        #expect(report.restored)
        #expect(try Data(contentsOf: desk.url) == before, "nothing was written")
        #expect(await desk.harness.journal.keptRecords().count == 1)
        for switchName in ["visibility", "relaunch-item", "dots", "dots-keep"] {
            let other = await desk.harness.run(.layoutOrder, [switchName: "true"])
            #expect(other.errors == [LayoutOrderProbe.keptMessage], "\(switchName)")
        }
        #expect(desk.harness.relauncher.asked.isEmpty && desk.harness.notifier.sent.isEmpty)
    }

    @Test func keptPlacesInOtherFilesAndOtherKeysDoNotCount() async throws {
        // Kept spacing is not the table's.
        let desk = try await world(barLag: .zero)
        try await desk.harness.defaults.write(.integer(4), forKey: IconSpacing.spacingKey, in: .globalCurrentHost, lifetime: .kept)
        let report = await desk.harness.run(.layoutOrder, ["runs": "1"])
        #expect(report.errors.isEmpty)
    }

    @Test func withoutAGrantThereIsNothingToDo() async throws {
        let harness = try ProbeHarness.make()
        let report = await harness.run(.layoutOrder)
        #expect(report.errors == [GrantedFile.missing(.menuBarLayout)])
    }

    @Test func theSwitchesThatCantBeTogetherAreRefused() async throws {
        let desk = try await world()
        let before = try Data(contentsOf: desk.url)
        let both = await desk.harness.run(.layoutOrder, ["dots": "true", "dots-keep": "true"])
        #expect(both.errors == ["Choose --dots or --dots-keep, not both."])
        let restoring = await desk.harness.run(.layoutOrder, ["dots-restore": "true", "dots": "true"])
        #expect(restoring.errors == ["--dots-restore runs alone."])
        #expect(try Data(contentsOf: desk.url) == before)
    }

    @Test func theItemIsOneOrAnExtra() async throws {
        let desk = try await world()
        let two = await desk.harness.run(.layoutOrder, ["item": "two"])
        #expect(two.errors == ["The item is one (swapped with two) or extra.<n> (swapped with extra.<n+1>)."])
        let last = await desk.harness.run(.layoutOrder, ["item": "extra.20"])
        #expect(last.errors.count == 1, "extra.20 has no next one to swap with")
    }

    @Test func theTableMustHoldBothItemsAndTheyMustBeInTheBar() async throws {
        let missing = try await world(table: [trailing: [oneKey: 120, otherKey: 60]])
        let report = await missing.harness.run(.layoutOrder)
        #expect(report.errors == ["The layout table has no entry for one and two. Run layout-map to see what it holds."])

        let same = try await world(table: [trailing: [oneKey: 120, twoKey: 120]])
        #expect(await same.harness.run(.layoutOrder).errors == ["one and two are at one distance, so swapping them changes nothing."])

        let gone = try await world()
        gone.harness.locator.remove(id("two"))
        let absent = await gone.harness.run(.layoutOrder)
        #expect(absent.errors.count == 1 && absent.errors[0].contains("aren't both found in the menu bar"))
        #expect(try ProbeHarness.read(gone.url) == gone.original, "nothing was written")
    }

    // MARK: Swap

    @Test func layoutOrderRecordsResortApplied() async throws {
        // The bar follows the table 300 ms after it changes.
        let desk = try await world(barLag: .milliseconds(300), framesLag: .milliseconds(300))
        let report = await desk.harness.run(.layoutOrder, ["runs": "2"])

        #expect(report.errors.isEmpty)
        #expect(report.restored)
        let records = runs(report)
        #expect(records.count == 2)
        for run in records {
            #expect(run["resortApplied"] == .bool(true))
            #expect(near(run["resortMs"], 300), "the first read after the bar followed")
            #expect(near(run["restoreMs"], 300))
            #expect(run["identifiable"] == .bool(true))
        }
        #expect(report.measurements["resortAppliedEveryRun"] == .bool(true))
        #expect(near(report.object("resortMs")?["p50"], 300))
        #expect(near(report.object("resortMs")?["max"], 300))
        #expect(report.measurements["neighbour"] == .string("two"))
    }

    @Test func aBarThatNeverResortsIsRecordedAsNotApplied() async throws {
        let desk = try await world(barLag: nil, framesLag: nil)
        let report = await desk.harness.run(.layoutOrder, ["runs": "2"])
        #expect(report.errors.isEmpty)
        #expect(report.restored, "and the table is put back all the same")
        for run in runs(report) {
            #expect(run["resortApplied"] == .bool(false))
            #expect(run["resortMs"] == .null)
        }
        #expect(report.measurements["resortAppliedEveryRun"] == .bool(false))
        #expect(report.measurements["resortAppliedNoRun"] == .bool(true))
        #expect(try ProbeHarness.read(desk.url) == desk.original)
    }

    @Test func layoutOrderRecordsFramesFollowed() async throws {
        // The bar re-sorts after 200 ms and the test item's own frames follow after a second.
        let desk = try await world(barLag: .milliseconds(200), framesLag: .seconds(1))
        let report = await desk.harness.run(.layoutOrder, ["runs": "2"])

        #expect(report.errors.isEmpty)
        for run in runs(report) {
            #expect(run["framesFollowed"] == .bool(true))
            #expect(near(run["framesFollowMs"], 1000))
            #expect(near(run["resortMs"], 200), "the bar and the frames are timed apart")
            #expect(near(run["framesBackMs"], 1000), "and the frames are waited for to be back before the next run")
        }
        #expect(report.measurements["framesFollowedEveryRun"] == .bool(true))
        #expect(near(report.object("framesFollowMs")?["p95"], 1000))
    }

    @Test func framesThatNeverFollowAreRecordedAsNotFollowed() async throws {
        let desk = try await world(barLag: .milliseconds(200), framesLag: nil)
        let report = await desk.harness.run(.layoutOrder, ["runs": "1"])
        let run = try #require(runs(report).first)
        #expect(run["resortApplied"] == .bool(true))
        #expect(run["framesFollowed"] == .bool(false))
        #expect(run["framesFollowMs"] == .null)
        #expect(report.measurements["framesFollowedEveryRun"] == .bool(false))
    }

    @Test func theFileCatchingUpIsTimedFromTheWrite() async throws {
        let desk = try await world()
        let report = await desk.harness.run(.layoutOrder, ["runs": "1"])
        #expect(near(runs(report).first?["fileFlushMs"], 0), "the harness writes the file with the write")
    }

    @Test func layoutOrderUndoesEveryPath() async throws {
        let log = WriteLog()
        let desk = try await world(barLag: .milliseconds(200), io: log.io())

        let report = await desk.harness.run(.layoutOrder, ["runs": "2"])

        #expect(report.errors.isEmpty)
        #expect(report.restored)
        #expect(try ProbeHarness.read(desk.url) == desk.original, "the file is as it was")
        #expect(await desk.harness.journal.records().isEmpty, "and nothing is left in the journal")
        // Every write changed the test item's two entries or one of them, and nothing else in the table.
        let before = try positions(desk.url)
        let allowed: Set<String> = [oneKey, twoKey]
        #expect(!log.all.isEmpty)
        for table in log.all {
            let changed = Set(table.keys.filter { table[$0] != before[$0] }).union(before.keys.filter { table[$0] == nil })
            #expect(changed.isSubset(of: allowed), "\(changed)")
        }
        // The first write is the swap, and is one write of the two places.
        let swap = try #require(log.all.first)
        #expect(swap[oneKey] == 70 && swap[twoKey] == 120)
    }

    @Test func theWritesAreTemporaryAndOfTheNewPlacesOnly() async throws {
        // A cut short probe: the writes are in the journal as temporary ones until they are put back.
        let clock = FakeClock()
        let desk = try await world(barLag: nil, clock: clock)
        let running = Task { await desk.harness.run(.layoutOrder, ["runs": "1"]) }
        await clock.waitForSleepers(1)
        let records = await desk.harness.journal.records()
        #expect(records.count == 2 && records.allSatisfy { $0.lifetime == .untilQuit })
        #expect(await desk.harness.journal.keptRecords().isEmpty)
        await desk.harness.runner.shutDown()
        let report = await running.value
        #expect(report.restored)
        #expect(report.notes.contains { $0.contains("cut short") })
        #expect(try ProbeHarness.read(desk.url) == desk.original)
        #expect(await desk.harness.journal.records().isEmpty)
    }

    @Test func aWriteThatFailsIsReportedAndWhateverWasWrittenIsPutBack() async throws {
        var io = PlistIO.filesOnly
        let write = io.write
        let calls = Mutex(0)
        io.write = { value, key, url, strategy in
            // The first write (the swap) goes through the file and then fails: it was changed all the same.
            try write(value, key, url, strategy)
            if calls.withLock({ $0 += 1; return $0 }) == 1 { throw CocoaError(.fileWriteUnknown) }
        }
        let desk = try await world(io: io)
        let report = await desk.harness.run(.layoutOrder, ["runs": "1"])
        #expect(!report.errors.isEmpty)
        #expect(try ProbeHarness.read(desk.url) == desk.original, "put back")
        #expect(await desk.harness.journal.records().isEmpty)
        #expect(report.restored)
    }

    // MARK: A table that won't go back

    private static let notPutBack = "The table couldn't be put back, so the probe stopped. Mantel puts it back when it next starts."

    @Test func aTableThatCantBePutBackStopsTheProbeBeforeTheGapAndTheNextRun() async throws {
        // Write 1 is the swap, 2 and 3 put its two places back: the second of those is refused.
        let writes = FailingWrites(failing: [3])
        let desk = try await world(io: writes.io())

        let report = await desk.harness.run(.layoutOrder, ["runs": "3"])

        #expect(report.errors.count == 2 && report.errors.last == Self.notPutBack, "\(report.errors)")
        #expect(report.errors.first?.hasPrefix("The table couldn't be put back:") == true, "and why is said first")
        #expect(writes.tried == 3, "no gap was written, and no second run was begun")
        #expect(runs(report).isEmpty, "the run did not finish")
        #expect(!report.restored)
        // The first place is back; the second is not, and is in the journal for Mantel to put back when it quits.
        let table = try positions(desk.url)
        #expect(table[oneKey] == 120 && table[twoKey] == 120)
        #expect(await desk.harness.journal.records().count == 1)
    }

    @Test func aGapThatCantBePutBackStopsTheProbeBeforeTheNextRun() async throws {
        // Writes 1 to 3 are the swap and its undoing, 4 is the gap, and 5 puts the gap back.
        let writes = FailingWrites(failing: [5])
        let desk = try await world(io: writes.io())

        let report = await desk.harness.run(.layoutOrder, ["runs": "3"])

        #expect(report.errors.count == 2 && report.errors.last == Self.notPutBack, "\(report.errors)")
        #expect(writes.tried == 5, "the next run's swap was not written")
        #expect(runs(report).isEmpty)
        #expect(!report.restored)
        #expect(await desk.harness.journal.records().count == 1, "the gap is still the journal's to put back")
    }

    @Test func aFailureBeforeAPutBackThatFailsIsSaidToo() async throws {
        // The swap changes the table and then fails, and putting back what it began is refused.
        let writes = FailingWrites(failing: [2], afterWriting: [1])
        let desk = try await world(io: writes.io())

        let report = await desk.harness.run(.layoutOrder, ["runs": "2"])

        #expect(report.errors.last == Self.notPutBack, "\(report.errors)")
        #expect(report.errors.contains { $0.hasPrefix("The probe stopped:") })
        #expect(!report.restored)
        #expect(runs(report).isEmpty)
    }

    @Test func dotsThatCantBePutBackStopTheProbeAllTheSame() async throws {
        // Write 1 moves both dots, and 2 and 3 put them back.
        let writes = FailingWrites(failing: [2])
        let desk = try await world(io: writes.io())

        let report = await desk.harness.run(.layoutOrder, ["dots": "true"])

        #expect(report.errors.last == Self.notPutBack, "\(report.errors)")
        #expect(!report.restored)
        #expect(report.measurements["dotsRestoredMs"] == nil)
    }

    // MARK: Gap

    @Test func whenADistanceIsAPlaceTheItemsDoNotPack() async throws {
        let desk = try await world()
        let report = await desk.harness.run(.layoutOrder, ["runs": "1"])

        let run = try #require(runs(report).first)
        // Item two (the one on the right) is written 600 beyond item one: 720, which is x = 2500, and its slot ends at 2540. Item one starts
        // at 3100, and Mantel's dot is between (30 points wide).
        #expect(run["gapPt"] == .number(560))
        #expect(run["slotsBetween"] == .number(1))
        #expect(run["deadSpace"] == .number(530))
        #expect(run["packs"] == .bool(false))
        #expect(report.measurements["packsNoRun"] == .bool(true))
        #expect(try ProbeHarness.read(desk.url) == desk.original)
    }

    @Test func whenADistanceIsOnlyAnOrderTheItemsPack() async throws {
        let desk = try await world(mode: .order)
        let report = await desk.harness.run(.layoutOrder, ["runs": "2"])

        for run in runs(report) {
            #expect(run["resortApplied"] == .bool(true))
            #expect(run["gapPt"] == .number(0), "side by side")
            #expect(run["deadSpace"] == .number(0))
            #expect(run["packs"] == .bool(true))
        }
        #expect(report.measurements["packsEveryRun"] == .bool(true))
        #expect(try ProbeHarness.read(desk.url) == desk.original)
    }

    @Test func theGapIsNotMeasuredWhenTheItemNeverArrives() async throws {
        // The bar never re-sorts: nothing is measured, and the place is put back.
        let desk = try await world(barLag: nil)
        let report = await desk.harness.run(.layoutOrder, ["runs": "1"])
        let run = try #require(runs(report).first)
        #expect(run["packs"] == .null && run["gapPt"] == .null)
        #expect(try ProbeHarness.read(desk.url) == desk.original)
    }

    // MARK: Extra items

    @Test func anExtraItemIsSwappedWithTheNextOne() async throws {
        // Slots with no name, of different widths.
        let desk = try await world(extras: [36, 30])
        let report = await desk.harness.run(.layoutOrder, ["item": "extra.1", "runs": "1"])

        #expect(report.errors.isEmpty, "\(report.errors)")
        #expect(report.measurements["item"] == .string("extra.1") && report.measurements["neighbour"] == .string("extra.2"))
        let run = try #require(runs(report).first)
        #expect(run["identifiable"] == .bool(true), "they are told apart by their widths")
        #expect(run["resortApplied"] == .bool(true))
        #expect(run["framesFollowed"] == .bool(true))
        #expect(try ProbeHarness.read(desk.url) == desk.original)
    }

    @Test func twoSlotsWithNoNameAndOneWidthCantBeToldApartByTheBar() async throws {
        let desk = try await world(extras: [36, 36])
        let report = await desk.harness.run(.layoutOrder, ["item": "extra.1", "runs": "1"])

        let run = try #require(runs(report).first)
        #expect(run["identifiable"] == .bool(false))
        #expect(run["resortApplied"] == .null, "neither true nor false: the order of the slots says nothing")
        #expect(run["framesFollowed"] == .bool(true), "and the test item's own frames still say where its items went")
        #expect(report.notes.contains { $0.contains("can't tell them apart") })
        #expect(try ProbeHarness.read(desk.url) == desk.original)
    }

    // MARK: Visibility

    private func visibilityDesk(returningTo place: CGRect? = nil, clock: any Clock = SteppingClock()) async throws -> (World, Switch) {
        let desk = try await world(clock: clock)
        // The test item is started with extras: three items.
        desk.harness.ax.addApp(pid: 300, extras: (0..<3).map { .init(title: "item \($0)", frame: CGRect(x: 3100 + 50 * CGFloat($0), y: 0, width: 40, height: 31)) })
        let hidden = Switch(false)
        let wasHidden = Switch(false)
        let frames = ["one": CGRect(x: 3100, y: 0, width: 40, height: 31), "two": CGRect(x: 3150, y: 0, width: 40, height: 31),
                      "extra.1": CGRect(x: 3200, y: 0, width: 40, height: 31)]
        for (name, frame) in frames {
            let item = id(name)
            desk.harness.locator.answer(for: item) { _ in
                if name == "extra.1" {
                    if hidden.isOn { return nil }
                    return FakeItemLocator.location(of: item, slot: wasHidden.isOn ? (place ?? frame) : frame, tiedBy: .tie)
                }
                return FakeItemLocator.location(of: item, slot: frame, tiedBy: .tie)
            }
        }
        desk.harness.notifier.onNotify { _ in
            hidden.set(!hidden.isOn)
            if hidden.isOn { wasHidden.set(true) }
        }
        return (desk, hidden)
    }

    @Test func layoutOrderVisibilityTogglesExtraOne() async throws {
        let (desk, hidden) = try await visibilityDesk()

        let report = await desk.harness.run(.layoutOrder, ["visibility": "true"])

        #expect(report.errors.isEmpty)
        #expect(desk.harness.notifier.sent == [TestItemCommands.toggleExtraOne, TestItemCommands.toggleExtraOne], "hidden, then shown")
        #expect(TestItemCommands.toggleExtraOne == "toggle-extra-1")
        #expect(!hidden.isOn)
        #expect(report.measurements["extraOneGoneWhileHidden"] == .bool(true))
        #expect(report.measurements["visibilityKeptPlace"] == .bool(true))
        #expect(report.restored)
        guard case .object(let before)? = report.measurements["itemsBefore"] else {
            Issue.record("itemsBefore")
            return
        }
        #expect(Set(before.keys) == ["one", "two", "extra.1"])
        #expect(await desk.harness.journal.records().isEmpty, "the table is not written")
        #expect(try ProbeHarness.read(desk.url) == desk.original)
    }

    @Test func anItemThatComesBackElsewhereDidNotKeepItsPlace() async throws {
        let (desk, _) = try await visibilityDesk(returningTo: CGRect(x: 3050, y: 0, width: 40, height: 31))
        let report = await desk.harness.run(.layoutOrder, ["visibility": "true"])
        #expect(report.measurements["visibilityKeptPlace"] == .bool(false))
    }

    @Test func visibilityNeedsTheTestItemStartedWithExtras() async throws {
        let desk = try await world()
        let report = await desk.harness.run(.layoutOrder, ["visibility": "true"])
        #expect(report.errors == ["Open the test item with extras first: open /Applications/MantelTestItem.app --args --extra 2"])
        #expect(desk.harness.notifier.sent.isEmpty)
    }

    @Test func aProbeCutShortWhileTheItemIsHiddenShowsItAgain() async throws {
        let clock = FakeClock()
        let (desk, hidden) = try await visibilityDesk(clock: clock)
        let running = Task { await desk.harness.run(.layoutOrder, ["visibility": "true"]) }
        await clock.waitForSleepers(1)
        #expect(hidden.isOn, "the item is hidden while the probe waits")

        await desk.harness.runner.shutDown()
        let report = await running.value

        #expect(!hidden.isOn, "and shown again")
        #expect(desk.harness.notifier.sent.count == 2)
        #expect(report.restored)
    }

    // MARK: Relaunching

    private func relaunchDesk(extras count: Int = 2) async throws -> World {
        let desk = try await world()
        let listed = (0..<(2 + count)).map { index -> FakeAX.Extra in
            .init(title: "item \(index)", frame: CGRect(x: 3000 + 50 * CGFloat(index), y: 0, width: 40, height: 31))
        }
        desk.harness.ax.addApp(pid: 300, extras: listed)
        return desk
    }

    private func place(_ order: [String], in desk: World) {
        for (index, name) in order.enumerated() {
            desk.harness.locator.place(FakeItemLocator.location(of: id(name), slot: CGRect(x: 3000 + 50 * CGFloat(index), y: 0, width: 40, height: 31),
                                                               tiedBy: .tie))
        }
    }

    @Test func layoutOrderRelaunchesOnlyTheTestItemWithItsExtras() async throws {
        let desk = try await relaunchDesk()
        let names = ["one", "two", "extra.1", "extra.2"]
        place(names, in: desk)

        let report = await desk.harness.run(.layoutOrder, ["relaunch-item": "true", "extra-count": "2", "allow-any": "true"])

        #expect(report.errors.isEmpty)
        let asked = desk.harness.relauncher.asked
        #expect(asked.count == 1)
        #expect(asked.first?.id == fixtureID && asked.first?.pid == 300)
        #expect(asked.first?.arguments == ["--extra", "2"])
        #expect(report.measurements["relaunch"] == .string("relaunched"))
        #expect(report.strings("orderBefore") == names)
        #expect(report.strings("orderAfter") == names)
        #expect(report.measurements["relaunchKeptPlaces"] == .bool(true))
        #expect(desk.harness.poster.clicks.isEmpty && desk.harness.presser.pressed.isEmpty && desk.harness.allowlist.calls.isEmpty)
        #expect(try ProbeHarness.read(desk.url) == desk.original, "nothing is written")
        #expect(await desk.harness.journal.records().isEmpty)
    }

    @Test func theExtraCountDefaultsToWhatTheTestItemHasAndCanBeChanged() async throws {
        let desk = try await relaunchDesk(extras: 2)
        place(["one", "two", "extra.1", "extra.2"], in: desk)
        _ = await desk.harness.run(.layoutOrder, ["relaunch-item": "true"])
        #expect(desk.harness.relauncher.asked.map(\.arguments) == [["--extra", "2"]])

        let none = try await relaunchDesk(extras: 2)
        place(["one", "two"], in: none)
        let report = await none.harness.run(.layoutOrder, ["relaunch-item": "true", "extra-count": "0"])
        #expect(none.harness.relauncher.asked.map(\.arguments) == [[]])
        #expect(report.strings("orderAfter") == ["one", "two"])
    }

    @Test func aTestItemThatIsOneItemAloneIsOpenedAgainAsOneItemAlone() async throws {
        // It was started with --single: its own list has the one item.
        let desk = try await world()
        desk.harness.ax.addApp(pid: 300, extras: [.init(title: "one", frame: CGRect(x: 3000, y: 0, width: 40, height: 31))])
        place(["one"], in: desk)

        let report = await desk.harness.run(.layoutOrder, ["relaunch-item": "true"])

        #expect(report.errors.isEmpty, "\(report.errors)")
        #expect(desk.harness.relauncher.asked.map(\.arguments) == [["--single"]], "not as the plain two")
        #expect(report.strings("orderBefore") == ["one"] && report.strings("orderAfter") == ["one"])
        #expect(report.measurements["extraCount"] == .number(0))
        #expect(report.measurements["relaunchKeptPlaces"] == .bool(true))
    }

    @Test func aCountThatIsGivenWinsOverTheItemsTheTestItemHas() async throws {
        let desk = try await world()
        desk.harness.ax.addApp(pid: 300, extras: [.init(title: "one", frame: CGRect(x: 3000, y: 0, width: 40, height: 31))])
        place(["one", "two"], in: desk)

        let report = await desk.harness.run(.layoutOrder, ["relaunch-item": "true", "extra-count": "0"])

        #expect(desk.harness.relauncher.asked.map(\.arguments) == [[]], "opened as the plain two, as it was asked")
        #expect(report.strings("orderAfter") == ["one", "two"])
    }

    @Test func itemsThatCameBackInAnotherOrderDidNotKeepTheirPlaces() async throws {
        let desk = try await relaunchDesk()
        place(["one", "two", "extra.1", "extra.2"], in: desk)
        // After the relaunch the extras are in front of the first two.
        let harness = desk.harness
        let relaunched = Switch(false)
        for (index, name) in ["extra.1", "extra.2", "one", "two"].enumerated() {
            let item = id(name)
            harness.locator.answer(for: item) { _ in
                let order = relaunched.isOn ? ["extra.1", "extra.2", "one", "two"] : ["one", "two", "extra.1", "extra.2"]
                let place = order.firstIndex(of: name) ?? index
                return FakeItemLocator.location(of: item, slot: CGRect(x: 3000 + 50 * CGFloat(place), y: 0, width: 40, height: 31), tiedBy: .tie)
            }
        }
        harness.relauncher.onRelaunch { _ in relaunched.set(true) }

        let report = await harness.run(.layoutOrder, ["relaunch-item": "true"])

        #expect(report.strings("orderBefore") == ["one", "two", "extra.1", "extra.2"])
        #expect(report.strings("orderAfter") == ["extra.1", "extra.2", "one", "two"])
        #expect(report.measurements["relaunchKeptPlaces"] == .bool(false))
    }

    @Test func theTestItemsPreferredPositionKeysAreCountedBeforeAndAfter() async throws {
        let counts = Mutex([4, 6])
        let desk = try await world { platform in
            platform.testItemPreferredPositionKeyCount = { counts.withLock { $0.isEmpty ? 0 : $0.removeFirst() } }
        }
        place(["one", "two"], in: desk)
        let report = await desk.harness.run(.layoutOrder, ["relaunch-item": "true"])
        #expect(report.measurements["testItemPreferredPositionKeyCountBefore"] == .number(4))
        #expect(report.measurements["testItemPreferredPositionKeyCountAfter"] == .number(6))
    }

    @Test func aTestItemThatDoesNotRelaunchIsSaidAndNotForced() async throws {
        let desk = try await world()
        place(["one", "two"], in: desk)
        desk.harness.relauncher.respond(with: .didNotQuit)
        let report = await desk.harness.run(.layoutOrder, ["relaunch-item": "true"])
        #expect(report.measurements["relaunch"] == .string("didNotQuit"))
        #expect(report.measurements["relaunchKeptPlaces"] == nil)
        #expect(desk.harness.relauncher.asked.count == 1)
    }

    // MARK: The dots

    private func dotPaths() -> Set<PlistKeyPath> { [[.key(hiddenDotKey)], [.key(alwaysDotKey)]] }

    @Test func dotsKeepIsKeptAndDotsRestoreRemovesIt() async throws {
        let desk = try await world(barLag: .milliseconds(200))

        // The dots are given places between the system's items (up to 30) and the apps' (from 60), and left there, kept.
        let kept = await desk.harness.run(.layoutOrder, ["dots-keep": "true"])
        #expect(kept.errors.isEmpty, "\(kept.errors)")
        #expect(kept.measurements["kept"] == .bool(true))
        #expect(near(kept.measurements["dotsMovedMs"], 200))
        let table = try positions(desk.url)
        #expect(table[hiddenDotKey] == 40 && table[alwaysDotKey] == 50, "• nearer the system's items than ••")
        let records = await desk.harness.journal.keptRecords()
        #expect(records.count == 2 && records.allSatisfy { $0.lifetime == .kept })
        #expect(Set(records.compactMap { record -> PlistKeyPath? in
            if case .plistPath(_, _, let path, _, _, _) = record.entry { path } else { nil }
        }) == dotPaths())
        #expect(!kept.restored, "a change was left in place, on purpose")
        #expect(kept.notes.contains { $0.contains("--dots-restore") })
        #expect(await desk.harness.journal.untilQuitRecords().isEmpty, "none of them is put back on quit")

        // What is kept stops the other steps, until it is restored.
        let refused = await desk.harness.run(.layoutOrder)
        #expect(refused.errors == [LayoutOrderProbe.keptMessage])

        let restored = await desk.harness.run(.layoutOrder, ["dots-restore": "true"])
        #expect(restored.errors.isEmpty, "\(restored.errors)")
        #expect(restored.measurements["restored"] == .bool(true))
        #expect(restored.measurements["restoredPlaces"] == .number(2))
        #expect(try ProbeHarness.read(desk.url) == desk.original, "the entries that were not there are gone again")
        #expect(await desk.harness.journal.records().isEmpty)

        let again = await desk.harness.run(.layoutOrder, ["runs": "1"])
        #expect(again.errors.isEmpty, "the probe runs again")
    }

    @Test func aKeptWriteThatFailsIsPutBackByARestoreNotAnUndo() async throws {
        // The write goes through the file and then fails: its places are kept, and only a restore puts a kept place back.
        var io = PlistIO.filesOnly
        let write = io.write
        let calls = Mutex(0)
        io.write = { value, key, url, strategy in
            try write(value, key, url, strategy)
            if calls.withLock({ $0 += 1; return $0 }) == 1 { throw CocoaError(.fileWriteUnknown) }
        }
        let desk = try await world(io: io)

        let report = await desk.harness.run(.layoutOrder, ["dots-keep": "true"])

        #expect(!report.errors.isEmpty)
        #expect(try ProbeHarness.read(desk.url) == desk.original, "put back")
        #expect(await desk.harness.journal.records().isEmpty, "and nothing is kept")
        #expect(report.restored)
    }

    @Test func dotsRestoreRefusesWhenOtherPathsAreKept() async throws {
        let desk = try await world()
        _ = await desk.harness.run(.layoutOrder, ["dots-keep": "true"])
        // Somebody's arrangement is kept in the table too.
        try await desk.harness.plist.write([PathEdit(path: [.key(otherKey)], value: .integer(61))], key: trailing, in: desk.url, lifetime: .kept)
        let before = try Data(contentsOf: desk.url)

        let report = await desk.harness.run(.layoutOrder, ["dots-restore": "true"])

        #expect(report.errors == [LayoutOrderProbe.otherKeptMessage])
        #expect(try Data(contentsOf: desk.url) == before, "nothing was put back")
        #expect(await desk.harness.journal.keptRecords().count == 3)
        #expect(report.measurements["restored"] == nil)
    }

    @Test func dotsRestoreWithNothingKeptSaysSoAndIsNoRefusal() async throws {
        let desk = try await world()
        let before = try Data(contentsOf: desk.url)

        let report = await desk.harness.run(.layoutOrder, ["dots-restore": "true"])

        #expect(report.errors.isEmpty, "\(report.errors)")
        #expect(report.measurements["restoredPlaces"] == .number(0))
        #expect(report.measurements["keptPlaces"] == .number(0))
        #expect(report.measurements["restored"] == .bool(true), "nothing is out of place")
        #expect(report.notes == ["Nothing was kept."])
        #expect(try Data(contentsOf: desk.url) == before, "and nothing was written")
        #expect(await desk.harness.journal.records().isEmpty)
    }

    @Test(arguments: [hiddenDotKey, alwaysDotKey])
    func dotsRestoreRefusesWhenOnlyOneOfTheDotsPlacesIsKept(key: String) async throws {
        // The dots' two places are what the dots' step keeps; one of them alone is not that.
        let desk = try await world()
        try await desk.harness.plist.write([PathEdit(path: [.key(key)], value: .integer(40))], key: trailing, in: desk.url, lifetime: .kept)
        let before = try Data(contentsOf: desk.url)

        let report = await desk.harness.run(.layoutOrder, ["dots-restore": "true"])

        #expect(report.errors == [LayoutOrderProbe.otherKeptMessage])
        #expect(report.measurements["restored"] == nil && report.measurements["restoredPlaces"] == nil)
        #expect(try Data(contentsOf: desk.url) == before, "nothing was put back")
        #expect(await desk.harness.journal.keptRecords().count == 1)
    }

    @Test func dotsStepsWriteOnlyTheDotKeys() async throws {
        for keep in [false, true] {
            let log = WriteLog()
            let desk = try await world(barLag: .milliseconds(100), io: log.io())
            let report = await desk.harness.run(.layoutOrder, [keep ? "dots-keep" : "dots": "true"])

            #expect(report.errors.isEmpty, "\(report.errors)")
            let before = try positions(desk.url)
            #expect(!log.all.isEmpty)
            for table in log.all {
                let changed = Set(table.keys.filter { table[$0] != before[$0] })
                #expect(changed.isSubset(of: [hiddenDotKey, alwaysDotKey]), "\(changed)")
                for key in [hiddenDotKey, alwaysDotKey] where table[key] != nil {
                    #expect(table[key]! > 30 && table[key]! < 60, "between the system's items and the apps': \(table[key]!)")
                }
            }
            if !keep {
                #expect(try ProbeHarness.read(desk.url) == desk.original, "put back")
                #expect(await desk.harness.journal.records().isEmpty)
                #expect(report.restored)
            }
            // And Mantel's own is the only item of Mantel's that was written.
            #expect(desk.harness.relauncher.asked.isEmpty && desk.harness.allowlist.calls.isEmpty)
        }
    }

    @Test func theDotsAreGivenRealNumbersWhenThereIsNoRoomForWholeOnes() {
        let places = LayoutOrderProbe.dotDistances(
            table: ["module:Clock": .integer(10), "module:Wifi": .integer(12), otherKey: .integer(15), oneKey: .integer(120)],
            dotKeys: [hiddenDotKey, alwaysDotKey])
        #expect(places?.hidden == 13 && places?.always == 14)
        #expect(LayoutOrderProbe.dotDistances(table: ["module:Clock": .integer(20), otherKey: .integer(20)], dotKeys: []) == nil, "no room")
        #expect(LayoutOrderProbe.dotDistances(table: ["module:Clock": .integer(10)], dotKeys: []) == nil, "no apps")
        // The dots' own entries and the other values that aren't numbers are not what the room is between.
        let own = LayoutOrderProbe.dotDistances(table: ["module:Clock": .integer(10), otherKey: .integer(40), hiddenDotKey: .integer(5),
                                                        "status:\(otherID)::y": .string("x")], dotKeys: [hiddenDotKey])
        #expect(own?.hidden == 20 && own?.always == 30)
    }

    @Test func dotsThatNeverMoveAreNullAndStillPutBack() async throws {
        let desk = try await world(barLag: nil)
        let report = await desk.harness.run(.layoutOrder, ["dots": "true"])
        #expect(report.errors.isEmpty)
        #expect(report.measurements["dotsMovedMs"] == .null)
        #expect(report.notes.contains { $0.contains("didn't move") })
        #expect(try ProbeHarness.read(desk.url) == desk.original)
        #expect(report.restored)
    }

    @Test func noRoomForTheDotsIsSaid() async throws {
        let desk = try await world(table: [trailing: [oneKey: 120, twoKey: 70, otherKey: 30, "module:Clock": 30]])
        let report = await desk.harness.run(.layoutOrder, ["dots": "true"])
        #expect(report.errors.count == 1 && report.errors[0].contains("no room in the table"))
        #expect(try ProbeHarness.read(desk.url) == desk.original)
    }
}
