import Foundation
import MKCore
import MKTestSupport
import Testing

@testable import MKCore

/// A settings document with a migration: version 1 called `name` `title`.
private struct TestSettings: SettingsDocument {
    static let fileName = "settings.json"
    static let currentVersion = 2

    var name = "default"
    var count = 0
    var created: Date?

    init() {}

    init(name: String, count: Int = 0, created: Date? = nil) {
        self.name = name
        self.count = count
        self.created = created
    }

    static func migrate(_ document: JSONValueTree, from version: Int) throws -> JSONValueTree {
        guard version == 1 else { throw SettingsMigrationError.noMigration(file: fileName, from: version, to: currentVersion) }
        var migrated = document
        migrated["name"] = migrated.removeValue(forKey: "title")
        return migrated
    }
}

/// A second document that has no migrations of its own.
private struct OtherSettings: SettingsDocument {
    static let fileName = "other.json"
    static let currentVersion = 1

    var flag = false
}

/// `TestSettings` under a file name no other test uses. The log is the whole process's, and the other tests of this suite migrate
/// `settings.json` at the same time: the tests that count the migration's lines count only the lines of this file.
private struct MigratedOnceSettings: SettingsDocument {
    static let fileName = "migrated-once.json"
    static let currentVersion = 2

    var name = "default"
    var count = 0

    init() {}

    init(name: String, count: Int = 0) {
        self.name = name
        self.count = count
    }

    static func migrate(_ document: JSONValueTree, from version: Int) throws -> JSONValueTree {
        guard version == 1 else { throw SettingsMigrationError.noMigration(file: fileName, from: version, to: currentVersion) }
        var migrated = document
        migrated["name"] = migrated.removeValue(forKey: "title")
        return migrated
    }
}

/// What a closure that runs while the log is captured loaded.
private actor LoadedDocuments {
    private(set) var all: [MigratedOnceSettings] = []
    func add(_ document: MigratedOnceSettings) { all.append(document) }
}

@Suite("SettingsStore", .timeLimit(.minutes(1)))
struct SettingsStoreTests {
    /// Held by the suite, and so for the whole test: the folder is deleted when the test is over.
    let folder = TemporaryFolder(prefix: "mantel-settings")
    let clock = FakeClock()
    private let fileManager = FileManager.default

    private var paths: MantelPaths {
        MantelPaths(root: folder.url.appending(path: "Support", directoryHint: .isDirectory),
                    logs: folder.url.appending(path: "Logs", directoryHint: .isDirectory))
    }

    private func makeStore() -> SettingsStore {
        SettingsStore(paths: paths, clock: clock)
    }

    /// A store that has loaded both documents, so that either can be saved (a document the store hasn't loaded isn't saved).
    private func makeLoadedStore(debounce: Duration = .milliseconds(500)) async -> SettingsStore {
        let store = SettingsStore(paths: paths, clock: clock, debounce: debounce)
        _ = await store.load(TestSettings.self)
        _ = await store.load(OtherSettings.self)
        return store
    }

    private func file(_ name: String) -> URL { paths.settings.appending(path: name) }

    private func exists(_ url: URL) -> Bool { fileManager.fileExists(atPath: url.path) }

    /// The copies of `name` that a migration made, in Backups.
    private func backups(of name: String) -> [String] {
        names(in: paths.backups).filter { $0.hasPrefix("\(name)-v") }
    }

    /// Puts `contents` in the settings folder as `name`, as a file written by some other version of Mantel.
    @discardableResult
    private func plant(_ contents: String, as name: String = "settings.json") throws -> URL {
        try fileManager.createDirectory(at: paths.settings, withIntermediateDirectories: true)
        let url = file(name)
        try Data(contents.utf8).write(to: url)
        return url
    }

    private func names(in folder: URL) -> [String] {
        ((try? fileManager.contentsOfDirectory(atPath: folder.path)) ?? []).sorted()
    }

    private func mode(of url: URL) throws -> Int? {
        try fileManager.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
    }

    private func contents(of url: URL) throws -> Data { try Data(contentsOf: url) }

    // MARK: Loading

    @Test func missingFileGivesDefaults() async {
        let store = makeStore()
        #expect(await store.load(TestSettings.self) == TestSettings())
        #expect(await store.isReadOnly(TestSettings.self) == false)
        #expect(!exists(paths.root), "loading doesn't make anything")
    }

    @Test func versionEqualToCurrentIsDecoded() async throws {
        try plant(#"{"version": 2, "document": {"name": "On disk", "count": 9, "created": "2023-11-14T22:13:20Z"}}"#)
        let loaded = await makeStore().load(TestSettings.self)
        #expect(loaded == TestSettings(name: "On disk", count: 9, created: Date(timeIntervalSince1970: 1_700_000_000)))
    }

    @Test func olderVersionIsBackedUpAndMigrated() async throws {
        let original = #"{"version": 1, "document": {"title": "Old name", "count": 3}}"#
        let url = try plant(original)
        let store = makeStore()

        let loaded = await store.load(TestSettings.self)
        #expect(loaded == TestSettings(name: "Old name", count: 3))
        #expect(await store.isReadOnly(TestSettings.self) == false)

        // The file as it was is kept in Backups, under the old version's name.
        let backups = names(in: paths.backups)
        #expect(backups.count == 1)
        let backup = try #require(backups.first)
        #expect(backup.wholeMatch(of: #/settings\.json-v1-\d{8}-\d{6}Z\.json/#) != nil, "named \(backup)")
        #expect(try contents(of: paths.backups.appending(path: backup)) == Data(original.utf8))
        // The file itself is rewritten on the next save, not by loading.
        #expect(try contents(of: url) == Data(original.utf8))

        await store.save(loaded)
        await store.flush()
        let written = try JSONDecoder().decode(Envelope<TestSettings>.self, from: contents(of: url))
        #expect(written.version == 2)
        #expect(written.document == loaded)
        #expect(names(in: paths.backups).count == 1, "saving makes no further backup")
    }

    /// Two readers load the file before the migrated document is saved (the app's layout reader and the save that follows
    /// its first change): the migration happens once, and the second load gets the migrated document, not the old file again.
    @Test func aFileLoadedTwiceBeforeItsSaveIsMigratedOnce() async throws {
        let original = #"{"version": 1, "document": {"title": "Old name", "count": 3}}"#
        let url = try plant(original, as: MigratedOnceSettings.fileName)
        let store = makeStore()

        let loads = LoadedDocuments()
        let lines = await LogCapture.lines {
            await loads.add(await store.load(MigratedOnceSettings.self))
            await loads.add(await store.load(MigratedOnceSettings.self))
        }

        let both = await loads.all
        #expect(both == [MigratedOnceSettings(name: "Old name", count: 3), MigratedOnceSettings(name: "Old name", count: 3)],
                "the second load sees the migrated document")
        #expect(lines.filter { $0.contains("migrated-once.json was migrated from version") }.count == 1, "\(lines)")
        #expect(backups(of: MigratedOnceSettings.fileName).count == 1, "one copy of the old file")
        #expect(try contents(of: url) == Data(original.utf8), "the file is still rewritten by a save, not by a load")

        // A save changes what a later load returns, and after the write the file itself is version 2.
        await store.save(MigratedOnceSettings(name: "Changed", count: 4))
        #expect(await store.load(MigratedOnceSettings.self) == MigratedOnceSettings(name: "Changed", count: 4))
        await store.flush()
        #expect(await store.load(MigratedOnceSettings.self) == MigratedOnceSettings(name: "Changed", count: 4))
        let written = try JSONDecoder().decode(Envelope<MigratedOnceSettings>.self, from: contents(of: url))
        #expect(written.version == 2)
        #expect(backups(of: MigratedOnceSettings.fileName).count == 1)
    }

    /// The migrated document is kept only while the file is the one it came from: another old file put in its place before the save (a
    /// copy from Backups put back), or a current one another writer saved, is read afresh.
    @Test func aFileChangedOnDiskBeforeTheSaveIsReadAfresh() async throws {
        let store = makeStore()
        let loads = LoadedDocuments()
        try plant(#"{"version": 1, "document": {"title": "First", "count": 1}}"#, as: MigratedOnceSettings.fileName)
        var lines = await LogCapture.lines { await loads.add(await store.load(MigratedOnceSettings.self)) }
        clock.advance(by: .seconds(2))
        try plant(#"{"version": 1, "document": {"title": "Second", "count": 2}}"#, as: MigratedOnceSettings.fileName)
        lines += await LogCapture.lines { await loads.add(await store.load(MigratedOnceSettings.self)) }
        try plant(#"{"version": 2, "document": {"name": "Third", "count": 3}}"#, as: MigratedOnceSettings.fileName)
        lines += await LogCapture.lines { await loads.add(await store.load(MigratedOnceSettings.self)) }

        #expect(await loads.all == [MigratedOnceSettings(name: "First", count: 1), MigratedOnceSettings(name: "Second", count: 2),
                                    MigratedOnceSettings(name: "Third", count: 3)])
        #expect(lines.filter { $0.contains("migrated-once.json was migrated from version") }.count == 2, "\(lines)")
        #expect(backups(of: MigratedOnceSettings.fileName).count == 2, "a copy of each old file")
    }

    /// A file whose copy couldn't be made is read-only and its error is told once, not at every load.
    @Test func aFileWhoseBackupCantBeMadeIsToldAboutOnceWhenLoadedTwice() async throws {
        try plant(#"{"version": 1, "document": {"title": "Old name", "count": 3}}"#, as: MigratedOnceSettings.fileName)
        try fileManager.createDirectory(at: paths.backups, withIntermediateDirectories: true)
        try fileManager.setAttributes([.posixPermissions: 0o500], ofItemAtPath: paths.backups.path)
        defer { try? fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: paths.backups.path) }
        let store = makeStore()

        let lines = await LogCapture.lines {
            _ = await store.load(MigratedOnceSettings.self)
            _ = await store.load(MigratedOnceSettings.self)
        }
        #expect(await store.load(MigratedOnceSettings.self) == MigratedOnceSettings(name: "Old name", count: 3))
        #expect(await store.isReadOnly(MigratedOnceSettings.self))
        #expect(lines.filter { $0.contains("migrated-once.json was migrated from version 1 but a copy of the old file couldn't be made") }.count == 1,
                "\(lines)")
    }

    @Test func anOlderVersionWithoutAMigrationIsSetAside() async throws {
        let original = #"{"version": 0, "document": {"flag": true}}"#
        let url = try plant(original, as: "other.json")
        let store = makeStore()
        #expect(await store.load(OtherSettings.self) == OtherSettings())
        #expect(!exists(url))
        let setAside = try #require(names(in: paths.backups).first)
        #expect(setAside.wholeMatch(of: #/corrupt-other-\d{8}-\d{6}Z\.json/#) != nil, "named \(setAside)")
        #expect(try contents(of: paths.backups.appending(path: setAside)) == Data(original.utf8))
    }

    @Test func aMigrationThatMakesSomethingUnreadableIsSetAside() async throws {
        let original = #"{"version": 1, "document": {"title": "x", "count": "many"}}"#
        let url = try plant(original)
        #expect(await makeStore().load(TestSettings.self) == TestSettings())
        #expect(!exists(url))
        let setAside = names(in: paths.backups).filter { $0.hasPrefix("corrupt-settings-") }
        #expect(setAside.count == 1)
    }

    @Test(arguments: [
        "{ this is not json",
        "[]",
        "null",
        #"{"document": {"name": "no version"}}"#,
        #"{"version": 2}"#,
        #"{"version": "two", "document": {}}"#,
        #"{"version": 2, "document": {"count": "five"}}"#,
        #"{"version": 2, "document": []}"#,
    ])
    func corruptFileIsSetAsideAndDefaultsLoad(json: String) async throws {
        let url = try plant(json)
        let store = makeStore()

        #expect(await store.load(TestSettings.self) == TestSettings())
        #expect(await store.isReadOnly(TestSettings.self) == false, "the defaults can be saved over the empty place")
        #expect(!exists(url), "the corrupt file is moved, not left in the way")
        let setAside = try #require(names(in: paths.backups).first)
        #expect(setAside.wholeMatch(of: #/corrupt-settings-\d{8}-\d{6}Z\.json/#) != nil, "named \(setAside)")
        #expect(try contents(of: paths.backups.appending(path: setAside)) == Data(json.utf8), "kept byte for byte")
    }

    @Test(arguments: ["", "   \n\t  "])
    func emptyFileIsSetAside(whitespace: String) async throws {
        let url = try plant(whitespace)
        #expect(await makeStore().load(TestSettings.self) == TestSettings())
        #expect(!exists(url))
        let setAside = try #require(names(in: paths.backups).first)
        #expect(setAside.hasPrefix("corrupt-settings-"))
        #expect(try contents(of: paths.backups.appending(path: setAside)) == Data(whitespace.utf8))
    }

    @Test func twoFilesSetAsideInTheSameSecondKeepTheirOwnNames() async throws {
        let store = makeStore()
        try plant("first corrupt")
        _ = await store.load(TestSettings.self)
        try plant("second corrupt")
        _ = await store.load(TestSettings.self)
        let setAside = names(in: paths.backups)
        #expect(setAside.count == 2, "\(setAside)")
        let texts = try setAside.map { String(decoding: try contents(of: paths.backups.appending(path: $0)), as: UTF8.self) }
        #expect(Set(texts) == ["first corrupt", "second corrupt"])
    }

    @Test func newerVersionIsReadOnly() async throws {
        let original = #"{"version": 99, "document": {"name": "future", "count": 5, "extra": {"a": [1, 2, 3]}}}"#
        let url = try plant(original)
        let store = makeStore()

        // Read with the current type, unknown keys ignored.
        let loaded = await store.load(TestSettings.self)
        #expect(loaded == TestSettings(name: "future", count: 5))
        #expect(await store.isReadOnly(TestSettings.self))

        // A save after loading changes nothing on disk, however long it waits.
        await store.save(TestSettings(name: "mine", count: 1))
        #expect(clock.sleeperCount == 0, "nothing is waiting to be written")
        clock.advance(by: .seconds(60))
        await store.flush()
        #expect(try contents(of: url) == Data(original.utf8))
        #expect(await store.writeCount == 0)
        #expect(!exists(paths.backups), "the file isn't moved or copied either")
    }

    @Test func aNewerFileTheCurrentTypeCantReadIsLeftAloneToo() async throws {
        let original = #"{"version": 99, "document": {"count": "a different shape"}}"#
        let url = try plant(original)
        let store = makeStore()
        #expect(await store.load(TestSettings.self) == TestSettings())
        #expect(await store.isReadOnly(TestSettings.self))
        await store.save(TestSettings(name: "mine"))
        await store.flush()
        #expect(try contents(of: url) == Data(original.utf8))
        #expect(!exists(paths.backups))
    }

    /// If a file that can't be read can't be set aside either, it is the only copy there is: it stays, and the store
    /// doesn't write over it.
    @Test func aCorruptFileThatCantBeMovedAsideIsNeverOverwritten() async throws {
        let original = "{ corrupt"
        let url = try plant(original)
        try fileManager.createDirectory(at: paths.backups, withIntermediateDirectories: true)
        try fileManager.setAttributes([.posixPermissions: 0o500], ofItemAtPath: paths.backups.path)
        defer { try? fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: paths.backups.path) }
        let store = makeStore()

        #expect(await store.load(TestSettings.self) == TestSettings())
        #expect(await store.isReadOnly(TestSettings.self))
        await store.save(TestSettings(name: "mine"))
        await store.flush()
        #expect(try contents(of: url) == Data(original.utf8))
        #expect(await store.writeCount == 0)
    }

    /// A migrated document is only safe to save over the old file if the old file has been kept. If the copy can't be made,
    /// the old file is the only copy there is: the document loads, read-only, and the file isn't written.
    @Test func aMigratedFileWhoseBackupCantBeMadeIsNeverOverwritten() async throws {
        let original = #"{"version": 1, "document": {"title": "Old name", "count": 3}}"#
        let url = try plant(original)
        try fileManager.createDirectory(at: paths.backups, withIntermediateDirectories: true)
        try fileManager.setAttributes([.posixPermissions: 0o500], ofItemAtPath: paths.backups.path)
        defer { try? fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: paths.backups.path) }
        let store = makeStore()

        #expect(await store.load(TestSettings.self) == TestSettings(name: "Old name", count: 3), "still migrated for this run")
        #expect(await store.isReadOnly(TestSettings.self))
        await store.save(TestSettings(name: "mine"))
        await store.flush()
        #expect(try contents(of: url) == Data(original.utf8))
        #expect(await store.writeCount == 0)
        #expect(names(in: paths.backups).isEmpty)
    }

    @Test func theDefaultMigrationKeepsACurrentDocumentAndRefusesAnyOther() throws {
        let document: JSONValueTree = ["flag": true]
        #expect(try OtherSettings.migrate(document, from: 1)["flag"] as? Bool == true)
        #expect(throws: SettingsMigrationError.noMigration(file: "other.json", from: 0, to: 1)) { try OtherSettings.migrate(document, from: 0) }
        #expect(throws: SettingsMigrationError.noMigration(file: "other.json", from: 2, to: 1)) { try OtherSettings.migrate(document, from: 2) }
    }

    @Test func readOnlyIsPerDocument() async throws {
        try plant(#"{"version": 99, "document": {}}"#)
        let store = makeStore()
        _ = await store.load(TestSettings.self)
        _ = await store.load(OtherSettings.self)
        #expect(await store.isReadOnly(TestSettings.self))
        #expect(await store.isReadOnly(OtherSettings.self) == false)
        await store.save(OtherSettings(flag: true))
        await store.flush()
        #expect(try JSONDecoder().decode(Envelope<OtherSettings>.self, from: contents(of: file("other.json"))).document.flag)
    }

    // MARK: Saving what was never read

    @Test func saveBeforeLoadIsRefused() async throws {
        // The file holds what the person set. A store that saved the defaults over it, because nothing had read it yet, would
        // lose it.
        let original = #"{"version": 2, "document": {"name": "the person's", "count": 9}}"#
        let url = try plant(original)
        let store = makeStore()

        let lines = await LogCapture.lines { await store.save(TestSettings(name: "defaults")) }
        #expect(lines.contains { $0.hasSuffix(" [WARN] [settings] settings.json wasn't read before this save, so it isn't saved") },
                "the refusal is logged, with the name of the file and not its contents: \(lines)")
        #expect(clock.sleeperCount == 0, "nothing is waiting to be written")
        await store.flush()

        #expect(try contents(of: url) == Data(original.utf8), "the file is as it was")
        #expect(await store.writeCount == 0)

        // Once it has been read, saving works, and a document that hasn't been is still refused.
        _ = await store.load(TestSettings.self)
        let otherLines = await LogCapture.lines { await store.save(OtherSettings(flag: true)) }
        #expect(otherLines.contains { $0.hasSuffix(" [WARN] [settings] other.json wasn't read before this save, so it isn't saved") },
                "and for the other document too: \(otherLines)")
        await store.save(TestSettings(name: "changed", count: 9))
        await store.flush()
        #expect(!exists(file("other.json")), "the other document was never loaded")
        #expect(await store.writeCount == 1)
        #expect(try JSONDecoder().decode(Envelope<TestSettings>.self, from: contents(of: file("settings.json"))).document.name == "changed")
    }

    @Test func aDocumentThatWasLoadedFromNoFileCanBeSaved() async throws {
        let store = makeStore()
        _ = await store.load(OtherSettings.self)
        await store.save(OtherSettings(flag: true))
        await store.flush()
        #expect(exists(file("other.json")))
    }

    @Test func migrationErrorsReadWell() {
        let none = SettingsMigrationError.noMigration(file: "settings.json", from: 1, to: 3)
        #expect(none.errorDescription == "Mantel can't update settings.json from version 1 to 3. It was set aside, and the defaults are used.")
        #expect(none.localizedDescription == none.errorDescription)

        let failed = SettingsMigrationError.failed(file: "profiles.json", reason: "wrong type at count")
        #expect(failed.errorDescription == "Mantel couldn't update profiles.json: wrong type at count. It was set aside, and the defaults are used.")
        #expect(SettingsMigrationError.noMigration(file: "a", from: 1, to: 2) == .noMigration(file: "a", from: 1, to: 2))
        #expect(SettingsMigrationError.noMigration(file: "a", from: 1, to: 2) != .failed(file: "a", reason: "x"))
    }

    // MARK: Old copies

    @Test func settingsBackupsArePruned() async throws {
        try fileManager.createDirectory(at: paths.backups, withIntermediateDirectories: true)
        func plantBackup(_ name: String) throws {
            try Data(name.utf8).write(to: paths.backups.appending(path: name))
        }
        let oldMigrated = (1 ... 6).map { "settings.json-v1-2020010\($0)-100000.json" }
        let oldCorrupt = (1 ... 7).map { "corrupt-settings-2020010\($0)-100000.json" }
        let unrelated = ["settings.json-v2-20200101-100000.json", "other.json-v1-20200101-100000.json", "corrupt-other-20200101-100000.json",
                         "com.apple.MenuBar-20200101-100000.plist"]
        for name in oldMigrated + oldCorrupt + unrelated { try plantBackup(name) }
        let store = makeStore()

        // A migration makes a copy of the old file: of the copies of this version of this file, the oldest and the four newest
        // are kept.
        try plant(#"{"version": 1, "document": {"title": "old", "count": 1}}"#)
        _ = await store.load(TestSettings.self)
        let migrated = names(in: paths.backups).filter { $0.hasPrefix("settings.json-v1-") }
        #expect(migrated.count == 5, "\(migrated)")
        #expect(migrated.first == oldMigrated[0], "the first copy ever is the person's original")
        #expect(migrated.contains(oldMigrated[5]) && migrated.contains(oldMigrated[3]) && !migrated.contains(oldMigrated[1]))
        #expect(migrated.contains { $0.wholeMatch(of: #/settings\.json-v1-2023\d{4}-\d{6}Z\.json/#) != nil }, "the new copy is among them")

        // A file set aside as corrupt: the five newest.
        try plant("{ corrupt", as: "settings.json")
        _ = await store.load(TestSettings.self)
        let corrupt = names(in: paths.backups).filter { $0.hasPrefix("corrupt-settings-") }
        #expect(corrupt.count == 5, "\(corrupt)")
        #expect(!corrupt.contains(oldCorrupt[0]) && !corrupt.contains(oldCorrupt[2]) && corrupt.contains(oldCorrupt[6]) && corrupt.contains(oldCorrupt[3]))
        #expect(corrupt.contains { $0.wholeMatch(of: #/corrupt-settings-2023\d{4}-\d{6}Z\.json/#) != nil }, "the one just set aside is kept")

        // Nothing else in the folder was touched.
        let left = names(in: paths.backups)
        for name in unrelated { #expect(left.contains(name), "\(name) was left alone") }
    }

    // MARK: Saving

    @Test func saveIsDebouncedThenWritten() async throws {
        let store = await makeLoadedStore()

        await store.save(TestSettings(name: "first"))
        await clock.waitForSleepers(1)
        #expect(!exists(file("settings.json")), "nothing is written at once")

        clock.advance(by: .milliseconds(300))
        await store.save(TestSettings(name: "second"))
        await clock.waitForSleepers(1)

        // 600 ms after the first save, but only 300 ms after the second one: the wait starts over.
        clock.advance(by: .milliseconds(300))
        for _ in 0 ..< 20 { await Task.yield() }
        #expect(!exists(file("settings.json")))
        #expect(await store.writeCount == 0)

        clock.advance(by: .milliseconds(200))
        await store.waitForDebounceTimers()
        #expect(await store.writeCount == 1, "two saves, one write")
        let written = try JSONDecoder().decode(Envelope<TestSettings>.self, from: contents(of: file("settings.json")))
        #expect(written.document.name == "second")
    }

    @Test func aSaveAfterAWriteStartsANewDebounce() async throws {
        let store = await makeLoadedStore()
        await store.save(TestSettings(name: "one"))
        await clock.waitForSleepers(1)
        clock.advance(by: .milliseconds(500))
        await store.waitForDebounceTimers()
        #expect(await store.writeCount == 1)

        await store.save(TestSettings(name: "two"))
        await clock.waitForSleepers(1)
        clock.advance(by: .milliseconds(499))
        for _ in 0 ..< 20 { await Task.yield() }
        #expect(await store.writeCount == 1)
        clock.advance(by: .milliseconds(1))
        await store.waitForDebounceTimers()
        #expect(await store.writeCount == 2)
        let written = try JSONDecoder().decode(Envelope<TestSettings>.self, from: contents(of: file("settings.json")))
        #expect(written.document.name == "two")
    }

    @Test func theDebounceIsTheOneTheStoreWasGiven() async throws {
        let store = await makeLoadedStore(debounce: .seconds(5))
        await store.save(TestSettings(name: "slow"))
        await clock.waitForSleepers(1)
        clock.advance(by: .milliseconds(4_999))
        for _ in 0 ..< 20 { await Task.yield() }
        #expect(await store.writeCount == 0)
        clock.advance(by: .milliseconds(1))
        await store.waitForDebounceTimers()
        #expect(await store.writeCount == 1)
    }

    @Test func eachDocumentHasItsOwnDebounce() async throws {
        let store = await makeLoadedStore()
        await store.save(TestSettings(name: "a"))
        await clock.waitForSleepers(1)
        clock.advance(by: .milliseconds(400))
        await store.save(OtherSettings(flag: true))
        await clock.waitForSleepers(2)
        // The first document's 500 ms are over, the second one's are not.
        clock.advance(by: .milliseconds(100))
        await store.waitForDebounceTimer(for: TestSettings.self)
        #expect(exists(file("settings.json")))
        #expect(!exists(file("other.json")))
        #expect(await store.writeCount == 1)
        clock.advance(by: .milliseconds(400))
        await store.waitForDebounceTimers()
        #expect(exists(file("other.json")))
        #expect(await store.writeCount == 2)
    }

    @Test func roundTripEqualsOriginal() async throws {
        let original = TestSettings(name: "Mantel ✓ “quoted” /slash/", count: 42,
                                    created: Date(timeIntervalSince1970: 1_700_000_000.5))
        let store = await makeLoadedStore()
        await store.save(original)
        await store.flush()

        // A new store, as after a relaunch.
        #expect(await makeStore().load(TestSettings.self) == original)
    }

    @Test func loadSeesASaveThatHasNotBeenWrittenYet() async {
        let store = await makeLoadedStore()
        await store.save(TestSettings(name: "pending", count: 7))
        #expect(await store.load(TestSettings.self) == TestSettings(name: "pending", count: 7))
        #expect(!exists(file("settings.json")))
    }

    @Test func flushWritesPendingNow() async throws {
        let store = await makeLoadedStore()
        await store.save(TestSettings(name: "now"))
        await store.save(OtherSettings(flag: true))
        #expect(!exists(file("settings.json")))

        await store.flush()
        #expect(await store.writeCount == 2)
        #expect(try JSONDecoder().decode(Envelope<TestSettings>.self, from: contents(of: file("settings.json"))).document.name == "now")
        #expect(try JSONDecoder().decode(Envelope<OtherSettings>.self, from: contents(of: file("other.json"))).document.flag)

        // The waits that were running end without writing again, and a flush with nothing pending writes nothing.
        await store.waitForDebounceTimers()
        await store.flush()
        #expect(await store.writeCount == 2)
        #expect(clock.sleeperCount == 0)
    }

    @Test func aSaveAfterAFlushIsStillWritten() async throws {
        let store = await makeLoadedStore()
        await store.save(TestSettings(name: "one"))
        await store.flush()
        await store.save(TestSettings(name: "two"))
        await clock.waitForSleepers(1)
        clock.advance(by: .milliseconds(500))
        await store.waitForDebounceTimers()
        #expect(await store.writeCount == 2)
        #expect(await makeStore().load(TestSettings.self).name == "two")
    }

    @Test func theFileIsVersionAndDocumentWithSortedKeysAndISODates() async throws {
        let store = await makeLoadedStore()
        await store.save(TestSettings(name: "A", count: 1, created: Date(timeIntervalSince1970: 1_700_000_000)))
        await store.flush()
        let text = try String(contentsOf: file("settings.json"), encoding: .utf8)
        #expect(text == """
        {
          "document" : {
            "count" : 1,
            "created" : "2023-11-14T22:13:20.000Z",
            "name" : "A"
          },
          "version" : 2
        }
        """)
    }

    @Test func filesAreMode0600() async throws {
        let store = await makeLoadedStore()
        await store.save(TestSettings(name: "private"))
        await store.flush()
        #expect(try mode(of: file("settings.json")) == 0o600)
        #expect(try mode(of: paths.settings) == 0o700, "a folder the store makes is private too")

        // Also over a file that was there before, with looser permissions.
        try fileManager.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file("settings.json").path)
        await store.save(TestSettings(name: "private again"))
        await store.flush()
        #expect(try mode(of: file("settings.json")) == 0o600)
        #expect(await makeStore().load(TestSettings.self).name == "private again")
    }

    @Test func backupsAreMode0600InAPrivateFolder() async throws {
        let store = makeStore()
        // A file set aside and a file copied before a migration, each from a file that was open to others.
        let corrupt = try plant("corrupt")
        try fileManager.setAttributes([.posixPermissions: 0o644], ofItemAtPath: corrupt.path)
        _ = await store.load(TestSettings.self)
        let old = try plant(#"{"version": 1, "document": {"title": "old", "count": 1}}"#)
        try fileManager.setAttributes([.posixPermissions: 0o644], ofItemAtPath: old.path)
        _ = await store.load(TestSettings.self)

        let backups = names(in: paths.backups)
        #expect(backups.count == 2)
        for backup in backups {
            #expect(try mode(of: paths.backups.appending(path: backup)) == 0o600, "\(backup)")
        }
        #expect(try mode(of: paths.backups) == 0o700)
    }

    @Test func savesOfDifferentDocumentsNeverInterleaveAndLeaveNoTemporaryFiles() async throws {
        let store = await makeLoadedStore()
        await withTaskGroup(of: Void.self) { group in
            for index in 0 ..< 25 {
                group.addTask { await store.save(TestSettings(name: "name \(index)", count: index)) }
                group.addTask { await store.save(OtherSettings(flag: index.isMultiple(of: 2))) }
                if index.isMultiple(of: 5) {
                    group.addTask { await store.flush() }
                }
            }
        }
        await store.flush()
        #expect(names(in: paths.settings) == ["other.json", "settings.json"])
        let settings = try JSONDecoder().decode(Envelope<TestSettings>.self, from: contents(of: file("settings.json")))
        #expect(settings.document.name == "name \(settings.document.count)", "one save's content, whole")
        _ = try JSONDecoder().decode(Envelope<OtherSettings>.self, from: contents(of: file("other.json")))
    }
}
