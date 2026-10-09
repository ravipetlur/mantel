import Darwin
import Dispatch
import Foundation

public enum ClientError: Error, Equatable {
    /// Nothing is listening at the socket's path: Mantel isn't running.
    case notRunning
    /// Mantel didn't answer in time.
    case timedOut
    /// Something answered, but not the way Mantel does. With what went wrong, in words.
    case protocolError(String)
}

/// Sends one command to the running app over the control socket and waits for its answer.
///
/// Each `send` makes its own connection. A refusal from the app (`rejected`) is an answer, returned as a
/// `CommandResult.failure`; the errors are for when there was no answer.
public struct ControlSocketClient: Sendable {
    private let path: URL

    public init(path: URL) {
        self.path = path
    }

    /// - Parameter timeout: the longest the whole exchange may take, from connecting to the last byte of the answer.
    ///   Cancelling the task doesn't cut it short: the timeout does.
    public func send(_ command: MantelCommand, timeout: Duration = .seconds(30)) async throws(ClientError) -> CommandResult {
        let request = RequestEnvelope(id: UUID(), command: command)
        let path = path.path
        // The exchange waits on the socket, so it runs on a thread of its own and doesn't hold up the caller's.
        let outcome: Result<CommandResult, ClientError> = await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                continuation.resume(returning: Self.exchange(request, at: path, timeout: timeout))
            }
        }
        return try outcome.get()
    }

    private static func exchange(_ request: RequestEnvelope, at path: String,
                                 timeout: Duration) -> Result<CommandResult, ClientError> {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        guard let address = SocketAddress.make(path: path) else { return .failure(.notRunning) }
        guard let line = try? LineCodec.encode(request) else {
            return .failure(.protocolError("Couldn't write the request."))
        }

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return .failure(.protocolError("Couldn't open a socket (error \(errno)).")) }
        defer { close(fd) }
        SocketAddress.configure(fd)

        guard SocketAddress.connect(fd, address) == 0 else {
            switch errno {
            case ENOENT, ECONNREFUSED, ENOTSOCK: return .failure(.notRunning)
            default: return .failure(.protocolError("Couldn't connect to Mantel: \(String(cString: strerror(errno)))."))
            }
        }

        // If Mantel has already hung up (it does, on a tool it refuses), the request can't be written, but the answer
        // that explains why can still be read.
        let sent = writeAll(line, to: fd, deadline: deadline)
        if sent == .timedOut { return .failure(.timedOut) }

        var codec = LineCodec()
        while true {
            switch readSome(from: fd, deadline: deadline) {
            case .timedOut:
                return .failure(.timedOut)
            case .closed:
                return .failure(.protocolError("Mantel closed the connection without answering."))
            case .failed(let code):
                return .failure(.protocolError("Couldn't read Mantel's answer: \(String(cString: strerror(code)))."))
            case .data(let bytes):
                for output in codec.append(bytes) {
                    switch output {
                    case .overlong:
                        return .failure(.protocolError("Mantel's answer was too large."))
                    case .line(let data):
                        return decode(data, answering: request.id)
                    }
                }
            }
        }
    }

    private static func decode(_ line: Data, answering id: UUID) -> Result<CommandResult, ClientError> {
        guard let reply = try? JSONDecoder().decode(ReplyEnvelope.self, from: line) else {
            return .failure(.protocolError("Mantel's answer couldn't be read."))
        }
        // An answer without an id is to no request in particular: a refusal, or a request that wasn't understood.
        guard reply.id == nil || reply.id == id else {
            return .failure(.protocolError("Mantel answered a different request."))
        }
        return .success(reply.result)
    }

    // MARK: Waiting on the socket

    private enum WriteOutcome { case done, closed, timedOut }
    private enum ReadOutcome { case data(Data), closed, timedOut, failed(Int32) }

    private static func writeAll(_ data: Data, to fd: Int32, deadline: ContinuousClock.Instant) -> WriteOutcome {
        let bytes = [UInt8](data)
        var offset = 0
        while offset < bytes.count {
            let count = bytes[offset...].withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
            if count >= 0 {
                offset += count
            } else if errno == EAGAIN {
                if !wait(for: Int16(POLLOUT), on: fd, until: deadline) { return .timedOut }
            } else if errno != EINTR {
                return .closed
            }
        }
        return .done
    }

    private static func readSome(from fd: Int32, deadline: ContinuousClock.Instant) -> ReadOutcome {
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = read(fd, &buffer, buffer.count)
            if count > 0 { return .data(Data(buffer[..<count])) }
            if count == 0 { return .closed }
            switch errno {
            case EINTR: continue
            case EAGAIN: if !wait(for: Int16(POLLIN), on: fd, until: deadline) { return .timedOut }
            case ECONNRESET: return .closed
            default: return .failed(errno)
            }
        }
    }

    /// Waits until `fd` is ready for `events`. False if the deadline came first.
    private static func wait(for events: Int16, on fd: Int32, until deadline: ContinuousClock.Instant) -> Bool {
        while true {
            let remaining = deadline - ContinuousClock.now
            guard remaining > .zero else { return false }
            var entry = pollfd(fd: fd, events: events, revents: 0)
            let ready = poll(&entry, 1, Int32(clamping: remaining.millisecondsRoundedUp))
            if ready > 0 { return true }
            if ready < 0, errno != EINTR { return true }  // let the next read or write report what is wrong
        }
    }
}
