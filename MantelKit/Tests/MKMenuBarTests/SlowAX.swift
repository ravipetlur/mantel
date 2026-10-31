import Foundation
import MKCore
import MKTestSupport
import Synchronization

@testable import MKMenuBar

/// A fake tree whose apps are slow, on the test's clock: a call that waits for `wait` seconds for an app that needs longer gives
/// `AXReadError.timeout` after having taken `wait` of the clock's time, and one that waits long enough takes the app's time and is
/// answered. An app that never answers (`hang`) takes every wait it is given. Nothing waits in real time.
final class SlowAX: AXReading {
    /// A call that was made: the app, and how long it was told to wait.
    struct Call: Equatable {
        let pid: pid_t
        let wait: TimeInterval
    }

    private struct State {
        var delays: [pid_t: TimeInterval] = [:]
        var hung: Set<pid_t> = []
        var slowFor: [pid_t: Int] = [:]
        var calls: [Call] = []
        /// Queries of an attribute that miss every wait they are given: the app, the attribute, how many calls to let through first, and how
        /// many then time out.
        var misses: [Miss] = []
    }

    private struct Miss {
        let pid: pid_t
        let name: String
        var skip: Int
        var left: Int
    }

    private let source: @Sendable () -> FakeAX
    private let ownerOf: @Sendable (AXElementRef) -> pid_t?
    private let applicationOf: @Sendable (pid_t) -> AXElementRef
    var tree: FakeAX { source() }
    let clock: FakeClock
    private let state = Mutex(State())
    private let stopped = Mutex(0)
    private let afterTimeout = Mutex<(@Sendable () -> Void)?>(nil)

    init(_ tree: FakeAX, clock: FakeClock) {
        source = { tree }
        ownerOf = { tree.ownerPID(of: $0) }
        applicationOf = { tree.application(pid: $0) }
        self.clock = clock
    }

    /// Slow over whichever tree a world has now (`WorldAX`).
    init(world: SessionWorld, clock: FakeClock) {
        source = { world.fixture().ax }
        ownerOf = { world.ownerPID(of: $0) }
        applicationOf = { world.treeApplication(pid: $0, in: world.fixture().ax) }
        self.clock = clock
    }

    /// The app takes this long (seconds) to answer each call, or, with `forCalls`, only its first calls.
    func setDelay(_ seconds: TimeInterval, for pid: pid_t, forCalls count: Int? = nil) {
        state.withLock {
            $0.delays[pid] = seconds
            $0.slowFor[pid] = count
        }
    }

    /// Of the queries for `name` that are made to the app from now on, the next `calls` calls time out (so that, with a ladder of three
    /// waits, `calls: 3` is one query that misses every wait) after `skipping` calls have been answered. The rest are answered.
    func miss(_ name: String, of pid: pid_t, skipping skip: Int = 0, calls count: Int) {
        state.withLock { $0.misses.append(Miss(pid: pid, name: name, skip: skip, left: count)) }
    }

    /// Runs `hook` each time a call has waited out its wait and timed out (the app quits while a query is partway through its waits).
    func onTimeout(_ hook: (@Sendable () -> Void)?) { afterTimeout.withLock { $0 = hook } }

    func hang(_ pid: pid_t) { state.withLock { _ = $0.hung.insert(pid) } }
    func release(_ pid: pid_t) { state.withLock { _ = $0.hung.remove(pid) } }

    var calls: [Call] { state.withLock { $0.calls } }
    func calls(to pid: pid_t) -> [Call] { calls.filter { $0.pid == pid } }
    var stopWaitingCalls: Int { stopped.withLock { $0 } }

    func stopWaiting() { stopped.withLock { $0 += 1 } }

    // MARK: AXReading

    func attribute(_ name: String, of element: AXElementRef) throws(AXReadError) -> AXValueBox {
        try attribute(name, of: element, wait: 0.25)
    }

    func attribute(_ name: String, of element: AXElementRef, wait: TimeInterval) throws(AXReadError) -> AXValueBox {
        let pid = ownerOf(element) ?? 0
        let decided = state.withLock { state -> (hung: Bool, delay: TimeInterval) in
            state.calls.append(Call(pid: pid, wait: wait))
            var delay = state.delays[pid] ?? 0
            if let left = state.slowFor[pid] {
                if left > 0 { state.slowFor[pid] = left - 1 } else { delay = 0 }
            }
            var misses = state.hung.contains(pid)
            if let at = state.misses.firstIndex(where: { $0.pid == pid && $0.name == name && $0.left > 0 }) {
                if state.misses[at].skip > 0 {
                    state.misses[at].skip -= 1
                } else {
                    state.misses[at].left -= 1
                    misses = true
                }
            }
            return (misses, delay)
        }
        if decided.hung || decided.delay > wait {
            clock.advance(by: .seconds(wait))
            afterTimeout.withLock { $0 }?()
            throw .timeout
        }
        clock.advance(by: .seconds(decided.delay))
        return try tree.attribute(name, of: element)
    }

    func children(of element: AXElementRef) throws(AXReadError) -> [AXElementRef] {
        if case .elements(let children) = try attribute(AXName.children, of: element) { return children }
        return []
    }

    func application(pid: pid_t) -> AXElementRef { applicationOf(pid) }
    func press(_ element: AXElementRef) throws(AXReadError) { try tree.press(element) }
}
