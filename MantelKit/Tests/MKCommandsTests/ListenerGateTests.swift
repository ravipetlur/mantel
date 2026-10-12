import Darwin
import Dispatch
import Foundation
import Synchronization
import Testing

@testable import MKCommands

/// The gate that rests the listening source when the process is out of descriptors. A source that is resumed while it isn't
/// suspended brings the process down (libdispatch calls that a bug of the client), and one that is left suspended never finishes
/// being cancelled.
@Suite("Listener gate", .timeLimit(.minutes(1)))
struct ListenerGateTests {
    /// A source on a pipe's read end, running, with a signal for when it has been cancelled.
    private func makeSource(queue: DispatchQueue) -> (source: any DispatchSourceRead, cancelled: DispatchSemaphore) {
        var descriptors: [Int32] = [0, 0]
        precondition(pipe(&descriptors) == 0)
        let (reader, writer) = (descriptors[0], descriptors[1])
        let source = DispatchSource.makeReadSource(fileDescriptor: reader, queue: queue)
        let cancelled = DispatchSemaphore(value: 0)
        source.setEventHandler {}
        source.setCancelHandler {
            close(reader)
            close(writer)
            cancelled.signal()
        }
        source.resume()
        return (source, cancelled)
    }

    @Test func shutDownDuringAPauseResumesOnlyAfterTheSuspend() {
        // The suspend is held (a semaphore, not a sleep) until the test lets it go, with a shutdown asked for meanwhile: the shutdown
        // must wait for the suspend, and so resume only a source that is suspended.
        let events = Mutex<[String]>([])
        let inSuspend = DispatchSemaphore(value: 0)
        let letSuspendGo = DispatchSemaphore(value: 0)
        let gate = ListenerGate(
            suspend: {
                inSuspend.signal()
                _ = letSuspendGo.wait(timeout: .now() + .seconds(10))
                events.withLock { $0.append("suspend") }
            },
            resume: { events.withLock { $0.append("resume") } })
        let queue = DispatchQueue(label: "mantel.test.gate.order")

        let pause = DispatchSemaphore(value: 0)
        let outcome = Mutex<ListenerGate.Pause?>(nil)
        Thread.detachNewThread {
            outcome.withLock { $0 = gate.pause(for: .seconds(30), on: queue) }
            pause.signal()
        }
        #expect(inSuspend.wait(timeout: .now() + .seconds(10)) == .success, "the pause is in its suspend")

        let shutDown = DispatchSemaphore(value: 0)
        Thread.detachNewThread {
            gate.shutDown()
            shutDown.signal()
        }
        // The shutdown is asked for while the suspend is held. Done at once, it would have resumed a source that isn't suspended yet;
        // it waits for the suspend instead, and is still waiting when the quarter of a second is over.
        let finishedEarly = shutDown.wait(timeout: .now() + .milliseconds(250)) == .success
        letSuspendGo.signal()
        #expect(pause.wait(timeout: .now() + .seconds(10)) == .success)
        #expect(shutDown.wait(timeout: .now() + .seconds(10)) == .success)

        #expect(!finishedEarly, "the shutdown waited for the suspend")
        #expect(outcome.withLock { $0 } == .pausedFirstOfEpisode)
        #expect(events.withLock { $0 } == ["suspend", "resume"], "resumed before the suspend, the source would be resumed twice over")
    }

    @Test func pauseAndShutDownTogetherNeitherOverResumeNorStrandTheSource() {
        let queue = DispatchQueue(label: "mantel.test.gate")
        for _ in 0..<2000 {
            let (source, cancelled) = makeSource(queue: queue)
            let gate = ListenerGate(source: source)
            // Shutting down while the source is being put to rest: whichever comes first, the source ends up running.
            DispatchQueue.concurrentPerform(iterations: 2) { index in
                if index == 0 {
                    _ = gate.pause(for: .milliseconds(1), on: queue)
                } else {
                    gate.shutDown()
                }
            }
            source.cancel()
            #expect(cancelled.wait(timeout: .now() + .seconds(5)) == .success, "a source that was left suspended is never cancelled")
        }
    }

    @Test func aPausedSourceIsResumedByShutDownOnceAndNotAgainByTheTimer() {
        let queue = DispatchQueue(label: "mantel.test.gate.timer")
        let (source, cancelled) = makeSource(queue: queue)
        let gate = ListenerGate(source: source)

        #expect(gate.pause(for: .milliseconds(50), on: queue) == .pausedFirstOfEpisode)
        #expect(gate.pause(for: .milliseconds(50), on: queue) == .alreadyResting, "a second pause while resting does nothing")
        gate.shutDown()
        // The timer that was set comes after the source was resumed, and finds nothing to resume.
        Thread.sleep(forTimeInterval: 0.15)
        #expect(gate.pause(for: .milliseconds(50), on: queue) == .alreadyResting, "nothing rests after a shutdown")

        source.cancel()
        #expect(cancelled.wait(timeout: .now() + .seconds(5)) == .success)
    }
}
