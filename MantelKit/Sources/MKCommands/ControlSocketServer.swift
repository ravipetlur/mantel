import Darwin
import Dispatch
import Foundation
import MKCore
import Synchronization

public enum SocketError: Error, Equatable {
    /// The path is longer than a socket's address can hold, with how many bytes it has.
    case pathTooLong(Int)
    /// Another running Mantel holds the socket's lock.
    case inUse
    case bindFailed(Int32)
    case listenFailed(Int32)
}

/// Listens on the control socket and answers the commands `mantel` and Mantel's other tools send.
///
/// - **Who may connect.** Each client is checked once, when it connects, by `PeerPolicy` on what `inspector` finds out
///   about it. A client that isn't one of Mantel's own tools gets one reply, `rejected`, and is closed; the handler never
///   hears of it. The socket file is also made private to the person (mode 0600).
/// - **What a client may say.** One JSON request per line (`RequestEnvelope`), up to 1 MiB. A line that can't be read, or
///   is too long, gets a `badRequest` reply, and the connection stays open.
/// - **Replies.** A connection is served one request at a time, so its replies come in the order of its requests;
///   different connections are served at once. `handler` is called for every request, and `stop()` doesn't wait for it.
/// - **The socket file.** While a server runs it holds an exclusive lock (`flock`) on a file beside the socket, named like
///   it with `.lock` after. That lock, and not a connection to the socket, is how a running Mantel is told from a leftover:
///   a connection to a socket whose queue is full, or that is bound but not yet listening, is refused just like one to a
///   socket nobody listens on (on macOS even when its owner is alive), so it can't say. A server that can't take the lock
///   throws `.inUse` and touches nothing. One that has it knows that any file at the path was left by a run that has
///   ended, and replaces it. The lock goes when the server stops, or when the process ends however it ends; the lock
///   file itself is left where it is, as removing it would let two servers hold different files.
///
/// The server never logs a request beyond its command's name.
public final class ControlSocketServer: Sendable {
    public typealias Handler = @Sendable (MantelCommand, PeerInfo) async -> CommandResult

    private static let backlog: Int32 = 8
    private static let category = "control"

    private struct Running {
        let listener: any DispatchSourceRead
        /// Left when the listener's descriptor has been closed.
        let listenerClosed: DispatchGroup
        let file: FileIdentity
        /// The lock file's descriptor; the lock is held for as long as it is open.
        let lock: Int32
        var connections: [UUID: ControlConnection] = [:]
    }

    private let path: URL
    private let inspector: any PeerInspecting
    private let own: OwnSigning
    private let handler: Handler
    private let queue = DispatchQueue(label: "\(Log.subsystem).control-socket")
    private let running = Mutex<Running?>(nil)

    public init(path: URL, inspector: any PeerInspecting, own: OwnSigning, handler: @escaping Handler) {
        self.path = path
        self.inspector = inspector
        self.own = own
        self.handler = handler
    }

    deinit {
        // A server dropped without `stop()` still lets go of its socket. (It can't wait for the listener: this may be
        // running on the queue the listener closes on.)
        teardown(waiting: false)
    }

    // MARK: Starting and stopping

    /// Starts listening. Starting a server that is running does nothing.
    public func start() throws(SocketError) {
        try running.withLock { (state: inout Running?) throws(SocketError) in
            guard state == nil else { return }
            state = try openListener()
        }
    }

    /// Stops listening, closes every client's connection and removes the socket file. Does nothing when not running.
    public func stop() {
        teardown(waiting: true)
    }

    private func teardown(waiting: Bool) {
        let stopped = running.withLock { state in
            let current = state
            state = nil
            return current
        }
        guard let stopped else { return }
        stopped.listener.cancel()
        for connection in stopped.connections.values { connection.close() }
        if waiting { stopped.listenerClosed.wait() }
        // Only the file this server made, and only while the lock is still held.
        if stopped.file.matches(path.path) { unlink(path.path) }
        close(stopped.lock)
        Log.info(Self.category, "the control socket is closed")
    }

    private func openListener() throws(SocketError) -> Running {
        let pathString = path.path
        guard let address = SocketAddress.make(path: pathString) else {
            throw .pathTooLong(pathString.utf8.count)
        }

        let lock = try takeLock()
        // The lock is ours until `stop()`, so a file at the path was left by a run that has ended, whatever it is.
        var existing = stat()
        if lstat(pathString, &existing) == 0 {
            Log.info(Self.category, "replacing a control socket that was left behind")
            unlink(pathString)
        }

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            let code = errno
            close(lock)
            throw .bindFailed(code)
        }
        SocketAddress.configure(fd)
        guard SocketAddress.bind(fd, address) == 0 else {
            let code = errno
            close(fd)
            close(lock)
            throw .bindFailed(code)
        }
        // Noted at once: this is the file `stop()` may remove.
        let file = FileIdentity(of: pathString)
        // The folder it is in is private to the person too, so nobody else could have connected in between.
        guard chmod(pathString, 0o600) == 0 else {
            let code = errno
            unlink(pathString)
            close(fd)
            close(lock)
            throw .bindFailed(code)
        }
        guard listen(fd, Self.backlog) == 0 else {
            let code = errno
            unlink(pathString)
            close(fd)
            close(lock)
            throw .listenFailed(code)
        }

        let listener = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        let listenerClosed = DispatchGroup()
        listenerClosed.enter()
        listener.setEventHandler { [weak self] in self?.acceptPending(on: fd) }
        listener.setCancelHandler {
            close(fd)
            listenerClosed.leave()
        }
        listener.resume()
        Log.info(Self.category, "listening on the control socket")
        return Running(listener: listener, listenerClosed: listenerClosed, file: file, lock: lock)
    }

    /// Takes the exclusive lock on the lock file beside the socket, making the file if it isn't there. The lock is held
    /// for as long as the descriptor it returns is open.
    private func takeLock() throws(SocketError) -> Int32 {
        let fd = open(path.path + ".lock", O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw .bindFailed(errno) }
        _ = fchmod(fd, 0o600)
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            let code = errno
            close(fd)
            if code == EWOULDBLOCK {
                Log.warning(Self.category, "another Mantel is using the control socket")
                throw .inUse
            }
            throw .bindFailed(code)
        }
        return fd
    }

    // MARK: Clients

    private func acceptPending(on listener: Int32) {
        // A few at a time: the source asks again if more are waiting, and other work gets its turn.
        for _ in 0..<8 {
            let client = accept(listener, nil, nil)
            guard client >= 0 else { return }
            admit(client)
        }
    }

    /// Checks a client that has just connected: refuses it, or starts serving it.
    private func admit(_ fd: Int32) {
        guard SocketAddress.configure(fd) else {
            close(fd)
            return
        }
        let connection = ControlConnection(fd: fd)
        let peer: PeerInfo
        switch vet(inspector.inspect(socket: fd)) {
        case .failure(let refusal):
            Log.warning(Self.category, "refused a client (pid \(refusal.pid)): \(refusal.reason)")
            _ = connection.send(ReplyEnvelope(id: nil, result: .failure(code: .rejected, message: refusal.reason)))
            connection.close()
            return
        case .success(let accepted):
            peer = accepted
        }

        let registered = running.withLock { state -> Bool in
            guard state != nil else { return false }
            state?.connections[connection.id] = connection
            return true
        }
        guard registered else {
            connection.close()
            return
        }
        connection.startReading(on: queue)
        Task { await serve(connection, peer: peer) }
    }

    private struct Refusal: Error {
        let reason: String
        let pid: pid_t
    }

    /// The client, if the policy lets it in; otherwise why not.
    private func vet(_ peer: PeerInfo?) -> Result<PeerInfo, Refusal> {
        guard let peer else { return .failure(Refusal(reason: "Unsigned or invalid client", pid: 0)) }
        switch PeerPolicy.decide(peer, own: own) {
        case .accept: return .success(peer)
        case .reject(let reason): return .failure(Refusal(reason: reason, pid: peer.pid))
        }
    }

    /// Answers a connection's requests one at a time, until the client has said all it will, or the connection is closed.
    private func serve(_ connection: ControlConnection, peer: PeerInfo) async {
        for await line in connection.inbound {
            let reply: ReplyEnvelope
            switch line {
            case .overlong:
                reply = ReplyEnvelope(id: nil, result: .failure(code: .badRequest, message: "Request too large"))
            case .line(let data):
                reply = await answer(data, from: peer)
            }
            guard connection.send(reply) else { break }
        }
        connection.close()
        running.withLock { _ = $0?.connections.removeValue(forKey: connection.id) }
    }

    private func answer(_ line: Data, from peer: PeerInfo) async -> ReplyEnvelope {
        let decoder = JSONDecoder()
        guard let request = try? decoder.decode(RequestEnvelope.self, from: line) else {
            // A request that can't be understood may still say which it was.
            let id = (try? decoder.decode(RequestID.self, from: line))?.id
            return ReplyEnvelope(id: id, result: .failure(code: .badRequest, message: "Couldn't read the request"))
        }
        Log.info(Self.category, "command: \(request.command.name)")
        return ReplyEnvelope(id: request.id, result: await handler(request.command, peer))
    }

    private struct RequestID: Decodable {
        let id: UUID
    }
}

/// A file on disk, as its device and inode name it, so that a server removes the socket it made and not whatever has
/// been put at the same path since.
private struct FileIdentity: Sendable {
    let device: dev_t
    let inode: ino_t

    init(of path: String) {
        var info = stat()
        _ = lstat(path, &info)
        device = info.st_dev
        inode = info.st_ino
    }

    func matches(_ path: String) -> Bool {
        var info = stat()
        return lstat(path, &info) == 0 && info.st_dev == device && info.st_ino == inode
    }
}
