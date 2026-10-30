import Foundation
import MKCore
import MKTestSupport
import Synchronization
import Testing

@testable import MKMenuBar

/// How many of the reads are under way at once, and the most there were.
private final class Counter: Sendable {
    private let state = Mutex((now: 0, most: 0))

    func enter() { state.withLock { $0.now += 1; $0.most = max($0.most, $0.now) } }
    func leave() { state.withLock { $0.now -= 1 } }
    var most: Int { state.withLock { $0.most } }
}

@Suite("Read gate", .timeLimit(.minutes(1)))
struct ReadGateTests {
    @Test func twoCallsThatShareAGateAreHeldToItsLimitTogether() async {
        // A scan and a look at one item, each with its own limit of eight, are held to eight in all: the blocking reads they are made of
        // would otherwise take sixteen of the threads the system has.
        let gate = ReadGate(limit: 3)
        let counter = Counter()
        let work: @Sendable (Int) async -> Int = { item in
            counter.enter()
            for _ in 0..<20 { await Task.yield() }
            counter.leave()
            return item
        }

        async let scan = ConcurrentMap.map(Array(0..<12), limit: 8, gate: gate, work)
        async let look = ConcurrentMap.map(Array(100..<108), limit: 8, gate: gate, work)
        let (scanned, looked) = await (scan, look)

        #expect(scanned == Array(0..<12) && looked == Array(100..<108), "every result, in the order of its items")
        #expect(counter.most <= 3, "at most the gate's limit were under way at once: \(counter.most)")
        #expect(counter.most > 1, "and they did run side by side")
        #expect(gate.running == 0)
    }

    @Test func withoutAGateEachCallHasItsOwnLimit() async {
        let counter = Counter()
        let work: @Sendable (Int) async -> Int = { item in
            counter.enter()
            for _ in 0..<20 { await Task.yield() }
            counter.leave()
            return item
        }
        async let first = ConcurrentMap.map(Array(0..<8), limit: 4, work)
        async let second = ConcurrentMap.map(Array(0..<8), limit: 4, work)
        _ = await (first, second)
        #expect(counter.most > 4, "two calls with a limit of four each can run eight")
    }

    @Test func theScannersScanAndLocateShareOneGate() async {
        let scanner = MenuBarScanner(ax: FakeAX(), runningApps: { [] }, layout: { DisplayLayout(displays: []) },
                                     ownBundleID: "com.example.mantel", isTrusted: { true }, clock: FakeClock())
        let gate = await scanner.readGate
        #expect(gate.limit == MenuBarReader.concurrency)
    }
}
