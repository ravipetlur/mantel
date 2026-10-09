import Foundation
import MKCore
import MKTestSupport
import Synchronization
import Testing

/// `FakeClock` is the tests' only source of time, so it gets tests of its own.
@Suite("FakeClock", .timeLimit(.minutes(1)))
struct FakeClockTests {
    private let start = Date(timeIntervalSince1970: 1_000)

    @Test func timeOnlyMovesWhenAdvanced() {
        let clock = FakeClock(now: start)
        #expect(clock.now() == start)
        clock.advance(by: .seconds(90))
        #expect(clock.now() == start.addingTimeInterval(90))
        clock.advance(by: .milliseconds(500))
        #expect(clock.now() == start.addingTimeInterval(90.5))
    }

    @Test func aSleeperWakesOnceItsDeadlineHasPassed() async throws {
        let clock = FakeClock(now: start)
        let woke = Mutex(false)
        let sleeper = Task {
            try await clock.sleep(for: .seconds(10))
            woke.withLock { $0 = true }
        }
        await clock.waitForSleepers(1)

        clock.advance(by: .seconds(4))
        clock.advance(by: .seconds(5))
        #expect(clock.sleeperCount == 1, "nine of ten seconds have passed")
        #expect(!woke.withLock { $0 })

        clock.advance(by: .seconds(1))
        try await sleeper.value
        #expect(woke.withLock { $0 })
        #expect(clock.sleeperCount == 0)
    }

    /// Steps that add up to the duration add up exactly: a debounce of 500 ms is over after 300 ms and 200 ms.
    @Test func stepsAddUpExactly() async throws {
        let clock = FakeClock(now: start)
        let sleeper = Task { try await clock.sleep(for: .milliseconds(500)) }
        await clock.waitForSleepers(1)
        clock.advance(by: .milliseconds(300))
        #expect(clock.sleeperCount == 1)
        clock.advance(by: .milliseconds(200))
        try await sleeper.value
    }

    @Test func eachSleeperWakesAtItsOwnDeadline() async throws {
        let clock = FakeClock(now: start)
        let short = Task { try await clock.sleep(for: .seconds(10)) }
        let long = Task { try await clock.sleep(for: .seconds(30)) }
        await clock.waitForSleepers(2)

        clock.advance(by: .seconds(10))
        try await short.value
        #expect(clock.sleeperCount == 1, "the 30-second sleeper keeps waiting")

        clock.advance(by: .seconds(20))
        try await long.value
        #expect(clock.sleeperCount == 0)
    }

    @Test func oneBigStepWakesEverySleeperThatIsDue() async throws {
        let clock = FakeClock(now: start)
        let sleepers = (1 ... 3).map { seconds in Task { try await clock.sleep(for: .seconds(seconds)) } }
        await clock.waitForSleepers(3)
        clock.advance(by: .seconds(60))
        for sleeper in sleepers { try await sleeper.value }
        #expect(clock.sleeperCount == 0)
    }

    @Test func waitForSleepersWaitsForEnoughOfThem() async throws {
        let clock = FakeClock(now: start)
        let counted = Mutex(false)
        let waiter = Task {
            await clock.waitForSleepers(2)
            counted.withLock { $0 = true }
        }
        let first = Task { try await clock.sleep(for: .seconds(5)) }
        // With one sleeper the waiter must still be waiting: let the first sleeper register, then give the waiter every
        // chance to run.
        await clock.waitForSleepers(1)
        for _ in 0 ..< 50 { await Task.yield() }
        #expect(!counted.withLock { $0 })

        let second = Task { try await clock.sleep(for: .seconds(5)) }
        await waiter.value
        #expect(counted.withLock { $0 })
        clock.advance(by: .seconds(5))
        try await first.value
        try await second.value
    }

    @Test func waitForSleepersReturnsAtOnceWhenThereAreEnough() async {
        let clock = FakeClock(now: start)
        let sleeper = Task { try await clock.sleep(for: .seconds(5)) }
        await clock.waitForSleepers(1)
        await clock.waitForSleepers(1)
        await clock.waitForSleepers(0)
        sleeper.cancel()
    }

    @Test func aCancelledWaitForSleepersReturns() async {
        let clock = FakeClock(now: start)
        let waiter = Task { await clock.waitForSleepers(1) }
        waiter.cancel()
        await waiter.value
        #expect(clock.sleeperCount == 0)
    }

    @Test func aCancelledSleeperThrowsAndStopsWaiting() async {
        let clock = FakeClock(now: start)
        let sleeper = Task { try await clock.sleep(for: .seconds(3_600)) }
        await clock.waitForSleepers(1)
        sleeper.cancel()
        let result = await sleeper.result
        #expect(throws: CancellationError.self) { try result.get() }
        #expect(clock.sleeperCount == 0)
    }

    @Test func aTaskCancelledBeforeItSleepsNeverWaits() async {
        let clock = FakeClock(now: start)
        let sleeper = Task {
            // Cancelled by the time it gets here, whichever side runs first.
            while !Task.isCancelled { await Task.yield() }
            try await clock.sleep(for: .seconds(3_600))
        }
        sleeper.cancel()
        let result = await sleeper.result
        #expect(throws: CancellationError.self) { try result.get() }
        #expect(clock.sleeperCount == 0)
    }

    @Test func aZeroOrNegativeSleepReturnsAtOnce() async throws {
        let clock = FakeClock(now: start)
        try await clock.sleep(for: .zero)
        try await clock.sleep(for: .seconds(-5))
        #expect(clock.sleeperCount == 0)
    }
}
