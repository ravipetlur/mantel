import Foundation
import MKCore
import MKTestSupport
import Synchronization
import Testing

@testable import MKMenuBar

/// What a journal file holds.
private struct OnDisk: Decodable {
    var records: [JournalRecord]
}

/// Changing a preference with the journal behind it. Every test has a preferences service of its own (`FakePreferences`) and a journal in a
/// folder of its own: the real preferences are never reached.
@Suite("Defaults access", .timeLimit(.minutes(1)))
struct DefaultsAccessTests {
    /// Held by the suite, and so for the whole test.
    let folder = TemporaryFolder(prefix: "mantel-defaults")
    let clock = FakeClock(now: Date(timeIntervalSince1970: 1_700_000_000))

    private let spacing = IconSpacing.spacingKey
    private let padding = IconSpacing.paddingKey
    private let domain = PreferencesDomain.globalCurrentHost

    private var journalFile: URL { folder.url.appending(path: "State/journal.json") }
    private func makeJournal() -> Journal { Journal(file: journalFile, clock: clock) }

    private func journalKey(_ key: String) -> String {
        "defaults:NSGlobalDomain#\(key)#true"
    }

    private func entry(_ key: String, original: PlistValue?) -> JournalEntry {
        .defaultsKey(domain: "NSGlobalDomain", key: key, currentHost: true, original: original)
    }

    // MARK: Writing

    @Test func writeJournalsOriginalFirst() async throws {
        let preferences = FakePreferences([spacing: .integer(6)])
        let journal = makeJournal()
        let access = DefaultsAccess(journal: journal, preferences: preferences)
        // What the journal file holds at the moment the preferences are written: the record has to be on disk by then.
        let file = journalFile
        let onDiskAtWrite = Mutex<[JournalRecord]?>(nil)
        preferences.onSet { _, _ in
            let records = (try? JSONCoding.decoder().decode(OnDisk.self, from: Data(contentsOf: file)))?.records
            onDiskAtWrite.withLock { $0 = records }
        }

        try await access.write(.integer(8), forKey: spacing, in: domain, lifetime: .kept)

        let atWrite = try #require(onDiskAtWrite.withLock { $0 })
        #expect(atWrite.map(\.entry) == [entry(spacing, original: .integer(6))], "the original was on disk before the write")
        #expect(preferences.held(spacing) == .integer(8))
        let records = await journal.records()
        #expect(records.map(\.entry) == [entry(spacing, original: .integer(6))])
        #expect(records.map(\.lifetime) == [.kept])
        #expect(records.first?.lastWritten == .value(.integer(8)), "what was written is noted")
        #expect(records.first?.key == journalKey(spacing))
    }

    @Test func firstOriginalWins() async throws {
        let preferences = FakePreferences()
        let journal = makeJournal()
        let access = DefaultsAccess(journal: journal, preferences: preferences)

        try await access.write(.integer(8), forKey: spacing, in: domain, lifetime: .kept)
        try await access.write(.integer(4), forKey: spacing, in: domain, lifetime: .kept)

        let records = await journal.records()
        #expect(records.map(\.entry) == [entry(spacing, original: nil)], "the value from before Mantel's first change, not 8")
        #expect(records.first?.lastWritten == .value(.integer(4)), "but what was written last is noted")
        #expect(preferences.held(spacing) == .integer(4))
    }

    /// The service drops the write, refuses it, or keeps something else than it was given (once): the key is as it was, and a change
    /// that isn't there leaves nothing to put back.
    @Test(arguments: [FakePreferences.Behavior.drops, .refuses, .replacesOnce(.integer(99))])
    func notPersistedWhenReadBackDiffers(_ behavior: FakePreferences.Behavior) async throws {
        let preferences = FakePreferences([spacing: .integer(6)])
        preferences.behave(behavior, forKey: spacing)
        let journal = makeJournal()
        let access = DefaultsAccess(journal: journal, preferences: preferences)

        let error = await #expect(throws: DefaultsAccessError.notPersisted(key: spacing)) {
            try await access.write(.integer(8), forKey: spacing, in: domain, lifetime: .kept)
        }

        #expect(error?.errorDescription == "macOS didn't keep the change to NSStatusItemSpacing. Try again.")
        #expect(preferences.held(spacing) == .integer(6), "the key is as it was (a 99 it kept is taken away again)")
        #expect(await journal.records().isEmpty, "and a change that isn't there leaves nothing to put back")
    }

    @Test func aKeyThatCantBePutBackKeepsItsRecord() async throws {
        let preferences = FakePreferences([spacing: .integer(6)])
        preferences.behave(.replaces(.integer(99)), forKey: spacing)
        let journal = makeJournal()
        let access = DefaultsAccess(journal: journal, preferences: preferences)

        await #expect(throws: DefaultsAccessError.notPersisted(key: spacing)) {
            try await access.write(.integer(8), forKey: spacing, in: domain, lifetime: .untilQuit)
        }
        #expect(preferences.held(spacing) == .integer(99), "the service keeps what it likes")
        #expect(await journal.records().map(\.entry) == [entry(spacing, original: .integer(6))], "so the original stays recorded")

        // Once the service takes writes again, the next replay puts the original back.
        preferences.behave(.keeps, forKey: spacing)
        let failures = await journal.replay(using: DefaultsJournalRestorer(access: access))
        #expect(failures.isEmpty)
        #expect(preferences.held(spacing) == .integer(6))
        #expect(await journal.records().isEmpty)
    }

    @Test func aChangeTakenBackLeavesAnEarlierRecordAlone() async throws {
        // A temporary record is there already (a probe's change), and the kept write that upgrades it isn't kept.
        let preferences = FakePreferences()
        let journal = makeJournal()
        let access = DefaultsAccess(journal: journal, preferences: preferences)
        try await access.write(.integer(6), forKey: spacing, in: domain, lifetime: .untilQuit)
        preferences.behave(.drops, forKey: spacing)

        await #expect(throws: DefaultsAccessError.notPersisted(key: spacing)) {
            try await access.write(.integer(8), forKey: spacing, in: domain, lifetime: .kept)
        }

        let records = await journal.records()
        #expect(records.map(\.lifetime) == [.untilQuit], "the upgrade is taken back, and the probe's record is still there")
        #expect(preferences.held(spacing) == .integer(6))
    }

    @Test func keptWriteUpgradesAnUntilQuitRecordKeepingTheOriginal() async throws {
        let preferences = FakePreferences()
        let journal = makeJournal()
        let access = DefaultsAccess(journal: journal, preferences: preferences)

        try await access.write(.integer(6), forKey: spacing, in: domain, lifetime: .untilQuit)
        try await access.write(.integer(8), forKey: spacing, in: domain, lifetime: .kept)

        let records = await journal.records()
        #expect(records.map(\.entry) == [entry(spacing, original: nil)])
        #expect(records.map(\.lifetime) == [.kept])
    }

    @Test func untilQuitWriteToKeptKeyIsRefused() async throws {
        let preferences = FakePreferences()
        let journal = makeJournal()
        let access = DefaultsAccess(journal: journal, preferences: preferences)
        try await access.write(.integer(8), forKey: spacing, in: domain, lifetime: .kept)

        let error = await #expect(throws: DefaultsAccessError.keptByMantel(key: journalKey(spacing))) {
            try await access.write(.integer(4), forKey: spacing, in: domain, lifetime: .untilQuit)
        }

        #expect(error?.errorDescription == "Mantel keeps its own icon spacing here. Use Restore original spacing first.")
        #expect(preferences.writes.count == 1, "nothing was written")
        #expect(preferences.held(spacing) == .integer(8))
        #expect(await journal.records().map(\.lifetime) == [.kept])
    }

    @Test func aRefusedRecordStopsEveryWriteOfTheCall() async throws {
        let preferences = FakePreferences()
        let journal = makeJournal()
        let access = DefaultsAccess(journal: journal, preferences: preferences)
        try await access.write(.integer(8), forKey: padding, in: domain, lifetime: .kept)
        let written = preferences.writes.count

        // The second key of the call is one Mantel keeps: the first isn't written, and isn't recorded.
        await #expect(throws: DefaultsAccessError.keptByMantel(key: journalKey(padding))) {
            try await access.writeAll([DefaultsChange(key: spacing, value: .integer(4)), DefaultsChange(key: padding, value: .integer(4))],
                                      in: domain, lifetime: .untilQuit)
        }

        #expect(preferences.writes.count == written)
        #expect(await journal.records().map(\.key) == [journalKey(padding)])
    }

    // MARK: Several keys

    @Test func writeAllIsAllOrNothing() async throws {
        let preferences = FakePreferences([spacing: .integer(6)])
        preferences.behave(.refuses, forKey: padding)
        let journal = makeJournal()
        let access = DefaultsAccess(journal: journal, preferences: preferences)

        await #expect(throws: DefaultsAccessError.notPersisted(key: padding)) {
            try await access.writeAll([DefaultsChange(key: spacing, value: .integer(8)), DefaultsChange(key: padding, value: .integer(8))],
                                      in: domain, lifetime: .kept)
        }

        #expect(preferences.held(spacing) == .integer(6), "the first key is put back")
        #expect(preferences.held(padding) == nil)
        #expect(await journal.records().isEmpty, "and nothing is left to put back")
    }

    @Test func aKeyAfterTheOneThatFailedIsNotWrittenToWhenTheCallIsTakenBack() async throws {
        // The padding is changed by another program between the failed write of the spacing and the putting back: it was never written by
        // this call, so what it holds now is no business of the call's. Its record goes all the same.
        let preferences = FakePreferences([spacing: .integer(6), padding: .integer(5)])
        preferences.behave(.refuses, forKey: spacing)
        preferences.onSet { key, _ in
            if key == self.spacing { preferences.change(self.padding, to: .integer(9)) }
        }
        let journal = makeJournal()
        let access = DefaultsAccess(journal: journal, preferences: preferences)

        await #expect(throws: DefaultsAccessError.notPersisted(key: spacing)) {
            try await access.writeAll([DefaultsChange(key: spacing, value: .integer(8)), DefaultsChange(key: padding, value: .integer(8))],
                                      in: domain, lifetime: .kept)
        }

        #expect(preferences.held(spacing) == .integer(6))
        #expect(preferences.held(padding) == .integer(9), "left as the other program made it")
        #expect(preferences.writes.map(\.key) == [spacing], "the padding was never written, nor put back")
        #expect(await journal.records().isEmpty, "and no record of either is left")
    }

    @Test func writeAllLeavesAKeyThatAlreadyHoldsItsValueAlone() async throws {
        let preferences = FakePreferences([spacing: .integer(8)])
        let journal = makeJournal()
        let access = DefaultsAccess(journal: journal, preferences: preferences)

        try await access.writeAll([DefaultsChange(key: spacing, value: .integer(8)), DefaultsChange(key: padding, value: .integer(8))],
                                  in: domain, lifetime: .kept)

        #expect(preferences.writes.map(\.key) == [padding], "the spacing is as it is to be")
        #expect(await journal.records().map(\.key) == [journalKey(padding)], "and nothing is recorded for it")
    }

    @Test func writeAllStillUpgradesATemporaryRecordOfAKeyThatHoldsItsValue() async throws {
        // A probe set 6 until quit. The person chooses 6: it is Mantel's now, and quitting must not put the original back.
        let preferences = FakePreferences()
        let journal = makeJournal()
        let access = DefaultsAccess(journal: journal, preferences: preferences)
        try await access.write(.integer(6), forKey: spacing, in: domain, lifetime: .untilQuit)

        try await access.writeAll([DefaultsChange(key: spacing, value: .integer(6))], in: domain, lifetime: .kept)

        #expect(await journal.records().map(\.lifetime) == [.kept])
        #expect(await journal.untilQuitRecords().isEmpty)
    }

    // MARK: Putting back

    /// A key that wasn't there is recorded as absent, and putting it back removes it.
    @Test(arguments: [PlistValue.integer(6), nil])
    func undoPutsBackOriginalAndRemovesRecord(original: PlistValue?) async throws {
        let preferences = original.map { FakePreferences([spacing: $0]) } ?? FakePreferences()
        let journal = makeJournal()
        let access = DefaultsAccess(journal: journal, preferences: preferences)
        try await access.write(.integer(8), forKey: spacing, in: domain, lifetime: .untilQuit)
        #expect(await journal.records().map(\.entry) == [entry(spacing, original: original)])

        try await access.undo(key: spacing, in: domain)

        #expect(preferences.held(spacing) == original)
        #expect(preferences.writes.last == FakePreferences.Write(key: spacing, value: original, domain: domain),
                "an absent key is removed, not set to something")
        #expect(await journal.records().isEmpty)
    }

    @Test func undoOfAKeptKeyIsRefused() async throws {
        let preferences = FakePreferences([spacing: .integer(6)])
        let journal = makeJournal()
        let access = DefaultsAccess(journal: journal, preferences: preferences)
        try await access.write(.integer(8), forKey: spacing, in: domain, lifetime: .kept)

        await #expect(throws: DefaultsAccessError.keptByMantel(key: journalKey(spacing))) {
            try await access.undo(key: spacing, in: domain)
        }

        #expect(preferences.held(spacing) == .integer(8))
        #expect(await journal.records().count == 1)
    }

    @Test func undoOfAKeyNobodyRecordedChangesNothing() async throws {
        let preferences = FakePreferences([spacing: .integer(6)])
        let access = DefaultsAccess(journal: makeJournal(), preferences: preferences)

        try await access.undo(key: spacing, in: domain)

        #expect(preferences.writes.isEmpty)
    }

    @Test func removingAKeyThatHoldsAValueJournalsTheValue() async throws {
        let preferences = FakePreferences([spacing: .integer(6)])
        let journal = makeJournal()
        let access = DefaultsAccess(journal: journal, preferences: preferences)

        try await access.write(nil, forKey: spacing, in: domain, lifetime: .untilQuit)

        #expect(preferences.held(spacing) == nil)
        let records = await journal.records()
        #expect(records.map(\.entry) == [entry(spacing, original: .integer(6))])
        #expect(records.first?.lastWritten == .removed)

        try await access.undo(key: spacing, in: domain)
        #expect(preferences.held(spacing) == .integer(6))
    }

    @Test func aReplayPutsBackTemporaryChangesAndLeavesKeptOnes() async throws {
        let preferences = FakePreferences([spacing: .integer(6)])
        let journal = makeJournal()
        let access = DefaultsAccess(journal: journal, preferences: preferences)
        try await access.write(.integer(8), forKey: spacing, in: domain, lifetime: .untilQuit)
        try await access.write(.integer(8), forKey: padding, in: domain, lifetime: .kept)

        let failures = await journal.replay(using: DefaultsJournalRestorer(access: access))

        #expect(failures.isEmpty)
        #expect(preferences.held(spacing) == .integer(6))
        #expect(preferences.held(padding) == .integer(8), "what Mantel keeps stays")
        #expect(await journal.records().map(\.key) == [journalKey(padding)])
    }

    /// A record a week old is put back, unless someone else has changed the key since: their change stays, and the record is dropped.
    @Test(arguments: [false, true])
    func anOldRecordIsPutBackUnlessSomeoneElseChangedTheKey(someoneChangedIt: Bool) async throws {
        let preferences = FakePreferences([spacing: .integer(6)])
        let journal = makeJournal()
        let access = DefaultsAccess(journal: journal, preferences: preferences)
        try await access.write(.integer(8), forKey: spacing, in: domain, lifetime: .untilQuit)
        clock.advance(by: .seconds(8 * 24 * 60 * 60))
        if someoneChangedIt { preferences.change(spacing, to: .integer(3)) }

        let failures = await journal.replay(using: DefaultsJournalRestorer(access: access))

        #expect(failures.isEmpty)
        #expect(preferences.held(spacing) == (someoneChangedIt ? .integer(3) : .integer(6)), "their change stays")
        #expect(await journal.records().isEmpty, "and the record is gone")
    }

    @Test func aRestoreThatWasNotKeptStaysInTheJournal() async throws {
        let preferences = FakePreferences([spacing: .integer(6)])
        let journal = makeJournal()
        let access = DefaultsAccess(journal: journal, preferences: preferences)
        try await access.write(.integer(8), forKey: spacing, in: domain, lifetime: .untilQuit)
        preferences.behave(.drops, forKey: spacing)

        let failures = await journal.replay(using: DefaultsJournalRestorer(access: access))

        #expect(failures.map(\.key) == [journalKey(spacing)])
        #expect(failures.first?.message == "macOS didn't keep the change to NSStatusItemSpacing. Try again.")
        #expect(await journal.records().count == 1, "for the next launch")
    }

    // MARK: One at a time

    @Test func writesAreMadeOneAtATime() async throws {
        let preferences = FakePreferences()
        let access = DefaultsAccess(journal: makeJournal(), preferences: preferences)
        let key = spacing
        let domain = domain

        await withTaskGroup(of: Void.self) { group in
            for value in 1...8 {
                group.addTask {
                    try? await access.write(.integer(value), forKey: key, in: domain, lifetime: .kept)
                }
            }
        }

        // Each write reads the key, sets it and reads it back before the next one starts.
        let expected = (1...8).flatMap { _ in ["read:\(key)", "set:\(key)", "read:\(key)"] }
        #expect(preferences.operations == expected)
    }
}
