import CoreGraphics
import Foundation
import Testing

@testable import MKLayout

/// Room for Mantel's dots: what the tracker moves when a dot is in the « menu of a bar that is shown, and how it gives the room back.
@Suite("Automatic overflow: the dots", .timeLimit(.minutes(1)))
struct AutoOverflowDotsTests {
    private let a = "com.example.a"
    private let b = "com.example.b"
    private let c = "com.example.c"
    private let laptop = "display-laptop"
    private let desk = "display-desk"

    private let fits: (Set<String>) -> Bool = { _ in true }

    private func t(_ seconds: Double) -> Date { Fixtures.date(seconds) }

    private func shown(_ apps: String...) -> SectionModel {
        var sections = SectionModel()
        for app in apps { sections.move(app: app, to: .shown) }
        return sections
    }

    /// A bar the dots are trapped on, with these apps on it from the left, each `width` wide, and the dots needing `needed`.
    private func trapped(_ display: String? = nil, needed: CGFloat = 38, width: CGFloat = 38, apps: [String], places: [CGRect] = [])
        -> AutoOverflowTracker.TrappedBar {
        AutoOverflowTracker.TrappedBar(displayUUID: display ?? laptop, neededWidth: needed,
                                       apps: apps.map { AutoOverflowTracker.ConcealableApp(bundleID: $0, width: width) }, dotPlaces: places)
    }

    private func place(_ x: CGFloat) -> CGRect { CGRect(x: x, y: 2.5, width: 24, height: 24) }

    private func read(_ bars: AutoOverflowTracker.TrappedBar..., overflowed: Set<String> = [], unanswered: Set<String> = []) -> AutoOverflowTracker.Read {
        .init(overflowedApps: overflowed, unansweredApps: unanswered, trappedBars: bars)
    }

    /// The dots are out of the way in a read and in the one after it, which is what a move waits for: the first read only asks for the
    /// second.
    @discardableResult
    private func confirmed(_ tracker: inout AutoOverflowTracker, _ sections: inout SectionModel, _ read: AutoOverflowTracker.Read,
                           at seconds: Double) -> AutoOverflowTracker.Outcome {
        let first = tracker.arrived(read, sections: &sections, now: t(seconds - 0.5))
        #expect(first.movedForDots.isEmpty, "the first read moves nothing")
        #expect(first.awaitingConfirmation == read.trappedBars.map(\.displayUUID), "it asks for the second")
        return tracker.arrived(read, sections: &sections, now: t(seconds))
    }

    private let hiddenAuto = AppPlacement(section: .hidden, isAuto: true)
    private let shownAuto = AppPlacement(section: .shown, isAuto: true)
    private let shownByTheirOwn = AppPlacement(section: .shown, isAuto: false)

    // MARK: Making room

    @Test func theLeftmostShownAppGoesToHiddenAsAnAutomaticMove() {
        var tracker = AutoOverflowTracker()
        var sections = shown(a, b, c)

        let outcome = confirmed(&tracker, &sections, read(trapped(apps: [a, b, c])), at: 0)
        #expect(outcome.changed)
        #expect(outcome.movedForDots == [.init(bundleID: a, displayUUID: laptop)])
        #expect(sections.apps[a] == hiddenAuto)
        #expect(sections.apps[b] == shownByTheirOwn && sections.apps[c] == shownByTheirOwn)
        #expect(tracker.trialApps.isEmpty, "a move for the dots is not a trial")
    }

    @Test func asManyAppsAreMovedAsTheDotsAreWide() {
        // The dots need 76 points and each app takes 38: two go, not one and not three.
        var tracker = AutoOverflowTracker()
        var sections = shown(a, b, c)
        let outcome = confirmed(&tracker, &sections, read(trapped(needed: 76, apps: [a, b, c])), at: 0)
        #expect(outcome.movedForDots.map(\.bundleID) == [a, b])
        #expect(sections.apps[c] == shownByTheirOwn)

        // An app that takes more than is needed alone is enough alone.
        var other = AutoOverflowTracker()
        var wide = shown(a, b)
        let one = confirmed(&other, &wide, read(.init(displayUUID: laptop, neededWidth: 76, apps: [.init(bundleID: a, width: 120), .init(bundleID: b, width: 38)])),
                            at: 0)
        #expect(one.movedForDots.map(\.bundleID) == [a])
    }

    @Test func anAppWhoseRoomIsUnknownIsTakenToBeRoomEnough() {
        var tracker = AutoOverflowTracker()
        var sections = shown(a, b)
        let bar = AutoOverflowTracker.TrappedBar(displayUUID: laptop, neededWidth: 76,
                                                 apps: [.init(bundleID: a, width: nil), .init(bundleID: b, width: 38)])
        #expect(confirmed(&tracker, &sections, read(bar), at: 0).movedForDots.map(\.bundleID) == [a])
    }

    @Test func dotsBackOnTheBarStopMovingAnything() {
        var tracker = AutoOverflowTracker()
        var sections = shown(a, b, c)
        #expect(confirmed(&tracker, &sections, read(trapped(apps: [a, b, c])), at: 0).changed)

        // The next read says the dots are on the bar: nothing more is moved, now or later.
        for seconds in [10.0, 20, 70, 600] {
            let outcome = tracker.arrived(read(), sections: &sections, now: t(seconds))
            #expect(outcome == AutoOverflowTracker.Outcome())
        }
        #expect(sections.apps[a] == hiddenAuto && sections.apps[b] == shownByTheirOwn && sections.apps[c] == shownByTheirOwn)
    }

    @Test func aReadThatMovedAnOverflowedAppLeavesTheDotsToTheNextRead() {
        // Apps the person put left of the dots overflow before the dots do. Moving them may have made the room.
        var tracker = AutoOverflowTracker()
        var sections = shown(a, b, c)
        let outcome = tracker.arrived(read(trapped(apps: [b, c]), overflowed: [a]), sections: &sections, now: t(0))
        #expect(outcome.changed)
        #expect(sections.apps[a] == hiddenAuto)
        #expect(outcome.movedForDots.isEmpty)
        #expect(sections.apps[b] == shownByTheirOwn)

        // If it wasn't enough, the next read says so, and the left-most app that is still Shown goes: a move of an app that overflowed
        // itself is nobody's trial, and doesn't hold the dots up.
        #expect(tracker.arrived(read(trapped(apps: [b, c])), sections: &sections, now: t(2)).movedForDots.map(\.bundleID) == [b])
    }

    @Test func movesAreOneInTenSeconds() {
        var tracker = AutoOverflowTracker()
        var sections = shown(a, b, c)
        #expect(confirmed(&tracker, &sections, read(trapped(apps: [a, b, c])), at: 0).movedForDots.map(\.bundleID) == [a])
        // Still trapped one read later: the next app waits for the ten seconds.
        #expect(!tracker.arrived(read(trapped(apps: [b, c])), sections: &sections, now: t(2)).changed)
        #expect(!tracker.arrived(read(trapped(apps: [b, c])), sections: &sections, now: t(9.9)).changed)
        #expect(sections.apps[b] == shownByTheirOwn)
        #expect(tracker.arrived(read(trapped(apps: [b, c])), sections: &sections, now: t(10)).movedForDots.map(\.bundleID) == [b])
    }

    @Test func aChangeOfDisplaysLetsTheNextMoveComeAtOnceButStillWantsTwoReads() {
        var tracker = AutoOverflowTracker()
        var sections = shown(a, b)
        #expect(confirmed(&tracker, &sections, read(trapped(apps: [a, b])), at: 0).changed)
        _ = tracker.roomMayHaveReturned(.displaysChanged, sections: &sections, predictedFits: { _ in false }, now: t(1))
        // The first read after the change is only asked to be confirmed; the second moves, without waiting for the ten seconds.
        let first = tracker.arrived(read(trapped(apps: [b])), sections: &sections, now: t(2))
        #expect(first.movedForDots.isEmpty && first.awaitingConfirmation == [laptop])
        #expect(tracker.arrived(read(trapped(apps: [b])), sections: &sections, now: t(3)).movedForDots.map(\.bundleID) == [b])
        // And then it is paced again.
        var more = shown(c)
        #expect(!tracker.arrived(read(trapped(apps: [c])), sections: &more, now: t(4)).changed)
    }

    @Test func theReadThatComesWithAChangeOfDisplaysDoesNotCountTowardsTheTwo() {
        // The read that was taken for the change is ingested first, and the tracker is told of the change after it: what it saw then is of
        // the displays as they were.
        var tracker = AutoOverflowTracker()
        var sections = shown(a, b)
        let sighting = tracker.arrived(read(trapped(apps: [a, b])), sections: &sections, now: t(0))
        #expect(sighting.awaitingConfirmation == [laptop])
        _ = tracker.roomMayHaveReturned(.displaysChanged, sections: &sections, predictedFits: { _ in false }, now: t(0.1))
        let after = tracker.arrived(read(trapped(apps: [a, b])), sections: &sections, now: t(1))
        #expect(after.movedForDots.isEmpty, "this is the first read since the change")
        #expect(after.awaitingConfirmation == [laptop])
        #expect(tracker.arrived(read(trapped(apps: [a, b])), sections: &sections, now: t(2)).movedForDots.map(\.bundleID) == [a])
    }

    @Test func aTrialThatStartedAfterAChangeUsesUpItsBypass() {
        // The change of displays let a move come at once; the trial it brought was the next thing the tracker did, and a move is paced from
        // it like from any trial.
        var tracker = AutoOverflowTracker()
        var sections = shown(b)
        sections.apps[a] = hiddenAuto
        #expect(tracker.roomMayHaveReturned(.displaysChanged, sections: &sections, predictedFits: fits, now: t(0)) == [a])
        #expect(tracker.arrived(read(), sections: &sections, now: t(1)).changed, "the trial passes")
        _ = tracker.arrived(read(trapped(apps: [b])), sections: &sections, now: t(2))
        #expect(!tracker.arrived(read(trapped(apps: [b])), sections: &sections, now: t(3)).changed, "three seconds after the trial's start")
        #expect(tracker.arrived(read(trapped(apps: [b])), sections: &sections, now: t(10)).movedForDots.map(\.bundleID) == [b])
    }

    @Test func theLogHearsWhenAnAppStaysAndWhyATrialFailed() {
        // An app that came back and has to go again is pinned: the move says so.
        var tracker = AutoOverflowTracker()
        var sections = shown(a, b)
        #expect(confirmed(&tracker, &sections, read(trapped(apps: [a, b])), at: 0).movedForDots == [.init(bundleID: a, displayUUID: laptop)])
        #expect(tracker.roomMayHaveReturned(.periodic, sections: &sections, predictedFits: fits, now: t(60)) == [a])
        _ = tracker.arrived(read(), sections: &sections, now: t(61))
        let again = confirmed(&tracker, &sections, read(trapped(apps: [a, b])), at: 600)
        #expect(again.movedForDots == [.init(bundleID: a, displayUUID: laptop, isPinned: true)])

        // An app that was moved for overflowing itself, and whose trial pushes the dots out: the dots weren't out before, and it says so.
        var other = AutoOverflowTracker()
        var more = SectionModel()
        more.apps[c] = hiddenAuto
        #expect(other.roomMayHaveReturned(.periodic, sections: &more, predictedFits: fits, now: t(0)) == [c])
        _ = other.arrived(read(trapped(apps: [c])), sections: &more, now: t(0.5))
        let failed = other.arrived(read(trapped(apps: [c])), sections: &more, now: t(1))
        #expect(failed.failedForDots == [.init(bundleID: c, displayUUID: laptop, isPinned: true, wasMovedForTheDots: false)])
        #expect(more.apps[c] == hiddenAuto)
    }

    @Test func aMoveThatChangedNothingStopsFurtherMoves() {
        // The dots say they are at x 484 and 522; an app is moved; ten seconds later they say it again. The apps moved change nothing, and
        // no more is moved: what the dots say is out of date, and stays so whatever is done.
        var tracker = AutoOverflowTracker()
        var sections = shown(a, b, c)
        let places = [place(484), place(522)]
        #expect(confirmed(&tracker, &sections, read(trapped(apps: [a, b, c], places: places)), at: 0).movedForDots.map(\.bundleID) == [a])
        let stuck = tracker.arrived(read(trapped(apps: [b, c], places: places)), sections: &sections, now: t(10))
        #expect(stuck.movedForDots.isEmpty)
        #expect(stuck.stoppedForDots == [.init(displayUUID: laptop, reason: .samePlace, held: 38)])
        #expect(stuck.noRoomToMakeFor.isEmpty, "b and c are Shown and were not moved: it is not that no app is left")
        #expect(sections.apps[b] == shownByTheirOwn && sections.apps[c] == shownByTheirOwn)
        // It stays stopped, and says nothing more.
        for seconds in [20.0, 100, 1000] {
            let outcome = tracker.arrived(read(trapped(apps: [b, c], places: places)), sections: &sections, now: t(seconds))
            #expect(outcome == AutoOverflowTracker.Outcome(), "\(seconds)")
        }
        // A change of displays starts over.
        _ = tracker.roomMayHaveReturned(.displaysChanged, sections: &sections, predictedFits: { _ in false }, now: t(1001))
        _ = tracker.arrived(read(trapped(apps: [b, c], places: places)), sections: &sections, now: t(1002))
        #expect(tracker.arrived(read(trapped(apps: [b, c], places: places)), sections: &sections, now: t(1003)).movedForDots.map(\.bundleID) == [b])
    }

    @Test func aMoveThatChangedWhereTheDotsAreLetsTheNextOneCome() {
        var tracker = AutoOverflowTracker()
        var sections = shown(a, b, c)
        #expect(confirmed(&tracker, &sections, read(trapped(apps: [a, b, c], places: [place(484), place(522)])), at: 0).changed)
        // One dot is drawn now and the other says it is somewhere else: the move did something, and the room it made wasn't enough.
        let next = tracker.arrived(read(trapped(apps: [b, c], places: [place(522)])), sections: &sections, now: t(10))
        #expect(next.movedForDots.map(\.bundleID) == [b] && next.stoppedForDots.isEmpty)
    }

    @Test func noMoreIsMovedThanWhatTheDotsNeededAndOneAppMore() {
        // They need 38 points and each app takes 38: the first app, and one more; then no more, however the dots move about.
        var tracker = AutoOverflowTracker()
        var sections = shown(a, b, c)
        #expect(confirmed(&tracker, &sections, read(trapped(apps: [a, b, c], places: [place(484)])), at: 0).movedForDots.map(\.bundleID) == [a])
        #expect(tracker.arrived(read(trapped(apps: [b, c], places: [place(500)])), sections: &sections, now: t(10)).movedForDots.map(\.bundleID) == [b])
        let capped = tracker.arrived(read(trapped(apps: [c], places: [place(520)])), sections: &sections, now: t(20))
        #expect(capped.movedForDots.isEmpty)
        #expect(capped.stoppedForDots == [.init(displayUUID: laptop, reason: .enoughMoved, held: 76)])
        #expect(capped.noRoomToMakeFor.isEmpty, "c is Shown and was refused: it is not that no app is left")
        #expect(sections.apps[c] == shownByTheirOwn)
        // A change of displays gives the allowance again.
        _ = tracker.roomMayHaveReturned(.displaysChanged, sections: &sections, predictedFits: { _ in false }, now: t(30))
        _ = tracker.arrived(read(trapped(apps: [c], places: [place(520)])), sections: &sections, now: t(31))
        #expect(tracker.arrived(read(trapped(apps: [c], places: [place(520)])), sections: &sections, now: t(32)).movedForDots.map(\.bundleID) == [c])
    }

    @Test func theCapIsWhatTheDotsNeededAndTheNextAppAndNotTheWidestOne() {
        // They need 38 points. An app further along the bar takes 100, which used to make room for a third app to go: the cap is what they
        // needed and the app that is next, so after two apps of 38 the third is refused.
        var tracker = AutoOverflowTracker()
        var sections = shown(a, b, c, "com.example.d")
        func bar(_ apps: [(String, CGFloat)], places: [CGRect]) -> AutoOverflowTracker.TrappedBar {
            .init(displayUUID: laptop, neededWidth: 38, apps: apps.map { .init(bundleID: $0.0, width: $0.1) }, dotPlaces: places)
        }
        let all: [(String, CGFloat)] = [(a, 38), (b, 38), (c, 38), ("com.example.d", 100)]
        #expect(confirmed(&tracker, &sections, read(bar(all, places: [place(484)])), at: 0).movedForDots.map(\.bundleID) == [a])
        #expect(tracker.arrived(read(bar(Array(all.dropFirst()), places: [place(500)])), sections: &sections, now: t(10)).movedForDots.map(\.bundleID) == [b])
        let capped = tracker.arrived(read(bar(Array(all.dropFirst(2)), places: [place(520)])), sections: &sections, now: t(20))
        #expect(capped.movedForDots.isEmpty)
        #expect(capped.stoppedForDots == [.init(displayUUID: laptop, reason: .enoughMoved, held: 76)])
        #expect(sections.apps[c] == shownByTheirOwn)
    }

    // MARK: A cycle that ended

    @Test func aGoodCycleThenTheSameLayoutMovesAgain() {
        // The dots are trapped at two places and an app is moved; the dots are drawn, the app's trial passes, and it is Shown again. Later
        // the same layout comes back, with the dots at the same places: that is a new trap, and not the old one that nothing changed.
        var tracker = AutoOverflowTracker()
        var sections = shown(a, b)
        let places = [place(484), place(522)]
        #expect(confirmed(&tracker, &sections, read(trapped(apps: [a, b], places: places)), at: 0).movedForDots.map(\.bundleID) == [a])
        #expect(tracker.arrived(read(), sections: &sections, now: t(5)) == AutoOverflowTracker.Outcome(), "the dots are drawn")
        #expect(tracker.roomMayHaveReturned(.periodic, sections: &sections, predictedFits: fits, now: t(60)) == [a])
        #expect(tracker.arrived(read(), sections: &sections, now: t(61)).returnedForDots.map(\.bundleID) == [a])
        #expect(sections.apps[a] == shownByTheirOwn)

        let again = confirmed(&tracker, &sections, read(trapped(apps: [a, b], places: places)), at: 600)
        #expect(again.stoppedForDots.isEmpty, "not the same trap as before the cycle")
        #expect(again.movedForDots == [.init(bundleID: a, displayUUID: laptop, isPinned: true)], "it came back once, so it stays out")
        #expect(sections.apps[a] == hiddenAuto)
    }

    @Test func aStopLastsOnlyUntilTheDotsAreSeenOnTheBar() {
        var tracker = AutoOverflowTracker()
        var sections = shown(a, b, c)
        let places = [place(484), place(522)]
        #expect(confirmed(&tracker, &sections, read(trapped(apps: [a, b, c], places: places)), at: 0).movedForDots.map(\.bundleID) == [a])
        #expect(tracker.arrived(read(trapped(apps: [b, c], places: places)), sections: &sections, now: t(10)).stoppedForDots
            == [.init(displayUUID: laptop, reason: .samePlace, held: 38)])
        #expect(tracker.arrived(read(trapped(apps: [b, c], places: places)), sections: &sections, now: t(20)) == AutoOverflowTracker.Outcome())

        // One read has the dots right: the stop is over, and the next trap is moved for.
        #expect(tracker.arrived(read(), sections: &sections, now: t(30)) == AutoOverflowTracker.Outcome())
        let next = confirmed(&tracker, &sections, read(trapped(apps: [b, c], places: places)), at: 40)
        #expect(next.stoppedForDots.isEmpty)
        #expect(next.movedForDots.map(\.bundleID) == [b])
    }

    @Test func aCapStopLastsOnlyUntilTheDotsAreSeenOnTheBar() {
        // As much is held in Hidden as the dots need and one app more, and they are still out: stopped. A read that has them right ends it,
        // but what is held stays held: the next trap is capped again at once, and no app is moved by the stop having ended.
        var tracker = AutoOverflowTracker()
        var sections = shown(a, b, c)
        #expect(confirmed(&tracker, &sections, read(trapped(apps: [a, b, c], places: [place(484)])), at: 0).movedForDots.map(\.bundleID) == [a])
        #expect(tracker.arrived(read(trapped(apps: [b, c], places: [place(500)])), sections: &sections, now: t(10)).movedForDots.map(\.bundleID) == [b])
        #expect(tracker.arrived(read(trapped(apps: [c], places: [place(520)])), sections: &sections, now: t(20)).stoppedForDots
            == [.init(displayUUID: laptop, reason: .enoughMoved, held: 76)])
        #expect(tracker.arrived(read(), sections: &sections, now: t(30)) == AutoOverflowTracker.Outcome())
        let again = confirmed(&tracker, &sections, read(trapped(apps: [c], places: [place(540)])), at: 40)
        #expect(again.movedForDots.isEmpty)
        #expect(again.stoppedForDots == [.init(displayUUID: laptop, reason: .enoughMoved, held: 76)], "what is held is still held")
        #expect(sections.apps[c] == shownByTheirOwn)
    }

    @Test func aPassedTrialGivesItsWidthBackToTheCap() {
        // The dots need 76 points; two apps of 38 are moved and both pass their trials, which gives their room back. Trapped again, the
        // dots need 76 again: both go, and the cap (what they needed, and one app more) has not been used up by apps that came back.
        var tracker = AutoOverflowTracker()
        var sections = shown(a, b, c)
        let first = confirmed(&tracker, &sections, read(trapped(needed: 76, apps: [a, b, c], places: [place(484), place(522)])), at: 0)
        #expect(first.movedForDots.map(\.bundleID) == [a, b])
        #expect(tracker.arrived(read(), sections: &sections, now: t(5)) == AutoOverflowTracker.Outcome())
        #expect(tracker.roomMayHaveReturned(.periodic, sections: &sections, predictedFits: fits, now: t(60)) == [a, b])
        #expect(tracker.arrived(read(), sections: &sections, now: t(61)).returnedForDots.map(\.bundleID) == [a, b])

        let again = confirmed(&tracker, &sections, read(trapped(needed: 76, apps: [a, b, c], places: [place(500), place(540)])), at: 600)
        #expect(again.stoppedForDots.isEmpty)
        #expect(again.movedForDots == [.init(bundleID: a, displayUUID: laptop, isPinned: true), .init(bundleID: b, displayUUID: laptop, isPinned: true)])
        #expect(sections.apps[c] == shownByTheirOwn)
    }

    @Test func whatThePersonMovedBackIsNotHeldForTheDots() {
        // An app was moved for the dots and the person put it back in Shown: it is theirs, and what it took is not held in Hidden.
        var tracker = AutoOverflowTracker()
        var sections = shown(a, b, c)
        #expect(confirmed(&tracker, &sections, read(trapped(apps: [a, b, c], places: [place(484)])), at: 0).movedForDots.map(\.bundleID) == [a])
        sections.move(app: a, to: .shown)
        // It is not on the bar's list any more (it quit, say), and the dots are still trapped: b goes, and then c may, as when a was never held.
        #expect(tracker.arrived(read(trapped(apps: [b, c], places: [place(500)])), sections: &sections, now: t(10)).movedForDots.map(\.bundleID) == [b])
        let third = tracker.arrived(read(trapped(apps: [c], places: [place(520)])), sections: &sections, now: t(20))
        #expect(third.movedForDots.map(\.bundleID) == [c] && third.stoppedForDots.isEmpty)
    }

    // MARK: A trial that was let go

    @Test func anAppLetGoOnATrialIsPinnedWhenItIsMovedAgainAndAtMostTwoMovesInAll() {
        // The app on trial doesn't answer for a minute and is let go, Shown, with no verdict. It was moved for the dots, so the next time is
        // its second: it stays in Hidden. However many times this goes round (nothing changes the displays), no app is moved more than twice.
        var tracker = AutoOverflowTracker()
        var sections = shown(a, b, c)
        var moves: [String: [Bool]] = [:]  // by app: for each move, whether it was pinned
        var now = 0.0
        for cycle in 0..<8 {
            let onTheBar = [a, b, c].filter { sections.section(ofApp: $0) == .shown }
            guard !onTheBar.isEmpty else { break }
            let places = [place(560 + CGFloat(cycle))]
            let trap = read(trapped(apps: onTheBar, places: places))
            _ = tracker.arrived(trap, sections: &sections, now: t(now))
            for move in tracker.arrived(trap, sections: &sections, now: t(now + 0.5)).movedForDots { moves[move.bundleID, default: []].append(move.isPinned) }
            _ = tracker.arrived(read(), sections: &sections, now: t(now + 1))
            let trial = tracker.roomMayHaveReturned(.periodic, sections: &sections, predictedFits: fits, now: t(now + 61))
            _ = tracker.arrived(read(unanswered: trial), sections: &sections, now: t(now + 62))
            _ = tracker.arrived(read(unanswered: trial), sections: &sections, now: t(now + 122))
            #expect(tracker.trialApps.isEmpty, "let go: cycle \(cycle)")
            now += 130
        }
        #expect(moves[a] == [false, true], "a is moved twice, and the second time it stays")
        for (app, pins) in moves {
            #expect(pins.count <= 2 && pins.dropFirst().allSatisfy { $0 }, "\(app): \(pins)")
        }
        #expect(sections.apps[a] == hiddenAuto)
    }

    @Test func aTrialLetGoForWantOfAConfirmationIsPinnedWhenItIsMovedAgain() {
        // The dots flicker between two displays through the minute the trial has, so it is never confirmed and is let go. The dots are then
        // confirmed on one display, and the app that was let go is the left-most: it goes, and stays.
        var tracker = AutoOverflowTracker()
        var sections = shown(a, b)
        #expect(confirmed(&tracker, &sections, read(trapped(apps: [a, b], places: [place(560)])), at: 0).movedForDots.map(\.bundleID) == [a])
        #expect(tracker.arrived(read(), sections: &sections, now: t(5)) == AutoOverflowTracker.Outcome())
        #expect(tracker.roomMayHaveReturned(.periodic, sections: &sections, predictedFits: fits, now: t(60)) == [a])
        for (seconds, display) in [(61.0, laptop), (75, desk), (90, laptop), (110, desk), (120, laptop)] {
            _ = tracker.arrived(read(trapped(display, apps: [b], places: [place(560)])), sections: &sections, now: t(seconds))
        }
        #expect(tracker.trialApps.isEmpty && sections.apps[a] == shownAuto, "let go at the minute")
        // The read at 120 was the first sighting on the laptop; the next confirms it.
        let again = tracker.arrived(read(trapped(apps: [a, b], places: [place(580)])), sections: &sections, now: t(200))
        #expect(again.movedForDots == [.init(bundleID: a, displayUUID: laptop, isPinned: true)])
        #expect(tracker.roomMayHaveReturned(.periodic, sections: &sections, predictedFits: fits, now: t(1000)).isEmpty, "it stays in Hidden")
    }

    @Test func aTrialIsLetGoForWantOfAConfirmationOnlyOnceItWasAskedFor() {
        // The first read to show the dots out of the way comes a minute after the trial began. Letting the trial go then would have it end
        // with no verdict before a confirming read was ever asked for: that read is asked for, and the trial waits for it.
        var tracker = AutoOverflowTracker()
        var sections = shown(a, b)
        #expect(confirmed(&tracker, &sections, read(trapped(apps: [a, b], places: [place(560)])), at: 0).movedForDots.map(\.bundleID) == [a])
        #expect(tracker.arrived(read(), sections: &sections, now: t(5)) == AutoOverflowTracker.Outcome())
        #expect(tracker.roomMayHaveReturned(.periodic, sections: &sections, predictedFits: fits, now: t(60)) == [a])
        let first = tracker.arrived(read(trapped(laptop, apps: [b], places: [place(560)])), sections: &sections, now: t(130))
        #expect(first.awaitingConfirmation == [laptop])
        #expect(tracker.trialApps == [a], "an old trial, but no confirming read was asked for before this one")
        // The read that confirms it decides.
        let second = tracker.arrived(read(trapped(laptop, apps: [b], places: [place(560)])), sections: &sections, now: t(131))
        #expect(second.failedForDots.map(\.bundleID) == [a])
    }

    @Test func noAppIsMovedMoreThanTwiceWhateverTheReadsAndTrialsDo() {
        // Reads that have the dots out or not, an app on trial that doesn't answer, and trials that start when there is room: with the
        // displays never changing, and within half an hour, no app is moved for the dots more than twice, and every move after the first is
        // pinned.
        struct Rng { var state: UInt64
            mutating func next(_ n: Int) -> Int { state = state &* 6364136223846793005 &+ 1442695040888963407; return Int((state >> 33) % UInt64(n)) } }
        let apps = [a, b, c, "com.example.d", "com.example.e"]
        for seed in UInt64(1)...150 {
            var rng = Rng(state: seed)
            var tracker = AutoOverflowTracker()
            var sections = shown(apps[0], apps[1], apps[2], apps[3], apps[4])
            var moves: [String: [Bool]] = [:]
            var now = 0.0
            // (Within one pin's half hour: a pin that has run out lets the app be tried and moved once more.)
            while now < 1700 {
                now += [0.5, 1, 5, 11, 30, 61][rng.next(6)]
                let onTheBar = apps.filter { sections.section(ofApp: $0) == .shown }
                var outcome: AutoOverflowTracker.Outcome?
                switch rng.next(10) {
                case 0...4:
                    let hung: Set<String> = rng.next(4) == 0 ? tracker.trialApps : []
                    outcome = tracker.arrived(read(trapped(apps: onTheBar.filter { !hung.contains($0) }, places: [place([500, 520][rng.next(2)])]),
                                                   unanswered: hung), sections: &sections, now: t(now))
                case 5...7:
                    let hung: Set<String> = rng.next(4) == 0 ? tracker.trialApps : []
                    outcome = tracker.arrived(read(unanswered: hung), sections: &sections, now: t(now))
                default:
                    let room = rng.next(3) != 0
                    _ = tracker.roomMayHaveReturned(rng.next(2) == 0 ? .periodic : .frontAppChanged, sections: &sections, predictedFits: { _ in room },
                                                    now: t(now))
                }
                for move in outcome?.movedForDots ?? [] { moves[move.bundleID, default: []].append(move.isPinned) }
            }
            for (app, pins) in moves {
                #expect(pins.count <= 2 && pins.dropFirst().allSatisfy { $0 }, "seed \(seed), \(app): \(pins)")
            }
        }
    }

    @Test func whatIsHeldCountsTheAppsOnTrialToo() {
        // The dots need 38 points. An app that was moved for them is on trial, and doesn't answer; the dots are out of the way. The 38 it
        // took is still held (it goes back to Hidden if the trial fails), so one more app goes and no more: not two.
        var tracker = AutoOverflowTracker()
        var sections = shown(a, b, c, "com.example.d")
        #expect(confirmed(&tracker, &sections, read(trapped(apps: [a, b, c, "com.example.d"], places: [place(484)])), at: 0).movedForDots.map(\.bundleID) == [a])
        #expect(tracker.arrived(read(), sections: &sections, now: t(5)) == AutoOverflowTracker.Outcome())
        #expect(tracker.roomMayHaveReturned(.periodic, sections: &sections, predictedFits: fits, now: t(60)) == [a])

        func hung(_ apps: [String], _ x: CGFloat) -> AutoOverflowTracker.Read { read(trapped(apps: apps, places: [place(x)]), unanswered: [a]) }
        #expect(tracker.arrived(hung([b, c, "com.example.d"], 500), sections: &sections, now: t(61)).awaitingConfirmation == [laptop])
        #expect(tracker.arrived(hung([b, c, "com.example.d"], 500), sections: &sections, now: t(71)).movedForDots.map(\.bundleID) == [b])
        let capped = tracker.arrived(hung([c, "com.example.d"], 520), sections: &sections, now: t(81))
        #expect(capped.movedForDots.isEmpty)
        #expect(capped.stoppedForDots == [.init(displayUUID: laptop, reason: .enoughMoved, held: 76)])
        #expect(sections.apps[c] == shownByTheirOwn)
    }

    @Test func anAppOutOfTheWayOnlyByItsPlaceWaitsForASecondRead() {
        var tracker = AutoOverflowTracker()
        var sections = shown(a, b)
        let inferred = AutoOverflowTracker.Read(overflowedApps: [a], inferredApps: [a])
        let first = tracker.arrived(inferred, sections: &sections, now: t(0))
        #expect(!first.changed && first.awaitingApps == [a])
        #expect(sections.apps[a] == shownByTheirOwn)
        // The second read says the same: it goes.
        let second = tracker.arrived(inferred, sections: &sections, now: t(1))
        #expect(second.changed && sections.apps[a] == hiddenAuto && second.awaitingApps.isEmpty)
        // One told by a slot or a « is moved at once, as before.
        let told = tracker.arrived(.init(overflowedApps: [b]), sections: &sections, now: t(2))
        #expect(told.changed && sections.apps[b] == hiddenAuto)
    }

    @Test func aReadThatHasTheAppRightStartsItsCountAgain() {
        var tracker = AutoOverflowTracker()
        var sections = shown(a)
        let inferred = AutoOverflowTracker.Read(overflowedApps: [a], inferredApps: [a])
        _ = tracker.arrived(inferred, sections: &sections, now: t(0))
        _ = tracker.arrived(.init(overflowedApps: []), sections: &sections, now: t(1))
        #expect(!tracker.arrived(inferred, sections: &sections, now: t(2)).changed, "a first sighting again")
        // A change of displays, or a time when nothing was made of the reads, starts it again too.
        tracker.displaysAreChanging()
        #expect(!tracker.arrived(inferred, sections: &sections, now: t(3)).changed)
        #expect(tracker.arrived(inferred, sections: &sections, now: t(4)).changed)
    }

    @Test func readsThatWereNotMadeOfAreNotCounted() {
        var tracker = AutoOverflowTracker()
        var sections = shown(a, b)
        _ = tracker.arrived(read(trapped(apps: [a, b])), sections: &sections, now: t(0))
        // Automatic overflow was turned off for a while, and on again: the sighting before is not the first of two.
        tracker.forgetSightings()
        let again = tracker.arrived(read(trapped(apps: [a, b])), sections: &sections, now: t(100))
        #expect(again.movedForDots.isEmpty && again.awaitingConfirmation == [laptop])
        #expect(tracker.arrived(read(trapped(apps: [a, b])), sections: &sections, now: t(101)).movedForDots.map(\.bundleID) == [a])
    }

    @Test func aTrialAppThatIsOutOfTheWayOnlyByItsPlaceStaysOnTrialUntilItIsConfirmed() {
        var tracker = AutoOverflowTracker()
        var sections = SectionModel()
        sections.apps[a] = hiddenAuto
        #expect(tracker.roomMayHaveReturned(.periodic, sections: &sections, predictedFits: fits, now: t(0)) == [a])
        let inferred = AutoOverflowTracker.Read(overflowedApps: [a], inferredApps: [a])
        let first = tracker.arrived(inferred, sections: &sections, now: t(1))
        #expect(!first.changed && first.awaitingApps == [a] && tracker.trialApps == [a])
        let second = tracker.arrived(inferred, sections: &sections, now: t(2))
        #expect(second.changed && sections.apps[a] == hiddenAuto && tracker.trialApps.isEmpty)
    }

    @Test func aSingleSightingDuringATrialDoesNotPinTheApp() {
        var tracker = AutoOverflowTracker()
        var sections = SectionModel()
        sections.apps[a] = hiddenAuto
        #expect(tracker.roomMayHaveReturned(.periodic, sections: &sections, predictedFits: fits, now: t(0)) == [a])
        // The dots are out of the way in the read that judges the trial, and in none before it: the app stays on trial, nothing is pinned or
        // failed, and the read that confirms is asked for.
        let single = tracker.arrived(read(trapped(apps: [b])), sections: &sections, now: t(1))
        #expect(!single.changed && single.failedForDots.isEmpty && single.awaitingConfirmation == [laptop])
        #expect(tracker.trialApps == [a] && sections.apps[a] == shownAuto)
        // The next read has them right: the app passes, as if the person had put it there, and is not pinned.
        let passed = tracker.arrived(read(), sections: &sections, now: t(2))
        #expect(passed.changed && sections.apps[a] == shownByTheirOwn)
        #expect(tracker.trialApps.isEmpty)
    }

    @Test func aTrialSightingThatIsConfirmedFailsAndPins() {
        var tracker = AutoOverflowTracker()
        var sections = SectionModel()
        sections.apps[a] = hiddenAuto
        #expect(tracker.roomMayHaveReturned(.periodic, sections: &sections, predictedFits: fits, now: t(0)) == [a])
        _ = tracker.arrived(read(trapped(apps: [b])), sections: &sections, now: t(1))
        let outcome = tracker.arrived(read(trapped(apps: [b])), sections: &sections, now: t(2))
        #expect(outcome.failedForDots.map(\.bundleID) == [a])
        #expect(sections.apps[a] == hiddenAuto)
        #expect(tracker.roomMayHaveReturned(.periodic, sections: &sections, predictedFits: fits, now: t(500)).isEmpty, "pinned")
    }

    @Test func aTrialIsJudgedByTheDotsCountedAfreshFromItsStart() {
        // The dots were out of the way in one read before the trial began (and the read asked for the one that confirms it). The trial's
        // first read has them out again: that is a first sighting of this trial's, and doesn't fail it, as it would with the count it
        // inherited.
        var tracker = AutoOverflowTracker()
        var sections = shown(a, b)
        #expect(confirmed(&tracker, &sections, read(trapped(apps: [a, b])), at: 0).movedForDots.map(\.bundleID) == [a])
        #expect(tracker.arrived(read(), sections: &sections, now: t(5)) == AutoOverflowTracker.Outcome())
        let before = tracker.arrived(read(trapped(apps: [b])), sections: &sections, now: t(59))
        #expect(before.awaitingConfirmation == [laptop] && before.movedForDots.isEmpty)
        #expect(tracker.roomMayHaveReturned(.periodic, sections: &sections, predictedFits: fits, now: t(60)) == [a])

        let first = tracker.arrived(read(trapped(apps: [a, b])), sections: &sections, now: t(60.5))
        #expect(first.failedForDots.isEmpty && first.awaitingConfirmation == [laptop])
        #expect(tracker.trialApps == [a] && sections.apps[a] == shownAuto)
        // The one that confirms it fails the trial.
        #expect(tracker.arrived(read(trapped(apps: [a, b])), sections: &sections, now: t(61)).failedForDots.map(\.bundleID) == [a])
    }

    @Test func aTrialThatWaitsForAConfirmingReadIsLetGoWhenItIsAsOldAsAnAppThatDoesNotAnswer() {
        // The dots flicker between two displays, each seen once at a time, and never twice in a row on one: the trial waits for the read
        // that confirms it, and has no end to wait for.
        var tracker = AutoOverflowTracker()
        var sections = shown(a, b)
        #expect(confirmed(&tracker, &sections, read(trapped(apps: [a, b])), at: 0).movedForDots.map(\.bundleID) == [a])
        #expect(tracker.arrived(read(), sections: &sections, now: t(5)) == AutoOverflowTracker.Outcome())
        #expect(tracker.roomMayHaveReturned(.periodic, sections: &sections, predictedFits: fits, now: t(60)) == [a])
        for (seconds, display) in [(61.0, laptop), (75, desk), (90, laptop), (118, desk)] {
            let outcome = tracker.arrived(read(trapped(display, apps: [b])), sections: &sections, now: t(seconds))
            #expect(outcome.awaitingConfirmation == [display] && outcome.failedForDots.isEmpty, "\(seconds)")
            #expect(tracker.trialApps == [a], "\(seconds)")
        }
        // A minute from its start it is let go where it is: Shown, and not failed or pinned.
        let old = tracker.arrived(read(trapped(laptop, apps: [b])), sections: &sections, now: t(120))
        #expect(tracker.trialApps.isEmpty && old.failedForDots.isEmpty)
        #expect(sections.apps[a] == shownAuto)
        #expect(old.awaitingConfirmation == [laptop], "the dots still ask for the read that confirms them")
    }

    @Test func aTrialAppThatIsOutOfTheWayOnlyByItsPlaceIsLetGoWhenTheTrialIsOld() {
        var tracker = AutoOverflowTracker()
        var sections = SectionModel()
        sections.apps[a] = hiddenAuto
        #expect(tracker.roomMayHaveReturned(.periodic, sections: &sections, predictedFits: fits, now: t(0)) == [a])
        let inferred = AutoOverflowTracker.Read(overflowedApps: [a], inferredApps: [a])
        #expect(tracker.arrived(inferred, sections: &sections, now: t(1)).awaitingApps == [a])
        // What was counted is lost (a change of displays), and the next sighting is a first again, a minute on.
        tracker.displaysAreChanging()
        #expect(tracker.arrived(inferred, sections: &sections, now: t(30)).awaitingApps == [a] && tracker.trialApps == [a])
        tracker.displaysAreChanging()
        let old = tracker.arrived(inferred, sections: &sections, now: t(61))
        #expect(old.awaitingApps == [a], "it is still not confirmed")
        #expect(tracker.trialApps.isEmpty, "but the trial doesn't wait for it any longer")
        #expect(sections.apps[a] == shownAuto)
    }

    @Test func anAppThatOverflowsOnTrialFailsAtOnceWhateverTheDotsSay() {
        var tracker = AutoOverflowTracker()
        var sections = SectionModel()
        sections.apps[a] = hiddenAuto
        #expect(tracker.roomMayHaveReturned(.periodic, sections: &sections, predictedFits: fits, now: t(0)) == [a])
        // It is in the « itself: no confirmation is needed for that.
        let outcome = tracker.arrived(read(trapped(apps: [b]), overflowed: [a]), sections: &sections, now: t(1))
        #expect(outcome.changed && sections.apps[a] == hiddenAuto && tracker.trialApps.isEmpty)
        #expect(outcome.failedForDots.isEmpty, "cooled as an app that overflowed is, not pinned for the dots")
    }

    @Test func aReadThatHasTheDotsRightStartsTheCountAgain() {
        var tracker = AutoOverflowTracker()
        var sections = shown(a, b)
        #expect(tracker.arrived(read(trapped(apps: [a, b])), sections: &sections, now: t(0)).awaitingConfirmation == [laptop])
        // The dots are on the bar in the next read: what the first saw was a glitch.
        #expect(tracker.arrived(read(), sections: &sections, now: t(1)) == AutoOverflowTracker.Outcome())
        // Trapped again: that is a first sighting once more.
        let again = tracker.arrived(read(trapped(apps: [a, b])), sections: &sections, now: t(2))
        #expect(again.movedForDots.isEmpty && again.awaitingConfirmation == [laptop])
        #expect(sections.apps[a] == shownByTheirOwn && sections.apps[b] == shownByTheirOwn)
        #expect(tracker.arrived(read(trapped(apps: [a, b])), sections: &sections, now: t(3)).movedForDots.map(\.bundleID) == [a])
    }

    @Test func eachBarIsConfirmedOnItsOwn() {
        var tracker = AutoOverflowTracker()
        var sections = shown(a, b)
        // The laptop's dots are seen twice and the desk's once: only the laptop's make room, and the desk's wait for their second.
        _ = tracker.arrived(read(trapped(laptop, apps: [a, b])), sections: &sections, now: t(0))
        let outcome = tracker.arrived(read(trapped(laptop, apps: [a, b]), trapped(desk, apps: [a, b])), sections: &sections, now: t(1))
        #expect(outcome.movedForDots == [.init(bundleID: a, displayUUID: laptop)])
        #expect(outcome.awaitingConfirmation == [desk])
    }

    @Test func aMoveAndATrialAreOneInTenSecondsBetweenThem() {
        var tracker = AutoOverflowTracker()
        var sections = shown(a, b)
        sections.apps[c] = hiddenAuto
        #expect(confirmed(&tracker, &sections, read(trapped(apps: [a, b])), at: 0).changed)
        // The room may be back a moment later, but no trial starts within ten seconds of the move.
        #expect(tracker.roomMayHaveReturned(.frontAppChanged, sections: &sections, predictedFits: fits, now: t(5)).isEmpty)
        #expect(tracker.roomMayHaveReturned(.frontAppChanged, sections: &sections, predictedFits: fits, now: t(10)) == [a, c])
    }

    @Test func anAppOnTrialIsNeverMovedForTheDots() {
        var tracker = AutoOverflowTracker()
        var sections = SectionModel()
        sections.apps[a] = hiddenAuto
        #expect(tracker.roomMayHaveReturned(.displaysChanged, sections: &sections, predictedFits: fits, now: t(0)) == [a])
        // The read that follows has the dots trapped and `a` among the apps that could be moved: it is on trial, and it is judged, not
        // moved a second time.
        sections.move(app: b, to: .shown)
        _ = tracker.arrived(read(trapped(apps: [a, b]), unanswered: [a]), sections: &sections, now: t(1))
        // (The trial began ten seconds before, so that a move is no sooner than the trial allows.)
        let outcome = tracker.arrived(read(trapped(apps: [a, b]), unanswered: [a]), sections: &sections, now: t(10))
        #expect(sections.apps[a] == shownAuto, "it didn't answer: it stays on trial")
        #expect(outcome.movedForDots.map(\.bundleID) == [b])
    }

    @Test func aBarWithNoShownAppToMoveSaysSoAndMovesNothing() {
        var tracker = AutoOverflowTracker()
        var sections = SectionModel()
        sections.move(app: a, to: .hidden)
        let outcome = confirmed(&tracker, &sections, read(trapped(apps: [])), at: 1)
        #expect(!outcome.changed)
        #expect(outcome.noRoomToMakeFor == [laptop])
        // Not being able to doesn't use up the ten seconds.
        sections.move(app: b, to: .shown)
        #expect(tracker.arrived(read(trapped(apps: [b])), sections: &sections, now: t(2)).movedForDots.map(\.bundleID) == [b])
    }

    @Test func oneAppFreesRoomOnEveryBarItIsOn() {
        var tracker = AutoOverflowTracker()
        var sections = shown(a, b)
        let outcome = confirmed(&tracker, &sections, read(trapped(laptop, apps: [a, b]), trapped(desk, apps: [a, b])), at: 0)
        #expect(outcome.movedForDots == [.init(bundleID: a, displayUUID: laptop)], "moved for the first bar, and enough for the second")
        #expect(outcome.noRoomToMakeFor.isEmpty)
    }

    // MARK: Giving the room back

    @Test func roomBackReturnsTheAutoAppWithoutFlapping() {
        var tracker = AutoOverflowTracker()
        var sections = shown(a, b)
        #expect(confirmed(&tracker, &sections, read(trapped(apps: [a, b])), at: 0).changed)
        #expect(sections.apps[a] == hiddenAuto)

        // A minute later room is predicted: the app is put on trial, like any other that Mantel moved.
        #expect(tracker.roomMayHaveReturned(.periodic, sections: &sections, predictedFits: fits, now: t(60)) == [a])
        #expect(sections.apps[a] == shownAuto)
        // The read that judges it has the dots on the bar: it stays, as if the person had put it there, and the log hears of it.
        let back = tracker.arrived(read(), sections: &sections, now: t(61))
        #expect(back.returnedForDots == [.init(bundleID: a, displayUUID: laptop)])
        #expect(sections.apps[a] == shownByTheirOwn)

        // And that is all: no trial, no move, no flap, however many triggers and reads come after.
        for seconds in stride(from: 70.0, through: 700, by: 30) {
            #expect(tracker.roomMayHaveReturned(.periodic, sections: &sections, predictedFits: fits, now: t(seconds)).isEmpty)
            #expect(tracker.arrived(read(), sections: &sections, now: t(seconds + 1)) == AutoOverflowTracker.Outcome())
        }
        #expect(sections.apps[a] == shownByTheirOwn)
    }

    @Test func aTrialThatPushesTheDotsOutAgainGoesBackAndStaysUntilTheDisplaysChange() {
        var tracker = AutoOverflowTracker()
        var sections = shown(a, b)
        #expect(confirmed(&tracker, &sections, read(trapped(apps: [a, b])), at: 0).changed)
        #expect(tracker.arrived(read(), sections: &sections, now: t(30)) == AutoOverflowTracker.Outcome(), "the dots are on the bar")
        #expect(tracker.roomMayHaveReturned(.periodic, sections: &sections, predictedFits: fits, now: t(60)) == [a])

        // The dots are in the « again, though no app overflowed, in this read and in the one that confirms it: the app on trial is what
        // pushed them out.
        let single = tracker.arrived(read(trapped(apps: [a, b])), sections: &sections, now: t(60.5))
        #expect(single.failedForDots.isEmpty && single.awaitingConfirmation == [laptop], "one sighting is not enough")
        let outcome = tracker.arrived(read(trapped(apps: [a, b])), sections: &sections, now: t(61))
        #expect(outcome.failedForDots == [.init(bundleID: a, displayUUID: laptop, isPinned: true, wasMovedForTheDots: true)])
        #expect(outcome.movedForDots.isEmpty, "it was the trial's doing: nothing more is moved for it")
        #expect(sections.apps[a] == hiddenAuto)
        #expect(tracker.trialApps.isEmpty)

        // Not tried again, whatever the room, for as long as the pin lasts: not after a minute (the cooling of an app that overflowed), and
        // not after nearly half an hour.
        for seconds in [125.0, 200, 900, 1800] {
            #expect(tracker.roomMayHaveReturned(.periodic, sections: &sections, predictedFits: fits, now: t(seconds)).isEmpty)
            #expect(tracker.roomMayHaveReturned(.frontAppChanged, sections: &sections, predictedFits: fits, now: t(seconds + 1)).isEmpty)
        }
        // A change of displays frees it.
        #expect(tracker.roomMayHaveReturned(.displaysChanged, sections: &sections, predictedFits: fits, now: t(1810)) == [a])
    }

    @Test func anAppThatCameBackAndHasToGoAgainStaysOutUntilTheDisplaysChange() {
        var tracker = AutoOverflowTracker()
        var sections = shown(a, b)
        #expect(confirmed(&tracker, &sections, read(trapped(apps: [a, b])), at: 0).changed)
        #expect(tracker.roomMayHaveReturned(.periodic, sections: &sections, predictedFits: fits, now: t(60)) == [a])
        #expect(tracker.arrived(read(), sections: &sections, now: t(61)).returnedForDots.map(\.bundleID) == [a])

        // Later the dots are trapped again, and the left-most Shown app is the same one: it goes, and this time it stays.
        let again = confirmed(&tracker, &sections, read(trapped(apps: [a, b])), at: 600)
        #expect(again.movedForDots.map(\.bundleID) == [a])
        #expect(tracker.arrived(read(), sections: &sections, now: t(601)) == AutoOverflowTracker.Outcome())
        for seconds in [700.0, 1000, 2000] {
            #expect(tracker.roomMayHaveReturned(.periodic, sections: &sections, predictedFits: fits, now: t(seconds)).isEmpty)
        }
        #expect(tracker.roomMayHaveReturned(.displaysChanged, sections: &sections, predictedFits: fits, now: t(2100)) == [a])
    }

    @Test func aPinRunsOutAfterHalfAnHourAndTheAppIsTriedOnceMore() {
        // The app came back once and went again, so it is pinned in Hidden. The displays never change; half an hour on it is tried again, and
        // fails (the dots are out again with it on the bar): pinned for another half hour, and not tried in between.
        var tracker = AutoOverflowTracker()
        var sections = shown(a, b)
        #expect(confirmed(&tracker, &sections, read(trapped(apps: [a, b])), at: 0).changed)
        #expect(tracker.roomMayHaveReturned(.periodic, sections: &sections, predictedFits: fits, now: t(60)) == [a])
        #expect(tracker.arrived(read(), sections: &sections, now: t(61)).returnedForDots.map(\.bundleID) == [a])
        let pinned = confirmed(&tracker, &sections, read(trapped(apps: [a, b])), at: 600)
        #expect(pinned.movedForDots == [.init(bundleID: a, displayUUID: laptop, isPinned: true)])
        #expect(AutoOverflowTracker.pinExpiry == .seconds(1800))

        for seconds in [700.0, 1200, 2399] {
            #expect(tracker.roomMayHaveReturned(.periodic, sections: &sections, predictedFits: fits, now: t(seconds)).isEmpty, "\(seconds)")
        }
        #expect(tracker.roomMayHaveReturned(.periodic, sections: &sections, predictedFits: fits, now: t(2400)) == [a], "pinned at 600, and 1800 s on")
        // It pushes the dots out again, in two reads: it goes back, and is pinned from now.
        _ = tracker.arrived(read(trapped(apps: [b])), sections: &sections, now: t(2401))
        #expect(tracker.arrived(read(trapped(apps: [b])), sections: &sections, now: t(2402)).failedForDots.map(\.bundleID) == [a])
        for seconds in [2500.0, 3000, 4201] {
            #expect(tracker.roomMayHaveReturned(.periodic, sections: &sections, predictedFits: fits, now: t(seconds)).isEmpty, "\(seconds)")
        }
        #expect(tracker.roomMayHaveReturned(.periodic, sections: &sections, predictedFits: fits, now: t(4202)) == [a], "half an hour after the second pin")
    }

    @Test func aPinThatRanOutLetsTheAppPassItsTrial() {
        var tracker = AutoOverflowTracker()
        var sections = shown(a, b)
        #expect(confirmed(&tracker, &sections, read(trapped(apps: [a, b])), at: 0).changed)
        #expect(tracker.roomMayHaveReturned(.periodic, sections: &sections, predictedFits: fits, now: t(60)) == [a])
        _ = tracker.arrived(read(trapped(apps: [b])), sections: &sections, now: t(61))
        #expect(tracker.arrived(read(trapped(apps: [b])), sections: &sections, now: t(62)).failedForDots.map(\.bundleID) == [a], "pinned at 62")
        #expect(tracker.roomMayHaveReturned(.periodic, sections: &sections, predictedFits: fits, now: t(1861)).isEmpty)
        #expect(tracker.roomMayHaveReturned(.periodic, sections: &sections, predictedFits: fits, now: t(1862)) == [a])
        // The room is back this time: it passes, and is an ordinary Shown app.
        #expect(tracker.arrived(read(), sections: &sections, now: t(1863)).returnedForDots.map(\.bundleID) == [a])
        #expect(sections.apps[a] == shownByTheirOwn)
    }

    @Test func anAppThatMovedForTheDotsAndOverflowsOnTrialIsCooledAsAnyOther() {
        var tracker = AutoOverflowTracker()
        var sections = shown(a, b)
        #expect(confirmed(&tracker, &sections, read(trapped(apps: [a, b])), at: 0).changed)
        #expect(tracker.roomMayHaveReturned(.periodic, sections: &sections, predictedFits: fits, now: t(60)) == [a])
        // The app itself is in the « this time: the rule for apps that overflow applies, a minute's cooling.
        let outcome = tracker.arrived(read(overflowed: [a]), sections: &sections, now: t(61))
        #expect(outcome.failedForDots.isEmpty && outcome.returnedForDots.isEmpty)
        #expect(sections.apps[a] == hiddenAuto)
        #expect(tracker.roomMayHaveReturned(.periodic, sections: &sections, predictedFits: fits, now: t(100)).isEmpty)
        #expect(tracker.roomMayHaveReturned(.periodic, sections: &sections, predictedFits: fits, now: t(125)) == [a])
    }

    @Test func aPersonsMoveOfAnAppThatMovedForTheDotsIsTheirs() {
        var tracker = AutoOverflowTracker()
        var sections = shown(a, b)
        #expect(confirmed(&tracker, &sections, read(trapped(apps: [a, b])), at: 0).changed)
        // The person puts it back in Shown: it isn't automatic any more, and no trial or read decides anything about it that isn't theirs.
        sections.move(app: a, to: .shown)
        #expect(tracker.roomMayHaveReturned(.periodic, sections: &sections, predictedFits: fits, now: t(60)).isEmpty)
        #expect(sections.apps[a] == shownByTheirOwn)
        // If the dots are trapped again it is a Shown app like any other, and the tracker moves it again.
        #expect(tracker.arrived(read(trapped(apps: [a, b])), sections: &sections, now: t(61)).movedForDots.map(\.bundleID) == [a])
    }

    // MARK: What was there before

    @Test func aReadWithNoStatedDotsIsTheReadItWasBefore() {
        var tracker = AutoOverflowTracker()
        var sections = shown(a, b)
        sections.note([Fixtures.item(Fixtures.itemID(a)), Fixtures.item(Fixtures.itemID(b))])
        #expect(tracker.inventoryArrived(overflowedApps: [a], unansweredApps: [], sections: &sections, now: t(0)))
        #expect(sections.apps[a] == hiddenAuto)
        #expect(tracker.arrived(read(overflowed: [a]), sections: &sections, now: t(1)) == AutoOverflowTracker.Outcome())
    }
}
