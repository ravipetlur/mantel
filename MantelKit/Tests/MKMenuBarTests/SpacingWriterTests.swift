import Foundation
import MKCore
import MKTestSupport
import Testing

@testable import MKMenuBar

/// Setting the icon spacing, and putting it back. Every test has a preferences service of its own (`FakePreferences`): the spacing keys of
/// the real preferences are never reached.
@Suite("Spacing writer", .timeLimit(.minutes(1)))
struct SpacingWriterTests {
    /// Held by the suite, and so for the whole test.
    let folder = TemporaryFolder(prefix: "mantel-spacing")
    let clock = FakeClock(now: Date(timeIntervalSince1970: 1_700_000_000))

    private let spacingKey = IconSpacing.spacingKey
    private let paddingKey = IconSpacing.paddingKey
    private let domain = PreferencesDomain.globalCurrentHost
    private let anyCustom = IconSpacingValues(spacing: 3, padding: 5)

    private struct Rig {
        let preferences: FakePreferences
        let journal: Journal
        let access: DefaultsAccess
        let writer: SpacingWriter
    }

    private func rig(_ values: [String: PlistValue] = [:]) -> Rig {
        let preferences = FakePreferences(values)
        let journal = Journal(file: folder.url.appending(path: "State/journal.json"), clock: clock)
        let access = DefaultsAccess(journal: journal, preferences: preferences)
        return Rig(preferences: preferences, journal: journal, access: access, writer: SpacingWriter(defaults: access, journal: journal))
    }

    private func entry(_ key: String, original: PlistValue?) -> JournalEntry {
        .defaultsKey(domain: "NSGlobalDomain", key: key, currentHost: true, original: original)
    }

    // MARK: Applying

    @Test func applyWritesBothKeysKept() async throws {
        let rig = rig()

        try await rig.writer.apply(.small, custom: anyCustom)

        #expect(rig.preferences.held(spacingKey) == .integer(8))
        #expect(rig.preferences.held(paddingKey) == .integer(8))
        #expect(rig.preferences.writes.map(\.domain) == [domain, domain], "the global domain for this Mac, and nothing else")
        let records = await rig.journal.records()
        #expect(records.map(\.entry) == [entry(spacingKey, original: nil), entry(paddingKey, original: nil)])
        #expect(records.map(\.lifetime) == [.kept, .kept])
    }

    @Test(arguments: [
        (IconSpacingPreset.small, 8, 8),
        (.tiny, 4, 6),
        (.none, 0, 4),
    ] as [(IconSpacingPreset, Int, Int)])
    func eachPresetWritesItsValues(_ preset: IconSpacingPreset, _ spacing: Int, _ padding: Int) async throws {
        let rig = rig()

        try await rig.writer.apply(preset, custom: anyCustom)

        #expect(rig.preferences.held(spacingKey) == .integer(spacing))
        #expect(rig.preferences.held(paddingKey) == .integer(padding))
        #expect(await rig.writer.current().preset == preset)
    }

    @Test func customClampsToTheRangeWhenWritten() async throws {
        let rig = rig()

        try await rig.writer.apply(.custom, custom: IconSpacingValues(spacing: -3, padding: 99))

        #expect(rig.preferences.held(spacingKey) == .integer(0))
        #expect(rig.preferences.held(paddingKey) == .integer(20))
    }

    @Test func defaultRemovesBoth() async throws {
        let rig = rig([spacingKey: .integer(6), paddingKey: .integer(5)])

        try await rig.writer.apply(.macOSDefault, custom: anyCustom)

        #expect(rig.preferences.held(spacingKey) == nil)
        #expect(rig.preferences.held(paddingKey) == nil)
        #expect(rig.preferences.writes.map(\.value) == [nil, nil], "removed, not set to a number")
        #expect(await rig.writer.current().preset == .macOSDefault)
    }

    @Test func defaultWhenNothingWasChangedIsLeftAlone() async throws {
        let rig = rig()

        try await rig.writer.apply(.macOSDefault, custom: anyCustom)

        #expect(rig.preferences.writes.isEmpty)
        #expect(await rig.journal.records().isEmpty, "Mantel hasn't changed anything, so there is nothing to restore")
        #expect(await rig.writer.current().original == nil)
    }

    @Test func aKeptChangeSurvivesAQuitReplay() async throws {
        let rig = rig()
        try await rig.writer.apply(.tiny, custom: anyCustom)

        let failures = await rig.journal.replay(using: DefaultsJournalRestorer(access: rig.access))

        #expect(failures.isEmpty)
        #expect(rig.preferences.held(spacingKey) == .integer(4), "quitting doesn't put the spacing back")
        #expect(await rig.journal.keptRecords().count == 2)
    }

    @Test func anUnkeptChangeLeavesBothKeysAsTheyWere() async throws {
        let rig = rig([spacingKey: .integer(6)])
        rig.preferences.behave(.refuses, forKey: paddingKey)

        let error = await #expect(throws: DefaultsAccessError.notPersisted(key: paddingKey)) {
            try await rig.writer.apply(.small, custom: anyCustom)
        }

        #expect(error?.errorDescription == "macOS didn't keep the change to NSStatusItemSelectionPadding. Try again.")
        #expect(rig.preferences.held(spacingKey) == .integer(6))
        #expect(await rig.journal.records().isEmpty)
        #expect(await rig.writer.current().original == nil)
    }

    @Test func aFailedReapplyLeavesTheKeptRecordsAndTheSpacingAsTheyWere() async throws {
        // Mantel changed the spacing before (the person had 6 and no padding); a later change isn't kept by the service.
        let rig = rig([spacingKey: .integer(6)])
        try await rig.writer.apply(.small, custom: anyCustom)
        rig.preferences.behave(.refuses, forKey: paddingKey)

        await #expect(throws: DefaultsAccessError.notPersisted(key: paddingKey)) {
            try await rig.writer.apply(.tiny, custom: anyCustom)
        }

        #expect(rig.preferences.held(spacingKey) == .integer(8), "the spacing of the first change, not the failed one's")
        #expect(rig.preferences.held(paddingKey) == .integer(8))
        let records = await rig.journal.records()
        #expect(records.map(\.entry) == [entry(spacingKey, original: .integer(6)), entry(paddingKey, original: nil)],
                "the first change's records stay, with the originals from before Mantel's first change")
        #expect(records.map(\.lifetime) == [.kept, .kept])
        #expect(await rig.writer.current().original == SpacingOriginal(spacing: 6, padding: nil))
        rig.preferences.behave(.keeps, forKey: paddingKey)
        #expect(await rig.writer.restoreOriginal().isEmpty)
        #expect(rig.preferences.held(spacingKey) == .integer(6), "and the original is still what a restore puts back")
        #expect(rig.preferences.held(paddingKey) == nil)
    }

    // MARK: Reading

    @Test(arguments: [
        (nil, nil, IconSpacingPreset.macOSDefault),
        (8, 8, .small),
        (4, 6, .tiny),
        (0, 4, .none),
        (7, 9, .custom),
        (8, nil, .custom),
    ] as [(Int?, Int?, IconSpacingPreset)])
    func currentMapsToPreset(_ spacing: Int?, _ padding: Int?, _ expected: IconSpacingPreset) async {
        var values: [String: PlistValue] = [:]
        if let spacing { values[spacingKey] = .integer(spacing) }
        if let padding { values[paddingKey] = .integer(padding) }
        let rig = rig(values)

        let state = await rig.writer.current()

        #expect(state.spacing == spacing)
        #expect(state.padding == padding)
        #expect(state.preset == expected)
        #expect(state.original == nil, "Mantel hasn't changed the keys")
    }

    @Test func currentReadsWholeNumbersHoweverTheyAreStored() async {
        let rig = rig([spacingKey: .real(8), paddingKey: .string("6")])

        let state = await rig.writer.current()

        #expect(state.spacing == 8)
        #expect(state.padding == 6)
        #expect(state.preset == .custom, "8 and 6 are no preset's pair")
    }

    @Test(arguments: [PlistValue.real(8.5), .string("wide"), .bool(true), .array([])])
    func aValueThatIsNoWholeNumberReadsAsNothing(_ value: PlistValue) async {
        let rig = rig([spacingKey: value])

        #expect(await rig.writer.current().spacing == nil)
    }

    @Test func originalIsTheKeptValue() async throws {
        // The person had 6 and no padding before Mantel touched them.
        let rig = rig([spacingKey: .integer(6)])
        try await rig.writer.apply(.small, custom: anyCustom)

        let first = await rig.writer.current()
        #expect(first.preset == .small)
        #expect(first.original == SpacingOriginal(spacing: 6, padding: nil))

        // A second change doesn't move the original: it is what the keys held before Mantel's first change.
        try await rig.writer.apply(.none, custom: anyCustom)
        let second = await rig.writer.current()
        #expect(second.preset == .none)
        #expect(second.original == SpacingOriginal(spacing: 6, padding: nil))
    }

    @Test func aKeyMantelHasNotChangedStillHoldsItsOriginal() async throws {
        // Only the spacing was ever changed (a crash between the two, say): the padding holds what it did before.
        let rig = rig([paddingKey: .integer(5)])
        try await rig.access.write(.integer(8), forKey: spacingKey, in: domain, lifetime: .kept)

        let state = await rig.writer.current()

        #expect(state.original == SpacingOriginal(spacing: nil, padding: 5))
    }

    @Test func aTemporaryChangeIsNoOriginalOfMantels() async throws {
        let rig = rig([spacingKey: .integer(6)])
        try await rig.access.write(.integer(8), forKey: spacingKey, in: domain, lifetime: .untilQuit)

        #expect(await rig.writer.current().original == nil, "it is put back on quit: Mantel hasn't kept anything")
    }

    // MARK: Restoring

    @Test func restoreOriginalPutsBackPreMantelValues() async throws {
        // Before Mantel the keys held values of the person's own, which is not "macOS default".
        let rig = rig([spacingKey: .integer(6), paddingKey: .integer(5)])
        try await rig.writer.apply(.none, custom: anyCustom)
        #expect(rig.preferences.held(spacingKey) == .integer(0))

        let failures = await rig.writer.restoreOriginal()

        #expect(failures.isEmpty)
        #expect(rig.preferences.held(spacingKey) == .integer(6))
        #expect(rig.preferences.held(paddingKey) == .integer(5))
        #expect(await rig.journal.records().isEmpty)
        let state = await rig.writer.current()
        #expect(state.original == nil, "and Mantel keeps nothing now")
        #expect(state.preset == .custom, "6 and 5 are no preset's pair")
    }

    @Test func restoreOriginalRemovesKeysThatWereNotThere() async throws {
        let rig = rig()
        try await rig.writer.apply(.small, custom: anyCustom)

        let failures = await rig.writer.restoreOriginal()

        #expect(failures.isEmpty)
        #expect(rig.preferences.held(spacingKey) == nil)
        #expect(rig.preferences.held(paddingKey) == nil)
        #expect(await rig.writer.current().preset == .macOSDefault)
    }

    @Test func restoreOriginalIgnoresAgeAndOtherChanges() async throws {
        let rig = rig([spacingKey: .integer(6)])
        try await rig.writer.apply(.small, custom: anyCustom)
        clock.advance(by: .seconds(40 * 24 * 60 * 60))
        rig.preferences.change(spacingKey, to: .integer(2))   // someone else changed it long after

        let failures = await rig.writer.restoreOriginal()

        #expect(failures.isEmpty)
        #expect(rig.preferences.held(spacingKey) == .integer(6), "a restore that is asked for is never doubted")
    }

    @Test func restoreOriginalLeavesEveryOtherRecordAlone() async throws {
        let rig = rig()
        try await rig.writer.apply(.small, custom: anyCustom)
        // Another kept change, and a temporary one, both for other keys.
        try await rig.access.write(.integer(1), forKey: "AppleExampleSetting", in: domain, lifetime: .kept)
        try await rig.access.write(.integer(2), forKey: "AppleOtherSetting", in: domain, lifetime: .untilQuit)

        let failures = await rig.writer.restoreOriginal()

        #expect(failures.isEmpty)
        #expect(await rig.journal.records().map(\.key) == ["defaults:NSGlobalDomain#AppleExampleSetting#true",
                                                           "defaults:NSGlobalDomain#AppleOtherSetting#true"])
        #expect(rig.preferences.held("AppleExampleSetting") == .integer(1))
    }

    @Test func restoreOriginalReportsWhatCouldNotBePutBack() async throws {
        let rig = rig([spacingKey: .integer(6)])
        try await rig.writer.apply(.small, custom: anyCustom)
        rig.preferences.behave(.drops, forKey: spacingKey)

        let failures = await rig.writer.restoreOriginal()

        #expect(failures.map(\.key) == ["defaults:NSGlobalDomain#NSStatusItemSpacing#true"])
        #expect(await rig.journal.keptRecords().map(\.key) == ["defaults:NSGlobalDomain#NSStatusItemSpacing#true"], "that record stays")
        #expect(rig.preferences.held(paddingKey) == nil, "the other key was put back")
    }

    @Test func aTemporaryWriteToAKeptKeyIsRefusedWithTheSpacingSentence() async throws {
        let rig = rig()
        try await rig.writer.apply(.small, custom: anyCustom)

        let error = await #expect(throws: DefaultsAccessError.self) {
            try await rig.access.write(.integer(1), forKey: self.spacingKey, in: self.domain, lifetime: .untilQuit)
        }

        #expect(error?.errorDescription == "Mantel keeps its own icon spacing here. Use Restore original spacing first.")
    }
}
