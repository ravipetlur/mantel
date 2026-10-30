import Foundation
import Testing

@testable import MKLayout

@Suite("⌘-drag reveal", .timeLimit(.minutes(1)))
struct CommandDragRevealTests {
    private let start = Date(timeIntervalSinceReferenceDate: 1_000)

    private func later(_ seconds: Double) -> Date { start.addingTimeInterval(seconds) }

    @Test func beginShowsAllWhenOn() {
        var drag = CommandDragReveal()
        #expect(drag.handle(.began(at: start, showAllOn: true)) == [.showAll])
        #expect(drag.isActive)
    }

    @Test func beginWithoutOptionShowsNothing() {
        var drag = CommandDragReveal()
        #expect(drag.handle(.began(at: start, showAllOn: false)) == [])
        // Nothing was shown, so nothing is put away, however the drag goes.
        #expect(drag.handle(.ended(at: later(1))) == [.askFollow(end: .mouseUp)], "a mouse-up says so")
        #expect(drag.handle(.followed) == [])
        #expect(!drag.isActive)
    }

    @Test func endAsksFollowAtOnce() {
        var drag = CommandDragReveal()
        _ = drag.handle(.began(at: start, showAllOn: true))
        #expect(drag.handle(.ended(at: later(2))) == [.askFollow(end: .mouseUp)], "the reveal stays until the follow is back")
        #expect(drag.isActive)
        // A mouse-up with no drag is nothing.
        var idle = CommandDragReveal()
        #expect(idle.handle(.ended(at: start)) == [])
    }

    @Test func collapseAfterFollow() {
        var drag = CommandDragReveal()
        _ = drag.handle(.began(at: start, showAllOn: true))
        _ = drag.handle(.ended(at: later(2)))
        #expect(drag.handle(.followed) == [.collapse(to: .off)])
        #expect(!drag.isActive)
        #expect(drag.handle(.followed) == [], "once")
    }

    @Test func noFollowCollapsesAtTheTimeout() {
        var drag = CommandDragReveal()
        _ = drag.handle(.began(at: start, showAllOn: true))
        _ = drag.handle(.ended(at: later(2)))
        #expect(CommandDragReveal.followTimeout == LayoutFollower.commandDragFollowDelay + .seconds(2), "the follower's wait and two seconds")
        #expect(CommandDragReveal.followTimeout == .milliseconds(2_600))
        let timeout = 2.6
        #expect(drag.handle(.tick(later(2 + timeout - 0.01))) == [])
        #expect(drag.handle(.tick(later(2 + timeout))) == [.collapse(to: .off)])
        #expect(!drag.isActive)
        #expect(drag.handle(.followed) == [], "a follow that comes after collapses nothing again")
    }

    @Test func aFollowBackAfterTheTimeoutIsNotTakenForALaterDrags() {
        var drag = CommandDragReveal()
        _ = drag.handle(.began(at: start, showAllOn: true))
        _ = drag.handle(.ended(at: start))
        #expect(drag.handle(.tick(later(2.6))) == [.collapse(to: .off)])
        #expect(drag.handle(.began(at: later(3), showAllOn: true)) == [.showAll])
        #expect(drag.handle(.ended(at: later(3.5))) == [.askFollow(end: .mouseUp)])
        #expect(drag.handle(.followed) == [], "the first drag's follow, late: the second's read is still to come")
        #expect(drag.isActive)
        #expect(drag.handle(.followed) == [.collapse(to: .off)])
    }

    @Test func missedMouseUpCollapsesAtCap() {
        var drag = CommandDragReveal()
        _ = drag.handle(.began(at: start, showAllOn: true))
        #expect(drag.handle(.tick(later(9.99))) == [])
        #expect(drag.handle(.tick(later(10))) == [.askFollow(end: .capReached(after: 10))],
                "the session's drag ends too, and the reveal stays for its read; it is told that no mouse-up was seen")
        #expect(drag.isActive)
        #expect(drag.handle(.followed) == [.collapse(to: .off)])
        #expect(!drag.isActive)
        // A drag that showed nothing still has its end followed at the cap.
        var quiet = CommandDragReveal()
        _ = quiet.handle(.began(at: start, showAllOn: false))
        #expect(quiet.handle(.tick(later(10.25))) == [.askFollow(end: .capReached(after: 10.25))], "as long as it was held when the tick came")
    }

    @Test func aSecondDragBeforeTheFirstIsFollowedKeepsTheRevealForTheSecondsRead() {
        var drag = CommandDragReveal()
        _ = drag.handle(.began(at: start, showAllOn: true))
        _ = drag.handle(.ended(at: later(1)))
        #expect(drag.handle(.began(at: later(1.2), showAllOn: true)) == [], "everything is shown already")
        #expect(drag.handle(.ended(at: later(3))) == [.askFollow(end: .mouseUp)])
        #expect(drag.handle(.followed) == [], "the first follow is back, the second's read is still to come")
        #expect(drag.isActive)
        #expect(drag.handle(.followed) == [.collapse(to: .off)])
        #expect(!drag.isActive)
    }

    @Test func aFollowBackWhileTheNextDragIsStillHeldCollapsesNothing() {
        var drag = CommandDragReveal()
        _ = drag.handle(.began(at: start, showAllOn: true))
        _ = drag.handle(.ended(at: later(1)))
        _ = drag.handle(.began(at: later(1.2), showAllOn: true))
        #expect(drag.handle(.followed) == [], "the second drag is still going on")
        #expect(drag.handle(.ended(at: later(2))) == [.askFollow(end: .mouseUp)])
        #expect(drag.handle(.followed) == [.collapse(to: .off)])
    }

    @Test func aMissedMouseUpStillHasItsFollowBeforeTheCollapse() {
        var drag = CommandDragReveal()
        _ = drag.handle(.began(at: start, showAllOn: true))
        #expect(drag.handle(.tick(later(10))) == [.askFollow(end: .capReached(after: 10))], "not [.askFollow, .collapse]")
        #expect(drag.handle(.followed) == [.collapse(to: .off)])
    }

    @Test func aMissedMouseUpWithNoFollowCollapsesAtTheFollowTimeout() {
        var drag = CommandDragReveal()
        _ = drag.handle(.began(at: start, showAllOn: true))
        _ = drag.handle(.tick(later(10)))
        #expect(drag.handle(.tick(later(10 + 2.59))) == [])
        #expect(drag.handle(.tick(later(10 + 2.6))) == [.collapse(to: .off)])
        #expect(!drag.isActive)
    }

    @Test func aDragThatBeganOverTheHiddenRevealGoesBackToIt() {
        var drag = CommandDragReveal()
        #expect(drag.handle(.began(at: start, showAllOn: true, revealBefore: .hidden)) == [.showAll])
        _ = drag.handle(.ended(at: later(2)))
        #expect(drag.handle(.followed) == [.collapse(to: .hidden)], "the reveal the person made with • is theirs")
        // One that began collapsed collapses.
        var collapsed = CommandDragReveal()
        _ = collapsed.handle(.began(at: start, showAllOn: true, revealBefore: .off))
        _ = collapsed.handle(.ended(at: later(2)))
        #expect(collapsed.handle(.followed) == [.collapse(to: .off)])
        // A second drag that began while the first's show-all was up doesn't take that for the person's reveal.
        var twice = CommandDragReveal()
        _ = twice.handle(.began(at: start, showAllOn: true, revealBefore: .hidden))
        _ = twice.handle(.ended(at: later(1)))
        _ = twice.handle(.began(at: later(1.2), showAllOn: true, revealBefore: .all))
        _ = twice.handle(.ended(at: later(2)))
        _ = twice.handle(.followed)
        #expect(twice.handle(.followed) == [.collapse(to: .hidden)])
    }
}
