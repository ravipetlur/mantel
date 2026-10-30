import Foundation
import MKTestSupport
import Synchronization
import Testing

@testable import MKCore

/// What the log says of a quit, so that an overrun can be told from why.
@Suite("Quit trace", .timeLimit(.minutes(2)))
struct QuitTraceTests {
    private final class Lines: Sendable {
        private let all = Mutex<[String]>([])
        func add(_ line: String) { all.withLock { $0.append(line) } }
        var value: [String] { all.withLock { $0 } }
    }

    private func trace(_ clock: FakeClock, _ lines: Lines) -> QuitTrace {
        QuitTrace(clock: clock) { lines.add($0) }
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
}
