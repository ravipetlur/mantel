import Foundation
import MKCore
import MKLayout
import MKTestSupport
import Testing

@testable import MKMenuBar

/// The order table, read from a file in a folder of the test's own through a grant of its own: never the real preferences file, and never
/// the real `cfprefsd` (the preferences are read from the file, as the probe tests read them).
@Suite("Layout table reader", .timeLimit(.minutes(1)))
struct LayoutTableReaderTests {
    /// Held by the suite, and so for the whole test.
    let folder = TemporaryFolder(prefix: "mantel-layout-table")
    let clock = FakeClock()

    private var home: URL { folder.url.appending(path: "home", directoryHint: .isDirectory) }
    private var paths: MantelPaths {
        MantelPaths(root: folder.url.appending(path: "Mantel", directoryHint: .isDirectory),
                    logs: folder.url.appending(path: "Logs", directoryHint: .isDirectory))
    }
    private var layoutFile: URL {
        home.appending(path: "Library/Group Containers/com.apple.MenuBar/Library/Preferences/com.apple.MenuBar.plist")
    }

    private func write(_ contents: [String: Any]) throws {
        try FileManager.default.createDirectory(at: layoutFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: contents, format: .xml, options: 0).write(to: layoutFile)
    }

    private struct Rig {
        let reader: LayoutTableReader
        let journal: Journal
        let grants: FileGrantStore
    }

    private func rig(granting: Bool = true) async throws -> Rig {
        try paths.createDirectories()
        let journal = Journal(file: paths.journalFile, clock: clock)
        let grants = FileGrantStore(store: SettingsStore(paths: paths, clock: SystemClock(), debounce: .seconds(3600)), bookmarkOptions: [], clock: clock)
        if granting { _ = try await grants.grant(.menuBarLayout, chosen: layoutFile, home: home) }
        let access = PlistFileAccess(journal: journal, paths: paths, grants: grants, io: .filesOnly, clock: clock)
        return Rig(reader: LayoutTableReader(access: access, grants: grants), journal: journal, grants: grants)
    }

    @Test func readsTheTableThroughTheGrant() async throws {
        try write([
            "TrailingItemPreferredPositions": [
                "status:com.example.weather::weather.temp": 120,
                "status:com.example.weather::weather.alerts": 84.5,
                "status:com.example.notes::notes.main": 46,
                "module:Clock": 0,
                "module:Battery": 31.25,
            ] as [String: Any],
            "SomethingElse": "left alone",
        ])
        let rig = try await rig()

        let table = try await rig.reader.read()

        #expect(table.distances == [
            "status:com.example.weather::weather.temp": 120, "status:com.example.weather::weather.alerts": 84.5,
            "status:com.example.notes::notes.main": 46, "module:Clock": 0, "module:Battery": 31.25,
        ])
        #expect(table.statusKeys(ofApp: "com.example.weather") == ["status:com.example.weather::weather.alerts", "status:com.example.weather::weather.temp"])
        #expect(table.moduleKeys == ["module:Battery", "module:Clock"])
    }

    @Test func aValueThatIsNoDistanceIsLeftOut() async throws {
        try write(["TrailingItemPreferredPositions": ["status:com.example.a::x": 10, "status:com.example.a::y": "ten",
                                                      "status:com.example.a::z": true, "status:com.example.a::w": [1, 2]] as [String: Any]])
        let table = try await rig().reader.read()
        #expect(table.distances["status:com.example.a::x"] == 10)
        #expect(table.distances["status:com.example.a::y"] == nil)
        #expect(table.distances["status:com.example.a::w"] == nil)
    }

    @Test func noTableIsAnEmptyOne() async throws {
        try write(["SomethingElse": 1])
        #expect(try await rig().reader.read() == LayoutTableSnapshot(distances: [:]))
    }

    @Test func aTableThatIsNotADictionaryIsAnError() async throws {
        try write(["TrailingItemPreferredPositions": [1, 2, 3]])
        let rig = try await rig()
        await #expect(throws: PlistAccessError.notADictionary) { try await rig.reader.read() }
    }

    @Test func noGrantIsNoAccess() async throws {
        try write(["TrailingItemPreferredPositions": ["module:Clock": 0] as [String: Any]])
        let rig = try await rig(granting: false)
        await #expect(throws: FileGrantError.stale(fileName: "com.apple.MenuBar.plist")) { try await rig.reader.read() }
    }

    @Test func aFileThatWentAwayIsNoAccessEither() async throws {
        try write(["TrailingItemPreferredPositions": ["module:Clock": 0] as [String: Any]])
        let rig = try await rig()
        try FileManager.default.removeItem(at: layoutFile)
        await #expect(throws: FileGrantError.stale(fileName: "com.apple.MenuBar.plist")) { try await rig.reader.read() }
    }

    @Test func readingChangesNothing() async throws {
        try write(["TrailingItemPreferredPositions": ["status:com.example.a::x": 10] as [String: Any]])
        let before = try Data(contentsOf: layoutFile)
        let rig = try await rig()

        _ = try await rig.reader.read()
        _ = try await rig.reader.read()

        #expect(try Data(contentsOf: layoutFile) == before)
        #expect(await rig.journal.records().isEmpty, "nothing is recorded, since nothing is written")
    }
}
