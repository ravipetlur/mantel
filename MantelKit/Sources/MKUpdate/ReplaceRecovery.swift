import Foundation

/// What to do on disk after the swap of the running app for its new copy reports an error.
///
/// `replaceItemAt` moves the running app aside (to the backup name beside it) before it puts the new copy in its place, so
/// an error can arrive with the swap undone, half done or done:
///
/// - **Something is at the app's place.** `NSFileOriginalItemLocationKey` comes with the error only when the old app is
///   not at its original location (NSFileManager.h). So with the key, what is at the app's place is the new copy and the
///   old app is where the key says: the swap took effect (`keepNewCopy`). Without the key it is the old app, which was
///   never moved (`discardStaged`).
/// - **Nothing is at the app's place.** The old copy is put back, from where the key says or from its backup name. When
///   it can't be found or put back, the staged copy (which has passed the same checks as the app it was copied from)
///   takes the app's place; only when that is impossible too is the app lost (`appLost`).
///
/// The staged copy is deleted only when the old app is known to be in place and untouched.
///
/// The running app's own place is never an old copy: it is where the new copy is, or the old app that never moved. So a
/// place the error names that is the running app's (`reportedOriginalLocation`) is taken as nothing named, and nothing
/// at that place is ever deleted as an old copy (`isRunningApp`).
public enum ReplaceRecovery {
    public enum Plan: Equatable, Sendable {
        /// The old app is where it was: nothing to restore, and the staged copy can go.
        case discardStaged
        /// The swap took effect: the new copy is at the app's place and the old one is where the error names. Nothing is
        /// deleted or put back; the old copy is deleted and the app relaunched, as after a clean swap.
        case keepNewCopy
        /// Move the old copy back from the place the error names, then let the staged copy go.
        case restoreFromOriginalLocation
        /// Move the old copy back from its backup name beside the app, then let the staged copy go.
        case restoreFromBackup
        /// No old copy to restore: move the staged copy into the app's place.
        case promoteStaged
        /// Nothing at the app's place and nothing to put there: the app is missing from its folder.
        case appLost
    }

    /// - Parameters:
    ///   - appInPlace: something exists at the running app's place.
    ///   - originalLocationReported: the error carries `NSFileOriginalItemLocationKey`.
    ///   - originalLocationExists: something exists at the place that key names (false when it isn't reported).
    ///   - backupExists: something exists at the backup name beside the app.
    ///   - stagedExists: the staged copy still exists.
    public static func plan(appInPlace: Bool, originalLocationReported: Bool, originalLocationExists: Bool,
                            backupExists: Bool, stagedExists: Bool) -> Plan {
        if appInPlace { return originalLocationReported ? .keepNewCopy : .discardStaged }
        if originalLocationReported, originalLocationExists { return .restoreFromOriginalLocation }
        if backupExists { return .restoreFromBackup }
        return planAfterFailedRestore(stagedExists: stagedExists)
    }

    /// What is left to do when the old copy couldn't be put back (or there was none): the staged copy takes the app's
    /// place if it is there, else the app is lost.
    public static func planAfterFailedRestore(stagedExists: Bool) -> Plan {
        stagedExists ? .promoteStaged : .appLost
    }

    /// The place the error names as the old app's, as far as a recovery may rely on it: nil when none is named, and nil
    /// when the one named is the running app's own place, which is never an old copy.
    public static func reportedOriginalLocation(_ reported: URL?, running: URL) -> URL? {
        guard let reported, !isRunningApp(reported, running: running) else { return nil }
        return reported
    }

    /// Whether `url` is the running app's own place, however the path is spelled (a trailing slash, `.` and `..` don't
    /// matter once it is standardized).
    public static func isRunningApp(_ url: URL, running: URL) -> Bool {
        standardizedPath(url) == standardizedPath(running)
    }

    /// The standardized path without a trailing slash, which a URL made as a directory keeps and the same place spelled
    /// as a file doesn't.
    private static func standardizedPath(_ url: URL) -> String {
        var path = url.standardizedFileURL.path(percentEncoded: false)
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        return path
    }
}
