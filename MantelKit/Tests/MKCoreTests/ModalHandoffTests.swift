import Foundation
import Testing

@testable import MKCore

@Suite("Starting a modal alert from the run loop", .timeLimit(.minutes(2)))
@MainActor
struct ModalHandoffTests {
    /// A schedule that keeps what it is asked to serve, for the test to serve when it chooses.
    private final class Schedule: @unchecked Sendable {
        var asked: [(modes: [RunLoop.Mode], work: @Sendable () -> Void)] = []
        var isScheduling = false

        func callAsFunction(_ modes: [RunLoop.Mode], _ work: @escaping @Sendable () -> Void) {
            isScheduling = true
            defer { isScheduling = false }
            asked.append((modes, work))
        }
    }

    /// Whether `count` pieces of work were asked for before the test is called hung: a busy Mac can take a while to run the asking task,
    /// and a test that went on without its work would wait for an answer that never comes.
    private func waitUntilAsked(_ schedule: Schedule, count: Int = 1) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(30)
        while schedule.asked.count < count, ContinuousClock.now < deadline { await Task.yield() }
        return schedule.asked.count >= count
    }

    @Test func theAlertIsStartedByTheRunLoopAndNeverByTheAsker() async throws {
        let schedule = Schedule()
        var started = 0
        let answer = Task { @MainActor in
            await ModalHandoff.run(through: { schedule($0, $1) }) { started += 1; return 7 }
        }
        try #require(await waitUntilAsked(schedule))
        #expect(schedule.asked.count == 1, "one piece of work for the run loop")
        #expect(started == 0, "nothing is shown from the task that asked")
        schedule.asked.first?.work()
        #expect(started == 1, "shown when the run loop serves it")
        #expect(await answer.value == 7, "the asker gets what the alert answered")
    }

    @Test func twoAlertsAskedForAreTwoPiecesOfWorkServedOneAfterTheOther() async throws {
        let schedule = Schedule()
        var order: [Int] = []
        let first = Task { @MainActor in await ModalHandoff.run(through: { schedule($0, $1) }) { order.append(1); return 1 } }
        try #require(await waitUntilAsked(schedule))
        let second = Task { @MainActor in await ModalHandoff.run(through: { schedule($0, $1) }) { order.append(2); return 2 } }
        try #require(await waitUntilAsked(schedule, count: 2))
        #expect(schedule.asked.count == 2)
        #expect(order.isEmpty, "neither is shown until the run loop serves it")
        schedule.asked[0].work()
        schedule.asked[1].work()
        #expect(await first.value == 1)
        #expect(await second.value == 2)
        #expect(order == [1, 2])
    }
}
