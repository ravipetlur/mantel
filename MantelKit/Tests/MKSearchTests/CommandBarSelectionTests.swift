import MKCore
import Testing

@testable import MKSearch

/// Which result the keyboard is on in the command bar's list.
@Suite("Command bar selection", .timeLimit(.minutes(1)))
struct CommandBarSelectionTests {
    private func results(_ ids: [String]) -> [SearchResult] {
        ids.map { SearchResult(candidate: SearchCandidate(id: $0, kind: .action(.showHidden), title: $0), score: 0, titleOffsets: []) }
    }

    @Test func aNewAnswerKeepsTheSelectedResultWhereverItIs() {
        let list = results(["a", "b", "c", "d"])
        #expect(CommandBarSelection.selecting(results: list, keeping: "c") == CommandBarSelection(index: 2))
        #expect(CommandBarSelection.selecting(results: list, keeping: "a") == CommandBarSelection(index: 0))
        #expect(CommandBarSelection.selecting(results: list.reversed(), keeping: "c") == CommandBarSelection(index: 1))
    }

    @Test func aResultThatIsGoneOrNeverWasFallsBackToTheFirst() {
        let list = results(["a", "b"])
        #expect(CommandBarSelection.selecting(results: list, keeping: "gone") == CommandBarSelection(index: 0))
        #expect(CommandBarSelection.selecting(results: list, keeping: nil) == CommandBarSelection(index: 0))
    }

    @Test func noResultsSelectNothing() {
        #expect(CommandBarSelection.selecting(results: [], keeping: "a") == CommandBarSelection(index: nil))
        #expect(CommandBarSelection.selecting(results: [], keeping: nil) == CommandBarSelection(index: nil))
        #expect(CommandBarSelection(index: 1).moved(by: 1, count: 0) == CommandBarSelection(index: nil))
    }

    @Test func arrowsStopAtTheEnds() {
        #expect(CommandBarSelection(index: 0).moved(by: -1, count: 3) == CommandBarSelection(index: 0))
        #expect(CommandBarSelection(index: 2).moved(by: 1, count: 3) == CommandBarSelection(index: 2))
        #expect(CommandBarSelection(index: 0).moved(by: 1, count: 3) == CommandBarSelection(index: 1))
        #expect(CommandBarSelection(index: 2).moved(by: -1, count: 3) == CommandBarSelection(index: 1))
        // A selection left past the end by a shorter list is brought back in.
        #expect(CommandBarSelection(index: 7).moved(by: 1, count: 3) == CommandBarSelection(index: 2))
    }

    @Test func fromNothingDownGoesToTheFirstAndUpToTheLast() {
        #expect(CommandBarSelection(index: nil).moved(by: 1, count: 5) == CommandBarSelection(index: 0))
        #expect(CommandBarSelection(index: nil).moved(by: -1, count: 5) == CommandBarSelection(index: 4))
    }
}
