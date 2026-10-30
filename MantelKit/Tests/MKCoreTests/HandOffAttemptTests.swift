import Synchronization
import Testing

@testable import MKCore

/// The hand-off from start to decision, with the outside world (the socket, LaunchServices, the process list) played by
/// fakes, so that the facts the app would hand to `HandOff.decide` are the facts under test.
@Suite("HandOff attempt", .timeLimit(.minutes(1)))
struct HandOffAttemptTests {
    private let alive = RunningInstance(pid: 10, isTerminated: false)
    private let exited = RunningInstance(pid: 10, isTerminated: true)

    /// What the fake world was asked, and what it answers.
    private final class World: Sendable {
        private struct State {
            var replies: [HandOffSocketReply]
            var observations: [RunningInstance?]
            var sends = 0
            var observes = 0
            var reopens = 0
            var pauses: [Duration] = []
        }

        private let state: Mutex<State>
        private let reopenPID: Int32?

        /// `replies` are given in turn (the last one repeats); so are `observations` of the target.
        init(replies: [HandOffSocketReply], observations: [RunningInstance?], reopenPID: Int32?) {
            state = Mutex(State(replies: replies, observations: observations))
            self.reopenPID = reopenPID
        }

        var sends: Int { state.withLock { $0.sends } }
        var reopens: Int { state.withLock { $0.reopens } }
        var pauses: [Duration] { state.withLock { $0.pauses } }

        var ports: HandOffPorts {
            HandOffPorts(
                sendOpenSettings: { [self] in
                    state.withLock {
                        defer { $0.sends += 1 }
                        return $0.replies[min($0.sends, $0.replies.count - 1)]
                    }
                },
                observeTarget: { [self] in
                    state.withLock {
                        defer { $0.observes += 1 }
                        return $0.observations[min($0.observes, $0.observations.count - 1)]
                    }
                },
                reopenTarget: { [self] in
                    state.withLock { $0.reopens += 1 }
                    return reopenPID
                },
                pause: { [self] duration in state.withLock { $0.pauses.append(duration) } })
        }
    }

    private func attempt(_ world: World, attempts: Int = 3) async -> HandOffFacts {
        await HandOff.attempt(world.ports, attempts: attempts, pause: .milliseconds(250))
    }

    // MARK: Reached over the socket

    @Test func anAnswerOverTheSocketQuitsWithoutOpeningAnythingAgain() async {
        let world = World(replies: [.answered], observations: [alive], reopenPID: 10)
        let facts = await attempt(world)
        #expect(facts.socketAnswered)
        #expect(facts.target == alive)
        #expect(HandOff.decide(facts) == .quit)
        #expect(world.sends == 1)
        #expect(world.reopens == 0)
    }

    @Test func aMantelThatIsStillStartingIsWaitedFor() async {
        let world = World(replies: [.notRunning, .notRunning, .answered], observations: [alive], reopenPID: nil)
        let facts = await attempt(world)
        #expect(HandOff.decide(facts) == .quit)
        #expect(world.sends == 3)
        #expect(world.pauses == [.milliseconds(250), .milliseconds(250)])
        #expect(world.reopens == 0)
    }

    // MARK: Reached by opening it again

    @Test func aConfirmedReopenOfALiveTargetQuitsEndToEnd() async {
        // The refusal the socket gives every Mantel that isn't the command-line tool.
        let world = World(replies: [.refused], observations: [alive], reopenPID: 10)
        let facts = await attempt(world)
        #expect(facts.target == alive)
        #expect(facts.reopenedPID == 10)
        #expect(!facts.socketAnswered)
        #expect(HandOff.decide(facts) == .quit)
        #expect(world.sends == 1)
        #expect(world.reopens == 1)
    }

    @Test func aSocketNobodyListensOnIsTriedForTheWholeWaitBeforeOpeningTheBundleAgain() async {
        let world = World(replies: [.notRunning], observations: [alive], reopenPID: 10)
        let facts = await attempt(world, attempts: 4)
        #expect(world.sends == 4)
        #expect(world.pauses.count == 3)
        #expect(world.reopens == 1)
        #expect(HandOff.decide(facts) == .quit)
    }

    @Test(arguments: [HandOffSocketReply.refused, .failed])
    func aRefusalOrAFailureIsNotRetried(reply: HandOffSocketReply) async {
        let world = World(replies: [reply], observations: [alive], reopenPID: 10)
        _ = await attempt(world)
        #expect(world.sends == 1)
        #expect(world.pauses.isEmpty)
    }

    // MARK: Not reached

    /// A hand-off that doesn't reach the target is decided as a start, and each says what it did and what it saw on the way.
    enum NotReached: CaseIterable, CustomTestStringConvertible {
        /// Opening its bundle would reopen this copy, or start a new one.
        case aTargetThatExitedWhileTheSocketWasTried
        /// Alive when asked to be reopened, gone when looked at again: the facts hold the last look.
        case aTargetThatExitedAfterBeingOpenedAgain
        case aReopenThatReachedAnotherProcess
        case aReopenThatFailed
        case noKnownTargetMeansNothingToOpenAgain

        var testDescription: String { String(describing: self) }
    }

    @Test(arguments: NotReached.allCases)
    func aTargetThatIsNotReachedIsStarted(_ notReached: NotReached) async {
        let world: World
        switch notReached {
        case .aTargetThatExitedWhileTheSocketWasTried: world = World(replies: [.notRunning], observations: [exited], reopenPID: 10)
        case .aTargetThatExitedAfterBeingOpenedAgain: world = World(replies: [.refused], observations: [alive, exited], reopenPID: 10)
        case .aReopenThatReachedAnotherProcess: world = World(replies: [.refused], observations: [alive], reopenPID: 99)
        case .aReopenThatFailed: world = World(replies: [.refused], observations: [alive], reopenPID: nil)
        case .noKnownTargetMeansNothingToOpenAgain: world = World(replies: [.refused], observations: [nil], reopenPID: 10)
        }
        let facts = await attempt(world)
        switch notReached {
        case .aTargetThatExitedWhileTheSocketWasTried:
            #expect(world.reopens == 0)
            #expect(facts.target == exited)
        case .aTargetThatExitedAfterBeingOpenedAgain:
            #expect(world.reopens == 1)
            #expect(facts.target == exited)
        case .aReopenThatReachedAnotherProcess:
            #expect(facts.reopenedPID == 99)
        case .aReopenThatFailed:
            #expect(world.reopens == 1)
            #expect(facts.reopenedPID == nil)
        case .noKnownTargetMeansNothingToOpenAgain:
            #expect(world.reopens == 0)
            #expect(facts.target == nil)
        }
        #expect(HandOff.decide(facts) == .start)
    }
}
