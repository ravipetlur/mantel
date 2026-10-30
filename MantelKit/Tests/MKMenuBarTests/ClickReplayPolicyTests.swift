import CoreGraphics
import Foundation
import Testing

@testable import MKMenuBar

private let clockRect = CGRect(x: 3300, y: 0, width: 50, height: 31)
private let otherRect = CGRect(x: 100, y: 0, width: 40, height: 31)

/// The decisions the click-replay tap makes, as plain values. The tap itself, which needs a live event stream, has no test:
/// nothing here installs one.
@Suite("Click replay policy", .timeLimit(.minutes(1)))
struct ClickReplayPolicyTests {
    private func policy(_ rects: [CGRect]? = nil) -> ClickReplayPolicy { ClickReplayPolicy(rects: rects ?? [clockRect]) }

    /// A click inside any rect is swallowed; one outside every rect (or below the bar) passes; with no rects nothing is swallowed.
    @Test(arguments: [
        (rects: [clockRect], x: 3320.0, y: 10.0, decision: ClickDecision.swallow),
        (rects: [clockRect], x: 500.0, y: 10.0, decision: .pass),
        (rects: [clockRect], x: 3320.0, y: 400.0, decision: .pass),
        (rects: [clockRect, otherRect], x: 110.0, y: 5.0, decision: .swallow),
        (rects: [], x: 3320.0, y: 10.0, decision: .pass),
    ])
    func aClickIsSwallowedOnlyInsideARect(rects: [CGRect], x: Double, y: Double, decision: ClickDecision) {
        var policy = policy(rects)
        #expect(policy.decide(.leftDown, at: CGPoint(x: x, y: y), isOurs: false) == decision)
    }

    @Test func theMouseUpOfASwallowedClickIsSwallowedToo() {
        var policy = policy()
        _ = policy.decide(.leftDown, at: CGPoint(x: 3320, y: 10), isOurs: false)
        // The pointer may have moved off the item before the button came up.
        #expect(policy.decide(.leftUp, at: CGPoint(x: 3320, y: 200), isOurs: false) == .swallow)
        // And once it has, the next up is an ordinary one.
        #expect(policy.decide(.leftUp, at: CGPoint(x: 3320, y: 10), isOurs: false) == .pass)
    }

    @Test func aDragAfterASwallowedDownIsSwallowedUntilTheUp() {
        var policy = policy()
        _ = policy.decide(.leftDown, at: CGPoint(x: 3320, y: 10), isOurs: false)
        #expect(policy.decide(.leftDragged, at: CGPoint(x: 3000, y: 10), isOurs: false) == .swallow)
        #expect(policy.decide(.leftUp, at: CGPoint(x: 3000, y: 10), isOurs: false) == .swallow)
        #expect(policy.decide(.leftDragged, at: CGPoint(x: 3000, y: 10), isOurs: false) == .pass)
    }

    @Test func anUpOrADragOfAClickThatWasNotSwallowedPasses() {
        var policy = policy()
        _ = policy.decide(.leftDown, at: CGPoint(x: 500, y: 10), isOurs: false)
        #expect(policy.decide(.leftDragged, at: CGPoint(x: 3320, y: 10), isOurs: false) == .pass)
        #expect(policy.decide(.leftUp, at: CGPoint(x: 3320, y: 10), isOurs: false) == .pass, "even over the rect")
    }

    @Test func theEventsItPostedItselfAlwaysPass() {
        var policy = policy()
        // Inside the rect, but ours: swallowing it would swallow the replay, and loop forever.
        #expect(policy.decide(.leftDown, at: CGPoint(x: 3320, y: 10), isOurs: true) == .pass)
        #expect(policy.decide(.leftUp, at: CGPoint(x: 3320, y: 10), isOurs: true) == .pass)
        // And they don't disturb a swallowed click that is in progress.
        _ = policy.decide(.leftDown, at: CGPoint(x: 3320, y: 10), isOurs: false)
        #expect(policy.decide(.leftUp, at: CGPoint(x: 3320, y: 10), isOurs: true) == .pass)
        #expect(policy.decide(.leftUp, at: CGPoint(x: 3320, y: 10), isOurs: false) == .swallow)
    }

    @Test func aRectIsHalfOpenSoNeighboursDontShareAnEdge() {
        var policy = policy()
        #expect(policy.decide(.leftDown, at: CGPoint(x: 3300, y: 0), isOurs: false) == .swallow, "its own left and top edge")
        _ = policy.decide(.leftUp, at: .zero, isOurs: false)
        #expect(policy.decide(.leftDown, at: CGPoint(x: 3350, y: 10), isOurs: false) == .pass, "its right edge belongs to the next")
    }

    @Test func theLifetimeIsNeverLongerThanAMinute() {
        #expect(ClickReplayTap.clamped(lifetime: .seconds(120)) == .seconds(60))
        #expect(ClickReplayTap.clamped(lifetime: .seconds(30)) == .seconds(30))
        #expect(ClickReplayTap.clamped(lifetime: .seconds(-5)) == .zero)
        #expect(ClickReplayTap.clamped(lifetime: .seconds(60)) == .seconds(60))
    }

    @Test func theMarkOnItsOwnEventsIsNotAnythingTheSystemUses() {
        // 'MNTL': the same on every run, and not zero, which is what an event nobody marked carries.
        #expect(ClickReplayTap.eventMark == 0x4D4E_544C)
    }
}
