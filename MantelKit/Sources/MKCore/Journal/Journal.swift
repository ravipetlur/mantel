import Foundation

/// Why the journal wouldn't take an entry.
public enum JournalError: Error, Equatable, LocalizedError {
    /// A replay is restoring what an earlier run left, and a record made now couldn't be kept: the replay removes the entry
    /// of the key it is restoring as soon as it is done, and restores the original of a key it hasn't reached under whatever
    /// is using it. The caller must not make its change; it can try again when the replay has finished.
    case replayInProgress

    public var errorDescription: String? {
        "Mantel is still restoring changes left by an earlier run. Try again in a moment."
    }
}

/// The journal of changes Mantel makes to the system, so that a crash in the middle of one never leaves the person's menu
/// bar altered.
///
/// - **Write first.** `record` returns only when the entry is on disk; the change it protects is made after that.
/// - **First original wins.** An entry for a key that is already recorded is ignored, so the journal keeps the value from
///   before Mantel's first change, not the value some later change started from.
/// - **Replay** restores in the reverse order of recording and removes each entry that was restored. One that fails stays
///   in the journal, for the next launch, and is reported. While a replay runs, `record` throws
///   `JournalError.replayInProgress` for every key.
///
/// The file is `{ "records": [ … ] }`.
public actor Journal {
    private struct JournalFile: Codable {
        var records: [JournalRecord]
    }

    private let file: URL
    private let clock: any Clock
    private var stored: [JournalRecord]
    /// How many replays are running. `replay` waits for restorers, which lets other calls in; one of them must not be
    /// `record`.
    private var replaysRunning = 0

    /// Opens the journal in `file`, reading what an earlier run left in it. A file that can't be read is moved aside
    /// (`journal-corrupt-<timestamp>.json`, next to it) and the journal starts empty.
    public init(file: URL, clock: any Clock = SystemClock()) {
        self.file = file
        self.clock = clock
        self.stored = Self.read(file, clock: clock)
    }

    /// What is recorded, in the order it was recorded.
    public func records() -> [JournalRecord] {
        stored
    }

    /// Records `entry`, unless a record with its key exists. The record is on disk when this returns. If it can't be
    /// written, or a replay is running, this throws and nothing is recorded: the caller must not make the change the
    /// entry protects.
    public func record(_ entry: JournalEntry) throws {
        guard replaysRunning == 0 else { throw JournalError.replayInProgress }
        let key = Self.key(for: entry)
        guard !stored.contains(where: { $0.key == key }) else { return }
        let updated = stored + [JournalRecord(key: key, entry: entry, recordedAt: clock.now())]
        try persist(updated)
        stored = updated
    }

    /// Takes the record with `key` out of the journal, once the change it protects has been undone. A key that isn't
    /// recorded is ignored.
    public func remove(key: String) throws {
        guard let index = stored.firstIndex(where: { $0.key == key }) else { return }
        var updated = stored
        updated.remove(at: index)
        try persist(updated)
        stored = updated
    }

    /// Restores what is recorded, newest record first, and removes each record that was restored. A record that couldn't
    /// be restored stays, and is in the result.
    ///
    /// The journal is closed to `record` while this runs (it throws `JournalError.replayInProgress`), because a restorer
    /// takes time and the actor serves other calls meanwhile. A `record` for a key still to be restored would find the
    /// entry there and do nothing, and then the replay would undo the caller's change or drop its protection.
    public func replay(using restorer: any JournalRestoring) async -> [ReplayFailure] {
        replaysRunning += 1
        defer { replaysRunning -= 1 }
        var failures: [ReplayFailure] = []
        for record in stored.reversed() {
            do {
                try await restorer.restore(record.entry)
            } catch {
                Log.error("journal", "couldn't restore \(record.key): \(error.localizedDescription)")
                failures.append(ReplayFailure(key: record.key, message: error.localizedDescription))
                continue
            }
            do {
                try remove(key: record.key)
            } catch {
                // Put back, but still in the journal: the next launch restores it again, which does no harm.
                Log.error("journal", "restored \(record.key) but couldn't remove it from the journal: \(error.localizedDescription)")
                failures.append(ReplayFailure(key: record.key,
                                              message: "Restored, but the journal couldn't be updated: \(error.localizedDescription)"))
            }
        }
        return failures
    }

    /// The identity of what an entry changes: `plist:<filePath>#<key>` or `defaults:<domain>#<key>#<currentHost>`. It
    /// leaves out the original value and the write strategy, which are not part of what is changed.
    public static func key(for entry: JournalEntry) -> String {
        switch entry {
        case .plistKey(let filePath, let key, _, _):
            "plist:\(filePath)#\(key)"
        case .defaultsKey(let domain, let key, let currentHost, _):
            "defaults:\(domain)#\(key)#\(currentHost)"
        }
    }

    // MARK: Files

    /// Written whole to a temporary file in the same folder, synchronised to disk, then moved over the journal.
    private func persist(_ records: [JournalRecord]) throws {
        let data = try JSONCoding.encoder().encode(JournalFile(records: records))
        try AtomicFile.ensureFolder(file.deletingLastPathComponent())
        try AtomicFile.write(data, to: file, synchronize: true)
    }

    private static func read(_ file: URL, clock: any Clock) -> [JournalRecord] {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: file.path(percentEncoded: false)) else { return [] }
        do {
            let data = try Data(contentsOf: file)
            return try JSONCoding.decoder().decode(JournalFile.self, from: data).records
        } catch {
            let stem = file.deletingPathExtension().lastPathComponent
            let destination = AtomicFile.unusedURL(in: file.deletingLastPathComponent(),
                                                   base: "\(stem)-corrupt-\(AtomicFile.timestamp(for: clock.now()))",
                                                   pathExtension: "json")
            do {
                try fileManager.moveItem(at: file, to: destination)
                Log.error("journal", "the journal couldn't be read and was moved to \(destination.lastPathComponent); starting with an empty one")
            } catch {
                Log.error("journal", "the journal couldn't be read, and couldn't be moved aside either: \(error.localizedDescription)")
            }
            return []
        }
    }
}
