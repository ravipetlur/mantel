import Foundation
import MKCore
import MKTestSupport
import Testing

@testable import MKCore
@testable import MKLayout

/// The check of the saved icons on a copy of a layout file in which one icon had collected many records (`SittingFixture`).
@Suite("Cleaning a layout file", .timeLimit(.minutes(1)))
struct SittingCleanupTests {
    let folder = TemporaryFolder(prefix: "mantel-cleanup")
    let clock = FakeClock()

    private var paths: MantelPaths {
        MantelPaths(root: folder.url.appending(path: "Support", directoryHint: .isDirectory),
                    logs: folder.url.appending(path: "Logs", directoryHint: .isDirectory))
    }

    private func installFile() throws {
        try FileManager.default.createDirectory(at: paths.settings, withIntermediateDirectories: true)
        try Data(SittingFixture.version1File.utf8).write(to: paths.settings.appending(path: "profiles.json"))
    }

    /// The file as it was, read as the type reads it (nothing dropped, nothing unchecked).
    private func asItWas() throws -> SectionModel {
        let root = try #require(try JSONSerialization.jsonObject(with: Data(SittingFixture.version1File.utf8)) as? [String: Any])
        let document = try #require(root["document"])
        return try JSONDecoder().decode(ProfilesDocument.self, from: JSONSerialization.data(withJSONObject: document)).active
    }

    private func records(_ model: SectionModel) -> Int {
        MenuBarSection.allCases.reduce(0) { $0 + (model.order[$1]?.count ?? 0) }
    }

    @Test func version1DropsOwnNamesUnderOtherAppsAndMarksEveryAppUnchecked() async throws {
        try installFile()
        let before = try asItWas()
        #expect(records(before) == SittingFixture.recordsBefore)

        let store = SettingsStore(paths: paths, clock: clock)
        let loaded = await store.load(ProfilesDocument.self).active

        // The names of Mantel's own items, under apps that aren't Mantel: gone.
        #expect(SittingFixture.recordsBefore - records(loaded) == SittingFixture.recordsDroppedByTheFile)
        let all = MenuBarSection.allCases.flatMap { loaded.order[$0] ?? [] }
        #expect(!all.contains { SectionModel.namesAnOwnItem($0) })
        // The test item's own names are its own, and stay.
        #expect(all.contains { $0.string.hasSuffix("::mantel.fixture.one") })
        // Every app that has a record is unchecked: the apps the file places, all of which have one.
        #expect(loaded.unchecked == Set(before.apps.keys))
        #expect(loaded.unchecked.count == 30)
        // Where each is, and the rest of the file, as it was.
        #expect(loaded.apps == before.apps)
        #expect(loaded.systemItems == before.systemItems && loaded.newItems == before.newItems)

        // The old file is in Backups first.
        let backups = try FileManager.default.contentsOfDirectory(atPath: paths.backups.path(percentEncoded: false))
        let kept = try #require(backups.first { $0.hasPrefix("profiles.json-v1-") })
        let copy = try String(contentsOf: paths.backups.appending(path: kept), encoding: .utf8)
        #expect(copy == SittingFixture.version1File)
    }

    @Test func theSittingsCopyIsCleanedToItsExpectedLists() async throws {
        try installFile()
        let before = try asItWas()
        let store = SettingsStore(paths: paths, clock: clock)
        var model = await store.load(ProfilesDocument.self).active

        // Each app that was read whole is checked against what it lists.
        var dropped = 0
        for (app, texts) in SittingFixture.wholeReads.sorted(by: { $0.key < $1.key }) {
            let current = try texts.map { try #require(ItemID(string: $0)) }
            dropped += model.reconcile(app: app, current: current).dropped.count
        }

        #expect(dropped == SittingFixture.recordsDroppedByTheCheck)
        #expect(records(model) == SittingFixture.recordsAfter)
        #expect(model.order[.shown]?.map(\.string) == SittingFixture.expectedShown)
        #expect(model.order[.hidden]?.map(\.string) == SittingFixture.expectedHidden)
        #expect(model.order[.alwaysHidden]?.map(\.string) == SittingFixture.expectedAlwaysHidden)
        // Every app is where it was.
        #expect(model.apps == before.apps)
        // The apps that were not read are still to be checked, with the records they have.
        #expect(model.unchecked == SittingFixture.appsNotRead)
        #expect(model.unchecked.count == 14)
        // And no icon an app lists is without a record.
        for texts in SittingFixture.wholeReads.values {
            for text in texts { #expect(MenuBarSection.allCases.contains { model.order[$0]?.contains { $0.string == text } == true }, "\(text)") }
        }
    }

    @Test func aFileOfVersion2IsNotMigratedAgain() async throws {
        try installFile()
        let first = SettingsStore(paths: paths, clock: clock)
        var document = await first.load(ProfilesDocument.self)
        document.active.unchecked = []
        await first.save(document)
        await clock.waitForSleepers(1)
        clock.advance(by: .milliseconds(500))
        await first.waitForDebounceTimers()

        let second = SettingsStore(paths: paths, clock: clock)
        let reloaded = await second.load(ProfilesDocument.self)
        #expect(reloaded == document)
        #expect(reloaded.active.unchecked.isEmpty)
    }
}
