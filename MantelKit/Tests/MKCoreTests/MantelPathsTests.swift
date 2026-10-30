import Foundation
import MKCore
import MKTestSupport
import Testing

@Suite("MantelPaths")
struct MantelPathsTests {
    private let fileManager = FileManager.default

    /// Folders under a temporary folder of the test's own, shaped like the live ones.
    private func makePaths(in folder: TemporaryFolder) -> MantelPaths {
        MantelPaths(root: folder.url.appending(path: "Application Support/Mantel", directoryHint: .isDirectory),
                    logs: folder.url.appending(path: "Logs/Mantel", directoryHint: .isDirectory))
    }

    private func permissions(of url: URL) throws -> Int? {
        try fileManager.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
    }

    private func isFolder(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    @Test func subfoldersHangOffRoot() {
        let paths = MantelPaths(root: URL(filePath: "/Example/Support/Mantel", directoryHint: .isDirectory),
                                logs: URL(filePath: "/Example/Logs/Mantel", directoryHint: .isDirectory))
        #expect(paths.root.path == "/Example/Support/Mantel")
        #expect(paths.logs.path == "/Example/Logs/Mantel")
        #expect(paths.settings.path == "/Example/Support/Mantel")
        #expect(paths.backups.path == "/Example/Support/Mantel/Backups")
        #expect(paths.probes.path == "/Example/Support/Mantel/Probes")
        #expect(paths.itemImages.path == "/Example/Support/Mantel/ItemImages")
        #expect(paths.ownImages.path == "/Example/Support/Mantel/OwnImages")
        #expect(paths.journalFile.path == "/Example/Support/Mantel/journal.json")
        #expect(paths.controlSocket.path == "/Example/Support/Mantel/control.sock")
    }

    @Test func createDirectoriesMakesThemPrivate() throws {
        let folder = TemporaryFolder()
        let paths = makePaths(in: folder)
        try paths.createDirectories()
        for url in [paths.root, paths.logs, paths.backups, paths.probes, paths.itemImages, paths.ownImages] {
            #expect(isFolder(url), "\(url.path) is a folder")
            #expect(try permissions(of: url) == 0o700, "\(url.path) is private")
        }
    }

    @Test func createDirectoriesTightensAFolderThatIsTooOpen() throws {
        let folder = TemporaryFolder()
        let paths = makePaths(in: folder)
        try fileManager.createDirectory(at: paths.backups, withIntermediateDirectories: true,
                                        attributes: [.posixPermissions: 0o755])
        try paths.createDirectories()
        #expect(try permissions(of: paths.backups) == 0o700)
        // A second call changes nothing and doesn't fail.
        try paths.createDirectories()
        #expect(try permissions(of: paths.backups) == 0o700)
        #expect(try permissions(of: paths.root) == 0o700)
    }

    @Test func liveUsesApplicationSupportAndLogs() {
        // The paths are compared as text and nothing is looked up: the live folders are the person's own, and this test must not
        // make them or read them.
        let home = fileManager.homeDirectoryForCurrentUser.path
        let live = MantelPaths.live()
        #expect(live.root.path.hasSuffix("Library/Application Support/Mantel"))
        #expect(live.logs.path.hasSuffix("Library/Logs/Mantel"))
        #expect(live.root.path == "\(home)/Library/Application Support/Mantel")
        #expect(live.logs.path == "\(home)/Library/Logs/Mantel")
    }
}
