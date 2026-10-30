import Foundation
import Testing

@testable import MKMenuBar

@Suite("Recapture wait", .timeLimit(.minutes(2)))
struct RecaptureWaitTests {
    private static let now = Date(timeIntervalSince1970: 1_700_000_000)

    /// What is left of the two seconds between strips, by how long ago the last one was taken (`nil`: none was; negative: the clock went back).
    @Test(arguments: [
        (nil, nil),
        (0, Duration.milliseconds(2000)),
        (0.5, .milliseconds(1500)),
        (1.999, .milliseconds(1)),
        (2, nil),
        (60, nil),
        (-30, .milliseconds(2000)),
    ] as [(TimeInterval?, Duration?)])
    func whatIsLeftOfTheIntervalIsWaitedOut(ago: TimeInterval?, remaining: Duration?) {
        let last = ago.map { Self.now.addingTimeInterval(-$0) }
        #expect(RecaptureWait.remaining(lastStrip: last, now: Self.now, interval: .seconds(2)) == remaining)
    }
}
