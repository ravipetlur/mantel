import CoreGraphics
import Testing

@testable import MKMenuBar

/// When the click-replay tap may be switched on. The tap grabs every click in the system while it is on, so the rule that it
/// is never on after it has been stopped is tested here, as a value, in the orders the tap's two threads can reach it in.
@Suite("Click replay lifecycle", .timeLimit(.minutes(1)))
struct ClickReplayLifecycleTests {
    private func started() -> ClickReplayLifecycle {
        var lifecycle = ClickReplayLifecycle()
        let began = lifecycle.begin()
        #expect(began)
        return lifecycle
    }

    @Test func aTapIsIdleUntilItIsStartedAndStartsOnce() {
        var lifecycle = ClickReplayLifecycle()
        #expect(lifecycle.phase == .idle)
        #expect(!lifecycle.mayEnableTap, "a tap that hasn't been started is not switched on")
        let first = lifecycle.begin()
        #expect(first)
        #expect(lifecycle.phase == .running)
        let second = lifecycle.begin()
        #expect(!second, "a second start does nothing")
    }

    @Test func aRunningTapMayBeSwitchedOn() {
        #expect(started().mayEnableTap)
    }

    @Test func aStopThatCameBeforeTheThreadSwitchedTheTapOnLeavesItOff() {
        // The race: `stop()` lands after the tap's thread has published its run loop and before it switches the tap on. The
        // thread's switch-on is a question put to the lifecycle under the lock, and the answer is no.
        var lifecycle = started()
        let stopped = lifecycle.stop()
        #expect(stopped)
        #expect(!lifecycle.mayEnableTap)
        #expect(lifecycle.phase == .stopped)
    }

    @Test func aStopThatCameAfterTheThreadSwitchedTheTapOnSwitchesItOff() {
        var lifecycle = started()
        #expect(lifecycle.mayEnableTap, "the thread switched it on, under the lock")
        let stopped = lifecycle.stop()
        #expect(stopped, "and the stop, which comes after, is the one that switches it off")
    }

    @Test func stoppingTwiceDoesItOnce() {
        var lifecycle = started()
        let first = lifecycle.stop()
        let second = lifecycle.stop()
        #expect(first)
        #expect(!second)
        #expect(lifecycle.phase == .stopped)
    }

    @Test func aStopBeforeAStartKeepsTheTapFromEverStarting() {
        var lifecycle = ClickReplayLifecycle()
        let stopped = lifecycle.stop()
        let began = lifecycle.begin()
        #expect(stopped)
        #expect(!began, "a stopped tap is stopped for good")
        #expect(!lifecycle.mayEnableTap)
    }

    @Test func aTapThatCouldNotBeMadeIsStopped() {
        var lifecycle = started()
        lifecycle.failed()
        #expect(lifecycle.phase == .stopped)
        #expect(!lifecycle.mayEnableTap)
    }

    // MARK: When the system switches it off

    @Test(arguments: [CGEventType.tapDisabledByTimeout, .tapDisabledByUserInput])
    func aTapTheSystemSwitchedOffIsSwitchedOnAgainWhileItRuns(type: CGEventType) {
        #expect(started().shouldReenable(after: type))
    }

    @Test(arguments: [CGEventType.tapDisabledByTimeout, .tapDisabledByUserInput])
    func aTapTheSystemSwitchedOffStaysOffOnceItIsStopped(type: CGEventType) {
        var lifecycle = started()
        _ = lifecycle.stop()
        #expect(!lifecycle.shouldReenable(after: type), "stop switched it off; a notice that was already on its way must not undo that")
        #expect(!ClickReplayLifecycle().shouldReenable(after: type), "nor one that was never started")
    }

    @Test(arguments: [CGEventType.leftMouseDown, .leftMouseUp, .leftMouseDragged, .null])
    func anEventThatIsNotASwitchOffIsNotAReason(type: CGEventType) {
        #expect(!started().shouldReenable(after: type))
    }

    // MARK: The thread's loop

    @Test func theThreadRunsItsLoopOnlyWhileTheTapRuns() {
        var lifecycle = ClickReplayLifecycle()
        #expect(!lifecycle.keepsRunLoopGoing)
        _ = lifecycle.begin()
        #expect(lifecycle.keepsRunLoopGoing)
        _ = lifecycle.stop()
        #expect(!lifecycle.keepsRunLoopGoing, "a stop that couldn't wake the loop is seen the next time it asks")
    }

    @Test func finishedRunLoopExits() {
        // A loop with nothing to wait for returns `.finished` at once, and would be run again at once for ever.
        let running = started()
        #expect(!running.keepsRunLoopGoing(after: .finished))
        #expect(!running.keepsRunLoopGoing(after: .stopped), "a stop that ended the slice ends the thread's loop")
        // The ordinary ends of a slice go on while the tap runs.
        #expect(running.keepsRunLoopGoing(after: .timedOut))
        #expect(running.keepsRunLoopGoing(after: .handledSource))
        // And nothing goes on once the tap is stopped.
        var stopped = started()
        _ = stopped.stop()
        #expect(!stopped.keepsRunLoopGoing(after: .timedOut))
        #expect(!stopped.keepsRunLoopGoing(after: .handledSource))
        // Before the first slice the result is the ordinary one.
        #expect(started().keepsRunLoopGoing(after: .timedOut))
    }

    @Test func theLoopIsRunInSlicesSoAStopIsSeenWithinOne() {
        #expect(TapThread.runLoopSlice == 0.25)
    }
}
