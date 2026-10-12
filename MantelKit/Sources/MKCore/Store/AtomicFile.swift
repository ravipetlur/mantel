import Foundation

/// The calls that make a written file durable, handed to `AtomicFile.write` so that a test can see which are made and in what
/// order.
package struct FileSyncing: Sendable {
    /// Gets the data written through `descriptor` onto the disk itself, not only into the drive's cache.
    package var syncFile: @Sendable (_ descriptor: Int32) throws -> Void
    /// Gets a change to the folder (the new name of a file) onto the disk.
    package var syncFolder: @Sendable (_ folder: URL) throws -> Void

    package init(syncFile: @escaping @Sendable (_ descriptor: Int32) throws -> Void,
                 syncFolder: @escaping @Sendable (_ folder: URL) throws -> Void) {
        self.syncFile = syncFile
        self.syncFolder = syncFolder
    }

    /// What the system does: `fcntl(F_FULLFSYNC)` for the file, which asks the drive to empty its cache too (a plain `fsync`
    /// doesn't on macOS), and `fsync` where a drive or a file system refuses that; `fsync` for the folder.
    package static let system = FileSyncing(
        syncFile: { descriptor in
            if fcntl(descriptor, F_FULLFSYNC) == 0 { return }
            guard fsync(descriptor) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        },
        syncFolder: { folder in
            let descriptor = open(folder.path(percentEncoded: false), O_RDONLY | O_DIRECTORY)
            guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            defer { close(descriptor) }
            // A file system that can't sync a folder has nothing to say about the file: it is not a failure to write.
            if fsync(descriptor) != 0, errno != EINVAL, errno != ENOTSUP {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        })
}

/// Writing a file so that a reader, or a crash, finds the old file or the new one whole and never half of one, and so that
/// nobody but the owner can read it (unless the file is macOS's: see `Ownership`).
package enum AtomicFile {
    /// Whose file it is, which decides what rewriting it does to the file's mode, owner and extended attributes.
    package enum Ownership: Sendable {
        /// Mantel's own: the new file is private to the owner (0600), whatever the old one had.
        case mantel
        /// macOS's, a preferences file Mantel changes one key of: the new file has the old one's mode, owner, group, extended
        /// attributes and ACL, as if the system had written it. (A file that isn't there yet is made as `mantel` would.)
        case system
    }

    /// Writes `data` to `url`: into a temporary file in the same folder (mode 0600 from the start, a name of its own so
    /// that two writes never share one), then moves that over `url`. With `synchronize`, the temporary file's data is on
    /// disk before it replaces the old one (`syncing.syncFile`: a full sync, which reaches the drive itself), so after a power
    /// loss the file is the old one or the new one, never an empty one; and the folder is synced after the move, so that the new
    /// name is on disk too (`syncing.syncFolder`). The journal asks for that; settings, which are rewritten from memory, don't.
    ///
    /// The temporary file is gone whatever happens: when the write fails at any step it is removed (an ACL it took from the old
    /// file that forbids deleting it is taken off first), and when it succeeds it has become `url`.
    package static func write(_ data: Data, to url: URL, synchronize: Bool = false, ownership: Ownership = .mantel,
                              syncing: FileSyncing = .system) throws {
        let fileManager = FileManager.default
        let path = url.path(percentEncoded: false)
        let temporary = url.deletingLastPathComponent()
            .appending(path: ".\(url.lastPathComponent).\(UUID().uuidString).tmp", directoryHint: .notDirectory)

        let descriptor = open(temporary.path(percentEncoded: false), O_WRONLY | O_CREAT | O_EXCL, 0o600)
        guard descriptor >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        // From here the temporary file exists, and it is removed unless it has become `url`.
        var replaced = false
        defer { if !replaced { discard(temporary) } }

        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        do {
            try handle.write(contentsOf: data)
            if ownership == .system { try copyModeAndOwner(ofFileAt: path, to: descriptor) }
            if synchronize { try syncing.syncFile(descriptor) }
            try handle.close()
        } catch {
            try? handle.close()
            throw error
        }

        if fileManager.fileExists(atPath: path) {
            switch ownership {
            case .mantel:
                // The new file's own metadata (mode 0600) replaces the old file's.
                _ = try fileManager.replaceItemAt(url, withItemAt: temporary, options: .usingNewMetadataOnly)
            case .system:
                // The old file's metadata (extended attributes, ACL, creation date) is kept: that is the default.
                _ = try fileManager.replaceItemAt(url, withItemAt: temporary, options: [])
            }
        } else {
            try fileManager.moveItem(at: temporary, to: url)
        }
        replaced = true
        if synchronize {
            // The file is in place. A folder that couldn't be synced is a weaker promise about a power loss, not a failed write:
            // throwing here would have the caller believe the old file is still there.
            do {
                try syncing.syncFolder(url.deletingLastPathComponent())
            } catch {
                Log.warning("files", "couldn't sync the folder of \(url.lastPathComponent); the file itself is written")
            }
        }
    }

    /// Gives the file `descriptor` is for the mode, owner and group of the file at `path`. A file that isn't there has nothing to
    /// copy. Throws when the owner or group can't be given (a file that is someone else's, which Mantel isn't to take over).
    private static func copyModeAndOwner(ofFileAt path: String, to descriptor: Int32) throws {
        var original = stat()
        guard stat(path, &original) == 0 else {
            if errno == ENOENT { return }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        var mine = stat()
        guard fstat(descriptor, &mine) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        guard fchmod(descriptor, original.st_mode & 0o7777) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        if original.st_uid != mine.st_uid || original.st_gid != mine.st_gid {
            guard fchown(descriptor, original.st_uid, original.st_gid) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EPERM)
            }
        }
    }

    /// Removes a temporary file that isn't wanted. A replace that failed part way may have given it the old file's ACL, which
    /// can forbid deleting it, so on a refusal the ACL and the flags are taken off, and it is tried once more.
    private static func discard(_ url: URL) {
        let path = url.path(percentEncoded: false)
        if unlink(path) == 0 || errno == ENOENT { return }
        if let empty = acl_init(0) {
            _ = acl_set_file(path, ACL_TYPE_EXTENDED, empty)
            acl_free(UnsafeMutableRawPointer(empty))
        }
        _ = chflags(path, 0)
        if unlink(path) != 0, errno != ENOENT {
            Log.warning("files", "a temporary file couldn't be removed: \(url.lastPathComponent) (error \(errno))")
        }
    }

    /// The folder, made private (0700) if it isn't there yet.
    package static func ensureFolder(_ folder: URL) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
    }

    /// A name for a file to keep in `folder`: `<base>.<pathExtension>`, or `<base>-2.<pathExtension>`, `-3`… when that is
    /// taken, so that two files kept in the same second don't collide.
    package static func unusedURL(in folder: URL, base: String, pathExtension: String) -> URL {
        let fileManager = FileManager.default
        var candidate = folder.appending(path: "\(base).\(pathExtension)", directoryHint: .notDirectory)
        var number = 2
        while fileManager.fileExists(atPath: candidate.path(percentEncoded: false)) {
            candidate = folder.appending(path: "\(base)-\(number).\(pathExtension)", directoryHint: .notDirectory)
            number += 1
        }
        return candidate
    }

    /// `yyyyMMdd-HHmmss` in the local time zone, for the names of files kept in the Backups folder.
    package static func timestamp(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: date)
    }
}
