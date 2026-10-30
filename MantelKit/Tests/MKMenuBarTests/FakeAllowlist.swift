import CoreGraphics
import Foundation
import MKCommands
import MKCore
import MKTestSupport
import Synchronization
import Testing

@testable import MKMenuBar

/// An allowlist that hides what it is not told to allow, in the fake menu bar, and notes every call.
final class FakeAllowlist: AllowlistControlling {
    struct Call: Equatable {
        let systemItems: [Int]
        let bundleIDs: [String]
    }

    private struct State {
        var calls: [Call] = []
        var invalidations = 0
        var live = 0
        var failure: AllowlistError?
        var inspection = FakeAllowlist.healthy
        /// The menu bar doesn't come back when an assertion is let go.
        var sticky = false
        /// An activation that finds its task cancelled gives up, as the real one does.
        var failWhenCancelled = false
    }

    static let healthy = AllowlistInspection(
        frameworkLoaded: true, configurationClassFound: true, assertionClassFound: true,
        encodings: ["initWithAllowedSystemItems:allowedBundleIdentifiers:": "@32@0:8@16@24",
                    "activateWithConfiguration:completionHandler:": "v32@0:8@16@?24", "invalidate": "v16@0:8"],
        problem: nil)

    private let state = Mutex(State())
    private let hidden: HiddenApps
    private let everyApp: @Sendable () -> [String]
    /// Opened when an activation is asked for, so that a test knows an activation has got that far.
    let entered = Gate()
    /// If set, an activation waits for it.
    private let hold = Mutex<Gate?>(nil)
    /// Runs when an assertion has been made live: for a test where something else changes while it is held.
    private let afterActivation = Mutex<(@Sendable () -> Void)?>(nil)

    init(hidden: HiddenApps, everyApp: @escaping @Sendable () -> [String]) {
        self.hidden = hidden
        self.everyApp = everyApp
    }

    var calls: [Call] { state.withLock { $0.calls } }
    var invalidations: Int { state.withLock { $0.invalidations } }
    /// How many assertions are live now.
    var live: Int { state.withLock { $0.live } }

    func fail(with error: AllowlistError?) { state.withLock { $0.failure = error } }
    func makeReleaseNotRestore() { state.withLock { $0.sticky = true } }
    func setInspection(_ inspection: AllowlistInspection) { state.withLock { $0.inspection = inspection } }
    func holdActivations(until gate: Gate?) { hold.withLock { $0 = gate } }
    /// An activation made on a task that is cancelled (when it is made, or while it waits at the gate) throws `CancellationError`, as the
    /// real one does.
    func failWhenCancelled(_ on: Bool) { state.withLock { $0.failWhenCancelled = on } }
    func onActivated(_ body: (@Sendable () -> Void)?) { afterActivation.withLock { $0 = body } }

    func inspect() -> AllowlistInspection { state.withLock { $0.inspection } }

    func activate(systemItems: [Int], bundleIDs: [String]) async throws -> any AllowlistAssertionHandle {
        state.withLock { $0.calls.append(Call(systemItems: systemItems, bundleIDs: bundleIDs)) }
        entered.open()
        if let gate = hold.withLock({ $0 }) { await gate.wait() }
        if state.withLock({ $0.failWhenCancelled }), Task.isCancelled { throw CancellationError() }
        if let failure = state.withLock({ $0.failure }) { throw failure }
        // What isn't allowed is hidden: the union with what an earlier assertion hid is not modelled (an assertion that is
        // replaced is invalidated by its caller).
        hidden.set(Set(everyApp()).subtracting(bundleIDs))
        state.withLock { $0.live += 1 }
        afterActivation.withLock { $0 }?()
        return Handle(owner: self)
    }

    fileprivate func release() {
        let last = state.withLock { state -> Bool in
            state.invalidations += 1
            state.live = max(0, state.live - 1)
            return state.live == 0 && !state.sticky
        }
        if last { hidden.set([]) }
    }

    private final class Handle: AllowlistAssertionHandle {
        private let owner: FakeAllowlist
        private let released = Mutex(false)

        init(owner: FakeAllowlist) { self.owner = owner }

        func invalidate() {
            let first = released.withLock { released -> Bool in
                defer { released = true }
                return !released
            }
            if first { owner.release() }
        }
    }
}
