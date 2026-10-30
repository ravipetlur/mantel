import Testing

@testable import MKCore

@Suite("HandOff", .timeLimit(.minutes(2)))
struct HandOffDecisionTests {
    private let alive = RunningInstance(pid: 10, isTerminated: false)
    private let exited = RunningInstance(pid: 10, isTerminated: true)

    private func facts(socketAnswered: Bool = false, target: RunningInstance? = nil, reopenedPID: Int32? = nil,
                       lockStillHeld: Bool? = nil) -> HandOffFacts {
        HandOffFacts(socketAnswered: socketAnswered, target: target, reopenedPID: reopenedPID,
                     socketLockStillHeld: lockStillHeld)
    }

    // MARK: Reached over the socket

    @Test func anAnswerOverTheSocketIsEnoughToQuit() {
        #expect(HandOff.decide(facts(socketAnswered: true, target: alive)) == .quit)
        // Even when LaunchServices didn't list the copy that answered.
        #expect(HandOff.decide(facts(socketAnswered: true)) == .quit)
    }

    // MARK: Reached by opening it again

    @Test func reopeningTheRunningCopyIsEnoughToQuit() {
        #expect(HandOff.decide(facts(target: alive, reopenedPID: 10)) == .quit)
    }

    @Test func aTargetThatHasExitedIsNotReached() {
        // It quit while the hand-off waited on its socket; opening its bundle again reached nobody it was meant for.
        #expect(HandOff.decide(facts(target: exited, reopenedPID: 10)) == .start)
        #expect(HandOff.decide(facts(target: exited)) == .start)
    }

    @Test func aReopenThatReachedAnotherProcessIsNotReached() {
        // The bundle was opened again but another process answered: this copy itself, or a fresh copy it started.
        #expect(HandOff.decide(facts(target: alive, reopenedPID: 99)) == .start)
    }

    @Test func aReopenThatWasNotMadeOrFailedIsNotReached() {
        #expect(HandOff.decide(facts(target: alive, reopenedPID: nil)) == .start)
    }

    @Test func aReopenWithNobodyToReopenIsNotReached() {
        #expect(HandOff.decide(facts(target: nil, reopenedPID: 10)) == .start)
    }

    @Test func nothingReachedMeansStart() {
        #expect(HandOff.decide(facts()) == .start)
        #expect(HandOff.decide(facts(target: alive)) == .start)
    }

    // MARK: Found by the socket's lock

    @Test func aLockStillHeldMeansALiveMantelWhetherOrNotTheHandOffGotThrough() {
        #expect(HandOff.decide(facts(lockStillHeld: true)) == .quit)
        #expect(HandOff.decide(facts(target: exited, lockStillHeld: true)) == .quit)
        #expect(HandOff.decide(facts(socketAnswered: true, lockStillHeld: true)) == .quit)
    }

    @Test func aLockThatIsFreeNowMeansThereIsNobodyLeftToHandOffTo() {
        // The holder quit while the hand-off ran. This copy took the lock, so it stays, whatever was answered before.
        #expect(HandOff.decide(facts(lockStillHeld: false)) == .start)
        #expect(HandOff.decide(facts(socketAnswered: true, lockStillHeld: false)) == .start)
        #expect(HandOff.decide(facts(target: alive, reopenedPID: 10, lockStillHeld: false)) == .start)
    }
}
