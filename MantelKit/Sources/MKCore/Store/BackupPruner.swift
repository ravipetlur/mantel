import Foundation

/// Keeps the Backups folder from growing for ever: of the copies of one thing, the oldest and the newest are kept.
public enum BackupPruner {
    /// Keeps the `keepOldest` oldest and the `keepNewest` newest of the files in `folder` named
    /// `<stem>-<yyyyMMdd-HHmmss>[-n].<pathExtension>`, and deletes the rest. "Oldest" and "newest" are by the time in the name,
    /// and for two files of the same second by their number (the first one has none). A file of any other name is left alone,
    /// also one that starts with the same stem (`<stem>-v1-…` is not a copy of `<stem>`).
    ///
    /// Every deletion is tried; if some failed, the first failure is thrown afterwards.
    public static func prune(in folder: URL, stem: String, pathExtension: String, keepOldest: Int, keepNewest: Int) throws {
        let fileManager = FileManager.default
        let names: [String]
        do {
            names = try fileManager.contentsOfDirectory(atPath: folder.path(percentEncoded: false))
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile {
            return
        }

        let copies = names.compactMap { name in
            copy(named: name, stem: stem, pathExtension: pathExtension).map { (name: name, order: $0) }
        }
        .sorted { ($0.order.timestamp, $0.order.number, $0.name) < ($1.order.timestamp, $1.order.number, $1.name) }

        let oldest = max(keepOldest, 0)
        let newest = max(keepNewest, 0)
        guard copies.count > oldest + newest else { return }

        var firstFailure: (any Error)?
        for copy in copies[oldest ..< (copies.count - newest)] {
            do {
                try fileManager.removeItem(at: folder.appending(path: copy.name, directoryHint: .notDirectory))
            } catch {
                firstFailure = firstFailure ?? error
            }
        }
        if let firstFailure { throw firstFailure }
    }

    /// The time and number in the name, when the name is `<stem>-<yyyyMMdd-HHmmss>[-n].<pathExtension>` exactly.
    private static func copy(named name: String, stem: String, pathExtension: String) -> (timestamp: String, number: Int)? {
        let prefix = "\(stem)-"
        let suffix = ".\(pathExtension)"
        guard name.hasPrefix(prefix), name.hasSuffix(suffix), name.count > prefix.count + suffix.count else { return nil }
        let middle = String(name.dropFirst(prefix.count).dropLast(suffix.count))
        guard let match = middle.wholeMatch(of: #/(\d{8}-\d{6})(?:-(\d+))?/#) else { return nil }
        return (String(match.1), match.2.flatMap { Int($0) } ?? 1)
    }
}
