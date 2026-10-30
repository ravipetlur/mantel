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

    @Test func aCancelledWaiterReturnsAtOnceWhileTheOnlySlotIsHeld() async {
        let gate = ReadGate(limit: 1)
        let held = Gate()
        let holder = Task { await gate.run { await held.wait() } }
        #expect(await waitUntil { gate.running == 1 }, "the first read has the only slot")

        let finished = Mutex(false)
        let waiter = Task { () -> Int? in
            let result = await gate.run { 1 }
            finished.withLock { $0 = true }
            return result
        }
        #expect(await waitUntil { gate.waiting == 1 }, "the second read waits for it")

        waiter.cancel()
        let returned = await waitUntil { finished.withLock { $0 } }
        #expect(returned, "the cancelled read is back while the slot is still held, and doesn't wait for ever")
        #expect(gate.waiting == 0 && gate.running == 1, "it left the queue, and the held slot is still held")

        held.open()
        _ = await holder.value
        #expect(await waiter.value == nil, "it gave no answer, and its read never ran")
        #expect(await gate.run { 2 } == 2, "the slot was not lost: a later read gets it")
        #expect(gate.running == 0)
    }
}
