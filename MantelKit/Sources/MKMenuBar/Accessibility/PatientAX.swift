import ApplicationServices
import Foundation
import MKCore
import Synchronization

/// What an app has done when asked, as far as Mantel has seen: how long it is worth waiting for.
public enum AXAppHistory: Sendable, Equatable {
    /// It has answered a query before (even to say it has no such attribute): a slow answer from it is a busy Mac, and worth waiting for.
    case answered
    /// Nothing is known of it yet.
    case unknown
    /// It has never answered, and has timed out at every wait it was given, a minute ago or less: a helper or an agent with no user
    /// interface, that never will. A minute later it is asked as an app nothing is known of again (`AXPatience.silenceLasts`).
    case silent
}

/// How long Accessibility queries wait for an app on a busy Mac, and how much of the read's time one app may take.
///
/// - **A query that times out is asked again with a longer wait** (`waits`): 0.25 s, then 1 s, then 2 s. The first wait is what a Mac
///   that isn't busy needs; the others are for a Mac that is, where MenuBarAgent and the apps answer later.
/// - **Not every app is worth the whole ladder.** One that has never answered (`AXAppHistory.silent`: Xcode's and WebKit's helpers, agents
///   with no menu bar items, that time out on the extras menu bar every time) is asked once, so that it doesn't cost each read its
///   timeouts again; one nothing is known of is asked twice. Silence is a state of a minute (`silenceLasts`), and an app isn't called
///   silent in the first minute it is asked of (`youngFor`): a Mac that is busy makes an app late, and an app that is late isn't one that
///   never answers.
/// - **An app that has answered and then timed out at every wait it was given** is asked with the first wait only for `learnedFor`, or
///   until it answers again: it is hung, and one hung app must not cost every read, click and check the whole ladder.
/// - **A read has a budget** (`AXReadScope`): once an app has used `perAppBudget` seconds in timeouts, it isn't asked again in that read,
///   and once the read's own deadline has passed nobody is asked at all, so that one app that hangs can't hold a read up past it.
public struct AXPatience: Sendable, Equatable {
    /// The waits one query is asked with, in turn.
    public var waits: [TimeInterval]
    /// How many of `waits` an app nothing is known of is asked with, and how many an app that has never answered is.
    public var unknownAppWaits: Int
    public var silentAppWaits: Int
    /// The most time one app may lose to timeouts in one read.
    public var perAppBudget: TimeInterval
    /// How long what a query waited for is remembered, so that the next one to the same app begins at the wait that worked, and how long an
    /// app that timed out at every wait is then asked with the first wait only.
    public var learnedFor: TimeInterval
    /// How long an app that has never answered is called silent, and how long an app is young: not called silent yet.
    public var silenceLasts: TimeInterval
    public var youngFor: TimeInterval

    public init(waits: [TimeInterval], unknownAppWaits: Int, silentAppWaits: Int, perAppBudget: TimeInterval, learnedFor: TimeInterval,
                silenceLasts: TimeInterval = 60, youngFor: TimeInterval = 60) {
        self.waits = waits
        self.unknownAppWaits = unknownAppWaits
        self.silentAppWaits = silentAppWaits
        self.perAppBudget = perAppBudget
        self.learnedFor = learnedFor
        self.silenceLasts = silenceLasts
        self.youngFor = youngFor
    }

    public static let standard = AXPatience(waits: [0.25, 1, 2], unknownAppWaits: 2, silentAppWaits: 1, perAppBudget: 4, learnedFor: 30)

    /// The most a scan of every app takes in waiting, from its start: once it has passed, no app is asked any more in that scan. A look at one
    /// bar, or at the apps whose frames a picture is checked with, is shorter.
    public static let scanBudget: TimeInterval = 8
    public static let checkBudget: TimeInterval = 4
    public static let lookBudget: TimeInterval = 2.5

    /// The waits an app of this history is asked with.
    public func ladder(for history: AXAppHistory) -> [TimeInterval] {
        switch history {
        case .answered: waits
        case .unknown: Array(waits.prefix(max(unknownAppWaits, 1)))
        case .silent: Array(waits.prefix(max(silentAppWaits, 1)))
        }
    }
}

/// The time one read has, kept for the queries of every task that is part of it (`AXReadScope.run`): the read's deadline, and how much of it
/// each app has lost to timeouts. A query that is made outside any scope (a probe's) has the ladder and no budget.
public final class AXReadScope: Sendable {
    @TaskLocal public static var current: AXReadScope?

    private let clock: any Clock
    private let deadline: Mutex<Date>
    private let perAppBudget: TimeInterval
    private let excusesGateWait: Bool
    private let quick: Set<pid_t>
    private let lost = Mutex<[pid_t: TimeInterval]>([:])

    /// - Parameters:
    ///   - budget: how long the read may keep waiting for apps, from now.
    ///   - perAppBudget: the most one app may lose to timeouts in it.
    ///   - quick: apps that are only asked to name the owners of slots, or to claim one (the bystanders of a click's read): they are asked
    ///     with the first wait only, as nothing the read does waits for them.
    ///   - excusesGateWait: whether time spent waiting for a turn at `ReadGate` doesn't count against the deadline, so that a short read
    ///     that queues behind a scan's slow apps has its time when it is asked, and not spent before it has asked anyone.
    public init(budget: TimeInterval, perAppBudget: TimeInterval, clock: any Clock, quick: Set<pid_t> = [], excusesGateWait: Bool = false) {
        self.clock = clock
        self.deadline = Mutex(clock.now().addingTimeInterval(budget))
        self.perAppBudget = perAppBudget
        self.quick = quick
        self.excusesGateWait = excusesGateWait
    }

    /// Runs `operation` as one read: every query it makes, and every task it starts, counts against this scope.
    public static func run<Result: Sendable>(_ scope: AXReadScope, _ operation: @Sendable () async -> Result) async -> Result {
        await $current.withValue(scope) { await operation() }
    }

    /// How much longer queries to this app may wait in this read: nothing once the deadline has passed or the app has used its share.
    func room(for pid: pid_t) -> TimeInterval {
        let used = lost.withLock { $0[pid] ?? 0 }
        let left = deadline.withLock { $0 }.timeIntervalSince(clock.now())
        return max(0, min(left, perAppBudget - used))
    }

    /// How much of the read's time is left (nothing once it has passed).
    var timeLeft: TimeInterval { max(0, deadline.withLock { $0 }.timeIntervalSince(clock.now())) }

    /// Whether this app is asked with the first wait only in this read.
    func isQuick(_ pid: pid_t) -> Bool { quick.contains(pid) }

    /// Notes time a query to this app waited for nothing.
    func charge(_ pid: pid_t, _ seconds: TimeInterval) {
        lost.withLock { $0[pid, default: 0] += seconds }
    }

    /// When a read begins to wait for its turn at the gate: the moment and the deadline it had then, to give back to `gateWaitEnded`.
    func gateWaitBegan() -> GateQueue? { excusesGateWait ? GateQueue(at: clock.now(), deadline: deadline.withLock { $0 }) : nil }

    /// A read got its turn after waiting: that time doesn't count against the deadline. Children of one scope that queue together wait
    /// together, so each puts the deadline back by its own wait from the deadline it had when it queued, and the deadline is the latest of
    /// those, not the sum of them.
    func gateWaitEnded(since queued: GateQueue?) {
        guard let queued else { return }
        let waited = max(0, clock.now().timeIntervalSince(queued.at))
        deadline.withLock { $0 = max($0, queued.deadline.addingTimeInterval(waited)) }
    }

    struct GateQueue: Sendable {
        let at: Date
        let deadline: Date
    }

    /// How much of each app's share is used. For tests.
    func lostTime(of pid: pid_t) -> TimeInterval { lost.withLock { $0[pid] ?? 0 } }
}

/// Accessibility that is patient with a busy Mac: a query that times out is asked again with the next longer wait (`AXPatience`), within the
/// budget of the read it is part of (`AXReadScope`), and each app is waited for as long as it has earned.
///
/// - **What an app has earned** is told from what it has done: an app that has answered before is waited for through every wait, and
///   a later query to it begins at the wait that worked last (for 30 seconds), so that a Mac that is busy for a while doesn't cost the
///   failed waits again for every query; an app that has never answered is asked once, for a minute; one that answered and has now
///   timed out at every wait is asked with the first wait only, for 30 seconds or until it answers again.
/// - **MenuBarAgent is never silent and never hung** (`expectAnswers(fromProcess:)`): it is what the bar is read from, and it answers, late
///   on a busy Mac. It is never a bystander, so its ladder is the read's own; what a read of it may cost is bounded by the read's scope.
/// - **Only reads are asked again.** A press or an action is sent once.
/// - **Quitting** (`stopWaiting()`) ends it all: no query is made after it, nor a longer wait of one that is in its ladder, so that a read
///   that is under way when the app quits is over at the end of the wait it is in, and doesn't take its turn on the main thread for the
///   calls about Mantel's own process.
///
/// It is for any thread, like `AXClient`.
public final class PatientAX: AXReading {
    private struct Knowledge {
        var answered: Set<pid_t> = []
        var expected: Set<pid_t> = []
        var silentSince: [pid_t: Date] = [:]
        var hungSince: [pid_t: Date] = [:]
        var firstAsked: [pid_t: Date] = [:]
        var learned: [pid_t: (rung: Int, at: Date)] = [:]
    }

    /// The queries that are waiting for an app now, for the log of a quit that overran.
    public struct Activity: Sendable, Equatable {
        public let inFlight: Int
        public let oldestAge: TimeInterval
    }

    private let inner: any AXReading
    private let patience: AXPatience
    private let clock: any Clock
    private let pidOf: @Sendable (AXElementRef) -> pid_t
    private let knowledge = Mutex(Knowledge())
    private let stopped = Mutex(false)
    private let waiting = Mutex<(next: Int, since: [Int: Date])>((0, [:]))

    /// - Parameter pidOf: the process an element belongs to; its own process ID, which the element knows without asking anyone, by default.
    public init(inner: any AXReading, patience: AXPatience = .standard, clock: any Clock = SystemClock(),
                pidOf: @escaping @Sendable (AXElementRef) -> pid_t = PatientAX.processID) {
        self.inner = inner
        self.patience = patience
        self.clock = clock
        self.pidOf = pidOf
    }

    public static let processID: @Sendable (AXElementRef) -> pid_t = { element in
        var pid: pid_t = 0
        AXUIElementGetPid(element.element, &pid)
        return pid
    }

    /// What is known of this app. For tests.
    func history(of pid: pid_t) -> AXAppHistory {
        knowledge.withLock { patienceHistory(of: pid, in: $0, at: clock.now()) }
    }

    /// Whether this app is asked with the first wait only now, having timed out at every wait it was given. For tests.
    func isHung(_ pid: pid_t) -> Bool {
        knowledge.withLock { hung(pid, in: $0, at: clock.now()) }
    }

    private func patienceHistory(of pid: pid_t, in knowledge: Knowledge, at now: Date) -> AXAppHistory {
        if knowledge.answered.contains(pid) { return .answered }
        guard let since = knowledge.silentSince[pid], now.timeIntervalSince(since) < patience.silenceLasts else { return .unknown }
        return .silent
    }

    private func hung(_ pid: pid_t, in knowledge: Knowledge, at now: Date) -> Bool {
        guard let since = knowledge.hungSince[pid] else { return false }
        return now.timeIntervalSince(since) < patience.learnedFor
    }

    /// The processes that are running now: what is known of the others goes.
    public func keep(onlyProcesses pids: Set<pid_t>) {
        knowledge.withLock { knowledge in
            knowledge.answered.formIntersection(pids)
            knowledge.expected.formIntersection(pids)
            knowledge.silentSince = knowledge.silentSince.filter { pids.contains($0.key) }
            knowledge.hungSince = knowledge.hungSince.filter { pids.contains($0.key) }
            knowledge.firstAsked = knowledge.firstAsked.filter { pids.contains($0.key) }
            knowledge.learned = knowledge.learned.filter { pids.contains($0.key) }
        }
    }

    /// This process answers, however late: it is waited for through every wait, and never called silent or hung. It is what every read is
    /// a read of, so that no read can do without it, whatever it is given.
    public func expectAnswers(fromProcess pid: pid_t) {
        knowledge.withLock { knowledge in
            knowledge.answered.insert(pid)
            knowledge.expected.insert(pid)
            knowledge.silentSince[pid] = nil
            knowledge.hungSince[pid] = nil
        }
    }

    public func stopWaiting() {
        stopped.withLock { $0 = true }
        inner.stopWaiting()
    }

    /// How many queries are waiting for an app now, and how long the oldest has waited.
    public func activity() -> Activity {
        let now = clock.now()
        return waiting.withLock { state in
            Activity(inFlight: state.since.count, oldestAge: state.since.values.map { now.timeIntervalSince($0) }.max() ?? 0)
        }
    }

    // MARK: AXReading

    public func attribute(_ name: String, of element: AXElementRef) throws(AXReadError) -> AXValueBox {
        let pid = pidOf(element)
        let scope = AXReadScope.current
        let now = clock.now()
        let (ladder, first, whole) = knowledge.withLock { knowledge -> ([TimeInterval], Int, Bool) in
            if knowledge.firstAsked[pid] == nil { knowledge.firstAsked[pid] = now }
            let history = patienceHistory(of: pid, in: knowledge, at: now)
            let ladder = patience.ladder(for: history)
            // One that hung, and a bystander of this read, are asked with the first wait only; what that comes to says nothing of what the
            // app has earned.
            if scope?.isQuick(pid) == true || (history == .answered && hung(pid, in: knowledge, at: now)) {
                return (Array(ladder.prefix(1)), 0, false)
            }
            // An app that is silent is asked with one wait, and what it does with it doesn't make its silence last longer.
            let whole = history != .silent
            guard let learned = knowledge.learned[pid], now.timeIntervalSince(learned.at) < patience.learnedFor else { return (ladder, 0, whole) }
            return (ladder, min(learned.rung, ladder.count - 1), whole)
        }
        var rung = first
        var exhausted = true
        var shortened = false
        while rung < ladder.count {
            // Looked at before every wait, and not once: a query that is in its ladder when the quit begins goes no further.
            if stopped.withLock({ $0 }) { throw .timeout }
            var wait = ladder[rung]
            if let scope {
                let room = scope.room(for: pid)
                // The first wait is the least one: a read with no room left asks nobody, and one with less than that left waits that long.
                guard room > 0 else {
                    exhausted = false
                    break
                }
                wait = min(wait, max(room, ladder[0]))
            }
            shortened = wait < ladder[rung]
            let began = clock.now()
            let ticket = waiting.withLock { state -> Int in
                state.next += 1
                state.since[state.next] = began
                return state.next
            }
            defer { waiting.withLock { _ = $0.since.removeValue(forKey: ticket) } }
            do {
                let value = try inner.attribute(name, of: element, wait: wait)
                answered(pid, rung: rung)
                return value
            } catch AXReadError.timeout {
                scope?.charge(pid, max(0, clock.now().timeIntervalSince(began)))
                rung += 1
            } catch {
                answered(pid, rung: rung)
                throw error
            }
        }
        // Hung is every wait of the ladder, from its first, given in full: a query that began at a learned rung, or whose last wait the
        // read's room cut short, shows only that the Mac is busy.
        if exhausted, whole, first == 0, !shortened { timedOut(pid) }
        throw .timeout
    }

    public func children(of element: AXElementRef) throws(AXReadError) -> [AXElementRef] {
        do {
            if case .elements(let children) = try attribute(AXName.children, of: element) { return children }
            return []
        } catch AXReadError.noValue {
            return []
        }
    }

    public func attribute(_ name: String, of element: AXElementRef, wait: TimeInterval) throws(AXReadError) -> AXValueBox {
        try attribute(name, of: element)
    }

    public func application(pid: pid_t) -> AXElementRef { inner.application(pid: pid) }
    public func press(_ element: AXElementRef) throws(AXReadError) { try inner.press(element) }
    public func attributeNames(of element: AXElementRef) throws(AXReadError) -> [String] { try inner.attributeNames(of: element) }
    public func actionNames(of element: AXElementRef) throws(AXReadError) -> [String] { try inner.actionNames(of: element) }
    public func perform(_ action: String, on element: AXElementRef) throws(AXReadError) { try inner.perform(action, on: element) }

    private func answered(_ pid: pid_t, rung: Int) {
        let now = clock.now()
        knowledge.withLock { knowledge in
            knowledge.answered.insert(pid)
            knowledge.silentSince[pid] = nil
            knowledge.hungSince[pid] = nil
            knowledge.learned[pid] = (rung, now)
        }
    }

    /// Every wait the app was given passed. One that has answered before is hung, and is asked with the first wait only for a while. One
    /// that never has is one that never will, unless it is young: a Mac that is busy makes a new app late, and it is asked as before.
    private func timedOut(_ pid: pid_t) {
        let now = clock.now()
        knowledge.withLock { knowledge in
            if knowledge.answered.contains(pid) {
                if !knowledge.expected.contains(pid) { knowledge.hungSince[pid] = now }
            } else if let first = knowledge.firstAsked[pid], now.timeIntervalSince(first) >= patience.youngFor {
                knowledge.silentSince[pid] = now
            }
        }
    }
}
