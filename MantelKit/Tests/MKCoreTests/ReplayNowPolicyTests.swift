import Testing

@testable import MKCore

@Suite("Replay now policy")
struct ReplayNowPolicyTests {
    @Test func anEmptyJournalHasNothingToPutBack() {
        #expect(ReplayNowPolicy.decide(journalEmpty: true, probeChangingMenuBar: false, engineHoldsJournal: false)
            == .refused("Nothing is waiting to be put back."))
    }

    @Test func aPlatformTestThatIsChangingTheMenuBarIsLeftToFinish() {
        #expect(ReplayNowPolicy.decide(journalEmpty: false, probeChangingMenuBar: true, engineHoldsJournal: false)
            == .refused("A platform test is changing the menu bar. Try again when it finishes."))
    }

    @Test func theHidingMethodThatIsUsingTheChangesIsLeftAlone() {
        #expect(ReplayNowPolicy.decide(journalEmpty: false, probeChangingMenuBar: false, engineHoldsJournal: true)
            == .refused("The hiding method is using these changes. Use Reset menu bar to undo them."))
    }

    @Test func otherwiseItIsAllowed() {
        #expect(ReplayNowPolicy.decide(journalEmpty: false, probeChangingMenuBar: false, engineHoldsJournal: false) == .allowed)
    }

    @Test func whenSeveralApplyTheFirstOfEmptyProbeEngineIsTheReason() {
        #expect(ReplayNowPolicy.decide(journalEmpty: true, probeChangingMenuBar: true, engineHoldsJournal: true)
            == .refused("Nothing is waiting to be put back."))
        #expect(ReplayNowPolicy.decide(journalEmpty: false, probeChangingMenuBar: true, engineHoldsJournal: true)
            == .refused("A platform test is changing the menu bar. Try again when it finishes."))
    }

    @Test func aResetIsRefusedWhileAPlatformTestChangesTheMenuBarInTheSameWords() {
        // Its replay would put back the test's records in the middle of a measurement, and restarting the menu bar would restart what the
        // test is reading: the words are the replay's.
        #expect(ReplayNowPolicy.resetRefusal(probeChangingMenuBar: true)
            == "A platform test is changing the menu bar. Try again when it finishes.")
        #expect(ReplayNowPolicy.resetRefusal(probeChangingMenuBar: true) == ReplayNowPolicy.probeChangingMenuBarText)
        #expect(ReplayNowPolicy.resetRefusal(probeChangingMenuBar: false) == nil)
        #expect(ReplayNowPolicy.decide(journalEmpty: false, probeChangingMenuBar: true, engineHoldsJournal: false)
            == .refused(ReplayNowPolicy.probeChangingMenuBarText), "one sentence, not two copies")
    }
}
