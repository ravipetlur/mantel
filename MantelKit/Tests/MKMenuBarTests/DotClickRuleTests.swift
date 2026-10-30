import Testing

@testable import MKMenuBar

@Suite("Dot click rule", .timeLimit(.minutes(2)))
struct DotClickRuleTests {
    @Test func aRightClickOpensTheMenuAndNothingElseDoes() {
        #expect(DotClickRule.action(for: .rightMouseUp) == .openMenu)
        for other: DotClickEvent in [.leftMouseUp, .noMouseEvent] {
            #expect(DotClickRule.action(for: other) != .openMenu, "\(other)")
        }
    }

    @Test func aLeftClickRevealsAndSoDoesAPressByAnAssistiveTool() {
        #expect(DotClickRule.action(for: .leftMouseUp) == .reveal)
        #expect(DotClickRule.action(for: .noMouseEvent) == .reveal, "a press has no mouse event of its own")
    }

    @Test func aRightClickCountsOnlyOnTheDotsOwnWindow() {
        #expect(DotClickRule.event(isLeftMouseUp: false, isRightMouseUp: true, isOnTheDotsWindow: true, age: 0) == .rightMouseUp)
        // An assistive press: the current event is the last one the app retrieved, which can be a right click on another window.
        #expect(DotClickRule.event(isLeftMouseUp: false, isRightMouseUp: true, isOnTheDotsWindow: false, age: 0) == .noMouseEvent)
        #expect(DotClickRule.action(for: DotClickRule.event(isLeftMouseUp: false, isRightMouseUp: true, isOnTheDotsWindow: false, age: 0)) == .reveal)
    }

    @Test func aLeftClickIsOneWhateverWindowItsEventIsOn() {
        #expect(DotClickRule.event(isLeftMouseUp: true, isRightMouseUp: false, isOnTheDotsWindow: true, age: 0) == .leftMouseUp)
        #expect(DotClickRule.event(isLeftMouseUp: true, isRightMouseUp: false, isOnTheDotsWindow: false, age: 0) == .leftMouseUp)
    }

    @Test func anEventFromLongBeforeIsNoClickOnTheDot() {
        // An assistive press comes with no event, and the current event is the last the app retrieved: a real click from seconds ago.
        #expect(DotClickRule.event(isLeftMouseUp: false, isRightMouseUp: true, isOnTheDotsWindow: true, age: 12) == .noMouseEvent)
        #expect(DotClickRule.event(isLeftMouseUp: true, isRightMouseUp: false, isOnTheDotsWindow: true, age: 12) == .noMouseEvent)
        // On a busy Mac the action can come a second or more after the button went up: that is still the right click, not a reveal.
        #expect(DotClickRule.event(isLeftMouseUp: false, isRightMouseUp: true, isOnTheDotsWindow: true, age: 1.5) == .rightMouseUp)
        // Right at the limit still counts; a hair over doesn't.
        let limit = DotClickRule.freshEventAge
        #expect(DotClickRule.event(isLeftMouseUp: false, isRightMouseUp: true, isOnTheDotsWindow: true, age: limit) == .rightMouseUp)
        #expect(DotClickRule.event(isLeftMouseUp: false, isRightMouseUp: true, isOnTheDotsWindow: true, age: limit + 0.01) == .noMouseEvent)
    }

    @Test func anythingElseIsNoMouseEvent() {
        // Another button or kind of event, or none at all.
        #expect(DotClickRule.event(isLeftMouseUp: false, isRightMouseUp: false, isOnTheDotsWindow: true, age: 0) == .noMouseEvent)
        #expect(DotClickRule.event(isLeftMouseUp: false, isRightMouseUp: false, isOnTheDotsWindow: false, age: 0) == .noMouseEvent)
    }

    @Test func anEventThatIsNoClickOnTheDotIsLoggedWithItsType() {
        // Another kind of event (type 26 is the other buttons' mouse up), or a right click on another window (type 4).
        #expect(DotClickRule.unexpectedEventLogLine(typeCode: 26, event: .noMouseEvent)
            == "a dot's action arrived with an event of type 26, which is no click on the dot")
        #expect(DotClickRule.unexpectedEventLogLine(typeCode: 4, event: .noMouseEvent)
            == "a dot's action arrived with an event of type 4, which is no click on the dot")
    }

    @Test func clicksAndPressesWithNoEventAreNotLogged() {
        #expect(DotClickRule.unexpectedEventLogLine(typeCode: 2, event: .leftMouseUp) == nil)
        #expect(DotClickRule.unexpectedEventLogLine(typeCode: 4, event: .rightMouseUp) == nil)
        #expect(DotClickRule.unexpectedEventLogLine(typeCode: nil, event: .noMouseEvent) == nil, "an assistive press has no event")
    }
}
