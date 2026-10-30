import Foundation
import Testing

@testable import MKMenuBar

@Suite("Recapture wait", .timeLimit(.minutes(2)))
struct RecaptureWaitTests {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    @Test func nothingWasTakenSoNothingIsWaitedFor() {
        #expect(RecaptureWait.remaining(lastStrip: nil, now: now, interval: .seconds(2)) == nil)
    }

    @Test func whatIsLeftOfTheIntervalIsWaitedOut() {
        #expect(RecaptureWait.remaining(lastStrip: now, now: now, interval: .seconds(2)) == .milliseconds(2000))
        #expect(RecaptureWait.remaining(lastStrip: now.addingTimeInterval(-0.5), now: now, interval: .seconds(2)) == .milliseconds(1500))
        #expect(RecaptureWait.remaining(lastStrip: now.addingTimeInterval(-1.999), now: now, interval: .seconds(2)) == .milliseconds(1))
    }

    @Test func nothingIsWaitedForOnceTheIntervalIsOver() {
        #expect(RecaptureWait.remaining(lastStrip: now.addingTimeInterval(-2), now: now, interval: .seconds(2)) == nil)
        #expect(RecaptureWait.remaining(lastStrip: now.addingTimeInterval(-60), now: now, interval: .seconds(2)) == nil)
    }

    @Test func aClockThatWentBackWaitsOutTheWholeInterval() {
        #expect(RecaptureWait.remaining(lastStrip: now.addingTimeInterval(30), now: now, interval: .seconds(2)) == .milliseconds(2000))
    }
}
