import Foundation
import MKCore
import MKTestSupport
import Synchronization
import Testing

@testable import MKMenuBar

/// Accessibility on a busy Mac: queries that time out are asked again with longer waits, within a budget, on slow fakes whose time is the
/// test's clock.
@Suite("Patient accessibility", .timeLimit(.minutes(1)))
struct PatientAXTests {
    private let pid: pid_t = 2001
    private let other: pid_t = 2002

    private struct Rig {
        let tree: FakeAX
        let clock: FakeClock
        let slow: SlowAX
        let patient: PatientAX
        let items: [pid_t: [Int]]

        init(apps: [pid_t], patience: AXPatience = .standard) {
            let tree = FakeAX()
            var items: [pid_t: [Int]] = [:]
            for pid in apps {
                items[pid] = tree.addApp(pid: pid, extras: [.init(title: "Item", identifier: "item.\(pid)", frame: CGRect(x: 10, y: 0, width: 30, height: 24))])
            }
            let clock = FakeClock()
            let slow = SlowAX(tree, clock: clock)
            self.tree = tree
            self.clock = clock
            self.slow = slow
            self.items = items
            patient = PatientAX(inner: slow, patience: patience, clock: clock, pidOf: { [tree] in tree.ownerPID(of: $0) ?? 0 })
        }

        func title(of pid: pid_t) throws -> AXValueBox {
            try patient.attribute(AXName.title, of: tree.ref(items[pid]![0]))
        }

        var elapsed: TimeInterval { clock.now().timeIntervalSince(Date(timeIntervalSince1970: 1_700_000_000)) }
    }

    @Test func anAppThatAnswersLateIsWaitedFor() throws {
        let rig = Rig(apps: [pid])
        rig.slow.setDelay(0.9, for: pid)

        // The reader as it was: one wait of a quarter of a second, and the answer is lost.
        #expect(throws: AXReadError.timeout) { try rig.slow.attribute(AXName.title, of: rig.tree.ref(rig.items[pid]![0])) }

        let value = try rig.title(of: pid)
        #expect(value == .string("Item"))
        #expect(rig.slow.calls(to: pid).dropFirst().map(\.wait) == [0.25, 1], "asked again with a longer wait")
    }

    @Test func aReadsBudgetEndsTheWaitingOfAnAppThatHangs() throws {
        let rig = Rig(apps: [pid])
        _ = try rig.title(of: pid)
        rig.slow.hang(pid)
        let scope = AXReadScope(budget: 8, perAppBudget: 4, clock: rig.clock)
        let before = rig.slow.calls.count
        let began = rig.elapsed

        for _ in 0..<5 {
            #expect(throws: AXReadError.timeout) { try AXReadScope.$current.withValue(scope) { try rig.title(of: pid) } }
        }
        let lost = rig.elapsed - began
        #expect(lost <= 4.0 + 0.001, "one app that hangs loses the read four seconds at most, not 16 (\(lost))")
        #expect(abs(scope.lostTime(of: pid) - lost) < 0.001)
        #expect(rig.slow.calls.count > before)
        let asked = rig.slow.calls.count
        #expect(throws: AXReadError.timeout) { try AXReadScope.$current.withValue(scope) { try rig.title(of: pid) } }
        #expect(rig.slow.calls.count == asked, "an app that has used its share isn't asked again in the read")
    }

    @Test func theReadsDeadlineEndsTheWaitingOfEveryApp() throws {
        let rig = Rig(apps: [pid, other])
        _ = try rig.title(of: pid)
        _ = try rig.title(of: other)
        rig.slow.hang(pid)
        rig.slow.hang(other)
        let scope = AXReadScope(budget: 1, perAppBudget: 4, clock: rig.clock)
        let before = rig.slow.calls.count
        let began = rig.elapsed

        #expect(throws: AXReadError.timeout) { try AXReadScope.$current.withValue(scope) { try rig.title(of: pid) } }
        #expect(throws: AXReadError.timeout) { try AXReadScope.$current.withValue(scope) { try rig.title(of: other) } }
        #expect(rig.elapsed - began <= 1.001, "the whole read waited for one second at most")
        #expect(rig.slow.calls.dropFirst(before).filter { $0.pid == other }.isEmpty, "the second app was asked nothing: the deadline had passed")
    }

    @Test func aRefusalIsAnAnswerAndIsNotAskedAgain() throws {
        let rig = Rig(apps: [pid])
        rig.tree.failReads(on: rig.items[pid]![0], with: .notTrusted)
        #expect(throws: AXReadError.notTrusted) { try rig.title(of: pid) }
        #expect(rig.slow.calls(to: pid).count == 1)
        #expect(rig.patient.history(of: pid) == .answered)
    }

    @Test func quittingEndsAllWaiting() throws {
        let rig = Rig(apps: [pid])
        _ = try rig.title(of: pid)
        let before = rig.slow.calls.count

        rig.patient.stopWaiting()
        #expect(throws: AXReadError.timeout) { try rig.title(of: pid) }
        #expect(rig.slow.calls.count == before, "no query is made after the quit has begun")
        #expect(rig.slow.stopWaitingCalls == 1)
    }

    // MARK: Silence, and what MenuBarAgent is

    @Test func menuBarAgentIsNeverSilentForBeingLate() throws {
        // It misses its first two waits (1.3 s): an app nothing is known of is asked twice and gives up; MenuBarAgent is waited for.
        let unknown = Rig(apps: [pid])
        unknown.slow.setDelay(1.3, for: pid, forCalls: 2)
        #expect(throws: AXReadError.timeout) { try unknown.title(of: pid) }

        let agent = Rig(apps: [pid])
        agent.patient.expectAnswers(fromProcess: pid)
        agent.slow.setDelay(1.3, for: pid, forCalls: 2)
        #expect(try agent.title(of: pid) == .string("Item"), "the third wait has its answer")
        #expect(agent.patient.history(of: pid) == .answered)
    }

    // MARK: An app that hangs

    // MARK: MenuBarAgent is never hung

    // MARK: Hung is a whole ladder, given in full

    // MARK: Quitting

    @Test func aQueryInItsLadderGoesNoFurtherOnceTheQuitHasBegun() throws {
        let rig = Rig(apps: [pid])
        _ = try rig.title(of: pid)
        rig.slow.hang(pid)
        let before = rig.slow.calls.count
        let patient = rig.patient
        rig.slow.onTimeout { patient.stopWaiting() }

        #expect(throws: AXReadError.timeout) { try rig.title(of: pid) }
        #expect(rig.slow.calls.dropFirst(before).map(\.wait) == [0.25], "the first wait was spent; the 1 s and the 2 s weren't")
        #expect(!rig.patient.isHung(pid), "and a query that was stopped says nothing of the app")
    }

    // MARK: A scope's time
}
