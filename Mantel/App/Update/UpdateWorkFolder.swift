import Foundation
import MKCore
import MKUpdate
import Synchronization

/// The private folder one install works in: the downloads and the mount point, in the temporary directory, readable by
/// this user only. It is made fresh for each attempt, and removed when the attempt ends; only a hand-off leaves it (the
/// image mounted from it is still in use), and `sweepLeftovers` clears out what a crash or a hand-off left behind.
nonisolated final class UpdateWorkFolder: Sendable {
    let url: URL
    /// Where the disk image is mounted: inside the folder, named after the volume, so that a Finder window opened on it
    /// says "Mantel".
    let mountPoint: URL
    /// Whether an eject of the image has been tried (by the detach step, or by the cleanup).
    private let ejectTried = Mutex(false)
    /// Whether this folder was made by this install (or is a leftover to clear out): only such a folder is ever removed.
    private let made: Mutex<Bool>

    init(parent: URL = FileManager.default.temporaryDirectory) {
        url = parent.appending(path: InstallNames.workFolderPrefix + UUID().uuidString, directoryHint: .isDirectory)
        mountPoint = url.appending(path: "Mantel", directoryHint: .isDirectory)
        made = Mutex(false)
    }

    /// Makes the folder, new and for this user only. It fails when there is already something of that name: the name has
    /// a UUID in it, so a folder that exists is not this install's.
    func create() throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: url, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        made.withLock { $0 = true }
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path(percentEncoded: false))
    }

    /// The detach step: ejects the image, and remembers that it was tried, so the cleanup doesn't try a second time.
    func detach(using images: DiskImage = DiskImage()) async {
        ejectTried.withLock { $0 = true }
        _ = await images.eject(mountPoint)
    }

    /// The cleanup: ejects the image if it is mounted and no eject was tried yet, then removes the folder. The folder is
    /// kept, and the log says so, when the image is still mounted: removing a folder with a volume mounted in it would
    /// reach into the volume. A folder this install never made (a cancel before the download began, or a name that was
    /// already taken) is nothing to remove, and nothing is said.
    func remove(using images: DiskImage = DiskImage()) async {
        guard made.withLock({ $0 }) else { return }
        while true {
            let tried = ejectTried.withLock { $0 }
            switch WorkFolderCleanup.next(ejectTried: tried, mounted: DiskImage.isMounted(mountPoint)) {
            case .eject:
                ejectTried.withLock { $0 = true }
                _ = await images.eject(mountPoint)
            case .remove:
                do {
                    try FileManager.default.removeItem(at: url)
                } catch {
                    Log.update.warning("The work folder couldn't be removed: \(error.localizedDescription)")
                }
                return
            case .keep:
                Log.update.warning("The work folder is kept: the disk image is still mounted in it")
                return
            }
        }
    }

    /// Clears out the work folders an earlier install left behind (it was cut short, or ended in a hand-off whose image
    /// was never ejected), once they are untouched for half a day: long enough that nobody is still using one. Only
    /// folders of the work folder's name in the temporary directory are looked at.
    static func sweepLeftovers(in parent: URL = FileManager.default.temporaryDirectory) async {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .isDirectoryKey]
        guard let entries = try? FileManager.default.contentsOfDirectory(at: parent, includingPropertiesForKeys: keys) else { return }
        let folders: [(name: String, modified: Date)] = entries.compactMap { entry in
            guard InstallNames.isWorkFolder(named: entry.lastPathComponent),
                  let values = try? entry.resourceValues(forKeys: Set(keys)), values.isDirectory == true,
                  let modified = values.contentModificationDate
            else { return nil }
            return (entry.lastPathComponent, modified)
        }
        let stale = InstallNames.staleWorkFolders(folders, now: Date())
        for name in stale {
            Log.update.info("Clearing out an old update work folder")
            let leftover = UpdateWorkFolder(existing: parent.appending(path: name, directoryHint: .isDirectory))
            await leftover.remove()
        }
    }

    /// Removes the staged copies a crash left beside the running app: hidden `.Mantel-update-X.Y.Z.app` folders, by
    /// exactly that name (`InstallNames.isStagedName`) and nothing else. They are our own half-made copies, so they are
    /// removed outright, not moved to the Trash. Run at launch, when no install of this process can be using one.
    static func sweepStagedCopies(besides app: URL) {
        let fileManager = FileManager.default
        let folder = app.deletingLastPathComponent()
        guard fileManager.isWritableFile(atPath: folder.path(percentEncoded: false)),
              let names = try? fileManager.contentsOfDirectory(atPath: folder.path(percentEncoded: false))
        else { return }
        for name in InstallNames.stagedCopies(in: names) {
            let copy = folder.appending(path: name, directoryHint: .isDirectory)
            // A real folder only: a link or a file with such a name isn't ours.
            guard let values = try? copy.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
                  values.isDirectory == true, values.isSymbolicLink != true
            else { continue }
            do {
                try fileManager.removeItem(at: copy)
                Log.update.info("Removed a staged copy an earlier update left beside the app")
            } catch {
                Log.update.warning("A staged copy beside the app couldn't be removed: \(error.localizedDescription)")
            }
        }
    }

    private init(existing url: URL) {
        self.url = url
        mountPoint = url.appending(path: "Mantel", directoryHint: .isDirectory)
        made = Mutex(true)
    }
}
