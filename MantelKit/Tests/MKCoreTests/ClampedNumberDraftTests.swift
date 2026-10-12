import Testing

@testable import MKCore

@Suite("Clamped number draft", .timeLimit(.minutes(1)))
struct ClampedNumberDraftTests {
    private let format = ClampedIntegerFormat(range: 1000...10000, step: 100)

    private func draft(_ number: Int = 3000) -> ClampedNumberDraft {
        ClampedNumberDraft(committed: number, format: format)
    }

    @Test func theFieldStartsOnTheNumberItStandsFor() {
        let draft = draft(3000)
        #expect(draft.text == "3000")
        #expect(draft.committed == 3000)
    }

    @Test func typingNeverCommits() {
        var draft = draft(3000)
        // The person types 12, a key at a time: each text is kept as it is, and the number the field stands for doesn't move.
        for typed in ["", "1", "12", "12", "1", "10"] {
            draft.text = typed
            #expect(draft.text == typed, "a number half typed is left alone")
            #expect(draft.committed == 3000, "typed: \(typed)")
        }
        // 99999 typed up to the last digit is still 3000 until it is committed.
        for typed in ["9", "99", "999", "9999", "99999"] {
            draft.text = typed
            #expect(draft.committed == 3000, "typed: \(typed)")
        }
    }

    @Test func commitClampsLowAndHigh() {
        var low = draft(3000)
        low.text = "12"
        #expect(low.commit() == 1000)
        #expect(low.committed == 1000)
        #expect(low.text == "1000", "the field shows what was kept")

        var high = draft(3000)
        high.text = "99999"
        #expect(high.commit() == 10000)
        #expect(high.committed == 10000)
        #expect(high.text == "10000")

        // Past what an Int can hold is as far past the range as can be.
        var huge = draft(3000)
        huge.text = "99999999999999999999999"
        #expect(huge.commit() == 10000)
    }

    @Test func aNumberBetweenStepsIsPutOnTheNearestStep() {
        var between = draft(3000)
        between.text = "3149"
        #expect(between.commit() == 3100)
        between.text = "3150"
        #expect(between.commit() == 3200)
        #expect(between.text == "3200")
    }

    @Test func nonNumericCommitKeepsTheOldValue() {
        for text in ["", "abc", "12x", "1.5", "--3", "a1", "  "] {
            var draft = draft(3000)
            draft.text = text
            #expect(draft.commit() == nil, "text: \(text)")
            #expect(draft.committed == 3000, "text: \(text)")
            #expect(draft.text == "3000", "the field goes back to the number it had: \(text)")
        }
    }

    @Test func spacesAndGroupMarksAreReadAsDigitsAreWhenCommitted() {
        var draft = draft(3000)
        draft.text = "4 500"
        #expect(draft.commit() == 4500)
        draft.text = "6,000"
        #expect(draft.commit() == 6000)
    }

    @Test func committingTheSameNumberSavesNothing() {
        var draft = draft(3000)
        // Return and then leaving the field are two commits: the second has nothing to save.
        draft.text = "4000"
        #expect(draft.commit() == 4000)
        #expect(draft.commit() == nil)
        // The text that clamps to the number the field already stands for saves nothing either.
        draft.text = "4030"
        #expect(draft.commit() == nil)
        #expect(draft.text == "4000")
    }

    @Test func aNumberChangedFromOutsideIsTakenAndTheTextFollows() {
        var draft = draft(3000)
        // Half a number is typed, and the stepper moves the number: the stepper wins.
        draft.text = "12"
        draft.follow(3100)
        #expect(draft.committed == 3100)
        #expect(draft.text == "3100")
        #expect(draft.commit() == nil)
    }
}
