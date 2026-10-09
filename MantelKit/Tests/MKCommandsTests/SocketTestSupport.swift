import Darwin
import Foundation
import MKCommands
import Synchronization

// What the socket tests share: a pretend peer inspector, a client that speaks the wire format by hand, and a gate for
// making a handler wait for the test. Nothing here sleeps: a test waits for an event, with a limit.

/// An inspector that knows nobody: it says whatever it was told, whoever connects.
struct FakePeerInspector: PeerInspecting {
    let peer: PeerInfo?

    func inspect(socket fd: Int32) -> PeerInfo? { peer }
}

enum Fixtures {
    static let team = "TEAM123456"
    static let own = OwnSigning(bundleIdentifier: "com.example.mantel", teamIdentifier: team,
                                bundlePath: "/Applications/Mantel.app")
    /// Mantel's own tool, as `own` sees it.
    static let tool = PeerInfo(pid: 4321, signingIdentifier: "com.example.mantel.cli", teamIdentifier: team,
                               isValidSignature: true, executablePath: "/Applications/Mantel.app/Contents/MacOS/mantel")
    /// Some other program, validly signed by the same team.
    static let stranger = PeerInfo(pid: 4322, signingIdentifier: "com.apple.Terminal", teamIdentifier: team,
                                   isValidSignature: true, executablePath: "/System/Applications/Utilities/Terminal.app")
}

/// Holds a handler until a test lets it go.
actor Gate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        for waiter in waiters { waiter.resume() }
        waiters = []
    }
}

/// What a handler was asked, in order.
final class CallLog: Sendable {
    private let entries = Mutex<[(command: MantelCommand, peer: PeerInfo)]>([])

    func record(_ command: MantelCommand, _ peer: PeerInfo) {
        entries.withLock { $0.append((command, peer)) }
    }

    var commands: [MantelCommand] { entries.withLock { $0.map(\.command) } }
    var peers: [PeerInfo] { entries.withLock { $0.map(\.peer) } }
}

/// The lock file a server keeps beside its socket, taken by hand: for a test that stands in for another running Mantel,
/// or that asks whether the lock is held.
final class LockHolder: Sendable {
    private let fd: Int32

    /// Takes the lock on the file at `url`, making it if it isn't there. Nil when someone else holds it.
    init?(url: URL) {
        // Opened into a local and given to `fd` only once the lock is held: a failed `init?` still runs `deinit` once
        // every stored property is set, which would close this descriptor a second time, perhaps after another test
        // had been given the same number.
        let opened = open(url.path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        guard opened >= 0 else { return nil }
        guard flock(opened, LOCK_EX | LOCK_NB) == 0 else {
            close(opened)
            return nil
        }
        fd = opened
    }

    deinit {
        close(fd)
    }
}

enum RawClientError: Error { case connectFailed(Int32), timedOut }

/// A connection made by hand: it sends exactly the bytes it is given and shows exactly what comes back.
final class RawClient: Sendable {
    enum Outcome: Sendable, Equatable {
        case line(Data)
        case endOfStream
        case timedOut
    }

    private struct Inbox {
        var codec = LineCodec()
        var outputs: [LineCodecOutput] = []
    }

    private let fd: Int32
    private let inbox = Mutex(Inbox())

    init(path: URL) throws {
        fd = socket(AF_UNIX, SOCK_STREAM, 0)
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: Array(path.path.utf8)) }
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        if result != 0 {
            // `deinit` runs for an initializer that throws after every property is set, and closes `fd`.
            throw RawClientError.connectFailed(errno)
        }
    }

    deinit {
        Darwin.close(fd)
    }

    /// Writes all of `data`. False when the other end has gone.
    @discardableResult
    func sendRaw(_ data: Data) async -> Bool {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                continuation.resume(returning: self.writeAll(data))
            }
        }
    }

    func send(_ envelope: some Encodable) async throws {
        await sendRaw(try LineCodec.encode(envelope))
    }

    /// The next line, the end of the stream, or neither within `timeout`.
    func readLine(timeout: Duration = .seconds(10)) async -> Outcome {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                continuation.resume(returning: self.blockingReadLine(timeout: timeout))
            }
        }
    }

    /// The next reply, nil at the end of the stream. Anything else fails the test that asked.
    func readReply(timeout: Duration = .seconds(10)) async throws -> ReplyEnvelope? {
        switch await readLine(timeout: timeout) {
        case .line(let data): return try JSONDecoder().decode(ReplyEnvelope.self, from: data)
        case .endOfStream: return nil
        case .timedOut: throw RawClientError.timedOut
        }
    }

    /// Says no more is coming, and still listens.
    func shutdownWrite() {
        shutdown(fd, SHUT_WR)
    }

    private func writeAll(_ data: Data) -> Bool {
        var offset = 0
        let bytes = [UInt8](data)
        while offset < bytes.count {
            let written = bytes[offset...].withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
            if written > 0 {
                offset += written
            } else if written < 0, errno == EINTR {
                continue
            } else {
                return false
            }
        }
        return true
    }

    private func blockingReadLine(timeout: Duration) -> Outcome {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while true {
            let next = inbox.withLock { $0.outputs.isEmpty ? nil : $0.outputs.removeFirst() }
            switch next {
            case .line(let data)?: return .line(data)
            case .overlong?: continue
            case nil: break
            }

            let remaining = deadline - ContinuousClock.now
            let milliseconds = max(0, remaining.components.seconds * 1000 + remaining.components.attoseconds / 1_000_000_000_000_000)
            var entry = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let ready = poll(&entry, 1, Int32(clamping: milliseconds))
            if ready == 0 { return .timedOut }
            if ready < 0 {
                if errno == EINTR { continue }
                return .endOfStream
            }
            var buffer = [UInt8](repeating: 0, count: 64 * 1024)
            let count = read(fd, &buffer, buffer.count)
            if count > 0 {
                inbox.withLock { $0.outputs += $0.codec.append(Data(buffer[..<count])) }
            } else if count < 0, errno == EINTR || errno == EAGAIN {
                continue
            } else {
                return .endOfStream
            }
        }
    }
}

/// Leaves a socket file at `url` and nobody behind it: what a run that was killed leaves. With `listening` the socket
/// was listening before its process went; without, it never was.
func leaveSocketFile(at url: URL, listening: Bool) {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
    withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: Array(url.path.utf8)) }
    _ = withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
    }
    if listening { listen(fd, 4) }
    close(fd)  // the file stays
}

/// A listening socket that answers by hand, once: for the client's tests, where the server is the odd one.
final class CannedServer: Sendable {
    private let listener: Int32
    private let path: String

    /// Listens on `path`. Each connection gets `reply` after its first line, if there is one, and is closed.
    init(path: URL, reply: Data?) {
        self.path = path.path
        listener = socket(AF_UNIX, SOCK_STREAM, 0)
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: Array(path.path.utf8)) }
        _ = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        listen(listener, 4)
        let listener = listener
        DispatchQueue.global().async {
            let client = accept(listener, nil, nil)
            guard client >= 0 else { return }
            var byte: UInt8 = 0
            while read(client, &byte, 1) == 1, byte != UInt8(ascii: "\n") {}
            if let reply {
                let bytes = [UInt8](reply)
                _ = write(client, bytes, bytes.count)
            }
            close(client)
        }
    }

    deinit {
        close(listener)
        unlink(path)
    }
}
