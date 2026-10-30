import Foundation
import MKCore
import MKTestSupport
import Synchronization
import Testing

@testable import MKMenuBar

/// A restorer that notes what it was asked to restore, newest first as the journal goes, and says what it is told when asked whether
/// the system still holds what Mantel wrote.
private final class NotingRestorer: JournalRestoring {
    private let log = Mutex<(restored: [JournalEntry], asked: [String])>(([], []))
    private let answer: Bool?

    init(stillHolds answer: Bool? = nil) {
        self.answer = answer
    }

    var restored: [JournalEntry] { log.withLock { $0.restored } }
    var asked: [String] { log.withLock { $0.asked } }

    func restore(_ entry: JournalEntry) async throws {
        log.withLock { $0.restored.append(entry) }
    }

    func stillHolds(_ written: WrittenValue, for entry: JournalEntry) async -> Bool? {
        log.withLock { $0.asked.append(Journal.key(for: entry)) }
        return answer
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

/// What a journal file holds.
private struct OnDisk: Decodable {
    var records: [JournalRecord]
}

/// What the lifetime of a journal record decides: a temporary change (`.untilQuit`) is put back on quit, by Reset and by Replay now; one
/// Mantel keeps (`.kept`) only when the person asks, whatever its age; and the two never undo each other.
///
/// Every test works on files in its own folder, and `cfPreferences` is given a service of the test's own.
@Suite("Journal lifetimes", .timeLimit(.minutes(1)))
struct JournalLifetimeTests {
    /// Held by the suite, and so for the whole test.
    let folder = TemporaryFolder(prefix: "mantel-lifetimes")
    let clock = FakeClock(now: Date(timeIntervalSince1970: 1_700_000_000))

    private var journalFile: URL { folder.url.appending(path: "State/journal.json") }
    private var plist: URL { folder.url.appending(path: "sample.plist") }
    private var paths: MantelPaths {
        MantelPaths(root: folder.url.appending(path: "Mantel", directoryHint: .isDirectory),
                    logs: folder.url.appending(path: "Logs", directoryHint: .isDirectory))
    }

    private func makeJournal() -> Journal { Journal(file: journalFile, clock: clock) }

    private func makeAccess(_ journal: Journal, service: ScriptedService = ScriptedService(.followsTheFile)) -> PlistFileAccess {
        PlistFileAccess(journal: journal, paths: paths, grants: nil, io: service.io, clock: clock)
    }

    private func readFile() throws -> OnDisk {
        try JSONCoding.decoder().decode(OnDisk.self, from: Data(contentsOf: journalFile))
    }

    private func writePlist(_ dictionary: [String: Any]) throws {
        try PropertyListSerialization.data(fromPropertyList: dictionary, format: .xml, options: 0).write(to: plist)
    }

    private func table() throws -> [String: Int] {
        let data = try Data(contentsOf: plist)
        let top = try #require(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        return try #require(top["table"] as? [String: Int])
    }

    private func backupNames() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: paths.backups.path)) ?? []).sorted()
    }

    private func edit(_ name: String, _ value: Int?) -> PathEdit {
        PathEdit(path: [.key(name)], value: value.map(PlistValue.integer))
    }

    /// The journal's key for a place of the key `table` of the test's own file.
    private func journalKey(_ name: String) -> String {
        "plist:\(CanonicalPath.of(plist))#table/k:\(name)"
    }

    private let layoutFile = "/Users/example/Library/Group Containers/com.apple.MenuBar/Library/Preferences/com.apple.MenuBar.plist"

    private func place(_ name: String, original: PlistValue? = .integer(1)) -> JournalEntry {
        .plistPath(filePath: layoutFile, key: "Positions", path: [.key("table"), .key(name)], original: original, strategy: .cfPreferences,
                   codec: .none)
    }

    // MARK: What an earlier or a later build wrote

    @Test func oldJournalReadsAsUntilQuit() async throws {
        // A journal as the second version wrote it, byte for byte in shape: a whole key, a place inside a key that held nothing (with what
        // was written there and the container the change made), and a `defaults` key. No lifetime anywhere.
        let json = """
        {
          "records" : [
            {
              "entry" : {
                "plistKey" : {
                  "filePath" : "/Users/example/Library/Preferences/example.plist",
                  "key" : "Other",
                  "original" : { "integer" : 1 },
                  "strategy" : "cfPreferences"
                }
              },
              "key" : "plist:/Users/example/Library/Preferences/example.plist#Other",
              "recordedAt" : "2023-11-14T22:13:20.000Z"
            },
            {
              "createdContainers" : 1,
              "entry" : {
                "plistPath" : {
                  "codec" : "none",
                  "filePath" : "/Users/example/Library/Preferences/example.plist",
                  "key" : "Positions",
                  "path" : [
                    { "key" : { "_0" : "table" } },
                    { "key" : { "_0" : "a" } }
                  ],
                  "strategy" : "cfPreferences"
                }
              },
              "key" : "plist:/Users/example/Library/Preferences/example.plist#Positions/k:table/k:a",
              "lastWritten" : { "value" : { "_0" : { "integer" : 9 } } },
              "recordedAt" : "2023-11-14T22:14:00.000Z"
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
              "recordedAt" : "2023-11-14T22:15:00.000Z"
            }
          ]
        }
        """
        try FileManager.default.createDirectory(at: journalFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(json.utf8).write(to: journalFile)

        let journal = makeJournal()
        #expect(await journal.isUsable)
        let read = await journal.records()
        #expect(read.count == 3)
        #expect(read.allSatisfy { $0.lifetime == .untilQuit })
        let file = "/Users/example/Library/Preferences/example.plist"
        let whole = JournalEntry.plistKey(filePath: file, key: "Other", original: .integer(1), strategy: .cfPreferences)
        let placed = JournalEntry.plistPath(filePath: file, key: "Positions", path: [.key("table"), .key("a")], original: nil,
                                            strategy: .cfPreferences, codec: .none)
        let spacing = JournalEntry.defaultsKey(domain: "NSGlobalDomain", key: "NSStatusItemSpacing", currentHost: true, original: nil)
        #expect(read.map(\.entry) == [whole, placed, spacing])
        #expect(read[1].lastWritten == .value(.integer(9)) && read[1].createdContainers == 1, "the rest of a record is as it was")
        #expect(await journal.untilQuitRecords().count == 3)
        #expect(await journal.keptRecords().isEmpty)
        // And a replay as quitting does it puts them all back.
        let restorer = NotingRestorer()
        #expect(await journal.replay(using: restorer).isEmpty)
        #expect(restorer.restored == [spacing, placed, whole])
    }

    @Test func aLifetimeIsWrittenAndSurvivesARestart() async throws {
        let journal = makeJournal()
        try await journal.record(place("a"), lifetime: .kept)
        try await journal.record(place("b"))

        let object = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: journalFile)) as? [String: Any])
        let written = try #require(object["records"] as? [[String: Any]])
        #expect(written.map { $0["lifetime"] as? String } == ["kept", "untilQuit"])
        let reopened = Journal(file: journalFile, clock: clock)
        #expect(await reopened.records().map(\.lifetime) == [.kept, .untilQuit])
    }

    @Test func anUnknownLifetimeReadsAsUntilQuitWithOneLogLine() async throws {
        // A newer build's lifetime, a lifetime that isn't even a word, and one this build knows: the file still reads, the two it can't
        // understand are "until quit", the cautious reading, and the log says so once for the file, not once for each record.
        func record(_ name: String, lifetime: String) -> String {
            """
            {
              "entry" : { "plistKey" : { "filePath" : "/p.plist", "key" : "\(name)", "strategy" : "cfPreferences" } },
              "key" : "plist:/p.plist#\(name)",
              "lifetime" : \(lifetime),
              "recordedAt" : "2023-11-14T22:13:20.000Z"
            }
            """
        }
        let json = "{ \"records\" : [ \(record("a", lifetime: "\"someday\"")), \(record("b", lifetime: "7")), \(record("c", lifetime: "\"kept\"")) ] }"
        try FileManager.default.createDirectory(at: journalFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(json.utf8).write(to: journalFile)

        let file = journalFile
        let clock = clock
        let opened = Mutex<Journal?>(nil)
        let lines = await LogCapture.lines { opened.withLock { $0 = Journal(file: file, clock: clock) } }
        let journal = try #require(opened.withLock { $0 })

        #expect(await journal.isUsable, "the file wasn't set aside")
        #expect(await journal.records().map(\.lifetime) == [.untilQuit, .untilQuit, .kept])
        let mentions = lines.filter { $0.contains("have a lifetime this version doesn't know") }
        #expect(mentions.count == 1, "\(mentions)")
        #expect(mentions.first?.contains("2 journal records") == true)
        #expect(mentions.first?.contains("someday") == false, "what the file held is not in the log")
    }

    @Test func aSingleUnknownLifetimeIsSaidInTheSingular() async throws {
        let json = """
        { "records" : [ {
          "entry" : { "plistKey" : { "filePath" : "/p.plist", "key" : "a", "strategy" : "cfPreferences" } },
          "key" : "plist:/p.plist#a",
          "lifetime" : "someday",
          "recordedAt" : "2023-11-14T22:13:20.000Z"
        } ] }
        """
        try FileManager.default.createDirectory(at: journalFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(json.utf8).write(to: journalFile)

        let file = journalFile
        let clock = clock
        let lines = await LogCapture.lines { _ = Journal(file: file, clock: clock) }
        let mentions = lines.filter { $0.contains("lifetime this version doesn't know") }
        #expect(mentions.count == 1, "\(mentions)")
        #expect(mentions.first?.hasSuffix("[WARN] [journal] 1 journal record has a lifetime this version doesn't know; it is treated as one to put back on quit") == true,
                "\(mentions)")
    }

    // MARK: Quitting, resetting and replaying leave what Mantel keeps

    @Test func quitReplayLeavesKeptRecords() async throws {
        let journal = makeJournal()
        let kept = place("kept")
        let temporary = place("temporary")
        try await journal.record(kept, lifetime: .kept)
        try await journal.record(temporary)

        let restorer = NotingRestorer()
        #expect(await journal.replay(using: restorer).isEmpty, "as quitting, a reset and Replay now ask for it")
        #expect(restorer.restored == [temporary])
        #expect(await journal.records().map(\.entry) == [kept])
        #expect(try readFile().records.map(\.lifetime) == [.kept], "and on disk")

        // The capped replay, which is the quit's and the launch's, does the same.
        try await journal.record(temporary)
        let capped = NotingRestorer()
        let outcome = await journal.replay(using: capped, cap: .seconds(10), clock: clock)
        #expect(outcome == .completed([]))
        #expect(capped.restored == [temporary])
        #expect(await journal.keptRecords().map(\.entry) == [kept])
    }

    @Test func aReplayCanBeAskedForBothLifetimes() async throws {
        let journal = makeJournal()
        let kept = place("kept")
        let temporary = place("temporary")
        try await journal.record(kept, lifetime: .kept)
        try await journal.record(temporary)

        let restorer = NotingRestorer()
        #expect(await journal.replay(using: restorer, lifetimes: [.untilQuit, .kept]).isEmpty)
        #expect(restorer.restored == [temporary, kept], "newest first")
        #expect(await journal.records().isEmpty)
    }

    @Test func untilQuitCountIgnoresKept() async throws {
        let journal = makeJournal()
        #expect(await journal.untilQuitRecords().isEmpty)
        #expect(await journal.keptRecords().isEmpty)
        try await journal.record(place("kept"), lifetime: .kept)
        try await journal.record(place("kept too"), lifetime: .kept)
        #expect(await journal.untilQuitRecords().isEmpty, "a journal that holds only what Mantel keeps has nothing to put back")
        #expect(await journal.keptRecords().count == 2)
        #expect(await journal.records().count == 2, "the records are all there")

        try await journal.record(place("temporary"))
        #expect(await journal.untilQuitRecords().map(\.key) == [Journal.key(for: place("temporary"))])
        #expect(await journal.keptRecords().count == 2)
    }

    // MARK: Restoring what Mantel keeps

    @Test func restoreKeptIgnoresTheAgeGuard() async throws {
        // Written 30 days ago, and the system holds something else now: a replay would doubt the record and drop it, but a restore that
        // is asked for puts the original back, and doesn't even ask the system.
        let journal = makeJournal()
        let entry = place("a")
        try await journal.record(entry, lifetime: .kept)
        try await journal.noteWritten(.value(.integer(9)), forKey: Journal.key(for: entry))
        clock.advance(by: .seconds(30 * 24 * 60 * 60))

        let restorer = NotingRestorer(stillHolds: false)
        #expect(await journal.restoreKept(where: { _ in true }, using: restorer).isEmpty)
        #expect(restorer.restored == [entry])
        #expect(restorer.asked.isEmpty, "the age of a kept record is never doubted")
        #expect(await journal.records().isEmpty)
    }

    @Test func aReplayStillDoubtsAnOldTemporaryRecord() async throws {
        // The age guard is for replays, and only for them: the same record, temporary, is dropped.
        let journal = makeJournal()
        let entry = place("a")
        try await journal.record(entry)
        try await journal.noteWritten(.value(.integer(9)), forKey: Journal.key(for: entry))
        clock.advance(by: .seconds(30 * 24 * 60 * 60))

        let restorer = NotingRestorer(stillHolds: false)
        #expect(await journal.replay(using: restorer).isEmpty)
        #expect(restorer.restored.isEmpty)
        #expect(restorer.asked == [Journal.key(for: entry)])
        #expect(await journal.records().isEmpty)
    }

    @Test func restoreKeptRemovesOnlySelected() async throws {
        let journal = makeJournal()
        let first = place("first"), second = place("second"), third = place("third"), temporary = place("temporary")
        try await journal.record(first, lifetime: .kept)
        try await journal.record(second, lifetime: .kept)
        try await journal.record(temporary)
        try await journal.record(third, lifetime: .kept)

        let wanted: Set<String> = [Journal.key(for: first), Journal.key(for: third), Journal.key(for: temporary)]
        let restorer = NotingRestorer()
        #expect(await journal.restoreKept(where: { wanted.contains($0.key) }, using: restorer).isEmpty)

        #expect(restorer.restored == [third, first], "newest first; the temporary record is not Mantel's to put back here, even when selected")
        #expect(await journal.records().map(\.entry) == [second, temporary])
        #expect(try readFile().records.map(\.entry) == [second, temporary])
    }

    @Test func restoreKeptKeepsARecordThatCouldNotBePutBack() async throws {
        struct Locked: LocalizedError { var errorDescription: String? { "the file is locked" } }
        let journal = makeJournal()
        let first = place("first"), second = place("second")
        try await journal.record(first, lifetime: .kept)
        try await journal.record(second, lifetime: .kept)

        let restorer = ClosureRestorer { entry in if entry == second { throw Locked() } }
        let failures = await journal.restoreKept(where: { _ in true }, using: restorer)

        #expect(failures == [ReplayFailure(key: Journal.key(for: second), message: "the file is locked")])
        #expect(await journal.records().map(\.entry) == [second], "the other one was put back all the same")
        // The key is let go again: the same change can be recorded now.
        try await journal.record(first, lifetime: .kept)
        #expect(await journal.records().count == 2)
    }

    @Test func restoreHoldsOnlyItsOwnKeys() async throws {
        let journal = makeJournal()
        let first = place("first"), second = place("second"), other = place("other")
        try await journal.record(first, lifetime: .kept)
        try await journal.record(second, lifetime: .kept)
        try await journal.record(other, lifetime: .kept)
        let selected: Set<String> = [Journal.key(for: first), Journal.key(for: second)]

        // While the second is being restored (the newest of the two goes first), something else records.
        let outcomes = Mutex<[String: String]>([:])
        let approvals = JournalEntry.plistKey(filePath: "/Users/example/Library/Group Containers/example/approvals.plist", key: "tracked",
                                              original: nil, strategy: .cfPreferences)
        let whole = JournalEntry.plistKey(filePath: layoutFile, key: "Positions", original: nil, strategy: .cfPreferences)
        let restorer = ClosureRestorer { entry in
            guard entry == second else { return }
            func attempt(_ name: String, _ entry: JournalEntry, lifetime: JournalLifetime = .kept) async {
                let outcome: String
                do {
                    try await journal.record(entry, lifetime: lifetime)
                    outcome = "recorded"
                } catch JournalError.restoreInProgress(let key) {
                    outcome = "restoreInProgress \(key)"
                } catch {
                    outcome = "other: \(error)"
                }
                outcomes.withLock { $0[name] = outcome }
            }
            await attempt("the key being restored", second)
            await attempt("the key still to be restored", first)
            await attempt("the whole key of those places", whole)
            await attempt("a place nobody is restoring", other)
            await attempt("another file's key", approvals, lifetime: .untilQuit)
        }
        #expect(await journal.restoreKept(where: { selected.contains($0.key) }, using: restorer).isEmpty)

        let seen = outcomes.withLock { $0 }
        #expect(seen["the key being restored"] == "restoreInProgress \(Journal.key(for: second))")
        #expect(seen["the key still to be restored"] == "restoreInProgress \(Journal.key(for: first))")
        #expect(seen["the whole key of those places"] == "restoreInProgress \(Journal.key(for: whole))")
        #expect(seen["a place nobody is restoring"] == "recorded", "a kept place that is not being restored is not held")
        #expect(seen["another file's key"] == "recorded", "the approvals engine, a platform test and the next kept write go on")
        #expect(await journal.records().map(\.entry) == [other, approvals], "the ones that were restored are gone; nothing a refused call asked for was kept")

        // Once it is over, nothing is held.
        try await journal.record(first, lifetime: .kept)
        #expect(await journal.keptRecords().count == 2)
    }

    @Test func aReplayStillClosesTheJournalToEveryKey() async throws {
        // Unlike a restore, which holds only its own keys: what a replay is putting back may be anything.
        let journal = makeJournal()
        try await journal.record(place("temporary"))
        let outcome = Mutex("")
        let unrelated = place("unrelated")
        let restorer = ClosureRestorer { _ in
            do {
                try await journal.record(unrelated, lifetime: .kept)
                outcome.withLock { $0 = "recorded" }
            } catch {
                outcome.withLock { $0 = "\(error)" }
            }
        }
        _ = await journal.replay(using: restorer)
        #expect(outcome.withLock { $0 } == "replayInProgress")
    }

    // MARK: A kept write, and what refuses it

    @Test func keptWriteUpgradesUntilQuitRecordKeepingOriginal() async throws {
        try writePlist(["table": ["a": 1, "b": 2]])
        let journal = makeJournal()
        let access = makeAccess(journal)

        // A platform test's change to a place, which quitting would put back.
        try await access.write([edit("a", 5)], key: "table", in: plist)
        let recorded = try #require(await journal.records().first)
        #expect(recorded.lifetime == .untilQuit)

        // Then Mantel's own arrangement is written to the same place: the record is Mantel's now, with the original from before both.
        clock.advance(by: .seconds(60))
        try await access.write([edit("a", 7), edit("b", 8)], key: "table", in: plist, lifetime: .kept)

        let records = await journal.records()
        #expect(records.map(\.key) == [journalKey("a"), journalKey("b")])
        #expect(records.map(\.lifetime) == [.kept, .kept])
        guard case .plistPath(_, _, _, let original, _, _) = records[0].entry else {
            Issue.record("a place inside a key")
            return
        }
        #expect(original == .integer(1), "not the 5 the test left there")
        #expect(records[0].recordedAt == recorded.recordedAt, "the record is the same one")
        #expect(records[0].lastWritten == .value(.integer(7)))
        #expect(try table() == ["a": 7, "b": 8])
        #expect(await journal.untilQuitRecords().isEmpty, "nothing is left that quitting would put back")
    }

    @Test func untilQuitWriteToKeptPathIsRefused() async throws {
        try writePlist(["table": ["a": 1, "b": 2]])
        let journal = makeJournal()
        let access = makeAccess(journal)
        try await access.write([edit("a", 7)], key: "table", in: plist, lifetime: .kept)
        let before = await journal.records()
        let backups = backupNames()

        // A platform test's write to the place, or to it among others: refused, with nothing recorded, written or backed up.
        await #expect(throws: PlistAccessError.keptByMantel(path: journalKey("a"))) {
            try await access.write([edit("a", 9)], key: "table", in: plist)
        }
        await #expect(throws: PlistAccessError.keptByMantel(path: journalKey("a"))) {
            try await access.write([edit("b", 3), edit("a", 9)], key: "table", in: plist)
        }
        #expect(try table() == ["a": 7, "b": 2])
        #expect(await journal.records() == before)
        #expect(backupNames() == backups)

        // Another place of the same key is a platform test's to change.
        try await access.write([edit("b", 3)], key: "table", in: plist)
        #expect(try table() == ["a": 7, "b": 3])
        #expect(await journal.records().map(\.lifetime) == [.kept, .untilQuit])

        // What it says, for whoever is told.
        #expect(PlistAccessError.keptByMantel(path: "x").errorDescription == "Mantel keeps its own arrangement here. Use Restore original layout first.")
    }

    @Test func theJournalRefusesAnUntilQuitRecordOfAKeptKeyToo() async throws {
        let journal = makeJournal()
        let entry = place("a")
        try await journal.record(entry, lifetime: .kept)

        await #expect(throws: JournalError.keptByMantel(key: Journal.key(for: entry))) { try await journal.record(entry) }
        // Of a place of the whole key, when the whole key is Mantel's.
        let whole = JournalEntry.plistKey(filePath: layoutFile, key: "Other", original: nil, strategy: .cfPreferences)
        try await journal.record(whole, lifetime: .kept)
        let under = JournalEntry.plistPath(filePath: layoutFile, key: "Other", path: [.key("x")], original: nil, strategy: .cfPreferences, codec: .none)
        await #expect(throws: JournalError.keptByMantel(key: Journal.key(for: whole))) { try await journal.record(under) }
        try await journal.record(under, lifetime: .kept)
        #expect(await journal.records().count == 2, "a kept place under a kept whole key is covered by it")
        #expect(JournalError.keptByMantel(key: "plist:/p.plist#k").errorDescription == "Mantel keeps its own arrangement here. Use Restore original layout first.")
        #expect(JournalError.keptByMantel(key: "defaults:NSGlobalDomain#NSStatusItemSpacing#true").errorDescription?.hasSuffix("Use Restore original spacing first.") == true)
    }

    @Test func undoOfKeptPathIsRefused() async throws {
        try writePlist(["table": ["a": 1, "b": 2]])
        let journal = makeJournal()
        let access = makeAccess(journal)
        try await access.write([edit("a", 7)], key: "table", in: plist, lifetime: .kept)
        let before = await journal.records()

        await #expect(throws: PlistAccessError.keptByMantel(path: journalKey("a"))) {
            try await access.undo(path: [.key("a")], key: "table", in: plist)
        }
        #expect(try table() == ["a": 7, "b": 2], "what Mantel keeps is as it was")
        #expect(await journal.records() == before)

        // The same for a whole key.
        let whole = JournalEntry.plistKey(filePath: CanonicalPath.of(plist), key: "other", original: nil, strategy: .cfPreferences)
        try await journal.record(whole, lifetime: .kept)
        await #expect(throws: PlistAccessError.keptByMantel(path: Journal.key(for: whole))) { try await access.undo(key: "other", in: plist) }
        #expect(await journal.records().count == 2)
    }

    @Test func keptWriteUnderLeftoverWholeKeyIsRefused() async throws {
        try writePlist(["table": ["a": 1, "b": 2]])
        let journal = makeJournal()
        let access = makeAccess(journal)
        // A platform test changed the whole key, and the app quit before it was put back.
        try await access.write(.dictionary(["a": .integer(5)]), key: "table", in: plist, strategy: .cfPreferences)
        let wholeKey = try #require(await journal.records().first?.key)
        let before = await journal.records()
        let fileBefore = try Data(contentsOf: plist)

        let error = await #expect(throws: PlistAccessError.leftoverWholeKey(key: wholeKey)) {
            try await access.write([edit("a", 7)], key: "table", in: plist, lifetime: .kept)
        }
        #expect(error?.errorDescription == "A platform test's change to sample.plist hasn't been put back yet. Use Replay now in Settings › Diagnostics.")
        #expect(await journal.records() == before, "nothing was recorded")
        #expect(try Data(contentsOf: plist) == fileBefore, "and nothing was written")

        // Replay now puts the test's change back, and then Mantel's own arrangement can be written.
        try paths.createDirectories()
        let grants = FileGrantStore(store: SettingsStore(paths: paths), bookmarkOptions: [], clock: clock)
        #expect(await journal.replay(using: PlistJournalRestorer(access: access, grants: grants)).isEmpty)
        #expect(try table() == ["a": 1, "b": 2])
        try await access.write([edit("a", 7)], key: "table", in: plist, lifetime: .kept)
        #expect(await journal.keptRecords().map(\.key) == [journalKey("a")])
    }

    @Test func aKeptWriteUnderAKeptWholeKeyIsCoveredByIt() async throws {
        try writePlist(["table": ["a": 1]])
        let journal = makeJournal()
        let access = makeAccess(journal)
        let whole = JournalEntry.plistKey(filePath: CanonicalPath.of(plist), key: "table", original: .dictionary(["a": .integer(1)]),
                                          strategy: .cfPreferences)
        try await journal.record(whole, lifetime: .kept)

        try await access.write([edit("a", 7)], key: "table", in: plist, lifetime: .kept)
        #expect(await journal.records().map(\.entry) == [whole], "the whole original covers the place")
        #expect(try table() == ["a": 7])
    }

    // MARK: A change that can't be recorded is taken back

    @Test func aFailedRecordRollsBackOnlyWhatThisCallRecorded() async throws {
        try writePlist(["table": ["a": 1, "b": 2, "c": 3]])
        let journal = makeJournal()
        let access = makeAccess(journal)
        // A place Mantel keeps, which is being put back, and so is held for as long as that takes.
        let held = JournalEntry.plistPath(filePath: CanonicalPath.of(plist), key: "table", path: [.key("c")], original: .integer(3),
                                          strategy: .cfPreferences, codec: .none)
        try await journal.record(held, lifetime: .kept)
        // And a temporary record, which the kept write below makes kept and then, when it fails, makes temporary again.
        try await access.write([edit("a", 5)], key: "table", in: plist)
        let temporaryBefore = try #require(await journal.records().last)

        let entered = Gate()
        let release = Gate()
        let heldKey = journalKey("c")
        let restoring = Task {
            await journal.restoreKept(where: { $0.key == heldKey }, using: ClosureRestorer { _ in
                entered.open()
                await release.wait()
            })
        }
        await entered.wait()

        // The write records a (an upgrade), then b (new), and then c, which is held: it can't be recorded.
        await #expect(throws: JournalError.restoreInProgress(key: heldKey)) {
            try await access.write([edit("a", 7), edit("b", 8), edit("c", 9)], key: "table", in: plist, lifetime: .kept)
        }
        let records = await journal.records()
        #expect(records.map(\.key) == [heldKey, journalKey("a")], "b's record was taken out again")
        #expect(records.last == temporaryBefore, "and a is a temporary record again, as it was")
        #expect(try table() == ["a": 5, "b": 2, "c": 3], "nothing was written")

        release.open()
        #expect(await restoring.value.isEmpty)
    }

    // MARK: A whole key and the places inside it

    @Test func aKeptPlaceUnderALeftoverWholeKeyIsRefusedByTheJournal() async throws {
        let journal = makeJournal()
        let whole = JournalEntry.plistKey(filePath: layoutFile, key: "Positions", original: nil, strategy: .cfPreferences)
        try await journal.record(whole)
        let under = place("a")

        // A temporary place under a temporary whole key is covered by it, as it always was; Mantel's own place is not: putting the whole
        // key back (quitting does) would put it back too.
        try await journal.record(under)
        #expect(await journal.records().map(\.entry) == [whole])
        let error = await #expect(throws: JournalError.leftoverWholeKey(key: Journal.key(for: whole))) {
            try await journal.record(under, lifetime: .kept)
        }
        #expect(error?.errorDescription == "A platform test's change to com.apple.MenuBar.plist hasn't been put back yet. Use Replay now in Settings › Diagnostics.")
        #expect(await journal.records().map(\.entry) == [whole], "nothing was recorded")
        #expect(try readFile().records.map(\.entry) == [whole])

        // Once the leftover is put back, the place can be recorded.
        #expect(await journal.replay(using: NotingRestorer()).isEmpty)
        try await journal.record(under, lifetime: .kept)
        #expect(await journal.keptRecords().map(\.entry) == [under])
    }

    @Test func aKeptWriteUpgradingATemporaryPlaceUnderALeftoverWholeKeyIsRefused() async throws {
        let journal = makeJournal()
        // The place was recorded first, as a temporary change; a temporary change of the whole key came after it.
        let under = place("a")
        try await journal.record(under)
        let whole = JournalEntry.plistKey(filePath: layoutFile, key: "Positions", original: nil, strategy: .cfPreferences)
        try await journal.record(whole)
        let before = await journal.records()

        await #expect(throws: JournalError.leftoverWholeKey(key: Journal.key(for: whole))) {
            try await journal.record(under, lifetime: .kept)
        }
        #expect(await journal.records() == before, "the place stays a temporary record")
        #expect(await journal.keptRecords().isEmpty)
    }

    @Test func aTemporaryWholeKeyOverKeptPlacesIsRefusedByTheJournal() async throws {
        let journal = makeJournal()
        let kept = place("a")
        try await journal.record(kept, lifetime: .kept)
        let whole = JournalEntry.plistKey(filePath: layoutFile, key: "Positions", original: nil, strategy: .cfPreferences)

        // Putting the whole key back (quitting does) would put Mantel's arrangement back with it.
        await #expect(throws: JournalError.keptByMantel(key: Journal.key(for: kept))) { try await journal.record(whole) }
        #expect(await journal.records().map(\.entry) == [kept], "nothing was recorded")

        // Another key of the same file is another matter, and so is a place that is only temporary.
        let other = JournalEntry.plistKey(filePath: layoutFile, key: "Other", original: nil, strategy: .cfPreferences)
        try await journal.record(other)
        let temporaryPlace = JournalEntry.plistPath(filePath: layoutFile, key: "Positions", path: [.key("table"), .key("t")], original: nil,
                                                    strategy: .cfPreferences, codec: .none)
        try await journal.record(temporaryPlace)
        #expect(await journal.records().count == 3)

        // Mantel's own whole key is no refusal: it is Mantel's arrangement too.
        try await journal.record(whole, lifetime: .kept)
        #expect(await journal.keptRecords().map(\.entry) == [kept, whole])
    }

    @Test func aWholeKeyWriteOverKeptPlacesIsRefused() async throws {
        try writePlist(["table": ["a": 1, "b": 2]])
        let journal = makeJournal()
        let access = makeAccess(journal)
        try await access.write([edit("a", 7)], key: "table", in: plist, lifetime: .kept)
        let before = await journal.records()
        let backups = backupNames()

        await #expect(throws: PlistAccessError.keptByMantel(path: journalKey("a"))) {
            try await access.write(.dictionary(["a": .integer(5)]), key: "table", in: plist, strategy: .cfPreferences)
        }
        #expect(try table() == ["a": 7, "b": 2], "nothing was written")
        #expect(await journal.records() == before, "nothing was recorded")
        #expect(backupNames() == backups, "and nothing was backed up")
    }

    @Test func undoOfAWholeKeyOverKeptPlacesIsRefused() async throws {
        try writePlist(["table": ["a": 1, "b": 2]])
        let journal = makeJournal()
        let access = makeAccess(journal)
        try await access.write([edit("a", 7)], key: "table", in: plist, lifetime: .kept)

        await #expect(throws: PlistAccessError.keptByMantel(path: journalKey("a"))) { try await access.undo(key: "table", in: plist) }
        #expect(try table() == ["a": 7, "b": 2])
        #expect(await journal.keptRecords().count == 1)
    }

    @Test func theJournalsRefusalsReachTheCallerAsOneError() {
        // Whether the early check or the journal itself refuses, whoever is told sees the same error.
        #expect(PlistFileAccess.translating(JournalError.keptByMantel(key: "plist:/p.plist#k/k:a")) as? PlistAccessError
            == .keptByMantel(path: "plist:/p.plist#k/k:a"))
        #expect(PlistFileAccess.translating(JournalError.leftoverWholeKey(key: "plist:/p.plist#k")) as? PlistAccessError
            == .leftoverWholeKey(key: "plist:/p.plist#k"))
        #expect(PlistFileAccess.translating(JournalError.replayInProgress) as? JournalError == .replayInProgress, "any other error is as it was")
        #expect(PlistAccessError.leftoverWholeKey(key: "plist:/Users/example/p.plist#k").errorDescription
            == JournalError.leftoverWholeKey(key: "plist:/Users/example/p.plist#k").errorDescription, "in the same words")
    }

    // MARK: A restore that doesn't put everything back says so

    @Test func aLatePlaceThatCantBePutBackIsReportedAndItsRecordStays() async throws {
        try writePlist(["table": ["a": 1, "b": 2]])
        let journal = makeJournal()
        let access = makeAccess(journal)
        try await access.write([edit("a", 7)], key: "table", in: plist, lifetime: .kept)
        // A place recorded after the restore has read the places that are kept, and before the journal starts: it isn't in the batch, so
        // it is put back by itself. This one is kept in a form this build has no codec for, so that can't be done.
        let late = JournalEntry.plistPath(filePath: CanonicalPath.of(plist), key: "table", path: [.key("late")], original: .integer(5),
                                          strategy: .cfPreferences, codec: PlistBlobCodecID(rawValue: "future-codec"))

        await #expect(throws: PlistAccessError.codecMissing("future-codec")) {
            try await access.restoreKept(key: "table", in: plist, afterSelecting: { try? await journal.record(late, lifetime: .kept) })
        }

        #expect(try table() == ["a": 1, "b": 2], "the place that was in the batch is back")
        #expect(await journal.keptRecords().map(\.key) == [Journal.key(for: late)], "and the one that wasn't stays recorded")
    }

    @Test func aLatePlaceIsPutBackByItselfAndCounted() async throws {
        try writePlist(["table": ["a": 1, "b": 2]])
        let journal = makeJournal()
        let access = makeAccess(journal)
        try await access.write([edit("a", 7)], key: "table", in: plist, lifetime: .kept)
        let late = JournalEntry.plistPath(filePath: CanonicalPath.of(plist), key: "table", path: [.key("b")], original: .integer(2),
                                          strategy: .cfPreferences, codec: .none)

        let restored = try await access.restoreKept(key: "table", in: plist, afterSelecting: { try? await journal.record(late, lifetime: .kept) })

        #expect(restored == 2)
        #expect(try table() == ["a": 1, "b": 2])
        #expect(await journal.records().isEmpty)
    }

    @Test func aRestoreWhoseRecordsCouldNotBeUpdatedSaysSo() async throws {
        try writePlist(["table": ["a": 1, "b": 2]])
        let journal = makeJournal()
        let access = makeAccess(journal)
        try await access.write([edit("a", 7)], key: "table", in: plist, lifetime: .kept)
        // The journal's folder can't be written to: the place is put back, and its record can't be taken out.
        let state = journalFile.deletingLastPathComponent()
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: state.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: state.path) }

        await #expect(throws: PlistAccessError.restoreIncomplete(places: 1)) { try await access.restoreKept(key: "table", in: plist) }
        #expect(try table() == ["a": 1, "b": 2], "what was put back stays put back")
        #expect(await journal.keptRecords().count == 1, "and its record is still there")

        // Once the journal can be written, the same restore finishes the job.
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: state.path)
        #expect(try await access.restoreKept(key: "table", in: plist) == 1)
        #expect(await journal.records().isEmpty)
        #expect(PlistAccessError.restoreIncomplete(places: 1).errorDescription
            == "Mantel couldn't finish putting back what it keeps: 1 change is still recorded. Try again.")
        #expect(PlistAccessError.restoreIncomplete(places: 3).errorDescription
            == "Mantel couldn't finish putting back what it keeps: 3 changes are still recorded. Try again.")
    }
}
