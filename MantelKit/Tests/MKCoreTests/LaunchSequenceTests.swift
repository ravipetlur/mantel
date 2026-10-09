import Testing

@testable import MKCore

@Suite("LaunchSequence")
struct LaunchSequenceTests {
    @Test func foldersAndTheLogComeBeforeTheSocket() {
        #expect(LaunchSequence.beforeSocket == [.createFolders, .configureLog])
    }

    @Test func afterTheSocketComesTheRestInOrder() {
        #expect(LaunchSequence.steps(after: .listening) == [
            .replayJournal, .loadSettings, .registerHotkeys, .createStatusItem, .observeDisplays, .openOnboardingIfNeeded,
        ])
    }

    @Test func aSocketThatCouldNotStartForAnotherReasonStillLaunches() {
        // Mantel works without the socket: only `mantel` can't reach it.
        #expect(LaunchSequence.steps(after: .notStarted) == LaunchSequence.steps(after: .listening))
    }

    @Test func aSocketHeldByAnotherMantelStopsTheLaunchBeforeAnythingElse() {
        // The lock on the socket is the single-instance lock. A copy that doesn't hold it must not replay the journal,
        // which would undo what the running copy has journaled for a change it is in the middle of.
        #expect(LaunchSequence.steps(after: .heldByAnotherMantel).isEmpty)
        #expect(!LaunchSequence.steps(after: .heldByAnotherMantel).contains(.replayJournal))
    }

    @Test func theJournalIsReplayedBeforeAnythingThatCouldRecordIntoIt() {
        let steps = LaunchSequence.steps(after: .listening)
        #expect(steps.first == .replayJournal)
    }

    @Test func settingsAreLoadedBeforeTheStatusItemAndOnboardingCanSaveThem() throws {
        let steps = LaunchSequence.steps(after: .listening)
        let load = try #require(steps.firstIndex(of: .loadSettings))
        let statusItem = try #require(steps.firstIndex(of: .createStatusItem))
        let onboarding = try #require(steps.firstIndex(of: .openOnboardingIfNeeded))
        #expect(load < statusItem)
        #expect(load < onboarding)
    }

    @Test func hotkeysAreRegisteredFromTheSettingsThatHaveBeenLoaded() throws {
        // The bindings are in a settings file, and a hotkey registered from the defaults would be one the person had
        // unassigned (or never reached by the one they chose).
        let steps = LaunchSequence.steps(after: .listening)
        let load = try #require(steps.firstIndex(of: .loadSettings))
        let register = try #require(steps.firstIndex(of: .registerHotkeys))
        #expect(load < register)
    }

    @Test func everyStepIsInExactlyOneList() {
        let all = LaunchSequence.beforeSocket + LaunchSequence.steps(after: .listening)
        #expect(Set(all).count == all.count)
        #expect(Set(all) == Set(LaunchStep.allCases))
    }
}
