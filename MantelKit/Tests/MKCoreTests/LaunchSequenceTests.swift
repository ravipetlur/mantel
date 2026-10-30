import Testing

@testable import MKCore

@Suite("LaunchSequence", .timeLimit(.minutes(2)))
struct LaunchSequenceTests {
    @Test func theFoldersComeBeforeTheSocket() {
        #expect(LaunchSequence.beforeSocket == [.createFolders])
    }

    @Test func afterTheSocketComesTheRestInOrder() {
        #expect(LaunchSequence.steps(after: .listening) == [
            .configureLog, .replayJournal, .loadSettings, .registerHotkeys, .createStatusItem, .observeDisplays, .startMenuBar,
            .openOnboardingIfNeeded,
        ])
    }

    @Test func theLogIsPointedAtItsFileOnlyByACopyThatHoldsTheSocket() {
        // A second copy leaves the running copy's log alone: its lines go to the unified log, and `mantel.log` stays as it was.
        #expect(!LaunchSequence.beforeSocket.contains(.configureLog))
        #expect(!LaunchSequence.steps(after: .heldByAnotherMantel).contains(.configureLog))
        #expect(LaunchSequence.steps(after: .listening).first == .configureLog)
        #expect(LaunchSequence.steps(after: .notStarted).first == .configureLog)
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

    @Test func theJournalIsReplayedBeforeAnythingThatCouldRecordIntoIt() throws {
        let steps = LaunchSequence.steps(after: .listening)
        let log = try #require(steps.firstIndex(of: .configureLog))
        let replay = try #require(steps.firstIndex(of: .replayJournal))
        #expect(log < replay, "what the replay says is kept")
        #expect(replay == steps.index(after: log))
        #expect(steps.dropFirst(replay + 1).allSatisfy { $0 != .replayJournal })
        // Everything that could record into the journal comes after it.
        for later in [LaunchStep.loadSettings, .registerHotkeys, .createStatusItem, .observeDisplays, .startMenuBar, .openOnboardingIfNeeded] {
            let index = try #require(steps.firstIndex(of: later))
            #expect(index > replay)
        }
    }

    @Test func settingsAreLoadedBeforeTheStatusItemAndOnboardingCanSaveThem() throws {
        let steps = LaunchSequence.steps(after: .listening)
        let load = try #require(steps.firstIndex(of: .loadSettings))
        let statusItem = try #require(steps.firstIndex(of: .createStatusItem))
        let onboarding = try #require(steps.firstIndex(of: .openOnboardingIfNeeded))
        #expect(load < statusItem)
        #expect(load < onboarding)
    }

    @Test func startMenuBarComesAfterObserveDisplays() throws {
        // The session hides by the sections and the displays' bars, so the displays are watched first; and it starts only once the
        // journal's replay and the settings are behind it.
        let steps = LaunchSequence.steps(after: .listening)
        let displays = try #require(steps.firstIndex(of: .observeDisplays))
        let menuBar = try #require(steps.firstIndex(of: .startMenuBar))
        #expect(menuBar == steps.index(after: displays))
        let replay = try #require(steps.firstIndex(of: .replayJournal))
        let load = try #require(steps.firstIndex(of: .loadSettings))
        let statusItem = try #require(steps.firstIndex(of: .createStatusItem))
        #expect(replay < menuBar && load < menuBar && statusItem < menuBar)
        // Onboarding opens with the menu bar already hiding what the person put away, not the other way round.
        let onboarding = try #require(steps.firstIndex(of: .openOnboardingIfNeeded))
        #expect(menuBar < onboarding)
        // A copy that hands off never starts it.
        #expect(!LaunchSequence.steps(after: .heldByAnotherMantel).contains(.startMenuBar))
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

    @Test func opensSettingsForHiddenDots() {
        var hidden = DotSettings()
        hidden.hideBothDots = true
        let shown = DotSettings()

        // Both dots are off the bar, and the person has been through onboarding: Settings opens, so that Mantel can be found again.
        #expect(LaunchSequence.opensSettingsForHiddenDots(onboardingCompleted: true, dots: hidden))
        // A dot is on the bar, so it is there to be clicked.
        #expect(!LaunchSequence.opensSettingsForHiddenDots(onboardingCompleted: true, dots: shown))
        // Onboarding has its own window, which comes first.
        #expect(!LaunchSequence.opensSettingsForHiddenDots(onboardingCompleted: false, dots: hidden))
        #expect(!LaunchSequence.opensSettingsForHiddenDots(onboardingCompleted: false, dots: shown))

        // Only hiding both dots counts: a style, •• visibility or the divider is no reason.
        var styled = DotSettings()
        styled.style = .chevrons
        styled.alwaysDot = .always
        styled.showsDivider = true
        #expect(!LaunchSequence.opensSettingsForHiddenDots(onboardingCompleted: true, dots: styled))
    }
}
