import Foundation
import MKTestSupport
import Synchronization
import Testing

@testable import MKCore

/// The calls a recording `FileSyncing` saw, in order.
private final class Events: Sendable {
    private let list = Mutex<[String]>([])

    func add(_ event: String) { list.withLock { $0.append(event) } }
    var all: [String] { list.withLock { $0 } }
}

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

    // MARK: Mantel's own files, and a file that isn't Mantel's

    /// A file of Mantel's own is private to the owner whatever the old one had; a file of the system's keeps its mode.
    @Test(arguments: [
        (AtomicFile.Ownership.mantel, 0o644, 0o600),
        (.system, 0o644, 0o644), (.system, 0o640, 0o640), (.system, 0o600, 0o600), (.system, 0o664, 0o664),
    ])
    func aFileKeepsItsModeIfItIsTheSystemsAndIsPrivateToTheOwnerIfItIsMantels(ownership: AtomicFile.Ownership, original: Int, expected: Int) throws {
        try Data("old".utf8).write(to: target)
        try FileManager.default.setAttributes([.posixPermissions: original], ofItemAtPath: target.path)

        try AtomicFile.write(Data("new".utf8), to: target, synchronize: true, ownership: ownership)

        #expect(try mode(of: target) == expected)
        #expect(try Data(contentsOf: target) == Data("new".utf8))
        #expect(try names() == ["target.plist"], "no temporary file is left")
    }

    @Test func aNewFileIsPrivateToTheOwnerWhoseverItIs() throws {
        for ownership in [AtomicFile.Ownership.mantel, .system] {
            let url = folder.url.appending(path: "new-\(ownership).plist")
            try AtomicFile.write(Data("x".utf8), to: url, ownership: ownership)
            #expect(try mode(of: url) == 0o600)
        }
    }

    // MARK: A file that isn't Mantel's

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

    // MARK: Durability

    /// A `FileSyncing` that notes each call with what the folder looked like at that moment.
    private func recordingSyncing(events: Events, target: URL, old: String, new: String) -> FileSyncing {
        @Sendable func holds(_ text: String) -> Bool { (try? Data(contentsOf: target)) == Data(text.utf8) }
        return FileSyncing(
            syncFile: { descriptor in
                events.add("file sync (open file: \(descriptor >= 0), target still \(old): \(holds(old)))")
            },
            syncFolder: { folder in
                events.add("folder sync (\(folder.lastPathComponent), target now \(new): \(holds(new)))")
            })
    }

    @Test(arguments: [AtomicFile.Ownership.mantel, .system])
    func fullSyncBeforeRenameThenFolderSync(ownership: AtomicFile.Ownership) throws {
        try Data("old".utf8).write(to: target)
        let events = Events()
        let syncing = recordingSyncing(events: events, target: target, old: "old", new: "new")

        try AtomicFile.write(Data("new".utf8), to: target, synchronize: true, ownership: ownership, syncing: syncing)

        #expect(events.all == [
            "file sync (open file: true, target still old: true)",
            "folder sync (\(folder.url.lastPathComponent), target now new: true)",
        ], "the data is synced while the old file is still in place, and the folder after the move")
        #expect(try Data(contentsOf: target) == Data("new".utf8))
    }

    @Test(arguments: [(synchronize: true, synced: ["file", "folder"]), (synchronize: false, synced: [String]())])
    func aNewFileIsSyncedTheSameWayAndNothingIsSyncedUnlessAskedFor(synchronize: Bool, synced: [String]) throws {
        let events = Events()
        let syncing = FileSyncing(
            syncFile: { _ in events.add("file") },
            syncFolder: { _ in events.add("folder") })
        try AtomicFile.write(Data("first".utf8), to: target, synchronize: synchronize, syncing: syncing)
        #expect(events.all == synced)
    }

    @Test func aSyncThatFailsLeavesTheOldFileAndNoTemporaryOne() throws {
        try Data("old".utf8).write(to: target)
        struct DiskFull: Error {}
        let syncing = FileSyncing(syncFile: { _ in throw DiskFull() }, syncFolder: { _ in })

        #expect(throws: DiskFull.self) {
            try AtomicFile.write(Data("new".utf8), to: target, synchronize: true, syncing: syncing)
        }
        #expect(try Data(contentsOf: target) == Data("old".utf8), "the file was never replaced")
        #expect(try names() == ["target.plist"])
    }

    @Test(arguments: [AtomicFile.Ownership.mantel, .system])
    func folderSyncFailureAfterRenameStillSucceeds(ownership: AtomicFile.Ownership) throws {
        try Data("old".utf8).write(to: target)
        struct NoFolderSync: Error {}
        let events = Events()
        let syncing = FileSyncing(
            syncFile: { _ in events.add("file") },
            syncFolder: { _ in
                events.add("folder")
                throw NoFolderSync()
            })

        // The file is replaced by then; a throw would tell the caller it wasn't, and its memory and the file would disagree.
        try AtomicFile.write(Data("new".utf8), to: target, synchronize: true, ownership: ownership, syncing: syncing)

        #expect(events.all == ["file", "folder"])
        #expect(try Data(contentsOf: target) == Data("new".utf8))
        #expect(try names() == ["target.plist"], "and no temporary file is left")
    }

    /// A drive or a file system that refuses F_FULLFSYNC gets a plain fsync: the write succeeds, and the file is the new one. One that
    /// takes the full sync is not followed by an fsync.
    @Test(arguments: [(fullSync: Int32(-1), synced: ["full", "fsync"]), (fullSync: Int32(0), synced: ["full"])])
    func aFullSyncThatFailsFallsBackToFsyncAndOneThatWorksIsNotFollowedByIt(fullSync: Int32, synced: [String]) throws {
        try Data("old".utf8).write(to: target)
        let events = Events()
        let syncing = FileSyncing.systemCalls(
            fullSync: { _ in
                events.add("full")
                return fullSync
            },
            fallbackSync: { _ in
                events.add("fsync")
                return 0
            })

        try AtomicFile.write(Data("new".utf8), to: target, synchronize: true, syncing: syncing)

        #expect(events.all == synced, "the full sync was tried first, and the plain one made only when it failed")
        #expect(try Data(contentsOf: target) == Data("new".utf8))
        #expect(try names() == ["target.plist"])
    }

    @Test func whenNeitherSyncWorksTheWriteFailsAndTheOldFileStays() throws {
        try Data("old".utf8).write(to: target)
        let syncing = FileSyncing.systemCalls(
            fullSync: { _ in -1 },
            fallbackSync: { _ in
                errno = ENOSPC
                return -1
            })

        #expect(throws: POSIXError(.ENOSPC)) {
            try AtomicFile.write(Data("new".utf8), to: target, synchronize: true, syncing: syncing)
        }
        #expect(try Data(contentsOf: target) == Data("old".utf8), "the file was never replaced")
        #expect(try names() == ["target.plist"], "and no temporary file is left")
    }

    @Test func theSystemsSyncingWorksOnARealFileAndFolder() throws {
        // Not a way to see that F_FULLFSYNC was used, only that the real calls succeed where a write is made.
        try AtomicFile.write(Data("durable".utf8), to: target, synchronize: true, syncing: .system)
        #expect(try Data(contentsOf: target) == Data("durable".utf8))
        try FileSyncing.system.syncFolder(folder.url)
        #expect(throws: (any Error).self) { try FileSyncing.system.syncFolder(folder.url.appending(path: "no-such-folder")) }
    }
}
