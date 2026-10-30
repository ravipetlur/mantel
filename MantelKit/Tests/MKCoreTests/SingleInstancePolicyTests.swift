import Testing

@testable import MKCore

@Suite("SingleInstancePolicy", .timeLimit(.minutes(2)))
struct SingleInstancePolicyTests {
    @Test func handsOffToAnotherLiveCopy() {
        let running = [RunningInstance(pid: 10, isTerminated: false), RunningInstance(pid: 20, isTerminated: false)]
        #expect(SingleInstancePolicy.instanceToHandOffTo(running: running, currentPID: 20)?.pid == 10)
    }

    @Test func ignoresACopyThatHasAlreadyExited() {
        // `make run` kills the old copy just before launching; LaunchServices can still list it briefly.
        let running = [RunningInstance(pid: 10, isTerminated: true), RunningInstance(pid: 20, isTerminated: false)]
        #expect(SingleInstancePolicy.instanceToHandOffTo(running: running, currentPID: 20) == nil)
    }

    @Test func aloneMeansNoHandOff() {
        #expect(SingleInstancePolicy.instanceToHandOffTo(running: [RunningInstance(pid: 20, isTerminated: false)],
                                                         currentPID: 20) == nil)
    }

    @Test func nobodyListedMeansNoHandOff() {
        #expect(SingleInstancePolicy.instanceToHandOffTo(running: [], currentPID: 20) == nil)
    }

    // MARK: A copy started by the move to Applications

    @Test func aCopyStartedByTheMoveDoesNotHandOff() {
        // The copy that moved itself is still running when the new one starts; handing off to it would quit the new one
        // and leave nothing running once the old one quits.
        let environment = [SingleInstancePolicy.relaunchedFromMoveKey: "1"]
        #expect(SingleInstancePolicy.suppressesHandOff(environment: environment))
    }

    @Test func theKeyIsTheOneTheMoveSets() {
        #expect(SingleInstancePolicy.relaunchedFromMoveKey == "MANTEL_RELAUNCHED_FROM_MOVE")
    }

    @Test(arguments: [
        [:],
        ["PATH": "/usr/bin"],
        ["MANTEL_RELAUNCHED_FROM_MOVE": "0"],
        ["MANTEL_RELAUNCHED_FROM_MOVE": ""],
        ["MANTEL_RELAUNCHED_FROM_MOVE": "yes"],
    ] as [[String: String]])
    func anythingButOneLeavesHandOffOn(environment: [String: String]) {
        #expect(!SingleInstancePolicy.suppressesHandOff(environment: environment))
    }
}
