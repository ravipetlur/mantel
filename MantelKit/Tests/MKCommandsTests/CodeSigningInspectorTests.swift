import Darwin
import Foundation
import MKCommands
import MKTestSupport
import Security
import Testing

@Suite("Code signing inspector", .timeLimit(.minutes(1)))
struct CodeSigningInspectorTests {
    /// Held for the whole test: the socket lives in it.
    private let folder = TemporaryFolder.shortForSockets()

    private var socketURL: URL { folder.url.appending(path: "s.sock") }

    /// A listening socket and a client connected to it; `accepted` is the server's end, which the inspector is given.
    /// The caller closes `listener` and `accepted`.
    private func connect() throws -> (listener: Int32, accepted: Int32, client: RawClient) {
        unlink(socketURL.path)  // a test may connect more than once
        let listener = socket(AF_UNIX, SOCK_STREAM, 0)
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: Array(socketURL.path.utf8)) }
        _ = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        listen(listener, 1)
        let client: RawClient
        do {
            client = try RawClient(path: socketURL)
        } catch {
            close(listener)
            throw error
        }
        return (listener, accept(listener, nil, nil), client)
    }

    @Test func describesTheProcessOnTheOtherEnd() throws {
        // The client is this very process, so what the inspector finds out can be checked against what is known.
        let connection = try connect()
        defer {
            close(connection.accepted)
            close(connection.listener)
        }
        let found = CodeSigningInspector().inspect(socket: connection.accepted)
        let peer = try #require(found)
        #expect(peer.pid == getpid())
        #expect(peer.executablePath?.hasPrefix("/") == true, "the program's path: \(peer.executablePath ?? "nil")")
        #expect(peer.isValidSignature, "a program that is running with a signature the system accepts")
        #expect(peer.signingIdentifier?.isEmpty == false, "it is signed with an identifier: \(peer.signingIdentifier ?? "nil")")
    }

    // MARK: Requirements

    private func inspectThisProcess(_ inspector: CodeSigningInspector) throws -> PeerInfo {
        let connection = try connect()
        defer {
            close(connection.accepted)
            close(connection.listener)
        }
        let found = inspector.inspect(socket: connection.accepted)
        return try #require(found)
    }

    @Test func aRequirementThePeerMeetsLeavesItsIdentity() throws {
        let plain = try inspectThisProcess(CodeSigningInspector())
        let identifier = try #require(plain.signingIdentifier)
        // Quotes, in case the identifier has any.
        let requirement = "identifier \"\(identifier.replacing("\"", with: "\\\""))\""

        let checked = try inspectThisProcess(CodeSigningInspector(requirement: requirement))
        #expect(checked.isValidSignature)
        #expect(checked.signingIdentifier == identifier)
        #expect(checked.executablePath == plain.executablePath)
    }

    @Test func aRequirementThePeerFailsMakesItInvalid() throws {
        let checked = try inspectThisProcess(CodeSigningInspector(requirement: #"identifier "com.example.nobody""#))
        #expect(!checked.isValidSignature)
        #expect(checked.signingIdentifier == nil)
        #expect(checked.teamIdentifier == nil)
        #expect(checked.pid == getpid(), "who it was is still known, for the log")
    }

    @Test func aRequirementThatCannotBeReadRefusesEveryone() throws {
        let checked = try inspectThisProcess(CodeSigningInspector(requirement: "this is not a requirement"))
        #expect(!checked.isValidSignature)
        #expect(checked.signingIdentifier == nil)
    }

    @Test func theTeamRequirementIsOneTheSystemCanRead() {
        // A typo in the requirement would refuse Mantel's own tool, so the text is checked against the real parser.
        let text = PeerPolicy.requirement(for: PeerPolicyTests.teamBuild)
        var requirement: SecRequirement?
        let status = SecRequirementCreateWithString((text ?? "") as CFString, SecCSFlags(), &requirement)
        #expect(text != nil)
        #expect(status == errSecSuccess, "SecRequirementCreateWithString said \(status) for: \(text ?? "nil")")
        #expect(requirement != nil)
    }

    @Test func theAppsPathAndAPeersPathAreWrittenTheSameWay() throws {
        // This process is both the app (whose "bundle" is the folder its program is in, as it is no app) and the peer
        // that connects to it. Given the identifier the policy wants, the policy accepts it only if the two paths, one
        // from `Bundle.main` and one from the code signing system, agree on where that is.
        let connection = try connect()
        defer {
            close(connection.accepted)
            close(connection.listener)
        }
        let found = CodeSigningInspector().inspect(socket: connection.accepted)
        let real = try #require(found)
        let own = OwnSigningReader.current()
        let adHoc = OwnSigning(bundleIdentifier: own.bundleIdentifier, teamIdentifier: nil, bundlePath: own.bundlePath)
        let asItsOwnTool = PeerInfo(pid: real.pid, signingIdentifier: "\(own.bundleIdentifier).cli", teamIdentifier: nil,
                                    isValidSignature: real.isValidSignature, executablePath: real.executablePath)
        #expect(PeerPolicy.decide(asItsOwnTool, own: adHoc) == .accept,
                "the app is at \(own.bundlePath), and the peer at \(real.executablePath ?? "nil")")

        let elsewhere = OwnSigning(bundleIdentifier: own.bundleIdentifier, teamIdentifier: nil,
                                   bundlePath: "/nonexistent/Mantel.app")
        #expect(PeerPolicy.decide(asItsOwnTool, own: elsewhere) != .accept)
    }

    @Test func aSocketThatIsNotConnectedHasNoPeer() throws {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        defer { close(fd) }
        #expect(CodeSigningInspector().inspect(socket: fd) == nil)
    }

    @Test func somethingThatIsNotASocketHasNoPeer() {
        var pipeEnds: [Int32] = [0, 0]
        #expect(pipe(&pipeEnds) == 0)
        defer { pipeEnds.forEach { close($0) } }
        #expect(CodeSigningInspector().inspect(socket: pipeEnds[0]) == nil)
        #expect(CodeSigningInspector().inspect(socket: -1) == nil)
    }

    @Test func theAppKnowsHowItIsSigned() {
        let own = OwnSigningReader.current()
        #expect(!own.bundleIdentifier.isEmpty)
        #expect(own.bundlePath.hasPrefix("/"))
        #expect(!own.bundlePath.hasSuffix("/"))
        #expect(own.teamIdentifier?.isEmpty != true, "a team, or none; never an empty one")
    }
}
