import AppKit
import Foundation
import MKCore
import MKUpdate

/// Puts a verified app in place of the running one, and relaunches. Everything here is a copy or a move on the same
/// volume as the running app, so a failure before the swap leaves the current version untouched, and after it the old
/// one is deleted (or, when that fails, left beside the new one under its backup name).
nonisolated struct AppInstaller: Sendable {
    /// The running app's bundle.
    let running: URL
    /// The version installed in `running`'s place now, which the backup's name carries: the running app's, or the one an
    /// earlier update installed since, which this process hasn't restarted into (`UpdateCenter.effectiveVersion`). It is
    /// not read from the bundle on disk, which `Bundle` caches at its launch-time contents.
    let currentVersion: VersionNumber
    let verifier: any CodeVerifying

    /// The folder the running app is in.
    private var folder: URL { running.deletingLastPathComponent() }

    /// Whether the running app can be replaced where it is: its folder can be written to, and so can the app itself. A
    /// folder an admin can write to (`/Applications`) holds apps other users own, which can't be swapped out (the swap
    /// fails with a permissions error), and an app run from a disk image or a translocated copy is in a folder nobody can
    /// write to. In both cases the install ends in a hand-off.
    var destinationIsWritable: Bool {
        let fileManager = FileManager.default
        return fileManager.isWritableFile(atPath: folder.path(percentEncoded: false))
            && fileManager.isWritableFile(atPath: running.path(percentEncoded: false))
    }

    /// Copies the verified app beside the running one under a hidden name, checks the copy as it checked the original,
    /// swaps it in for the running app (which keeps working until it quits), and returns the old copy, which is now a
    /// backup beside the new one.
    ///
    /// A failure before the swap removes the copy and leaves the current version in place: `UpdateFailure.installFailed`.
    /// An error from the swap itself is looked at before anything is deleted (`recover`): when the swap took effect the
    /// install carries on; when it didn't, the app is put back if it was moved away, and the staged copy is deleted only
    /// once the app is known to be in place.
    func stageAndReplace(_ verified: URL, version: VersionNumber) throws -> URL {
        let fileManager = FileManager.default
        let staged = folder.appending(path: InstallNames.stagedName(for: version), directoryHint: .isDirectory)
        let backupName = InstallNames.backupName(for: currentVersion) {
            fileManager.fileExists(atPath: folder.appending(path: $0).path(percentEncoded: false))
        }
        let backup = folder.appending(path: backupName, directoryHint: .isDirectory)
        do {
            // A hidden copy an earlier try left behind would make the copy fail.
            if fileManager.fileExists(atPath: staged.path(percentEncoded: false)) { try fileManager.removeItem(at: staged) }
            try fileManager.copyItem(at: verified, to: staged)
            // What is swapped in is what was checked: the copy has the same signature, strictly, and the same signer.
            try verifier.checkSignature(of: staged)
            Log.update.info("The new version is staged beside the running app")
        } catch {
            Log.update.warning("The new version couldn't be staged: \(error.localizedDescription)")
            try? fileManager.removeItem(at: staged)
            throw UpdateFailure.installFailed
        }
        do {
            _ = try fileManager.replaceItemAt(running, withItemAt: staged, backupItemName: backupName,
                                              options: .withoutDeletingBackupItem)
        } catch {
            Log.update.warning("The running app couldn't be replaced: \(error.localizedDescription)")
            switch recover(from: error, staged: staged, backup: backup) {
            case .newCopyInPlace(let oldCopy):
                Log.update.info("The running app was replaced in spite of the error; the old copy is \(oldCopy.lastPathComponent)")
                return oldCopy
            case .failed(let failure):
                throw failure
            }
        }
        Log.update.info("The running app was replaced; the old copy is \(backupName)")
        return backup
    }

    /// How an error from the swap ended.
    private enum Recovered {
        /// The new copy is at the app's place, where the old one was; the old copy is at `oldCopy`. The install carries on.
        case newCopyInPlace(oldCopy: URL)
        case failed(UpdateFailure)
    }

    /// After an error from the swap: finds out where the old app and the new one are (`ReplaceRecovery`), and acts on
    /// it. Only a copy that has been checked is ever put at the app's place: the old app, or the staged copy, which passed
    /// the same signature and designated-requirement check as the app it was copied from.
    private func recover(from error: any Error, staged: URL, backup: URL) -> Recovered {
        // Where the swap left the old app, when the error says so. The key is documented in NSFileManager.h, which doesn't
        // declare it as a symbol, so it is spelled out. The running app's own place is never an old copy (it holds the new
        // copy, or the old app that never moved), so a key naming it counts as no key: it would otherwise be deleted.
        let reported = ReplaceRecovery.reportedOriginalLocation(
            (error as NSError).userInfo["NSFileOriginalItemLocationKey"] as? URL, running: running)
        let plan = ReplaceRecovery.plan(appInPlace: Self.exists(running), originalLocationReported: reported != nil,
                                        originalLocationExists: reported.map(Self.exists) ?? false,
                                        backupExists: Self.exists(backup), stagedExists: Self.exists(staged))
        switch plan {
        case .discardStaged:
            try? FileManager.default.removeItem(at: staged)
            return .failed(.installFailed)
        case .keepNewCopy:
            // The bytes at the app's place are the staged copy's, which passed the checks. The old one is where the error says.
            Log.update.warning("The swap took effect: the new version is in place and the old copy is at the place the error names")
            return .newCopyInPlace(oldCopy: reported ?? backup)
        case .restoreFromOriginalLocation:
            return putBack(from: reported ?? backup, staged: staged)
        case .restoreFromBackup:
            return putBack(from: backup, staged: staged)
        case .promoteStaged:
            return promote(staged, oldCopy: backup)
        case .appLost:
            Log.update.error("The app is missing from its folder and no copy of it was found")
            return .failed(.appNotRestored)
        }
    }

    /// Moves the old copy back to the app's place, and lets the staged copy go. When it can't be moved back, the staged
    /// copy takes the app's place instead (`ReplaceRecovery.planAfterFailedRestore`).
    private func putBack(from source: URL, staged: URL) -> Recovered {
        do {
            try FileManager.default.moveItem(at: source, to: running)
            Log.update.warning("The old copy was put back")
            try? FileManager.default.removeItem(at: staged)
            return .failed(.installFailed)
        } catch {
            Log.update.error("The old copy couldn't be put back: \(error.localizedDescription)")
            switch ReplaceRecovery.planAfterFailedRestore(stagedExists: Self.exists(staged)) {
            case .promoteStaged:
                return promote(staged, oldCopy: source)
            default:
                Log.update.error("The app is missing from its folder and no copy of it is left to put there")
                return .failed(.appNotRestored)
            }
        }
    }

    /// Moves the staged copy into the app's place: the app isn't missing, and the update is in. The old copy, wherever
    /// it is (`oldCopy`), is left for the caller to delete. When even this fails, the staged copy is kept, and the log says
    /// where it is.
    private func promote(_ staged: URL, oldCopy: URL) -> Recovered {
        do {
            try FileManager.default.moveItem(at: staged, to: running)
            Log.update.warning("The app was missing from its folder: the new copy was moved into its place")
            return .newCopyInPlace(oldCopy: oldCopy)
        } catch {
            Log.update.error("The new copy couldn't be moved into the app's place (\(error.localizedDescription)); it was kept as \(staged.lastPathComponent)")
            return .failed(.appNotRestored)
        }
    }

    private static func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path(percentEncoded: false))
    }

    /// Deletes the backup: an update replaces the old version, and nothing goes to the Trash. Throws when the delete
    /// fails; the new app is in place by then, so the caller carries on and the backup stays beside it. Nothing at
    /// `backup` (no old copy could be found) is nothing to delete, and the running app's own place is never deleted,
    /// whatever called it an old copy.
    func removeBackup(_ backup: URL) throws {
        guard !ReplaceRecovery.isRunningApp(backup, running: running) else {
            Log.update.error("The old copy is named as the running app's own place; it was not deleted")
            return
        }
        guard Self.exists(backup) else {
            Log.update.info("There is no old copy to delete")
            return
        }
        try FileManager.default.removeItem(at: backup)
        Log.update.info("The old copy is deleted")
    }

    /// Starts the relaunch with the app's own relauncher, which waits for this process to exit before it opens the app
    /// again, then quits through the app's own quit. False when the relaunch couldn't be started: the app is still running.
    @MainActor
    static func relaunch() -> Bool {
        Relauncher.relaunch()
    }
}
