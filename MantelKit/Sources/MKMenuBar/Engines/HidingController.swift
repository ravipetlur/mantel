import Foundation
import MKCore
import MKLayout
import Synchronization

/// What a look at the bar says of a plan that was applied, for the confirmation of a switch of engine.
public enum PlanConfirmation: Sendable, Equatable {
    /// The bar shows the plan.
    case seen
    /// Not yet: another look may.
    case notYet
    /// The bar couldn't be looked at (no Accessibility, no MenuBarAgent or window, a read that timed out): waiting won't help.
    case cantTell
}

/// Keeps one engine in charge of the menu bar, sends it the plans, switches engines when the choice changes, and shows everything
/// when an engine fails.
///
/// - **Choosing.** `choose` asks each engine whether it can be used, adds the engines that have failed out, and `EngineChoice.decide`
///   says which one hides. A new choice is a switch.
/// - **Switching.** The current plan is applied with the new engine, `confirm` is asked whether the menu bar shows it (a look at the
///   bar every 250 ms, for 2 s of clock time at most), and only then is the old engine torn down: the icons are never left with no
///   engine at all. The wait ends when the look says the plan is on the bar, when the look can't tell (nothing to look with, or a read
///   timed out: waiting wouldn't help), or when the time is up. It is advisory: a confirmation that doesn't come is logged and the old
///   engine is torn down anyway, and it is never counted as a failure of the engine. There is no wait when there is no old engine.
/// - **Failing open.** An engine whose `apply` throws is torn down, which shows everything, and its error is kept (`status`). The next
///   plan tries the same engine. After three throws in a row it is failed out: the choice is made again without it, and the next engine
///   is switched to. A plan applied with `force` (Refresh) forgets the failures, and so does a new controller (the launch). A throw of
///   `HidingError.notSettled` (the preferences service lagging behind its file, which is the only thing that is not a failure) shows
///   everything the same way but isn't counted: any other error, a write macOS took and didn't keep included, is.
/// - **One at a time.** Calls that await are let through in the order they came. `confirm` must not call back into the controller.
/// - **Ending is final for what was asked before it.** `tearDown` bumps `epoch`, and a `choose` that was asked for in an earlier one is
///   dropped when it gets its turn: it was asked for before the engines were taken down, and would put one back in charge after. (The
///   session reads `epoch` when it decides to choose, before it hands the call over.) `shutDown`, for quitting, is `tearDown` and then
///   no choice and no plan is taken, ever.
public actor HidingController {
    /// How long a switch waits for `confirm` before it goes on, in time on the clock from the first look.
    public static let confirmationTimeout: Duration = .seconds(2)
    /// How often `confirm` is asked during that time.
    static let confirmationInterval: Duration = .milliseconds(250)
    /// How many throws in a row make an engine fail out.
    static let failuresBeforeFallingBack = 3

    private let engines: [HidingEngineKind: any HidingEngine]
    private let clock: any Clock
    private let confirm: @Sendable (VisibilityPlan) async -> PlanConfirmation
    private let note: @Sendable (String) -> Void
    private let turnstile = Turnstile()

    /// What `choose` was last asked, kept so that the choice can be made again when an engine fails out or a plan is forced.
    private var wanted: Wanted?
    private var availability: [HidingEngineKind: EngineAvailability] = [:]
    private var failedOut: Set<HidingEngineKind> = []
    private var failures: [HidingEngineKind: Int] = [:]
    /// The engine in charge; nil before the first choice and after `tearDown`.
    private var current: HidingEngineKind?
    private var choice: EngineChoice?
    private var lastPlan: VisibilityPlan?
    /// The last plan the current engine took without throwing.
    private var appliedPlan: VisibilityPlan?
    private var lastError: String?
    /// The method of the last `choose` that was made to the end (the switch it asked for done, the old engine taken down): what
    /// `EngineStatus.decidedFor` says. A status read while a switch is under way still names the one before it.
    private var decidedFor: HidingMethodChoice?
    /// Set by `tearDown`, which doesn't wait for a confirmation that is being waited for.
    private var abandonConfirmation = false
    /// How many times `tearDown` has been called; kept where it can be read without waiting for the actor (`epoch`).
    private let tearDowns = Mutex(0)
    /// Set by `shutDown` (quitting): nothing is chosen or applied after it.
    private var isShutDown = false

    private struct Wanted {
        let method: HidingMethodChoice
        let callActive: Bool
        let keepMicVisibleDuringCalls: Bool
        let unattachedShownApps: Set<String>
    }

    /// - Parameters:
    ///   - engines: the engines there are, by kind; a kind that is missing can't be chosen.
    ///   - clock: what the wait for a confirmation sleeps on.
    ///   - confirm: what a look at the menu bar makes of the plan.
    public init(engines: [HidingEngineKind: any HidingEngine], clock: any Clock,
                confirm: @escaping @Sendable (VisibilityPlan) async -> PlanConfirmation) {
        self.init(engines: engines, clock: clock, confirm: confirm, note: { Log.warning("hiding", $0) })
    }

    init(engines: [HidingEngineKind: any HidingEngine], clock: any Clock,
         confirm: @escaping @Sendable (VisibilityPlan) async -> PlanConfirmation,
         note: @escaping @Sendable (String) -> Void) {
        self.engines = engines
        self.clock = clock
        self.confirm = confirm
        self.note = note
    }

    /// The allowlist engine, for whatever has to reach it without waiting (the click tap lifts it from its own thread).
    public nonisolated var allowlist: AllowlistEngine? {
        engines[.allowlist] as? AllowlistEngine
    }

    /// The spacer engine, which has to be told where the menu bars are whenever they are read (`SpacerEngine.setBars`), whichever engine
    /// is in charge: it can't work out its widths from a plan alone, and has them ready when it takes over.
    public nonisolated var spacer: SpacerEngine? {
        engines[.spacer] as? SpacerEngine
    }

    // MARK: Choosing

    /// How many times the engines have been taken down (`tearDown`). A caller that decides to choose reads it then, and passes it to
    /// `choose`: a choice that was decided on before a teardown is not carried out after it.
    public nonisolated var epoch: Int {
        tearDowns.withLock { $0 }
    }

    /// Asks each engine's availability, adds the engines that have failed out, decides, and switches if the choice changed.
    ///
    /// Does nothing when the engines were taken down (`tearDown`) after `epoch` was read (`expectedEpoch`, which is the `epoch` of the call
    /// when none is given, so that a choice that waits for its turn through a teardown is dropped too), or after `shutDown`.
    public func choose(method: HidingMethodChoice, callActive: Bool = false, keepMicVisibleDuringCalls: Bool = false,
                       unattachedShownApps: Set<String> = [], expectedEpoch: Int? = nil) async {
        let asked = expectedEpoch ?? epoch
        await turnstile.enter()
        defer { turnstile.leave() }
        guard !isShutDown, epoch == asked else { return }
        wanted = Wanted(method: method, callActive: callActive, keepMicVisibleDuringCalls: keepMicVisibleDuringCalls,
                        unattachedShownApps: unattachedShownApps)
        availability = await currentAvailability()
        await decideAgain()
        // Only now, with the switch it asked for finished: the status says it settled.
        if wanted?.method == method { decidedFor = method }
    }

    /// Makes the choice again from what is known, and switches when it names another engine.
    private func decideAgain() async {
        guard let decided = decision() else { return }
        if decided.kind == current {
            choice = decided
        } else {
            await switchTo(decided)
        }
    }

    private func decision() -> EngineChoice? {
        guard let wanted else { return nil }
        return EngineChoice.decide(EngineChoiceInputs(method: wanted.method, callActive: wanted.callActive,
                                                      keepMicVisibleDuringCalls: wanted.keepMicVisibleDuringCalls,
                                                      availability: availability, failedOut: failedOut,
                                                      unattachedShownApps: wanted.unattachedShownApps))
    }

    private func currentAvailability() async -> [HidingEngineKind: EngineAvailability] {
        var result: [HidingEngineKind: EngineAvailability] = [:]
        // A kind with no engine has no entry: `EngineChoice` takes that as "it isn't set up".
        for kind in HidingEngineKind.allCases {
            if let engine = engines[kind] { result[kind] = await engine.availability() }
        }
        return result
    }

    // MARK: Switching

    /// `decided` takes over: it applies the current plan, a confirmation is waited for, and the engine that was in charge is torn down.
    private func switchTo(_ decided: EngineChoice) async {
        let old = current
        current = decided.kind
        choice = decided
        appliedPlan = nil
        Log.info("hiding", "using \(decided.kind.title): \(decided.reason)")

        if let plan = lastPlan {
            abandonConfirmation = false
            let applied = await applyToCurrent(plan)
            if applied, let old, old != current { await waitForConfirmation(plan, replacing: old) }
        }
        // What the engine that was in charge changed is undone. (An engine that failed out and was switched away from, and a switch
        // that came back to the one it left, are both finished by the time this is reached: the one in charge now isn't torn down.)
        if let old, old != current, let engine = engines[old] {
            await engine.tearDown()
        }
    }

    /// Asks `confirm` every 250 ms for up to 2 s of clock time, counted from the first look (so that a look that takes long counts).
    /// Not a test the engine can fail: it ends when the plan is seen, when the look can't tell (logged), when the time is up (logged),
    /// when the sleep is cancelled, or when `tearDown` asks it to.
    private func waitForConfirmation(_ plan: VisibilityPlan, replacing old: HidingEngineKind) async {
        let started = clock.now()
        let limit = Double(Self.confirmationTimeout.components.seconds)
        while true {
            if abandonConfirmation { return }
            switch await confirm(plan) {
            case .seen:
                return
            case .cantTell:
                note("engine switch couldn't be confirmed on the bar; tearing down \(old.title) anyway")
                return
            case .notYet:
                break
            }
            guard clock.now().timeIntervalSince(started) < limit else { break }
            do {
                try await clock.sleep(for: Self.confirmationInterval)
            } catch {
                return
            }
        }
        note("engine switch not confirmed within 2 s; tearing down \(old.title) anyway")
    }

    // MARK: Plans

    /// Sends the plan to the engine in charge. An equal plan is not sent again unless `force` is set, which also makes Refresh start
    /// over: the engines that failed out are tried again, the choice is made again (availability asked again too), and the engine in
    /// charge applies the plan as if it were new (`HidingEngine.reapply`).
    public func apply(_ plan: VisibilityPlan, force: Bool = false) async {
        await turnstile.enter()
        defer { turnstile.leave() }
        guard !isShutDown else { return }
        lastPlan = plan
        if force {
            failedOut = []
            failures = [:]
            if wanted != nil {
                availability = await currentAvailability()
                if let decided = decision(), decided.kind != current {
                    // The switch applies the plan.
                    await switchTo(decided)
                    return
                } else {
                    choice = decision()
                }
            }
        }
        guard current != nil else { return }
        if !force, appliedPlan == plan { return }
        await applyToCurrent(plan, forced: force)
    }

    /// Applies the plan with the engine in charge (`forced`: as if nothing had been applied before, which is what Refresh asks for). When
    /// it throws: everything is shown (the engine is torn down), the error is kept, and the third throw in a row fails the engine out.
    /// True when the plan was applied.
    @discardableResult
    private func applyToCurrent(_ plan: VisibilityPlan, forced: Bool = false) async -> Bool {
        guard let kind = current, let engine = engines[kind] else { return false }
        do {
            if forced {
                try await engine.reapply(plan)
            } else {
                try await engine.apply(plan)
            }
            failures[kind] = 0
            appliedPlan = plan
            lastError = nil
            return true
        } catch is CancellationError {
            // Not a failure of the engine: what was applied isn't known, and the next plan is applied whatever it is.
            appliedPlan = nil
            return false
        } catch let error as HidingError where isNotSettled(error) {
            // The preferences service hadn't caught up with its file: everything is shown, and the error kept, but the engine is no
            // worse for it, and it doesn't count toward failing out.
            appliedPlan = nil
            lastError = error.localizedDescription
            Log.warning("hiding", "\(kind.title) couldn't apply the plan yet (macOS hadn't caught up); not counted as a failure")
            await engine.tearDown()
            return false
        } catch {
            appliedPlan = nil
            lastError = error.localizedDescription
            let count = (failures[kind] ?? 0) + 1
            failures[kind] = count
            Log.warning("hiding", "\(kind.title) couldn't apply the plan (\(count) in a row)")
            await engine.tearDown()
            if count >= Self.failuresBeforeFallingBack { await failOut(kind) }
            return false
        }
    }

    private func isNotSettled(_ error: HidingError) -> Bool {
        if case .notSettled = error { true } else { false }
    }

    /// The engine threw three times in a row: it isn't tried again until Refresh or the next launch, and the choice is made again.
    private func failOut(_ kind: HidingEngineKind) async {
        failedOut.insert(kind)
        failures[kind] = 0
        guard let decided = decision() else { return }
        if decided.kind != kind {
            note("\(kind.title) failed 3 times; using \(decided.kind.title)")
            await switchTo(decided)
        } else {
            // Nothing else can take over: it stays in charge, and is tried again with the next plan.
            choice = decided
        }
    }

    // MARK: Ending

    /// Shows everything: the engine in charge is torn down, and no engine is in charge until the next `choose`. A confirmation that
    /// is being waited for is let go of.
    ///
    /// The choice that was last asked for is forgotten too: a plan applied by force chooses the engine again, and that must not put one
    /// back in charge after a teardown (a refresh that was waiting when a reset took everything down, say). Only `choose` does.
    public func tearDown() async {
        tearDowns.withLock { $0 += 1 }
        abandonConfirmation = true
        await turnstile.enter()
        defer { turnstile.leave() }
        if let kind = current, let engine = engines[kind] { await engine.tearDown() }
        current = nil
        appliedPlan = nil
        wanted = nil
        decidedFor = nil
    }

    /// `tearDown` for good, for the app that is quitting: after it no engine is chosen or applied to, whatever was asked for before it
    /// and is still on its way. (Mirrors `ClockClickController.shutDown()`.)
    public func shutDown() async {
        isShutDown = true
        await tearDown()
    }

    /// Whether a confirmation that is being waited for has been told to give up (for the tests of `tearDown`, which wait for it).
    var isAbandoningConfirmation: Bool {
        abandonConfirmation
    }

    // MARK: Status

    /// The engine in charge and why, for Diagnostics. Before the first choice it says that none was made.
    public func status() async -> EngineStatus {
        let chosen = choice ?? EngineChoice(kind: .allowlist, reason: "No way of hiding icons has been chosen yet.")
        var reason = chosen.reason
        if let engine = engines[chosen.kind], let note = await engine.statusNote() { reason += " \(note)" }
        return EngineStatus(kind: chosen.kind, reason: reason, degraded: chosen.kind == .spacer,
                            availability: availability.mapValues(\.statusText), lastError: lastError,
                            unavailableReasons: availability.compactMapValues(\.reason), decidedFor: decidedFor)
    }
}
