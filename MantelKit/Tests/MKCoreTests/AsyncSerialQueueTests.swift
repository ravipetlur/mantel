import Foundation
import MKTestSupport
import Synchronization
import Testing

@testable import MKCore

/// What a queue's pieces of work noted, in the order they did.
private final class Notes: Sendable {
    private let list = Mutex<[Int]>([])

    var all: [Int] { list.withLock { $0 } }
    func add(_ number: Int) { list.withLock { $0.append(number) } }
}

@Suite("Async serial queue", .timeLimit(.minutes(1)))
struct AsyncSerialQueueTests {
    @Test func workIsDoneInTheOrderItWasGiven() async {
        let queue = AsyncSerialQueue()
        let notes = Notes()
        // Each piece suspends, which lets a queue that isn't serial interleave them.
        for number in 0 ..< 50 {
            queue.enqueue {
                await Task.yield()
                notes.add(number)
                await Task.yield()
            }
        }
        await queue.drained()
        #expect(notes.all == Array(0 ..< 50))
    }

    @Test func aPieceIsFinishedBeforeTheNextBegins() async {
        let queue = AsyncSerialQueue()
        let gate = Gate()
        let notes = Notes()
        queue.enqueue {
            notes.add(1)
            await gate.wait()
            notes.add(2)
        }
        queue.enqueue { notes.add(3) }
        #expect(await waitUntil { notes.all == [1] })
        // The second is waiting behind the first, which is held.
        try? await Task.sleep(for: .milliseconds(20))
        #expect(notes.all == [1])
        gate.open()
        await queue.drained()
        #expect(notes.all == [1, 2, 3])
    }

    @Test func runGivesWhatTheWorkCameTo() async {
        let queue = AsyncSerialQueue()
        let notes = Notes()
        queue.enqueue { notes.add(1) }
        let answer = await queue.run { () -> Int in
            notes.add(2)
            return 42
        }
        #expect(answer == 42)
        #expect(notes.all == [1, 2], "it was done after what came before it")
    }

    @Test func workIsNotDroppedWhenTheQueueIsLetGo() async {
        // The last reference goes while work is still waiting: it is all done.
        let notes = Notes()
        let gate = Gate()
        do {
            let queue = AsyncSerialQueue()
            queue.enqueue {
                await gate.wait()
                notes.add(1)
            }
            queue.enqueue { notes.add(2) }
        }
        gate.open()
        #expect(await waitUntil { notes.all == [1, 2] })
    }

    @Test func aCancelledCallerOfRunDoesNotCutTheWorkShort() async {
        let queue = AsyncSerialQueue()
        let gate = Gate()
        let notes = Notes()
        let caller = Task {
            await queue.run {
                await gate.wait()
                notes.add(1)
            }
        }
        caller.cancel()
        gate.open()
        await caller.value
        #expect(notes.all == [1])
    }
}
