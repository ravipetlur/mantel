/// Runs pieces of async work one after the other, in the order they were given, each finished before the next begins.
///
/// What is handed in from separate unstructured tasks isn't ordered: two tasks started one after the other may reach what they call
/// in either order. A queue is: it is one stream with one task reading it. Work is never dropped and never cancelled (the reader is
/// not a task anybody holds), so a piece that is long (a call that waits for a menu bar read) is finished, and the pieces behind it
/// wait for it.
///
/// A piece of work mustn't wait for the queue it is on: it would wait for itself.
public final class AsyncSerialQueue: Sendable {
    private let continuation: AsyncStream<@Sendable () async -> Void>.Continuation

    public init() {
        let (stream, continuation) = AsyncStream.makeStream(of: (@Sendable () async -> Void).self, bufferingPolicy: .unbounded)
        self.continuation = continuation
        // Holds nothing of the queue: a queue nobody has any more finishes the stream (in `deinit`), and the reader ends once the
        // work that is left has been done.
        Task.detached {
            for await work in stream { await work() }
        }
    }

    deinit {
        continuation.finish()
    }

    /// Puts the work at the end of the queue and returns at once.
    public func enqueue(_ work: @escaping @Sendable () async -> Void) {
        continuation.yield(work)
    }

    /// Puts the work at the end of the queue and returns what it comes to, once it has been done.
    public func run<Value: Sendable>(_ work: @escaping @Sendable () async -> Value) async -> Value {
        await withCheckedContinuation { (waiting: CheckedContinuation<Value, Never>) in
            enqueue { waiting.resume(returning: await work()) }
        }
    }

    /// Returns once everything put in the queue before this call has been done.
    public func drained() async {
        await run {}
    }
}
