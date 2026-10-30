import Foundation
import Testing

@testable import MKLayout

/// What the log says of a ⌘-drag, in its words.
@Suite("Command drag log", .timeLimit(.minutes(2)))
struct CommandDragLogTests {
    @Test func theSettingIsTheFirstReasonThenTheRevealThenAnEarlierDrag() {
        typealias S = CommandDragLog.ShowAll
        #expect(S.decide(settingOn: true, revealAllows: true, earlierDragShowing: false) == .shown)
        #expect(S.decide(settingOn: false, revealAllows: false, earlierDragShowing: true) == .settingOff)
        #expect(S.decide(settingOn: true, revealAllows: false, earlierDragShowing: true) == .somethingShowing)
        #expect(S.decide(settingOn: true, revealAllows: true, earlierDragShowing: true) == .earlierDragShowing)
    }
}
