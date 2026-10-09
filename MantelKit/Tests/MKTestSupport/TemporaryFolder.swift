import Foundation

/// A folder of a test's own: made when it's created, deleted with everything in it when it's released. Hold it for as
/// long as the test uses the folder, as a test suite's stored property or through `withExtendedLifetime`. (A local that
/// is only read from once may be released straight after that read.)
public final class TemporaryFolder: Sendable {
    public let url: URL

    /// A folder named `<prefix>-<UUID>` in the system's temporary folder.
    public init(prefix: String = "mantel-test") {
        url = FileManager.default.temporaryDirectory
            .appending(path: "\(prefix)-\(UUID().uuidString)", directoryHint: .isDirectory)
        Self.make(url)
    }

    /// A folder whose path is short enough for a Unix socket: `sun_path` holds at most 103 bytes, which the system's
    /// temporary folder (under /var/folders) can exceed. The folder is `/tmp/mk-<8 random hex digits>`.
    public static func shortForSockets() -> TemporaryFolder {
        TemporaryFolder(url: URL(filePath: "/tmp/mk-\(String(format: "%08x", UInt32.random(in: .min ... .max)))",
                                 directoryHint: .isDirectory))
    }

    private init(url: URL) {
        self.url = url
        Self.make(url)
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }

    /// Makes the folder, readable by its owner alone. A test that can't get its folder can't run, so this stops the run
    /// with the reason rather than letting each test fail on a missing path.
    private static func make(_ url: URL) {
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
        } catch {
            fatalError("TemporaryFolder couldn't make \(url.path): \(error)")
        }
    }
}
