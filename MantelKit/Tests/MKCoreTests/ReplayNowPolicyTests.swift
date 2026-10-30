import Foundation
import MKTestSupport
import Testing

@testable import MKCore

@Suite("Replay now policy", .timeLimit(.minutes(2)))
struct ReplayNowPolicyTests {
    /// Held by the suite, and so for the whole test.
    let folder = TemporaryFolder(prefix: "mantel-replay-now")

    @Test func anEmptyJournalHasNothingToPutBack() {
        #expect(ReplayNowPolicy.decide(journalEmpty: true, engineHoldsJournal: false)
            == .refused("Nothing is waiting to be put back."))
    }

    @Test func theHidingMethodThatIsUsingTheChangesIsLeftAlone() {
        #expect(ReplayNowPolicy.decide(journalEmpty: false, engineHoldsJournal: true)
            == .refused("The hiding method is using these changes. Use Reset menu bar to undo them."))
    }

    @Test func otherwiseItIsAllowed() {
        #expect(ReplayNowPolicy.decide(journalEmpty: false, engineHoldsJournal: false) == .allowed)
    }

    @Test func whenBothApplyTheEmptyJournalIsTheReason() {
        #expect(ReplayNowPolicy.decide(journalEmpty: true, engineHoldsJournal: true)
            == .refused("Nothing is waiting to be put back."))
    }

    @Test func journalWithOnlyKeptRecordsIsEmpty() async throws {
        // What Mantel keeps (its own arrangement) isn't waiting to be put back: "Replay now" doesn't touch it, so it has nothing to do.
        let journal = Journal(file: folder.url.appending(path: "journal.json"))
        let kept = JournalEntry.plistPath(filePath: "/Users/example/p.plist", key: "Positions", path: [.key("a")], original: .integer(1),
                                          strategy: .cfPreferences, codec: .none)
        try await journal.record(kept, lifetime: .kept)

        let journalEmpty = await journal.untilQuitRecords().isEmpty
        #expect(journalEmpty)
        #expect(ReplayNowPolicy.decide(journalEmpty: journalEmpty, engineHoldsJournal: false)
            == .refused("Nothing is waiting to be put back."))

        // A temporary change next to it is what Replay now is for.
        try await journal.record(.plistKey(filePath: "/Users/example/p.plist", key: "Other", original: nil, strategy: .cfPreferences))
        let notEmpty = await journal.untilQuitRecords().isEmpty
        #expect(!notEmpty)
        #expect(ReplayNowPolicy.decide(journalEmpty: notEmpty, engineHoldsJournal: false) == .allowed)
    }
}
