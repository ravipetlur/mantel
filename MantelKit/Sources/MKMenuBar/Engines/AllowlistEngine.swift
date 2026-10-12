import Foundation
import MKCore
import MKLayout

/// Hides icons with macOS's allowlist: every app and system item that isn't on it has its status items concealed for as long as the
/// assertion lives.
///
/// - **The allowlist is what stays.** The bundle IDs are the plan's visible apps and Mantel's own (always), sorted and each once; the
///   system items are the plan's visible ones, sorted. A plan that conceals nothing holds no assertion at all, so nothing is hidden as
///   a side effect (`EngineNotes.sideEffects`).
/// - **A change of plan makes the new assertion live before the old one is let go.** Even a few milliseconds with none would show every
///   icon that is meant to be hidden. An allowlist equal to the live one's is not activated again (an app that starts and changes
///   nothing in it costs nothing), except by `reapply` (Refresh): macOS can let go of an assertion without Mantel hearing of it, and
///   then a plan that is "live" is not.
/// - **Fail open.** An activation that fails lets go of the old assertion too, and throws: everything shows rather than what is
///   hidden being stale.
/// - **The lift (`liftNow`)** lets go of the live assertion at once, on the calling thread, for a click on the clock: the system ignores
///   that click while any assertion is live. While lifted `apply` only remembers the plan; `restoreAfterLift` puts the latest one back.
///
/// Calls that await are let through one at a time, so that a plan can't be overtaken by the one after it. `liftNow` and `isArmed` are
/// not calls on the actor: they touch only the lock of `LiftableAllowlist`, which nothing holds while it waits.
public actor AllowlistEngine: HidingEngine {
    /// What an assertion was made from.
    private struct Inputs: Equatable {
        let bundleIDs: [String]
        let systemItems: [Int]
    }

    private let allowlist: any AllowlistControlling
    private let ownBundleID: String
    private let isInstalledCopy: Bool
    private let live = LiftableAllowlist()
    private let turnstile = Turnstile()
    private var latestPlan: VisibilityPlan?
    /// What the live assertion was made from; nil when none is live.
    private var activeInputs: Inputs?

    /// - Parameters:
    ///   - ownBundleID: Mantel's own bundle ID, which is on every allowlist.
    ///   - isInstalledCopy: whether this is the copy in the Applications folder. macOS honours an allowlist only for that one.
    public init(allowlist: any AllowlistControlling, ownBundleID: String, isInstalledCopy: Bool) {
        self.allowlist = allowlist
        self.ownBundleID = ownBundleID
        self.isInstalledCopy = isInstalledCopy
    }

    public nonisolated var kind: HidingEngineKind {
        .allowlist
    }

    // MARK: Availability

    public func availability() async -> EngineAvailability {
        guard isInstalledCopy else { return .broken("Mantel has to run from the Applications folder for this") }
        if let problem = allowlist.inspect().problem { return .broken("macOS's allowlist has changed (\(problem))") }
        return .available
    }

    // MARK: The plan

    public func apply(_ plan: VisibilityPlan) async throws {
        await turnstile.enter()
        defer { turnstile.leave() }
        latestPlan = plan
        // Lifted for a click: the plan is kept, and put back by `restoreAfterLift`.
        guard !live.isLifted else { return }
        try await activate(plan)
    }

    /// `apply`, but an assertion equal to the plan's is made live again all the same (the one before it is let go of afterwards).
    public func reapply(_ plan: VisibilityPlan) async throws {
        await turnstile.enter()
        defer { turnstile.leave() }
        latestPlan = plan
        guard !live.isLifted else { return }
        try await activate(plan, remakingTheLiveOne: true)
    }

    public func tearDown() async {
        await turnstile.enter()
        defer { turnstile.leave() }
        // Nothing is left to put back after a lift, either: a restore that comes later finds no plan.
        latestPlan = nil
        live.release()
        activeInputs = nil
    }

    /// Makes `plan` the live allowlist, new before old. An assertion made from the same inputs is left as it is, unless
    /// `remakingTheLiveOne` is set.
    private func activate(_ plan: VisibilityPlan, remakingTheLiveOne: Bool = false) async throws {
        guard !plan.concealsNothing else {
            live.release()
            activeInputs = nil
            return
        }
        let inputs = Self.inputs(for: plan, own: ownBundleID)
        if !remakingTheLiveOne, live.isArmed, activeInputs == inputs { return }

        live.beginActivation()
        let assertion: any AllowlistAssertionHandle
        do {
            assertion = try await allowlist.activate(systemItems: inputs.systemItems, bundleIDs: inputs.bundleIDs)
        } catch is CancellationError {
            // Given up on, not failed: what is live stays as it is.
            live.activationFailed()
            throw CancellationError()
        } catch {
            live.activationFailed()
            // Fail open: the old one is let go as well, so that nothing stale stays hidden.
            live.release()
            activeInputs = nil
            Log.warning("allowlist", "activating the allowlist failed; everything is shown")
            throw HidingError.failed(.allowlist, error.localizedDescription)
        }
        switch live.complete(with: assertion) {
        case .armed(let previous):
            previous?.invalidate()
            activeInputs = inputs
        case .lifted:
            // A click lifted while this was activating: it isn't kept, and `restoreAfterLift` makes the latest plan live.
            assertion.invalidate()
            activeInputs = nil
        }
    }

    /// The allowlist a plan asks for: Mantel's own ID and every visible app, sorted, each once; and the visible system items, sorted.
    private static func inputs(for plan: VisibilityPlan, own: String) -> Inputs {
        var bundleIDs = plan.visibleBundleIDs
        bundleIDs.insert(own)
        return Inputs(bundleIDs: bundleIDs.sorted(), systemItems: plan.visibleSystemItems.sorted())
    }

    // MARK: The lift

    /// Lets go of the live assertion at once, on the thread that calls this (the event tap's, for a click on the clock). True when there
    /// was one to let go of, or one was being made. From here until `restoreAfterLift`, plans are only remembered.
    public nonisolated func liftNow() -> Bool {
        live.lift()
    }

    /// An assertion is live and has not been lifted. Safe from any thread, and not a call on the actor.
    public nonisolated var isArmed: Bool {
        live.isArmed
    }

    /// Ends a lift: the latest plan is made live again. A plan that can't be activated is logged, and nothing is held until the next one.
    public func restoreAfterLift() async {
        await turnstile.enter()
        defer { turnstile.leave() }
        live.endLift()
        guard let plan = latestPlan else { return }
        do {
            try await activate(plan)
        } catch {
            Log.warning("allowlist", "putting the allowlist back after a lift failed: \(error.localizedDescription)")
        }
    }
}
