import Darwin
import Foundation
import MKCore
import MKTestSupport
import Testing

@Suite("CanonicalPath", .timeLimit(.minutes(2)))
struct CanonicalPathTests {
    /// `/tmp/mk-…`, which the system reaches through `/private`.
    private let folder = TemporaryFolder.shortForSockets()

    private func file(_ name: String) throws -> URL {
        let url = folder.url.appending(path: name)
        try Data("x".utf8).write(to: url)
        return url
    }

    @Test func resolvesPrivateVar() throws {
        // /tmp and /var are links into /private. `URL.resolvingSymlinksInPath()` would turn the answer back into /tmp.
        let url = try file("a.plist")
        #expect(url.path.hasPrefix("/tmp/"))
        #expect(CanonicalPath.of(url) == "/private" + url.path)
        #expect(CanonicalPath.of(URL(filePath: "/var/tmp")) == "/private/var/tmp")
    }

    @Test func missingTailIsKept() {
        let url = folder.url.appending(path: "gone/deeper/file.plist")
        #expect(CanonicalPath.of(url) == "/private" + folder.url.path + "/gone/deeper/file.plist")
        // Nothing of the path exists but the root.
        #expect(CanonicalPath.of(URL(filePath: "/no-such-folder-here/x")) == "/no-such-folder-here/x")
        #expect(CanonicalPath.of(URL(filePath: "/")) == "/")
    }

    @Test func sameAsM1CanonicalForExistingFiles() throws {
        // For a file that is there, the answer is what the system's own `realpath` says: what the earlier per-file function
        // gave, whichever of the spellings it was asked about.
        let url = try file("b.plist")
        let direct = url.path
        let dotted = folder.url.appending(path: "x/../b.plist").path
        let link = folder.url.appending(path: "link.plist")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: url)
        let linkedFolder = folder.url.appending(path: "folder-link")
        try FileManager.default.createSymbolicLink(at: linkedFolder, withDestinationURL: folder.url)

        let expected = try #require(realpath(direct, nil).map { pointer in
            defer { free(pointer) }
            return String(cString: pointer)
        })
        for spelling in [direct, link.path, linkedFolder.appending(path: "b.plist").path] {
            #expect(CanonicalPath.of(URL(filePath: spelling)) == expected, "\(spelling)")
        }
        // `..` through a folder that doesn't exist is taken out too, as a standardized path says.
        #expect(CanonicalPath.of(URL(filePath: dotted)) == expected)
    }

    @Test func aTrailingSlashIsDropped() {
        let url = URL(filePath: folder.url.path + "/", directoryHint: .isDirectory)
        #expect(CanonicalPath.of(url) == "/private" + folder.url.path)
    }

    @Test func aLinkThatLeadsNowhereIsKeptAsItIs() throws {
        // A dangling link isn't a file, so it counts as the missing tail under the folder it is in.
        let link = folder.url.appending(path: "dangling")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: folder.url.appending(path: "nothing"))
        #expect(CanonicalPath.of(link) == "/private" + folder.url.path + "/dangling")
    }
}
