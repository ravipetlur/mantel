import Foundation
import MKTestSupport
import Testing

@Suite("TemporaryFolder", .timeLimit(.minutes(2)))
struct TemporaryFolderTests {
    private func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    @Test func existsWhileHeldAndIsGoneWithItsContentsWhenReleased() throws {
        var folder: TemporaryFolder? = TemporaryFolder()
        let url = try #require(folder?.url)
        #expect(exists(url))
        try Data("x".utf8).write(to: url.appending(path: "file.txt"))

        folder = nil
        #expect(!exists(url))
    }

    @Test func prefixNamesTheFolderAndEachFolderIsItsOwn() {
        let first = TemporaryFolder(prefix: "named")
        let second = TemporaryFolder(prefix: "named")
        #expect(first.url.lastPathComponent.hasPrefix("named-"))
        #expect(first.url != second.url)
    }

    @Test func shortForSocketsLeavesRoomForASocketFile() throws {
        var folder: TemporaryFolder? = TemporaryFolder.shortForSockets()
        let url = try #require(folder?.url)
        #expect(url.path.wholeMatch(of: /\/tmp\/mk-[0-9a-f]{8}/) != nil, "\(url.path) is /tmp/mk-<8 hex digits>")
        #expect(exists(url))
        // sun_path holds at most 103 bytes.
        #expect(url.appending(path: "s.sock").path.utf8.count <= 103)

        folder = nil
        #expect(!exists(url))
    }
}
