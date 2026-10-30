import Foundation
import Testing

@testable import MKLayout

/// What the log says of a ⌘-drag, in its words.
@Suite("Command drag log")
struct CommandDragLogTests {
    @Test func theSettingIsTheFirstReasonThenTheRevealThenAnEarlierDrag() {
        typealias S = CommandDragLog.ShowAll
        #expect(S.decide(settingOn: true, revealAllows: true, earlierDragShowing: false) == .shown)
        #expect(S.decide(settingOn: false, revealAllows: false, earlierDragShowing: true) == .settingOff)
        #expect(S.decide(settingOn: true, revealAllows: false, earlierDragShowing: true) == .somethingShowing)
        #expect(S.decide(settingOn: true, revealAllows: true, earlierDragShowing: true) == .earlierDragShowing)
    }

    @Test func aDragThatBeginsIsOneLineThatSaysWhetherEverythingWasShown() {
        #expect(CommandDragLog.beganLine(.shown) == "⌘-drag seen: began; everything shown for it")
        #expect(CommandDragLog.beganLine(.shown, toldAfter: 0.4) == "⌘-drag seen: began; everything shown for it", "a moment says nothing")
        #expect(CommandDragLog.beganLine(.settingOff, toldAfter: 2.5)
                == "⌘-drag seen: began; everything not shown for it (the setting is off); told 2.5 s after it was seen")
        #expect(CommandDragLog.beganLine(.settingOff) == "⌘-drag seen: began; everything not shown for it (the setting is off)")
        #expect(CommandDragLog.beganLine(.somethingShowing)
                == "⌘-drag seen: began; everything not shown for it (everything or Focus Mode was showing already)")
        #expect(CommandDragLog.beganLine(.earlierDragShowing)
                == "⌘-drag seen: began; everything not shown for it (an earlier drag's reveal was still in force)")
    }

    @Test func aFollowThatMovedAppsListsThemSortedWithTheirSections() {
        let line = CommandDragLog.followLine(.moved(["com.example.b": .alwaysHidden, "com.example.a": .hidden]), afterDrop: 1.44, begunAfter: 0,
                                             limitReached: false)
        #expect(line == "⌘-drag followed 1.4 s after the drop: sections changed: com.example.a to Hidden, com.example.b to Always Hidden")
        #expect(CommandDragLog.followLine(.nothingMoved, afterDrop: 0.6, begunAfter: 0.2, limitReached: false)
                == "⌘-drag followed 0.6 s after the drop: no section changed")
    }

    @Test func aFollowThatWasNotMadeSaysWhy() {
        func line(_ follow: CommandDragLog.Follow, limit: Bool = false) -> String {
            CommandDragLog.followLine(follow, afterDrop: 3.6, begunAfter: 0, limitReached: limit)
        }
        #expect(line(.notTrusted(.appsMissing(["com.example.a", "com.example.b"])), limit: true)
                == "⌘-drag not followed 3.6 s after the drop: a read not trusted: com.example.a, com.example.b didn't answer, or answered in part; the limit of 3.5 s was reached")
        #expect(line(.notTrusted(.agentReadCut)) == "⌘-drag not followed 3.6 s after the drop: a read not trusted: MenuBarAgent's read was cut")
        #expect(line(.notTrusted(.unclaimedSlots(2))) == "⌘-drag not followed 3.6 s after the drop: a read not trusted: 2 slots that no app claims")
        #expect(line(.writeUnderWay)
                == "⌘-drag not followed 3.6 s after the drop: a write of the order was under way; it is followed when the write ends")
        #expect(line(.noBars, limit: true) == "⌘-drag not followed 3.6 s after the drop: the read had no bars; the limit of 3.5 s was reached")
        #expect(line(.notRun) == "⌘-drag not followed 3.6 s after the drop: quitting, resetting or no read taken")
    }

    @Test func aFollowThatBeganLateSaysSoOnlyWhenItWasMoreThanAMoment() {
        #expect(!CommandDragLog.followLine(.nothingMoved, afterDrop: 1, begunAfter: 0.9, limitReached: false).contains("began"))
        #expect(CommandDragLog.followLine(.nothingMoved, afterDrop: 61, begunAfter: 58, limitReached: false).hasSuffix("; its wait began 58.0 s after the drop"))
    }

    @Test func aDragWhoseMouseUpWasNotSeenDoesNotSpeakOfADrop() {
        let capped = CommandDragLog.End.capReached(after: 10.2)
        let line = CommandDragLog.followLine(.moved(["com.example.a": .hidden]), afterDrop: 1.4, begunAfter: 0, limitReached: false, end: capped)
        #expect(line == "⌘-drag followed 1.4 s after the cap: sections changed: com.example.a to Hidden; no mouse-up seen, the drag was held 10.2 s")
        #expect(!line.contains("drop"))
        #expect(CommandDragLog.followLine(.notRun, afterDrop: 0.6, begunAfter: 58, limitReached: false, end: capped)
                == "⌘-drag not followed 0.6 s after the cap: quitting, resetting or no read taken; its wait began 58.0 s after the cap; no mouse-up seen, the drag was held 10.2 s")
        #expect(CommandDragLog.followLine(.nothingMoved, afterDrop: 0.6, begunAfter: 0, limitReached: false, end: .mouseUp)
                == "⌘-drag followed 0.6 s after the drop: no section changed", "a mouse-up is a drop, as before")
    }
}
