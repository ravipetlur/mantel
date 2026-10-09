import Foundation
import MKCore
import MKTestSupport
import Synchronization
import Testing

@testable import MKCore

/// A restorer that notes what it was asked to restore, in order, and fails for the keys it was told to.
private final class RecordingRestorer: JournalRestoring {
    private let restoredEntries = Mutex<[JournalEntry]>([])
    private let failingKeys: Set<String>

    init(failing: Set<String> = []) {
        failingKeys = failing
    }

    var restored: [JournalEntry] { restoredEntries.withLock { $0 } }

    func restore(_ entry: JournalEntry) async throws {
        if failingKeys.contains(Journal.key(for: entry)) { throw RestoreError() }
        restoredEntries.withLock { $0.append(entry) }
    }
}

/// A restorer that runs a closure for each entry, so that a test can do something while the journal waits for it.
private final class ClosureRestorer: JournalRestoring {
    private let body: @Sendable (JournalEntry) async throws -> Void

    init(_ body: @escaping @Sendable (JournalEntry) async throws -> Void) {
        self.body = body
    }

    func restore(_ entry: JournalEntry) async throws {
        try await body(entry)
    }
}

private struct RestoreError: LocalizedError {
    var errorDescription: String? { "the file is locked" }
}

/// What `record` did when it was called: the replay is waiting for a restorer when these calls are made, and the
/// journal answers them in the meantime.
private func attemptToRecord(_ entry: JournalEntry, in journal: Journal) async -> String {
    do {
        try await journal.record(entry)
        return "recorded"
    } catch JournalError.replayInProgress {
        return "replayInProgress"
    } catch {
        return "other: \(error)"
    }
}

/// What a journal file holds.
private struct OnDisk: Decodable {
    var records: [JournalRecord]
}

@Suite("Journal", .timeLimit(.minutes(1)))
struct JournalTests {
    /// Held by the suite, and so for the whole test: the folder is deleted when the test is over.
    let folder = TemporaryFolder(prefix: "mantel-journal")
    let clock = FakeClock(now: Date(timeIntervalSince1970: 1_700_000_000))
    private let fileManager = FileManager.default

    private var file: URL { folder.url.appending(path: "State/journal.json") }

    private func makeJournal() -> Journal { Journal(file: file, clock: clock) }

    private func readFile() throws -> OnDisk {
        try JSONCoding.decoder().decode(OnDisk.self, from: Data(contentsOf: file))
    }

    private let approvals = "/Users/example/Library/Group Containers/group.com.apple.controlcenter/approvals.plist"
    private let layout = "/Users/example/Library/Preferences/com.apple.controlcenter.plist"

    private func approval(_ app: String, original: PlistValue?) -> JournalEntry {
        .plistKey(filePath: approvals, key: app, original: original, strategy: .atomicFile)
    }

    // MARK: Recording

    @Test func recordIsDurableBeforeReturning() async throws {
        let journal = makeJournal()
        let entry = approval("com.example.app", original: .integer(1))
        try await journal.record(entry)

        // Read at once, with nothing else asked of the journal, and from the file, not from the journal's memory.
        let onDisk = try readFile()
        #expect(onDisk.records.count == 1)
        #expect(onDisk.records.first?.entry == entry)
        #expect(onDisk.records.first?.key == "plist:\(approvals)#com.example.app")
        #expect(onDisk.records.first?.recordedAt == Date(timeIntervalSince1970: 1_700_000_000))
        // A second journal on the file, as after a crash, finds it.
        #expect(await Journal(file: file, clock: clock).records().map(\.entry) == [entry])
    }

    @Test func theFileIsAnObjectWithARecordsArray() async throws {
        let journal = makeJournal()
        try await journal.record(approval("a", original: nil))
        let object = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        #expect(Array(object.keys) == ["records"])
        #expect((object["records"] as? [Any])?.count == 1)
    }

    @Test func theFileIsMode0600InAPrivateFolder() async throws {
        let journal = makeJournal()
        try await journal.record(approval("a", original: nil))
        func mode(_ url: URL) throws -> Int? { try fileManager.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int }
        #expect(try mode(file) == 0o600)
        #expect(try mode(file.deletingLastPathComponent()) == 0o700)
        // Rewritten, it stays private.
        try await journal.record(approval("b", original: nil))
        #expect(try mode(file) == 0o600)
        #expect(names(in: file.deletingLastPathComponent()) == ["journal.json"], "no temporary file is left")
    }

    private func names(in folder: URL) -> [String] {
        ((try? fileManager.contentsOfDirectory(atPath: folder.path)) ?? []).sorted()
    }

    @Test func firstOriginalWins() async throws {
        let journal = makeJournal()
        try await journal.record(approval("com.example.app", original: .integer(1)))
        clock.advance(by: .seconds(30))
        // The same key again, after something changed it: what's recorded is still the value from before the first change.
        try await journal.record(approval("com.example.app", original: .integer(2)))
        try await journal.record(.plistKey(filePath: approvals, key: "com.example.app", original: nil, strategy: .cfPreferences))

        let records = await journal.records()
        #expect(records.count == 1)
        #expect(records.first?.entry == approval("com.example.app", original: .integer(1)))
        #expect(records.first?.recordedAt == Date(timeIntervalSince1970: 1_700_000_000), "the first record's time too")
        #expect(try readFile().records == records)
    }

    @Test func aKeyThatDidNotExistIsRecordedAsNoOriginal() async throws {
        let journal = makeJournal()
        try await journal.record(approval("new.app", original: nil))
        try await journal.record(approval("new.app", original: .integer(5)))
        let reopened = await Journal(file: file, clock: clock).records()
        #expect(reopened.map(\.entry) == [approval("new.app", original: nil)], "nil stays nil, and isn't replaced by a later value")
    }

    @Test func differentKeysFilesAndKindsAreRecordedSeparately() async throws {
        let journal = makeJournal()
        let entries: [JournalEntry] = [
            approval("a", original: .integer(1)),
            approval("b", original: .integer(2)),
            .plistKey(filePath: layout, key: "a", original: .bool(true), strategy: .cfPreferences),
            .defaultsKey(domain: "NSGlobalDomain", key: "a", currentHost: true, original: .real(1.5)),
            .defaultsKey(domain: "NSGlobalDomain", key: "a", currentHost: false, original: .string("x")),
        ]
        for entry in entries { try await journal.record(entry) }
        #expect(await journal.records().map(\.entry) == entries, "all five, in the order they were recorded")
        #expect(Set(await journal.records().map(\.key)).count == 5)
    }

    @Test func recordedAtComesFromTheClock() async throws {
        let journal = makeJournal()
        try await journal.record(approval("a", original: nil))
        clock.advance(by: .seconds(90))
        try await journal.record(approval("b", original: nil))
        let times = try readFile().records.map(\.recordedAt)
        #expect(times == [Date(timeIntervalSince1970: 1_700_000_000), Date(timeIntervalSince1970: 1_700_000_090)])
    }

    @Test func recordThrowsAndKeepsWhatItHadWhenTheFileCantBeWritten() async throws {
        let journal = makeJournal()
        try await journal.record(approval("a", original: .integer(1)))
        let state = file.deletingLastPathComponent()
        try fileManager.setAttributes([.posixPermissions: 0o500], ofItemAtPath: state.path)
        defer { try? fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: state.path) }

        await #expect(throws: (any Error).self) { try await journal.record(approval("b", original: .integer(2))) }
        #expect(await journal.records().map(\.key) == ["plist:\(approvals)#a"], "a record that isn't on disk isn't kept")
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: state.path)
        #expect(try readFile().records.count == 1)
        // And once the folder can be written again, the same record goes in.
        try await journal.record(approval("b", original: .integer(2)))
        #expect(await journal.records().count == 2)
    }

    // MARK: Remove

    @Test func removeTakesOutOneRecordAndKeepsTheRestInOrder() async throws {
        let journal = makeJournal()
        let a = approval("a", original: nil), b = approval("b", original: nil), c = approval("c", original: nil)
        for entry in [a, b, c] { try await journal.record(entry) }
        try await journal.remove(key: Journal.key(for: b))
        #expect(await journal.records().map(\.entry) == [a, c])
        #expect(try readFile().records.map(\.entry) == [a, c])
        // A key that isn't there is nothing to remove.
        try await journal.remove(key: "plist:/nowhere#nothing")
        #expect(await journal.records().count == 2)
    }

    @Test func aRemovedKeyCanBeRecordedAgainWithItsNewOriginal() async throws {
        let journal = makeJournal()
        try await journal.record(approval("a", original: .integer(1)))
        try await journal.remove(key: Journal.key(for: approval("a", original: nil)))
        try await journal.record(approval("a", original: .integer(7)))
        #expect(await journal.records().map(\.entry) == [approval("a", original: .integer(7))])
    }

    // MARK: Replay

    @Test func replayIsReverseOrder() async throws {
        let journal = makeJournal()
        let entries = (1 ... 4).map { approval("app\($0)", original: .integer($0)) }
        for entry in entries { try await journal.record(entry) }

        let restorer = RecordingRestorer()
        let failures = await journal.replay(using: restorer)
        #expect(failures.isEmpty)
        #expect(restorer.restored == Array(entries.reversed()))
    }

    @Test func successfulReplayRemovesEntries() async throws {
        let journal = makeJournal()
        for name in ["a", "b", "c"] { try await journal.record(approval(name, original: .integer(1))) }
        _ = await journal.replay(using: RecordingRestorer())
        #expect(await journal.records().isEmpty)
        #expect(try readFile().records.isEmpty)
        #expect(await Journal(file: file, clock: clock).records().isEmpty, "nothing is replayed twice at the next launch")

        // With nothing left, a replay has nothing to do.
        let restorer = RecordingRestorer()
        #expect(await journal.replay(using: restorer).isEmpty)
        #expect(restorer.restored.isEmpty)
    }

    @Test func failedEntryStaysAndIsReported() async throws {
        let journal = makeJournal()
        let a = approval("a", original: .integer(1)), b = approval("b", original: .integer(2)), c = approval("c", original: .integer(3))
        for entry in [a, b, c] { try await journal.record(entry) }

        let restorer = RecordingRestorer(failing: [Journal.key(for: b)])
        let failures = await journal.replay(using: restorer)

        #expect(failures == [ReplayFailure(key: Journal.key(for: b), message: "the file is locked")])
        #expect(restorer.restored == [c, a], "the others are restored, the one after the failure too")
        #expect(await journal.records().map(\.entry) == [b], "only the failed one stays")
        #expect(try readFile().records.map(\.entry) == [b])
    }

    @Test func aFailedEntryIsTriedAgainAtTheNextReplay() async throws {
        let journal = makeJournal()
        let b = approval("b", original: .integer(2))
        try await journal.record(b)
        #expect(await journal.replay(using: RecordingRestorer(failing: [Journal.key(for: b)])).count == 1)

        let later = RecordingRestorer()
        #expect(await journal.replay(using: later).isEmpty)
        #expect(later.restored == [b])
        #expect(await journal.records().isEmpty)
    }

    @Test func replayAfterRelaunchRestoresFirstOriginalsInReverse() async throws {
        // The first run changes three things, one of them twice, and then crashes.
        let firstRun = makeJournal()
        let approvalsA = approval("com.example.a", original: .integer(1))
        let layoutKey = JournalEntry.plistKey(filePath: layout, key: "NSStatusItem Preferred Position Item-0",
                                              original: .real(120), strategy: .cfPreferences)
        let spacing = JournalEntry.defaultsKey(domain: "NSGlobalDomain", key: "NSStatusItemSpacing", currentHost: true, original: nil)
        try await firstRun.record(approvalsA)
        try await firstRun.record(layoutKey)
        try await firstRun.record(approval("com.example.a", original: .integer(0)))   // changed again: the 1 stays
        try await firstRun.record(spacing)
        try await firstRun.record(.plistKey(filePath: layout, key: "NSStatusItem Preferred Position Item-0",
                                            original: .real(999), strategy: .cfPreferences))

        // The next launch: a journal instance on the same file, and nothing else from the first run.
        let secondRun = Journal(file: file, clock: clock)
        #expect(await secondRun.records().count == 3)
        let restorer = RecordingRestorer()
        let failures = await secondRun.replay(using: restorer)

        #expect(failures.isEmpty)
        #expect(restorer.restored == [spacing, layoutKey, approvalsA], "reverse order, the originals from before the first change")
        #expect(await secondRun.records().isEmpty)
        #expect(await Journal(file: file, clock: clock).records().isEmpty, "a third launch has nothing to do")
    }

    // MARK: Record during a replay

    /// A record that returns normally is a promise that the change after it is protected. During a replay it can't be
    /// kept: for the key being restored, the replay removes the entry as soon as the restorer returns; for a key it hasn't
    /// reached yet, the replay restores the original underneath the caller. So `record` throws, and the caller doesn't
    /// make its change.
    @Test func recordingTheKeyBeingRestoredThrowsInsteadOfPromisingAProtectionThatIsRemoved() async throws {
        let journal = makeJournal()
        let entry = approval("com.example.a", original: .integer(1))
        try await journal.record(entry)

        let again = approval("com.example.a", original: .integer(2))
        let outcomes = Mutex<[String]>([])
        let restorer = ClosureRestorer { restored in
            let outcome = await attemptToRecord(again, in: journal)
            outcomes.withLock { $0.append(outcome) }
            #expect(restored == entry)
        }
        let failures = await journal.replay(using: restorer)

        #expect(failures.isEmpty)
        #expect(outcomes.withLock { $0 } == ["replayInProgress"])
        #expect(await journal.records().isEmpty, "the replay restored the entry and removed it; the refused record added nothing")
        #expect(try readFile().records.isEmpty)
    }

    @Test func recordingAKeyTheReplayHasNotReachedYetThrowsAndItIsStillRestored() async throws {
        let journal = makeJournal()
        let first = approval("com.example.a", original: .integer(1))
        let second = approval("com.example.b", original: .integer(2))
        try await journal.record(first)
        try await journal.record(second)

        // The replay goes second, then first. While it restores the second, something asks to record the first.
        let firstAgain = approval("com.example.a", original: .integer(99))
        let outcomes = Mutex<[String]>([])
        let restoredEntries = Mutex<[JournalEntry]>([])
        let restorer = ClosureRestorer { restored in
            restoredEntries.withLock { $0.append(restored) }
            if restored == second {
                let outcome = await attemptToRecord(firstAgain, in: journal)
                outcomes.withLock { $0.append(outcome) }
            }
        }
        let failures = await journal.replay(using: restorer)

        #expect(failures.isEmpty)
        #expect(outcomes.withLock { $0 } == ["replayInProgress"])
        #expect(restoredEntries.withLock { $0 } == [second, first], "the first original is restored, as recorded")
        #expect(await journal.records().isEmpty)
        #expect(try readFile().records.isEmpty)
    }

    @Test func recordingAnyOtherKeyDuringAReplayThrowsToo() async throws {
        let journal = makeJournal()
        try await journal.record(approval("old", original: .integer(1)))

        let new = approval("new", original: .integer(2))
        let outcomes = Mutex<[String]>([])
        let restorer = ClosureRestorer { _ in
            let outcome = await attemptToRecord(new, in: journal)
            outcomes.withLock { $0.append(outcome) }
        }
        _ = await journal.replay(using: restorer)

        #expect(outcomes.withLock { $0 } == ["replayInProgress"])
        #expect(await journal.records().isEmpty, "nothing was recorded for a change that must not be made")
        #expect(try readFile().records.isEmpty)
    }

    @Test func recordingWorksAgainOnceTheReplayIsOver() async throws {
        let journal = makeJournal()
        let failing = approval("stays", original: .integer(1))
        try await journal.record(failing)
        let failures = await journal.replay(using: RecordingRestorer(failing: [Journal.key(for: failing)]))
        #expect(failures.count == 1)

        // A replay with failures ends the same way as one without: the journal takes records again.
        let later = approval("later", original: .integer(2))
        try await journal.record(later)
        #expect(await journal.records().map(\.entry) == [failing, later])
        #expect(try readFile().records.map(\.entry) == [failing, later])
    }

    // MARK: Keys

    @Test func keysAreStable() {
        #expect(Journal.key(for: .plistKey(filePath: "/Users/example/Library/Preferences/x.plist", key: "some key",
                                           original: .integer(1), strategy: .atomicFile))
            == "plist:/Users/example/Library/Preferences/x.plist#some key")
        #expect(Journal.key(for: .defaultsKey(domain: "com.apple.controlcenter", key: "NSStatusItem Visible Item-0",
                                              currentHost: true, original: nil))
            == "defaults:com.apple.controlcenter#NSStatusItem Visible Item-0#true")
        #expect(Journal.key(for: .defaultsKey(domain: "NSGlobalDomain", key: "NSStatusItemSpacing",
                                              currentHost: false, original: .integer(4)))
            == "defaults:NSGlobalDomain#NSStatusItemSpacing#false")
    }

    @Test func aKeyDoesNotDependOnTheOriginalOrTheStrategy() {
        let path = "/p.plist"
        let keys = [
            Journal.key(for: .plistKey(filePath: path, key: "k", original: nil, strategy: .atomicFile)),
            Journal.key(for: .plistKey(filePath: path, key: "k", original: .string("x"), strategy: .atomicFile)),
            Journal.key(for: .plistKey(filePath: path, key: "k", original: .bool(true), strategy: .cfPreferences)),
        ]
        #expect(Set(keys).count == 1)
    }

    @Test func theKeyInTheRecordIsTheKeyOfTheEntry() async throws {
        let journal = makeJournal()
        let entry = JournalEntry.defaultsKey(domain: "d", key: "k", currentHost: true, original: .data(Data([1, 2])))
        try await journal.record(entry)
        #expect(await journal.records().first?.key == Journal.key(for: entry))
    }

    // MARK: Damaged files

    @Test func aCorruptJournalIsSetAsideAndTheJournalStartsEmpty() async throws {
        try fileManager.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{ not a journal".utf8).write(to: file)

        let journal = makeJournal()
        #expect(await journal.records().isEmpty)
        let setAside = names(in: file.deletingLastPathComponent()).filter { $0 != "journal.json" }
        #expect(setAside.count == 1)
        let name = try #require(setAside.first)
        #expect(name.wholeMatch(of: #/journal-corrupt-\d{8}-\d{6}\.json/#) != nil, "named \(name)")
        #expect(try String(contentsOf: file.deletingLastPathComponent().appending(path: name), encoding: .utf8) == "{ not a journal")

        // The journal works from there.
        try await journal.record(approval("a", original: nil))
        #expect(try readFile().records.count == 1)
    }

    @Test func aMissingJournalIsEmptyAndMakesNoFile() async {
        let journal = makeJournal()
        #expect(await journal.records().isEmpty)
        #expect(!fileManager.fileExists(atPath: file.path))
    }
}
