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

    @Test func aLaterQueryBeginsAtTheWaitThatWorked() throws {
        let rig = Rig(apps: [pid])
        rig.slow.setDelay(0.9, for: pid)
        _ = try rig.title(of: pid)
        let before = rig.slow.calls.count

        _ = try rig.title(of: pid)
        #expect(rig.slow.calls.dropFirst(before).map(\.wait) == [1], "the wait that failed isn't spent again")
    }

    @Test func anAppThatAnsweredBeforeIsWaitedForThroughEveryWait() throws {
        let rig = Rig(apps: [pid])
        _ = try rig.title(of: pid)
        #expect(rig.patient.history(of: pid) == .answered)
        let before = rig.slow.calls.count
        let began = rig.elapsed

        rig.slow.hang(pid)
        #expect(throws: AXReadError.timeout) { try rig.title(of: pid) }
        #expect(rig.slow.calls.dropFirst(before).map(\.wait) == [0.25, 1, 2])
        #expect(abs(rig.elapsed - began - 3.25) < 0.001)
    }

    @Test func anAppThatNeverAnswersCostsTheFirstReadTwoWaitsAndEveryOtherOne() throws {
        let rig = Rig(apps: [pid])
        rig.slow.hang(pid)

        #expect(throws: AXReadError.timeout) { try rig.title(of: pid) }
        #expect(rig.slow.calls(to: pid).map(\.wait) == [0.25, 1], "an app nothing is known of is asked twice")
        // After its first minute (`AXPatience.youngFor`) what has never answered is silent.
        rig.clock.advance(by: .seconds(61))
        #expect(throws: AXReadError.timeout) { try rig.title(of: pid) }
        #expect(rig.patient.history(of: pid) == .silent)

        let before = rig.slow.calls.count
        let began = rig.elapsed
        #expect(throws: AXReadError.timeout) { try rig.title(of: pid) }
        #expect(rig.slow.calls.dropFirst(before).map(\.wait) == [0.25], "once it is known never to answer, it is asked once")
        #expect(abs(rig.elapsed - began - 0.25) < 0.001, "and costs each read a quarter of a second, not its timeouts again")
    }

    @Test func anAppThatAnswersAfterBeingSilentIsWaitedForAgain() throws {
        let rig = Rig(apps: [pid])
        rig.slow.hang(pid)
        #expect(throws: AXReadError.timeout) { try rig.title(of: pid) }
        rig.slow.release(pid)
        _ = try rig.title(of: pid)
        #expect(rig.patient.history(of: pid) == .answered)
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

    @Test func withoutABudgetEachAppThatHangsCostsItsWholeLadder() throws {
        let apps: [pid_t] = [2001, 2002, 2003, 2004, 2005]
        let rig = Rig(apps: apps)
        for app in apps { _ = try rig.title(of: app) }
        for app in apps { rig.slow.hang(app) }
        let began = rig.elapsed
        for app in apps { #expect(throws: AXReadError.timeout) { try rig.title(of: app) } }
        #expect(rig.elapsed - began > 16, "which is what a read with a budget is kept from")
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

    @Test func theProcessesThatAreGoneAreForgotten() throws {
        let rig = Rig(apps: [pid, other])
        _ = try rig.title(of: pid)
        _ = try rig.title(of: other)
        rig.patient.keep(onlyProcesses: [other])
        #expect(rig.patient.history(of: pid) == .unknown)
        #expect(rig.patient.history(of: other) == .answered)
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

    @Test func anAppIsNotCalledSilentInItsFirstMinute() throws {
        let rig = Rig(apps: [pid])
        rig.slow.hang(pid)
        #expect(throws: AXReadError.timeout) { try rig.title(of: pid) }
        #expect(rig.patient.history(of: pid) == .unknown, "a busy Mac makes an app late: it hasn't had its minute")

        let before = rig.slow.calls.count
        #expect(throws: AXReadError.timeout) { try rig.title(of: pid) }
        #expect(rig.slow.calls.dropFirst(before).map(\.wait) == [0.25, 1], "so it is asked as before")

        rig.clock.advance(by: .seconds(61))
        #expect(throws: AXReadError.timeout) { try rig.title(of: pid) }
        #expect(rig.patient.history(of: pid) == .silent, "after the minute, what never answers is silent")
    }

    @Test func silenceEndsAfterAMinute() throws {
        let rig = Rig(apps: [pid])
        rig.slow.hang(pid)
        #expect(throws: AXReadError.timeout) { try rig.title(of: pid) }
        rig.clock.advance(by: .seconds(61))
        #expect(throws: AXReadError.timeout) { try rig.title(of: pid) }
        #expect(rig.patient.history(of: pid) == .silent)

        let before = rig.slow.calls.count
        #expect(throws: AXReadError.timeout) { try rig.title(of: pid) }
        #expect(rig.slow.calls.dropFirst(before).map(\.wait) == [0.25], "silent: asked once, and that doesn't make the silence last longer")

        rig.clock.advance(by: .seconds(61))
        #expect(rig.patient.history(of: pid) == .unknown, "a minute on it is asked as an app nothing is known of again")
        let again = rig.slow.calls.count
        #expect(throws: AXReadError.timeout) { try rig.title(of: pid) }
        #expect(rig.slow.calls.dropFirst(again).map(\.wait) == [0.25, 1])
    }

    // MARK: An app that hangs

    @Test func anAppThatAnsweredAndHangsCostsTheFirstWaitOnly() throws {
        let rig = Rig(apps: [pid])
        _ = try rig.title(of: pid)
        rig.slow.hang(pid)
        #expect(throws: AXReadError.timeout) { try rig.title(of: pid) }
        #expect(rig.patient.isHung(pid))

        let before = rig.slow.calls.count
        let began = rig.elapsed
        for _ in 0..<3 { #expect(throws: AXReadError.timeout) { try rig.title(of: pid) } }
        #expect(rig.slow.calls.dropFirst(before).map(\.wait) == [0.25, 0.25, 0.25], "no ladder for it in any read")
        #expect(abs(rig.elapsed - began - 0.75) < 0.001)
    }

    @Test func aHungAppIsGivenItsLadderAgainAfterThirtySecondsAndWhenItAnswers() throws {
        let rig = Rig(apps: [pid])
        _ = try rig.title(of: pid)
        rig.slow.hang(pid)
        #expect(throws: AXReadError.timeout) { try rig.title(of: pid) }
        rig.clock.advance(by: .seconds(31))
        let before = rig.slow.calls.count
        #expect(throws: AXReadError.timeout) { try rig.title(of: pid) }
        #expect(rig.slow.calls.dropFirst(before).map(\.wait) == [0.25, 1, 2], "thirty seconds on, the ladder again")

        rig.slow.release(pid)
        _ = try rig.title(of: pid)
        #expect(!rig.patient.isHung(pid), "it answered: it is no longer hung")
    }

    @Test func aBystanderIsAskedWithTheFirstWaitOnlyAndNothingIsLearnedOfIt() throws {
        let rig = Rig(apps: [pid])
        _ = try rig.title(of: pid)
        rig.slow.hang(pid)
        let scope = AXReadScope(budget: 8, perAppBudget: 4, clock: rig.clock, quick: [pid])
        let before = rig.slow.calls.count

        #expect(throws: AXReadError.timeout) { try AXReadScope.$current.withValue(scope) { try rig.title(of: pid) } }
        #expect(rig.slow.calls.dropFirst(before).map(\.wait) == [0.25])
        #expect(!rig.patient.isHung(pid), "a wait it was given by choice says nothing of the app")
    }

    // MARK: MenuBarAgent is never hung

    @Test func menuBarAgentIsNeverHungForMissingAWholeLadder() throws {
        let rig = Rig(apps: [pid])
        rig.patient.expectAnswers(fromProcess: pid)
        rig.slow.hang(pid)
        #expect(throws: AXReadError.timeout) { try rig.title(of: pid) }
        #expect(rig.slow.calls(to: pid).map(\.wait) == [0.25, 1, 2])
        #expect(!rig.patient.isHung(pid), "every read is a read of it: it is never a bystander")

        // The next query has its whole ladder again, and the third wait has the answer.
        rig.slow.release(pid)
        rig.slow.setDelay(1.3, for: pid)
        let before = rig.slow.calls.count
        #expect(try rig.title(of: pid) == .string("Item"))
        #expect(rig.slow.calls.dropFirst(before).map(\.wait) == [0.25, 1, 2])
    }

    @Test func menuBarAgentThatWasHungBeforeItWasExpectedIsNotHungAnyMore() throws {
        let rig = Rig(apps: [pid])
        _ = try rig.title(of: pid)
        rig.slow.hang(pid)
        #expect(throws: AXReadError.timeout) { try rig.title(of: pid) }
        #expect(rig.patient.isHung(pid))

        rig.patient.expectAnswers(fromProcess: pid)
        #expect(!rig.patient.isHung(pid))
    }

    @Test func aProcessThatIsGoneIsNoLongerExpected() throws {
        let rig = Rig(apps: [pid, other])
        rig.patient.expectAnswers(fromProcess: pid)
        rig.patient.keep(onlyProcesses: [other])
        // The process ID is another process's now: once it has answered, and then missed a whole ladder, it is hung like any other.
        _ = try rig.title(of: pid)
        rig.slow.hang(pid)
        #expect(throws: AXReadError.timeout) { try rig.title(of: pid) }
        #expect(rig.patient.isHung(pid))
    }

    // MARK: Hung is a whole ladder, given in full

    @Test func aQueryThatBeganAtALearnedWaitAndMissedItIsNotHung() throws {
        let rig = Rig(apps: [pid])
        _ = try rig.title(of: pid)
        rig.slow.setDelay(1.3, for: pid)
        _ = try rig.title(of: pid)
        rig.slow.hang(pid)
        let before = rig.slow.calls.count

        #expect(throws: AXReadError.timeout) { try rig.title(of: pid) }
        #expect(rig.slow.calls.dropFirst(before).map(\.wait) == [2], "it began at the wait that worked last, and that is all it was given")
        #expect(!rig.patient.isHung(pid), "one busy moment from a learned start says nothing of the app")
    }

    @Test func aQueryWhoseLastWaitTheReadsRoomShortenedIsNotHung() throws {
        let rig = Rig(apps: [pid])
        _ = try rig.title(of: pid)
        rig.slow.hang(pid)
        let scope = AXReadScope(budget: 2, perAppBudget: 4, clock: rig.clock)
        let before = rig.slow.calls.count

        #expect(throws: AXReadError.timeout) { try AXReadScope.$current.withValue(scope) { try rig.title(of: pid) } }
        #expect(rig.slow.calls.dropFirst(before).map(\.wait) == [0.25, 1, 0.75], "the last wait was cut short, with room left")
        #expect(!rig.patient.isHung(pid))
    }

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

    @Test func whatIsWaitingIsCounted() throws {
        let rig = Rig(apps: [pid])
        #expect(rig.patient.activity() == PatientAX.Activity(inFlight: 0, oldestAge: 0))
        _ = try rig.title(of: pid)
        rig.slow.hang(pid)
        let patient = rig.patient
        let seen = Mutex<[PatientAX.Activity]>([])
        // From inside the wait that has just run out, as a quit's log would see it.
        rig.slow.onTimeout { seen.withLock { $0.append(patient.activity()) } }

        #expect(throws: AXReadError.timeout) { try rig.title(of: pid) }

        #expect(seen.withLock { $0.map(\.inFlight) } == [1, 1, 1], "the query is waiting for the app")
        let ages = seen.withLock { $0.map(\.oldestAge) }
        #expect(ages.count == 3 && zip(ages, [0.25, 1, 2]).allSatisfy { abs($0 - $1) < 0.001 }, "for as long as its wait has run (\(ages))")
        #expect(rig.patient.activity() == PatientAX.Activity(inFlight: 0, oldestAge: 0), "and not once it is over")
    }

    // MARK: A scope's time

    @Test func theTimeAGateTurnTakesIsNotChargedToAReadThatExcusesIt() {
        let clock = FakeClock()
        let excusing = AXReadScope(budget: 4, perAppBudget: 4, clock: clock, excusesGateWait: true)
        let counting = AXReadScope(budget: 4, perAppBudget: 4, clock: clock)
        let queuedA = excusing.gateWaitBegan()
        let queuedB = counting.gateWaitBegan()
        clock.advance(by: .seconds(3))
        excusing.gateWaitEnded(since: queuedA)
        counting.gateWaitEnded(since: queuedB)

        #expect(abs(excusing.timeLeft - 4) < 0.001, "its time starts when it gets its turn")
        #expect(abs(counting.timeLeft - 1) < 0.001, "a scan's time is all of it")
    }

    @Test func appsThatQueueTogetherPutTheDeadlineBackByTheirWaitOnceAndNotEachOfThem() {
        let clock = FakeClock()
        let scope = AXReadScope(budget: 4, perAppBudget: 4, clock: clock, excusesGateWait: true)
        // Three reads of one scope wait for a turn together, for three seconds.
        let queued = (0..<3).map { _ in scope.gateWaitBegan() }
        clock.advance(by: .seconds(3))
        for turn in queued { scope.gateWaitEnded(since: turn) }

        #expect(abs(scope.timeLeft - 4) < 0.001, "they waited three seconds, not nine: the read has its four (\(scope.timeLeft))")
    }

    @Test func readsLeaveThreadsFreeForWhatMustRun() {
        #expect(ReadConcurrency.limit(processors: 8) == 4)
        #expect(ReadConcurrency.limit(processors: 12) == 8)
        #expect(ReadConcurrency.limit(processors: 4) == 4, "never fewer than four")
        #expect(ReadConcurrency.limit(processors: 32) == 8, "never more than eight")
    }
}
