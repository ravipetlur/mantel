import Foundation

/// Where Mantel keeps its files. The app uses `live()`; everything that owns a folder takes a `MantelPaths`, so tests
/// give it a temporary folder of their own and never touch the real ones.
public struct MantelPaths: Sendable, Equatable {
    /// Mantel's folder: `~/Library/Application Support/Mantel`, or a temporary folder in tests.
    public let root: URL
    /// The log folder: `~/Library/Logs/Mantel`, or a temporary folder in tests.
    public let logs: URL

    public init(root: URL, logs: URL) {
        self.root = root
        self.logs = logs
    }

    /// The real folders. Nothing is created: `createDirectories()` does that.
    public static func live() -> MantelPaths {
        MantelPaths(root: URL.applicationSupportDirectory.appending(path: "Mantel", directoryHint: .isDirectory),
                    logs: URL.libraryDirectory.appending(path: "Logs/Mantel", directoryHint: .isDirectory))
    }

    /// The settings files, `root` itself.
    public var settings: URL { root }
    /// Copies kept before a migration or an import, and files set aside as corrupt.
    public var backups: URL { root.appending(path: "Backups", directoryHint: .isDirectory) }
    /// The reports the probes write.
    public var probes: URL { root.appending(path: "Probes", directoryHint: .isDirectory) }
    /// The menu bar item images Mantel caches.
    public var itemImages: URL { root.appending(path: "ItemImages", directoryHint: .isDirectory) }
    /// The journal of changes Mantel makes to the system.
    public var journalFile: URL { root.appending(path: "journal.json", directoryHint: .notDirectory) }
    /// The Unix socket the command-line tool talks to.
    public var controlSocket: URL { root.appending(path: "control.sock", directoryHint: .notDirectory) }

    /// Makes the folders that don't exist yet and leaves each readable by the owner alone (0700), also one that was
    /// there already with looser permissions.
    public func createDirectories() throws {
        let fileManager = FileManager.default
        for folder in [root, logs, backups, probes, itemImages] {
            try fileManager.createDirectory(at: folder, withIntermediateDirectories: true,
                                            attributes: [.posixPermissions: 0o700])
            try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
        }
    }
}
