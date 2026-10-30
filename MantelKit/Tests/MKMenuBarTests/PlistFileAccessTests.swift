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

/// What a journal file holds.
private struct JournalOnDisk: Decodable {
    var records: [JournalRecord]
}

/// A codec for a value that is kept as the bytes of an XML property list.
private struct XMLBlobCodec: PlistBlobCodec {
    func value(at path: PlistKeyPath, in blob: Data) throws -> PlistValue? {
        try decode(blob).value(at: path)
    }

    func setting(_ value: PlistValue?, at path: PlistKeyPath, in blob: Data) throws -> Data {
        let updated = try decode(blob).setting(value, at: path)
        return try PropertyListSerialization.data(fromPropertyList: updated.propertyList, format: .xml, options: 0)
    }

    private func decode(_ blob: Data) throws -> PlistValue {
        let object = try PropertyListSerialization.propertyList(from: blob, format: nil)
        guard let value = PlistValue(propertyList: object) else { throw PlistAccessError.notADictionary }
        return value
    }
}

/// Every test makes its own folder with the files it needs, writes only there, and the folder goes away with the test.
/// Nothing here touches a real preferences file: `cfPreferences` is given the temporary file's path as its domain.
@Suite("Plist file access", .timeLimit(.minutes(1)))
struct PlistFileAccessTests {
    /// Held by the suite, and so for the whole test.
    let folder = TemporaryFolder(prefix: "mantel-plist")
    let clock = FakeClock()
    /// For the tests that wait for `cfprefsd` and the file to agree: its sleeps return at once, having moved the time on.
    let stepping = SteppingClock()

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

    private func resolved(_ url: URL) -> String { CanonicalPath.of(url) }

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

    @Test func undoOfAWholeKeyPutsBackThatKeyAndTakesItsRecordOut() async throws {
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
        // Both strategies on the files themselves: a group container's path is never given to the real preferences service here.
        let access = PlistFileAccess(journal: journal, paths: paths, grants: grants, io: .filesOnly, clock: clock)

        try await access.write(.dictionary(["com.example.app": .bool(false)]), key: "trackedApplications", in: file, strategy: .cfPreferences)
        #expect(try onDisk(file)["trackedApplications"] as? [String: Bool] == ["com.example.app": false])
        let failures = await journal.replay(using: PlistJournalRestorer(access: access, grants: grants))
        #expect(failures.isEmpty)
        #expect(try onDisk(file)["trackedApplications"] as? [String: Bool] == ["com.example.app": true])

        // The file is gone: the grant says so (the plain way would have made a new file).
        let entry = JournalEntry.plistKey(filePath: CanonicalPath.of(file), key: "trackedApplications",
                                          original: nil, strategy: .cfPreferences)
        try FileManager.default.removeItem(at: file)
        await #expect(throws: FileGrantError.stale(fileName: "group.com.apple.controlcenter.plist")) {
            try await PlistJournalRestorer(access: PlistFileAccess(journal: journal, paths: paths, io: .filesOnly, clock: clock), grants: grants)
                .restore(entry)
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

    // MARK: Places inside a key

    private func tableOnDisk(_ url: URL? = nil) throws -> [String: Int] {
        try #require(onDisk(url)["table"] as? [String: Int])
    }

    private func backupNames() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: paths.backups.path)) ?? []).sorted()
    }

    private func tableEntry(_ name: String, original: PlistValue?, strategy: PlistWriteStrategy = .cfPreferences) -> JournalEntry {
        .plistPath(filePath: resolved(plist), key: "table", path: [.key(name)], original: original, strategy: strategy, codec: .none)
    }

    private func steppingAccess(_ journal: Journal, service: ScriptedService) -> PlistFileAccess {
        PlistFileAccess(journal: journal, paths: paths, grants: nil, io: service.io, clock: stepping)
    }

    @Test func pathWriteJournalsEachPathThenWritesOnce() async throws {
        try writePlist(["table": ["a": 1, "b": 2, "c": 3], "keep": "me"])
        let journal = makeJournal()
        let service = ScriptedService(.followsTheFile)
        let access = PlistFileAccess(journal: journal, paths: paths, grants: nil, io: service.io, clock: clock)
        // What the journal's file holds at the moment of the write: the records are on disk before the change is made.
        let journalFile = journalFile
        let atTheWrite = Mutex<[JournalEntry]>([])
        service.onWrite {
            let records = (try? Data(contentsOf: journalFile)).flatMap { try? JSONCoding.decoder().decode(JournalOnDisk.self, from: $0) }
            atTheWrite.withLock { $0 = records?.records.map(\.entry) ?? [] }
        }

        let edits = [PathEdit(path: [.key("a")], value: .integer(10)), PathEdit(path: [.key("b")], value: nil),
                     PathEdit(path: [.key("d")], value: .integer(4))]
        try await access.write(edits, key: "table", in: plist, strategy: .cfPreferences)

        let expected = [tableEntry("a", original: .integer(1)), tableEntry("b", original: .integer(2)), tableEntry("d", original: nil)]
        #expect(atTheWrite.withLock { $0 } == expected, "each path was journaled, with its original, before the key was written")
        #expect(service.writeCount == 1, "and the key was written once, for all three")
        #expect(await journal.records().map(\.entry) == expected)
        #expect(await journal.records().map(\.lastWritten) == [.value(.integer(10)), .removed, .value(.integer(4))] as [WrittenValue?],
                "what was written is noted for each")
        #expect(try tableOnDisk() == ["a": 10, "c": 3, "d": 4])
        #expect(try onDisk()["keep"] as? String == "me")
        #expect(backupNames().count == 1, "the file was copied once, before the write")
    }

    @Test func pathWriteRoundTripsThroughThePreferencesService() async throws {
        try writePlist(["table": ["a": 1, "b": 2], "keep": "me"])
        let journal = makeJournal()
        let access = makeAccess(journal)

        try await access.write([PathEdit(path: [.key("a")], value: .integer(10))], key: "table", in: plist)
        #expect(try access.readTopLevel(plist)["table"] == .dictionary(["a": .integer(10), "b": .integer(2)]))
        #expect(try await access.value(at: [.key("a")], key: "table", in: plist) == .integer(10))
        #expect(try await access.value(at: [.key("nothing")], key: "table", in: plist) == nil)

        // A second write to the same place, as the next change after a first: it isn't refused, and the original is still the first.
        try await access.write([PathEdit(path: [.key("a")], value: .integer(11))], key: "table", in: plist)
        #expect(await journal.records().map(\.entry) == [tableEntry("a", original: .integer(1))])

        try await access.undo(path: [.key("a")], key: "table", in: plist)
        #expect(try tableOnDisk() == ["a": 1, "b": 2])
        #expect(await journal.records().isEmpty)
    }

    @Test func undoPutsBackOnlyThatPath() async throws {
        try writePlist(["table": ["a": 1, "b": 2, "c": 3]])
        let journal = makeJournal()
        let access = PlistFileAccess(journal: journal, paths: paths, grants: nil, io: ScriptedService(.followsTheFile).io, clock: clock)
        try await access.write([PathEdit(path: [.key("a")], value: .integer(10)), PathEdit(path: [.key("b")], value: .integer(20))],
                               key: "table", in: plist)
        // Meanwhile macOS changes a place of its own in the same table.
        try PlistIO.writeFile(.dictionary(["a": .integer(10), "b": .integer(20), "c": .integer(33)]), key: "table", to: plist)

        try await access.undo(path: [.key("a")], key: "table", in: plist)

        #expect(try tableOnDisk() == ["a": 1, "b": 20, "c": 33], "a is back; b is still Mantel's, and c is macOS's")
        #expect(await journal.records().map(\.key) == ["plist:\(resolved(plist))#table/k:b"], "only a's record is gone")
        // A place that isn't recorded is nothing to put back.
        try await access.undo(path: [.key("a")], key: "table", in: plist)
        #expect(try tableOnDisk() == ["a": 1, "b": 20, "c": 33])
    }

    @Test func replayOfPathEntriesLeavesWhatOthersChangedAlone() async throws {
        try writePlist(["table": ["a": 1, "b": 2, "c": 3]])
        let journal = makeJournal()
        let access = PlistFileAccess(journal: journal, paths: paths, grants: nil, io: ScriptedService(.followsTheFile).io, clock: clock)
        try await access.write([PathEdit(path: [.key("a")], value: .integer(10)), PathEdit(path: [.key("b")], value: nil)],
                               key: "table", in: plist)
        try PlistIO.writeFile(.dictionary(["a": .integer(10), "c": .integer(33), "d": .integer(4)]), key: "table", to: plist)

        // As after a crash: a new journal on the same file.
        let restarted = Journal(file: journalFile, clock: clock)
        let restorer = PlistJournalRestorer(access: PlistFileAccess(journal: restarted, paths: paths, grants: nil,
                                                                    io: ScriptedService(.followsTheFile).io, clock: clock),
                                            grants: try makeGrants())
        let failures = await restarted.replay(using: restorer)

        #expect(failures.isEmpty)
        #expect(try tableOnDisk() == ["a": 1, "b": 2, "c": 33, "d": 4], "a and b are back; c and d, which were never Mantel's, stay")
        #expect(await restarted.records().isEmpty)
    }

    @Test func aPathThatCantBeTakenIsFoundBeforeAnythingIsChanged() async throws {
        try writePlist(["table": ["a": 1]])
        let before = try Data(contentsOf: plist)
        let journal = makeJournal()
        let access = PlistFileAccess(journal: journal, paths: paths, grants: nil, io: ScriptedService(.followsTheFile).io, clock: clock)

        await #expect(throws: PlistAccessError.path(.notAContainer(step: 1))) {
            try await access.write([PathEdit(path: [.key("a"), .key("deeper")], value: .integer(1))], key: "table", in: plist)
        }
        await #expect(throws: PlistAccessError.path(.noMatch(step: 0)), "an empty path has no place to put a value") {
            try await access.write([PathEdit(path: [], value: .integer(1))], key: "table", in: plist)
        }
        #expect(await journal.records().isEmpty, "nothing was journaled for a change that can't be made")
        #expect(backupNames().isEmpty)
        #expect(try Data(contentsOf: plist) == before)

        // No edits, nothing to do.
        try await access.write([], key: "table", in: plist)
        #expect(try Data(contentsOf: plist) == before)
    }

    @Test func aPathWriteTheJournalCantRecordChangesNothing() async throws {
        try writePlist(["table": ["a": 1, "b": 2]])
        let journal = makeJournal()
        // Something already recorded, which stays. The journal's folder can't be written to, so the next record can't be made.
        try await journal.record(tableEntry("a", original: .integer(1)))
        let access = PlistFileAccess(journal: journal, paths: paths, grants: nil, io: ScriptedService(.followsTheFile).io, clock: clock)
        let before = try Data(contentsOf: plist)
        let state = journalFile.deletingLastPathComponent()
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: state.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: state.path) }

        await #expect(throws: (any Error).self) {
            try await access.write([PathEdit(path: [.key("a")], value: .integer(9)), PathEdit(path: [.key("b")], value: .integer(9))],
                                   key: "table", in: plist)
        }
        #expect(await journal.records().map(\.entry) == [tableEntry("a", original: .integer(1))])
        #expect(try Data(contentsOf: plist) == before, "nothing was changed")
    }

    // MARK: The two files macOS keeps for the menu bar

    @Test func atomicFileIsRefusedForGrantedAppleFile() async throws {
        let settings = try makeSettings()
        let grants = try makeGrants(settings: settings)
        let file = try await grantedApprovals(grants)
        await settings.flush()
        let journal = makeJournal()
        let access = PlistFileAccess(journal: journal, paths: paths, grants: grants, io: .filesOnly, clock: clock)
        let before = try Data(contentsOf: file)

        let refusal = PlistAccessError.atomicFileRefused(file: "group.com.apple.controlcenter.plist")
        await #expect(throws: refusal) {
            try await access.write([PathEdit(path: [.key("com.example.app")], value: .bool(false))], key: "trackedApplications",
                                   in: file, strategy: .atomicFile)
        }
        await #expect(throws: refusal, "a whole key can't be replaced that way either") {
            try await access.write(.dictionary([:]), key: "trackedApplications", in: file, strategy: .atomicFile)
        }
        #expect(refusal.errorDescription
            == "macOS doesn't let apps replace group.com.apple.controlcenter.plist, so Mantel only changes it through macOS's preferences service.")
        #expect(try Data(contentsOf: file) == before)
        #expect(await journal.records().isEmpty, "refused before the journal, and before the backup")
        #expect(backupNames().isEmpty)

        // Through the preferences service it is allowed, and any other file may still be replaced.
        try await access.write([PathEdit(path: [.key("com.example.app")], value: .bool(false))], key: "trackedApplications", in: file)
        #expect(try onDisk(file)["trackedApplications"] as? [String: Bool] == ["com.example.app": false])
        try writePlist(["alpha": 1])
        try await access.write(.integer(2), key: "alpha", in: plist, strategy: .atomicFile)
        #expect(try onDisk()["alpha"] as? Int == 2)
    }

    @Test func legacyAtomicEntryRestoresThroughPreferences() async throws {
        // An earlier version journaled an atomic write of the approvals file. macOS refused it, so the preferences service is the
        // only way back.
        let settings = try makeSettings()
        let grants = try makeGrants(settings: settings)
        let file = try await grantedApprovals(grants)
        await settings.flush()
        let strategies = Mutex<[PlistWriteStrategy]>([])
        var io = PlistIO.filesOnly
        let write = io.write
        io.write = { value, key, url, strategy in
            strategies.withLock { $0.append(strategy) }
            try write(value, key, url, strategy)
        }
        let journal = makeJournal()
        let access = PlistFileAccess(journal: journal, paths: paths, grants: grants, io: io, clock: clock)
        try await journal.record(.plistKey(filePath: resolved(file), key: "trackedApplications",
                                           original: .dictionary(["com.example.app": .bool(true)]), strategy: .atomicFile))
        try writePlist(["trackedApplications": ["com.example.app": false]], to: file)

        let failures = await journal.replay(using: PlistJournalRestorer(access: access, grants: grants))

        #expect(failures.isEmpty)
        #expect(strategies.withLock { $0 } == [.cfPreferences], "not through the file")
        #expect(try onDisk(file)["trackedApplications"] as? [String: Bool] == ["com.example.app": true])
        #expect(await journal.records().isEmpty)
    }

    @Test func legacyAtomicEntryOfAnotherFileStaysAtomic() async throws {
        try writePlist(["alpha": 5])
        let strategies = Mutex<[PlistWriteStrategy]>([])
        var io = PlistIO.filesOnly
        let write = io.write
        io.write = { value, key, url, strategy in
            strategies.withLock { $0.append(strategy) }
            try write(value, key, url, strategy)
        }
        let journal = makeJournal()
        let access = PlistFileAccess(journal: journal, paths: paths, grants: try makeGrants(), io: io, clock: clock)
        try await journal.record(.plistKey(filePath: resolved(plist), key: "alpha", original: .integer(1), strategy: .atomicFile))

        #expect(await journal.replay(using: PlistJournalRestorer(access: access, grants: try makeGrants())).isEmpty)
        #expect(strategies.withLock { $0 } == [.atomicFile])
        #expect(try onDisk()["alpha"] as? Int == 1)
    }

    // MARK: cfprefsd and the file disagree

    @Test func pendingFlushOfOwnWriteDoesNotRefuse() async throws {
        try writePlist(["table": ["a": 1]])
        let journal = Journal(file: journalFile, clock: stepping)
        let first = tableEntry("a", original: .integer(1))
        try await journal.record(first)
        try await journal.noteWritten(.value(.integer(9)), forKey: Journal.key(for: first))
        // cfprefsd holds Mantel's last write (a = 9), which has not reached the file (a = 1) yet, and says so every time it is asked.
        let service = ScriptedService(.saysUntilWritten(.dictionary(["a": .integer(9)])))
        let access = steppingAccess(journal, service: service)
        let started = stepping.now()

        try await access.write([PathEdit(path: [.key("a")], value: .integer(10))], key: "table", in: plist)

        #expect(service.writeCount == 1)
        #expect(stepping.now().timeIntervalSince(started) >= 2, "it waited the 2 s out, on the injected clock, before deciding")
        #expect(try tableOnDisk() == ["a": 10])
        let records = await journal.records()
        #expect(records.map(\.entry) == [first], "the first original is still the one that counts")
        #expect(records.first?.lastWritten == .value(.integer(10)))
    }

    @Test(arguments: [nil, WrittenValue.value(.integer(7)), .removed] as [WrittenValue?])
    func persistentDisagreementRefusesBeforeBackup(lastWritten: WrittenValue?) async throws {
        try writePlist(["table": ["a": 1]])
        let before = try Data(contentsOf: plist)
        let journal = Journal(file: journalFile, clock: stepping)
        let first = tableEntry("a", original: .integer(1))
        var recordsBefore: [JournalRecord] = []
        if let lastWritten {
            try await journal.record(first)
            try await journal.noteWritten(lastWritten, forKey: Journal.key(for: first))
            recordsBefore = await journal.records()
        }
        // cfprefsd says a = 5: not what the file says, and not what Mantel last wrote either.
        let service = ScriptedService(.says(.dictionary(["a": .integer(5)])))
        let access = steppingAccess(journal, service: service)
        let started = stepping.now()

        await #expect(throws: PlistAccessError.disagree(key: "table")) {
            try await access.write([PathEdit(path: [.key("a")], value: .integer(10))], key: "table", in: plist)
        }

        #expect(stepping.now().timeIntervalSince(started) >= 2, "it gave them 2 s on the injected clock, and not a moment of real time")
        #expect(service.readCount >= 20)
        #expect(service.writeCount == 0)
        #expect(backupNames().isEmpty, "refused before the backup")
        #expect(await journal.records() == recordsBefore, "and before the journal")
        #expect(try Data(contentsOf: plist) == before)
    }

    @Test func aFlushThatLandsWhilePollingEndsTheWaitEarly() async throws {
        try writePlist(["table": ["a": 1]])
        let journal = Journal(file: journalFile, clock: stepping)
        // cfprefsd disagrees for three looks and then the file catches up.
        let service = ScriptedService(.saysForReads(3, .dictionary(["a": .integer(9)])))
        let access = steppingAccess(journal, service: service)
        let started = stepping.now()

        try await access.write([PathEdit(path: [.key("a")], value: .integer(10))], key: "table", in: plist)

        let waited = stepping.now().timeIntervalSince(started)
        #expect(abs(waited - 0.3) < 0.001, "three waits of 100 ms, then it went on: \(waited)")
        #expect(try tableOnDisk() == ["a": 10])
        #expect(await journal.records().map(\.entry) == [tableEntry("a", original: .integer(1))], "the original is what both agreed on")
    }

    @Test func aWriteWhereTheyAgreeDoesNotWait() async throws {
        try writePlist(["table": ["a": 1, "b": 2]])
        let access = steppingAccess(makeJournal(), service: ScriptedService(.followsTheFile))
        let started = stepping.now()
        try await access.write([PathEdit(path: [.key("a")], value: .integer(10))], key: "table", in: plist)
        #expect(stepping.now() == started, "no wait at all")
    }

    // MARK: Places that are journaled already

    @Test func newPathsOnlySkipsAgreementWaitForJournaledPath() async throws {
        try writePlist(["table": ["a": 1]])
        let journal = Journal(file: journalFile, clock: stepping)
        let first = tableEntry("a", original: .integer(1))
        try await journal.record(first)

        // cfprefsd says a = 5, and the file says 1, which nobody wrote: with every place checked, that is a disagreement waited out for
        // 2 s and refused.
        let refusing = steppingAccess(journal, service: ScriptedService(.says(.dictionary(["a": .integer(5)]))))
        await #expect(throws: PlistAccessError.disagree(key: "table")) {
            try await refusing.write([PathEdit(path: [.key("a")], value: .integer(10))], key: "table", in: plist)
        }

        // A place that has its original in the journal isn't waited for: the writer writes the same places again and again, and the
        // preferences service flushes lazily after each re-sort of the menu bar.
        let service = ScriptedService(.saysUntilWritten(.dictionary(["a": .integer(5)])))
        let access = steppingAccess(journal, service: service)
        let started = stepping.now()
        try await access.write([PathEdit(path: [.key("a")], value: .integer(10))], key: "table", in: plist, originalCheck: .newPathsOnly)

        #expect(stepping.now() == started, "no wait at all")
        #expect(service.writeCount == 1)
        #expect(try tableOnDisk() == ["a": 10])
        #expect(await journal.records().map(\.entry) == [first], "the original is the one that was recorded")
    }

    @Test func newPathsOnlyStillChecksANewPath() async throws {
        try writePlist(["table": ["a": 1, "b": 2]])
        let journal = Journal(file: journalFile, clock: stepping)
        try await journal.record(tableEntry("a", original: .integer(1)))
        let before = try Data(contentsOf: plist)

        // cfprefsd and the file disagree about b, which has no record: its original can't be trusted, so it is waited for and refused,
        // whether it is written alone or with a place that is journaled.
        let access = steppingAccess(journal, service: ScriptedService(.says(.dictionary(["a": .integer(1), "b": .integer(9)]))))
        for edits in [[PathEdit(path: [.key("b")], value: .integer(20))],
                      [PathEdit(path: [.key("a")], value: .integer(10)), PathEdit(path: [.key("b")], value: .integer(20))]] {
            let started = stepping.now()
            await #expect(throws: PlistAccessError.disagree(key: "table")) {
                try await access.write(edits, key: "table", in: plist, originalCheck: .newPathsOnly)
            }
            #expect(stepping.now().timeIntervalSince(started) >= 2, "it gave them 2 s first")
        }
        #expect(await journal.records().count == 1, "nothing was journaled")
        #expect(try Data(contentsOf: plist) == before)
        #expect(backupNames().isEmpty, "refused before the backup")
    }

    @Test func aPlaceUnderARecordedWholeKeyIsNotWaitedForEither() async throws {
        // The whole key is recorded, which covers every place in it: each has its original already.
        try writePlist(["table": ["a": 1]])
        let journal = Journal(file: journalFile, clock: stepping)
        try await journal.record(.plistKey(filePath: resolved(plist), key: "table", original: .dictionary(["a": .integer(1)]),
                                           strategy: .cfPreferences))
        let service = ScriptedService(.saysUntilWritten(.dictionary(["a": .integer(5)])))
        let started = stepping.now()
        try await steppingAccess(journal, service: service)
            .write([PathEdit(path: [.key("a")], value: .integer(10))], key: "table", in: plist, originalCheck: .newPathsOnly)
        #expect(stepping.now() == started)
        #expect(try tableOnDisk() == ["a": 10])
    }

    // MARK: Putting back what Mantel keeps

    @Test func restoreKeptIsOneWriteOnFreshRead() async throws {
        try writePlist(["table": ["a": 1, "b": 2, "c": 3], "keep": "me"])
        let journal = makeJournal()
        let service = ScriptedService(.followsTheFile)
        let access = PlistFileAccess(journal: journal, paths: paths, grants: nil, io: service.io, clock: clock)
        // Mantel's arrangement: two places changed and one made (d held nothing).
        try await access.write([PathEdit(path: [.key("a")], value: .integer(10)), PathEdit(path: [.key("b")], value: .integer(20)),
                                PathEdit(path: [.key("d")], value: .integer(4))], key: "table", in: plist, lifetime: .kept)
        #expect(service.writeCount == 1)
        #expect(await journal.keptRecords().count == 3)
        // Then macOS changes a place of its own in the same table, which the restore must find when it reads.
        try PlistIO.writeFile(.dictionary(["a": .integer(10), "b": .integer(20), "c": .integer(33), "d": .integer(4)]), key: "table", to: plist)

        let restored = try await access.restoreKept(key: "table", in: plist)

        #expect(restored == 3)
        #expect(service.writeCount == 2, "one write for the three places")
        #expect(try tableOnDisk() == ["a": 1, "b": 2, "c": 33], "a and b are back, d is gone, and c, which was macOS's, is as it is now")
        #expect(try onDisk()["keep"] as? String == "me")
        #expect(await journal.records().isEmpty, "the records go once the read-back holds")
        #expect(try await access.restoreKept(key: "table", in: plist) == 0, "and a second restore has nothing to do")
        #expect(service.writeCount == 2)
    }

    @Test func restoreKeptLeavesOtherPathsAlone() async throws {
        try writePlist(["table": ["a": 1, "b": 2], "other": ["x": 1]])
        let journal = makeJournal()
        let access = PlistFileAccess(journal: journal, paths: paths, grants: nil, io: ScriptedService(.followsTheFile).io, clock: clock)
        try await access.write([PathEdit(path: [.key("a")], value: .integer(10))], key: "table", in: plist, lifetime: .kept)
        try await access.write([PathEdit(path: [.key("x")], value: .integer(10))], key: "other", in: plist, lifetime: .kept)
        // A platform test's temporary change in the same key.
        try await access.write([PathEdit(path: [.key("b")], value: .integer(20))], key: "table", in: plist)

        #expect(try await access.restoreKept(key: "table", in: plist) == 1)

        #expect(try tableOnDisk() == ["a": 1, "b": 20], "a is back; b is the platform test's, which only quitting or Replay now puts back")
        let other = try #require(onDisk()["other"] as? [String: Int])
        #expect(other == ["x": 10], "another key's place is Mantel's still")
        let left = await journal.records()
        #expect(left.map(\.lifetime) == [.kept, .untilQuit])
        #expect(left.map(\.key) == ["plist:\(resolved(plist))#other/k:x", "plist:\(resolved(plist))#table/k:b"])
    }

    @Test func restoreKeptTakesOutTheContainersTheWriteMade() async throws {
        try writePlist(["keep": "me"])
        let journal = makeJournal()
        let access = PlistFileAccess(journal: journal, paths: paths, grants: nil, io: ScriptedService(.followsTheFile).io, clock: clock)
        try await access.write([PathEdit(path: [.key("a")], value: .integer(1)), PathEdit(path: [.key("b")], value: .integer(2))],
                               key: "table", in: plist, lifetime: .kept)
        #expect(try tableOnDisk() == ["a": 1, "b": 2])

        #expect(try await access.restoreKept(key: "table", in: plist) == 2)

        #expect(try onDisk()["table"] == nil, "the table is gone, not left as {}")
        #expect(try onDisk()["keep"] as? String == "me")
        #expect(await journal.records().isEmpty)
    }

    @Test func restoreKeptKeepsTheRecordsWhenTheServiceDoesNotKeepTheWrite() async throws {
        try writePlist(["table": ["a": 1]])
        let journal = makeJournal()
        let access = PlistFileAccess(journal: journal, paths: paths, grants: nil, io: ScriptedService(.followsTheFile).io, clock: clock)
        try await access.write([PathEdit(path: [.key("a")], value: .integer(10))], key: "table", in: plist, lifetime: .kept)

        let dropping = PlistFileAccess(journal: journal, paths: paths, grants: nil, io: ScriptedService(.dropsWrites).io, clock: clock)
        await #expect(throws: PlistAccessError.notPersisted(key: "table")) {
            try await dropping.restoreKept(key: "table", in: plist)
        }
        #expect(try tableOnDisk() == ["a": 10], "nothing came back")
        #expect(await journal.keptRecords().count == 1, "so the record stays, for the next try")

        // And the next try, with a service that keeps what it is told, puts it back.
        #expect(try await access.restoreKept(key: "table", in: plist) == 1)
        #expect(try tableOnDisk() == ["a": 1])
        #expect(await journal.records().isEmpty)
    }

    @Test func restoreKeptPutsBackEvenWhenTheJournalIsReopened() async throws {
        // The records are Mantel's across quits: a new process, with a new journal on the same file, restores them.
        try writePlist(["table": ["a": 1, "b": 2]])
        let first = PlistFileAccess(journal: makeJournal(), paths: paths, grants: nil, io: ScriptedService(.followsTheFile).io, clock: clock)
        try await first.write([PathEdit(path: [.key("a")], value: .integer(10))], key: "table", in: plist, lifetime: .kept)

        let later = Journal(file: journalFile, clock: clock)
        clock.advance(by: .seconds(40 * 24 * 60 * 60))
        let access = PlistFileAccess(journal: later, paths: paths, grants: nil, io: ScriptedService(.followsTheFile).io, clock: clock)
        #expect(try await access.restoreKept(key: "table", in: plist) == 1, "whatever its age")
        #expect(try tableOnDisk() == ["a": 1, "b": 2])
    }

    // MARK: Containers the write made

    @Test func undoRemovesContainersTheWriteCreated() async throws {
        // The table isn't in the file: writing a place in it makes it, and putting the place back leaves no table at all.
        try writePlist(["keep": "me"])
        let journal = makeJournal()
        let access = PlistFileAccess(journal: journal, paths: paths, grants: nil, io: ScriptedService(.followsTheFile).io, clock: clock)
        try await access.write([PathEdit(path: [.key("a")], value: .integer(1))], key: "table", in: plist)
        #expect(try tableOnDisk() == ["a": 1])
        #expect(await journal.records().first?.createdContainers == 1, "the journal knows the write made the table")

        try await access.undo(path: [.key("a")], key: "table", in: plist)
        #expect(try onDisk()["table"] == nil, "the table is gone, not left as {}")
        #expect(try onDisk()["keep"] as? String == "me")
        #expect(await journal.records().isEmpty)
    }

    @Test func undoRemovesOnlyTheLevelsTheWriteMade() async throws {
        // The table is there; the write makes one more level inside it.
        try writePlist(["table": ["b": 2]])
        let journal = makeJournal()
        let access = PlistFileAccess(journal: journal, paths: paths, grants: nil, io: ScriptedService(.followsTheFile).io, clock: clock)
        let place: PlistKeyPath = [.key("x"), .key("y")]
        try await access.write([PathEdit(path: place, value: .integer(1))], key: "table", in: plist)
        #expect(await journal.records().first?.createdContainers == 1, "x was made; the table was there")

        try await access.undo(path: place, key: "table", in: plist)
        #expect(try tableOnDisk() == ["b": 2])
        #expect(try onDisk()["table"] as? [String: Any] != nil, "the table stays: it was there before")
    }

    @Test func undoLeavesACreatedContainerSomeoneElseAddedTo() async throws {
        try writePlist(["keep": "me"])
        let journal = makeJournal()
        let access = PlistFileAccess(journal: journal, paths: paths, grants: nil, io: ScriptedService(.followsTheFile).io, clock: clock)
        try await access.write([PathEdit(path: [.key("a")], value: .integer(1))], key: "table", in: plist)
        // macOS puts a place of its own in the table Mantel made.
        try PlistIO.writeFile(.dictionary(["a": .integer(1), "c": .integer(3)]), key: "table", to: plist)

        try await access.undo(path: [.key("a")], key: "table", in: plist)
        #expect(try tableOnDisk() == ["c": 3], "it isn't empty, so it is theirs now")
    }

    @Test func aTableThatWasThereEmptyStaysEmpty() async throws {
        try writePlist(["table": [String: Int]()])
        let journal = makeJournal()
        let access = PlistFileAccess(journal: journal, paths: paths, grants: nil, io: ScriptedService(.followsTheFile).io, clock: clock)
        try await access.write([PathEdit(path: [.key("a")], value: .integer(1))], key: "table", in: plist)
        #expect(await journal.records().first?.createdContainers == nil, "the write made no container")

        try await access.undo(path: [.key("a")], key: "table", in: plist)
        #expect(try tableOnDisk() == [:], "as it was")
    }

    @Test func aReplayRemovesWhatTheWriteCreatedToo() async throws {
        try writePlist(["keep": "me"])
        let journal = makeJournal()
        let access = PlistFileAccess(journal: journal, paths: paths, grants: nil, io: ScriptedService(.followsTheFile).io, clock: clock)
        try await access.write([PathEdit(path: [.key("a")], value: .integer(1)), PathEdit(path: [.key("b")], value: .integer(2))],
                               key: "table", in: plist)

        // As after a crash: a new journal on the same file.
        let restarted = Journal(file: journalFile, clock: clock)
        let restorer = PlistJournalRestorer(access: PlistFileAccess(journal: restarted, paths: paths, grants: nil,
                                                                    io: ScriptedService(.followsTheFile).io, clock: clock),
                                            grants: try makeGrants())
        let failures = await restarted.replay(using: restorer)

        #expect(failures.isEmpty)
        #expect(try onDisk()["table"] == nil, "both places are back to nothing, and the table with them")
        #expect(try onDisk()["keep"] as? String == "me")
        #expect(await restarted.records().isEmpty)
    }

    @Test func containersInsideABlobAreRemovedToo() async throws {
        let codec = PlistBlobCodecID(rawValue: "xml")
        let inner = try PropertyListSerialization.data(fromPropertyList: ["other": 1], format: .xml, options: 0)
        try writePlist(["blob": inner])
        let journal = makeJournal()
        let access = PlistFileAccess(journal: journal, paths: paths, grants: nil, codecs: [codec: XMLBlobCodec()],
                                     io: ScriptedService(.followsTheFile).io, clock: clock)
        let place: PlistKeyPath = [.key("apps"), .key("x")]
        try await access.write([PathEdit(path: place, value: .integer(5))], key: "blob", in: plist, codec: codec)
        #expect(await journal.records().first?.createdContainers == 1)

        try await access.undo(path: place, key: "blob", in: plist)
        #expect(try await access.value(at: [.key("apps")], key: "blob", in: plist, codec: codec) == nil)
        #expect(try await access.value(at: [.key("other")], key: "blob", in: plist, codec: codec) == .integer(1))
    }

    // MARK: Files that can't be read

    @Test(.disabled(if: getuid() == 0, "root can read any file"))
    func permissionDeniedIsNotAbsent() throws {
        try writePlist(["alpha": 1])
        let absent = folder.url.appending(path: "absent.plist")
        #expect(try PlistIO.readFile(absent, key: "alpha") == nil, "a file that isn't there has no keys")

        func isUnreadable(_ body: () throws -> Void) -> Bool {
            do {
                try body()
                return false
            } catch PlistAccessError.unreadable {
                return true
            } catch {
                return false
            }
        }
        // The file is there, and Mantel isn't allowed to read it.
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: plist.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: plist.path) }
        #expect(isUnreadable { _ = try PlistIO.readFile(plist, key: "alpha") }, "read as absent, a write would make a new file over it")
        #expect(isUnreadable { try PlistIO.writeFile(.integer(2), key: "alpha", to: plist) })

        // The folder it is in can't be looked into: the file can't even be found, which is not the same as not being there.
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: plist.path)
        let inner = folder.url.appending(path: "closed", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: inner, withIntermediateDirectories: true)
        let hidden = inner.appending(path: "sample.plist")
        try writePlist(["alpha": 1], to: hidden)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: inner.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: inner.path) }
        #expect(isUnreadable { _ = try PlistIO.readFile(hidden, key: "alpha") })
        #expect(isUnreadable { try PlistIO.writeFile(.integer(2), key: "alpha", to: hidden) })
    }

    // MARK: Lists

    private func appsEntry(_ app: String, flag: Bool) -> [String: Any] { ["bundle": app, "allowed": flag] }

    private func allowed(_ app: String) throws -> Bool? {
        let apps = try #require(onDisk()["apps"] as? [[String: Any]])
        return apps.first { $0["bundle"] as? String == app }?["allowed"] as? Bool
    }

    @Test func matchingEntryGoneCountsAsRestored() async throws {
        try writePlist(["apps": [appsEntry("com.example.one", flag: true), appsEntry("com.example.two", flag: true)]])
        let journal = makeJournal()
        let access = PlistFileAccess(journal: journal, paths: paths, grants: nil, io: ScriptedService(.followsTheFile).io, clock: clock)
        let one: PlistKeyPath = [.matching(key: "bundle", value: "com.example.one"), .key("allowed")]
        try await access.write([PathEdit(path: one, value: .bool(false))], key: "apps", in: plist)
        #expect(try allowed("com.example.one") == false)

        // The app's entry is gone meanwhile.
        try writePlist(["apps": [appsEntry("com.example.two", flag: true)]])
        let before = try Data(contentsOf: plist)
        try await access.undo(path: one, key: "apps", in: plist)

        #expect(try Data(contentsOf: plist) == before, "nothing was put back, and nothing was made up")
        #expect(await journal.records().isEmpty, "and the record is gone: there is nothing left to restore")

        // Through a replay it is the same.
        try writePlist(["apps": [appsEntry("com.example.one", flag: true)]])
        try await access.write([PathEdit(path: one, value: .bool(false))], key: "apps", in: plist)
        try writePlist(["apps": [appsEntry("com.example.two", flag: true)]])
        let failures = await journal.replay(using: PlistJournalRestorer(access: access, grants: try makeGrants()))
        #expect(failures.isEmpty)
        #expect(await journal.records().isEmpty)
    }

    @Test func vanishedListCountsAsEntryGone() async throws {
        let one: PlistKeyPath = [.matching(key: "bundle", value: "com.example.one"), .key("allowed")]
        try writePlist(["apps": [appsEntry("com.example.one", flag: true)], "keep": "me"])
        let journal = makeJournal()
        let access = PlistFileAccess(journal: journal, paths: paths, grants: nil, io: ScriptedService(.followsTheFile).io, clock: clock)
        try await access.write([PathEdit(path: one, value: .bool(false))], key: "apps", in: plist)

        // The whole list is gone meanwhile, not just the app's entry in it.
        try PlistIO.writeFile(nil, key: "apps", to: plist)
        let before = try Data(contentsOf: plist)
        try await access.undo(path: one, key: "apps", in: plist)

        #expect(try Data(contentsOf: plist) == before, "nothing was put back, and no list was made up to put it in")
        #expect(await journal.records().isEmpty, "and the record is gone: its entry is gone, so there is nothing left to restore")

        // Through a replay it is the same, and it says so in the log's words rather than as a failure.
        try writePlist(["apps": [appsEntry("com.example.one", flag: true)]])
        try await access.write([PathEdit(path: one, value: .bool(false))], key: "apps", in: plist)
        try PlistIO.writeFile(nil, key: "apps", to: plist)
        let failures = await journal.replay(using: PlistJournalRestorer(access: access, grants: try makeGrants()))
        #expect(failures.isEmpty)
        #expect(await journal.records().isEmpty)

        // A write into a list that isn't there is refused, as for any entry that isn't in it.
        await #expect(throws: PlistAccessError.path(.noMatch(step: 0))) {
            try await access.write([PathEdit(path: one, value: .bool(false))], key: "apps", in: plist)
        }
        #expect(await journal.records().isEmpty)
    }

    @Test func vanishedBlobCountsAsEntryGoneToo() async throws {
        let codec = PlistBlobCodecID(rawValue: "xml")
        let inner = try PropertyListSerialization.data(fromPropertyList: ["apps": [appsEntry("com.example.one", flag: true)]],
                                                       format: .xml, options: 0)
        try writePlist(["blob": inner, "keep": "me"])
        let journal = makeJournal()
        let access = PlistFileAccess(journal: journal, paths: paths, grants: nil, codecs: [codec: XMLBlobCodec()],
                                     io: ScriptedService(.followsTheFile).io, clock: clock)
        let one: PlistKeyPath = [.key("apps"), .matching(key: "bundle", value: "com.example.one"), .key("allowed")]
        try await access.write([PathEdit(path: one, value: .bool(false))], key: "blob", in: plist, codec: codec)

        // The whole value is gone, so there is no blob to read the list from.
        try PlistIO.writeFile(nil, key: "blob", to: plist)
        let before = try Data(contentsOf: plist)
        try await access.undo(path: one, key: "blob", in: plist)

        #expect(try Data(contentsOf: plist) == before)
        #expect(await journal.records().isEmpty)
    }

    @Test func aMatchingStepFindsTheAppWhereverItIsNow() async throws {
        try writePlist(["apps": [appsEntry("com.example.one", flag: true), appsEntry("com.example.two", flag: true)]])
        let journal = makeJournal()
        let access = PlistFileAccess(journal: journal, paths: paths, grants: nil, io: ScriptedService(.followsTheFile).io, clock: clock)
        let one: PlistKeyPath = [.matching(key: "bundle", value: "com.example.one"), .key("allowed")]
        try await access.write([PathEdit(path: one, value: .bool(false))], key: "apps", in: plist)

        // macOS puts another app's entry in front of it, and turns that one off.
        try writePlist(["apps": [appsEntry("com.example.new", flag: false), appsEntry("com.example.one", flag: false),
                                 appsEntry("com.example.two", flag: true)]])
        try await access.undo(path: one, key: "apps", in: plist)

        #expect(try allowed("com.example.one") == true, "the app Mantel changed is put back")
        #expect(try allowed("com.example.new") == false, "the one that took its place in the list is left as it is")
        #expect(try allowed("com.example.two") == true)
    }

    // MARK: Entries that name their app some levels down

    /// An entry of a list the way macOS keeps its approvals: whether the app is allowed, and where it says it is.
    private func approval(_ app: String, allowed: Bool) -> [String: Any] {
        ["isAllowed": allowed, "menuItemLocations": [["bundle": ["_0": app]]]]
    }

    private func isAllowed(_ app: String, in list: [[String: Any]]) -> Bool? {
        list.first { entry in
            ((entry["menuItemLocations"] as? [[String: Any]])?.contains { ($0["bundle"] as? [String: Any])?["_0"] as? String == app }) == true
        }?["isAllowed"] as? Bool
    }

    private func approvalsOnDisk() throws -> [[String: Any]] {
        try #require(onDisk()["list"] as? [[String: Any]])
    }

    private func theWay(to app: String) -> PlistKeyPath {
        [.matchingPath(path: [.key("menuItemLocations"), .anyElement, .key("bundle"), .key("_0")], value: app), .key("isAllowed")]
    }

    @Test func pathWriteAndUndoThroughMatchingPathOnReorderedList() async throws {
        try writePlist(["list": [approval("com.example.one", allowed: true), approval("com.example.two", allowed: true),
                                 approval("com.example.three", allowed: true)]])
        let journal = makeJournal()
        let access = PlistFileAccess(journal: journal, paths: paths, grants: nil, io: ScriptedService(.followsTheFile).io, clock: clock)
        let two = theWay(to: "com.example.two")

        try await access.write([PathEdit(path: two, value: .bool(false))], key: "list", in: plist)
        #expect(try isAllowed("com.example.two", in: approvalsOnDisk()) == false)
        #expect(await journal.records().map(\.entry) == [
            .plistPath(filePath: resolved(plist), key: "list", path: two, original: .bool(true), strategy: .cfPreferences, codec: .none),
        ])

        // macOS writes the whole list again, in another order, and turns another app's entry off while it is at it.
        try writePlist(["list": [approval("com.example.three", allowed: false), approval("com.example.two", allowed: false),
                                 approval("com.example.new", allowed: true), approval("com.example.one", allowed: true)]])
        try await access.undo(path: two, key: "list", in: plist)

        let list = try approvalsOnDisk()
        #expect(isAllowed("com.example.two", in: list) == true, "the entry Mantel changed is put back, wherever it is now")
        #expect(isAllowed("com.example.three", in: list) == false, "what macOS changed meanwhile is left as it is")
        #expect(isAllowed("com.example.one", in: list) == true)
        #expect(isAllowed("com.example.new", in: list) == true)
        #expect(list.count == 4, "nothing was added or taken out")
        #expect(list.map { ($0["menuItemLocations"] as? [[String: Any]])?.count } == [1, 1, 1, 1])
        #expect(await journal.records().isEmpty)
    }

    @Test func vanishedEntryCountsAsGone() async throws {
        try writePlist(["list": [approval("com.example.one", allowed: true), approval("com.example.two", allowed: true)]])
        let journal = makeJournal()
        let access = PlistFileAccess(journal: journal, paths: paths, grants: nil, io: ScriptedService(.followsTheFile).io, clock: clock)
        let two = theWay(to: "com.example.two")
        try await access.write([PathEdit(path: two, value: .bool(false))], key: "list", in: plist)

        // The app's entry is gone meanwhile.
        try writePlist(["list": [approval("com.example.one", allowed: true)]])
        let before = try Data(contentsOf: plist)
        try await access.undo(path: two, key: "list", in: plist)

        #expect(try Data(contentsOf: plist) == before, "nothing was put back, and nothing was made up")
        #expect(await journal.records().isEmpty, "and the record is gone: there is nothing left to restore")

        // Through a replay it is the same, also when the whole list is gone.
        for gone in [[approval("com.example.one", allowed: true)], [[String: Any]]()] {
            try writePlist(["list": [approval("com.example.two", allowed: true)]])
            try await access.write([PathEdit(path: two, value: .bool(false))], key: "list", in: plist)
            try writePlist(["list": gone])
            let failures = await journal.replay(using: PlistJournalRestorer(access: access, grants: try makeGrants()))
            #expect(failures.isEmpty)
            #expect(await journal.records().isEmpty)
        }
    }

    @Test func twoEntriesForOneAppAreRefusedAndTheRecordStays() async throws {
        try writePlist(["list": [approval("com.example.one", allowed: true), approval("com.example.two", allowed: true)]])
        let journal = makeJournal()
        let access = PlistFileAccess(journal: journal, paths: paths, grants: nil, io: ScriptedService(.followsTheFile).io, clock: clock)
        let two = theWay(to: "com.example.two")

        // A write into a list that already has two entries for the app is refused before anything is journaled.
        try writePlist(["list": [approval("com.example.two", allowed: true), approval("com.example.two", allowed: true)]])
        await #expect(throws: PlistAccessError.path(.ambiguousMatch(step: 0))) {
            try await access.write([PathEdit(path: two, value: .bool(false))], key: "list", in: plist)
        }
        #expect(await journal.records().isEmpty)

        // One that comes between a write and its undo is not put back over: which of the two was Mantel's isn't known.
        try writePlist(["list": [approval("com.example.one", allowed: true), approval("com.example.two", allowed: true)]])
        try await access.write([PathEdit(path: two, value: .bool(false))], key: "list", in: plist)
        try writePlist(["list": [approval("com.example.two", allowed: false), approval("com.example.two", allowed: true)]])
        let before = try Data(contentsOf: plist)
        await #expect(throws: PlistAccessError.path(.ambiguousMatch(step: 0))) { try await access.undo(path: two, key: "list", in: plist) }
        #expect(try Data(contentsOf: plist) == before)
        #expect(await journal.records().count == 1, "the entry stays, for the next try")
    }

    // MARK: Old records, with the real restorer

    private let eightDays = Duration.seconds(8 * 24 * 60 * 60)

    @Test func aStaleEntryThatSomeoneChangedIsDroppedNotRestored() async throws {
        try writePlist(["table": ["a": 1]])
        let journal = makeJournal()
        let access = PlistFileAccess(journal: journal, paths: paths, grants: nil, io: ScriptedService(.followsTheFile).io, clock: clock)
        try await access.write([PathEdit(path: [.key("a")], value: .integer(10))], key: "table", in: plist)
        // Weeks later the person has set it to something else themselves.
        try PlistIO.writeFile(.dictionary(["a": .integer(99)]), key: "table", to: plist)
        clock.advance(by: eightDays)

        let failures = await journal.replay(using: PlistJournalRestorer(access: access, grants: try makeGrants()))

        #expect(failures.isEmpty)
        #expect(try tableOnDisk() == ["a": 99], "their change is not undone")
        #expect(await journal.records().isEmpty)
    }

    @Test func aStaleEntryThatStillHoldsIsRestored() async throws {
        try writePlist(["table": ["a": 1]])
        let journal = makeJournal()
        let access = PlistFileAccess(journal: journal, paths: paths, grants: nil, io: ScriptedService(.followsTheFile).io, clock: clock)
        try await access.write([PathEdit(path: [.key("a")], value: .integer(10))], key: "table", in: plist)
        clock.advance(by: eightDays)

        let failures = await journal.replay(using: PlistJournalRestorer(access: access, grants: try makeGrants()))

        #expect(failures.isEmpty)
        #expect(try tableOnDisk() == ["a": 1])
    }

    @Test func aStaleEntryOfAWholeKeyIsRestoredAsBefore() async throws {
        // A whole-key record doesn't know what was written, so nothing about it is doubted.
        try writePlist(["alpha": 1])
        let journal = makeJournal()
        let access = PlistFileAccess(journal: journal, paths: paths, grants: nil, io: ScriptedService(.followsTheFile).io, clock: clock)
        try await access.write(.integer(5), key: "alpha", in: plist, strategy: .atomicFile)
        try PlistIO.writeFile(.integer(77), key: "alpha", to: plist)
        clock.advance(by: eightDays)

        #expect(await journal.replay(using: PlistJournalRestorer(access: access, grants: try makeGrants())).isEmpty)
        #expect(try onDisk()["alpha"] as? Int == 1)
    }

    // MARK: Codecs

    @Test func aCodecEditsAPlaceInsideABlob() async throws {
        let inner = try PropertyListSerialization.data(fromPropertyList: ["apps": ["x": 1, "y": 2]], format: .xml, options: 0)
        try writePlist(["blob": inner, "keep": "me"])
        let codec = PlistBlobCodecID(rawValue: "xml")
        let journal = makeJournal()
        let access = PlistFileAccess(journal: journal, paths: paths, grants: nil, codecs: [codec: XMLBlobCodec()],
                                     io: ScriptedService(.followsTheFile).io, clock: clock)
        let place: PlistKeyPath = [.key("apps"), .key("x")]

        try await access.write([PathEdit(path: place, value: .integer(5))], key: "blob", in: plist, codec: codec)

        #expect(try await access.value(at: place, key: "blob", in: plist, codec: codec) == .integer(5))
        #expect(try await access.value(at: [.key("apps"), .key("y")], key: "blob", in: plist, codec: codec) == .integer(2))
        #expect(await journal.records().map(\.entry) == [
            .plistPath(filePath: resolved(plist), key: "blob", path: place, original: .integer(1), strategy: .cfPreferences, codec: codec),
        ])

        try await access.undo(path: place, key: "blob", in: plist)
        #expect(try await access.value(at: place, key: "blob", in: plist, codec: codec) == .integer(1))
        #expect(try onDisk()["keep"] as? String == "me")
        #expect(await journal.records().isEmpty)
    }

    @Test func aCodecThatIsNotRegisteredWritesNothingAndTheEntryStays() async throws {
        let inner = try PropertyListSerialization.data(fromPropertyList: ["x": 1], format: .xml, options: 0)
        try writePlist(["blob": inner])
        let before = try Data(contentsOf: plist)
        let journal = makeJournal()
        let access = PlistFileAccess(journal: journal, paths: paths, grants: nil, io: ScriptedService(.followsTheFile).io, clock: clock)
        let unknown = PlistBlobCodecID(rawValue: "nope")

        await #expect(throws: PlistAccessError.codecMissing("nope")) {
            try await access.write([PathEdit(path: [.key("x")], value: .integer(2))], key: "blob", in: plist, codec: unknown)
        }
        await #expect(throws: PlistAccessError.codecMissing("nope")) {
            try await access.value(at: [.key("x")], key: "blob", in: plist, codec: unknown)
        }
        #expect(await journal.records().isEmpty)
        #expect(backupNames().isEmpty)
        #expect(try Data(contentsOf: plist) == before)

        // An entry a newer build made, for a codec this one doesn't have: it can't be put back, and stays.
        let entry = JournalEntry.plistPath(filePath: resolved(plist), key: "blob", path: [.key("x")], original: .integer(1),
                                           strategy: .cfPreferences, codec: unknown)
        try await journal.record(entry)
        let failures = await journal.replay(using: PlistJournalRestorer(access: access, grants: try makeGrants()))
        #expect(failures.map(\.key) == [Journal.key(for: entry)])
        #expect(failures.first?.message == PlistAccessError.codecMissing("nope").errorDescription)
        #expect(await journal.records().map(\.entry) == [entry])
        #expect(try Data(contentsOf: plist) == before)
    }
}
