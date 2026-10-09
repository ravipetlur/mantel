import Foundation
import MKCommands
import Testing

@testable import MKMenuBar

/// What a poll that watches for a change writes down about itself: when the poll that saw it began and ended, when the one
/// before it ended, and what a read of the menu bar cost, so that a latency reads as "between A and B".
@Suite("Poll trace", .timeLimit(.minutes(1)))
struct PollTraceTests {
    @Test func aHitOnTheFirstPollHasNoPollBeforeIt() {
        var tracker = PollTracker()
        let bounds = tracker.record(startedMs: 0, endedMs: 12)
        let trace = tracker.trace(hit: bounds)
        #expect(trace.previousPollEndedMs == nil)
        #expect(trace.hitPollStartedMs == 0)
        #expect(trace.hitPollEndedMs == 12)
        #expect(trace.polls == 1)
    }

    @Test func aHitLaterHasThePollBeforeItsEndAndItsOwnStartAndEnd() {
        var tracker = PollTracker()
        _ = tracker.record(startedMs: 0, endedMs: 12)
        _ = tracker.record(startedMs: 37, endedMs: 50)
        let bounds = tracker.record(startedMs: 75, endedMs: 90)
        let trace = tracker.trace(hit: bounds)
        #expect(trace.previousPollEndedMs == 50, "the change wasn't there when the poll before ended")
        #expect(trace.hitPollStartedMs == 75)
        #expect(trace.hitPollEndedMs == 90)
        #expect(trace.polls == 3)
    }

    @Test func theCostOfAPollIsTheMedianAndTheLongestOfWhatThePollsTook() {
        var tracker = PollTracker()
        for (start, end) in [(0.0, 10.0), (35.0, 65.0), (90.0, 100.0)] { _ = tracker.record(startedMs: start, endedMs: end) }
        let odd = tracker.trace(hit: nil)
        #expect(odd.pollSnapshotMsMedian == 10, "10, 10 and 30 ms")
        #expect(odd.pollSnapshotMsMax == 30)

        _ = tracker.record(startedMs: 125, endedMs: 145)
        let even = tracker.trace(hit: nil)
        #expect(even.pollSnapshotMsMedian == 15, "the middle two of 10, 10, 20 and 30 are 10 and 20")
        #expect(even.pollSnapshotMsMax == 30)
    }

    @Test func aPollThatNeverSawItHasNoBoundsButStillSaysWhatItCost() {
        var tracker = PollTracker()
        _ = tracker.record(startedMs: 0, endedMs: 8)
        _ = tracker.record(startedMs: 33, endedMs: 41)
        let trace = tracker.trace(hit: nil)
        #expect(trace.previousPollEndedMs == nil)
        #expect(trace.hitPollStartedMs == nil)
        #expect(trace.hitPollEndedMs == nil)
        #expect(trace.polls == 2)
        #expect(trace.pollSnapshotMsMedian == 8)
    }

    @Test func aTraceIsKeptAsItWasWhenTheHitCameEvenIfPollingWentOn() {
        // `allowlist-activate` watches two changes in one loop: the first one's trace is taken when it is seen.
        var tracker = PollTracker()
        let first = tracker.record(startedMs: 0, endedMs: 10)
        let early = tracker.trace(hit: first)
        _ = tracker.record(startedMs: 35, endedMs: 55)
        #expect(early.polls == 1)
        #expect(early.pollSnapshotMsMax == 10)
    }

    @Test func theTraceIsMeasuredAsJSONWithTheNamesTheReportUses() {
        var tracker = PollTracker()
        _ = tracker.record(startedMs: 0, endedMs: 10)
        let bounds = tracker.record(startedMs: 35, endedMs: 47)
        #expect(tracker.trace(hit: bounds).json == .object([
            "previousPollEndedMs": .number(10), "hitPollStartedMs": .number(35), "hitPollEndedMs": .number(47),
            "pollSnapshotMsMedian": .number(11), "pollSnapshotMsMax": .number(12), "polls": .number(2),
        ]))
        #expect(tracker.trace(hit: nil).json == .object([
            "previousPollEndedMs": .null, "hitPollStartedMs": .null, "hitPollEndedMs": .null,
            "pollSnapshotMsMedian": .number(11), "pollSnapshotMsMax": .number(12), "polls": .number(2),
        ]))
    }
}
