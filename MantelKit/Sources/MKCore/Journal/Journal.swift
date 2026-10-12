import Foundation

/// Why the journal wouldn't take an entry.
public enum JournalError: Error, Equatable, LocalizedError {
    /// A replay is restoring what an earlier run left, and a record made now couldn't be kept: the replay removes the entry
    /// of the key it is restoring as soon as it is done, and restores the original of a key it hasn't reached under whatever
    /// is using it. The caller must not make its change; it can try again when the replay has finished.
    case replayInProgress
    /// The journal file couldn't be read, and couldn't be set aside either. It is left exactly as it is, and Mantel changes
    /// nothing in the system until the person moves it away.
    case unreadable(path: String)

    public var errorDescription: String? {
        switch self {
        case .replayInProgress:
            "Mantel is still restoring changes left by an earlier run. Try again in a moment."
        case .unreadable(let path):
            "Mantel's journal at \(path) couldn't be read, so Mantel won't change system files. Move the file away and open Mantel again."
        }
    }
}

/// Puts back what an entry says was changed. Mantel's platform layer provides the real one; tests give the journal their own.
public protocol JournalRestoring: Sendable {
    func restore(_ entry: JournalEntry) async throws
    /// Whether the system still holds what Mantel last wrote for `entry`; nil when it can't tell. The journal asks this of an
    /// old record only, to see whether anyone has changed the setting since (a change that is not Mantel's is not put back
    /// over). The default can't tell.
    func stillHolds(_ written: WrittenValue, for entry: JournalEntry) async -> Bool?
}

extension JournalRestoring {
    public func stillHolds(_ written: WrittenValue, for entry: JournalEntry) async -> Bool? {
        nil
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
/// - **Old records are not put back over someone else's change.** A record older than `staleAge` that knows what Mantel last
///   wrote (`noteWritten`) is dropped, not restored, when the system no longer holds that.
/// - **A file that can't be trusted is never overwritten.** One that can't be read is moved aside (the journal then starts
///   empty); if it can't be moved either, the journal is unusable: it keeps the file as it is, and `record` and `replay`
///   say so.
///
/// The file is `{ "records": [ … ] }`.
public actor Journal {
    private struct JournalFile: Codable {
        var records: [JournalRecord]
    }

    private let file: URL
    private let clock: any Clock
    private var stored: [JournalRecord]
    /// False when the file couldn't be read or set aside: it is the only copy of what it holds, so nothing is ever written
    /// over it.
    private let usable: Bool
    /// How many replays are running. `replay` waits for restorers, which lets other calls in; one of them must not be
    /// `record`.
    private var replaysRunning = 0

    /// Opens the journal in `file`, reading what an earlier run left in it. A file that can't be read is moved aside
    /// (`journal-corrupt-<timestamp>.json`, next to it) and the journal starts empty. One that can't be moved aside either is
    /// left alone, and the journal is unusable (`isUsable`).
    public init(file: URL, clock: any Clock = SystemClock()) {
        self.file = file
        self.clock = clock
        let opened = Self.read(file, clock: clock)
        stored = opened.records
        usable = opened.usable
    }

    /// What is recorded, in the order it was recorded.
    public func records() -> [JournalRecord] {
        stored
    }

    /// False when the file couldn't be read or set aside. Mantel changes nothing in the system then.
    public var isUsable: Bool {
        usable
    }

    private var unreadable: JournalError {
        .unreadable(path: file.path(percentEncoded: false))
    }

    /// Records `entry`, unless a record with its key exists. The record is on disk when this returns. If it can't be
    /// written, or a replay is running, this throws and nothing is recorded: the caller must not make the change the
    /// entry protects.
    ///
    /// A record for a place inside a key (`.plistPath`) is not made when the whole key is recorded (`.plistKey`) already: the
    /// whole original covers it.
    ///
    /// `createdContainers` is how many containers on the way to a place the change is about to make (see
    /// `JournalRecord.createdContainers`); like the original, the first record's count stands.
    ///
    /// - Throws: `JournalError.unreadable` when the journal file couldn't be read, `JournalError.replayInProgress` while a
    ///   replay runs.
    public func record(_ entry: JournalEntry, createdContainers: Int = 0) throws {
        guard usable else { throw unreadable }
        guard replaysRunning == 0 else { throw JournalError.replayInProgress }
        let key = Self.key(for: entry)
        guard !stored.contains(where: { $0.key == key }) else { return }
        if case .plistPath(let filePath, let topLevelKey, _, _, _, _) = entry,
           stored.contains(where: { $0.key == Self.wholeKey(filePath: filePath, key: topLevelKey) }) {
            return
        }
        let updated = stored + [JournalRecord(key: key, entry: entry, recordedAt: clock.now(),
                                              createdContainers: createdContainers > 0 ? createdContainers : nil)]
        try persist(updated)
        stored = updated
    }

    /// Keeps what Mantel just wrote for the record with `key`, so that a replay long afterwards can tell whether the system
    /// still holds it. A key that isn't recorded is ignored (the whole key may be recorded instead, or the record may be gone
    /// already).
    public func noteWritten(_ value: WrittenValue, forKey key: String) throws {
        guard usable else { throw unreadable }
        guard let index = stored.firstIndex(where: { $0.key == key }), stored[index].lastWritten != value else { return }
        var updated = stored
        updated[index].lastWritten = value
        try persist(updated)
        stored = updated
    }

    /// Takes the record with `key` out of the journal, once the change it protects has been undone. A key that isn't
    /// recorded is ignored.
    public func remove(key: String) throws {
        guard usable else { throw unreadable }
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
    ///
    /// A record older than `staleAge` whose last written value is known, and that the system no longer holds
    /// (`JournalRestoring.stillHolds` says false), is removed without being restored: the setting was changed by someone else
    /// since, and putting the original back would undo their change. When the restorer can't tell, it is restored as usual.
    ///
    /// A replay that is cancelled (the cap gave up on it) goes no further: the records it hasn't reached aren't looked at, the
    /// system isn't read for them and the journal isn't written, and each is in the result as left for the next launch.
    ///
    /// A journal that couldn't be read (`isUsable` is false) restores nothing, and says why as its one failure.
    public func replay(using restorer: any JournalRestoring) async -> [ReplayFailure] {
        guard usable else {
            return [ReplayFailure(key: file.path(percentEncoded: false), message: unreadable.errorDescription ?? "")]
        }
        replaysRunning += 1
        defer { replaysRunning -= 1 }
        var failures: [ReplayFailure] = []
        let pending = Array(stored.reversed())
        for (index, record) in pending.enumerated() {
            if Task.isCancelled {
                Log.warning("journal", "the replay was cut short; \(pending.count - index) records stay for the next launch")
                failures += pending[index...].map {
                    ReplayFailure(key: $0.key, message: "The restore was cut short. This change stays in the journal for the next launch.")
                }
                break
            }
            if await isStaleAndChanged(record, restorer: restorer) {
                Log.info("journal", "dropped \(record.key): older than 7 days and changed since Mantel wrote it")
                do {
                    try remove(key: record.key)
                } catch {
                    Log.error("journal", "dropped \(record.key) but couldn't remove it from the journal: \(error.localizedDescription)")
                    failures.append(ReplayFailure(key: record.key,
                                                  message: "Not put back, but the journal couldn't be updated: \(error.localizedDescription)"))
                }
                continue
            }
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

    /// Whether the record is old enough to be doubted, knows what Mantel last wrote, and the system says it no longer holds
    /// that.
    private func isStaleAndChanged(_ record: JournalRecord, restorer: any JournalRestoring) async -> Bool {
        guard let written = record.lastWritten, clock.now().timeIntervalSince(record.recordedAt) > Self.staleSeconds else {
            return false
        }
        return await restorer.stillHolds(written, for: record.entry) == false
    }

    /// The identity of what an entry changes: `plist:<filePath>#<key>` or `defaults:<domain>#<key>#<currentHost>`, and for a
    /// place inside a plist key (`.plistPath`) the plist key's identity followed by one segment per step: `/k:<key>`,
    /// `/i:<position>`, `/m:<key>=<value>`, where `/`, `=` and `%` inside a name are percent-encoded. It leaves out the
    /// original value, the write strategy and the codec, which are not part of what is changed.
    public static func key(for entry: JournalEntry) -> String {
        switch entry {
        case .plistKey(let filePath, let key, _, _):
            wholeKey(filePath: filePath, key: key)
        case .plistPath(let filePath, let key, let path, _, _, _):
            wholeKey(filePath: filePath, key: key) + KeyPathText.text(for: path)
        case .defaultsKey(let domain, let key, let currentHost, _):
            "defaults:\(domain)#\(key)#\(currentHost)"
        }
    }

    private static func wholeKey(filePath: String, key: String) -> String {
        "plist:\(filePath)#\(key)"
    }

    // MARK: Files

    /// Written whole to a temporary file in the same folder, synchronised to disk, then moved over the journal.
    private func persist(_ records: [JournalRecord]) throws {
        let data = try JSONCoding.encoder().encode(JournalFile(records: records))
        try AtomicFile.ensureFolder(file.deletingLastPathComponent())
        try AtomicFile.write(data, to: file, synchronize: true)
    }

    private static func read(_ file: URL, clock: any Clock) -> (records: [JournalRecord], usable: Bool) {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: file.path(percentEncoded: false)) else { return ([], true) }
        do {
            let data = try Data(contentsOf: file)
            return (try JSONCoding.decoder().decode(JournalFile.self, from: data).records, true)
        } catch {
            let stem = file.deletingPathExtension().lastPathComponent
            let destination = AtomicFile.unusedURL(in: file.deletingLastPathComponent(),
                                                   base: "\(stem)-corrupt-\(AtomicFile.timestamp(for: clock.now()))",
                                                   pathExtension: "json")
            do {
                try fileManager.moveItem(at: file, to: destination)
                Log.error("journal", "the journal couldn't be read and was moved to \(destination.lastPathComponent); starting with an empty one")
                return ([], true)
            } catch {
                // It is the only copy of what it holds, and it may hold changes still to be put back: it stays as it is.
                Log.error("journal", "the journal couldn't be read, and couldn't be moved aside either (\(error.localizedDescription)); it is left alone and nothing is changed in the system")
                return ([], false)
            }
        }
    }
}

extension Journal {
    /// How old a record is before a replay doubts it: it is put back only if the system still holds what Mantel wrote.
    public static let staleAge: Duration = .seconds(7 * 24 * 60 * 60)

    fileprivate static var staleSeconds: TimeInterval {
        Double(staleAge.components.seconds)
    }
}
