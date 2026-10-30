import Foundation
import MKCore
import MKLayout
import MKTestSupport
import Testing

@testable import MKMenuBar

/// The order table, written to a file in a folder of the test's own through a grant of its own, with a preferences service of the test's
/// own: never the real preferences file, and never the real `cfprefsd`.
@Suite("Layout table writer", .timeLimit(.minutes(1)))
struct LayoutTableWriterTests {
    /// Held by the suite, and so for the whole test.
    let folder = TemporaryFolder(prefix: "mantel-layout-writer")
    let clock = FakeClock()

    static let own = "com.example.mantel"
    static let hiddenDot = LayoutKey.status(bundleID: own, autosaveName: OwnItems.hiddenDotName)
    static let alwaysDot = LayoutKey.status(bundleID: own, autosaveName: OwnItems.alwaysDotName)
    static let divider = LayoutKey.status(bundleID: own, autosaveName: OwnItems.dividerName)
    static let weather = LayoutKey.status(bundleID: "com.example.weather", autosaveName: "Item-0")
    static let tableKey = "TrailingItemPreferredPositions"

    private var home: URL { folder.url.appending(path: "home", directoryHint: .isDirectory) }
    private var paths: MantelPaths {
        MantelPaths(root: folder.url.appending(path: "Mantel", directoryHint: .isDirectory),
                    logs: folder.url.appending(path: "Logs", directoryHint: .isDirectory))
    }
    private var layoutFile: URL {
        home.appending(path: "Library/Group Containers/com.apple.MenuBar/Library/Preferences/com.apple.MenuBar.plist")
    }

    private func writeFile(_ contents: [String: Any]) throws {
        try FileManager.default.createDirectory(at: layoutFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: contents, format: .xml, options: 0).write(to: layoutFile)
    }

    private func writeTable(_ table: [String: Double]) throws {
        try writeFile([Self.tableKey: table, "Other": "left alone"])
    }

    private func tableOnDisk() throws -> [String: Double] {
        let data = try Data(contentsOf: layoutFile)
        let top = try #require(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        let table = try #require(top[Self.tableKey] as? [String: Any])
        return table.compactMapValues { ($0 as? NSNumber)?.doubleValue }
    }

    private struct Rig {
        let writer: LayoutTableWriter
        let journal: Journal
        let grants: FileGrantStore
        let service: ScriptedService
    }

    private func rig(granting: Bool = true, broken: String? = nil, service: ScriptedService = ScriptedService(.followsTheFile),
                     journal existing: Journal? = nil) async throws -> Rig {
        try paths.createDirectories()
        let journal = existing ?? Journal(file: paths.journalFile, clock: clock)
        let grants = FileGrantStore(store: SettingsStore(paths: paths, clock: SystemClock(), debounce: .seconds(3600)), bookmarkOptions: [], clock: clock)
        if granting { _ = try await grants.grant(.menuBarLayout, chosen: layoutFile, home: home) }
        let access = PlistFileAccess(journal: journal, paths: paths, grants: grants, io: service.io, clock: SteppingClock())
        let writer = LayoutTableWriter(access: access, reader: LayoutTableReader(access: access, grants: grants), grants: grants,
                                       journal: journal, home: home, broken: broken)
        return Rig(writer: writer, journal: journal, grants: grants, service: service)
    }

    private func arrangement(_ distances: [LayoutToken: Double]) -> (arrangement: LayoutArrangement, keys: [LayoutToken: String]) {
        let all: [(LayoutToken, String)] = [(.dot(.always), Self.alwaysDot), (.dot(.hidden), Self.hiddenDot), (.divider, Self.divider)]
        let tokens = all.map(\.0).filter { distances[$0] != nil }
        let keys = Dictionary(uniqueKeysWithValues: all.filter { distances[$0.0] != nil })
        return (LayoutArrangement(tokens: tokens, distances: distances, skipped: []), keys)
    }

    // MARK: Availability

    @Test func brokenWhenFileMissing() async throws {
        try writeTable([Self.weather: 100])
        let rig = try await rig()
        #expect(await rig.writer.availability() == .available)

        // The granted file is gone from where macOS keeps it: it keeps the order somewhere else on this Mac.
        try FileManager.default.removeItem(at: layoutFile)
        #expect(await rig.writer.availability() == .broken(LayoutWords.broken))
    }

    @Test func brokenWhenTheTableIsMissing() async throws {
        try writeFile(["Other": 1])
        let rig = try await rig()
        #expect(await rig.writer.availability() == .broken(LayoutWords.broken))
        await #expect(throws: LayoutWriteError.broken(LayoutWords.broken)) {
            try await rig.writer.write(LayoutArrangement(tokens: [], distances: [:], skipped: []), keys: [:])
        }
    }

    @Test func brokenFromRuling() async throws {
        try writeTable([Self.weather: 100])
        let rig = try await rig(broken: "Reordering is off on this Mac.")
        #expect(await rig.writer.availability() == .broken("Reordering is off on this Mac."))
    }

    @Test func needsGrantWithoutGrant() async throws {
        try writeTable([Self.weather: 100])
        let rig = try await rig(granting: false)
        #expect(await rig.writer.availability() == .needsGrant)
        await #expect(throws: LayoutWriteError.needsGrant) { try await rig.writer.readTable() }
        let (made, keys) = arrangement([.dot(.hidden): 10])
        await #expect(throws: LayoutWriteError.needsGrant) { try await rig.writer.write(made, keys: keys) }
        await #expect(throws: LayoutWriteError.needsGrant) { try await rig.writer.restoreOriginalLayout() }
    }

    @Test func aGrantThatIsRevokedMidwayIsFailedAndThenNeedsGrant() async throws {
        try writeTable([Self.weather: 100])
        let rig = try await rig()
        #expect(await rig.writer.availability() == .available)

        await rig.grants.revoke(.menuBarLayout)
        let (made, keys) = arrangement([.dot(.hidden): 10])
        await #expect(throws: LayoutWriteError.needsGrant) { try await rig.writer.write(made, keys: keys) }
        #expect(await rig.writer.availability() == .needsGrant)
    }

    @Test func heldByWholeKeyLeftover() async throws {
        try writeTable([Self.weather: 100])
        let rig = try await rig()
        // A platform test's change to the whole table is still in the journal: a kept write under it would be put back with it.
        let whole = JournalEntry.plistKey(filePath: CanonicalPath.of(layoutFile), key: Self.tableKey,
                                          original: .dictionary([Self.weather: .integer(100)]), strategy: .cfPreferences)
        try await rig.journal.record(whole)

        let text = "A platform test's change to com.apple.MenuBar.plist hasn't been put back yet. Use Replay now in Settings › Diagnostics."
        #expect(await rig.writer.availability() == .held(text))
        let (made, keys) = arrangement([.dot(.hidden): 10])
        await #expect(throws: LayoutWriteError.failed(text)) { try await rig.writer.write(made, keys: keys) }
        #expect(try tableOnDisk() == [Self.weather: 100], "nothing was written")

        // Once the leftover is put back, the table can be written again.
        #expect(await rig.journal.replay(using: PlistJournalRestorer(access: PlistFileAccess(journal: rig.journal, paths: paths, grants: rig.grants, io: rig.service.io, clock: SteppingClock()), grants: rig.grants)).isEmpty)
        #expect(await rig.writer.availability() == .available)
    }

    // MARK: Writing

    @Test func writesOnlyChangedDistances() async throws {
        try writeTable([Self.weather: 100, Self.alwaysDot: 80, Self.hiddenDot: 60])
        let rig = try await rig()
        let (made, keys) = arrangement([.dot(.always): 80.2, .dot(.hidden): 70, .divider: 40])

        let written = try await rig.writer.write(made, keys: keys)

        // The always-dot is within 0.25 of the table's: left alone. The hidden dot moved. The divider has no entry yet.
        #expect(Set(written) == [Self.hiddenDot, Self.divider], "it answers the keys it wrote")
        #expect(try tableOnDisk() == [Self.weather: 100, Self.alwaysDot: 80, Self.hiddenDot: 70, Self.divider: 40])
        #expect(await rig.journal.keptRecords().count == 2, "only the places that were written are journaled")

        // Written again as it is now: nothing differs, so nothing is written.
        let writesBefore = rig.service.writeCount
        #expect(try await rig.writer.write(made, keys: keys).isEmpty)
        #expect(rig.service.writeCount == writesBefore)
    }

    @Test func tokensWithoutADistanceOrAKeyAreLeftOut() async throws {
        try writeTable([Self.weather: 100])
        let rig = try await rig()
        let made = LayoutArrangement(tokens: [.dot(.hidden), .dot(.always), .divider], distances: [.dot(.hidden): 70, .dot(.always): 80], skipped: [])
        let written = try await rig.writer.write(made, keys: [.dot(.hidden): Self.hiddenDot, .divider: Self.divider])
        #expect(written == [Self.hiddenDot])
        #expect(try tableOnDisk() == [Self.weather: 100, Self.hiddenDot: 70])
    }

    @Test func writesAreKeptAndNewPathsOnly() async throws {
        try writeTable([Self.weather: 100, Self.hiddenDot: 60])
        let first = try await rig()
        let (made, keys) = arrangement([.dot(.hidden): 70])
        #expect(try await first.writer.write(made, keys: keys).count == 1)

        let records = await first.journal.keptRecords()
        #expect(records.count == 1)
        #expect(records.first?.lifetime == .kept)
        #expect(LayoutTableWriter.lifetime == .kept)
        #expect(await first.writer.hasKeptChanges)
        #expect(await first.journal.untilQuitRecords().isEmpty, "nothing is put back on quit")

        // macOS re-sorts the bar and rewrites the table, and the preferences service flushes lazily: it says another value from the file's.
        // A place that is journaled already is not waited for (a place that isn't would be, for two seconds, and refused).
        let lagging = ScriptedService(.saysUntilWritten(.dictionary([Self.weather: .integer(100), Self.hiddenDot: .integer(65)])))
        let again = try await rig(service: lagging, journal: first.journal)
        let (next, nextKeys) = arrangement([.dot(.hidden): 90])
        #expect(try await again.writer.write(next, keys: nextKeys).count == 1)
        #expect(try tableOnDisk()[Self.hiddenDot] == 90)
        #expect(await first.journal.keptRecords().count == 1, "the same place keeps the one record, with its original")
    }

    // MARK: Putting back

    @Test func restoreOriginalPutsBackPreMantelDistancesInOneWrite() async throws {
        try writeTable([Self.weather: 100, Self.alwaysDot: 50])
        let rig = try await rig()
        let (made, keys) = arrangement([.dot(.always): 60, .dot(.hidden): 70, .divider: 20])
        #expect(try await rig.writer.write(made, keys: keys).count == 3)
        #expect(try tableOnDisk() == [Self.weather: 100, Self.alwaysDot: 60, Self.hiddenDot: 70, Self.divider: 20])
        #expect(await rig.writer.hasKeptChanges)

        // What macOS or the person changed meanwhile, elsewhere in the table, stays.
        try writeTable([Self.weather: 110, Self.alwaysDot: 60, Self.hiddenDot: 70, Self.divider: 20])
        let writesBefore = rig.service.writeCount

        let count = try await rig.writer.restoreOriginalLayout()

        #expect(count == 3)
        #expect(rig.service.writeCount == writesBefore + 1, "one write")
        #expect(try tableOnDisk() == [Self.weather: 110, Self.alwaysDot: 50], "the entry that existed is as it was, the new ones are gone")
        #expect(await rig.writer.hasKeptChanges == false)
        #expect(await rig.journal.keptRecords().isEmpty)
    }

    @Test func restoreWithNothingKeptIsZero() async throws {
        try writeTable([Self.weather: 100])
        let rig = try await rig()
        let writesBefore = rig.service.writeCount
        #expect(try await rig.writer.restoreOriginalLayout() == 0)
        #expect(rig.service.writeCount == writesBefore)
        #expect(await rig.writer.hasKeptChanges == false)
    }
}
