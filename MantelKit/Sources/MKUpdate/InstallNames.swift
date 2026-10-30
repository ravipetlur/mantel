import Foundation

/// The names an install puts on disk.
public enum InstallNames {
    /// The app inside the disk image, and the name of the running app as shipped.
    public static let appName = "Mantel.app"

    /// The start of the work folder's name, in the temporary directory: one folder per attempt, holding the downloads and
    /// the mount point.
    public static let workFolderPrefix = "Mantel-update-"

    /// Whether a folder of this name is an install's work folder.
    public static func isWorkFolder(named name: String) -> Bool {
        name.hasPrefix(workFolderPrefix) && name.count > workFolderPrefix.count
    }

    /// How long a work folder is left alone before it counts as a leftover: long enough that a person who was handed the
    /// disk image is still dragging the app out of it.
    public static let staleAfter: TimeInterval = 12 * 3600

    /// The names, among `folders` (a name and when it was last changed), of the work folders an earlier install left
    /// behind (a crash, or a hand-off whose image was never ejected): those untouched for more than `staleAfter`. A
    /// folder of another name, and one dated in the future, is never one.
    public static func staleWorkFolders(_ folders: [(name: String, modified: Date)], now: Date) -> [String] {
        folders.filter { isWorkFolder(named: $0.name) && now.timeIntervalSince($0.modified) > staleAfter }.map(\.name)
    }

    /// The hidden name the verified copy gets beside the running app, until it replaces it.
    public static func stagedName(for version: VersionNumber) -> String {
        ".Mantel-update-\(version).app"
    }

    /// Whether a name is exactly a staged copy's: `.Mantel-update-<X.Y.Z>.app`, hidden, with a version in its own
    /// spelling (no `v`, no suffix). Nothing else beside the app is ever taken for one.
    public static func isStagedName(_ name: String) -> Bool {
        let prefix = ".Mantel-update-"
        let suffix = ".app"
        guard name.hasPrefix(prefix), name.hasSuffix(suffix), name.count > prefix.count + suffix.count else { return false }
        let text = String(name.dropFirst(prefix.count).dropLast(suffix.count))
        guard let version = VersionNumber(text), version.description == text else { return false }
        return true
    }

    /// The staged copies among the names in a folder, in the order given: what a crash left beside the app.
    public static func stagedCopies(in names: [String]) -> [String] {
        names.filter { isStagedName($0) }
    }

    /// The name the old app is kept under after it is replaced (`Mantel-1.1.0.app`), before it is deleted. A
    /// name that is taken (a backup an earlier update left beside the app) gets a number, as the Finder gives one, so
    /// nothing is overwritten.
    public static func backupName(for version: VersionNumber, isTaken: (String) -> Bool) -> String {
        let name = "Mantel-\(version).app"
        guard isTaken(name) else { return name }
        var number = 2
        while isTaken("Mantel-\(version) \(number).app") { number += 1 }
        return "Mantel-\(version) \(number).app"
    }
}
