import MKCommands
import MKCore
@testable import MKMenuBar
import Testing

@Suite("Command outcomes")
struct CommandOutcomesTests {
    @Test func aClickThatWasSentSaysSo() {
        for route in [IconClickRoute.pressedDrawn, .postedDrawn, .pressedInPlace, .shownMenu, .madeRoomThenPressed, .madeRoomThenPosted] {
            #expect(IconClickOutcome.clicked(route).result(app: "Notes", kind: .left) == .ok(.string("Clicked Notes.")))
        }
        #expect(IconClickOutcome.clicked(.pressedDrawn).result(app: "Notes", kind: .option) == .ok(.string("Clicked Notes as a left click.")))
    }

    @Test func eachFailureHasItsOwnSentence() {
        func failed(_ failure: IconClickFailure, kind: ClickKind = .left) -> CommandResult {
            IconClickOutcome.failed(failure).result(app: "Notes", kind: kind)
        }
        #expect(failed(.noRoom) == .failure(code: .failed, message: "There's no room on the menu bar to click Notes."))
        #expect(failed(.hiddenBar, kind: .right)
                == .failure(code: .failed, message: "The menu bar is hidden by a full-screen app, so Notes can't be right-clicked."))
        #expect(failed(.hiddenBar, kind: .option)
                == .failure(code: .failed, message: "The menu bar is hidden by a full-screen app, so Notes can't be option-clicked."))
        #expect(failed(.refused("it was busy")) == .failure(code: .failed, message: "Notes didn't respond to the click: it was busy"))
        #expect(failed(.notRunning) == .failure(code: .failed, message: "Notes isn't running."))
        #expect(failed(.unreachable) == .failure(code: .failed, message: "Mantel couldn't reach Notes's icon."))
    }

    @Test func aClickThatAnotherTookOverSaysSoAndIsNotAnUnreachableIcon() {
        #expect(IconClickOutcome.overtaken.result(app: "Notes", kind: .left)
                == .failure(code: .failed, message: "Notes's icon wasn't clicked: another click came first."))
        #expect(IconClickOutcome.overtaken.result(app: "Notes", kind: .right) != IconClickOutcome.failed(.unreachable).result(app: "Notes", kind: .right))
    }

    @Test func theCollectorsWordsForScreenRecordingOffAreTheOnesTheAnswerLooksFor() {
        // The answer to a Recapture that took nothing because Screen Recording is off goes by what the collector says.
        #expect(ItemImageCollector.SkipReason.screenRecordingOff.text.hasPrefix(CommandAnswers.screenRecordingOffReason))
    }

    @Test func layoutRestoreAnswersForWhatTheWriterDid() {
        func answer(_ result: Result<Int, LayoutWriteError>) -> CommandResult { result.restoreResult }
        #expect(answer(.success(3)) == .ok(.string("The menu bar order is back to how it was.")))
        #expect(answer(.success(0)) == .ok(.string("Nothing to put back: Mantel hasn't changed the order.")))
        #expect(answer(.failure(.needsGrant)) == .failure(code: .unavailable, message: "Grant access to the layout file in Settings › Layout first."))
        #expect(answer(.failure(.failed(LayoutWords.heldForAProbe)))
                == .failure(code: .failed, message: "Couldn't change the menu bar order: \(LayoutWords.heldForAProbe)"))
        #expect(answer(.failure(.failed("EPERM at /Users/someone/file")))
                == .failure(code: .failed, message: "Couldn't change the menu bar order: macOS didn't take the change."))
        #expect(answer(.failure(.notAccepted)) == .failure(code: .failed, message: "Couldn't change the menu bar order: macOS didn't accept the old order."))
        #expect(answer(.failure(.broken("It is somewhere else."))) == .failure(code: .failed, message: "Couldn't change the menu bar order: It is somewhere else."))
    }
}
