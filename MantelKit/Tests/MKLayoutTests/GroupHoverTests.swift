import Foundation
import Testing

@testable import MKLayout

@Suite("Group hover", .timeLimit(.minutes(1)))
struct GroupHoverTests {
    private let start = Date(timeIntervalSinceReferenceDate: 5_000)
    private let work = GroupID(rawValue: "0000000a")
    private let play = GroupID(rawValue: "0000000b")

    private func at(_ milliseconds: Int) -> Date { start.addingTimeInterval(Double(milliseconds) / 1000) }

    private func point(_ hover: inout GroupHover, onGroup group: GroupID? = nil, onPanel: Bool = false, _ milliseconds: Int) {
        #expect(hover.handle(.pointer(onGroup: group, onPanel: onPanel, at: at(milliseconds))) == [])
    }

    @Test func opensAfterThreeTenths() {
        var hover = GroupHover()
        point(&hover, onGroup: work, 0)
        #expect(hover.handle(.tick(at(299))) == [])
        #expect(hover.handle(.tick(at(300))) == [.open(work)])
        #expect(hover.handle(.tick(at(900))) == [], "opened once")
    }

    @Test func leavingBeforeDelayOpensNothing() {
        var hover = GroupHover()
        point(&hover, onGroup: work, 0)
        point(&hover, 200)
        #expect(hover.handle(.tick(at(400))) == [])
        #expect(!hover.isActive)
        // Coming back starts the wait again.
        point(&hover, onGroup: work, 500)
        #expect(hover.handle(.tick(at(700))) == [])
        #expect(hover.handle(.tick(at(800))) == [.open(work)])
    }

    @Test func closesHalfASecondAfterLeavingBoth() {
        var hover = GroupHover()
        point(&hover, onGroup: work, 0)
        _ = hover.handle(.tick(at(300)))
        point(&hover, 400)
        #expect(hover.handle(.tick(at(899))) == [])
        #expect(hover.handle(.tick(at(900))) == [.close(work)])
        #expect(!hover.isActive)
    }

    @Test func panelKeepsItOpen() {
        var hover = GroupHover()
        point(&hover, onGroup: work, 0)
        _ = hover.handle(.tick(at(300)))
        point(&hover, onPanel: true, 400)
        #expect(hover.handle(.tick(at(5_000))) == [], "the pointer is on the panel")
        // Off the panel: the half second runs from there.
        point(&hover, 5_100)
        #expect(hover.handle(.tick(at(5_599))) == [])
        #expect(hover.handle(.tick(at(5_600))) == [.close(work)])
        // Back on the icon within the half second keeps it too.
        var again = GroupHover()
        point(&again, onGroup: work, 0)
        _ = again.handle(.tick(at(300)))
        point(&again, 400)
        point(&again, onGroup: work, 800)
        #expect(again.handle(.tick(at(2_000))) == [])
    }

    @Test func anotherGroupOpensAfterItsOwnDelayAndTheOpenOneCloses() {
        var hover = GroupHover()
        point(&hover, onGroup: work, 0)
        _ = hover.handle(.tick(at(300)))
        point(&hover, onGroup: play, 400)
        #expect(hover.handle(.tick(at(600))) == [])
        #expect(hover.handle(.tick(at(900))) == [.close(work), .open(play)], "the old one's half second and the new one's delay are both up")
    }

    @Test func aClosedPanelIsNotOpenedAgainWhileThePointerStaysOnTheIcon() {
        var hover = GroupHover()
        point(&hover, onGroup: work, 0)
        _ = hover.handle(.tick(at(300)))
        // The person clicked the icon: the panel closed, and the pointer is still there.
        hover.panelClosed(work)
        point(&hover, onGroup: work, 1_000)
        #expect(hover.handle(.tick(at(3_000))) == [])
        // Off the icon and back, it opens again.
        point(&hover, 3_100)
        point(&hover, onGroup: work, 3_200)
        #expect(hover.handle(.tick(at(3_500))) == [.open(work)])
    }

    @Test func theClosingOfAnotherPanelIsNotItsOwn() {
        var hover = GroupHover()
        point(&hover, onGroup: work, 0)
        _ = hover.handle(.tick(at(300)))
        // Another group's panel closes as a click opens one in its place: the one this machine opened is still its to close.
        hover.panelClosed(play)
        point(&hover, 400)
        #expect(hover.handle(.tick(at(900))) == [.close(work)])
    }

    @Test func aPanelTheMachineDidNotOpenIsNeverClosedByIt() {
        var hover = GroupHover()
        // The person clicked another group open; the pointer is off both.
        point(&hover, 0)
        #expect(hover.handle(.tick(at(2_000))) == [])
    }

    // MARK: What the app did, and what the person did

    @Test func aClickBeforeTheRestIsUpIsNotTakenForTheHovers() {
        var hover = GroupHover()
        point(&hover, onGroup: work, 0)
        // The person clicked within the 300 ms: the panel is open (key), opened by the click.
        hover.panelOpenedElsewhere(work)
        #expect(hover.handle(.tick(at(300))) == [], "the rest has had its say")
        point(&hover, onGroup: work, 100)
        point(&hover, 600)
        #expect(hover.handle(.tick(at(5_000))) == [], "and the panel they are typing in is never closed by the hover")
        #expect(!hover.isActive)
    }

    @Test func anOpenTheAppDeclinedIsNeverClosed() {
        var hover = GroupHover()
        point(&hover, onGroup: work, 0)
        #expect(hover.handle(.tick(at(300))) == [.open(work)])
        // The panel was open already, or the group has nothing to list: nothing was opened.
        hover.declined(work)
        point(&hover, 400)
        #expect(hover.handle(.tick(at(5_000))) == [], "nothing is closed")
        #expect(!hover.isActive)
        // Still resting on it: it doesn't ask again until the pointer has left.
        var staying = GroupHover()
        point(&staying, onGroup: work, 0)
        _ = staying.handle(.tick(at(300)))
        staying.declined(work)
        point(&staying, onGroup: work, 400)
        #expect(staying.handle(.tick(at(3_000))) == [])
    }

    @Test func aDeclinedOpenForOneGroupDoesNotCloseAnotherGroupsPanel() {
        // A click opened `work`; the pointer rests on `play`, which has no running members: its open is declined.
        var hover = GroupHover()
        point(&hover, onGroup: play, 0)
        #expect(hover.handle(.tick(at(300))) == [.open(play)])
        hover.declined(play)
        point(&hover, 500)
        #expect(hover.handle(.tick(at(2_000))) == [], "no close of whichever group panel is open")
    }

    @Test func aClickCloseOnlyTheHoversOwnGroup() {
        var hover = GroupHover()
        point(&hover, onGroup: work, 0)
        _ = hover.handle(.tick(at(300)))
        point(&hover, 400)
        #expect(hover.handle(.tick(at(900))) == [.close(work)], "the effect names the group it opened")
    }

    @Test func aClickOnTheIconOfAPanelTheHoverOpenedTakesItOver() {
        var hover = GroupHover()
        point(&hover, onGroup: work, 0)
        _ = hover.handle(.tick(at(300)))
        #expect(hover.iconClicked(work) == .makeKey, "key, not closed")
        // The panel is the person's now: the pointer leaving doesn't close it.
        point(&hover, 400)
        #expect(hover.handle(.tick(at(5_000))) == [])
        // A click on a panel nobody's hover opened, or on another group's icon, is the usual toggle.
        var other = GroupHover()
        #expect(other.iconClicked(work) == .toggle)
        var two = GroupHover()
        point(&two, onGroup: work, 0)
        _ = two.handle(.tick(at(300)))
        #expect(two.iconClicked(play) == .toggle)
    }
}
