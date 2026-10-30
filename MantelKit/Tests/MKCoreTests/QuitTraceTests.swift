import Foundation
import MKTestSupport
import Synchronization
import Testing

@testable import MKCore

/// What the log says of a quit, so that an overrun can be told from why.
@Suite("Quit trace")
struct QuitTraceTests {
    private final class Lines: Sendable {
        private let all = Mutex<[String]>([])
        func add(_ line: String) { all.withLock { $0.append(line) } }
        var value: [String] { all.withLock { $0 } }
    }

    private func trace(_ clock: FakeClock, _ lines: Lines) -> QuitTrace {
        QuitTrace(clock: clock) { lines.add($0) }
    }

    @Test func eachStepSaysWhenItBeganAndEndedAndHowLongItTook() async {
        let clock = FakeClock(), lines = Lines()
        let trace = trace(clock, lines)
        trace.begin("quitting")
        clock.advance(by: .milliseconds(20))
        await trace.step("flushing the settings") { clock.advance(by: .milliseconds(300)) }

        #expect(lines.value == [
            "quit trace: quitting (0 ms)",
            "quit trace: flushing the settings begins (20 ms)",
            "quit trace: flushing the settings ends (320 ms, took 300 ms)",
        ])
    }

    @Test func aStepThatDoesntWaitIsSaidTheSameWay() {
        let clock = FakeClock(), lines = Lines()
        let trace = trace(clock, lines)
        trace.begin("quitting")
        trace.quickStep("stopping the control socket") { clock.advance(by: .milliseconds(500)) }
        #expect(lines.value.last == "quit trace: stopping the control socket ends (500 ms, took 500 ms)")
    }

    @Test func theFallbackSaysTheLastStepReachedAndWhoAnsweredTheQuit() async {
        let clock = FakeClock(), lines = Lines()
        let trace = trace(clock, lines)
        trace.begin("quitting")
        trace.setDiagnostics { "3 Accessibility queries waiting" }
        trace.quickStep("stopping the control socket") { clock.advance(by: .seconds(8)) }
        // Another step has begun and not ended when the fallback fires: the last marker says so.
        let began = Gate()
        let hold = Gate()
        let stuck = Task { await trace.step("taking down the engine") { began.open(); await hold.wait() } }
        await began.wait()

        let line = trace.fallbackLine()
        #expect(line.contains("the last step reached was taking down the engine (begun)"))
        #expect(line.contains("the quit was not answered"))
        #expect(line.contains("3 Accessibility queries waiting"))
        #expect(line.contains("(8000 ms)"))
        hold.open()
        await stuck.value
    }

    @Test func onlyTheFirstAnswerCountsAndItEndsTheHeartbeats() {
        let clock = FakeClock(), lines = Lines()
        let trace = trace(clock, lines)
        trace.begin("quitting")
        #expect(!trace.isOver)
        clock.advance(by: .milliseconds(1500))
        #expect(trace.answered(by: "the timer"))
        #expect(!trace.answered(by: "the cleanup"))
        #expect(trace.isOver)
        #expect(lines.value.last == "quit trace: the quit is answered by the timer (1500 ms)")
        #expect(trace.fallbackLine().contains("answered by the timer"))
    }

    @Test func aBeatSaysWhichThreadWasFree() {
        let clock = FakeClock(), lines = Lines()
        let trace = trace(clock, lines)
        trace.begin("quitting")
        clock.advance(by: .milliseconds(500))
        trace.beat("the main thread")
        #expect(lines.value.last == "quit trace: the main thread is free (500 ms)")
    }
}
