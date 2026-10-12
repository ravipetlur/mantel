import Foundation
import MKCore
import MKTestSupport
import Testing

@testable import MKMenuBar

/// What the preferences service does after a write, and what a list that has an entry twice does to a record: the cases the approvals
/// engine runs into, because it writes the same places again and again within a few seconds.
@Suite("Plist file access: writes close together", .timeLimit(.minutes(1)))
struct PlistFileAccessLagTests {
    /// Held by the suite, and so for the whole test.
    let folder = TemporaryFolder(prefix: "mantel-plist-lag")
    /// Its sleeps return at once, having moved the time on: the 2 s wait for the file to agree costs no real time.
    let clock = SteppingClock()

    private var paths: MantelPaths {
        MantelPaths(root: folder.url.appending(path: "Mantel", directoryHint: .isDirectory),
                    logs: folder.url.appending(path: "Logs", directoryHint: .isDirectory))
    }

    private var plist: URL { folder.url.appending(path: "sample.plist") }
    private func makeJournal() -> Journal { Journal(file: folder.url.appending(path: "journal.json"), clock: clock) }

    private func writePlist(_ dictionary: [String: Any]) throws {
        try PropertyListSerialization.data(fromPropertyList: dictionary, format: .binary, options: 0).write(to: plist)
    }

    private func onDisk() throws -> [String: Any] {
        let data = try Data(contentsOf: plist)
        return try #require(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
    }

    private func makeAccess(_ journal: Journal, _ service: ScriptedService) -> PlistFileAccess {
        PlistFileAccess(journal: journal, paths: paths, grants: nil, io: service.io, clock: clock)
    }

    // MARK: A write right after an undo

    @Test func writeRightAfterUndoPassesTheCheckWhileTheFlushIsPending() async throws {
        try writePlist(["table": ["a": 1, "b": 5]])
        let journal = makeJournal()
        let service = ScriptedService(.aheadOfTheFile)
        let access = makeAccess(journal, service)
        let place: PlistKeyPath = [.key("a")]

        // Run 1: change the place; the service has it, and by the time of the undo the file does too.
        try await access.write([PathEdit(path: place, value: .integer(2))], key: "table", in: plist)
        try service.flush(to: plist)
        // The undo puts the original back through the service, which hasn't given it to the file yet.
        try await access.undo(path: place, key: "table", in: plist)
        #expect(try await access.value(at: place, key: "table", in: plist) == .integer(1), "the service has the original")
        let table = try #require(onDisk()["table"] as? [String: Int])
        #expect(table["a"] == 2, "the file still has run 1's value: the flush of the undo is pending")
        #expect(await journal.records().isEmpty)

        // Run 2: the service and the file disagree, and what the service holds is what Mantel put there last: its own undo.
        let before = clock.now()
        try await access.write([PathEdit(path: place, value: .integer(3))], key: "table", in: plist)

        #expect(clock.now().timeIntervalSince(before) >= 2, "it gave the file its 2 s first")
        #expect(try await access.value(at: place, key: "table", in: plist) == .integer(3))
        let records = await journal.records()
        #expect(records.count == 1)
        guard case .plistPath(_, _, _, let original, _, _)? = records.first?.entry else {
            Issue.record("the change is journaled")
            return
        }
        #expect(original == .integer(1), "the original is what the service held: the undo's value")
    }

    @Test func aChangeBySomeoneElseAfterTheUndoStillRefuses() async throws {
        try writePlist(["table": ["a": 1]])
        let journal = makeJournal()
        let service = ScriptedService(.aheadOfTheFile)
        let access = makeAccess(journal, service)
        let place: PlistKeyPath = [.key("a")]

        try await access.write([PathEdit(path: place, value: .integer(2))], key: "table", in: plist)
        try service.flush(to: plist)
        try await access.undo(path: place, key: "table", in: plist)
        // Then the person changes it in System Settings: the service has that, and the file has neither it nor the undo yet.
        service.someoneElseWrites(.dictionary(["a": .integer(7)]), key: "table")

        await #expect(throws: PlistAccessError.disagree(key: "table")) {
            try await access.write([PathEdit(path: place, value: .integer(3))], key: "table", in: plist)
        }
        #expect(await journal.records().isEmpty, "nothing was journaled for a write that was refused")
    }

    @Test func theReplayRestorerAlsoRemembersWhatItPutBack() async throws {
        try writePlist(["table": ["a": 1]])
        let journal = makeJournal()
        let service = ScriptedService(.aheadOfTheFile)
        let access = makeAccess(journal, service)
        let place: PlistKeyPath = [.key("a")]
        try await access.write([PathEdit(path: place, value: .integer(2))], key: "table", in: plist)
        try service.flush(to: plist)

        // The replay (a quit, or the next launch) puts it back, and removes the record.
        try paths.createDirectories()
        let grants = FileGrantStore(store: SettingsStore(paths: paths), bookmarkOptions: [], clock: clock)
        let restorer = PlistJournalRestorer(access: access, grants: grants)
        #expect(await journal.replay(using: restorer).isEmpty)
        #expect(await journal.records().isEmpty)

        try await access.write([PathEdit(path: place, value: .integer(3))], key: "table", in: plist)
        #expect(try await access.value(at: place, key: "table", in: plist) == .integer(3))
    }

    // MARK: An entry that is in a list twice

    private let way: [KeyPathStep] = [.key("menuItemLocations"), .anyElement, .key("bundle"), .key("_0")]

    private func entry(_ id: String, allowed: Bool) -> [String: Any] {
        ["isAllowed": allowed, "menuItemLocations": [["bundle": ["_0": id]]]]
    }

    private func writeList(_ entries: [[String: Any]]) throws {
        try writePlist(["tracked": try PropertyListSerialization.data(fromPropertyList: entries, format: .binary, options: 0)])
    }

    @Test func stillHoldsCantTellWhenTheEntryIsDoubled() async throws {
        let flag: PlistKeyPath = [.matchingPath(path: way, value: "com.example.app"), .key("isAllowed")]
        let list = [entry("com.example.other", allowed: true), entry("com.example.app", allowed: false)]
        try writeList(list)
        let codecs = [PlistBlobCodecs.nested: NestedPlistCodec() as any PlistBlobCodec]
        let access = PlistFileAccess(journal: makeJournal(), paths: paths, grants: nil, codecs: codecs,
                                     io: ScriptedService(.followsTheFile).io, clock: clock)
        let entryOfTheApp = JournalEntry.plistPath(filePath: plist.resolvingSymlinksInPath().path(percentEncoded: false), key: "tracked",
                                                   path: flag, original: .bool(true), strategy: .cfPreferences, codec: PlistBlobCodecs.nested)

        #expect(await access.stillHolds(.value(.bool(false)), for: entryOfTheApp, grants: nil) == true, "the switch is as Mantel left it")
        #expect(await access.stillHolds(.value(.bool(true)), for: entryOfTheApp, grants: nil) == false, "someone changed it")

        // The list now has the app twice (macOS wrote another entry for it): which one is Mantel's is not known.
        try writeList(list + [entry("com.example.app", allowed: true)])
        #expect(await access.stillHolds(.value(.bool(false)), for: entryOfTheApp, grants: nil) == nil)
        #expect(await access.stillHolds(.value(.bool(true)), for: entryOfTheApp, grants: nil) == nil)

        // An entry that is gone is a change; a list that is reordered is not.
        try writeList([entry("com.example.other", allowed: true)])
        #expect(await access.stillHolds(.value(.bool(false)), for: entryOfTheApp, grants: nil) == false)
        try writeList(Array(list.reversed()))
        #expect(await access.stillHolds(.value(.bool(false)), for: entryOfTheApp, grants: nil) == true)
    }

    // MARK: A path that is built wrongly

    @Test func aNestedMatchingPathWriteIsRefusedBeforeAnythingIsJournaled() async throws {
        try writePlist(["table": ["a": 1]])
        let before = try Data(contentsOf: plist)
        let journal = makeJournal()
        let access = makeAccess(journal, ScriptedService(.followsTheFile))
        let nested: PlistKeyPath = [.key("list"), .matchingPath(path: [.matchingPath(path: [.key("x")], value: "y")], value: "z"), .key("flag")]

        await #expect(throws: PlistAccessError.path(.nestedMatchingPath(step: 1))) {
            try await access.write([PathEdit(path: [.key("a")], value: .integer(2)), PathEdit(path: nested, value: .bool(false))],
                                   key: "table", in: plist)
        }
        #expect(await journal.records().isEmpty, "not even the edit before it")
        #expect(try Data(contentsOf: plist) == before)
        #expect(!FileManager.default.fileExists(atPath: paths.backups.path), "and nothing was backed up")
    }
}
