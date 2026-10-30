import Foundation
import MKUpdate
import Testing

/// The names an install puts on disk. Only the exact staged name is ever removed from beside the app, and a backup of an
/// earlier update is never overwritten.
@Suite("Install names", .timeLimit(.minutes(2)))
struct InstallNamesTests {
    let old = VersionNumber("1.1.0")!

    /// A backup left beside the app by an earlier update isn't overwritten: the name gets a number.
    @Test func aTakenBackupNameGetsANumber() {
        let taken: Set<String> = ["Mantel-1.1.0.app", "Mantel-1.1.0 2.app"]
        #expect(InstallNames.backupName(for: old, isTaken: { taken.contains($0) }) == "Mantel-1.1.0 3.app")
        #expect(InstallNames.backupName(for: old, isTaken: { $0 == "Mantel-1.1.0.app" }) == "Mantel-1.1.0 2.app")
    }

    /// Only the staged copy's own name, exactly: hidden, named for the updater, with a version `X.Y.Z`. Nothing else beside the
    /// app is ever taken for one, however similar its name.
    @Test(arguments: [
        "Mantel-update-1.2.0.app", ".Mantel-update-1.2.app", ".Mantel-update-1.2.0.0.app", ".Mantel-update-1.2.0",
        ".Mantel-update-1.2.0.app.zip", ".Mantel-update-1.2.0.app ", ".Mantel-update-v1.2.0.app", ".Mantel-update-1.02.0.app",
        ".Mantel-update-1.2.0-beta.app", ".Mantel-update-.app", ".mantel-update-1.2.0.app", "..Mantel-update-1.2.0.app",
        ".Mantel-update-1.2.0.app/..", "Mantel.app", "Mantel-1.1.0.app", "Safari.app", ".DS_Store", "",
    ])
    func nothingElseIsAStagedCopy(name: String) {
        #expect(!InstallNames.isStagedName(name))
    }

    @Test func onlyStagedCopiesAreChosenFromAFolder() {
        #expect(InstallNames.isStagedName(".Mantel-update-10.0.12.app"))
        let names = ["Mantel.app", ".Mantel-update-1.2.0.app", "Notes.app", "Mantel-1.1.0.app", ".DS_Store", ".Mantel-update-1.3.1.app",
                     ".Mantel-update-1.2.app"]
        #expect(InstallNames.stagedCopies(in: names) == [".Mantel-update-1.2.0.app", ".Mantel-update-1.3.1.app"])
    }

    /// A work folder an install left behind is cleared out only once it is clearly nobody's, and only by its own name.
    @Test func onlyOldWorkFoldersAreLeftovers() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let hour: TimeInterval = 3600
        let folders: [(name: String, modified: Date)] = [
            ("Mantel-update-FRESH", now.addingTimeInterval(-5 * 60)), ("Mantel-update-OLD", now.addingTimeInterval(-13 * hour)),
            ("Mantel-update-FUTURE", now.addingTimeInterval(hour)), ("Mantel-update-EDGE", now.addingTimeInterval(-InstallNames.staleAfter)),
            ("Other-folder", now.addingTimeInterval(-40 * 24 * hour)), ("Mantel-update-", now.addingTimeInterval(-40 * 24 * hour)),
        ]
        #expect(InstallNames.staleWorkFolders(folders, now: now) == ["Mantel-update-OLD"])
    }
}
