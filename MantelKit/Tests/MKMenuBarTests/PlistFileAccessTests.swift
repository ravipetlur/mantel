import Foundation
import MKCore
import MKTestSupport
import Synchronization
import Testing

@testable import MKMenuBar

/// A restorer that tells a test it has been asked to restore, then waits to be let go.
private struct BlockingRestorer: JournalRestoring {
    let entered: Gate
    let release: Gate

    func restore(_ entry: JournalEntry) async throws {
        entered.open()
        await release.wait()
    }
}

/// Every test makes its own folder with the files it needs, writes only there, and the folder goes away with the test.
/// Nothing here touches a real preferences file: `cfPreferences` is given the temporary file's path as its domain.
@Suite("Plist file access", .timeLimit(.minutes(1)))
struct PlistFileAccessTests {
    /// Held by the suite, and so for the whole test.
    let folder = TemporaryFolder(prefix: "mantel-plist")
    let clock = FakeClock()

    private var journalFile: URL { folder.url.appending(path: "journal.json") }
    private var plist: URL { folder.url.appending(path: "sample.plist") }
    private func makeJournal() -> Journal { Journal(file: journalFile, clock: clock) }
    /// Mantel's folders for the test, so that the backups a write makes go to its own folder.
    private var paths: MantelPaths {
        MantelPaths(root: folder.url.appending(path: "Mantel", directoryHint: .isDirectory),
                    logs: folder.url.appending(path: "Logs", directoryHint: .isDirectory))
    }
    private func makeAccess(_ journal: Journal) -> PlistFileAccess { PlistFileAccess(journal: journal, paths: paths) }

    private func writePlist(_ dictionary: [String: Any], to url: URL? = nil, format: PropertyListSerialization.PropertyListFormat = .xml) throws {
        let data = try PropertyListSerialization.data(fromPropertyList: dictionary, format: format, options: 0)
        try data.write(to: url ?? plist)
    }

    private func onDisk(_ url: URL? = nil) throws -> [String: Any] {
        let data = try Data(contentsOf: url ?? plist)
        return try #require(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
    }

    private func resolved(_ url: URL) -> String { url.resolvingSymlinksInPath().path(percentEncoded: false) }

    // MARK: Reading

    @Test func readTopLevelReturnsTheKeysWithTheirValues() throws {
        try writePlist(["name": "x", "count": 3, "flag": true, "nested": ["a": [1, 2]]])
        let access = makeAccess(makeJournal())
        let top = try access.readTopLevel(plist)
        #expect(top["name"] == .string("x"))
        #expect(top["count"] == .integer(3))
        #expect(top["flag"] == .bool(true))
        #expect(top["nested"] == .dictionary(["a": .array([.integer(1), .integer(2)])]))
    }

    @Test func aFileThatIsNotADictionaryIsRefused() throws {
        let data = try PropertyListSerialization.data(fromPropertyList: [1, 2, 3], format: .xml, options: 0)
        try data.write(to: plist)
        #expect(throws: PlistAccessError.notADictionary) { try makeAccess(makeJournal()).readTopLevel(plist) }
    }

    @Test func aMissingFileCantBeRead() {
        #expect(throws: PlistAccessError.self) { try makeAccess(makeJournal()).readTopLevel(plist) }
    }

    // MARK: Writing

    @Test func atomicWriteRoundTrips() async throws {
        try writePlist(["keep": "me", "alpha": 1])
        let journal = makeJournal()
        let access = makeAccess(journal)

        try await access.write(.integer(5), key: "alpha", in: plist, strategy: .atomicFile)

        let top = try access.readTopLevel(plist)
        #expect(top["alpha"] == .integer(5))
        #expect(top["keep"] == .string("me"), "the other keys are as they were")
        // Written as a binary plist.
        #expect(try Data(contentsOf: plist).prefix(8) == Data("bplist00".utf8))
        // The journal holds the original, under the file's own path, with the strategy.
        let records = await journal.records()
        #expect(records.map(\.entry) == [.plistKey(filePath: resolved(plist), key: "alpha", original: .integer(1), strategy: .atomicFile)])
    }

    @Test func anAtomicWriteKeepsTheFilesModeAndExtendedAttributes() async throws {
        // A file of macOS's is rewritten the way macOS would: not with the private mode of Mantel's own files, and not without
        // the attributes it had.
        try writePlist(["keep": "me", "alpha": 1])
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: plist.path)
        let attribute = "com.example.mantel-test"
        let set = "hello".withCString { setxattr(plist.path, attribute, $0, strlen($0), 0, 0) }
        try #require(set == 0)
        let access = makeAccess(makeJournal())

        try await access.write(.integer(5), key: "alpha", in: plist, strategy: .atomicFile)

        #expect(try access.readTopLevel(plist)["alpha"] == .integer(5))
        #expect(try FileManager.default.attributesOfItem(atPath: plist.path)[.posixPermissions] as? Int == 0o644)
        var buffer = [UInt8](repeating: 0, count: 16)
        let size = getxattr(plist.path, attribute, &buffer, buffer.count, 0, 0)
        #expect(size == 5 && String(decoding: buffer.prefix(5), as: UTF8.self) == "hello")
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: folder.url.path).filter { $0.hasSuffix(".tmp") }
        #expect(leftovers.isEmpty, "no temporary file is left")
    }

    @Test func theRestoreOfAnAtomicWriteKeepsThemToo() async throws {
        try writePlist(["alpha": 1])
        try FileManager.default.setAttributes([.posixPermissions: 0o640], ofItemAtPath: plist.path)
        let journal = makeJournal()
        let access = makeAccess(journal)
        try await access.write(.integer(5), key: "alpha", in: plist, strategy: .atomicFile)
        try await access.undo(key: "alpha", in: plist)

        #expect(try onDisk()["alpha"] as? Int == 1)
        #expect(try FileManager.default.attributesOfItem(atPath: plist.path)[.posixPermissions] as? Int == 0o640)
    }

    @Test func cfPreferencesWriteRoundTrips() async throws {
        try writePlist(["keep": "me", "alpha": 1])
        let journal = makeJournal()
        let access = makeAccess(journal)

        try await access.write(.integer(5), key: "alpha", in: plist, strategy: .cfPreferences)

        let top = try access.readTopLevel(plist)
        #expect(top["alpha"] == .integer(5))
        #expect(top["keep"] == .string("me"))
        let records = await journal.records()
        #expect(records.map(\.entry) == [.plistKey(filePath: resolved(plist), key: "alpha", original: .integer(1), strategy: .cfPreferences)])
    }

    @Test func aWriteCanSetADictionaryAndABoolean() async throws {
        try writePlist(["alpha": 1])
        let access = makeAccess(makeJournal())
        let value = PlistValue.dictionary(["x": .bool(false), "y": .array([.string("s"), .real(1.5)])])
        try await access.write(value, key: "alpha", in: plist, strategy: .atomicFile)
        #expect(try access.readTopLevel(plist)["alpha"] == value)
    }

    @Test func writingNilRemovesTheKey() async throws {
        try writePlist(["keep": 1, "gone": "bye"])
        let access = makeAccess(makeJournal())
        try await access.write(nil, key: "gone", in: plist, strategy: .atomicFile)
        #expect(try onDisk().keys.sorted() == ["keep"])
    }

    @Test func whenTheJournalCantRecordNothingIsChanged() async throws {
        try writePlist(["alpha": 1])
        // The journal's folder can't be written to, so it can't record; the plist's folder can be written to, so a write that
        // was made all the same would show.
        let journalFolder = folder.url.appending(path: "journal-folder", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: journalFolder, withIntermediateDirectories: false)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: journalFolder.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: journalFolder.path) }
        let access = makeAccess(Journal(file: journalFolder.appending(path: "journal.json"), clock: clock))

        await #expect(throws: (any Error).self) {
            try await access.write(.integer(2), key: "alpha", in: plist, strategy: .atomicFile)
        }
        #expect(try onDisk()["alpha"] as? Int == 1, "the change is made only once the record is on disk")
    }

    @Test func aFailedWriteLeavesTheRecordForTheNextLaunch() async throws {
        let target = folder.url.appending(path: "locked", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
        let file = target.appending(path: "sample.plist")
        try writePlist(["alpha": 1], to: file)
        let journal = makeJournal()
        let access = makeAccess(journal)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: target.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: target.path) }

        await #expect(throws: (any Error).self) {
            try await access.write(.integer(2), key: "alpha", in: file, strategy: .atomicFile)
        }
        #expect(try onDisk(file)["alpha"] as? Int == 1)
        #expect(await journal.records().count == 1, "recorded before it was tried, so the restore of a half-done change can run")
    }

    @Test func aWriteThatDoesntStickThrowsNotPersisted() async throws {
        try writePlist(["alpha": 1])
        // A system that says it wrote and then reads back the old value.
        var io = PlistIO.system
        io.write = { _, _, _, _ in }
        let access = PlistFileAccess(journal: makeJournal(), paths: paths, grants: nil, io: io)
        await #expect(throws: PlistAccessError.notPersisted(key: "alpha")) {
            try await access.write(.integer(9), key: "alpha", in: plist, strategy: .atomicFile)
        }
    }

    @Test func aValueTheJournalCantKeepIsNotChanged() async throws {
        // A key whose value isn't a property list type of ours can't be put back, so nothing is written over it.
        var io = PlistIO.system
        io.read = { _, _, _ in throw PlistAccessError.notRepresentable(key: "alpha") }
        let access = PlistFileAccess(journal: makeJournal(), paths: paths, grants: nil, io: io)
        try writePlist(["alpha": 1])
        await #expect(throws: PlistAccessError.notRepresentable(key: "alpha")) {
            try await access.write(.integer(9), key: "alpha", in: plist, strategy: .atomicFile)
        }
        #expect(try onDisk()["alpha"] as? Int == 1)
    }

    // MARK: Symlinks

    @Test func aSymlinkIsWrittenThroughNotReplaced() async throws {
        let real = folder.url.appending(path: "real.plist")
        let link = folder.url.appending(path: "link.plist")
        try writePlist(["alpha": 1], to: real)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        let journal = makeJournal()
        let access = makeAccess(journal)

        try await access.write(.integer(7), key: "alpha", in: link, strategy: .atomicFile)

        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: link.path) == real.path, "the link is still a link")
        #expect(try onDisk(real)["alpha"] as? Int == 7)
        let records = await journal.records()
        #expect(records.map(\.entry) == [.plistKey(filePath: resolved(real), key: "alpha", original: .integer(1), strategy: .atomicFile)],
                "the journal names the file, not the link")
    }

    // MARK: Replay

    @Test(arguments: [PlistWriteStrategy.atomicFile, .cfPreferences])
    func journaledWriteIsUndoneByReplay(strategy: PlistWriteStrategy) async throws {
        try writePlist(["keep": "me", "alpha": 1])
        let journal = makeJournal()
        let access = makeAccess(journal)
        try await access.write(.integer(5), key: "alpha", in: plist, strategy: strategy)

        // As after a crash: a new journal on the same file, and a restorer.
        let restarted = Journal(file: journalFile, clock: clock)
        let restorer = PlistJournalRestorer(access: PlistFileAccess(journal: restarted, paths: paths), grants: try makeGrants())
        let failures = await restarted.replay(using: restorer)

        #expect(failures.isEmpty)
        #expect(try onDisk()["alpha"] as? Int == 1)
        #expect(try onDisk()["keep"] as? String == "me")
        #expect(await restarted.records().isEmpty)
    }

    @Test(arguments: [PlistWriteStrategy.atomicFile, .cfPreferences])
    func secondWriteKeepsFirstOriginal(strategy: PlistWriteStrategy) async throws {
        try writePlist(["alpha": 1])
        let journal = makeJournal()
        let access = makeAccess(journal)
        try await access.write(.integer(2), key: "alpha", in: plist, strategy: strategy)
        try await access.write(.integer(3), key: "alpha", in: plist, strategy: strategy)
        #expect(try access.readTopLevel(plist)["alpha"] == .integer(3))
        #expect(await journal.records().count == 1)

        let failures = await journal.replay(using: PlistJournalRestorer(access: access, grants: try makeGrants()))
        #expect(failures.isEmpty)
        #expect(try onDisk()["alpha"] as? Int == 1, "the value from before the first change, not the one before the second")
    }

    @Test(arguments: [PlistWriteStrategy.atomicFile, .cfPreferences])
    func missingKeyRestoresToAbsent(strategy: PlistWriteStrategy) async throws {
        try writePlist(["keep": 1])
        let journal = makeJournal()
        let access = makeAccess(journal)
        try await access.write(.string("new"), key: "fresh", in: plist, strategy: strategy)
        #expect(try onDisk()["fresh"] as? String == "new")
        #expect(await journal.records().first?.entry == .plistKey(filePath: resolved(plist), key: "fresh", original: nil, strategy: strategy))

        let failures = await journal.replay(using: PlistJournalRestorer(access: access, grants: try makeGrants()))
        #expect(failures.isEmpty)
        #expect(try onDisk().keys.sorted() == ["keep"], "the key that wasn't there is removed, not set to something")
    }

    @Test func replayRestoresInReverseOrderEachKeyItsFirstOriginal() async throws {
        try writePlist(["a": 1, "b": "x"])
        let journal = makeJournal()
        let access = makeAccess(journal)
        try await access.write(.integer(10), key: "a", in: plist, strategy: .atomicFile)
        try await access.write(.string("y"), key: "b", in: plist, strategy: .cfPreferences)
        try await access.write(.integer(11), key: "a", in: plist, strategy: .atomicFile)

        let failures = await journal.replay(using: PlistJournalRestorer(access: access, grants: try makeGrants()))
        #expect(failures.isEmpty)
        let result = try onDisk()
        #expect(result["a"] as? Int == 1)
        #expect(result["b"] as? String == "x")
    }

    @Test func undoPutsBackOneKeyAndTakesItsRecordOut() async throws {
        try writePlist(["a": 1, "b": 2])
        let journal = makeJournal()
        let access = makeAccess(journal)
        try await access.write(.integer(10), key: "a", in: plist, strategy: .cfPreferences)
        try await access.write(.integer(20), key: "b", in: plist, strategy: .atomicFile)

        try await access.undo(key: "a", in: plist)

        let result = try onDisk()
        #expect(result["a"] as? Int == 1)
        #expect(result["b"] as? Int == 20, "only that key")
        #expect(await journal.records().map(\.key) == ["plist:\(resolved(plist))#b"])
        // Nothing recorded for the key: nothing to do.
        try await access.undo(key: "a", in: plist)
    }

    @Test func undoKeepsTheRecordWhenTheValueDidntComeBack() async throws {
        try writePlist(["a": 1])
        let journal = makeJournal()
        try await makeAccess(journal).write(.integer(10), key: "a", in: plist, strategy: .atomicFile)

        var io = PlistIO.system
        io.write = { _, _, _, _ in }
        let broken = PlistFileAccess(journal: journal, paths: paths, grants: nil, io: io)
        await #expect(throws: PlistAccessError.notPersisted(key: "a")) { try await broken.undo(key: "a", in: plist) }
        #expect(await journal.records().count == 1)
    }

    @Test func writesAreRefusedWhileAReplayRuns() async throws {
        try writePlist(["alpha": 1, "other": 1])
        let journal = makeJournal()
        let access = makeAccess(journal)
        // Something to replay, so that the replay takes a moment.
        try await journal.record(.plistKey(filePath: resolved(plist), key: "other", original: .integer(1), strategy: .atomicFile))

        let entered = Gate()
        let release = Gate()
        let replay = Task { await journal.replay(using: BlockingRestorer(entered: entered, release: release)) }
        await entered.wait()

        await #expect(throws: JournalError.replayInProgress) {
            try await access.write(.integer(2), key: "alpha", in: plist, strategy: .atomicFile)
        }
        #expect(try onDisk()["alpha"] as? Int == 1, "no write happened")

        release.open()
        _ = await replay.value
        // After the replay it works again.
        try await access.write(.integer(2), key: "alpha", in: plist, strategy: .atomicFile)
        #expect(try onDisk()["alpha"] as? Int == 2)
    }

    // MARK: Restorer

    @Test func theRestorerLeavesAnEntryItCantRestoreInTheJournal() async throws {
        let journal = makeJournal()
        let missing = folder.url.appending(path: "no-such-folder/file.plist")
        try await journal.record(.plistKey(filePath: missing.path, key: "k", original: .integer(1), strategy: .atomicFile))
        let failures = await journal.replay(using: PlistJournalRestorer(access: makeAccess(journal), grants: try makeGrants()))
        #expect(failures.count == 1)
        #expect(await journal.records().count == 1)
    }

    @Test func aDefaultsEntryIsNotRestoredYet() async throws {
        let journal = makeJournal()
        let restorer = PlistJournalRestorer(access: makeAccess(journal), grants: try makeGrants())
        await #expect(throws: PlistAccessError.unsupportedEntry) {
            try await restorer.restore(.defaultsKey(domain: "com.example", key: "k", currentHost: true, original: nil))
        }
    }

    @Test func aCancelledReplayRestoresNothingMore() async throws {
        try writePlist(["alpha": 1])
        let journal = makeJournal()
        let access = makeAccess(journal)
        try await access.write(.integer(2), key: "alpha", in: plist, strategy: .atomicFile)
        let restorer = PlistJournalRestorer(access: access, grants: try makeGrants())
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await journal.replay(using: restorer)
        }
        let failures = await task.value
        #expect(failures.count == 1, "it stays in the journal for the next launch")
        #expect(try onDisk()["alpha"] as? Int == 2)
    }

    // MARK: Grants

    private func makeSettings() throws -> SettingsStore {
        let paths = MantelPaths(root: folder.url.appending(path: "Mantel", directoryHint: .isDirectory),
                                logs: folder.url.appending(path: "Logs", directoryHint: .isDirectory))
        try paths.createDirectories()
        return SettingsStore(paths: paths)
    }

    private func makeGrants(settings: SettingsStore? = nil) throws -> FileGrantStore {
        FileGrantStore(store: try settings ?? makeSettings(), bookmarkOptions: [], clock: clock)
    }

    /// A fake home with the approvals file where `ExpectedFile` says it is, and a grant of it.
    private func grantedApprovals(_ grants: FileGrantStore) async throws -> URL {
        let home = folder.url.appending(path: "home", directoryHint: .isDirectory)
        let file = home.appending(path: "Library/Group Containers/group.com.apple.controlcenter/Library/Preferences/group.com.apple.controlcenter.plist")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try writePlist(["trackedApplications": ["com.example.app": true]], to: file)
        _ = try await grants.grant(.controlCenterApprovals, chosen: file, home: home)
        return file
    }

    @Test func aFileThatHasAGrantIsOpenedThroughIt() async throws {
        let settings = try makeSettings()
        let grants = try makeGrants(settings: settings)
        let file = try await grantedApprovals(grants)
        // The grant is saved a moment after it is made; saved now, it is in this test's folder.
        await settings.flush()
        let journal = makeJournal()
        let access = PlistFileAccess(journal: journal, paths: paths, grants: grants)

        try await access.write(.dictionary(["com.example.app": .bool(false)]), key: "trackedApplications", in: file, strategy: .atomicFile)
        let failures = await journal.replay(using: PlistJournalRestorer(access: access, grants: grants))
        #expect(failures.isEmpty)
        #expect(try onDisk(file)["trackedApplications"] as? [String: Bool] == ["com.example.app": true])

        // The file is gone: the grant says so (the plain way would have made a new file).
        let entry = JournalEntry.plistKey(filePath: file.resolvingSymlinksInPath().path, key: "trackedApplications",
                                          original: nil, strategy: .atomicFile)
        try FileManager.default.removeItem(at: file)
        await #expect(throws: FileGrantError.stale) {
            try await PlistJournalRestorer(access: PlistFileAccess(journal: journal, paths: paths), grants: grants).restore(entry)
        }
    }

    @Test func aFileWithoutAGrantIsOpenedDirectly() async throws {
        try writePlist(["alpha": 1])
        let grants = try makeGrants()
        let journal = makeJournal()
        let access = PlistFileAccess(journal: journal, paths: paths, grants: grants)
        try await access.write(.integer(2), key: "alpha", in: plist, strategy: .atomicFile)
        #expect(try onDisk()["alpha"] as? Int == 2)
    }
}
