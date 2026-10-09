import Foundation
import Synchronization

/// A door a test holds shut: whoever `wait()`s is suspended until `open()`, and anyone who comes after it is open passes.
/// For a test that has to hold something half way (a probe that is waiting for the system) and look at it.
///
/// A wait ends when its task is cancelled too, which is what a test's time limit does, so that a door that is never opened
/// makes the test fail on its time limit instead of hanging the run.
public final class Gate: Sendable {
    private struct Waiter {
        let id: UInt64
        let continuation: CheckedContinuation<Void, Never>
    }

    private struct State {
        var isOpen = false
        var nextID: UInt64 = 0
        var waiting: [Waiter] = []
    }

    private let state = Mutex(State())

    public init() {}

    public func wait() async {
        let id = state.withLock { state -> UInt64 in
            state.nextID += 1
            return state.nextID
        }
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let passes = state.withLock { state -> Bool in
                    // Looked at inside the lock, so that a cancel can't come between the check and the waiting.
                    if state.isOpen || Task.isCancelled { return true }
                    state.waiting.append(Waiter(id: id, continuation: continuation))
                    return false
                }
                if passes { continuation.resume() }
            }
        } onCancel: {
            let waiter = state.withLock { state -> Waiter? in
                guard let index = state.waiting.firstIndex(where: { $0.id == id }) else { return nil }
                return state.waiting.remove(at: index)
            }
            waiter?.continuation.resume()
        }
    }

    public func open() {
        let waiting = state.withLock { state -> [Waiter] in
            state.isOpen = true
            defer { state.waiting = [] }
            return state.waiting
        }
        for waiter in waiting { waiter.continuation.resume() }
    }
}
