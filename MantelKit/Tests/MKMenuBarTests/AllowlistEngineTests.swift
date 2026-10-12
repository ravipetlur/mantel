import Foundation
import MKCore
import MKLayout
import MKTestSupport
import Synchronization
import Testing

@testable import MKMenuBar

/// An allowlist that notes, in order, which assertion was made live and which was let go, and on which thread the letting go happened.
private final class RecordingAllowlist: AllowlistControlling {
    private struct State {
        var events: [String] = []
        var made = 0
        var attempts = 0
        var invalidationThreads: [mach_port_t] = []
        var failure: AllowlistError?
        var live: Set<Int> = []
    }

    private let state = Mutex(State())
    private let hold = Mutex<Gate?>(nil)
    /// Opened by the first activation that is asked for.
    let entered = Gate()

    /// How many activations were asked for, those that are waiting included.
    var attempts: Int { state.withLock { $0.attempts } }
    var events: [String] { state.withLock { $0.events } }
    var liveNumbers: Set<Int> { state.withLock { $0.live } }
    var invalidationThreads: [mach_port_t] { state.withLock { $0.invalidationThreads } }
    func fail(with error: AllowlistError?) { state.withLock { $0.failure = error } }
    func holdActivations(until gate: Gate?) { hold.withLock { $0 = gate } }

    func inspect() -> AllowlistInspection { FakeAllowlist.healthy }

    func activate(systemItems: [Int], bundleIDs: [String]) async throws -> any AllowlistAssertionHandle {
        state.withLock { $0.attempts += 1 }
        entered.open()
        if let gate = hold.withLock({ $0 }) { await gate.wait() }
        return try state.withLock { state -> any AllowlistAssertionHandle in
            if let failure = state.failure { throw failure }
            state.made += 1
            state.live.insert(state.made)
            state.events.append("activate \(state.made)")
            return Handle(owner: self, number: state.made)
        }
    }

    fileprivate func invalidated(_ number: Int) {
        state.withLock { state in
            state.events.append("invalidate \(number)")
            state.live.remove(number)
            state.invalidationThreads.append(pthread_mach_thread_np(pthread_self()))
        }
    }

    private final class Handle: AllowlistAssertionHandle {
        private let owner: RecordingAllowlist
        private let number: Int
        private let done = Mutex(false)

        init(owner: RecordingAllowlist, number: Int) {
            self.owner = owner
            self.number = number
        }

        func invalidate() {
            let first = done.withLock { done -> Bool in
                defer { done = true }
                return !done
            }
            if first { owner.invalidated(number) }
        }
    }
}

@Suite("Allowlist engine", .timeLimit(.minutes(1)))
struct AllowlistEngineTests {
    private let own = EngineFixtures.own

    private func make(installed: Bool = true, everyApp: [String] = ["com.example.a", "com.example.b", "com.example.c"])
        -> (engine: AllowlistEngine, allowlist: FakeAllowlist, hidden: HiddenApps) {
        let hidden = HiddenApps()
        let allowlist = FakeAllowlist(hidden: hidden, everyApp: { everyApp })
        return (AllowlistEngine(allowlist: allowlist, ownBundleID: own, isInstalledCopy: installed), allowlist, hidden)
    }

    // MARK: What is activated

    @Test func applyAllowsVisibleAndOwn() async throws {
        let (engine, allowlist, hidden) = make()
        let plan = EngineFixtures.plan(visible: ["com.example.a", "com.example.b"], concealed: ["com.example.c"], concealedSystemItems: [0, 6])

        try await engine.apply(plan)

        #expect(allowlist.calls.count == 1)
        let call = try #require(allowlist.calls.first)
        #expect(call.bundleIDs == ["com.example.a", "com.example.b", own], "the visible apps and Mantel's own")
        #expect(call.systemItems == Array(0...255).filter { $0 != 0 && $0 != 6 }, "the visible system items")
        #expect(hidden.all == ["com.example.c"], "what isn't on the allowlist is what is concealed")
        #expect(engine.isArmed)
        #expect(engine.kind == .allowlist)
    }

    @Test func bundleIDsSortedAndUnique() async throws {
        let (engine, allowlist, _) = make()
        // Mantel's own is in the plan already, and the apps come in any order.
        let plan = VisibilityPlan(visibleBundleIDs: ["com.example.z", own, "com.example.b", "com.example.a", "com.example.B"],
                                  concealedBundleIDs: ["com.example.c"], visibleSystemItems: [200, 3, 7, 100], concealedSections: [.hidden],
                                  source: .sections)
        try await engine.apply(plan)

        let call = try #require(allowlist.calls.first)
        #expect(call.bundleIDs == ["com.example.B", "com.example.a", "com.example.b", own, "com.example.z"])
        #expect(Set(call.bundleIDs).count == call.bundleIDs.count)
        #expect(call.systemItems == [3, 7, 100, 200])
        // Mantel's own is on the allowlist even when the plan doesn't say so.
        let without = VisibilityPlan(visibleBundleIDs: ["com.example.a"], concealedBundleIDs: ["com.example.c"], visibleSystemItems: [1],
                                     concealedSections: [.hidden], source: .sections)
        try await engine.apply(without)
        #expect(allowlist.calls.last?.bundleIDs == ["com.example.a", own])
    }

    @Test func sameAllowlistIsNoOp() async throws {
        let (engine, allowlist, _) = make()
        let plan = EngineFixtures.plan(visible: ["com.example.a"], concealed: ["com.example.c"])
        try await engine.apply(plan)
        try await engine.apply(plan)
        #expect(allowlist.calls.count == 1, "the same plan again activates nothing")

        // A plan that differs in what it conceals, but not in what stays, makes the same allowlist.
        var other = plan
        other.source = .reveal(.hidden)
        other.concealedBundleIDs = ["com.example.c", "com.example.d"]
        other.concealedSections = [.hidden, .alwaysHidden]
        try await engine.apply(other)
        #expect(allowlist.calls.count == 1)
        #expect(allowlist.invalidations == 0, "and lets go of nothing")

        // An app that starts and is shown joins the visible apps: that is a new allowlist.
        try await engine.apply(EngineFixtures.plan(visible: ["com.example.a", "com.example.new"], concealed: ["com.example.c"]))
        #expect(allowlist.calls.count == 2)
    }

    @Test func reapplyMakesTheSameAllowlistLiveAgainNewBeforeOld() async throws {
        // Refresh: macOS may have let go of the assertion without Mantel hearing of it, so the plan that is live is made live once more, and
        // only then is the old assertion let go of.
        let allowlist = RecordingAllowlist()
        let engine = AllowlistEngine(allowlist: allowlist, ownBundleID: own, isInstalledCopy: true)
        let plan = EngineFixtures.plan(visible: ["com.example.a"], concealed: ["com.example.c"])
        try await engine.apply(plan)

        try await engine.reapply(plan)

        #expect(allowlist.events == ["activate 1", "activate 2", "invalidate 1"])
        #expect(allowlist.liveNumbers == [2])
        #expect(engine.isArmed)
        // An ordinary apply of the same plan is still nothing.
        try await engine.apply(plan)
        #expect(allowlist.events == ["activate 1", "activate 2", "invalidate 1"])
    }

    @Test func reapplyOfAPlanThatConcealsNothingHoldsNothing() async throws {
        let allowlist = RecordingAllowlist()
        let engine = AllowlistEngine(allowlist: allowlist, ownBundleID: own, isInstalledCopy: true)
        try await engine.reapply(EngineFixtures.plan(visible: ["com.example.a"]))
        #expect(allowlist.attempts == 0)
        #expect(!engine.isArmed)
    }

    @Test func reapplyThatFailsShowsEverythingAndThrows() async throws {
        let allowlist = RecordingAllowlist()
        let engine = AllowlistEngine(allowlist: allowlist, ownBundleID: own, isInstalledCopy: true)
        let plan = EngineFixtures.plan(visible: ["com.example.a"], concealed: ["com.example.c"])
        try await engine.apply(plan)
        allowlist.fail(with: .failed("macOS refused"))

        let error = await #expect(throws: HidingError.self) { try await engine.reapply(plan) }

        #expect(error == .failed(.allowlist, "macOS refused"))
        #expect(allowlist.liveNumbers.isEmpty, "the old one is let go too: fail open")
        #expect(!engine.isArmed)
    }

    @Test func reapplyWhileLiftedOnlyRemembersThePlan() async throws {
        let allowlist = RecordingAllowlist()
        let engine = AllowlistEngine(allowlist: allowlist, ownBundleID: own, isInstalledCopy: true)
        let plan = EngineFixtures.plan(visible: ["com.example.a"], concealed: ["com.example.c"])
        try await engine.apply(plan)
        #expect(engine.liftNow())

        try await engine.reapply(plan)
        #expect(allowlist.attempts == 1, "nothing is made live while the clock's panel is open")

        await engine.restoreAfterLift()
        #expect(allowlist.liveNumbers == [2])
    }

    @Test func changedPlanActivatesNewBeforeInvalidatingOld() async throws {
        let allowlist = RecordingAllowlist()
        let engine = AllowlistEngine(allowlist: allowlist, ownBundleID: own, isInstalledCopy: true)

        try await engine.apply(EngineFixtures.plan(visible: ["com.example.a"], concealed: ["com.example.b", "com.example.c"]))
        try await engine.apply(EngineFixtures.plan(visible: ["com.example.a", "com.example.b"], concealed: ["com.example.c"]))
        try await engine.apply(EngineFixtures.plan(visible: ["com.example.a", "com.example.b", "com.example.c"], concealed: []))

        // The second is made live, and only then is the first let go: never a moment with none. The third conceals nothing, so none is held.
        #expect(allowlist.events == ["activate 1", "activate 2", "invalidate 1", "invalidate 2"])
        #expect(allowlist.liveNumbers.isEmpty)
        #expect(!engine.isArmed)
    }

    @Test func changedPlanNeverLeavesNoAssertionBetween() async throws {
        let (engine, allowlist, _) = make()
        // While the new one is being made live, the old one is still live: two are live at that moment, and no invalidation has run.
        let seen = Mutex<[(live: Int, invalidations: Int)]>([])
        try await engine.apply(EngineFixtures.plan(visible: ["com.example.a"], concealed: ["com.example.b"]))
        allowlist.onActivated { seen.withLock { $0.append((allowlist.live, allowlist.invalidations)) } }

        try await engine.apply(EngineFixtures.plan(visible: ["com.example.a", "com.example.b"], concealed: ["com.example.c"]))

        #expect(seen.withLock { $0.map(\.live) } == [2], "both were live together")
        #expect(seen.withLock { $0.map(\.invalidations) } == [0], "and the old one hadn't been let go")
        #expect(allowlist.live == 1)
        #expect(allowlist.invalidations == 1)
    }

    @Test func concealsNothingHoldsNoAssertion() async throws {
        let (engine, allowlist, hidden) = make()
        // Nothing concealed from the start: nothing is activated, so none of the side effects of an assertion happen either.
        try await engine.apply(EngineFixtures.plan(visible: ["com.example.a", "com.example.b", "com.example.c"]))
        #expect(allowlist.calls.isEmpty)
        #expect(!engine.isArmed)

        // Something concealed, and then nothing: the live assertion is let go and none is made.
        try await engine.apply(EngineFixtures.plan(visible: ["com.example.a"], concealed: ["com.example.b"]))
        #expect(allowlist.live == 1)
        try await engine.apply(EngineFixtures.plan(visible: ["com.example.a", "com.example.b"]))
        #expect(allowlist.live == 0)
        #expect(allowlist.calls.count == 1)
        #expect(hidden.all.isEmpty)
        #expect(!engine.isArmed)

        // A plan that conceals only a system item still holds one.
        try await engine.apply(EngineFixtures.plan(visible: ["com.example.a"], concealedSystemItems: [6]))
        #expect(allowlist.live == 1)
    }

    @Test func activationFailureShowsEverythingAndThrows() async throws {
        let (engine, allowlist, hidden) = make()
        try await engine.apply(EngineFixtures.plan(visible: ["com.example.a"], concealed: ["com.example.b"]))
        #expect(hidden.all == ["com.example.b", "com.example.c"])
        allowlist.fail(with: .failed("macOS refused"))

        let error = await #expect(throws: HidingError.self) {
            try await engine.apply(EngineFixtures.plan(visible: ["com.example.a", "com.example.c"], concealed: ["com.example.b"]))
        }
        #expect(error == .failed(.allowlist, "macOS refused"))
        #expect(error?.errorDescription == "Allowlist couldn't hide icons: macOS refused.")
        #expect(allowlist.live == 0, "the old assertion was let go as well: everything shows")
        #expect(hidden.all.isEmpty)
        #expect(!engine.isArmed)

        // The next plan tries again, and hides again.
        allowlist.fail(with: nil)
        try await engine.apply(EngineFixtures.plan(visible: ["com.example.a", "com.example.c"], concealed: ["com.example.b"]))
        #expect(allowlist.live == 1)
        #expect(engine.isArmed)
    }

    @Test func tearDownInvalidates() async throws {
        let (engine, allowlist, hidden) = make()
        try await engine.apply(EngineFixtures.plan(visible: ["com.example.a"], concealed: ["com.example.b"]))
        #expect(engine.isArmed)

        await engine.tearDown()

        #expect(allowlist.live == 0)
        #expect(hidden.all.isEmpty)
        #expect(!engine.isArmed)
        // It is safe to call when nothing is held, and a lift that is still to be ended finds no plan to put back.
        await engine.tearDown()
        await engine.restoreAfterLift()
        #expect(allowlist.calls.count == 1)
    }

    // MARK: Availability

    @Test func notInstalledCopyIsBroken() async {
        let (engine, _, _) = make(installed: false)
        #expect(await engine.availability() == .broken("Mantel has to run from the Applications folder for this"))
    }

    @Test func inspectionProblemIsBroken() async {
        let (engine, allowlist, _) = make()
        #expect(await engine.availability() == .available)
        let problem = AllowlistInspection(frameworkLoaded: true, configurationClassFound: true, assertionClassFound: false, encodings: [:],
                                          problem: "MBAssessmentModeAssertion isn't there")
        allowlist.setInspection(problem)
        #expect(await engine.availability() == .broken("macOS's allowlist has changed (MBAssessmentModeAssertion isn't there)"))
    }

    // MARK: The lift

    @Test func liftNowInvalidatesOnCallingThread() async throws {
        let allowlist = RecordingAllowlist()
        let engine = AllowlistEngine(allowlist: allowlist, ownBundleID: own, isInstalledCopy: true)
        try await engine.apply(EngineFixtures.plan(visible: ["com.example.a"], concealed: ["com.example.b"]))
        #expect(engine.isArmed)

        // From a thread that isn't the actor's, with no await: the way the tap's callback calls it.
        let (callingThread, lifted) = await Task.detached { () -> (mach_port_t, Bool) in
            let thread = pthread_mach_thread_np(pthread_self())
            return (thread, engine.liftNow())
        }.value

        #expect(lifted)
        #expect(allowlist.invalidationThreads == [callingThread], "invalidated by the caller, at once")
        #expect(allowlist.liveNumbers.isEmpty)
        #expect(!engine.isArmed)
        #expect(!engine.liftNow(), "nothing is live to lift the second time")
    }

    @Test func liftNowTakesNothingTheEngineIsWaitingFor() async throws {
        // The actor is busy making an assertion live; the lift is not a call on it, and still comes straight back.
        let allowlist = RecordingAllowlist()
        let gate = Gate()
        let engine = AllowlistEngine(allowlist: allowlist, ownBundleID: own, isInstalledCopy: true)
        try await engine.apply(EngineFixtures.plan(visible: ["com.example.a"], concealed: ["com.example.b"]))
        allowlist.holdActivations(until: gate)
        let next = Task { try await engine.apply(EngineFixtures.plan(visible: ["com.example.a", "com.example.b"], concealed: ["com.example.c"])) }
        // The second activation is under way (the first one was asked for already).
        #expect(await waitUntil { allowlist.attempts == 2 })

        let lifted = engine.liftNow()
        #expect(lifted)
        #expect(!engine.isArmed)
        gate.open()
        try await next.value
        // The assertion that was being made when the click lifted is not kept: the click is still to be replayed.
        #expect(allowlist.liveNumbers.isEmpty)
        #expect(!engine.isArmed)
        #expect(allowlist.events == ["activate 1", "invalidate 1", "activate 2", "invalidate 2"])

        // The lift ends: the latest plan is made live.
        await engine.restoreAfterLift()
        #expect(engine.isArmed)
        #expect(allowlist.liveNumbers == [3])
    }

    @Test func applyWhileLiftedWaitsForRestore() async throws {
        let (engine, allowlist, _) = make()
        try await engine.apply(EngineFixtures.plan(visible: ["com.example.a"], concealed: ["com.example.b"]))
        #expect(engine.liftNow())
        #expect(allowlist.live == 0)

        // While lifted, a plan is only remembered: an assertion made live now would swallow the click that is about to be replayed.
        try await engine.apply(EngineFixtures.plan(visible: ["com.example.a", "com.example.c"], concealed: ["com.example.b"]))
        #expect(allowlist.calls.count == 1)
        #expect(allowlist.live == 0)
        #expect(!engine.isArmed)
        // Not even a plan that conceals nothing activates anything or lets go of anything.
        try await engine.apply(EngineFixtures.plan(visible: ["com.example.a", "com.example.b", "com.example.c"]))
        #expect(allowlist.calls.count == 1)

        await engine.restoreAfterLift()
        #expect(allowlist.live == 0, "the latest plan conceals nothing, so none is held")
    }

    @Test func restoreAfterLiftActivatesLatestPlan() async throws {
        let (engine, allowlist, hidden) = make()
        try await engine.apply(EngineFixtures.plan(visible: ["com.example.a"], concealed: ["com.example.b", "com.example.c"]))
        #expect(engine.liftNow())
        // Two plans come while it is lifted; only the latest is put back.
        try await engine.apply(EngineFixtures.plan(visible: ["com.example.a", "com.example.b"], concealed: ["com.example.c"]))
        try await engine.apply(EngineFixtures.plan(visible: ["com.example.a", "com.example.c"], concealed: ["com.example.b"]))

        await engine.restoreAfterLift()

        #expect(allowlist.calls.count == 2, "the first, and the one put back")
        #expect(allowlist.calls.last?.bundleIDs == ["com.example.a", "com.example.c", own])
        #expect(engine.isArmed)
        #expect(hidden.all == ["com.example.b"])
        // A plan after that is applied as usual.
        try await engine.apply(EngineFixtures.plan(visible: ["com.example.a"], concealed: ["com.example.b", "com.example.c"]))
        #expect(allowlist.calls.count == 3)
    }

    @Test func aLiftThatWasNotAssertingAnythingIsNotALift() async throws {
        let (engine, allowlist, _) = make()
        #expect(!engine.liftNow(), "nothing is live")
        // So a plan that comes next is applied: nothing is waiting to be restored.
        try await engine.apply(EngineFixtures.plan(visible: ["com.example.a"], concealed: ["com.example.b"]))
        #expect(allowlist.calls.count == 1)
        #expect(engine.isArmed)
    }

    // MARK: One at a time

    @Test func plansAreAppliedInTheOrderTheyCame() async throws {
        let allowlist = RecordingAllowlist()
        let gate = Gate()
        let engine = AllowlistEngine(allowlist: allowlist, ownBundleID: own, isInstalledCopy: true)
        allowlist.holdActivations(until: gate)
        let first = Task { try await engine.apply(EngineFixtures.plan(visible: ["com.example.a"], concealed: ["com.example.b"])) }
        await allowlist.entered.wait()
        let second = Task { try await engine.apply(EngineFixtures.plan(visible: ["com.example.b"], concealed: ["com.example.a"])) }
        // The second can't start while the first is under way: it hasn't even asked the system for an allowlist.
        try await Task.sleep(for: .milliseconds(50))
        #expect(allowlist.attempts == 1)
        #expect(allowlist.events.isEmpty)

        gate.open()
        try await first.value
        try await second.value

        #expect(allowlist.events == ["activate 1", "activate 2", "invalidate 1"], "the second plan is the one that is left live")
        #expect(allowlist.liveNumbers == [2])
    }
}
