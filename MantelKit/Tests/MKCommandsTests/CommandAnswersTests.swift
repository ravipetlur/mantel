import MKCommands
import MKCore
import Testing

@Suite("Command answers")
struct CommandAnswersTests {
    @Test func showSaysWhatWasDone() {
        #expect(CommandAnswers.show(.hidden) == "Showing hidden icons.")
        #expect(CommandAnswers.show(.all) == "Showing all icons.")
        #expect(CommandAnswers.show(.nothing) == "Hiding icons again.")
    }

    @Test func focusSaysHowItIsNow() {
        #expect(CommandAnswers.focus(isOn: true) == "Focus Mode is on.")
        #expect(CommandAnswers.focus(isOn: false) == "Focus Mode is off.")
    }

    @Test func refreshAndStartingHaveTheirWords() {
        #expect(CommandAnswers.refreshed == "Menu bar refreshed.")
        #expect(CommandAnswers.stillStarting == "Mantel is still starting. Try again in a moment.")
    }

    @Test func resetSaysWhatCameOfIt() {
        #expect(CommandAnswers.reset == "Menu bar reset.")
        #expect(CommandAnswers.resetUnderWay == "A reset is already under way.")
        #expect(ResetOutcome.done.result == .ok(.string("Menu bar reset.")))
        #expect(ResetOutcome.alreadyUnderWay.result == .failure(code: .unavailable, message: "A reset is already under way."))
        let words = "macOS's menu bar didn't restart. Log out and back in to restart it."
        #expect(ResetOutcome.failed(words).result == .failure(code: .failed, message: words))
        #expect(ResetOutcome.done.message == "Menu bar reset.")
        #expect(ResetOutcome.alreadyUnderWay.message == "A reset is already under way.")
        #expect(ResetOutcome.failed(words).message == words)
    }

    @Test func aResetThatWasNotStartedIsRefusedNotFailed() {
        // Nothing was changed: it is unavailable now, the way a second reset is, and the sentence is what the person is told.
        let words = ReplayNowPolicy.probeChangingMenuBarText
        #expect(ResetOutcome.refused(words).result == .failure(code: .unavailable, message: words))
        #expect(ResetOutcome.refused(words).message == words)
        #expect(ResetOutcome.refused(CommandAnswers.quitting).result == .failure(code: .unavailable, message: "Mantel is quitting."))
        #expect(CommandAnswers.quitting == "Mantel is quitting.")
    }

    @Test func aRefreshSaysItWasDoneOrWhyItWasNot() {
        #expect(RefreshOutcome.done.result == .ok(.string("Menu bar refreshed.")))
        #expect(RefreshOutcome.done.message == "Menu bar refreshed.")
        // Asked during a reset, it didn't refresh anything, and it doesn't say it did.
        let refused = RefreshOutcome.refused(CommandAnswers.resetUnderWay)
        #expect(refused.result == .failure(code: .unavailable, message: "A reset is already under way."))
        #expect(refused.message == "A reset is already under way.")
    }

    @Test func everyAnswerIsASentence() {
        let answers = ShowTarget.allCases.map(CommandAnswers.show) + [CommandAnswers.focus(isOn: true), CommandAnswers.focus(isOn: false),
                                                                      CommandAnswers.refreshed, CommandAnswers.stillStarting,
                                                                      CommandAnswers.reset, CommandAnswers.resetUnderWay, CommandAnswers.quitting]
        for answer in answers {
            #expect(answer.hasSuffix("."), "\(answer)")
            #expect(answer.first?.isUppercase == true, "\(answer)")
        }
    }
}
