import Testing

@testable import MKMenuBar

@Suite("Dot menu opening", .timeLimit(.minutes(2)))
struct DotMenuOpeningTests {
    @Test func aMenuThatNeverOpenedIsNoticed() throws {
        var opening = DotMenuOpening()
        let asked = opening.beginAsking()
        let ticket = try #require(asked)
        opening.endAsking()
        #expect(!opening.hasOpened(since: ticket))
    }

    @Test func aMenuThatOpenedDuringTheAskIsNotMissed() throws {
        // `performClick` tracks the menu until it closes, so everything happens inside the ask.
        var opening = DotMenuOpening()
        let asked = opening.beginAsking()
        let ticket = try #require(asked)
        opening.menuWillOpen()
        opening.endAsking()
        #expect(opening.hasOpened(since: ticket))
    }

    @Test func aMenuThatOpensAfterTheAskReturnedIsFoundByTheSecondLook() throws {
        var opening = DotMenuOpening()
        let asked = opening.beginAsking()
        let ticket = try #require(asked)
        opening.endAsking()
        #expect(!opening.hasOpened(since: ticket), "the first look, as the ask returns")
        opening.menuWillOpen()
        #expect(opening.hasOpened(since: ticket), "the look 0.3 seconds later")
        #expect(DotMenuOpening.recheckDelay == 0.3)
    }

    @Test func aMenuThatOpenedBeforeAnAskIsNotThisAsksMenu() throws {
        var opening = DotMenuOpening()
        opening.menuWillOpen()
        let asked = opening.beginAsking()
        let ticket = try #require(asked)
        opening.endAsking()
        #expect(!opening.hasOpened(since: ticket))
    }

    @Test func aClickInTheMiddleOfAnAskIsNotAClickAndDoesNotAskAgain() throws {
        var opening = DotMenuOpening()
        let first = opening.beginAsking()
        #expect(first != nil)
        #expect(opening.isAsking)
        // The system sent the action while the ask was under way: nothing starts a second one.
        #expect(opening.beginAsking() == nil)
        #expect(opening.beginAsking() == nil)
        opening.endAsking()
        #expect(!opening.isAsking)
        #expect(opening.beginAsking() != nil, "the next click asks again")
    }

    @Test func theLogSaysWhatHappened() {
        #expect(DotMenuOpening.didNotOpenLogLine == "the status item didn't open the menu")
    }
}
