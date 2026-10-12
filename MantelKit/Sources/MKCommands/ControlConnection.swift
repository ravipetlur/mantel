import Darwin
import Dispatch
import Foundation
import MKCore
import Synchronization

/// One client of the control socket, as the server sees it: its descriptor, the lines that have come in, and the replies
/// going out.
///
/// - **Reading** happens on the server's queue, whenever the descriptor has something: the bytes go through a
///   `LineCodec`, and each line (or an over-long one) is handed to `inbound`, which the connection's own task reads.
/// - **Writing** is done off the server's queue and off the threads Swift's concurrency runs on (on a queue of its own, which
///   `send` waits for without blocking anything), with the descriptor in non-blocking mode and a limit on how long a client
///   that doesn't read may keep a reply waiting.
/// - **How much a client may have waiting.** `inbound` holds at most `maxPendingLines` lines that haven't been answered. A
///   client that says more than that is cut off: what it had asked is answered, then `hasOverflowed` says why it ended, and
///   the server tells it so and closes.
/// - **Closing** has two parts, and the descriptor is closed when both are done: the server asks for it (`close()`),
///   and the read source has finished (a source's descriptor must stay open until its cancel handler has run). A client
///   that has only stopped sending is still answered; the task closes the connection when it has.
///
/// Everything that can change is behind one lock, held only for single system calls, never while waiting.
final class ControlConnection: Sendable {
    /// How long a reply may wait for a client that doesn't read it: a second. After that the connection is closed.
    static let writeTimeout = Duration.seconds(1)
    /// How many lines may be waiting to be answered. A client that is served one request at a time and sends more than this
    /// at once is saying too much.
    static let maxPendingLines = 32
    /// Where a reply is written while it waits for a client that may not read it: a queue that isn't the server's, so that one
    /// slow client never holds the others up, and that isn't one of the threads Swift's tasks run on.
    private static let writeQueue = DispatchQueue(label: "\(Log.subsystem).control-write", qos: .userInitiated,
                                                  attributes: .concurrent)

    let id = UUID()
    /// What the client has sent, in order. It ends when the client stops sending or the connection is closed.
    let inbound: AsyncStream<LineCodecOutput>

    private struct State {
        var fd: Int32
        var codec = LineCodec()
        var source: (any DispatchSourceRead)?
        /// True when no read source is left to finish: none was made, or its cancel handler has run.
        var sourceFinished = true
        var closeRequested = false
        /// The client sent more lines than `maxPendingLines` while they were waiting.
        var overflowed = false
    }

    private let continuation: AsyncStream<LineCodecOutput>.Continuation
    private let state: Mutex<State>

    init(fd: Int32) {
        state = Mutex(State(fd: fd))
        // The oldest lines are kept: what a client asked first is what it is answered first.
        (inbound, continuation) = AsyncStream.makeStream(of: LineCodecOutput.self,
                                                         bufferingPolicy: .bufferingOldest(Self.maxPendingLines))
    }

    // MARK: Reading

    /// Starts reading, on `queue`.
    func startReading(on queue: DispatchQueue) {
        let source: any DispatchSourceRead? = state.withLock { state in
            guard state.fd >= 0, !state.closeRequested else { return nil }
            let source = DispatchSource.makeReadSource(fileDescriptor: state.fd, queue: queue)
            state.source = source
            state.sourceFinished = false
            return source
        }
        guard let source else { return }
        source.setEventHandler { [self] in readAvailable() }
        source.setCancelHandler { [self] in sourceDidFinish() }
        source.resume()
    }

    /// Reads once, which is all the source asks for: if more is waiting, it asks again.
    private func readAvailable() {
        enum Outcome { case read([LineCodecOutput]), endOfStream, failed, nothing }
        let outcome: Outcome = state.withLock { state in
            guard state.fd >= 0, !state.closeRequested else { return .nothing }
            var buffer = [UInt8](repeating: 0, count: 64 * 1024)
            let count = read(state.fd, &buffer, buffer.count)
            if count > 0 { return .read(state.codec.append(Data(buffer[..<count]))) }
            if count == 0 { return .endOfStream }
            return errno == EAGAIN || errno == EINTR ? .nothing : .failed
        }
        switch outcome {
        case .read(let outputs):
            for output in outputs {
                guard case .dropped = continuation.yield(output) else { continue }
                // Too many lines were waiting: what is waiting is still answered, and nothing more is read.
                state.withLock { $0.overflowed = true }
                stopReading()
                break
            }
        case .endOfStream:
            stopReading()
        case .failed:
            close()
        case .nothing:
            break
        }
    }

    /// The client has said all it will: no more is read, and what it asked is still answered.
    private func stopReading() {
        let source = state.withLock { $0.source }
        source?.cancel()
        continuation.finish()
    }

    /// Whether the client said more than `maxPendingLines` at once, which is why `inbound` ended.
    var hasOverflowed: Bool {
        state.withLock { $0.overflowed }
    }

    private func sourceDidFinish() {
        state.withLock { state in
            state.sourceFinished = true
            state.source = nil
            closeDescriptorIfDone(&state)
        }
    }

    // MARK: Writing

    /// Sends `reply`. False when it couldn't be sent in full: the client has gone, or hasn't read it within `writeTimeout`.
    func send(_ reply: ReplyEnvelope) async -> Bool {
        let line: Data
        if let encoded = try? LineCodec.encode(reply) {
            line = encoded
        } else if let fallback = try? LineCodec.encode(
            ReplyEnvelope(id: reply.id, result: .failure(code: .failed, message: "Couldn't write the answer."))) {
            line = fallback
        } else {
            return false
        }
        return await withCheckedContinuation { continuation in
            Self.writeQueue.async { continuation.resume(returning: self.write(line)) }
        }
    }

    /// Writes all of `data`, waiting for room as long as `writeTimeout` allows. It blocks: it runs on `writeQueue`.
    private func write(_ data: Data) -> Bool {
        let bytes = [UInt8](data)
        var offset = 0
        let deadline = ContinuousClock.now.advanced(by: Self.writeTimeout)
        while offset < bytes.count {
            enum Step { case wrote(Int), wait(Int32), failed }
            let step: Step = state.withLock { state in
                guard state.fd >= 0, !state.closeRequested else { return .failed }
                let count = bytes[offset...].withUnsafeBytes { Darwin.write(state.fd, $0.baseAddress, $0.count) }
                if count >= 0 { return .wrote(count) }
                switch errno {
                case EINTR: return .wrote(0)
                case EAGAIN: return .wait(state.fd)
                default: return .failed
                }
            }
            switch step {
            case .wrote(let count):
                offset += count
            case .wait(let fd):
                guard ContinuousClock.now < deadline else { return false }
                // Wakes when there is room, or when the descriptor is shut or closed under it; the next turn of the loop
                // finds out which, with the lock.
                var entry = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
                _ = poll(&entry, 1, 100)
            case .failed:
                return false
            }
        }
        return true
    }

    // MARK: Closing

    /// Ends the connection: the client sees the end of the stream at once, and the descriptor is closed as soon as the
    /// read source is done with it.
    func close() {
        let source: (any DispatchSourceRead)? = state.withLock { state in
            guard !state.closeRequested else { return nil }
            state.closeRequested = true
            if state.fd >= 0 { shutdown(state.fd, SHUT_RDWR) }
            closeDescriptorIfDone(&state)
            return state.source
        }
        source?.cancel()
        continuation.finish()
    }

    private func closeDescriptorIfDone(_ state: inout State) {
        guard state.closeRequested, state.sourceFinished, state.fd >= 0 else { return }
        Darwin.close(state.fd)
        state.fd = -1
    }
}
