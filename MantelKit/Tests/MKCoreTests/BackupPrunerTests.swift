import Foundation
import MKTestSupport
import Testing

@testable import MKCore

@Suite("Backup pruner", .timeLimit(.minutes(1)))
struct BackupPrunerTests {
    /// Held by the suite, and so for the whole test.
    let folder = TemporaryFolder(prefix: "mantel-pruner")

    /// Makes the files in the folder, each holding its own name.
    private func plant(_ names: [String]) throws {
        for name in names {
            try Data(name.utf8).write(to: folder.url.appending(path: name))
        }
    }

    private func names() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: folder.url.path).sorted()
    }

    /// `<stem>-202610<nn>-100000.<ext>`, oldest first.
    private func copies(_ count: Int, stem: String = "snap", pathExtension: String = "plist") -> [String] {
        (1 ... count).map { "\(stem)-202610\(String(format: "%02d", $0))-100000.\(pathExtension)" }
    }

    @Test func keepsOldestAndFourNewest() throws {
        let all = copies(10)
        try plant(all)

        try BackupPruner.prune(in: folder.url, stem: "snap", pathExtension: "plist", keepOldest: 1, keepNewest: 4)

        #expect(try names() == [all[0]] + all[6...], "the first copy, which is the person's original, and the four newest")
    }

    @Test func keepsEverythingThereIsRoomFor() throws {
        let all = copies(5)
        try plant(all)
        try BackupPruner.prune(in: folder.url, stem: "snap", pathExtension: "plist", keepOldest: 1, keepNewest: 4)
        #expect(try names() == all, "one oldest and four newest are five, and there are five")

        try BackupPruner.prune(in: folder.url, stem: "snap", pathExtension: "plist", keepOldest: 3, keepNewest: 4)
        #expect(try names() == all, "the oldest and the newest may overlap; nothing is deleted by mistake")
    }

    @Test func noOldestKeepsOnlyTheNewest() throws {
        let all = copies(8, stem: "corrupt-settings", pathExtension: "json")
        try plant(all)
        try BackupPruner.prune(in: folder.url, stem: "corrupt-settings", pathExtension: "json", keepOldest: 0, keepNewest: 5)
        #expect(try names() == Array(all[3...]))
    }

    @Test func ignoresOtherNames() throws {
        let mine = copies(6)
        let others = [
            "snap.plist",                          // no time in it
            "snap-notes.plist",
            "snap-20261001-100000.json",           // another extension
            "snap-v1-20261001-100000.plist",       // another stem that starts with this one
            "other-20261001-100000.plist",
            "snap-20261001-100000.plist.bak",
            "snap-2026100-100000.plist",           // not a time
            "xsnap-20261001-100000.plist",
        ]
        try plant(mine + others)

        try BackupPruner.prune(in: folder.url, stem: "snap", pathExtension: "plist", keepOldest: 1, keepNewest: 2)

        #expect(try names() == (others + [mine[0]] + mine[4...]).sorted(), "only copies of this stem and extension were counted or deleted")
    }

    @Test func numberedDuplicatesCount() throws {
        // Three copies made in the same second, and one a second later.
        let first = "snap-20261001-100000.plist"
        let second = "snap-20261001-100000-2.plist"
        let third = "snap-20261001-100000-3.plist"
        let later = "snap-20261001-100001.plist"
        try plant([third, later, first, second])

        try BackupPruner.prune(in: folder.url, stem: "snap", pathExtension: "plist", keepOldest: 1, keepNewest: 2)
        #expect(try names() == [first, later, third].sorted(), "in the order they were made: first, -2, -3, then the later second")

        try plant([second])
        try BackupPruner.prune(in: folder.url, stem: "snap", pathExtension: "plist", keepOldest: 0, keepNewest: 1)
        #expect(try names() == [later])
    }

    @Test func aNumberAboveNineIsAfterNine() throws {
        let numbered = (2 ... 11).map { "snap-20261001-100000-\($0).plist" }
        try plant(["snap-20261001-100000.plist"] + numbered)
        try BackupPruner.prune(in: folder.url, stem: "snap", pathExtension: "plist", keepOldest: 0, keepNewest: 2)
        #expect(try names() == ["snap-20261001-100000-10.plist", "snap-20261001-100000-11.plist"].sorted(),
                "-10 and -11 are newer than -9, not older than -2")
    }

    @Test func aFolderThatIsNotThereHasNothingToPrune() throws {
        try BackupPruner.prune(in: folder.url.appending(path: "no-such-folder"), stem: "snap", pathExtension: "plist",
                               keepOldest: 1, keepNewest: 4)
    }

    @Test func aDeletionThatFailsIsReportedAfterTheOthersWereTried() throws {
        let all = copies(6)
        try plant(all)
        // A folder that can't be emptied can't be removed, and sits in the middle of what is to be deleted.
        let stuck = folder.url.appending(path: all[2])
        try FileManager.default.removeItem(at: stuck)
        try FileManager.default.createDirectory(at: stuck, withIntermediateDirectories: false)
        try Data("inside".utf8).write(to: stuck.appending(path: "inside"))
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: stuck.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: stuck.path) }

        #expect(throws: (any Error).self) {
            try BackupPruner.prune(in: folder.url, stem: "snap", pathExtension: "plist", keepOldest: 1, keepNewest: 1)
        }
        let left = try names()
        #expect(!left.contains(all[1]) && !left.contains(all[3]) && !left.contains(all[4]), "the deletions around the failed one were made")
    }

    // MARK: Names in UTC

    @Test func theStampIsUTCWhateverTheLocalTimeIs() {
        // 2026-11-01 05:30:00 UTC and 06:15:00 UTC: in New York the first is 1:30 EDT and the second 1:15 EST, because the clocks went
        // back in between.
        #expect(BackupPruner.stamp(for: Date(timeIntervalSince1970: 1_793_511_000)) == "20261101-053000Z")
        #expect(BackupPruner.stamp(for: Date(timeIntervalSince1970: 1_793_513_700)) == "20261101-061500Z")
        #expect(BackupPruner.stamp(for: Date(timeIntervalSince1970: 0)) == "19700101-000000Z")
    }

    @Test func utcNamesSortAcrossDSTChange() throws {
        // Named by the local time, the copy made later (1:15 EST) would sort before the earlier one (1:30 EDT) and be pruned as the
        // older. Named in UTC, they are in the order they were made.
        let earlier = "snap-\(BackupPruner.stamp(for: Date(timeIntervalSince1970: 1_793_511_000))).plist"
        let later = "snap-\(BackupPruner.stamp(for: Date(timeIntervalSince1970: 1_793_513_700))).plist"
        #expect(earlier == "snap-20261101-053000Z.plist" && later == "snap-20261101-061500Z.plist")
        try plant([earlier, later])

        let newYork = try #require(TimeZone(identifier: "America/New_York"))
        try BackupPruner.prune(in: folder.url, stem: "snap", pathExtension: "plist", keepOldest: 0, keepNewest: 1, localTimeZone: newYork)
        #expect(try names() == [later], "the copy made later is the one kept")
    }

    @Test func oldAndNewNamesMix() throws {
        // An old copy is named by the local time of the time it was made, a new one in UTC. In New York, 23:00 on 31 October is 03:00 UTC
        // on 1 November: later than a new copy made at 02:00 UTC, though its name sorts before it.
        let oldLocal = "snap-20261031-230000.plist"
        let newUTC = "snap-20261101-020000Z.plist"
        let muchOlder = "snap-20260101-120000.plist"
        let muchNewer = "snap-20261201-120000Z.plist"
        try plant([oldLocal, newUTC, muchOlder, muchNewer])

        let newYork = try #require(TimeZone(identifier: "America/New_York"))
        try BackupPruner.prune(in: folder.url, stem: "snap", pathExtension: "plist", keepOldest: 1, keepNewest: 2, localTimeZone: newYork)
        // Oldest to newest: muchOlder, newUTC (02:00Z), oldLocal (03:00Z), muchNewer. The oldest and the two newest stay.
        #expect(try names() == [muchOlder, oldLocal, muchNewer].sorted())

        // Read as UTC, the old name is the earlier one, and it is newUTC that goes.
        try plant([newUTC])
        try BackupPruner.prune(in: folder.url, stem: "snap", pathExtension: "plist", keepOldest: 1, keepNewest: 2,
                               localTimeZone: try #require(TimeZone(identifier: "UTC")))
        #expect(try names() == [muchOlder, newUTC, muchNewer].sorted(), "the old names are read in the time zone they were written in")
    }

    @Test func numberedCopiesOfTheSameSecondKeepTheirOrderInUTC() throws {
        let first = "snap-20261101-053000Z.plist"
        let second = "snap-20261101-053000Z-2.plist"
        let third = "snap-20261101-053000Z-10.plist"
        try plant([third, first, second])
        try BackupPruner.prune(in: folder.url, stem: "snap", pathExtension: "plist", keepOldest: 0, keepNewest: 2)
        #expect(try names() == [second, third].sorted())
    }

    @Test func aTimeThatIsNotATimeIsLeftAlone() throws {
        // Digits in the right places, but no such month, day or minute: not a copy this pruner made, so it isn't counted or deleted.
        let impossible = ["snap-20261340-120000.plist", "snap-20261101-126100Z.plist", "snap-20261101-250000Z.plist",
                          "snap-20260230-120000.plist"]
        let mine = copies(4)
        try plant(impossible + mine)
        try BackupPruner.prune(in: folder.url, stem: "snap", pathExtension: "plist", keepOldest: 0, keepNewest: 1)
        #expect(try names() == (impossible + [mine[3]]).sorted())
    }
}
