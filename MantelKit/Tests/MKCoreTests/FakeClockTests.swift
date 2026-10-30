import Foundation
import MKCore
import MKTestSupport
import Synchronization
import Testing

/// `FakeClock` is the tests' only source of time, so it gets tests of its own.
@Suite("FakeClock", .timeLimit(.minutes(1)))
struct FakeClockTests {
    private let start = Date(timeIntervalSince1970: 1_000)

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
}
