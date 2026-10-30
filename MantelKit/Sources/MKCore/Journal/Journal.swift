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
    /// The change is one Mantel keeps (a record with the lifetime `.kept`: its own arrangement), and a temporary change (a platform
    /// test's) to the same place would put the original back over it. `key` is the journal's key for the place. Only a restore of what
    /// Mantel keeps puts it back.
    case keptByMantel(key: String)
    /// What Mantel keeps at this place is being put back (`restoreKept`), and a record for it made now couldn't be kept: the
    /// restore removes the record as soon as it is done. `key` is the journal's key for the place. The caller must not make its change;
    /// it can try again when the restore has finished.
    case restoreInProgress(key: String)
    /// A platform test's change to a whole key (a temporary record of the whole key) is still in the journal, and Mantel's own change
    /// to a place inside it (a `.kept` record) would be put back with it. `key` is the journal's key for the whole key. The
    /// test's change is put back first (Replay now).
    case leftoverWholeKey(key: String)

    public var errorDescription: String? {
        switch self {
        case .replayInProgress:
            "Mantel is still restoring changes left by an earlier run. Try again in a moment."
        case .unreadable(let path):
            "Mantel's journal at \(path) couldn't be read, so Mantel won't change system files. Move the file away and open Mantel again."
        case .keptByMantel(let key):
            key.hasPrefix("defaults:")
                ? "Mantel keeps its own icon spacing here. Use Restore original spacing first."
                : "Mantel keeps its own arrangement here. Use Restore original layout first."
        case .restoreInProgress:
            "Mantel is still putting back what it keeps. Try again in a moment."
        case .leftoverWholeKey(let key):
            "A platform test's change to \(Self.fileName(ofJournalKey: key)) hasn't been put back yet. Use Replay now in Settings › Diagnostics."
        }
    }

    /// The name of the file in a journal key (`plist:<file>#<key>…`): the file part is everything before the first `#`.
    static func fileName(ofJournalKey key: String) -> String {
        var path = key.hasPrefix("plist:") ? String(key.dropFirst("plist:".count)) : key
        if let hash = path.firstIndex(of: "#") { path = String(path[..<hash]) }
        return (path as NSString).lastPathComponent
    }
}

/// What one `Journal.recordWithReceipt` did, so that the caller can take back exactly that (`Journal.rollBack`) when the change the
/// record protects can't be made: never a record some other writer made, or one that was there already.
public struct JournalReceipt: Sendable, Equatable {
    public enum Change: Sendable, Equatable {
        /// The call made the record, which says it was recorded at this time.
        case added(recordedAt: Date)
        /// The call made an `.untilQuit` record `.kept`; the record says it was recorded at this time.
        case upgraded(recordedAt: Date)
        /// A record for the place was there already (or the whole key covers it): there is nothing to take back.
        case nothing
    }

    /// The journal's key for the place.
    public let key: String
    public let change: Change

    public init(key: String, change: Change) {
        self.key = key
        self.change = change
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
/// - **Lifetimes.** A record is `.untilQuit` (a temporary change: quitting, the next launch after a crash, Reset and Replay now put
///   it back) or `.kept` (Mantel's own arrangement: it stays across all of those, and only `restoreKept` puts it back, whatever
///   its age). `replay` restores `.untilQuit` records unless told otherwise. A `.kept` write to a place that has an `.untilQuit`
///   record makes that record `.kept` and keeps its original; an `.untilQuit` write to a place Mantel keeps is refused
///   (`JournalError.keptByMantel`). A whole key and the places inside it follow the same rule: a `.kept` place under a temporary
///   whole-key record (a platform test's leftover) is refused (`leftoverWholeKey`), and so is a temporary whole-key record over a key
///   that holds kept places (`keptByMantel`), because putting the whole key back would put them back too.
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
    /// The keys `restoreKept` is putting back now. `record` throws `JournalError.restoreInProgress` for these (and for the whole key
    /// of a place, or a place of a whole key, among them) and goes on for every other key.
    private var restoring: Set<String> = []

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

    /// The records Mantel keeps (`.kept`), in the order they were recorded.
    public func keptRecords() -> [JournalRecord] {
        stored.filter { $0.lifetime == .kept }
    }

    /// The records that quitting puts back (`.untilQuit`), in the order they were recorded. Whatever asks "is there anything to put
    /// back" asks this, never `records()`: a kept record is not waiting for anything.
    public func untilQuitRecords() -> [JournalRecord] {
        stored.filter { $0.lifetime == .untilQuit }
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
    /// `lifetime` is what the record is for (`JournalLifetime`). An existing `.untilQuit` record for the same key is made `.kept` by
    /// a `.kept` call, and keeps its original; a `.kept` record for the key refuses an `.untilQuit` call.
    ///
    /// - Throws: `JournalError.unreadable` when the journal file couldn't be read, `JournalError.replayInProgress` while a
    ///   replay runs, `JournalError.restoreInProgress` for a key `restoreKept` is putting back, `JournalError.keptByMantel` for an
    ///   `.untilQuit` record of a place Mantel keeps (or of a whole key that holds places Mantel keeps), and
    ///   `JournalError.leftoverWholeKey` for a `.kept` place under a temporary whole-key record.
    public func record(_ entry: JournalEntry, createdContainers: Int = 0, lifetime: JournalLifetime = .untilQuit) throws {
        _ = try recordWithReceipt(entry, createdContainers: createdContainers, lifetime: lifetime)
    }

    /// `record`, saying what it did, for a caller that has several records to make and a change after them: if one of them can't be
    /// made, it takes back what its own calls did with `rollBack`, and nothing a concurrent writer recorded.
    public func recordWithReceipt(_ entry: JournalEntry, createdContainers: Int = 0,
                                  lifetime: JournalLifetime = .untilQuit) throws -> JournalReceipt {
        guard usable else { throw unreadable }
        guard replaysRunning == 0 else { throw JournalError.replayInProgress }
        let key = Self.key(for: entry)
        guard !restoring.contains(where: { Self.overlap($0, key) }) else { throw JournalError.restoreInProgress(key: key) }

        if let index = stored.firstIndex(where: { $0.key == key }) {
            let existing = stored[index]
            switch (existing.lifetime, lifetime) {
            case (.kept, .untilQuit):
                throw JournalError.keptByMantel(key: key)
            case (.untilQuit, .kept):
                // The same rule as for a new place, below: a temporary whole-key record over the place would put it back with the key.
                if case .plistPath(let filePath, let topLevelKey, _, _, _, _) = entry,
                   let whole = stored.first(where: { $0.key == Self.wholeKey(filePath: filePath, key: topLevelKey) && $0.lifetime == .untilQuit }) {
                    throw JournalError.leftoverWholeKey(key: whole.key)
                }
                var updated = stored
                updated[index].lifetime = .kept
                try persist(updated)
                stored = updated
                return JournalReceipt(key: key, change: .upgraded(recordedAt: existing.recordedAt))
            default:
                return JournalReceipt(key: key, change: .nothing)
            }
        }
        if case .plistPath(let filePath, let topLevelKey, _, _, _, _) = entry,
           let whole = stored.first(where: { $0.key == Self.wholeKey(filePath: filePath, key: topLevelKey) }) {
            // The whole original covers the place. That is no protection for a place Mantel keeps when the whole key is a temporary
            // change's: putting the whole key back (quitting does) would put Mantel's arrangement back with it.
            switch (whole.lifetime, lifetime) {
            case (.kept, .untilQuit): throw JournalError.keptByMantel(key: whole.key)
            case (.untilQuit, .kept): throw JournalError.leftoverWholeKey(key: whole.key)
            default: return JournalReceipt(key: key, change: .nothing)
            }
        }
        // A temporary record of a whole key puts every place in it back, Mantel's own arrangement among them.
        if case .plistKey = entry, lifetime == .untilQuit,
           let kept = stored.first(where: { $0.lifetime == .kept && Self.isPlace(of: $0, under: key) }) {
            throw JournalError.keptByMantel(key: kept.key)
        }
        let record = JournalRecord(key: key, entry: entry, recordedAt: clock.now(),
                                   createdContainers: createdContainers > 0 ? createdContainers : nil, lifetime: lifetime)
        let updated = stored + [record]
        try persist(updated)
        stored = updated
        return JournalReceipt(key: key, change: .added(recordedAt: record.recordedAt))
    }

    /// Takes back what a call of `recordWithReceipt` did: the record it made is removed, or the record it made `.kept` is an
    /// `.untilQuit` one again. A record that is not the one the receipt names (the same key, another time: someone else recorded it
    /// after this one's was taken out) is left as it is, and so is a call that did nothing.
    public func rollBack(_ receipt: JournalReceipt) throws {
        guard usable else { throw unreadable }
        switch receipt.change {
        case .nothing:
            return
        case .added(let recordedAt):
            guard let index = stored.firstIndex(where: { $0.key == receipt.key && $0.recordedAt == recordedAt }) else { return }
            var updated = stored
            updated.remove(at: index)
            try persist(updated)
            stored = updated
        case .upgraded(let recordedAt):
            guard let index = stored.firstIndex(where: { $0.key == receipt.key && $0.recordedAt == recordedAt && $0.lifetime == .kept })
            else { return }
            var updated = stored
            updated[index].lifetime = .untilQuit
            try persist(updated)
            stored = updated
        }
    }

    /// Whether the record is for a place inside the whole key `wholeKey` (`Journal.key(for:)` of a `.plistKey`).
    private static func isPlace(of record: JournalRecord, under wholeKey: String) -> Bool {
        guard case .plistPath = record.entry else { return false }
        return record.key.hasPrefix(wholeKey + "/")
    }

    /// Whether two journal keys are the same place, or one is the whole key of a file's key and the other a place inside it.
    private static func overlap(_ first: String, _ second: String) -> Bool {
        first == second || first.hasPrefix(second + "/") || second.hasPrefix(first + "/")
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
    /// Only the records whose lifetime is in `lifetimes` are restored: by default `.untilQuit`, the temporary changes. The ones Mantel
    /// keeps stay where they are (`restoreKept` puts those back, when the person asks).
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
    public func replay(using restorer: any JournalRestoring, lifetimes: Set<JournalLifetime> = [.untilQuit]) async -> [ReplayFailure] {
        guard usable else {
            return [ReplayFailure(key: file.path(percentEncoded: false), message: unreadable.errorDescription ?? "")]
        }
        replaysRunning += 1
        defer { replaysRunning -= 1 }
        let pending = Array(stored.reversed().filter { lifetimes.contains($0.lifetime) })
        return await putBack(pending, using: restorer, doubtingOldRecords: true,
                             cutShort: "The restore was cut short. This change stays in the journal for the next launch.")
    }

    /// Puts back the records Mantel keeps (`.kept`) that `matching` selects, newest first, whatever their age (a restore that is asked
    /// for is never doubted for being old), and removes each one that was restored. One that couldn't be restored stays, and is in the
    /// result.
    ///
    /// Only the keys being restored are held: `record` throws `JournalError.restoreInProgress` for those until this is over, and goes
    /// on for every other key (the approvals engine, a platform test, the next kept write elsewhere). A record whose place is gone
    /// counts as restored, as in a replay; one that is cancelled goes no further, as in a replay.
    public func restoreKept(where matching: @Sendable (JournalRecord) -> Bool,
                            using restorer: any JournalRestoring) async -> [ReplayFailure] {
        guard usable else {
            return [ReplayFailure(key: file.path(percentEncoded: false), message: unreadable.errorDescription ?? "")]
        }
        // A key another restore is putting back is that restore's.
        let selected = Array(stored.reversed().filter { $0.lifetime == .kept && matching($0) && !restoring.contains($0.key) })
        guard !selected.isEmpty else { return [] }
        let keys = Set(selected.map(\.key))
        restoring.formUnion(keys)
        defer { restoring.subtract(keys) }
        return await putBack(selected, using: restorer, doubtingOldRecords: false,
                             cutShort: "The restore was cut short. This change stays in the journal.")
    }

    /// Restores `pending` in the order given, removing each record that was restored (see `replay`).
    private func putBack(_ pending: [JournalRecord], using restorer: any JournalRestoring, doubtingOldRecords: Bool,
                         cutShort: String) async -> [ReplayFailure] {
        var failures: [ReplayFailure] = []
        for (index, record) in pending.enumerated() {
            if Task.isCancelled {
                Log.warning("journal", "the restore was cut short; \(pending.count - index) records stay in the journal")
                failures += pending[index...].map { ReplayFailure(key: $0.key, message: cutShort) }
                break
            }
            if doubtingOldRecords, await isStaleAndChanged(record, restorer: restorer) {
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
                // Put back, but still in the journal: the next restore does it again, which does no harm.
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
    ///
    /// The file part of a `plist:` key isn't escaped: a path never holds `#` (Apple's two files' don't), so the first `#` ends it.
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
            let notes = JournalDecodingNotes()
            let decoder = JSONCoding.decoder()
            decoder.userInfo[.journalDecodingNotes] = notes
            let records = try decoder.decode(JournalFile.self, from: data).records
            let unknown = notes.unknownLifetimeCount
            if unknown > 0 {
                Log.warning("journal", unknown == 1
                    ? "1 journal record has a lifetime this version doesn't know; it is treated as one to put back on quit"
                    : "\(unknown) journal records have a lifetime this version doesn't know; they are treated as ones to put back on quit")
            }
            return (records, true)
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
