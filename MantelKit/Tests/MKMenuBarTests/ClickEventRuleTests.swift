import Foundation
import Testing

// `ClickEventRule` is the test item's own source: the package's tests link `TestFixtures/MantelTestItem/ClickEventRule.swift` (see
// `FixtureClickEventRule.swift`), so what is checked here is the code the test item runs. Nothing here starts the test item or reads an event.

@Suite("The test item's reading of a click", .timeLimit(.minutes(2)))
struct ClickEventRuleTests {
    private func event(_ button: ClickEventRule.LastEvent.Button?, option: Bool = false, onTheItem: Bool = true,
                       age: TimeInterval = 0.01) -> ClickEventRule.LastEvent {
        ClickEventRule.LastEvent(mouseUp: button, isOptionHeld: option, isOnTheItem: onTheItem, age: age)
    }

    @Test func aMouseUpThatJustHappenedOnTheItemIsWhatItWas() {
        #expect(ClickEventRule.kind(of: event(.left)) == .left)
        #expect(ClickEventRule.kind(of: event(.right)) == .right)
        #expect(ClickEventRule.kind(of: event(.left, option: true)) == .option)
        #expect(ClickEventRule.kind(of: event(.right, option: true)) == .right, "a right button is a right click, whatever is held")
    }

    @Test func anEventThatIsOlderThanHalfASecondIsNotCounted() {
        // A press comes with no event of its own, and the last one the app saw was a right click, or an Option click, a while ago.
        #expect(ClickEventRule.kind(of: event(.right, age: 0.51)) == .left)
        #expect(ClickEventRule.kind(of: event(.left, option: true, age: 0.51)) == .left)
        #expect(ClickEventRule.kind(of: event(.right, age: 3600)) == .left)
        #expect(ClickEventRule.freshEventAge == 0.5)
    }

    @Test func anEventOfHalfASecondIsStillWithin() {
        #expect(ClickEventRule.kind(of: event(.right, age: 0.5)) == .right)
        #expect(ClickEventRule.kind(of: event(.left, option: true, age: 0.5)) == .option)
        #expect(ClickEventRule.kind(of: event(.right, age: 0)) == .right)
    }

    @Test func anEventThatIsNotAMouseUpIsNotCounted() {
        // A key, a mouse-down or a drag that was the app's last event, with Option held.
        #expect(ClickEventRule.kind(of: event(nil)) == .left)
        #expect(ClickEventRule.kind(of: event(nil, option: true)) == .left)
    }

    @Test func anEventOnAnotherWindowIsNotCounted() {
        #expect(ClickEventRule.kind(of: event(.right, onTheItem: false)) == .left)
        #expect(ClickEventRule.kind(of: event(.left, option: true, onTheItem: false)) == .left)
    }

    @Test func noEventIsALeftClick() {
        #expect(ClickEventRule.kind(of: nil) == .left)
    }

    @Test func theKindsAreTheWordsTheClickLogHolds() {
        #expect(ClickEventRule.Kind.left.rawValue == "left")
        #expect(ClickEventRule.Kind.right.rawValue == "right")
        #expect(ClickEventRule.Kind.option.rawValue == "option")
    }
}
