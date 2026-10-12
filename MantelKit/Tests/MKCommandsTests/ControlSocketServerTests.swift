import Darwin
import Foundation
import MKTestSupport
import Synchronization
import Testing

@testable import MKCommands

@Suite("Control socket server", .timeLimit(.minutes(1)))
struct ControlSocketServerTests {
    /// Held for the whole test: the sockets live in it.
    private let folder = TemporaryFolder.shortForSockets()
    private let calls = CallLog()

    private var socketURL: URL { folder.url.appending(path: "s.sock") }
    /// The file a server holds a lock on for as long as it runs.
    private var lockURL: URL { folder.url.appending(path: "s.sock.lock") }

    private func inode(of url: URL) -> ino_t? {
        var info = stat()
        return lstat(url.path, &info) == 0 ? info.st_ino : nil
    }

    private func makeServer(at path: URL? = nil, peer: PeerInfo? = Fixtures.tool,
                            handler: (@Sendable (MantelCommand, PeerInfo) async -> CommandResult)? = nil
    ) -> ControlSocketServer {
        let calls = calls
        return ControlSocketServer(path: path ?? socketURL, inspector: FakePeerInspector(peer: peer),
                                   own: Fixtures.own) { command, peer in
            calls.record(command, peer)
            if let handler { return await handler(command, peer) }
            return .ok(.string("handled \(command.name)"))
        }
    }

    private func request(_ command: MantelCommand = .ping, id: UUID = UUID()) -> RequestEnvelope {
        RequestEnvelope(id: id, command: command)
    }

    private func expectBadRequest(_ reply: ReplyEnvelope?, _ message: String, id: UUID? = nil,
                                  sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(reply == ReplyEnvelope(id: id, result: .failure(code: .badRequest, message: message)),
                sourceLocation: sourceLocation)
    }

    // MARK: Answering

    @Test func requestGetsReplyWithSameID() async throws {
        let server = makeServer()
        try server.start()
        defer { server.stop() }

        let client = try RawClient(path: socketURL)
        let first = request(.ping)
        try await client.send(first)
        #expect(try await client.readReply() == ReplyEnvelope(id: first.id, result: .ok(.string("handled ping"))))

        // The same connection serves another request, with its own id.
        let second = request(.openSettings(.about))
        try await client.send(second)
        #expect(try await client.readReply() == ReplyEnvelope(id: second.id, result: .ok(.string("handled settings"))))

        // The handler was given the command, and who asked.
        #expect(calls.commands == [.ping, .openSettings(.about)])
        #expect(calls.peers == [Fixtures.tool, Fixtures.tool])
    }

    @Test func aHandlersFailureIsTheReply() async throws {
        let server = makeServer { _, _ in .failure(code: .unavailable, message: "Probes aren't built yet") }
        try server.start()
        defer { server.stop() }

        let client = try RawClient(path: socketURL)
        let probe = request(.probe(.inventory, options: [:]))
        try await client.send(probe)
        #expect(try await client.readReply()
                == ReplyEnvelope(id: probe.id, result: .failure(code: .unavailable, message: "Probes aren't built yet")))
    }

    @Test func repliesAreInRequestOrder() async throws {
        let server = makeServer { command, _ in
            // Some requests take longer than the ones after them, which must not overtake.
            if case .openSettings = command { for _ in 0..<50 { await Task.yield() } }
            return .ok(.string(command.name))
        }
        try server.start()
        defer { server.stop() }

        // Fewer than the 32 a connection may have waiting.
        let requests = (0..<30).map { request($0.isMultiple(of: 3) ? .openSettings(nil) : .ping) }
        var batch = Data()
        for envelope in requests { batch.append(try LineCodec.encode(envelope)) }

        let client = try RawClient(path: socketURL)
        await client.sendRaw(batch)
        for envelope in requests {
            let reply = try await client.readReply()
            #expect(reply?.id == envelope.id, "got \(String(describing: reply))")
        }
    }

    @Test func aClientThatClosesItsSendingEndStillGetsItsReply() async throws {
        let server = makeServer()
        try server.start()
        defer { server.stop() }

        let client = try RawClient(path: socketURL)
        let envelope = request(.version)
        try await client.send(envelope)
        client.shutdownWrite()
        #expect(try await client.readReply()?.id == envelope.id)
        #expect(try await client.readReply() == nil, "and then the server closes")
    }

    @Test func twoClientsConcurrently() async throws {
        let gate = Gate()
        let server = makeServer { command, _ in
            // `version` waits for a `ping` from the other client. If clients were served one at a time, it never would.
            if case .version = command { await gate.wait() }
            if case .ping = command { await gate.open() }
            return .ok(.string(command.name))
        }
        try server.start()
        defer { server.stop() }

        let waiting = try RawClient(path: socketURL)
        let other = try RawClient(path: socketURL)
        let first = request(.version)
        try await waiting.send(first)
        let second = request(.ping)
        try await other.send(second)

        #expect(try await other.readReply() == ReplyEnvelope(id: second.id, result: .ok(.string("ping"))))
        #expect(try await waiting.readReply() == ReplyEnvelope(id: first.id, result: .ok(.string("version"))))
    }

    @Test func manyClientsAtOnce() async throws {
        let server = makeServer()
        try server.start()
        defer { server.stop() }

        let url = socketURL
        try await withThrowingTaskGroup(of: Bool.self) { group in
            for _ in 0..<6 {
                group.addTask {
                    let client = try RawClient(path: url)
                    let envelope = RequestEnvelope(id: UUID(), command: .version)
                    try await client.send(envelope)
                    return try await client.readReply()?.id == envelope.id
                }
            }
            for try await answered in group {
                #expect(answered)
            }
        }
    }

    // MARK: Strangers

    @Test(arguments: [
        (Fixtures.stranger, "Not a Mantel tool: com.apple.Terminal"),
        (PeerInfo(pid: 9, signingIdentifier: nil, teamIdentifier: nil, isValidSignature: false, executablePath: nil),
         "Unsigned or invalid client"),
        (nil, "Unsigned or invalid client"),
    ] as [(PeerInfo?, String)])
    func rejectedPeerGetsOneReplyAndIsClosed(peer: PeerInfo?, reason: String) async throws {
        let server = makeServer(peer: peer)
        try server.start()
        defer { server.stop() }

        let client = try RawClient(path: socketURL)
        // It asks anyway, and nobody answers: the reply to a stranger says no, once.
        await client.sendRaw(try LineCodec.encode(request(.version)))
        #expect(try await client.readReply() == ReplyEnvelope(id: nil, result: .failure(code: .rejected, message: reason)))
        #expect(try await client.readReply() == nil, "the connection is closed")
        #expect(calls.commands.isEmpty, "the handler was never asked")
    }

    @Test func aRejectedClientDoesNotStopTheServer() async throws {
        // A server that refuses everyone, and one that serves, side by side: refusing leaves no mark on the next client.
        let server = makeServer(peer: Fixtures.stranger)
        try server.start()
        defer { server.stop() }

        for _ in 0..<5 {
            let client = try RawClient(path: socketURL)
            #expect(try await client.readReply()?.result
                    == .failure(code: .rejected, message: "Not a Mantel tool: com.apple.Terminal"))
        }
    }

    @Test func theRealInspectorRefusesAProgramThatIsNotMantelsTool() async throws {
        // This test's own process connects, and it isn't `com.example.mantel.cli`, whatever it is signed with.
        let server = ControlSocketServer(path: socketURL, inspector: CodeSigningInspector(), own: Fixtures.own) { _, _ in
            .ok(.string("should not be asked"))
        }
        try server.start()
        defer { server.stop() }

        let client = try RawClient(path: socketURL)
        await client.sendRaw(try LineCodec.encode(request(.ping)))
        let answer = try await client.readReply()
        let reply = try #require(answer)
        #expect(reply.id == nil)
        guard case .failure(let code, let message) = reply.result else {
            Issue.record("the real inspector let a stranger in: \(reply)")
            return
        }
        #expect(code == .rejected)
        #expect(!message.isEmpty)
        #expect(try await client.readReply() == nil)
    }

    @Test func theRealInspectorWithTheTeamRequirementRefusesAProgramNotSignedByTheTeam() async throws {
        // The app is a team build, so a client must meet the requirement for its team: this process (ad hoc) doesn't.
        let inspector = CodeSigningInspector(requirement: PeerPolicy.requirement(for: Fixtures.own))
        let server = ControlSocketServer(path: socketURL, inspector: inspector, own: Fixtures.own) { _, _ in
            .ok(.string("should not be asked"))
        }
        try server.start()
        defer { server.stop() }

        let client = try RawClient(path: socketURL)
        await client.sendRaw(try LineCodec.encode(request(.ping)))
        #expect(try await client.readReply()
                == ReplyEnvelope(id: nil, result: .failure(code: .rejected, message: "Unsigned or invalid client")))
        #expect(try await client.readReply() == nil)
    }

    // MARK: Garbage

    @Test func garbageDoesNotStopTheServer() async throws {
        let server = makeServer()
        try server.start()
        defer { server.stop() }

        let client = try RawClient(path: socketURL)

        // Lines that aren't a request: text, an empty line, other JSON, bytes that aren't UTF-8, a command nobody knows.
        for garbage in [Data("this is not json\n".utf8), Data("\n".utf8), Data("[1,2,3]\n".utf8), Data("{}\n".utf8),
                        Data([0xFF, 0xFE, 0x00, 0x80, 0x0A]), Data("{\"id\":\"not a uuid\"}\n".utf8)] {
            await client.sendRaw(garbage)
            expectBadRequest(try await client.readReply(), "Couldn't read the request")
        }

        // A request that is readable but names a command this version doesn't know still has its id answered.
        let strange = UUID()
        await client.sendRaw(Data("{\"command\":{\"command\":\"explode\"},\"id\":\"\(strange.uuidString)\"}\n".utf8))
        expectBadRequest(try await client.readReply(), "Couldn't read the request", id: strange)

        // The same connection still works.
        let good = request(.ping)
        try await client.send(good)
        #expect(try await client.readReply()?.id == good.id)

        // A line over the limit gets its own answer, and the connection stays open.
        await client.sendRaw(Data(repeating: UInt8(ascii: "x"), count: LineCodec.maxLineBytes + 10) + Data("\n".utf8))
        expectBadRequest(try await client.readReply(), "Request too large")
        let afterwards = request(.version)
        try await client.send(afterwards)
        #expect(try await client.readReply()?.id == afterwards.id)

        // The handler heard of none of it but the two good requests.
        #expect(calls.commands == [.ping, .version])

        // And a new client is served as before.
        let fresh = try RawClient(path: socketURL)
        let last = request(.diagnostics)
        try await fresh.send(last)
        #expect(try await fresh.readReply()?.id == last.id)
    }

    @Test func anOverlongLineSentInPiecesIsAnsweredOnceAndSkipped() async throws {
        let server = makeServer()
        try server.start()
        defer { server.stop() }

        let client = try RawClient(path: socketURL)
        let piece = Data(repeating: UInt8(ascii: "y"), count: LineCodec.maxLineBytes / 2 + 1)
        await client.sendRaw(piece)
        await client.sendRaw(piece)
        expectBadRequest(try await client.readReply(), "Request too large")
        await client.sendRaw(piece)
        await client.sendRaw(Data("\n".utf8))

        let good = request(.ping)
        try await client.send(good)
        // The next reply is the good request's: the rest of the long line was dropped without a word.
        #expect(try await client.readReply()?.id == good.id)
    }

    @Test func aClientThatHangsUpInTheMiddleOfALineIsForgotten() async throws {
        let server = makeServer()
        try server.start()
        defer { server.stop() }

        do {
            let client = try RawClient(path: socketURL)
            await client.sendRaw(Data("{\"command\":".utf8))
        }

        let client = try RawClient(path: socketURL)
        let good = request(.ping)
        try await client.send(good)
        #expect(try await client.readReply()?.id == good.id)
    }

    @Test func clientThatHangsUpBeforeTheReplyDoesNotKillTheServer() async throws {
        // Writing to a socket the other end has closed raises SIGPIPE, which ends a process that doesn't ask otherwise:
        // the server asks, for each socket it accepts, so this test is still running at the end of it.
        let gate = Gate()
        let server = makeServer { command, _ in
            if case .version = command { await gate.wait() }
            return .ok(.string(command.name))
        }
        try server.start()
        defer { server.stop() }

        for _ in 0..<12 {
            let client = try RawClient(path: socketURL)
            try await client.send(request(.version))
            // It goes before the handler is done, and without reading anything.
        }
        await gate.open()

        let client = try RawClient(path: socketURL)
        let good = request(.ping)
        try await client.send(good)
        #expect(try await client.readReply()?.id == good.id)
    }


    // MARK: Clients that don't behave

    @Test func slowReaderIsClosedAfterOneSecond() async throws {
        // A reply far bigger than the socket's buffers, for a client that reads none of it.
        let big = String(repeating: "x", count: 4 << 20)
        let server = makeServer { command, _ in
            if case .diagnostics = command { return .ok(.string(big)) }
            return .ok(.string("handled \(command.name)"))
        }
        try server.start()
        defer { server.stop() }

        let slow = try RawClient(path: socketURL)
        let started = ContinuousClock.now
        try await slow.send(request(.diagnostics))

        // Meanwhile another client is answered at once: waiting for the slow one holds nobody else up.
        let other = try RawClient(path: socketURL)
        let ping = request(.ping)
        try await other.send(ping)
        #expect(try await other.readReply()?.id == ping.id)
        #expect(ContinuousClock.now - started < .seconds(1), "answered while the slow client was still being waited for")

        // The server gives up on the slow one and hangs up, which the client finds out by writing: its write fails then.
        var closedAfter: Duration?
        while ContinuousClock.now - started < .seconds(6) {
            if await !slow.sendRaw(Data(" ".utf8)) {
                closedAfter = ContinuousClock.now - started
                break
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        let elapsed = try #require(closedAfter, "the server never closed the connection")
        #expect(elapsed >= .milliseconds(900), "it waited the second: \(elapsed)")
        #expect(elapsed < .seconds(3), "and not much longer: \(elapsed)")
    }

    @Test func aReaderThatCatchesUpWithinTheSecondIsKept() async throws {
        // The second is for a client that has stopped reading, not one that is slow. (A line the client itself would call too long
        // is not what this is about, so the reply is big for a socket's buffers and not for a line.)
        let big = String(repeating: "x", count: 512 << 10)
        let server = makeServer { _, _ in .ok(.string(big)) }
        try server.start()
        defer { server.stop() }

        let client = try RawClient(path: socketURL)
        let asked = request(.diagnostics)
        try await client.send(asked)
        try await Task.sleep(for: .milliseconds(300))
        let reply = try await client.readReply()
        #expect(reply?.id == asked.id)
        #expect(reply?.result == .ok(.string(big)))
    }

    @Test func floodOfLinesIsCappedAndClosed() async throws {
        let gate = Gate()
        let server = makeServer { command, _ in
            // The first request holds the connection, so that nothing that follows it can be answered, and so is waiting.
            if case .version = command { await gate.wait() }
            return .ok(.string("handled \(command.name)"))
        }
        try server.start()
        defer { server.stop() }

        let client = try RawClient(path: socketURL)
        let held = request(.version)
        try await client.send(held)
        while calls.commands.isEmpty { try await Task.sleep(for: .milliseconds(5)) }

        var flood = Data()
        for _ in 0..<300 { flood.append(try LineCodec.encode(request(.ping))) }
        // Sent on the side: once the server has had enough it stops reading, and a write that is bigger than the socket's buffers
        // waits until the server closes the connection.
        let flooding = Task { await client.sendRaw(flood) }
        // The server reads what was sent at once; the lines past the 32 that can wait are not kept.
        try await Task.sleep(for: .milliseconds(300))
        await gate.open()

        var replies: [ReplyEnvelope] = []
        while let reply = try await client.readReply() { replies.append(reply) }

        #expect(replies.first?.id == held.id, "what it asked first is answered first")
        #expect(replies.last == ReplyEnvelope(id: nil, result: .failure(code: .badRequest, message: "Too many requests at once")))
        let answered = replies.dropLast().count
        #expect(answered <= 33, "the held request and the 32 that could wait were answered, no more: \(answered)")
        #expect(answered >= 2, "and what had been kept was answered: \(answered)")
        #expect(calls.commands.count == answered, "the handler heard of exactly the requests that were answered")
        // The connection was closed: nothing more comes, and what was still being sent has nowhere to go.
        #expect(try await client.readReply() == nil)
        #expect(await flooding.value == false)

        // And the server carries on with the next client.
        let fresh = try RawClient(path: socketURL)
        let good = request(.ping)
        try await fresh.send(good)
        #expect(try await fresh.readReply()?.id == good.id)
    }

    @Test func aBurstThatFitsIsAnsweredInFull() async throws {
        // The cap is for a flood: a client that sends 30 requests at once gets 30 answers.
        let server = makeServer()
        try server.start()
        defer { server.stop() }

        let requests = (0..<30).map { _ in request(.ping) }
        var batch = Data()
        for envelope in requests { batch.append(try LineCodec.encode(envelope)) }
        let client = try RawClient(path: socketURL)
        await client.sendRaw(batch)
        for envelope in requests {
            #expect(try await client.readReply()?.id == envelope.id)
        }
    }

    // MARK: Running out of descriptors

    @Test func acceptEMFILEPausesInsteadOfSpinning() async throws {
        let accepts = AcceptScript(failures: .max, error: EMFILE)
        let warnings = Mutex<[String]>([])
        let server = ControlSocketServer(path: socketURL, inspector: FakePeerInspector(peer: Fixtures.tool), own: Fixtures.own,
                                         accept: accepts.accept, pauseOnExhaustion: .seconds(1),
                                         warn: { message in warnings.withLock { $0.append(message) } }) { _, _ in .ok(.null) }
        try server.start()
        defer { server.stop() }

        // A client is waiting to be accepted, which makes the listening source ready for as long as it stays there. (The time is taken before
        // the client connects, so that a poll that notices the first try late, on a busy machine, can't make the second look too soon.)
        let first = ContinuousClock.now
        let waiting = try RawClient(path: socketURL)
        defer { withExtendedLifetime(waiting) {} }
        while accepts.count == 0 { try await Task.sleep(for: .milliseconds(5)) }

        // For the next half second the source isn't called at all: without the pause it would be called without end.
        try await Task.sleep(for: .milliseconds(500))
        #expect(accepts.count == 1, "called \(accepts.count) times in half a second")

        // After a second it tries again, once, and rests again.
        while accepts.count < 2, ContinuousClock.now - first < .seconds(5) { try await Task.sleep(for: .milliseconds(10)) }
        let gap = ContinuousClock.now - first
        #expect(accepts.count == 2)
        #expect(gap >= .milliseconds(900), "the second try was \(gap) after the first")
        // Said once, however long it lasts.
        #expect(warnings.withLock { $0 } == ["too many open files; pausing new connections for a second"])
    }

    @Test func aClientIsServedOnceDescriptorsAreBack() async throws {
        let accepts = AcceptScript(failures: 2, error: ENFILE)
        let warnings = Mutex<[String]>([])
        let server = ControlSocketServer(path: socketURL, inspector: FakePeerInspector(peer: Fixtures.tool), own: Fixtures.own,
                                         accept: accepts.accept, pauseOnExhaustion: .milliseconds(100),
                                         warn: { message in warnings.withLock { $0.append(message) } }) { command, _ in
            .ok(.string("handled \(command.name)"))
        }
        try server.start()
        defer { server.stop() }

        let client = try RawClient(path: socketURL)
        let asked = request(.ping)
        try await client.send(asked)
        #expect(try await client.readReply() == ReplyEnvelope(id: asked.id, result: .ok(.string("handled ping"))))
        #expect(accepts.count >= 3, "it failed twice and then accepted")
        #expect(warnings.withLock { $0.count } == 1, "one episode, one line")

        // The next time it runs out, that is a new episode, and is said again.
        accepts.fail(times: 1, error: EMFILE)
        let second = try RawClient(path: socketURL)
        let again = request(.version)
        try await second.send(again)
        #expect(try await second.readReply()?.id == again.id)
        #expect(warnings.withLock { $0.count } == 2)
    }

    @Test func stopWhileTheListenerRestsDoesNotHang() async throws {
        let accepts = AcceptScript(failures: .max, error: EMFILE)
        let server = ControlSocketServer(path: socketURL, inspector: FakePeerInspector(peer: Fixtures.tool), own: Fixtures.own,
                                         accept: accepts.accept, pauseOnExhaustion: .seconds(30), warn: { _ in }) { _, _ in .ok(.null) }
        try server.start()
        let waiting = try RawClient(path: socketURL)
        defer { withExtendedLifetime(waiting) {} }
        while accepts.count == 0 { try await Task.sleep(for: .milliseconds(5)) }
        // The source is suspended now, for half a minute. Stopping waits for it to finish being cancelled, which a suspended
        // source doesn't do until it is resumed.
        server.stop()
        #expect(!FileManager.default.fileExists(atPath: socketURL.path))
    }

    // MARK: The socket file

    @Test func socketFileIsMode0600() throws {
        let server = makeServer()
        try server.start()
        defer { server.stop() }

        var info = stat()
        #expect(lstat(socketURL.path, &info) == 0)
        #expect(info.st_mode & S_IFMT == S_IFSOCK, "it's a socket")
        #expect(info.st_mode & 0o777 == 0o600)
    }

    @Test(arguments: StaleThing.allCases)
    func staleSocketIsReplaced(stale: StaleThing) async throws {
        try stale.make(at: socketURL)

        let server = makeServer()
        try server.start()
        defer { server.stop() }

        let client = try RawClient(path: socketURL)
        let good = request(.ping)
        try await client.send(good)
        #expect(try await client.readReply()?.id == good.id)

        var info = stat()
        #expect(lstat(socketURL.path, &info) == 0)
        #expect(info.st_mode & 0o777 == 0o600)
    }

    @Test func liveSocketIsNotStolen() async throws {
        let first = makeServer { command, _ in .ok(.string("first: \(command.name)")) }
        try first.start()
        defer { first.stop() }

        let second = makeServer { command, _ in .ok(.string("second: \(command.name)")) }
        #expect(throws: SocketError.inUse) { try second.start() }
        // Stopping the one that never started must not remove the other's file.
        second.stop()

        let client = try RawClient(path: socketURL)
        let good = request(.ping)
        try await client.send(good)
        #expect(try await client.readReply() == ReplyEnvelope(id: good.id, result: .ok(.string("first: ping"))))

        // Once the first is gone the path is free for the second.
        first.stop()
        try await second.startWhenTheLockIsFree()
        defer { second.stop() }
        let again = try RawClient(path: socketURL)
        try await again.send(good)
        #expect(try await again.readReply() == ReplyEnvelope(id: good.id, result: .ok(.string("second: ping"))))
    }

    // MARK: The lock

    @Test func aHeldLockMeansInUseEvenWhenNothingListens() throws {
        // Another Mantel that is starting up has the lock but hasn't made its socket yet (or has bound it and not yet
        // started to listen, when a connection is refused). Connecting can't tell that from a leftover; the lock can.
        let other = try #require(LockHolder(url: lockURL))
        let server = makeServer()
        #expect(throws: SocketError.inUse) { try server.start() }
        #expect(!FileManager.default.fileExists(atPath: socketURL.path), "nothing was made")
        withExtendedLifetime(other) {}
    }

    @Test func aHeldLockProtectsASocketFileThatLooksLeftOver() throws {
        // The socket file is there and a connection to it is refused: without the lock it would look stale.
        leaveSocketFile(at: socketURL, listening: false)
        let before = try #require(inode(of: socketURL))
        let other = try #require(LockHolder(url: lockURL))

        let server = makeServer()
        #expect(throws: SocketError.inUse) { try server.start() }
        #expect(inode(of: socketURL) == before, "the file was not removed")
        withExtendedLifetime(other) {}
    }

    @Test func aLockFileNobodyHoldsHoldsNothing() async throws {
        // A run that ended badly leaves the lock file behind; its lock went with it.
        try Data().write(to: lockURL)
        leaveSocketFile(at: socketURL, listening: true)

        let server = makeServer()
        try server.start()
        defer { server.stop() }

        let client = try RawClient(path: socketURL)
        let good = request(.ping)
        try await client.send(good)
        #expect(try await client.readReply()?.id == good.id)

        var info = stat()
        #expect(lstat(lockURL.path, &info) == 0)
        #expect(info.st_mode & 0o777 == 0o600, "the lock file is private too")
    }

    @Test(arguments: StaleThing.allCases)
    func aServerSaysItReplacedAFileLeftBehind(thing: StaleThing) throws {
        // The app starts the server before its log has a file, so it asks the server and says it there.
        try thing.make(at: socketURL)
        let server = makeServer()
        #expect(!server.replacedLeftoverSocket, "nothing has been started")
        try server.start()
        defer { server.stop() }
        #expect(server.replacedLeftoverSocket)
    }

    @Test func aServerThatFoundNothingAtThePathSaysSo() throws {
        let server = makeServer()
        try server.start()
        defer { server.stop() }
        #expect(!server.replacedLeftoverSocket)
    }

    @Test func serversStartingAtTheSameTimeLeaveExactlyOne() async throws {
        let servers = (0..<8).map { _ in makeServer() }
        defer { servers.forEach { $0.stop() } }

        let outcomes = await withTaskGroup(of: (Int, SocketError?).self) { group in
            for (index, server) in servers.enumerated() {
                group.addTask {
                    do throws(SocketError) {
                        try server.start()
                        return (index, nil)
                    } catch {
                        return (index, error)
                    }
                }
            }
            var all: [(Int, SocketError?)] = []
            for await outcome in group { all.append(outcome) }
            return all
        }
        let winners = outcomes.filter { $0.1 == nil }.map(\.0)
        #expect(winners.count == 1)
        #expect(outcomes.filter { $0.1 != nil }.allSatisfy { $0.1 == .inUse })

        // The one that won is the one reachable at the path, and it removes its own file when it stops.
        let client = try RawClient(path: socketURL)
        let good = request(.ping)
        try await client.send(good)
        #expect(try await client.readReply()?.id == good.id)
        let winner = try #require(winners.first)
        servers[winner].stop()
        #expect(!FileManager.default.fileExists(atPath: socketURL.path))
    }

    @Test func stopReleasesTheLock() async throws {
        let server = makeServer()
        try server.start()
        #expect(LockHolder(url: lockURL) == nil, "a running server holds the lock")

        server.stop()
        let free = await LockHolder.takeWhenFree(url: lockURL)
        #expect(free != nil, "a stopped one doesn't")
        withExtendedLifetime(free) {}
    }

    @Test func aStopThenAStartByAnotherServerWorks() async throws {
        let first = makeServer { _, _ in .ok(.string("first")) }
        try first.start()
        first.stop()

        let second = makeServer { _, _ in .ok(.string("second")) }
        try await second.startWhenTheLockIsFree()
        defer { second.stop() }

        let client = try RawClient(path: socketURL)
        let good = request(.ping)
        try await client.send(good)
        #expect(try await client.readReply() == ReplyEnvelope(id: good.id, result: .ok(.string("second"))))
    }

    @Test func aFailedStartReleasesTheLock() async throws {
        // A folder at the socket's path can't be replaced, so binding fails after the lock was taken.
        try FileManager.default.createDirectory(at: socketURL, withIntermediateDirectories: false)
        let server = makeServer()
        #expect(throws: SocketError.bindFailed(EADDRINUSE)) { try server.start() }

        let free = await LockHolder.takeWhenFree(url: lockURL)
        #expect(free != nil)
        withExtendedLifetime(free) {}
    }

    @Test func pathTooLongIsRefused() throws {
        // The folder is `/tmp/mk-` and 8 hex digits: 16 bytes, then `/`, then the name. A socket path holds 103 bytes.
        let prefix = folder.url.path + "/"
        let fits = folder.url.appending(path: String(repeating: "a", count: 103 - prefix.utf8.count))
        let tooLong = folder.url.appending(path: String(repeating: "b", count: 104 - prefix.utf8.count))
        #expect(fits.path.utf8.count == 103)
        #expect(tooLong.path.utf8.count == 104)

        let refused = makeServer(at: tooLong)
        #expect(throws: SocketError.pathTooLong(104)) { try refused.start() }
        #expect(!FileManager.default.fileExists(atPath: tooLong.path))

        let allowed = makeServer(at: fits)
        try allowed.start()
        allowed.stop()
    }

    @Test func aFolderThatIsNotThereIsABindFailure() {
        let server = makeServer(at: folder.url.appending(path: "missing/s.sock"))
        #expect(throws: SocketError.bindFailed(ENOENT)) { try server.start() }
    }

    @Test func stopClosesClientsAndRemovesTheSocket() async throws {
        let server = makeServer()
        try server.start()
        defer { server.stop() }

        let client = try RawClient(path: socketURL)
        let good = request(.ping)
        try await client.send(good)
        #expect(try await client.readReply()?.id == good.id)

        server.stop()
        #expect(!FileManager.default.fileExists(atPath: socketURL.path))
        #expect(try await client.readReply() == nil, "the client sees the end")
        #expect(throws: RawClientError.self) { try RawClient(path: socketURL) }
        server.stop()  // a second stop is harmless
    }

    @Test func aStoppedServerCanBeStartedAgain() async throws {
        let server = makeServer()
        try server.start()
        try server.start()  // already running: nothing to do
        server.stop()
        // The lock can look held for a few milliseconds after `stop()` (the server's own doc says so), as it does for any server that starts
        // right after another: the wait the other tests use.
        try await server.startWhenTheLockIsFree()
        defer { server.stop() }

        let client = try RawClient(path: socketURL)
        let good = request(.ping)
        try await client.send(good)
        #expect(try await client.readReply()?.id == good.id)
    }

    @Test func stopLeavesAFileThatIsNotItsOwn() throws {
        let server = makeServer()
        try server.start()
        // Something else puts a file at the path after the server's socket was removed and made again.
        unlink(socketURL.path)
        try Data("not mine".utf8).write(to: socketURL)
        server.stop()
        #expect(FileManager.default.fileExists(atPath: socketURL.path))
    }
}

/// What may be at the socket's path when a server starts, left by a run that didn't clean up.
enum StaleThing: CaseIterable, Sendable, CustomTestStringConvertible {
    case regularFile, socketThatNeverListened, socketOfAListenerThatExited

    var testDescription: String {
        switch self {
        case .regularFile: "a regular file"
        case .socketThatNeverListened: "a socket that never listened"
        case .socketOfAListenerThatExited: "the socket of a listener that has exited"
        }
    }

    func make(at url: URL) throws {
        switch self {
        case .regularFile: try Data("left behind".utf8).write(to: url)
        case .socketThatNeverListened: leaveSocketFile(at: url, listening: false)
        case .socketOfAListenerThatExited: leaveSocketFile(at: url, listening: true)
        }
    }
}
