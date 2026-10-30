import Foundation
import MKCore
import Synchronization

/// A session state that changes only when a test says so: no Mac is put to sleep, locked or switched to another user.
///
/// - `current()` is what the tests have made of it so far: the state it began with, and each change `send` has applied.
/// - `send(_:)` applies the change and tells every stream that is open. A change sent while no stream is open is only in `current()`
///   (a session that starts after it reads the state, as it does the real one).
/// - `openStreams` says how many streams are open: a test that quits the session sees its listener go.
public final class FakeSessionState: SessionStateSource {
    private struct State {
        var session: SessionState
        var continuations: [Int: AsyncStream<SessionChange>.Continuation] = [:]
        var nextID = 0
    }

    private let state: Mutex<State>

    public init(_ session: SessionState = .awake) {
        state = Mutex(State(session: session))
    }

    public func current() -> SessionState {
        state.withLock { $0.session }
    }

    public func changes() -> AsyncStream<SessionChange> {
        let (stream, continuation) = AsyncStream.makeStream(of: SessionChange.self, bufferingPolicy: .unbounded)
        let id = state.withLock { state -> Int in
            state.nextID += 1
            state.continuations[state.nextID] = continuation
            return state.nextID
        }
        continuation.onTermination = { [weak self] _ in
            self?.state.withLock { $0.continuations[id] = nil }
        }
        return stream
    }

    /// How many streams are open: asked for by `changes()`, and not yet ended by their listener or by `finish()`.
    public var openStreams: Int {
        state.withLock { $0.continuations.count }
    }

    /// Makes the change, and tells the streams that are open.
    public func send(_ change: SessionChange) {
        let open = state.withLock { state -> [AsyncStream<SessionChange>.Continuation] in
            state.session = state.session.applying(change)
            return Array(state.continuations.values)
        }
        for continuation in open { continuation.yield(change) }
    }

    /// Ends the streams that are open.
    public func finish() {
        let open = state.withLock { state -> [AsyncStream<SessionChange>.Continuation] in
            let open = Array(state.continuations.values)
            state.continuations = [:]
            return open
        }
        for continuation in open { continuation.finish() }
    }
}
