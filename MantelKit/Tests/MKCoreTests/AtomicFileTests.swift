import Foundation
import MKTestSupport
import Testing

@testable import MKCore

/// Writing a file whole, and what that does to the file it replaces. Mantel's own files are private to the owner; a file that
/// belongs to macOS keeps the mode, owner and extended attributes it had. Every test works on files in its own folder.
@Suite("Atomic file", .timeLimit(.minutes(1)))
struct AtomicFileTests {
    /// Held by the suite, and so for the whole test.
    let folder = TemporaryFolder(prefix: "mantel-atomic")

    private var target: URL { folder.url.appending(path: "target.plist") }

    private func mode(of url: URL) throws -> Int {
        try #require(FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int)
    }

    private func setExtendedAttribute(_ name: String, _ value: String, on url: URL) throws {
        let result = value.withCString { setxattr(url.path, name, $0, strlen($0), 0, 0) }
        try #require(result == 0, "the test's own file takes an extended attribute")
    }

    private func extendedAttribute(_ name: String, of url: URL) -> String? {
        let size = getxattr(url.path, name, nil, 0, 0, 0)
        guard size >= 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard getxattr(url.path, name, &buffer, size, 0, 0) == size else { return nil }
        return String(decoding: buffer, as: UTF8.self)
    }

    private func chmod(_ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(filePath: "/bin/chmod")
        process.arguments = arguments
        try process.run()
        process.waitUntilExit()
        try #require(process.terminationStatus == 0)
    }

    /// The names in the folder, hidden ones too.
    private func names() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: folder.url.path).sorted()
    }

    // MARK: Mantel's own files

    @Test func aFileOfMantelsOwnIsPrivateToTheOwnerWhateverTheOldOneHad() throws {
        try Data("old".utf8).write(to: target)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: target.path)

        try AtomicFile.write(Data("new".utf8), to: target)

        #expect(try mode(of: target) == 0o600)
        #expect(try Data(contentsOf: target) == Data("new".utf8))
        #expect(try names() == ["target.plist"])
    }

    @Test func aNewFileIsPrivateToTheOwnerWhoseverItIs() throws {
        for ownership in [AtomicFile.Ownership.mantel, .system] {
            let url = folder.url.appending(path: "new-\(ownership).plist")
            try AtomicFile.write(Data("x".utf8), to: url, ownership: ownership)
            #expect(try mode(of: url) == 0o600)
        }
    }

    // MARK: A file that isn't Mantel's

    @Test(arguments: [0o644, 0o640, 0o600, 0o664])
    func aFileOfTheSystemsKeepsItsMode(mode original: Int) throws {
        try Data("old".utf8).write(to: target)
        try FileManager.default.setAttributes([.posixPermissions: original], ofItemAtPath: target.path)

        try AtomicFile.write(Data("new".utf8), to: target, synchronize: true, ownership: .system)

        #expect(try mode(of: target) == original)
        #expect(try Data(contentsOf: target) == Data("new".utf8))
        #expect(try names() == ["target.plist"], "no temporary file is left")
    }

    @Test func aFileOfTheSystemsKeepsItsExtendedAttributes() throws {
        try Data("old".utf8).write(to: target)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: target.path)
        try setExtendedAttribute("com.example.mantel-test", "hello", on: target)

        try AtomicFile.write(Data("new".utf8), to: target, ownership: .system)

        #expect(extendedAttribute("com.example.mantel-test", of: target) == "hello")
        #expect(try mode(of: target) == 0o644)
    }

    @Test func aFileOfTheSystemsKeepsItsOwnerAndGroup() throws {
        try Data("old".utf8).write(to: target)
        var before = stat()
        try #require(stat(target.path, &before) == 0)

        try AtomicFile.write(Data("new".utf8), to: target, ownership: .system)

        var after = stat()
        try #require(stat(target.path, &after) == 0)
        #expect(after.st_uid == before.st_uid)
        #expect(after.st_gid == before.st_gid)
    }

    @Test func aFileOfTheSystemsGetsNewContentAndANewModificationTime() throws {
        // Something that watches the file (cfprefsd) is told by its modification time.
        try Data("old".utf8).write(to: target)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_000_000_000)], ofItemAtPath: target.path)

        try AtomicFile.write(Data("new".utf8), to: target, ownership: .system)

        let modified = try #require(FileManager.default.attributesOfItem(atPath: target.path)[.modificationDate] as? Date)
        #expect(modified > Date(timeIntervalSince1970: 1_000_000_000) + 86_400)
    }

    // MARK: Failing

    @Test(arguments: [AtomicFile.Ownership.mantel, .system])
    func noTemporaryFileIsLeftWhenTheReplaceFails(ownership: AtomicFile.Ownership) throws {
        // An ACL that forbids deleting the file makes the replace fail. With the original's metadata kept, the temporary file
        // takes on that ACL too, and so can't be deleted unless the ACL is taken off it first.
        try Data("old".utf8).write(to: target)
        try chmod(["+a", "everyone deny delete", target.path])
        defer { try? chmod(["-N", target.path]) }

        #expect(throws: (any Error).self) {
            try AtomicFile.write(Data("new".utf8), to: target, ownership: ownership)
        }

        #expect(try names() == ["target.plist"], "the temporary file went with the failure")
        #expect(try Data(contentsOf: target) == Data("old".utf8), "and the old file is as it was")
    }

    @Test(arguments: [AtomicFile.Ownership.mantel, .system])
    func nothingIsLeftWhenTheFolderCantBeWrittenTo(ownership: AtomicFile.Ownership) throws {
        try Data("old".utf8).write(to: target)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: folder.url.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.url.path) }

        #expect(throws: (any Error).self) {
            try AtomicFile.write(Data("new".utf8), to: target, ownership: ownership)
        }

        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.url.path)
        #expect(try names() == ["target.plist"])
        #expect(try Data(contentsOf: target) == Data("old".utf8))
    }
}
