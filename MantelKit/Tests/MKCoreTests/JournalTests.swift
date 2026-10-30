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

/// A restorer whose first restore cancels the replay (as the cap does), and that notes what it was asked and what it restored.
private final class CancellingRestorer: JournalRestoring {
    private let log = Mutex<(restored: [String], asked: [String])>(([], []))

    var restored: [String] { log.withLock { $0.restored } }
    var asked: [String] { log.withLock { $0.asked } }

    func restore(_ entry: JournalEntry) async throws {
        log.withLock { $0.restored.append(Journal.key(for: entry)) }
        withUnsafeCurrentTask { $0?.cancel() }
    }

    func stillHolds(_ written: WrittenValue, for entry: JournalEntry) async -> Bool? {
        log.withLock { $0.asked.append(Journal.key(for: entry)) }
        return true
    }
}

/// What the system holds, in memory: a restorer that puts a place back the way the real one does, by an inverse edit on the
/// value as it is when the replay gets there, and that can say whether the system still holds what Mantel wrote.
private final class InMemoryPlist: JournalRestoring {
    private let top: Mutex<PlistValue>

    init(_ top: PlistValue) {
        self.top = Mutex(top)
    }

    var value: PlistValue { top.withLock { $0 } }

    /// What the person, or macOS, does to the setting meanwhile.
    func change(_ value: PlistValue?, at path: PlistKeyPath) throws {
        try top.withLock { $0 = try $0.setting(value, at: path) }
    }

    func restore(_ entry: JournalEntry) async throws {
        guard case .plistPath(_, _, let path, let original, _, _) = entry else { throw RestoreError() }
        try change(original, at: path)
    }

    func stillHolds(_ written: WrittenValue, for entry: JournalEntry) async -> Bool? {
        guard case .plistPath(_, _, let path, _, _, _) = entry else { return nil }
        let now = value.value(at: path)
        switch written {
        case .value(let value): return now == value
        case .removed: return now == nil
        }
    }
}

/// A restorer with a fixed answer to "does the system still hold what Mantel wrote?", that notes what it was asked and what it
/// restored.
private final class AnsweringRestorer: JournalRestoring {
    private let answer: Bool?
    private let log = Mutex<(restored: [String], asked: [String])>(([], []))

    init(stillHolds answer: Bool?) {
        self.answer = answer
    }

    var restored: [String] { log.withLock { $0.restored } }
    var asked: [String] { log.withLock { $0.asked } }

    func restore(_ entry: JournalEntry) async throws {
        log.withLock { $0.restored.append(Journal.key(for: entry)) }
    }

    func stillHolds(_ written: WrittenValue, for entry: JournalEntry) async -> Bool? {
        log.withLock { $0.asked.append(Journal.key(for: entry)) }
        return answer
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

    // MARK: Places inside a key

    private let table = "/Users/example/Library/Group Containers/com.apple.MenuBar/Library/Preferences/com.apple.MenuBar.plist"

    private func place(_ name: String, original: PlistValue?, in key: String = "Positions") -> JournalEntry {
        .plistPath(filePath: table, key: key, path: [.key("table"), .key(name)], original: original, strategy: .cfPreferences, codec: .none)
    }

    @Test func pathEntryReplaysAsInverseEditOnFreshRead() async throws {
        // Mantel changes one place of a table and records its original. Meanwhile the person (or macOS) changes another place.
        let system = InMemoryPlist(.dictionary(["table": .dictionary(["a": .integer(1), "b": .integer(2)])]))
        let journal = makeJournal()
        try await journal.record(place("a", original: .integer(1)))
        try system.change(.integer(9), at: [.key("table"), .key("a")])
        try system.change(.integer(5), at: [.key("table"), .key("b")])
        try system.change(.integer(7), at: [.key("table"), .key("c")])

        let failures = await journal.replay(using: system)

        #expect(failures.isEmpty)
        #expect(system.value == .dictionary(["table": .dictionary(["a": .integer(1), "b": .integer(5), "c": .integer(7)])]),
                "a is put back; b and c, which Mantel never changed, are as they are now")
        #expect(await journal.records().isEmpty)
    }

    @Test func pathEntryWithNoOriginalRemovesThePlace() async throws {
        let system = InMemoryPlist(.dictionary(["table": .dictionary(["b": .integer(2)])]))
        let journal = makeJournal()
        try await journal.record(place("a", original: nil))
        try system.change(.integer(9), at: [.key("table"), .key("a")])

        #expect(await journal.replay(using: system).isEmpty)
        #expect(system.value == .dictionary(["table": .dictionary(["b": .integer(2)])]))
    }

    @Test func firstOriginalWinsPerPath() async throws {
        let journal = makeJournal()
        try await journal.record(place("a", original: .integer(1)))
        clock.advance(by: .seconds(30))
        try await journal.record(place("a", original: .integer(9)))
        // Another path of the same key is a record of its own.
        try await journal.record(place("b", original: .integer(2)))
        // The same name under another key, or in another file, is not the same place.
        try await journal.record(place("a", original: .integer(3), in: "Other"))

        let records = await journal.records()
        #expect(records.map(\.entry) == [place("a", original: .integer(1)), place("b", original: .integer(2)),
                                         place("a", original: .integer(3), in: "Other")])
        #expect(records.first?.recordedAt == Date(timeIntervalSince1970: 1_700_000_000))
        #expect(try readFile().records == records)
    }

    @Test func pathEntryUnderWholeKeyEntryIsNotRecorded() async throws {
        let journal = makeJournal()
        let whole = JournalEntry.plistKey(filePath: table, key: "Positions", original: .dictionary(["table": .dictionary([:])]),
                                          strategy: .cfPreferences)
        try await journal.record(whole)
        try await journal.record(place("a", original: .integer(1)))
        #expect(await journal.records().map(\.entry) == [whole], "the whole original covers it")
        #expect(try readFile().records.map(\.entry) == [whole])

        // Another key of the file is not covered.
        try await journal.record(place("a", original: .integer(1), in: "Other"))
        #expect(await journal.records().count == 2)
    }

    @Test func pathKeysAreOneSegmentPerStepWithNamesEscaped() {
        func key(_ path: PlistKeyPath) -> String {
            Journal.key(for: .plistPath(filePath: "/p.plist", key: "K", path: path, original: nil, strategy: .cfPreferences, codec: .none))
        }
        #expect(key([.key("a"), .index(3), .matching(key: "bundle", value: "com.example.app")])
            == "plist:/p.plist#K/k:a/i:3/m:bundle=com.example.app")
        #expect(key([.key("a/b"), .key("c=d"), .key("50%")]) == "plist:/p.plist#K/k:a%2Fb/k:c%3Dd/k:50%25")
        #expect(key([.matching(key: "a=b", value: "c/d")]) == "plist:/p.plist#K/m:a%3Db=c%2Fd")
        // "%2F" typed by hand is not "/": the escape is reversible.
        #expect(key([.key("%2F")]) != key([.key("/")]))
        // The original, the strategy and the codec are not part of what is changed.
        let other = JournalEntry.plistPath(filePath: "/p.plist", key: "K", path: [.key("a")], original: .bool(true), strategy: .atomicFile,
                                           codec: PlistBlobCodecID(rawValue: "other"))
        #expect(Journal.key(for: other) == key([.key("a")]))
    }

    // MARK: What Mantel last wrote

    @Test func whatWasWrittenIsKeptWithTheRecord() async throws {
        let journal = makeJournal()
        let entry = place("a", original: .integer(1))
        try await journal.record(entry)
        #expect(await journal.records().first?.lastWritten == nil)

        try await journal.noteWritten(.value(.integer(9)), forKey: Journal.key(for: entry))
        #expect(await journal.records().first?.lastWritten == .value(.integer(9)))
        #expect(try readFile().records.first?.lastWritten == .value(.integer(9)), "on disk, not just in memory")
        #expect(await Journal(file: file, clock: clock).records().first?.lastWritten == .value(.integer(9)))

        try await journal.noteWritten(.removed, forKey: Journal.key(for: entry))
        #expect(await journal.records().first?.lastWritten == .removed)
        #expect(await journal.records().first?.recordedAt == Date(timeIntervalSince1970: 1_700_000_000), "when it was recorded doesn't change")

        // A key that isn't recorded is nothing to note.
        try await journal.noteWritten(.value(.bool(true)), forKey: "plist:/nowhere#nothing")
        #expect(await journal.records().count == 1)
    }

    // MARK: What the change made

    @Test func whatTheChangeCreatedIsKeptWithTheRecord() async throws {
        let journal = makeJournal()
        let entry = place("a", original: nil)
        try await journal.record(entry, createdContainers: 2)
        #expect(await journal.records().first?.createdContainers == 2)
        #expect(try readFile().records.first?.createdContainers == 2, "on disk, not just in memory")
        #expect(await Journal(file: file, clock: clock).records().first?.createdContainers == 2, "and after a restart")

        // First wins here too: the second change found the container its first one made, and made none.
        try await journal.record(entry, createdContainers: 0)
        #expect(await journal.records().first?.createdContainers == 2)
    }

    @Test func aRecordThatCreatedNothingHasNoFieldForIt() async throws {
        let journal = makeJournal()
        try await journal.record(place("a", original: .integer(1)))
        let object = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        let record = try #require((object["records"] as? [[String: Any]])?.first)
        #expect(record["createdContainers"] == nil, "a journal an earlier build wrote reads the same as one without any")
        #expect(try readFile().records.first?.createdContainers == nil)
    }

    // MARK: Old records

    private let eightDays = Duration.seconds(8 * 24 * 60 * 60)

    @Test func staleEntryChangedSinceIsDropped() async throws {
        // Mantel changed a place a week ago and was never quit properly. Since then someone else changed it again.
        let system = InMemoryPlist(.dictionary(["table": .dictionary(["a": .integer(1)])]))
        let journal = makeJournal()
        let entry = place("a", original: .integer(1))
        try await journal.record(entry)
        try system.change(.integer(9), at: [.key("table"), .key("a")])
        try await journal.noteWritten(.value(.integer(9)), forKey: Journal.key(for: entry))
        try system.change(.integer(42), at: [.key("table"), .key("a")])
        clock.advance(by: eightDays)

        let failures = await journal.replay(using: system)

        #expect(failures.isEmpty, "dropping it is not a failure")
        #expect(system.value == .dictionary(["table": .dictionary(["a": .integer(42)])]), "their change is not undone")
        #expect(await journal.records().isEmpty, "and the record is gone, not kept for the next launch")
        #expect(try readFile().records.isEmpty)
    }

    @Test func staleEntryStillHoldingIsRestored() async throws {
        let system = InMemoryPlist(.dictionary(["table": .dictionary(["a": .integer(1)])]))
        let journal = makeJournal()
        let entry = place("a", original: .integer(1))
        try await journal.record(entry)
        try system.change(.integer(9), at: [.key("table"), .key("a")])
        try await journal.noteWritten(.value(.integer(9)), forKey: Journal.key(for: entry))
        clock.advance(by: eightDays)

        #expect(await journal.replay(using: system).isEmpty)
        #expect(system.value == .dictionary(["table": .dictionary(["a": .integer(1)])]), "it still holds what Mantel wrote, so it is put back")
        #expect(await journal.records().isEmpty)
    }

    @Test(arguments: [true, nil] as [Bool?])
    func staleEntryThatStillHoldsOrCantBeToldIsRestored(answer: Bool?) async throws {
        let journal = makeJournal()
        let entry = place("a", original: .integer(1))
        try await journal.record(entry)
        try await journal.noteWritten(.value(.integer(9)), forKey: Journal.key(for: entry))
        clock.advance(by: eightDays)

        let restorer = AnsweringRestorer(stillHolds: answer)
        #expect(await journal.replay(using: restorer).isEmpty)
        #expect(restorer.asked == [Journal.key(for: entry)])
        #expect(restorer.restored == [Journal.key(for: entry)])
        #expect(await journal.records().isEmpty)
    }

    @Test(arguments: [Duration.seconds(60), .seconds(6 * 24 * 60 * 60), Journal.staleAge])
    func freshEntryIsRestoredWhateverItHolds(age: Duration) async throws {
        // Up to the seventh day, and on it, nothing is doubted: the system is not even asked.
        let journal = makeJournal()
        let entry = place("a", original: .integer(1))
        try await journal.record(entry)
        try await journal.noteWritten(.value(.integer(9)), forKey: Journal.key(for: entry))
        clock.advance(by: age)

        let restorer = AnsweringRestorer(stillHolds: false)
        #expect(await journal.replay(using: restorer).isEmpty)
        #expect(restorer.restored == [Journal.key(for: entry)])
        #expect(restorer.asked.isEmpty)
    }

    @Test func staleEntryThatNeverKnewWhatWasWrittenIsRestored() async throws {
        // A record an earlier version made, or one whose write didn't get as far as being noted.
        let journal = makeJournal()
        let entry = place("a", original: .integer(1))
        try await journal.record(entry)
        clock.advance(by: eightDays)

        let restorer = AnsweringRestorer(stillHolds: false)
        #expect(await journal.replay(using: restorer).isEmpty)
        #expect(restorer.restored == [Journal.key(for: entry)])
        #expect(restorer.asked.isEmpty)
    }

    @Test func cancelledReplayStopsBeforeTheNextRecord() async throws {
        // Two old records that know what Mantel wrote: each is checked against the system before it is put back. The cap cancels the
        // replay while the first is being restored; the second is not even looked at, and the journal is not written again.
        let journal = makeJournal()
        let older = place("a", original: .integer(1))
        let newer = place("b", original: .integer(2))
        for entry in [older, newer] {
            try await journal.record(entry)
            try await journal.noteWritten(.value(.integer(9)), forKey: Journal.key(for: entry))
        }
        clock.advance(by: eightDays)

        let restorer = CancellingRestorer()
        let task = Task { await journal.replay(using: restorer) }
        let failures = await task.value

        #expect(restorer.asked == [Journal.key(for: newer)], "the system was read for the first record and not for the second")
        #expect(restorer.restored == [Journal.key(for: newer)])
        #expect(await journal.records().map(\.key) == [Journal.key(for: older)], "the second is still there for the next launch")
        #expect(try readFile().records.map(\.key) == [Journal.key(for: older)])
        #expect(failures.map(\.key) == [Journal.key(for: older)], "and the replay says it left it")
    }

    @Test func aReplayCancelledBeforeItStartsDropsAndRestoresNothing() async throws {
        let journal = makeJournal()
        let entry = place("a", original: .integer(1))
        try await journal.record(entry)
        try await journal.noteWritten(.value(.integer(9)), forKey: Journal.key(for: entry))
        clock.advance(by: eightDays)

        let restorer = AnsweringRestorer(stillHolds: false)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await journal.replay(using: restorer)
        }
        let failures = await task.value

        #expect(restorer.asked.isEmpty && restorer.restored.isEmpty)
        #expect(failures.map(\.key) == [Journal.key(for: entry)])
        #expect(await journal.records().count == 1, "an old record that would have been dropped is kept for a replay that can finish")
    }

    @Test func theStaleAgeIsSevenDays() {
        #expect(Journal.staleAge == .seconds(604_800))
    }

    // MARK: What an earlier or a later build wrote

    @Test func unknownCodecDecodesAndStays() async throws {
        // A newer build recorded a place inside a value it keeps in a form this build doesn't know.
        let future = PlistBlobCodecID(rawValue: "future-codec")
        let entry = JournalEntry.plistPath(filePath: table, key: "Positions", path: [.matching(key: "bundle", value: "com.example.app"), .key("allowed")],
                                           original: .bool(true), strategy: .cfPreferences, codec: future)
        try await makeJournal().record(entry)

        let reopened = Journal(file: file, clock: clock)
        #expect(await reopened.records().map(\.entry) == [entry])
        #expect(try readFile().records.map(\.entry) == [entry])
        guard case .plistPath(_, _, _, _, _, let codec)? = await reopened.records().first?.entry else {
            Issue.record("the entry is a place inside a key")
            return
        }
        #expect(codec.rawValue == "future-codec")

        // Its restorer has no such codec, so it can't put it back: it stays for a build that has.
        let restorer = RecordingRestorer(failing: [Journal.key(for: entry)])
        #expect(await reopened.replay(using: restorer).count == 1)
        #expect(await reopened.records().map(\.entry) == [entry])
    }

    @Test func theCodecIsWrittenAsAPlainString() throws {
        let data = try JSONCoding.encoder().encode([PlistBlobCodecID.none, PlistBlobCodecID(rawValue: "approvals")])
        #expect(String(decoding: data, as: UTF8.self).contains("\"none\""))
        #expect(try JSONCoding.decoder().decode([PlistBlobCodecID].self, from: data) == [.none, PlistBlobCodecID(rawValue: "approvals")])
        #expect(PlistBlobCodecID.none.rawValue == "none")
    }

    @Test func m1JournalFileStillReads() async throws {
        // A journal as the first version wrote it: whole-key and `defaults` records, and no `lastWritten` anywhere.
        let json = """
        {
          "records" : [
            {
              "entry" : {
                "plistKey" : {
                  "filePath" : "/Users/example/Library/Group Containers/group.com.apple.controlcenter/approvals.plist",
                  "key" : "trackedApplications",
                  "original" : { "dictionary" : { "com.example.app" : { "bool" : true } } },
                  "strategy" : "atomicFile"
                }
              },
              "key" : "plist:/Users/example/Library/Group Containers/group.com.apple.controlcenter/approvals.plist#trackedApplications",
              "recordedAt" : "2023-11-14T22:13:20.000Z"
            },
            {
              "entry" : {
                "defaultsKey" : {
                  "currentHost" : true,
                  "domain" : "NSGlobalDomain",
                  "key" : "NSStatusItemSpacing"
                }
              },
              "key" : "defaults:NSGlobalDomain#NSStatusItemSpacing#true",
              "recordedAt" : "2023-11-14T22:14:00.000Z"
            }
          ]
        }
        """
        try fileManager.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(json.utf8).write(to: file)

        let journal = makeJournal()
        #expect(await journal.isUsable)
        let records = await journal.records()
        #expect(records.map(\.key) == [
            "plist:\(approvals)#trackedApplications",
            "defaults:NSGlobalDomain#NSStatusItemSpacing#true",
        ])
        #expect(records.map(\.entry) == [
            .plistKey(filePath: approvals, key: "trackedApplications", original: .dictionary(["com.example.app": .bool(true)]), strategy: .atomicFile),
            .defaultsKey(domain: "NSGlobalDomain", key: "NSStatusItemSpacing", currentHost: true, original: nil),
        ])
        #expect(records.allSatisfy { $0.lastWritten == nil })
        #expect(records.first?.recordedAt == Date(timeIntervalSince1970: 1_700_000_000))
        #expect(names(in: file.deletingLastPathComponent()) == ["journal.json"], "it wasn't set aside")

        // And it goes on from there: a record added is written next to the old ones, which are as they were.
        try await journal.record(place("a", original: nil))
        let written = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any]
        let objects = try #require(written?["records"] as? [[String: Any]])
        #expect(objects.count == 3)
        #expect(Set(objects[0].keys) == ["entry", "key", "lifetime", "recordedAt"], "no lastWritten where none is known; the lifetime is written")
    }

    // MARK: Taking back what a call recorded

    @Test func rollbackKeepsConcurrentWritersRecord() async throws {
        let journal = makeJournal()
        let mine = approval("mine", original: .integer(1))
        let shared = approval("shared", original: .integer(2))
        let theirs = approval("theirs", original: .integer(3))

        // This writer records a place, and is about to record another, and then to make its change.
        let first = try await journal.recordWithReceipt(mine)
        #expect(first.change == .added(recordedAt: Date(timeIntervalSince1970: 1_700_000_000)))
        // Meanwhile another writer (the layout writer next to the approvals engine) records a place of its own, and the one this writer is
        // about to record: it is there when this writer comes to it.
        clock.advance(by: .seconds(5))
        try await journal.record(theirs)
        try await journal.record(shared)
        let second = try await journal.recordWithReceipt(shared)
        #expect(second.change == .nothing, "it was there already, so it isn't this writer's")

        // This writer's change can't be made, and it takes back what it did.
        try await journal.rollBack(second)
        try await journal.rollBack(first)

        #expect(await journal.records().map(\.entry) == [theirs, shared], "the other writer's two records are as they were")
        #expect(try readFile().records.map(\.entry) == [theirs, shared])
    }

    @Test func rollbackKeepsARecordMadeAgainAfterThisOnesWasTakenOut() async throws {
        let journal = makeJournal()
        let entry = approval("a", original: .integer(1))
        let receipt = try await journal.recordWithReceipt(entry)

        // A replay put the place back and took its record out, and then another writer recorded it afresh, later.
        try await journal.remove(key: Journal.key(for: entry))
        clock.advance(by: .seconds(30))
        try await journal.record(approval("a", original: .integer(7)))

        try await journal.rollBack(receipt)
        let records = await journal.records()
        #expect(records.map(\.entry) == [approval("a", original: .integer(7))], "the same key, but not the record this call made")
        #expect(records.first?.recordedAt == Date(timeIntervalSince1970: 1_700_000_030))
    }

    @Test func rollbackOfAnUpgradeMakesTheRecordUntilQuitAgain() async throws {
        let journal = makeJournal()
        let entry = approval("a", original: .integer(1))
        try await journal.record(entry)
        let before = try #require(await journal.records().first)

        clock.advance(by: .seconds(5))
        let receipt = try await journal.recordWithReceipt(entry, lifetime: .kept)
        #expect(receipt.change == .upgraded(recordedAt: before.recordedAt))
        #expect(await journal.records().first?.lifetime == .kept)

        try await journal.rollBack(receipt)
        #expect(await journal.records() == [before], "as it was, to the last field")
        #expect(try readFile().records == [before])
    }

    @Test func aReceiptOfNothingTakesNothingBack() async throws {
        let journal = makeJournal()
        let entry = approval("a", original: .integer(1))
        try await journal.record(entry, lifetime: .kept)
        let receipt = try await journal.recordWithReceipt(entry, lifetime: .kept)
        #expect(receipt.change == .nothing)
        try await journal.rollBack(receipt)
        #expect(await journal.keptRecords().map(\.entry) == [entry])
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

    @Test func unreadableJournalIsNeverOverwritten() async throws {
        // A file that isn't a journal, in a folder that can't be written to: it can't be moved aside either.
        let state = file.deletingLastPathComponent()
        try fileManager.createDirectory(at: state, withIntermediateDirectories: true)
        let bytes = Data("{ not a journal".utf8)
        try bytes.write(to: file)
        try fileManager.setAttributes([.posixPermissions: 0o500], ofItemAtPath: state.path)
        defer { try? fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: state.path) }
        let journal = makeJournal()
        // The folder can be written to again by the time something records: the file is still not to be replaced.
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: state.path)

        #expect(await journal.isUsable == false)
        let expected = JournalError.unreadable(path: file.path(percentEncoded: false))
        await #expect(throws: expected) { try await journal.record(approval("a", original: .integer(1))) }
        await #expect(throws: expected) { try await journal.noteWritten(.removed, forKey: "plist:x#a") }
        #expect(try Data(contentsOf: file) == bytes, "the bytes are as they were")
        #expect(names(in: state) == ["journal.json"], "nothing was set aside, and nothing else was written")

        // A replay restores nothing, and says why as its one failure.
        let restorer = RecordingRestorer()
        let failures = await journal.replay(using: restorer)
        #expect(failures.count == 1)
        #expect(failures.first?.message == "Mantel's journal at \(file.path(percentEncoded: false)) couldn't be read, so Mantel won't change system files. Move the file away and open Mantel again.")
        #expect(restorer.restored.isEmpty)
        #expect(try Data(contentsOf: file) == bytes)
    }

    @Test func aReplayWithACapOfAnUnreadableJournalReportsTheSameFailure() async throws {
        let state = file.deletingLastPathComponent()
        try fileManager.createDirectory(at: state, withIntermediateDirectories: true)
        try Data("{ not a journal".utf8).write(to: file)
        try fileManager.setAttributes([.posixPermissions: 0o500], ofItemAtPath: state.path)
        defer { try? fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: state.path) }
        let journal = makeJournal()

        let outcome = await journal.replay(using: RecordingRestorer(), cap: .seconds(2), clock: clock)

        guard case .completed(let failures) = outcome else {
            Issue.record("the replay should have ended at once, not at its cap: \(outcome)")
            return
        }
        #expect(failures.count == 1)
        #expect(failures.first?.message.hasPrefix("Mantel's journal at ") == true)
    }

    @Test func aJournalThatCouldBeSetAsideIsUsable() async throws {
        try fileManager.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{ nope".utf8).write(to: file)
        let journal = makeJournal()
        #expect(await journal.isUsable)
        #expect(await makeJournal().isUsable, "and so is one that was never there")
    }

    @Test func aMissingJournalIsEmptyAndMakesNoFile() async {
        let journal = makeJournal()
        #expect(await journal.records().isEmpty)
        #expect(!fileManager.fileExists(atPath: file.path))
    }
}
