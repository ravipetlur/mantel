import Foundation
import MKCommands
import MKTestSupport
import Testing

@Suite("Control socket client", .timeLimit(.minutes(1)))
struct ControlSocketClientTests {
    /// Held for the whole test: the sockets live in it.
    private let folder = TemporaryFolder.shortForSockets()

    private var socketURL: URL { folder.url.appending(path: "s.sock") }

    private func startServer(peer: PeerInfo? = Fixtures.tool,
                             handler: @escaping @Sendable (MantelCommand) async -> CommandResult = { _ in .ok(.string("pong")) }
    ) throws -> ControlSocketServer {
        let server = ControlSocketServer(path: socketURL, inspector: FakePeerInspector(peer: peer),
                                         own: Fixtures.own) { command, _ in await handler(command) }
        try server.start()
        return server
    }

    @Test func sendsACommandAndReturnsTheAnswer() async throws {
        let server = try startServer { command in .ok(.string("answer to \(command.name)")) }
        defer { server.stop() }

        let client = ControlSocketClient(path: socketURL)
        #expect(try await client.send(.ping) == .ok(.string("answer to ping")))
        #expect(try await client.send(.openSettings(.hotkeys)) == .ok(.string("answer to settings")))
    }

    @Test func aFailureIsAnAnswerNotAnError() async throws {
        let server = try startServer { _ in .failure(code: .unavailable, message: "Probes aren't built yet") }
        defer { server.stop() }

        let result = try await ControlSocketClient(path: socketURL).send(.probe(.capture, options: [:]))
        #expect(result == .failure(code: .unavailable, message: "Probes aren't built yet"))
    }

    @Test func aRefusalIsTheAnswerToAClientTheAppRefused() async throws {
        let server = try startServer(peer: Fixtures.stranger)
        defer { server.stop() }

        let result = try await ControlSocketClient(path: socketURL).send(.ping)
        #expect(result == .failure(code: .rejected, message: "Not a Mantel tool: com.apple.Terminal"))
    }

    @Test func manyCommandsInARowAndAtOnce() async throws {
        let server = try startServer()
        defer { server.stop() }

        let client = ControlSocketClient(path: socketURL)
        for _ in 0..<10 {
            #expect(try await client.send(.version) == .ok(.string("pong")))
        }
        try await withThrowingTaskGroup(of: CommandResult.self) { group in
            for _ in 0..<6 {
                group.addTask { try await client.send(.version) }
            }
            for try await result in group {
                #expect(result == .ok(.string("pong")))
            }
        }
    }

    @Test func aBigAnswerIsReadWhole() async throws {
        let big = String(repeating: "0123456789", count: 20_000)
        let server = try startServer { _ in .ok(.string(big)) }
        defer { server.stop() }

        #expect(try await ControlSocketClient(path: socketURL).send(.diagnostics) == .ok(.string(big)))
    }

    // MARK: Nobody there

    @Test func noSocketMeansNotRunning() async {
        let client = ControlSocketClient(path: socketURL)
        await #expect(throws: ClientError.notRunning) { try await client.send(.ping) }
    }

    @Test(arguments: StaleThing.allCases)
    func aLeftoverFileMeansNotRunning(stale: StaleThing) async throws {
        try stale.make(at: socketURL)
        let client = ControlSocketClient(path: socketURL)
        await #expect(throws: ClientError.notRunning) { try await client.send(.ping) }
    }

    @Test func aServerThatHasStoppedMeansNotRunning() async throws {
        let server = try startServer()
        server.stop()
        let client = ControlSocketClient(path: socketURL)
        await #expect(throws: ClientError.notRunning) { try await client.send(.ping) }
    }

    @Test func aPathNoSocketCouldHaveMeansNotRunning() async {
        let client = ControlSocketClient(path: folder.url.appending(path: String(repeating: "x", count: 120)))
        await #expect(throws: ClientError.notRunning) { try await client.send(.ping) }
    }

    // MARK: Trouble

    @Test func anAppThatNeverAnswersTimesOut() async throws {
        let gate = Gate()
        let server = try startServer { _ in
            await gate.wait()
            return .ok(.null)
        }
        defer { server.stop() }

        let client = ControlSocketClient(path: socketURL)
        await #expect(throws: ClientError.timedOut) { try await client.send(.ping, timeout: .milliseconds(300)) }
        await gate.open()
    }

    @Test func aServerThatHangsUpWithoutAnsweringIsAProtocolError() async throws {
        let canned = CannedServer(path: socketURL, reply: nil)
        withExtendedLifetime(canned) {}
        let client = ControlSocketClient(path: socketURL)
        do {
            _ = try await client.send(.ping)
            Issue.record("expected a protocol error")
        } catch {
            guard case .protocolError = error else {
                Issue.record("expected a protocol error, got \(error)")
                return
            }
        }
    }

    @Test(arguments: ["this is not json\n", "[]\n", "{\"result\":{\"status\":\"maybe\"}}\n"])
    func anAnswerThatCannotBeReadIsAProtocolError(text: String) async throws {
        let canned = CannedServer(path: socketURL, reply: Data(text.utf8))
        withExtendedLifetime(canned) {}
        let client = ControlSocketClient(path: socketURL)
        do {
            _ = try await client.send(.ping)
            Issue.record("expected a protocol error")
        } catch {
            guard case .protocolError = error else {
                Issue.record("expected a protocol error, got \(error)")
                return
            }
        }
    }

    @Test func anAnswerToAnotherRequestIsAProtocolError() async throws {
        let stray = ReplyEnvelope(id: UUID(), result: .ok(.string("not for you")))
        let canned = CannedServer(path: socketURL, reply: try LineCodec.encode(stray))
        withExtendedLifetime(canned) {}
        let client = ControlSocketClient(path: socketURL)
        do {
            _ = try await client.send(.ping)
            Issue.record("expected a protocol error")
        } catch {
            guard case .protocolError = error else {
                Issue.record("expected a protocol error, got \(error)")
                return
            }
        }
    }

    @Test func anAnswerWithNoIdIsTheAnswerToThisRequest() async throws {
        let refusal = ReplyEnvelope(id: nil, result: .failure(code: .rejected, message: "No."))
        let canned = CannedServer(path: socketURL, reply: try LineCodec.encode(refusal))
        withExtendedLifetime(canned) {}
        #expect(try await ControlSocketClient(path: socketURL).send(.ping) == .failure(code: .rejected, message: "No."))
    }
}
