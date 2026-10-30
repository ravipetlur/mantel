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

    @Test func slotsThatDifferCostOnlyTheAppsWhoseSlotsMoved() {
        var watch = StillCurrentWatch(apps: [weather, notes])
        // The weather app's icon is left of the new slot, the notes app's right of it, in a slot that is where it was, with its frames in it.
        #expect(watch.note(slots: .differs, tied: [notes], answered: [weather, notes], moved: [weather]) == .done(kept: [notes]))
        #expect(watch.rejected == [weather])
        #expect(!watch.isOutOfTime(keeping: [notes], of: [weather, notes]), "what moved is a change")
    }
}
