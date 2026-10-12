import Foundation
import Synchronization

/// The allowlist assertion that is live, held where the event tap's click callback can reach it: the callback lifts it at the moment
/// a click is held, on the thread the tap runs on.
///
/// Every call is safe from any thread, takes nothing but the one lock below for as long as it takes to change a few fields, and calls
/// into the allowlist (`invalidate()`) outside the lock, so that the lift never waits for anything an actor is holding.
///
/// - **Lifted** is the state between a lift that took a live assertion (or met an activation that was under way) and the next
///   `arm`/`endLift`: an assertion that is made live then is let go of at once instead of being kept, because the click that lifted is
///   still to be replayed, and the system ignores the clock while any assertion is live.
/// - **An activation under way** is counted by `beginActivation`, so that a lift that comes while one is, doesn't find nothing to lift
///   and let the click through into an assertion that goes live a moment later.
final class LiftableAllowlist: Sendable {
    /// What became of an assertion that was made live: kept as the live one (and the one it replaces, which the caller is to
    /// invalidate), or not kept because a lift came first (the caller invalidates the new one).
    enum Replacement {
        case armed(previous: (any AllowlistAssertionHandle)?)
        case lifted
    }

    private struct State {
        var assertion: (any AllowlistAssertionHandle)?
        var lifted = false
        var activating = 0
    }

    private let state = Mutex(State())

    /// An assertion is live: made live and not invalidated since, by a lift or otherwise.
    var isArmed: Bool {
        state.withLock { $0.assertion != nil }
    }

    /// The live assertion was lifted for a click and not put back yet.
    var isLifted: Bool {
        state.withLock { $0.lifted }
    }

    /// A new assertion is live. (The probes' way: they put one back after each lift, and let go of the one they had.)
    func arm(_ assertion: any AllowlistAssertionHandle) {
        state.withLock { state in
            state.assertion = assertion
            state.lifted = false
        }
    }

    /// Invalidates the assertion that is live, if one is, and is lifted from then until the next `arm` or `endLift`. True when there was
    /// one to lift, or an activation under way that the lift is then taken to have come in the middle of: either way the system isn't
    /// to be left with an assertion live when the click is replayed.
    @discardableResult
    func lift() -> Bool {
        let (taken, wasLive) = state.withLock { state -> ((any AllowlistAssertionHandle)?, Bool) in
            let taken = state.assertion
            state.assertion = nil
            let wasLive = taken != nil || state.activating > 0
            if wasLive { state.lifted = true }
            return (taken, wasLive)
        }
        taken?.invalidate()
        return wasLive
    }

    /// What was lifted is to be put back: assertions that are made live from now on are kept.
    func endLift() {
        state.withLock { $0.lifted = false }
    }

    /// An activation is about to start. Each is followed by exactly one `complete(with:)` or `activationFailed()`.
    func beginActivation() {
        state.withLock { $0.activating += 1 }
    }

    /// An activation failed: it is no longer under way.
    func activationFailed() {
        state.withLock { $0.activating -= 1 }
    }

    /// An activation finished with `assertion`, which is live. It becomes the live assertion unless a lift came meanwhile; the caller
    /// invalidates whichever of the two isn't kept, after this returns.
    func complete(with assertion: any AllowlistAssertionHandle) -> Replacement {
        state.withLock { state in
            state.activating -= 1
            if state.lifted { return .lifted }
            let previous = state.assertion
            state.assertion = assertion
            return .armed(previous: previous)
        }
    }

    /// Takes the live assertion away and invalidates it, and ends a lift: nothing is held any more. True when there was one.
    @discardableResult
    func release() -> Bool {
        let taken = state.withLock { state -> (any AllowlistAssertionHandle)? in
            let taken = state.assertion
            state.assertion = nil
            state.lifted = false
            return taken
        }
        taken?.invalidate()
        return taken != nil
    }
}
