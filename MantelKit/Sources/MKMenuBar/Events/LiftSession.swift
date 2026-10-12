import Foundation
import MKCore
import Synchronization

/// When the allowlist that was lifted for a click on the clock is put back, as a value: what it is told (the replay was posted, a
/// poll of whether the panel is open, a click somewhere other than the clock, a timer going off) and the time, and what it says to do.
///
/// - **Before the panel has been seen open,** it waits `openWait` from the replay, and then restores: a click that opened nothing
///   (the clock was clicked while something else was in the way) doesn't leave the icons shown.
/// - **Once the panel has been seen open,** it restores on the first poll that sees it closed, or at `cap`, and for no other reason.
///   A click somewhere other than the clock is then most likely a click on the panel (a notification, a widget), and putting the
///   allowlist back would hide the icons behind it while it is open.
/// - **A click somewhere other than the clock, before the panel has been seen open,** restores `clickOutsideDelay` later: the click goes
///   through first, and the panel is not going to open. A click that is waiting when the panel is seen open is let go of.
/// - **After `cap`** it restores whatever else is going on.
///
/// Time is the `now` each event brings (milliseconds are what is compared), so that the caller decides how often to look, and a test
/// needs no sleeping.
public struct LiftSession: Sendable, Equatable {
    public enum Event: Sendable, Equatable {
        /// The held click was posted again. The waits are counted from here.
        case replayed
        /// The panel was looked for: whether it is open.
        case poll(open: Bool)
        /// The person clicked somewhere other than a target (the clock) while the allowlist was lifted. The click may be on the open panel
        /// (`LiftSession` takes that into account); it is not known to be away from it.
        case clickOutside
        /// A timer the caller set has gone off: nothing new is known but the time.
        case timerFired
    }

    public enum Effect: Sendable, Equatable {
        /// Put the allowlist back.
        case restore
        /// Not yet.
        case keepPolling
    }

    /// How often the caller looks for the panel.
    public static let pollInterval: Duration = .milliseconds(200)
    /// How long, from the replay, a panel that has not been seen open is waited for.
    public static let openWait: Duration = .seconds(1)
    /// The most a lift lasts, from the replay.
    public static let cap: Duration = .seconds(8)
    /// How long after a click somewhere other than the clock, made before the panel was seen open, the allowlist is put back.
    public static let clickOutsideDelay: Duration = .milliseconds(300)

    private var startedAt: Date
    private var seenOpen = false
    private var clickedOutsideAt: Date?

    public init(startedAt: Date) {
        self.startedAt = startedAt
    }

    public mutating func handle(_ event: Event, now: Date) -> Effect {
        switch event {
        case .replayed:
            startedAt = now
        case .poll(let open):
            if open {
                seenOpen = true
                // From here on only its close or the cap restores: a click that was waiting to put the allowlist back was most likely on
                // the panel, which has come up.
                clickedOutsideAt = nil
            } else if seenOpen {
                return .restore
            }
        case .clickOutside:
            // On the open panel: not a reason to restore. Before it has been seen open: the click may be what closes or replaces it.
            if !seenOpen, clickedOutsideAt == nil { clickedOutsideAt = now }
        case .timerFired:
            break
        }

        if Self.milliseconds(from: startedAt, to: now) >= Self.milliseconds(of: Self.cap) { return .restore }
        if let clickedOutsideAt, Self.milliseconds(from: clickedOutsideAt, to: now) >= Self.milliseconds(of: Self.clickOutsideDelay) {
            return .restore
        }
        if !seenOpen, Self.milliseconds(from: startedAt, to: now) >= Self.milliseconds(of: Self.openWait) { return .restore }
        return .keepPolling
    }

    /// Whole milliseconds, so that two dates that are meant to be a round time apart are, whatever the last bit of each is.
    private static func milliseconds(from start: Date, to end: Date) -> Int {
        Int((end.timeIntervalSince(start) * 1000).rounded())
    }

    private static func milliseconds(of duration: Duration) -> Int {
        let parts = duration.components
        return Int(parts.seconds) * 1000 + Int(parts.attoseconds / 1_000_000_000_000_000)
    }
}

/// Runs lifts: starts a `LiftSession` when a held click has been replayed, looks for the panel every `LiftSession.pollInterval`, and
/// puts the allowlist back when the session says to.
///
/// - **Everything it is told can come from any thread** (`replayed` from the tap's queue, `clickOutside` from inside its callback), and
///   none of it waits: a lock is taken for as long as it takes to change a few fields.
/// - **One lift at a time.** A replay that comes while one is on (the allowlist was put back by something else, and the clock was
///   clicked again) starts a new one in its place; the old one never restores, the new one does.
/// - **Restoring** is `restore`, which has to be safe when nothing is lifted: it may find the allowlist already back (a plan that was
///   applied after a failed activation re-armed it), or none to put back. It is run on a task of its own, so that a session that ends
///   by being cancelled can't cancel it.
/// - **`stop()` ends the runner for good, and doesn't restore.** It is for when the allowlist is no longer wanted: another engine took
///   over, or the app is quitting, and then letting go of the allowlist is the engine's own teardown, which also ends a lift. A restore
///   there would put an allowlist back that is about to be let go of. A replay that comes after `stop()` (the tap posts what it held,
///   even after it was stopped) is ignored. Make another runner to lift again.
/// - **A click somewhere other than the clock with no lift on is nothing.**
public final class LiftRunner: Sendable {
    private struct Running {
        let id: UInt64
        var session: LiftSession
        var tasks: [Task<Void, Never>] = []
    }

    private struct State {
        var lastID: UInt64 = 0
        var running: Running?
        var isStopped = false
    }

    private enum Delivery {
        /// The lift this was for is over (or was replaced).
        case gone
        case continues
        /// The session said to restore; these are its tasks, to cancel.
        case restore([Task<Void, Never>])
    }

    private let clock: any Clock
    private let isOpen: @Sendable () -> Bool
    private let restore: @Sendable () async -> Void
    private let state = Mutex(State())

    /// - Parameters:
    ///   - clock: what the polls and timers sleep on.
    ///   - isOpen: whether the panel is open now (`OpenedSystemUI`). Read off the main actor, on the poll's own task.
    ///   - restore: puts the allowlist back (`AllowlistEngine.restoreAfterLift`).
    public init(clock: any Clock = SystemClock(), isOpen: @escaping @Sendable () -> Bool, restore: @escaping @Sendable () async -> Void) {
        self.clock = clock
        self.isOpen = isOpen
        self.restore = restore
    }

    /// A lift is on.
    public var isRunning: Bool {
        state.withLock { $0.running != nil }
    }

    /// The held click has been posted again: a lift begins, in place of the one that was on, if any. Ignored once `stop()` has been called.
    public func replayed() {
        let now = clock.now()
        let started = state.withLock { state -> (UInt64, [Task<Void, Never>])? in
            guard !state.isStopped else { return nil }
            state.lastID += 1
            var session = LiftSession(startedAt: now)
            _ = session.handle(.replayed, now: now)
            let replaced = state.running?.tasks ?? []
            state.running = Running(id: state.lastID, session: session)
            return (state.lastID, replaced)
        }
        guard let (id, replaced) = started else { return }
        for task in replaced { task.cancel() }
        attach(Task { [self] in await poll(id) }, to: id)
    }

    /// The person clicked somewhere other than a target (the clock) while the allowlist was lifted. Ignored when no lift is on. Whether it
    /// restores is the session's to say: not when the panel has been seen open.
    public func clickOutside() {
        guard let id = state.withLock({ $0.running?.id }), deliver(.clickOutside, to: id) else { return }
        attach(Task { [self] in
            guard (try? await clock.sleep(for: LiftSession.clickOutsideDelay)) != nil else { return }
            deliver(.timerFired, to: id)
        }, to: id)
    }

    /// Ends the lift that is on, if any, without putting the allowlist back, and ends the runner: later replays are ignored.
    public func stop() {
        let tasks = state.withLock { state -> [Task<Void, Never>] in
            state.isStopped = true
            defer { state.running = nil }
            return state.running?.tasks ?? []
        }
        for task in tasks { task.cancel() }
    }

    // MARK: Driving

    private func poll(_ id: UInt64) async {
        while !Task.isCancelled {
            do {
                try await clock.sleep(for: LiftSession.pollInterval)
            } catch {
                return
            }
            guard deliver(.poll(open: isOpen()), to: id) else { return }
        }
    }

    /// Tells lift `id` what happened. True while it goes on; when the session says to restore, the allowlist is put back from here.
    @discardableResult
    private func deliver(_ event: LiftSession.Event, to id: UInt64) -> Bool {
        let now = clock.now()
        let delivery = state.withLock { state -> Delivery in
            guard var running = state.running, running.id == id else { return .gone }
            guard running.session.handle(event, now: now) == .restore else {
                state.running = running
                return .continues
            }
            state.running = nil
            return .restore(running.tasks)
        }
        switch delivery {
        case .gone:
            return false
        case .continues:
            return true
        case .restore(let tasks):
            for task in tasks { task.cancel() }
            Task { [restore] in await restore() }
            return false
        }
    }

    /// Keeps `task` with lift `id`, so that the lift's end cancels it; a task for a lift that is already over is cancelled at once.
    private func attach(_ task: Task<Void, Never>, to id: UInt64) {
        let kept = state.withLock { state -> Bool in
            guard state.running?.id == id else { return false }
            state.running?.tasks.append(task)
            return true
        }
        if !kept { task.cancel() }
    }
}
