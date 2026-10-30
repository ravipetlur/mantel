import MKCommands
import MKCore
@testable import MKMenuBar
import Testing

@Suite("Command outcomes", .timeLimit(.minutes(2)))
struct CommandOutcomesTests {
    @Test func aClickThatAnotherTookOverSaysSoAndIsNotAnUnreachableIcon() {
        #expect(IconClickOutcome.overtaken.result(app: "Notes", kind: .left)
                == .failure(code: .failed, message: "Notes's icon wasn't clicked: another click came first."))
        #expect(IconClickOutcome.overtaken.result(app: "Notes", kind: .right) != IconClickOutcome.failed(.unreachable).result(app: "Notes", kind: .right))
    }

    @Test func layoutRestoreAnswersForWhatTheWriterDid() {
        func answer(_ result: Result<Int, LayoutWriteError>) -> CommandResult { result.restoreResult }
        #expect(answer(.success(3)) == .ok(.string("The menu bar order is back to how it was.")))
        #expect(answer(.success(0)) == .ok(.string("Nothing to put back: Mantel hasn't changed the order.")))
        #expect(answer(.failure(.needsGrant)) == .failure(code: .unavailable, message: "Grant access to the layout file in Settings › Layout first."))
        #expect(answer(.failure(.failed(LayoutWords.heldForTheSpacer)))
                == .failure(code: .failed, message: "Couldn't change the menu bar order: \(LayoutWords.heldForTheSpacer)"))
        #expect(answer(.failure(.failed("EPERM at /Users/someone/file")))
                == .failure(code: .failed, message: "Couldn't change the menu bar order: macOS didn't take the change."))
        #expect(answer(.failure(.notAccepted)) == .failure(code: .failed, message: "Couldn't change the menu bar order: macOS didn't accept the old order."))
        #expect(answer(.failure(.broken("It is somewhere else."))) == .failure(code: .failed, message: "Couldn't change the menu bar order: It is somewhere else."))
    }
}
