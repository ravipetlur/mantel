import MKCore

/// Runs a `RevealMachine`: it owns the timers the machine asks for, and passes on what the caller has to do.
///
/// - **Timers.** `startTimer` makes a task that sleeps on the clock and then sends `.timerFired` to the machine. A newer start of the
///   same timer, or a cancel of it, ends the task before it. Each timer has a generation number that goes up with every start and
///   cancel, so a timer that has woken just as it was cancelled is told apart from the live one and ignored.
/// - **Effects.** What the machine says to do is carried out in the order it says it. A timer is started or cancelled at once, within
///   the event that asked for it. `stateChanged` and `checkRoom` go to the caller by a task the driver owns, which takes them from a
///   queue one at a time, each finished before the next begins. So an effect never runs on the task of whoever sent the event (and
///   never ends because that task was cancelled), effects stay in the order the machine made them whatever the caller is doing, and
///   `send` returns at once: it never waits for the caller. An event sent from an effect is handled when it is sent, and what it
///   says to do comes after what was said before.
/// - **Settling.** `settled()` returns once every effect queued so far has been handed over and the caller has finished with it.
///
/// **A caller that acts on what it is told has to look at the state first.** An effect is delivered some time after the event that
/// made it, and the machine may have moved on: a `checkRoom` that arrives after the reveal was hidden again is about a reveal that
/// is over. A caller that turns a `NoRoomAction` into anything (a swap, a takeover of the menu bar) checks `await driver.state` first
/// and does nothing if it is no longer revealed.
public actor RevealDriver {
    private var machine: RevealMachine
    private let clock: any Clock

    /// Where effects for the caller are put, in order. The delivery task reads the other end.
    private let outbox: AsyncStream<RevealEffect>.Continuation
    private let inbox: AsyncStream<RevealEffect>
    private let effects: @Sendable (RevealEffect) async -> Void
    private var delivery: Task<Void, Never>?
    /// How many effects have been put in the outbox, and how many the caller has finished with.
    private var queued = 0
    private var delivered = 0
    private var settleWaiters: [Int: SettleWaiter] = [:]
    private var nextWaiterID = 0

    private struct SettleWaiter {
        /// The number of effects that have to be delivered before this one is let go.
        let upTo: Int
        let continuation: CheckedContinuation<Void, Never>
    }

    private var tasks: [RevealTimer: Task<Void, Never>] = [:]
    private var generations: [RevealTimer: Int] = [:]
    /// How many times a timer's wake-up has been ignored for being from a timer that was started again or cancelled. For tests.
    private(set) var ignoredTimerWakeups = 0

    /// - Parameters:
    ///   - machine: the machine to run, in the state it starts in.
    ///   - clock: what the timers wait on.
    ///   - effects: called with each `stateChanged` and `checkRoom` the machine produces, one at a time and in order, on a task of
    ///     the driver's own. It may send events back to the driver, but must not call `settled()`, which would wait for itself.
    public init(machine: RevealMachine, clock: any Clock, effects: @escaping @Sendable (RevealEffect) async -> Void) {
        self.machine = machine
        self.clock = clock
        self.effects = effects
        let (stream, continuation) = AsyncStream<RevealEffect>.makeStream(bufferingPolicy: .unbounded)
        inbox = stream
        outbox = continuation
    }

    deinit {
        for task in tasks.values { task.cancel() }
        // What is queued is still delivered; then the delivery task ends.
        outbox.finish()
    }

    public var state: RevealState { machine.state }

    /// Gives the machine the event and carries out what it asks for, except handing effects to the caller: those are queued, and
    /// delivered after this returns.
    public func send(_ event: RevealEvent) {
        for effect in machine.handle(event) {
            switch effect {
            case .startTimer(let timer, let duration): start(timer, after: duration)
            case .cancelTimer(let timer): cancel(timer)
            case .stateChanged, .checkRoom: enqueue(effect)
            }
        }
    }

    /// Returns once every effect queued before the call has been delivered and the caller has finished with it. Effects queued while
    /// it waits (an event sent from an effect, say) aren't waited for. It ends early if the task that waits is cancelled.
    ///
    /// Not to be called from an effect: the effect that is being delivered would be waited for by itself.
    public func settled() async {
        let target = queued
        guard delivered < target else { return }
        let id = nextWaiterID
        nextWaiterID += 1
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                if Task.isCancelled {
                    continuation.resume()
                } else {
                    settleWaiters[id] = SettleWaiter(upTo: target, continuation: continuation)
                }
            }
        } onCancel: {
            Task { await self.stopWaiting(id) }
        }
    }

    // MARK: Delivery

    private func enqueue(_ effect: RevealEffect) {
        if delivery == nil { startDelivery() }
        queued += 1
        outbox.yield(effect)
    }

    /// Starts the one task that hands effects to the caller. It is detached, so that it has nothing of the task that sent the first
    /// event (its priority, its task-local values), and holds the driver only weakly, so that a driver nobody uses is let go and ends
    /// it.
    private func startDelivery() {
        let inbox = inbox, effects = effects
        delivery = Task.detached { [weak self] in
            for await effect in inbox {
                await effects(effect)
                await self?.didDeliver()
            }
        }
    }

    private func didDeliver() {
        delivered += 1
        let done = settleWaiters.filter { $0.value.upTo <= delivered }
        for (id, waiter) in done {
            settleWaiters[id] = nil
            waiter.continuation.resume()
        }
    }

    /// How many calls to `settled()` are waiting. For tests.
    var settleWaiting: Int { settleWaiters.count }

    private func stopWaiting(_ id: Int) {
        settleWaiters.removeValue(forKey: id)?.continuation.resume()
    }

    // MARK: Timers

    private func start(_ timer: RevealTimer, after duration: Duration) {
        let generation = bumpGeneration(of: timer)
        tasks[timer]?.cancel()
        tasks[timer] = Task { [weak self, clock] in
            do { try await clock.sleep(for: duration) } catch { return }
            await self?.fired(timer, generation: generation)
        }
    }

    private func cancel(_ timer: RevealTimer) {
        _ = bumpGeneration(of: timer)
        tasks.removeValue(forKey: timer)?.cancel()
    }

    private func bumpGeneration(of timer: RevealTimer) -> Int {
        let next = (generations[timer] ?? 0) + 1
        generations[timer] = next
        return next
    }

    /// The generation the timer is on now: the one a live task of it carries. For tests.
    func currentGeneration(of timer: RevealTimer) -> Int {
        generations[timer] ?? 0
    }

    /// A timer's task has slept its time. Passed on to the machine only if the timer hasn't been started again or cancelled since the
    /// task began; a stale one does nothing. Called by the task; tests call it with a generation that is no longer current.
    func fired(_ timer: RevealTimer, generation: Int) {
        guard generations[timer] == generation else {
            ignoredTimerWakeups += 1
            return
        }
        tasks[timer] = nil
        send(.timerFired(timer))
    }
}
