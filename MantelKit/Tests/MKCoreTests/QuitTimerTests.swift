import Foundation
import MKTestSupport
import Synchronization
import Testing

@testable import MKCore

/// Whether a task has come back from `wait()`.
private final class Returned: Sendable {
    private let flag = Mutex(false)

    var value: Bool { flag.withLock { $0 } }
    func set() { flag.withLock { $0 = true } }
}

@Suite("Quit timer", .timeLimit(.minutes(1)))
struct QuitTimerTests {
    /// Held by the suite, and so for the whole test.
    let folder = TemporaryFolder(prefix: "mantel-quit-timer")
    let clock = FakeClock()

    private func startWaiting(_ timer: QuitTimer) -> (task: Task<Void, Never>, returned: Returned) {
        let returned = Returned()
        let task = Task {
            await timer.wait()
            returned.set()
        }
        return (task, returned)
    }

    @Test func theTimesAreOneAndThreeSeconds() {
        #expect(QuitTimer.base == .seconds(1))
        #expect(QuitTimer.extended == .seconds(3))
    }

    @Test func returnsAtOneSecond() async {
        let timer = QuitTimer(clock: clock)
        let (task, returned) = startWaiting(timer)
        await clock.waitForSleepers(1)

        clock.advance(by: .milliseconds(999))
        for _ in 0 ..< 20 { await Task.yield() }
        #expect(!returned.value, "not a moment before the second is up")
        #expect(clock.sleeperCount == 1)

        clock.advance(by: .milliseconds(1))
        await task.value
        #expect(returned.value)
        #expect(clock.sleeperCount == 0, "and it didn't go on to wait for more")
    }

    @Test func extendBeforeOneSecondWaitsThree() async {
        let timer = QuitTimer(clock: clock)
        let (task, returned) = startWaiting(timer)
        await clock.waitForSleepers(1)

        // The cleanup has found something to put back, half a second in.
        clock.advance(by: .milliseconds(500))
        await timer.extend()

        clock.advance(by: .milliseconds(500))
        // The first second is over, and the rest of the three is being waited for.
        await clock.waitForSleepers(1)
        for _ in 0 ..< 20 { await Task.yield() }
        #expect(!returned.value, "a second isn't enough any more")

        clock.advance(by: .milliseconds(1999))
        for _ in 0 ..< 20 { await Task.yield() }
        #expect(!returned.value, "three seconds in all, not a moment before")

        clock.advance(by: .milliseconds(1))
        await task.value
        #expect(returned.value)
    }

    @Test func extendBeforeTheWaitBeganStillCounts() async {
        // The cleanup can get as far as asking before the timer has been started.
        let timer = QuitTimer(clock: clock)
        await timer.extend()
        let (task, returned) = startWaiting(timer)
        await clock.waitForSleepers(1)

        clock.advance(by: .seconds(1))
        await clock.waitForSleepers(1)
        for _ in 0 ..< 20 { await Task.yield() }
        #expect(!returned.value)
        clock.advance(by: .seconds(2))
        await task.value
        #expect(returned.value)
    }

    @Test func remainingIsWhatIsLeftOfTheWait() async {
        let timer = QuitTimer(clock: clock)
        #expect(await timer.remaining() == .seconds(1), "before the wait begins it is all of it")
        let (task, returned) = startWaiting(timer)
        await clock.waitForSleepers(1)
        #expect(await timer.remaining() == .seconds(1))

        clock.advance(by: .milliseconds(300))
        #expect(await timer.remaining() == .milliseconds(700))
        // The cleanup has changes to put back: the wait is three seconds, and the 300 ms are spent.
        await timer.extend()
        #expect(await timer.remaining() == .milliseconds(2700))
        clock.advance(by: .milliseconds(700))
        #expect(await timer.remaining() == .milliseconds(2000))
        await clock.waitForSleepers(1)

        clock.advance(by: .seconds(2))
        await task.value
        #expect(returned.value)
        #expect(await timer.remaining() == .zero, "never less than nothing")
        clock.advance(by: .seconds(5))
        #expect(await timer.remaining() == .zero)
    }

    @Test func remainingAfterExtendingBeforeTheWaitBeganIsThree() async {
        let timer = QuitTimer(clock: clock)
        await timer.extend()
        #expect(await timer.remaining() == .seconds(3))
    }

    @Test func extendAfterOneSecondChangesNothing() async {
        let timer = QuitTimer(clock: clock)
        let (task, returned) = startWaiting(timer)
        await clock.waitForSleepers(1)

        // The second is up, and the app is answering the quit: asking for more time now is too late.
        clock.advance(by: .seconds(1))
        await timer.extend()

        await task.value
        #expect(returned.value)
        #expect(clock.sleeperCount == 0, "nothing more was waited for")
    }

    @Test func extendingTwiceIsTheSameAsOnce() async {
        let timer = QuitTimer(clock: clock)
        let (task, returned) = startWaiting(timer)
        await clock.waitForSleepers(1)
        await timer.extend()
        await timer.extend()

        clock.advance(by: .seconds(1))
        await clock.waitForSleepers(1)
        clock.advance(by: .seconds(2))
        await task.value
        #expect(returned.value)
    }

    // MARK: What the journal holds

    private func entry(_ name: String) -> JournalEntry {
        .plistPath(filePath: "/Users/example/p.plist", key: "Positions", path: [.key(name)], original: .integer(1),
                   strategy: .cfPreferences, codec: .none)
    }

    @Test func onlyKeptRecordsDoNotExtend() async throws {
        // What Mantel keeps stays across a quit, so a journal that holds only that has nothing to put back: the second is all it needs.
        let journal = Journal(file: folder.url.appending(path: "journal.json"), clock: clock)
        try await journal.record(entry("a"), lifetime: .kept)
        let timer = QuitTimer(clock: clock)

        await timer.extendForReplay(of: journal)
        #expect(await timer.remaining() == .seconds(1))

        // A temporary change next to it does.
        try await journal.record(entry("b"))
        await timer.extendForReplay(of: journal)
        #expect(await timer.remaining() == .seconds(3))
    }

    @Test func anEmptyJournalDoesNotExtend() async {
        let timer = QuitTimer(clock: clock)
        await timer.extendForReplay(of: Journal(file: folder.url.appending(path: "journal.json"), clock: clock))
        #expect(await timer.remaining() == .seconds(1))
    }

    @Test func replayCapLeavesAMargin() async {
        // The replay may use what is left of the wait less 150 ms: the socket stops, the hotkeys are let go and the settings are written
        // after it, and the app doesn't quit in the middle of it.
        #expect(QuitTimer.replayMargin == .milliseconds(150))
        let timer = QuitTimer(clock: clock)
        #expect(await timer.replayCap() == .milliseconds(850), "before the wait begins: all of it, less the margin")

        let (task, returned) = startWaiting(timer)
        await clock.waitForSleepers(1)
        clock.advance(by: .milliseconds(300))
        await timer.extend()
        #expect(await timer.remaining() == .milliseconds(2700))
        #expect(await timer.replayCap() == .milliseconds(2550))

        clock.advance(by: .milliseconds(2500))
        #expect(await timer.replayCap() == .milliseconds(50), "a little is left: a little, less the margin")
        clock.advance(by: .milliseconds(100))
        #expect(await timer.remaining() == .milliseconds(100))
        #expect(await timer.replayCap() == .zero, "less than the margin is left: nothing, never less")

        await clock.waitForSleepers(1)
        clock.advance(by: .seconds(5))
        await task.value
        #expect(returned.value)
        #expect(await timer.replayCap() == .zero)
    }
}
