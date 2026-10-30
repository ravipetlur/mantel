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
///   is too long, gets a `badRequest` reply, and the connection stays open. A client that has more than 32 lines waiting
///   to be answered is told "Too many requests at once" (`badRequest`) after the answers it was owed, and is closed.
/// - **Replies.** A connection is served one request at a time, so its replies come in the order of its requests;
///   different connections are served at once. `handler` is called for every request, and `stop()` doesn't wait for it. A
///   client that doesn't read a reply within a second is closed, and the wait is not on the server's queue.
/// - **Running out of descriptors.** When `accept` fails because the process (or the system) has no more files to give
///   (`EMFILE`, `ENFILE`), the listener is suspended for a second, so that it doesn't spin on the connection that is still
///   waiting. That is logged once for as long as it lasts.
/// - **The socket file.** While a server runs it holds an exclusive lock (`flock`) on a file beside the socket, named like
///   it with `.lock` after. That lock, and not a connection to the socket, is how a running Mantel is told from a leftover:
///   a connection to a socket whose queue is full, or that is bound but not yet listening, is refused just like one to a
///   socket nobody listens on (on macOS even when its owner is alive), so it can't say. A server that can't take the lock
///   throws `.inUse` and touches nothing. One that has it knows that any file at the path was left by a run that has
///   ended, and replaces it. The lock goes when the server stops, or when the process ends however it ends; the lock
///   file itself is left where it is, as removing it would let two servers hold different files. (An `flock` belongs to the open
///   file, not to the descriptor: a child process that another thread is spawning when the server stops has a copy of the
///   descriptor until it runs its program, which closes it, as the lock file is opened close-on-exec. So for a few
///   milliseconds after `stop()` a lock can still look held. A new server in the same process finds `.inUse` for that long;
///   another process, which is what the lock is for, just finds the holder gone a moment later.)
///
/// The server never logs a request beyond its command's name. It says nothing when it finds the lock held: that is not a
/// fault of this server, and the app that was refused says what it did about it.
public final class ControlSocketServer: Sendable {
    public typealias Handler = @Sendable (MantelCommand, PeerInfo) async -> CommandResult

    private static let backlog: Int32 = 8
    private static let category = "control"

    /// How the listener accepts a connection: `accept(2)` on the listening descriptor, which returns the client's descriptor,
    /// or -1 with `errno` set. A test gives its own to make it fail.
    typealias Accept = @Sendable (_ listener: Int32) -> Int32
    /// Calls `work` once `after` has passed (on the server's queue, or on a test's clock).
    typealias Scheduler = @Sendable (_ after: Duration, _ work: @escaping @Sendable () -> Void) -> Void

    private struct Running {
        let listener: any DispatchSourceRead
        let gate: ListenerGate
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
    private let accept: Accept
    private let pauseOnExhaustion: Duration
    private let resumeAfter: Scheduler?
    private let clock: any Clock
    private let warn: @Sendable (String) -> Void
    private let queue = DispatchQueue(label: "\(Log.subsystem).control-socket")
    private let running = Mutex<Running?>(nil)
    private let replacedLeftover = Mutex(false)

    /// Whether the last start found a file at the socket's path, left by a run that ended, and replaced it. The app starts the
    /// server before its log has a file, so it says so there itself: it is what a crash leaves behind.
    public var replacedLeftoverSocket: Bool {
        replacedLeftover.withLock { $0 }
    }

    public convenience init(path: URL, inspector: any PeerInspecting, own: OwnSigning, handler: @escaping Handler) {
        self.init(path: path, inspector: inspector, own: own, accept: { Darwin.accept($0, nil, nil) },
                  pauseOnExhaustion: .seconds(1), warn: { Log.warning(Self.category, $0) }, handler: handler)
    }

    /// With the way a connection is accepted, how long the listener rests when there are no descriptors left (and what ends the rest, a
    /// test's clock; the server's own queue when it isn't given), and where the warning about that goes given, so that a test can make
    /// `accept` fail and see what is said. `clock` is what the wait for a client that doesn't read a reply goes by (the real time when it
    /// isn't given), so that a test moves it by hand.
    init(path: URL, inspector: any PeerInspecting, own: OwnSigning, accept: @escaping Accept, pauseOnExhaustion: Duration,
         resumeAfter: Scheduler? = nil, clock: any Clock = SystemClock(), warn: @escaping @Sendable (String) -> Void,
         handler: @escaping Handler) {
        self.resumeAfter = resumeAfter
        self.clock = clock
        self.path = path
        self.inspector = inspector
        self.own = own
        self.accept = accept
        self.pauseOnExhaustion = pauseOnExhaustion
        self.warn = warn
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

    /// How long `stop()` waits for the listener to finish closing. The quit calls it on the main thread, and a main thread that waits with no
    /// bound is the one step of the quit that the quit timer can't get past (it answers on the main actor too).
    static let listenerCloseLimit: DispatchTimeInterval = .milliseconds(500)

    /// Stops listening, closes every client's connection and removes the socket file. Does nothing when not running. Waits for the listener
    /// to be closed for `listenerCloseLimit` at most: past it the file is removed all the same, and the listener finishes closing by itself.
    public func stop() {
        teardown(waiting: true)
    }

    /// Waits for the listener's cancel handler to have run, for `limit` at most; false when it hadn't (the quit's own trace says how long
    /// the step took).
    @discardableResult
    static func waitForClose(_ closed: DispatchGroup, limit: DispatchTimeInterval) -> Bool {
        closed.wait(timeout: .now() + limit) != .timedOut
    }

    private func teardown(waiting: Bool) {
        let stopped = running.withLock { state in
            let current = state
            state = nil
            return current
        }
        guard let stopped else { return }
        stopped.listener.cancel()
        // A suspended source doesn't finish being cancelled until it is resumed.
        stopped.gate.shutDown()
        for connection in stopped.connections.values { connection.close() }
        if waiting { Self.waitForClose(stopped.listenerClosed, limit: Self.listenerCloseLimit) }
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
        let leftBehind = lstat(pathString, &existing) == 0
        replacedLeftover.withLock { $0 = leftBehind }
        if leftBehind { unlink(pathString) }

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
        let gate = ListenerGate(source: listener)
        let listenerClosed = DispatchGroup()
        listenerClosed.enter()
        listener.setEventHandler { [weak self] in self?.acceptPending(on: fd, gate: gate) }
        listener.setCancelHandler {
            close(fd)
            listenerClosed.leave()
        }
        listener.resume()
        Log.info(Self.category, "listening on the control socket")
        return Running(listener: listener, gate: gate, listenerClosed: listenerClosed, file: file, lock: lock)
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
            // Said nothing: the one that is refused knows, and says what it does about it.
            if code == EWOULDBLOCK { throw .inUse }
            throw .bindFailed(code)
        }
        return fd
    }

    // MARK: Clients

    private func acceptPending(on listener: Int32, gate: ListenerGate) {
        // A few at a time: the source asks again if more are waiting, and other work gets its turn.
        for _ in 0..<8 {
            let client = accept(listener)
            guard client >= 0 else {
                let code = errno
                // No descriptor to give it: the connection stays waiting, and the source would call again at once, for ever.
                if code == EMFILE || code == ENFILE, pause(gate) == .pausedFirstOfEpisode {
                    warn("too many open files; pausing new connections for a second")
                }
                return
            }
            gate.accepted()
            admit(client)
        }
    }

    private func pause(_ gate: ListenerGate) -> ListenerGate.Pause {
        guard let resumeAfter else { return gate.pause(for: pauseOnExhaustion, on: queue) }
        return gate.pause(for: pauseOnExhaustion, schedule: resumeAfter)
    }

    /// Whether a client has sent more lines than could wait and is only being answered now (for a test to know the flood was read).
    var hasOverflowedConnection: Bool {
        running.withLock { $0?.connections.values.contains { $0.hasOverflowed } ?? false }
    }

    /// Checks a client that has just connected: refuses it, or starts serving it.
    private func admit(_ fd: Int32) {
        guard SocketAddress.configure(fd) else {
            close(fd)
            return
        }
        let connection = ControlConnection(fd: fd, clock: clock)
        let peer: PeerInfo
        switch vet(inspector.inspect(socket: fd)) {
        case .failure(let refusal):
            Log.warning(Self.category, "refused a client (pid \(refusal.pid)): \(refusal.reason)")
            // The reply is written off this queue: a client that doesn't read must not hold the others up.
            Task {
                _ = await connection.send(ReplyEnvelope(id: nil, result: .failure(code: .rejected, message: refusal.reason)))
                connection.close()
            }
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
        var delivered = true
        for await line in connection.inbound {
            let reply: ReplyEnvelope
            switch line {
            case .overlong:
                reply = ReplyEnvelope(id: nil, result: .failure(code: .badRequest, message: "Request too large"))
            case .line(let data):
                reply = await answer(data, from: peer)
            }
            guard await connection.send(reply) else {
                delivered = false
                break
            }
        }
        // It ended because the client said more than could wait: it has what it asked for, and now is told why that is all.
        if delivered, connection.hasOverflowed {
            _ = await connection.send(ReplyEnvelope(id: nil, result: .failure(code: .badRequest, message: "Too many requests at once")))
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

/// Lets the listening source rest for a while: a source that is suspended isn't called, and the connections that are waiting
/// stay in the queue the system keeps for them.
///
/// Whoever suspends it is the one to resume it, once: the timer that was set, or `shutDown`, which a source that is being
/// cancelled needs (a cancelled source that is suspended never finishes). The calls to the source are made inside the lock that
/// guards the flag, so that a resume can never come between the flag being set and the suspend that goes with it: a source
/// resumed while it isn't suspended brings the process down.
final class ListenerGate: Sendable {
    enum Pause: Equatable {
        /// Already resting, or shut down: nothing was done.
        case alreadyResting
        /// Now resting. It was a fresh episode: the first failure since a connection was last accepted.
        case pausedFirstOfEpisode
        /// Now resting again, in an episode that was already told of.
        case paused
    }

    private struct State {
        var isSuspended = false
        var isShutDown = false
        /// Whether the episode of failures that is going on has been told of.
        var toldOfEpisode = false
    }

    private let suspendSource: @Sendable () -> Void
    private let resumeSource: @Sendable () -> Void
    private let state = Mutex(State())

    init(source: any DispatchSourceRead) {
        suspendSource = { source.suspend() }
        resumeSource = { source.resume() }
    }

    /// What a test gives to see the order of the calls.
    init(suspend: @escaping @Sendable () -> Void, resume: @escaping @Sendable () -> Void) {
        suspendSource = suspend
        resumeSource = resume
    }

    /// Suspends the source, and resumes it after `duration` on `queue`.
    func pause(for duration: Duration, on queue: DispatchQueue) -> Pause {
        pause(for: duration, schedule: { after, work in
            let seconds = Double(after.components.seconds) + Double(after.components.attoseconds) / 1e18
            queue.asyncAfter(deadline: .now() + seconds) { work() }
        })
    }

    /// Suspends the source, and has `schedule` call back after `duration` to resume it.
    func pause(for duration: Duration, schedule: ControlSocketServer.Scheduler) -> Pause {
        let outcome = state.withLock { [suspendSource] state -> Pause in
            guard !state.isShutDown, !state.isSuspended else { return .alreadyResting }
            state.isSuspended = true
            suspendSource()
            defer { state.toldOfEpisode = true }
            return state.toldOfEpisode ? .paused : .pausedFirstOfEpisode
        }
        guard outcome != .alreadyResting else { return outcome }
        schedule(duration) { [self] in resume() }
        return outcome
    }

    /// A connection was accepted: whatever went wrong before is over, and the next failure is a new episode.
    func accepted() {
        state.withLock { $0.toldOfEpisode = false }
    }

    func shutDown() {
        state.withLock { $0.isShutDown = true }
        resume()
    }

    private func resume() {
        state.withLock { [resumeSource] state in
            guard state.isSuspended else { return }
            state.isSuspended = false
            resumeSource()
        }
    }
}
