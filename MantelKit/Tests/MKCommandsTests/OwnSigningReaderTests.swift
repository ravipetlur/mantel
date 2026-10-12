import Darwin
import Foundation
import MKCore
import MKTestSupport
import Testing

@testable import MKCommands

/// How the app tells its own tool, against real code signatures: small apps made and signed ad hoc in a temporary folder.
@Suite("Own signing reader", .timeLimit(.minutes(1)), .enabled(if: MiniApp.canSign, "codesign is needed to make the apps"))
struct OwnSigningReaderTests {
    @Test func theSealedHashIsTheToolsOwn() throws {
        let app = try MiniApp()
        let hash = try #require(OwnSigningReader.sealedHelperHash(inAppAt: app.appURL))
        // What the `codesign` program says, which doesn't come from the code under test.
        #expect(hash == (try MiniApp.codeDirectoryHash(of: app.helperURL)))
        #expect(hash.allSatisfy { $0.isHexDigit && !$0.isUppercase }, "lowercase hex: \(hash)")
    }

    @Test func theSealedHashIsTheOneTheAppsSignatureRecordsForTheTool() throws {
        // Read from the seal itself: the resource list the app's signature covers, which names the tool and its hash.
        let app = try MiniApp()
        let resources = app.appURL.appending(path: "Contents/_CodeSignature/CodeResources")
        let list = try #require(PropertyListSerialization.propertyList(from: Data(contentsOf: resources), format: nil) as? [String: Any])
        let files = try #require(list["files2"] as? [String: Any])
        let entry = try #require(files["Helpers/mantel"] as? [String: Any], "the tool is sealed as a piece of code")
        let sealed = try #require(entry["cdhash"] as? Data)

        let hash = try #require(OwnSigningReader.sealedHelperHash(inAppAt: app.appURL))
        #expect(hash == sealed.map { String(format: "%02x", $0) }.joined())
    }

    @Test func aToolSwappedAfterTheAppWasSignedGivesNoHash() throws {
        let app = try MiniApp()
        #expect(OwnSigningReader.sealedHelperHash(inAppAt: app.appURL) != nil)

        // Another program, signed well, with the same identifier: it would pass for the tool if the hash were read from its
        // file. It isn't what the app sealed.
        try app.swapHelper(for: "/usr/bin/false", identifier: "com.example.mini.cli")
        #expect(OwnSigningReader.sealedHelperHash(inAppAt: app.appURL) == nil)
        // The tool's own signature is perfectly valid, which is why the check can't be left to it.
        #expect(try MiniApp.run("/usr/bin/codesign", ["--verify", app.helperURL.path]) == "")
    }

    @Test func aToolWhoseSignatureWasRemovedGivesNoHash() throws {
        let app = try MiniApp()
        #expect(OwnSigningReader.sealedHelperHash(inAppAt: app.appURL) != nil)
        try MiniApp.run("/usr/bin/codesign", ["--remove-signature", app.helperURL.path])
        #expect(OwnSigningReader.sealedHelperHash(inAppAt: app.appURL) == nil)
    }

    @Test func anAppThatIsNotSignedGivesNoHash() throws {
        let app = try MiniApp(signApp: false)
        #expect(OwnSigningReader.sealedHelperHash(inAppAt: app.appURL) == nil)
    }

    @Test func anAppWithoutAToolGivesNoHash() throws {
        let app = try MiniApp(withHelper: false)
        #expect(OwnSigningReader.sealedHelperHash(inAppAt: app.appURL) == nil)
        #expect(OwnSigningReader.sealedHelperHash(inAppAt: app.folder.url.appending(path: "Nothing.app")) == nil)
    }

    @Test func aFolderThatIsNotAnAppGivesNoHash() {
        #expect(OwnSigningReader.sealedHelperHash(inAppAt: URL(filePath: "/tmp", directoryHint: .isDirectory)) == nil)
    }

    // MARK: The whole of it, with a program that connects

    /// The tool's place, hash and identifier as a connected program shows them to the inspector, and what the policy says.
    private struct Connection {
        let peer: PeerInfo
        let decision: PeerDecision
    }

    /// Starts the tool of `app` (a program that connects, signed in as the tool) so that it connects to a socket of the test's, and has
    /// `own` decide about the peer the inspector finds.
    private func connect(from app: MiniApp, decidingWith own: OwnSigning) throws -> Connection {
        let socketPath = app.folder.url.appending(path: "s.sock").path
        let listener = socket(AF_UNIX, SOCK_STREAM, 0)
        defer { close(listener) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: Array(socketPath.utf8)) }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        try #require(bound == 0)
        try #require(listen(listener, 1) == 0)

        let process = Process()
        process.executableURL = app.helperURL
        process.arguments = [socketPath]
        // Kept open, so that the program stays connected until the test is done with it.
        let input = Pipe()
        process.standardInput = input
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        defer {
            try? input.fileHandleForWriting.close()
            process.terminate()
            process.waitUntilExit()
        }

        var ready = pollfd(fd: listener, events: Int16(POLLIN), revents: 0)
        try #require(poll(&ready, 1, 10_000) == 1, "the program connected")
        let accepted = accept(listener, nil, nil)
        try #require(accepted >= 0)
        defer { close(accepted) }
        let peer = try #require(CodeSigningInspector().inspect(socket: accepted))
        return Connection(peer: peer, decision: PeerPolicy.decide(peer, own: own))
    }

    @Test(.enabled(if: MiniApp.canCompileConnector, "clang and an arm64 Mac are needed to build the program that connects"))
    func theRealToolIsAcceptedByItsAppAndNoOtherProgramIs() throws {
        let tools = TemporaryFolder()
        // The program compiled in it is copied into apps below, and `tools` isn't read again: held until the test is over.
        defer { withExtendedLifetime(tools) {} }
        let connector = try MiniApp.compileConnector(variant: 1, in: tools)
        let app = try MiniApp(helper: connector, identifier: "com.example.mini.cli")
        let hash = try #require(OwnSigningReader.sealedHelperHash(inAppAt: app.appURL))
        let own = OwnSigning(bundleIdentifier: "com.example.mini", teamIdentifier: nil,
                             bundlePath: CanonicalPath.of(app.appURL), helperCodeDirectoryHash: hash)
        #expect(own.helperCanonicalPath == CanonicalPath.of(app.helperURL))

        let real = try connect(from: app, decidingWith: own)
        #expect(real.peer.isValidSignature)
        #expect(real.peer.signingIdentifier == "com.example.mini.cli")
        #expect(real.peer.canonicalPath == own.helperCanonicalPath, "\(real.peer.canonicalPath ?? "nil") and \(own.helperCanonicalPath)")
        #expect(real.peer.codeDirectoryHash == hash)
        #expect(real.decision == .accept)

        // Another app's tool is a perfectly good tool of that app, and is not this app's.
        let other = try MiniApp(helper: connector, identifier: "com.example.mini.cli")
        let impostor = try connect(from: other, decidingWith: own)
        #expect(impostor.peer.isValidSignature)
        #expect(impostor.peer.signingIdentifier == "com.example.mini.cli")
        #expect(impostor.decision == .reject("Not a Mantel tool: com.example.mini.cli"))
    }

    @Test(.enabled(if: MiniApp.canCompileConnector, "clang and an arm64 Mac are needed to build the program that connects"))
    func aToolThatIsNotWhatTheAppSealedIsRefusedWhereverItIs() throws {
        let tools = TemporaryFolder()
        // The program compiled in it is copied into apps below, and `tools` isn't read again: held until the test is over.
        defer { withExtendedLifetime(tools) {} }
        let sealing = try MiniApp(helper: try MiniApp.compileConnector(variant: 2, in: tools), identifier: "com.example.mini.cli")
        let sealed = try #require(OwnSigningReader.sealedHelperHash(inAppAt: sealing.appURL))

        // The program that connects is at the place `own` names, and is signed with the identifier it wants; its hash is not the
        // one the app sealed.
        let app = try MiniApp(helper: try MiniApp.compileConnector(variant: 3, in: tools), identifier: "com.example.mini.cli")
        let own = OwnSigning(bundleIdentifier: "com.example.mini", teamIdentifier: nil, bundlePath: CanonicalPath.of(app.appURL),
                             helperCodeDirectoryHash: sealed)
        let connection = try connect(from: app, decidingWith: own)
        #expect(connection.peer.canonicalPath == own.helperCanonicalPath)
        #expect(connection.peer.codeDirectoryHash != sealed)
        #expect(connection.decision == .reject("Not a Mantel tool: com.example.mini.cli"))
    }
}
