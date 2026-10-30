import Foundation
import MKTestSupport
import Testing

@testable import MKCore

@Suite("Replay now policy")
struct ReplayNowPolicyTests {
    /// Held by the suite, and so for the whole test.
    let folder = TemporaryFolder(prefix: "mantel-replay-now")

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

    @Test func journalWithOnlyKeptRecordsIsEmpty() async throws {
        // What Mantel keeps (its own arrangement) isn't waiting to be put back: "Replay now" doesn't touch it, so it has nothing to do.
        let journal = Journal(file: folder.url.appending(path: "journal.json"))
        let kept = JournalEntry.plistPath(filePath: "/Users/example/p.plist", key: "Positions", path: [.key("a")], original: .integer(1),
                                          strategy: .cfPreferences, codec: .none)
        try await journal.record(kept, lifetime: .kept)

        let journalEmpty = await journal.untilQuitRecords().isEmpty
        #expect(journalEmpty)
        #expect(ReplayNowPolicy.decide(journalEmpty: journalEmpty, probeChangingMenuBar: false, engineHoldsJournal: false)
            == .refused("Nothing is waiting to be put back."))

        // A temporary change next to it is what Replay now is for.
        try await journal.record(.plistKey(filePath: "/Users/example/p.plist", key: "Other", original: nil, strategy: .cfPreferences))
        let notEmpty = await journal.untilQuitRecords().isEmpty
        #expect(!notEmpty)
        #expect(ReplayNowPolicy.decide(journalEmpty: notEmpty, probeChangingMenuBar: false, engineHoldsJournal: false) == .allowed)
    }
}
