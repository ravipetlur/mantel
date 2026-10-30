import Foundation
import Synchronization

/// How many reads that block (Accessibility calls) run at once.
///
/// A blocked read holds one of the threads Swift's tasks run on, and there are as many of those as the Mac has processors. A read that
/// waits longer for a busy Mac (`PatientAX`) holds its thread longer; if the reads took every thread, nothing else that has to run (the
/// quit's timer, the teardown, the next click) would have one until they gave theirs back. So the reads leave four of them free, and
/// are never fewer than four or more than eight, on a Mac with eight processors or more (every Mac that runs macOS 27). A machine with
/// fewer (a virtual machine, a build server) gets half of them, at least one, so that the reads never take every thread.
enum ReadConcurrency {
    static let minimum = 4
    static let maximum = 8
    static let threadsLeftFree = 4

    static func limit(processors: Int) -> Int {
        guard processors >= minimum + threadsLeftFree else { return max(1, processors / 2) }
        return max(minimum, min(maximum, processors - threadsLeftFree))
    }

    static var current: Int { limit(processors: ProcessInfo.processInfo.activeProcessorCount) }
}

/// A limit on how many reads that block, shared by every caller that is given it: a scan and a look at one item that run
/// together (a reveal is read while the session scans) take turns, and don't each take eight of the threads the system has.
final class ReadGate: Sendable {
    private struct State {
        var running = 0
        var waiters: [CheckedContinuation<Void, Never>] = []
    }

    let limit: Int
    private let state = Mutex(State())

    init(limit: Int) {
        self.limit = max(limit, 1)
    }

    /// How many reads are running now, and how many wait for their turn. For tests and for the log of a quit that overran.
    var running: Int { state.withLock { $0.running } }
    var waiting: Int { state.withLock { $0.waiters.count } }

    /// Runs `body` once fewer than `limit` reads are running, in the order the callers came.
    ///
    /// The time a read of a scope that excuses it (`AXReadScope`) waits for its turn doesn't count against that scope's deadline.
    func run<T: Sendable>(_ body: @Sendable () async -> T) async -> T {
        let scope = AXReadScope.current
        let queued = scope?.gateWaitBegan()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let ready = state.withLock { state -> Bool in
                if state.running < limit {
                    state.running += 1
                    return true
                }
                state.waiters.append(continuation)
                return false
            }
            if ready { continuation.resume() }
        }
        scope?.gateWaitEnded(since: queued)
        let result = await body()
        let next = state.withLock { state -> CheckedContinuation<Void, Never>? in
            if state.waiters.isEmpty {
                state.running -= 1
                return nil
            }
            // The slot goes to the one that waited longest, and is still counted.
            return state.waiters.removeFirst()
        }
        next?.resume()
        return result
    }
}

/// Running work on many things at once, with a limit.
enum ConcurrentMap {
    /// `transform` for each item, at most `limit` at a time, results in the order of the items. The work of the reads this is for
    /// blocks (it is Accessibility calls), so the limit keeps it from taking every thread the system has. With a `gate`, every call that
    /// shares it is held to the gate's limit together.
    static func map<Item: Sendable, Result: Sendable>(
        _ items: [Item], limit: Int, gate: ReadGate? = nil, _ transform: @escaping @Sendable (Item) async -> Result
    ) async -> [Result] {
        await withTaskGroup(of: (Int, Result).self) { group in
            var results: [Result?] = Array(repeating: nil, count: items.count)
            var next = 0
            func addNext() {
                guard next < items.count else { return }
                let index = next
                let item = items[index]
                next += 1
                group.addTask {
                    guard let gate else { return (index, await transform(item)) }
                    return (index, await gate.run { await transform(item) })
                }
            }
            for _ in 0..<min(max(limit, 1), items.count) { addNext() }
            while let (index, result) = await group.next() {
                results[index] = result
                addNext()
            }
            return results.compactMap { $0 }
        }
    }
}
