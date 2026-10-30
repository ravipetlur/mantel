import Foundation
import Testing

@testable import MKMenuBar

/// When a look or an app doesn't answer, the bar is asked again; only a difference that was answered throws pictures away.
@Suite("Still current watch", .timeLimit(.minutes(2)))
struct StillCurrentWatchTests {
    private let weather = "com.example.weather"
    private let notes = "com.example.notes"

    @Test func aCleanFirstRoundDecidesAtOnce() {
        var watch = StillCurrentWatch(apps: [weather, notes])
        #expect(watch.note(slots: .same, tied: [weather, notes], answered: [weather, notes]) == .done(kept: [weather, notes]))
        #expect(watch.rounds == 1)
    }

    @Test func slotsThatDifferKeepNothing() {
        var watch = StillCurrentWatch(apps: [weather, notes])
        #expect(watch.note(slots: .differs, tied: [weather, notes], answered: [weather, notes], moved: [weather, notes]) == .done(kept: []))
        #expect(watch.rejected == [weather, notes])
    }

    @Test func slotsThatDidNotAnswerAreAskedAgainAndAreNoChange() {
        var watch = StillCurrentWatch(apps: [weather])
        #expect(watch.note(slots: .unanswered, tied: [], answered: []) == .again)
        // The bar is settling: one round that agrees isn't enough, two in a row are.
        #expect(watch.note(slots: .same, tied: [weather], answered: [weather]) == .again)
        #expect(watch.note(slots: .same, tied: [weather], answered: [weather]) == .done(kept: [weather]))
    }

    @Test func appsThatAreNotKeptAreOutOfTimeWhenNothingWasSeenToDiffer() {
        var neverLooked = StillCurrentWatch(apps: [weather])
        for _ in 0..<StillCurrentWatch.maxRounds { _ = neverLooked.note(slots: .unanswered, tied: [], answered: []) }
        #expect(neverLooked.isOutOfTime(keeping: [], of: [weather]), "no look answered: the bar wasn't seen")

        var cutShort = StillCurrentWatch(apps: [weather])
        #expect(cutShort.note(slots: .unanswered, tied: [], answered: []) == .again)
        #expect(cutShort.isOutOfTime(keeping: [], of: [weather]), "the bound ended it with nothing judged")

        var looked = StillCurrentWatch(apps: [weather])
        #expect(looked.note(slots: .differs, tied: [], answered: [], moved: [weather]) == .done(kept: []))
        #expect(!looked.isOutOfTime(keeping: [], of: [weather]), "a look that answered whole and differed is a change")
    }

    @Test func anAppThatNeverAnswersIsOutOfTimeAtTheLastRoundOfALookThatAnsweredWhole() {
        var watch = StillCurrentWatch(apps: [weather])
        // The look is the same in every round, and the app never answers: nothing was seen to move.
        for _ in 0..<(StillCurrentWatch.maxRounds - 1) { #expect(watch.note(slots: .same, tied: [], answered: []) == .again) }
        #expect(watch.note(slots: .same, tied: [], answered: []) == .done(kept: []))
        #expect(watch.isOutOfTime(keeping: [], of: [weather]), "a look that answered whole and didn't differ says nothing of a change")
    }

    @Test func anAppThatWasSeenToDifferIsAChangeEvenWhenNoLookAnswered() {
        var watch = StillCurrentWatch(apps: [weather, notes])
        // The weather app's frames are not in its slots: that is its own difference; the notes app never answered.
        #expect(watch.note(slots: .unanswered, tied: [], answered: [weather]) == .again)
        #expect(!watch.isOutOfTime(keeping: [], of: [weather]), "the one that differed was judged")
        #expect(!watch.isOutOfTime(keeping: [], of: [weather, notes]), "and what moved is said, whatever became of the other")
    }

    @Test func nothingIsOutOfTimeWhenEveryAppIsKept() {
        var watch = StillCurrentWatch(apps: [weather])
        #expect(watch.note(slots: .same, tied: [weather], answered: [weather]) == .done(kept: [weather]))
        #expect(!watch.isOutOfTime(keeping: [weather], of: [weather]))
    }

    @Test func anAppsPicturesAreKeptWhenAnotherNeverAnswers() {
        var watch = StillCurrentWatch(apps: [weather, notes])
        // The notes app doesn't answer in any round: the weather app's frames were confirmed, and that is kept.
        #expect(watch.note(slots: .same, tied: [weather], answered: [weather]) == .again)
        #expect(watch.confirmed == [weather])
        for _ in 0..<(StillCurrentWatch.maxRounds - 2) {
            #expect(watch.note(slots: .same, tied: [], answered: []) == .again)
        }
        #expect(watch.note(slots: .same, tied: [], answered: []) == .done(kept: [weather]), "after the last round")
    }

    @Test func anAppWhoseFramesAreInOtherSlotsIsARealDifferenceForThatApp() {
        var watch = StillCurrentWatch(apps: [weather, notes])
        #expect(watch.note(slots: .same, tied: [notes], answered: [weather, notes]) == .done(kept: [notes]))
        #expect(watch.rejected == [weather])
    }

    @Test func aBarThatMovesBetweenTwoRoundsAfterAMissedLookKeepsNothingOfWhatMoved() {
        var watch = StillCurrentWatch(apps: [weather])
        _ = watch.note(slots: .unanswered, tied: [], answered: [])
        _ = watch.note(slots: .same, tied: [weather], answered: [weather])
        // The second look finds the app's frames elsewhere: it was still moving.
        #expect(watch.note(slots: .same, tied: [], answered: [weather]) == .done(kept: []))
    }

    @Test func anAppWhoseFramesMovedIsRejectedInARoundWhoseLookDidNotAnswer() {
        var watch = StillCurrentWatch(apps: [weather, notes])
        // The look didn't answer, but the weather app did, with its frames away from the slots the read gave it: that is a change.
        #expect(watch.note(slots: .unanswered, tied: [notes], answered: [weather, notes]) == .again)
        #expect(watch.rejected == [weather])
        // The bar is back by the next rounds, and the weather app's frames are where they were: it was rejected, and stays so.
        #expect(watch.note(slots: .same, tied: [weather, notes], answered: [weather, notes]) == .again)
        #expect(watch.note(slots: .same, tied: [weather, notes], answered: [weather, notes]) == .done(kept: [notes]))
    }

    @Test func theRoundsAreBounded() {
        var watch = StillCurrentWatch(apps: [weather])
        for _ in 0..<(StillCurrentWatch.maxRounds - 1) {
            #expect(watch.note(slots: .unanswered, tied: [], answered: []) == .again)
        }
        #expect(watch.note(slots: .unanswered, tied: [], answered: []) == .done(kept: []))
    }

    @Test func slotsThatDifferCostOnlyTheAppsWhoseSlotsMoved() {
        var watch = StillCurrentWatch(apps: [weather, notes])
        // The weather app's icon is left of the new slot, the notes app's right of it, in a slot that is where it was, with its frames in it.
        #expect(watch.note(slots: .differs, tied: [notes], answered: [weather, notes], moved: [weather]) == .done(kept: [notes]))
        #expect(watch.rejected == [weather])
        #expect(!watch.isOutOfTime(keeping: [notes], of: [weather, notes]), "what moved is a change")
    }

    @Test func anAppInASlotThatDidntMoveStillNeedsItsFramesInIt() {
        var watch = StillCurrentWatch(apps: [weather, notes])
        // Both apps' slots are where they were, and the notes app's frames lie elsewhere (an icon that slid into the slot of another's width).
        #expect(watch.note(slots: .differs, tied: [weather], answered: [weather, notes], moved: []) == .done(kept: [weather]))
        #expect(watch.rejected == [notes])
    }

    @Test func anAppThatDidntAnswerWaitsForTheNextRoundWhenTheSlotsDiffer() {
        var watch = StillCurrentWatch(apps: [weather, notes])
        #expect(watch.note(slots: .differs, tied: [notes], answered: [notes], moved: []) == .again)
        #expect(watch.confirmed == [notes])
        #expect(watch.note(slots: .same, tied: [weather], answered: [weather]) == .done(kept: [notes, weather]))
    }

    @Test func aDifferingLookAfterAMissedOneStillNeedsTwoRoundsThatAgree() {
        var watch = StillCurrentWatch(apps: [weather, notes])
        _ = watch.note(slots: .unanswered, tied: [], answered: [])
        // The bar was settling: the first look that answers is not enough.
        #expect(watch.note(slots: .differs, tied: [notes], answered: [notes], moved: [weather]) == .again)
        #expect(watch.confirmed.isEmpty)
        #expect(watch.rejected == [weather])
        #expect(watch.note(slots: .same, tied: [notes], answered: [notes]) == .done(kept: [notes]))
    }

    @Test func everyAppWhoseSlotsMovedEndsTheCheckAtOnce() {
        var watch = StillCurrentWatch(apps: [weather, notes])
        #expect(watch.note(slots: .differs, tied: [], answered: [], moved: [weather, notes]) == .done(kept: []))
        #expect(watch.rounds == 1)
    }

    @Test func theLooksThatAnsweredAreCounted() {
        var watch = StillCurrentWatch(apps: [weather])
        _ = watch.note(slots: .unanswered, tied: [], answered: [])
        #expect(watch.looksAnswered == 0)
        _ = watch.note(slots: .same, tied: [], answered: [])
        #expect(watch.looksAnswered == 1)
    }

    // MARK: A difference that moved none of the apps that are waiting

    @Test func aDifferenceThatMovedNoneOfTheWaitingAppsLeavesAnUnansweredAppOutOfTime() {
        var watch = StillCurrentWatch(apps: [weather])
        // The look answers whole and differs (something came at the left end), and moves no app that is waiting; the app never answers.
        for _ in 0..<(StillCurrentWatch.maxRounds - 1) { #expect(watch.note(slots: .differs, tied: [], answered: [], moved: []) == .again) }
        #expect(watch.note(slots: .differs, tied: [], answered: [], moved: []) == .done(kept: []))
        #expect(watch.isOutOfTime(keeping: [], of: [weather]), "nothing of this app moved, and it wasn't judged: that is no change of its")
    }

    @Test func theAppsNotJudgedAreSaidWhateverElseTheCheckFound() {
        var watch = StillCurrentWatch(apps: [weather, notes])
        // The weather app's icons moved; the notes app never answers.
        for _ in 0..<(StillCurrentWatch.maxRounds - 1) {
            #expect(watch.note(slots: .differs, tied: [], answered: [weather], moved: [weather]) == .again)
        }
        #expect(watch.note(slots: .differs, tied: [], answered: [weather], moved: [weather]) == .done(kept: []))

        let answer = StillCurrentFindings().answer(for: watch, kept: [], of: [weather, notes])
        #expect(!answer.outOfTime, "an app moved: that is a change")
        #expect(answer.changes == ["not judged: \(notes)"], "\(answer.changes)")
    }

    @Test func aCheckThatRanOutOfTimeSaysHowFarItGotWithoutSayingSoTwice() {
        var watch = StillCurrentWatch(apps: [weather])
        _ = watch.note(slots: .unanswered, tied: [], answered: [])
        _ = watch.note(slots: .same, tied: [], answered: [])
        let answer = StillCurrentFindings().answer(for: watch, kept: [], of: [weather])
        #expect(answer.outOfTime)
        #expect(answer.changes == ["after 2 rounds, a whole look in 1 of them; not judged: \(weather)"], "\(answer.changes)")
    }

    @Test func aCheckThatJudgedEveryAppSaysNothingOfTheAppsNotJudged() {
        var watch = StillCurrentWatch(apps: [weather])
        #expect(watch.note(slots: .same, tied: [weather], answered: [weather]) == .done(kept: [weather]))
        #expect(StillCurrentFindings().answer(for: watch, kept: [weather], of: [weather]).changes.isEmpty)
    }
}
