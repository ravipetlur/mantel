import Foundation
import MKCore
import MKTestSupport
import Testing

@testable import MKMenuBar

/// The journal has one restorer, and it has to send each kind of entry where it is put back: a plist file's change to the plist restorer,
/// a preference's to the defaults restorer. The plist file is a temporary file of the test's own, and the preferences are a fake.
@Suite("Routing journal restorer", .timeLimit(.minutes(1)))
struct RoutingJournalRestorerTests {
    /// Held by the suite, and so for the whole test.
    let folder = TemporaryFolder(prefix: "mantel-routing")
    let clock = FakeClock(now: Date(timeIntervalSince1970: 1_700_000_000))

    private var plist: URL { folder.url.appending(path: "sample.plist") }
    private var paths: MantelPaths {
        MantelPaths(root: folder.url.appending(path: "Mantel", directoryHint: .isDirectory),
                    logs: folder.url.appending(path: "Logs", directoryHint: .isDirectory))
    }

    private struct Rig {
        let routing: RoutingJournalRestorer
        let journal: Journal
        let preferences: FakePreferences
    }

    private func rig(_ values: [String: PlistValue] = [:]) throws -> Rig {
        try PropertyListSerialization.data(fromPropertyList: ["other": 2], format: .xml, options: 0).write(to: plist)
        try paths.createDirectories()
        let journal = Journal(file: folder.url.appending(path: "State/journal.json"), clock: clock)
        let preferences = FakePreferences(values)
        let access = PlistFileAccess(journal: journal, paths: paths, grants: nil, io: ScriptedService(.followsTheFile).io, clock: clock)
        let grants = FileGrantStore(store: SettingsStore(paths: paths), bookmarkOptions: [], clock: clock)
        let routing = RoutingJournalRestorer(plist: PlistJournalRestorer(access: access, grants: grants),
                                             defaults: DefaultsJournalRestorer(access: DefaultsAccess(journal: journal, preferences: preferences)))
        return Rig(routing: routing, journal: journal, preferences: preferences)
    }

    private func other() throws -> Int? {
        let top = try #require(PropertyListSerialization.propertyList(from: Data(contentsOf: plist), format: nil) as? [String: Any])
        return top["other"] as? Int
    }

    @Test func defaultsEntriesReachDefaultsRestorer() async throws {
        let rig = try rig([IconSpacing.spacingKey: .integer(8)])
        let entry = JournalEntry.defaultsKey(domain: "NSGlobalDomain", key: IconSpacing.spacingKey, currentHost: true, original: .integer(6))

        try await rig.routing.restore(entry)

        #expect(rig.preferences.held(IconSpacing.spacingKey) == .integer(6))
        #expect(try other() == 2, "the plist file wasn't touched")
    }

    @Test func plistEntriesReachPlistRestorer() async throws {
        let rig = try rig([IconSpacing.spacingKey: .integer(8)])
        let key = JournalEntry.plistKey(filePath: CanonicalPath.of(plist), key: "other", original: .integer(1), strategy: .cfPreferences)

        try await rig.routing.restore(key)

        #expect(try other() == 1)
        #expect(rig.preferences.writes.isEmpty, "the preferences weren't touched")
        #expect(rig.preferences.held(IconSpacing.spacingKey) == .integer(8))
    }

    @Test func aReplayPutsBackBothKindsInTheOrderTheyWereMade() async throws {
        let rig = try rig([IconSpacing.spacingKey: .integer(8)])
        try await rig.journal.record(.plistKey(filePath: CanonicalPath.of(plist), key: "other", original: .integer(1), strategy: .cfPreferences))
        try await rig.journal.record(.defaultsKey(domain: "NSGlobalDomain", key: IconSpacing.spacingKey, currentHost: true, original: .integer(6)))

        let failures = await rig.journal.replay(using: rig.routing)

        #expect(failures.isEmpty)
        #expect(try other() == 1)
        #expect(rig.preferences.held(IconSpacing.spacingKey) == .integer(6))
        #expect(await rig.journal.records().isEmpty)
    }

    @Test func staleQuestionsGoToTheRestorerThatKnowsTheKind() async throws {
        let rig = try rig([IconSpacing.spacingKey: .integer(8)])
        let defaults = JournalEntry.defaultsKey(domain: "NSGlobalDomain", key: IconSpacing.spacingKey, currentHost: true, original: .integer(6))
        let file = JournalEntry.plistKey(filePath: CanonicalPath.of(plist), key: "other", original: .integer(1), strategy: .cfPreferences)

        #expect(await rig.routing.stillHolds(.value(.integer(8)), for: defaults) == true)
        #expect(await rig.routing.stillHolds(.value(.integer(7)), for: defaults) == false, "someone changed it since: not put back over")
        #expect(await rig.routing.stillHolds(.value(.integer(2)), for: file) == true)
        #expect(await rig.routing.stillHolds(.value(.integer(3)), for: file) == false)
    }

    @Test func anOldPreferenceIsNotPutBackOverSomeoneElsesChange() async throws {
        // What `stillHolds` is for: a replay a week or more later doubts an old record, and for a preference it has to be able to tell.
        let rig = try rig([IconSpacing.spacingKey: .integer(6)])
        let access = DefaultsAccess(journal: rig.journal, preferences: rig.preferences)
        try await access.write(.integer(8), forKey: IconSpacing.spacingKey, in: .globalCurrentHost, lifetime: .untilQuit)
        clock.advance(by: .seconds(8 * 24 * 60 * 60))
        rig.preferences.change(IconSpacing.spacingKey, to: .integer(3))

        let failures = await rig.journal.replay(using: rig.routing)

        #expect(failures.isEmpty)
        #expect(rig.preferences.held(IconSpacing.spacingKey) == .integer(3))
        #expect(await rig.journal.records().isEmpty)
    }
}
