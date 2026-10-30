import Foundation
import MKTestSupport
import Testing

@testable import MKCore

/// Whether the menu bar the person sees is the one Mantel reads, as plain values.
@Suite("Session state", .timeLimit(.minutes(1)))
struct SessionStateTests {
    private struct Combination: Sendable, CustomTestStringConvertible {
        let displaysAsleep: Bool
        let screenLocked: Bool
        let sessionActive: Bool

        var state: SessionState { SessionState(displaysAsleep: displaysAsleep, screenLocked: screenLocked, sessionActive: sessionActive) }
        var testDescription: String {
            "asleep \(displaysAsleep), locked \(screenLocked), active \(sessionActive)"
        }
    }

    private static let combinations: [Combination] = [false, true].flatMap { asleep in
        [false, true].flatMap { locked in
            [false, true].map { Combination(displaysAsleep: asleep, screenLocked: locked, sessionActive: $0) }
        }
    }

    @Test(arguments: combinations)
    private func isAwakeOnlyWhenAwakeUnlockedAndActive(_ combination: Combination) {
        let awake = !combination.displaysAsleep && !combination.screenLocked && combination.sessionActive
        #expect(combination.state.isAwake == awake)
        #expect((combination.state.pauseReason == nil) == awake, "a reason is given exactly when it isn't")
    }

    @Test func theSteadyStateIsTheAwakeOne() {
        #expect(SessionState.awake == SessionState(displaysAsleep: false, screenLocked: false, sessionActive: true))
        #expect(SessionState.awake == SessionState())
        #expect(SessionState.awake.isAwake)
        #expect(SessionState.awake.pauseReason == nil)
    }

    @Test func applyingEachChange() {
        let awake = SessionState.awake
        #expect(awake.applying(.displaysAsleep(true)) == SessionState(displaysAsleep: true))
        #expect(awake.applying(.screenLocked(true)) == SessionState(screenLocked: true))
        #expect(awake.applying(.sessionActive(false)) == SessionState(sessionActive: false))

        // Each one undoes itself, and touches nothing else.
        let everything = SessionState(displaysAsleep: true, screenLocked: true, sessionActive: false)
        #expect(everything.applying(.displaysAsleep(false)) == SessionState(screenLocked: true, sessionActive: false))
        #expect(everything.applying(.screenLocked(false)) == SessionState(displaysAsleep: true, sessionActive: false))
        #expect(everything.applying(.sessionActive(true)) == SessionState(displaysAsleep: true, screenLocked: true))
        #expect(everything.applying(.displaysAsleep(false)).applying(.screenLocked(false)).applying(.sessionActive(true)) == .awake)

        // The same change again changes nothing.
        #expect(awake.applying(.screenLocked(true)).applying(.screenLocked(true)) == SessionState(screenLocked: true))
        #expect(awake.applying(.displaysAsleep(false)) == awake)
    }

    @Test func aWakeOfTheSystemIsAnEventNotAState() {
        #expect(SessionState.awake.applying(.systemWoke) == .awake)
        let asleep = SessionState(displaysAsleep: true, screenLocked: true, sessionActive: false)
        #expect(asleep.applying(.systemWoke) == asleep, "the displays' own notifications say whether they are on")
    }

    @Test func pauseReasonOrder() {
        // The first that applies: the displays, then the lock, then the session.
        #expect(SessionState(displaysAsleep: true, screenLocked: true, sessionActive: false).pauseReason == "the displays are asleep")
        #expect(SessionState(displaysAsleep: true, screenLocked: false, sessionActive: true).pauseReason == "the displays are asleep")
        #expect(SessionState(displaysAsleep: true, screenLocked: false, sessionActive: false).pauseReason == "the displays are asleep")
        #expect(SessionState(displaysAsleep: false, screenLocked: true, sessionActive: false).pauseReason == "the screen is locked")
        #expect(SessionState(displaysAsleep: false, screenLocked: true, sessionActive: true).pauseReason == "the screen is locked")
        #expect(SessionState(displaysAsleep: false, screenLocked: false, sessionActive: false).pauseReason
            == "another user's session is on screen")
        #expect(SessionState.awake.pauseReason == nil)
    }

    @Test func theSteadySourceIsAlwaysAwakeAndItsChangesEndAtOnce() async {
        let source = SteadySessionState()
        #expect(source.current() == .awake)
        var seen = 0
        for await _ in source.changes() { seen += 1 }
        #expect(seen == 0, "the stream finished without a change, or this would not have come back")
        #expect(source.current() == .awake)
    }

    @Test func theFakeSourceFollowsWhatItIsToldAndTellsOpenStreams() async {
        let source = FakeSessionState(SessionState(screenLocked: true))
        #expect(source.current() == SessionState(screenLocked: true))
        let stream = source.changes()
        #expect(source.openStreams == 1)

        source.send(.screenLocked(false))
        source.send(.displaysAsleep(true))
        source.finish()
        #expect(source.openStreams == 0)

        var seen: [SessionChange] = []
        for await change in stream { seen.append(change) }
        #expect(seen == [.screenLocked(false), .displaysAsleep(true)])
        #expect(source.current() == SessionState(displaysAsleep: true))
    }
}
