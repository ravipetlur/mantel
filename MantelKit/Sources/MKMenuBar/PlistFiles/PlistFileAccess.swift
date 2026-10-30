import CoreFoundation
import Foundation
import MKCore
import Synchronization

/// Why a plist file couldn't be read or changed.
public enum PlistAccessError: Error, Equatable, LocalizedError {
    /// The file isn't a property list with a dictionary at the top.
    case notADictionary
    /// The file couldn't be read (it isn't there, or it isn't a property list); the text says why.
    case unreadable(String)
    /// The key holds something that isn't a property list type of Mantel's, so its value couldn't be put back; nothing is
    /// changed.
    case notRepresentable(key: String)
    /// The value was written, and the next read of it came back as something else.
    case notPersisted(key: String)
    /// `cfprefsd` and the file itself say different things about the key, so which one is the original is not known. Nothing
    /// is journaled or changed.
    case disagree(key: String)
    /// `cfprefsd` has no value for a key the file holds. (Reading a file in a group container through the preferences service
    /// can give this: the service may not be able to see it.) Nothing is journaled or changed.
    case serviceSeesNothing(key: String)
    /// The copy of the file that is made before its first change couldn't be made. Nothing is journaled or changed.
    case backupFailed(file: String, reason: String)
    /// A journal entry this restorer doesn't restore (a `defaults` key: `DefaultsJournalRestorer` puts those back).
    case unsupportedEntry
    /// The file is one of the two that macOS keeps for the menu bar, and macOS doesn't let apps replace those: they are only
    /// changed through the preferences service. `file` is the file's name.
    case atomicFileRefused(file: String)
    /// The value is kept in a form (named by the text) that this Mantel has no codec for, so a place inside it can't be read or
    /// put back.
    case codecMissing(String)
    /// A step of the path couldn't be taken.
    case path(KeyPathError)
    /// A temporary change (a write, or an undo of one) was asked for at a place Mantel keeps: its own arrangement,
    /// which only a restore puts back. `path` is the journal's key for the place. Nothing is changed.
    case keptByMantel(path: String)
    /// A change to the whole key, left in the journal by an earlier version's platform test, is still there (it is put back by Replay now), and a change Mantel keeps
    /// under it would be undone with it. `key` is the journal's key for the whole key. Nothing is changed.
    case leftoverWholeKey(key: String)
    /// Putting back what Mantel keeps (`restoreKept`) did not end with every place put back and its record taken out: this many are
    /// still recorded (the journal couldn't be updated, or the restore was cut short). What was put back stays put back.
    case restoreIncomplete(places: Int)

    public var errorDescription: String? {
        switch self {
        case .notADictionary: "The file isn't a property list with a dictionary in it."
        case .unreadable(let reason): "The file couldn't be read: \(reason)"
        // These say "this setting", never the key's name: the sentence reaches Diagnostics, and a key is for the log (which has it).
        case .notRepresentable: "A value in this setting can't be saved and put back, so Mantel left it alone."
        case .notPersisted: "macOS didn't keep the change to this setting."
        case .disagree: "macOS's preferences service and the file disagree about this setting, so nothing was changed."
        case .serviceSeesNothing:
            "macOS's preferences service reports no value for this setting, but the file has one, so nothing was changed."
        case .backupFailed(let file, let reason): "Mantel couldn't make a backup copy of \(file) first, so nothing was changed: \(reason)"
        case .unsupportedEntry: "Mantel can't put this kind of change back yet."
        case .atomicFileRefused(let file):
            "macOS doesn't let apps replace \(file), so Mantel only changes it through macOS's preferences service."
        case .codecMissing(let codec): "This setting is kept in a form Mantel doesn't know (\(codec)), so Mantel left it alone."
        case .path(let error): error.errorDescription
        case .keptByMantel: "Mantel keeps its own arrangement here. Use Restore original layout first."
        case .leftoverWholeKey(let key): JournalError.leftoverWholeKey(key: key).errorDescription
        case .restoreIncomplete(let places):
            "Mantel couldn't finish putting back what it keeps: \(places) \(places == 1 ? "change is" : "changes are") still recorded. Try again."
        }
    }
}

/// The two ways of reading and writing one top-level key of a plist file, with nothing about the journal or grants. It is
/// a struct of closures so that a test can give it a system that doesn't keep what it is told.
struct PlistIO: Sendable {
    /// The key's value now, read afresh: `nil` when there is none.
    var read: @Sendable (_ url: URL, _ key: String, _ strategy: PlistWriteStrategy) throws -> PlistValue?
    /// Sets the key to the value (or removes it, for `nil`). It doesn't check that the change took.
    var write: @Sendable (_ value: PlistValue?, _ key: String, _ url: URL, _ strategy: PlistWriteStrategy) throws -> Void

    static let system = PlistIO(
        read: { url, key, strategy in
            switch strategy {
            case .atomicFile: try readFile(url, key: key)
            case .cfPreferences: try readPreferences(url, key: key)
            }
        },
        write: { value, key, url, strategy in
            switch strategy {
            case .atomicFile: try writeFile(value, key: key, to: url)
            case .cfPreferences: try writePreferences(value, key: key, to: url)
            }
        })

    // MARK: The file itself

    /// The file's bytes, or nil when the file isn't there: the read failing with `ENOENT`, and nothing else. A file that is
    /// there and can't be read (no permission to it, or to the folder it is in) is `.unreadable`: taken for a file with no keys,
    /// it would be written over, or put back as if it had never held anything.
    static func readBytes(_ url: URL) throws -> Data? {
        let descriptor = open(url.path(percentEncoded: false), O_RDONLY)
        guard descriptor >= 0 else {
            if errno == ENOENT { return nil }
            throw PlistAccessError.unreadable(String(cString: strerror(errno)))
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        do {
            return try handle.readToEnd() ?? Data()
        } catch {
            throw PlistAccessError.unreadable(error.localizedDescription)
        }
    }

    private static func dictionary(from data: Data) throws -> [String: Any] {
        let object: Any
        do {
            object = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
        } catch {
            throw PlistAccessError.unreadable(error.localizedDescription)
        }
        guard let dictionary = object as? [String: Any] else { throw PlistAccessError.notADictionary }
        return dictionary
    }

    static func readFile(_ url: URL, key: String) throws -> PlistValue? {
        // A file that isn't there has no keys.
        guard let data = try readBytes(url) else { return nil }
        guard let raw = try dictionary(from: data)[key] else { return nil }
        guard let value = PlistValue(propertyList: raw) else { throw PlistAccessError.notRepresentable(key: key) }
        return value
    }

    /// Reads the file, sets the key, and writes the whole dictionary as a binary plist, atomically. The file is macOS's, not
    /// Mantel's: it keeps the mode, owner, extended attributes and ACL it had, which Mantel's own private files don't need to.
    static func writeFile(_ value: PlistValue?, key: String, to url: URL) throws {
        var dictionary = try readBytes(url).map(dictionary(from:)) ?? [:]
        if let value {
            dictionary[key] = value.propertyList
        } else {
            guard dictionary[key] != nil else { return }
            dictionary[key] = nil
        }
        let data = try PropertyListSerialization.data(fromPropertyList: dictionary, format: .binary, options: 0)
        try AtomicFile.write(data, to: url, synchronize: true, ownership: .system)
    }

    // MARK: CFPreferences

    /// The file's path is the preferences domain: `cfprefsd`, which caches domains, sees the change, which a write to the
    /// file behind its back wouldn't make it see.
    ///
    /// `nil` is for a key the service has no value for, which is not the same as one it can't give back as a `PlistValue`
    /// (that throws): a journal that kept the second as "absent" would delete the person's key when it restored.
    private static func readPreferences(_ url: URL, key: String) throws -> PlistValue? {
        let domain = url.path(percentEncoded: false) as CFString
        CFPreferencesSynchronize(domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        guard let raw = CFPreferencesCopyValue(key as CFString, domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost) else {
            return nil
        }
        guard let value = PlistValue(propertyList: raw) else { throw PlistAccessError.notRepresentable(key: key) }
        return value
    }

    private static func writePreferences(_ value: PlistValue?, key: String, to url: URL) throws {
        let domain = url.path(percentEncoded: false) as CFString
        CFPreferencesSetValue(key as CFString, value.map { $0.propertyList as CFPropertyList }, domain,
                              kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        guard CFPreferencesSynchronize(domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost) else {
            throw PlistAccessError.notPersisted(key: key)
        }
    }
}

/// Copies a file whole into the Backups folder, once per file for as long as the process lives. After a copy, the folder keeps
/// of the copies of that file the first one ever made, which is the person's original, and the four newest.
///
/// Copies of `PlistFileAccess` share one ledger, and the app makes one `PlistFileAccess`, so "once" is once per run. A copy that
/// couldn't be made isn't counted, so the next write tries again.
final class BackupLedger: Sendable {
    private let done = Mutex<Set<String>>([])

    /// Copies `file`'s bytes to `<folder>/<name without .plist>-<yyyyMMdd-HHmmss>Z.plist`, the time in UTC (`BackupPruner.stamp(for:)`)
    /// (privately, and whole or not at all),
    /// unless a copy of `identity` was made already. A file that isn't there has nothing to copy, and counts as copied.
    func backUpOnce(_ file: URL, identity: String, into folder: URL, at date: Date) throws {
        try done.withLock { done in
            guard !done.contains(identity) else { return }
            if FileManager.default.fileExists(atPath: file.path(percentEncoded: false)) {
                do {
                    let bytes = try Data(contentsOf: file)
                    try AtomicFile.ensureFolder(folder)
                    let name = file.pathExtension == "plist" ? file.deletingPathExtension().lastPathComponent : file.lastPathComponent
                    let destination = AtomicFile.unusedURL(in: folder, base: "\(name)-\(BackupPruner.stamp(for: date))",
                                                           pathExtension: "plist")
                    try AtomicFile.write(bytes, to: destination, synchronize: true)
                    prune(copiesOf: name, in: folder)
                } catch {
                    throw PlistAccessError.backupFailed(file: file.lastPathComponent, reason: error.localizedDescription)
                }
            }
            done.insert(identity)
        }
    }
}

/// What Mantel last wrote at each place inside a key (by `Journal.key(for:)`), for as long as the process lives.
///
/// The preferences service takes a while to give a write to the file, and an undo takes the place's journal record away, with its note
/// of what was written there. The next write to the place finds the service and the file in disagreement all the same, and this is
/// what tells that the service's value is Mantel's own (the undo's), which the file hasn't caught up with, and not someone else's.
/// Copies of `PlistFileAccess` share one ledger, as they share the backup ledger.
final class WrittenLedger: Sendable {
    private let written = Mutex<[String: WrittenValue]>([:])

    func note(_ value: WrittenValue, forKey key: String) {
        written.withLock { $0[key] = value }
    }

    func last(forKey key: String) -> WrittenValue? {
        written.withLock { $0[key] }
    }
}

extension BackupLedger {
    /// Clears out the old copies. The copy just made is in place, so a failure here is only logged: it must not refuse the write
    /// the copy was made for.
    fileprivate func prune(copiesOf name: String, in folder: URL) {
        do {
            try BackupPruner.prune(in: folder, stem: name, pathExtension: "plist", keepOldest: 1, keepNewest: 4)
        } catch {
            Log.warning("plist", "old backup copies of \(name) couldn't be cleared out: \(error.localizedDescription)")
        }
    }
}

/// How much of the check that `cfprefsd` and the file agree about a place (`PlistFileAccess.write(_ edits:…)`, step 3) a write makes.
public enum OriginalCheck: Sendable, Equatable {
    /// Every place of the write.
    case everyPath
    /// Only the places that have no record in the journal yet: a recorded place has its original already.
    case newPathsOnly
}

/// Reads and changes top-level keys of plist files (the approvals file, the layout file), and places inside them, with the
/// journal behind every change, so that a crash in the middle of one never leaves the person's menu bar altered.
///
/// - **`write(_ value:…)`** first checks that the value it would keep as the original is the true one, then copies the file whole to the
///   Backups folder (the first write to it in this run), then records the original in the journal (first original wins),
///   writes, reads the value afresh and compares. The journal comes before the change: if the journal can't record, because
///   it can't be written or because a replay is running (`JournalError.replayInProgress`), nothing is written. Anything that
///   makes the original doubtful, or the backup impossible, refuses the write before the journal is touched.
/// - **`write(_ edits:…)`** changes places inside one top-level key, in the same order of steps, and puts back only those places
///   (`undo(path:…)`, or the replay): what the person or macOS changed elsewhere in the key meanwhile is left alone. Before
///   anything else it checks, for each place, that `cfprefsd` (the source of truth) and the file say the same; if they don't, it
///   waits for them to (up to two seconds), and goes on only if what `cfprefsd` holds is what Mantel itself wrote last, which
///   the file hasn't caught up with yet.
/// - **Symlinks are resolved** before anything is written, with `CanonicalPath` (the journal's keys use the same form). An atomic
///   replace onto a link would replace the link with a regular file.
/// - **Lifetimes.** `write(_ edits:…)` journals its places `.untilQuit` (put back on quit) or `.kept` (Mantel's own
///   arrangement, put back only by `restoreKept`). A `.kept` write to a place that has an `.untilQuit` record makes it `.kept`, with its
///   original; one under a whole-key record an earlier version's platform test left is refused (`leftoverWholeKey`); an `.untilQuit` write or `undo` at a
///   place Mantel keeps is refused (`keptByMantel`).
/// - **`.atomicFile` is refused for the two files macOS keeps for the menu bar**: macOS doesn't let apps replace them. It stays
///   for any other file, and for putting back what an earlier version recorded.
/// - **A file that has a grant** (see `FileGrantStore`) is opened through it, for exactly as long as the reading or the
///   writing takes.
public struct PlistFileAccess: Sendable {
    private let journal: Journal
    private let grants: FileGrantStore?
    private let backups: URL
    private let clock: any Clock
    private let io: PlistIO
    private let codecs: [PlistBlobCodecID: any PlistBlobCodec]
    private let backedUp = BackupLedger()
    private let lastWritten = WrittenLedger()

    /// How often, and how many times, `cfprefsd` and the file are looked at again while they disagree: 100 ms, for 2 s.
    static let agreementInterval: Duration = .milliseconds(100)
    static let agreementPolls = 20

    /// - Parameters:
    ///   - paths: where Mantel keeps its files; the copies made before a file's first change go to `paths.backups`.
    ///   - grants: a file one of them is for is opened through it.
    ///   - codecs: how to follow a path into a value kept as a blob, by the ID an entry names.
    public init(journal: Journal, paths: MantelPaths, grants: FileGrantStore? = nil,
                codecs: [PlistBlobCodecID: any PlistBlobCodec] = [:]) {
        self.init(journal: journal, paths: paths, grants: grants, codecs: codecs, io: .system)
    }

    init(journal: Journal, paths: MantelPaths, grants: FileGrantStore? = nil, codecs: [PlistBlobCodecID: any PlistBlobCodec] = [:],
         io: PlistIO, clock: any Clock = SystemClock()) {
        self.journal = journal
        self.grants = grants
        backups = paths.backups
        self.clock = clock
        self.io = io
        self.codecs = codecs
    }

    /// The value at `path` inside the top-level `key`, as the preferences service (`cfprefsd`, the source of truth) holds it
    /// now; nil when it isn't there. A `codec` other than `.none` is how the value of `key` is read for the path to be followed.
    public func value(at path: PlistKeyPath, key: String, in url: URL, codec: PlistBlobCodecID = .none) async throws -> PlistValue? {
        let target = URL(filePath: CanonicalPath.of(url))
        let blobCodec = try blobCodec(for: codec)
        let top = try await withFile(target) { [io] file in try io.read(file, key, .cfPreferences) }
        return try Self.value(at: path, in: top, codec: blobCodec, key: key)
    }

    // MARK: Writing a whole key

    /// Journals the key's current value (first original wins), writes, re-reads, and checks the value on disk.
    ///
    /// Before anything is journaled or changed, inside the same grant: the original is checked (`originalValue`), and the file
    /// is copied whole into the Backups folder if this is the first write to it in this run.
    ///
    /// - Throws: `PlistAccessError.disagree`, `.serviceSeesNothing` or `.notRepresentable` when the original is doubtful, and
    ///   `.backupFailed` when the copy can't be made: nothing is journaled, written or backed up in the first case, and
    ///   nothing is journaled or written in the second. `PlistAccessError.atomicFileRefused` for `.atomicFile` on one of
    ///   macOS's two files. `PlistAccessError.keptByMantel` when the key holds places Mantel keeps (nothing is changed). `JournalError.replayInProgress` while a replay runs, and nothing is written.
    ///   `PlistAccessError.notPersisted` when the value that was read back isn't the one written (the journal keeps the
    ///   original, for the restore).
    public func write(_ value: PlistValue?, key: String, in url: URL, strategy: PlistWriteStrategy) async throws {
        let identity = CanonicalPath.of(url)
        let target = URL(filePath: identity)
        try await refuseAtomicReplacement(of: target, strategy: strategy)
        // The whole key includes the places Mantel keeps: they are not a temporary change's to put back or to write over.
        try await refuseIfKept(key: key, inFile: identity)
        let original = try await withFile(target) { [io, backups, ledger = backedUp, now = clock.now()] file in
            let original = try Self.originalValue(of: key, in: file, strategy: strategy, io: io)
            try ledger.backUpOnce(file, identity: identity, into: backups, at: now)
            return original
        }
        do {
            try await journal.record(.plistKey(filePath: identity, key: key, original: original, strategy: strategy))
        } catch {
            throw Self.translating(error)
        }
        try await apply(value, key: key, to: target, strategy: strategy, grants: grants)
    }

    /// The value the journal keeps as the key's original: the strategy's own view of it, checked.
    ///
    /// The restore puts back exactly what is kept here, and "no value" means the key is removed. So a view that can be wrong
    /// can't be kept: for `cfPreferences`, which reads through `cfprefsd` (it says nothing for a key it can't see, and nothing
    /// for one it can't represent), the file's own bytes are read as well, and the two have to be the same. `atomicFile`'s view
    /// is the file's bytes already.
    private static func originalValue(of key: String, in file: URL, strategy: PlistWriteStrategy, io: PlistIO) throws -> PlistValue? {
        let seen = try io.read(file, key, strategy)
        guard strategy == .cfPreferences else { return seen }
        let onDisk = try PlistIO.readFile(file, key: key)
        guard seen == onDisk else {
            throw seen == nil ? PlistAccessError.serviceSeesNothing(key: key) : PlistAccessError.disagree(key: key)
        }
        return seen
    }

    // MARK: Writing places inside a key

    /// Changes places inside the top-level `key`, journaling the original of each (first original wins per place), writing the
    /// key once, and reading it back through the strategy to check that every place holds what it was given.
    ///
    /// `lifetime` says what the journal's records are for: `.untilQuit` (the default: put back on quit) or `.kept` (Mantel's own
    /// arrangement: put back only by `restoreKept`). See the type's note on lifetimes for what each refuses. `originalCheck` is how much
    /// of step 3 is done: `.everyPath` (the default) for every place, `.newPathsOnly` for the places that have no record yet. A place
    /// that is recorded has its original already; the preferences service flushes lazily after each re-sort of the menu bar, and waiting
    /// for it would only delay a writer that writes the same places again and again.
    ///
    /// In this order, and the first step that fails stops the rest:
    /// 1. `.atomicFile` on one of macOS's two files is refused (`atomicFileRefused`); so is a write the lifetimes forbid
    ///    (`keptByMantel`, `leftoverWholeKey`).
    /// 2. The key is read through the strategy (for `cfPreferences`, `cfprefsd`, the source of truth), and decoded through the
    ///    codec when there is one.
    /// 3. For each place, `cfprefsd` and the file must say the same. If they don't, they are looked at again every 100 ms, up
    ///    to 2 s (reading through `cfprefsd` synchronizes it with the file), and if they still don't, the write goes on only when
    ///    what `cfprefsd` holds is what Mantel last wrote there (a write or an undo of this run, or what an earlier run noted in the
    ///    record), which the file hasn't caught up with; otherwise `disagree`, with nothing backed up or journaled.
    /// 4. The file is copied into Backups, once per run (and old copies cleared out).
    /// 5. The original of each place is journaled. If one of the records can't be made, the ones this call made are taken out again
    ///    (and a record it made `.kept` is `.untilQuit` again), and no other writer's record is touched.
    /// 6. The edits are applied to the key as it is now, and it is written once.
    /// 7. It is read back, and each place must hold its new value (`notPersisted`).
    /// 8. What was written is noted in the journal, for each place.
    ///
    /// An edit that can't be applied (`PlistAccessError.path`, `.codecMissing`) is found before step 4; a path that has a `matchingPath`
    /// inside the way of another is refused before step 1 (`KeyPathError.nestedMatchingPath`).
    public func write(_ edits: [PathEdit], key: String, in url: URL, strategy: PlistWriteStrategy = .cfPreferences,
                      codec codecID: PlistBlobCodecID = .none, lifetime: JournalLifetime = .untilQuit,
                      originalCheck: OriginalCheck = .everyPath) async throws {
        guard !edits.isEmpty else { return }
        guard edits.allSatisfy({ !$0.path.isEmpty }) else { throw PlistAccessError.path(.noMatch(step: 0)) }
        // A step that finds an entry inside the way another one reads has no text for the journal to be keyed by: refused here, before
        // the first record of the call is made.
        for edit in edits {
            if let step = edit.path.nestedMatchingPathStep { throw PlistAccessError.path(.nestedMatchingPath(step: step)) }
        }
        let identity = CanonicalPath.of(url)
        let target = URL(filePath: identity)
        try await refuseAtomicReplacement(of: target, strategy: strategy)
        let blobCodec = try blobCodec(for: codecID)
        let recorded = try await checkLifetimes(of: edits, key: key, identity: identity, strategy: strategy, codecID: codecID,
                                                lifetime: lifetime)

        // The places whose agreement is waited for: all of them, or those that have no original in the journal yet.
        let checked = originalCheck == .everyPath ? edits : edits.filter { !recorded.contains(Self.journalKey(of: $0, key: key, identity: identity,
                                                                                                           strategy: strategy, codecID: codecID)) }
        let seen = try await agreedTopLevel(key: key, edits: checked, in: target, strategy: strategy, identity: identity,
                                            codecID: codecID, blobCodec: blobCodec)
        // Whether the edits can be applied at all, before anything is backed up or journaled: a record for a change that can't be
        // made would only ever fail to be put back.
        _ = try Self.applying(edits, to: seen, codec: blobCodec, key: key)

        try await withFile(target) { [backups, ledger = backedUp, now = clock.now()] file in
            try ledger.backUpOnce(file, identity: identity, into: backups, at: now)
        }

        let planned = try edits.map { edit -> (entry: JournalEntry, created: Int) in
            let original = try Self.value(at: edit.path, in: seen, codec: blobCodec, key: key)
            let entry = JournalEntry.plistPath(filePath: identity, key: key, path: edit.path, original: original, strategy: strategy,
                                               codec: codecID)
            return (entry, try Self.createdContainers(by: edit, original: original, in: seen, codec: blobCodec, key: key))
        }
        let entries = planned.map(\.entry)
        try await record(planned, lifetime: lifetime)
        try await apply(edits, key: key, to: target, strategy: strategy, codec: blobCodec, grants: grants)

        for (edit, entry) in zip(edits, entries) {
            let written = edit.value.map(WrittenValue.value) ?? .removed
            lastWritten.note(written, forKey: Journal.key(for: entry))
            do {
                try await journal.noteWritten(written, forKey: Journal.key(for: entry))
            } catch {
                // The change is made and journaled; only the note that lets an old record be told from a changed one is missing.
                Log.warning("plist", "what was written for \(Journal.key(for: entry)) couldn't be noted: \(error.localizedDescription)")
            }
        }
    }

    /// The top-level value as the strategy holds it, once `cfprefsd` and the file agree about every place in `edits` (see
    /// `write(_ edits:…)`, step 3).
    private func agreedTopLevel(key: String, edits: [PathEdit], in target: URL, strategy: PlistWriteStrategy, identity: String,
                                codecID: PlistBlobCodecID, blobCodec: (any PlistBlobCodec)?) async throws -> PlistValue? {
        var views = try await topLevel(of: key, in: target, strategy: strategy)
        // The file's own bytes can't disagree with the strategy that reads them.
        guard strategy == .cfPreferences else { return views.seen }

        var disagreeing = try Self.disagreements(among: edits, views: views, codec: blobCodec, key: key)
        var polls = 0
        while !disagreeing.isEmpty, polls < Self.agreementPolls {
            try await clock.sleep(for: Self.agreementInterval)
            polls += 1
            views = try await topLevel(of: key, in: target, strategy: strategy)
            disagreeing = try Self.disagreements(among: edits, views: views, codec: blobCodec, key: key)
        }

        // Still different. That is no disagreement if `cfprefsd` holds what Mantel wrote there last: its own write, not yet
        // written to the file. Anything else makes the original doubtful.
        let records = await journal.records()
        for edit in disagreeing {
            let entry = JournalEntry.plistPath(filePath: identity, key: key, path: edit.path, original: nil, strategy: strategy,
                                               codec: codecID)
            let journalKey = Journal.key(for: entry)
            // This process's own last write at the place first (an undo has taken its record away), then what an earlier run noted.
            guard let written = lastWritten.last(forKey: journalKey) ?? records.first(where: { $0.key == journalKey })?.lastWritten,
                  Self.matches(written, try Self.value(at: edit.path, in: views.seen, codec: blobCodec, key: key))
            else {
                throw PlistAccessError.disagree(key: key)
            }
        }
        return views.seen
    }

    /// The key's value as the strategy sees it, and as the file's bytes say it (the same thing for `atomicFile`).
    private func topLevel(of key: String, in target: URL, strategy: PlistWriteStrategy) async throws -> (seen: PlistValue?, disk: PlistValue?) {
        try await withFile(target) { [io] file in
            let seen = try io.read(file, key, strategy)
            let disk = strategy == .cfPreferences ? try PlistIO.readFile(file, key: key) : seen
            return (seen, disk)
        }
    }

    /// The edits whose place holds something else in the file than `cfprefsd` says.
    private static func disagreements(among edits: [PathEdit], views: (seen: PlistValue?, disk: PlistValue?),
                                      codec: (any PlistBlobCodec)?, key: String) throws -> [PathEdit] {
        try edits.filter { edit in
            try value(at: edit.path, in: views.seen, codec: codec, key: key) != value(at: edit.path, in: views.disk, codec: codec, key: key)
        }
    }

    /// Whether what a place holds now is what was written there (`nil` is what a removal leaves).
    private static func matches(_ written: WrittenValue, _ current: PlistValue?) -> Bool {
        switch written {
        case .value(let value): current == value
        case .removed: current == nil
        }
    }

    /// Records each entry, with the containers its change will make. If one can't be recorded, what the calls so far did is taken out
    /// again, newest first: the records they made, and the records they made `.kept`: a change that is not going to be made has
    /// nothing to put back. A record that was there already, or that a concurrent writer made meanwhile, is never touched.
    private func record(_ planned: [(entry: JournalEntry, created: Int)], lifetime: JournalLifetime) async throws {
        var receipts: [JournalReceipt] = []
        do {
            for (entry, created) in planned {
                receipts.append(try await journal.recordWithReceipt(entry, createdContainers: created, lifetime: lifetime))
            }
        } catch {
            for receipt in receipts.reversed() { try? await journal.rollBack(receipt) }
            throw Self.translating(error)
        }
    }

    /// The journal's refusals as the errors of this type, so that whoever is told sees one error whatever the timing: the early check
    /// that comes before the backup, or the journal itself when it records (it is the authority, and a record may be refused after the
    /// check). Any other error is as it was.
    static func translating(_ error: any Error) -> any Error {
        switch error as? JournalError {
        case .keptByMantel(let key)?: PlistAccessError.keptByMantel(path: key)
        case .leftoverWholeKey(let key)?: PlistAccessError.leftoverWholeKey(key: key)
        default: error
        }
    }

    /// Refuses a temporary change to a whole key that holds places Mantel keeps (or that is Mantel's own): `keptByMantel`.
    private func refuseIfKept(key: String, inFile identity: String) async throws {
        let wholeKey = Journal.key(for: .plistKey(filePath: identity, key: key, original: nil, strategy: .cfPreferences))
        let kept = await journal.keptRecords().first { $0.key == wholeKey || Self.isPlace(of: $0, inFile: identity, key: key) }
        if let kept { throw PlistAccessError.keptByMantel(path: kept.key) }
    }

    /// The journal's keys of the places already recorded for `key` (the places of `edits`, and every one when the whole key is
    /// recorded), after refusing what the lifetimes forbid:
    /// - `.untilQuit`: a place that Mantel keeps (its own record is `.kept`, or the whole key's is) is `keptByMantel`.
    /// - `.kept`: a whole-key record that is a temporary change's (`.untilQuit`) is an earlier version's platform test's leftover, which would put the
    ///   place back over Mantel's arrangement: `leftoverWholeKey`.
    private func checkLifetimes(of edits: [PathEdit], key: String, identity: String, strategy: PlistWriteStrategy,
                                codecID: PlistBlobCodecID, lifetime: JournalLifetime) async throws -> Set<String> {
        let records = await journal.records()
        let wholeKey = Journal.key(for: .plistKey(filePath: identity, key: key, original: nil, strategy: strategy))
        let whole = records.first { $0.key == wholeKey }
        switch lifetime {
        case .untilQuit:
            if let whole, whole.lifetime == .kept { throw PlistAccessError.keptByMantel(path: whole.key) }
        case .kept:
            if let whole, whole.lifetime == .untilQuit { throw PlistAccessError.leftoverWholeKey(key: whole.key) }
        }
        let byKey = Dictionary(records.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })
        var recorded: Set<String> = []
        for edit in edits {
            let placeKey = Self.journalKey(of: edit, key: key, identity: identity, strategy: strategy, codecID: codecID)
            guard let record = byKey[placeKey] else {
                if whole != nil { recorded.insert(placeKey) }
                continue
            }
            if lifetime == .untilQuit, record.lifetime == .kept { throw PlistAccessError.keptByMantel(path: placeKey) }
            recorded.insert(placeKey)
        }
        return recorded
    }

    private static func journalKey(of edit: PathEdit, key: String, identity: String, strategy: PlistWriteStrategy,
                                   codecID: PlistBlobCodecID) -> String {
        Journal.key(for: .plistPath(filePath: identity, key: key, path: edit.path, original: nil, strategy: strategy, codec: codecID))
    }

    // MARK: Putting back

    /// Puts the key back as the journal says it was, with the strategy it was changed with, and takes its record out of the
    /// journal. A key that isn't recorded is left alone.
    ///
    /// - Throws: `PlistAccessError.keptByMantel` when the record is one Mantel keeps: only `restoreKept` puts that back.
    public func undo(key: String, in url: URL) async throws {
        let path = CanonicalPath.of(url)
        // The whole key includes the places Mantel keeps, which putting it back would put back too.
        try await refuseIfKept(key: key, inFile: path)
        let probe = JournalEntry.plistKey(filePath: path, key: key, original: nil, strategy: .atomicFile)
        let journalKey = Journal.key(for: probe)
        guard let record = await journal.records().first(where: { $0.key == journalKey }) else { return }
        guard record.lifetime == .untilQuit else { throw PlistAccessError.keptByMantel(path: journalKey) }
        try await restore(record.entry, grants: grants)
        try await journal.remove(key: journalKey)
    }

    /// Puts one place inside a key back as the journal says it was (an inverse edit on the key as it is now: nothing else in the
    /// key is touched), and takes its record out of the journal. A place that isn't recorded is left alone.
    ///
    /// - Throws: `PlistAccessError.keptByMantel` when the record is one Mantel keeps: only `restoreKept` puts that back.
    public func undo(path: PlistKeyPath, key: String, in url: URL) async throws {
        let file = CanonicalPath.of(url)
        let probe = JournalEntry.plistPath(filePath: file, key: key, path: path, original: nil, strategy: .cfPreferences, codec: .none)
        let journalKey = Journal.key(for: probe)
        guard let record = await journal.records().first(where: { $0.key == journalKey }) else { return }
        guard record.lifetime == .untilQuit else { throw PlistAccessError.keptByMantel(path: journalKey) }
        try await restore(record.entry, grants: grants)
        try await journal.remove(key: journalKey)
    }

    /// Puts back every place Mantel keeps (`.kept` records) under the top-level `key` of the file, in one write, and takes their records
    /// out of the journal. Returns how many places were put back.
    ///
    /// The key is read afresh through the preferences service (`cfprefsd`, the source of truth), each place is set to its original (or
    /// removed, where it held nothing, and the containers the change made around it that are empty now with it), the key is written
    /// once, and read back: a record goes only when its place holds what it was given. What the person or macOS changed elsewhere in
    /// the key meanwhile is left alone, as in `undo(path:key:in:)`. The age of a record doesn't matter: a restore that is asked for
    /// is never doubted.
    ///
    /// While it runs, the journal refuses records for these places (`JournalError.restoreInProgress`) and takes every other one. A
    /// place whose entry is gone counts as put back.
    ///
    /// - Throws: the first error of a place that couldn't be put back (it stays recorded, and the others were put back), or of the
    ///   write as a whole (nothing was put back); `PlistAccessError.restoreIncomplete` when places are still recorded at the end (the
    ///   journal couldn't be updated, or the restore was cut short); `JournalError.unreadable` for a journal that couldn't be read;
    ///   `CancellationError` when the restore was cut short. A second restore of the same key while one runs puts back nothing and
    ///   answers 0, though records exist: callers that can overlap serialize them (`LayoutApplier` does).
    public func restoreKept(key: String, in url: URL) async throws -> Int {
        try await restoreKept(key: key, in: url, afterSelecting: nil)
    }

    /// `restoreKept(key:in:)`, with something to do between reading the places that are kept and handing them to the journal: where a
    /// place recorded in that moment is found, for a test. (The journal puts back what it holds when it starts, and that place is put
    /// back by itself, as a replay would.)
    func restoreKept(key: String, in url: URL, afterSelecting hook: (@Sendable () async -> Void)?) async throws -> Int {
        let identity = CanonicalPath.of(url)
        let selects: @Sendable (JournalRecord) -> Bool = { Self.isPlace(of: $0, inFile: identity, key: key) }
        let planned = await journal.keptRecords().filter(selects)
        guard !planned.isEmpty else { return 0 }
        await hook?()

        let batch = KeptPlaces(access: self, file: URL(filePath: identity), key: key, records: Array(planned.reversed()))
        let failures = await journal.restoreKept(where: selects, using: batch)
        guard await journal.isUsable else { throw JournalError.unreadable(path: failures.first?.key ?? "") }
        // A place that couldn't be put back, the newest first, whether it was in the batch or recorded after it was read.
        if let error = batch.firstError { throw error }
        // Nothing failed to be put back, and the journal still says something is left: the restore was cut short, or a record that was
        // restored couldn't be taken out (said in the log).
        try Task.checkCancellation()
        if !failures.isEmpty { throw PlistAccessError.restoreIncomplete(places: failures.count) }
        return batch.restoredCount
    }

    private static func isPlace(of record: JournalRecord, inFile file: String, key: String) -> Bool {
        guard case .plistPath(let filePath, let topLevelKey, _, _, _, _) = record.entry else { return false }
        return filePath == file && topLevelKey == key
    }

    /// Sets the places of `records` (newest first, all of one file and top-level key) to their originals, in one write on a fresh read.
    /// The result has, by journal key, the error of each place that couldn't be put back; a write or a read that fails as a whole throws.
    ///
    /// Places nested inside another kept place aren't supported: each place is set to its original on its own, newest first, which is
    /// right for places side by side (the layout table is flat) and not for a place that holds another one. Nothing writes such a
    /// pair today.
    fileprivate func putBackKept(_ records: [JournalRecord], key: String, in file: URL) async throws -> [String: any Error] {
        // Records of one key are written with one strategy and codec, but nothing makes that so: each kind is its own write.
        struct Kind: Hashable { let strategy: PlistWriteStrategy; let codec: PlistBlobCodecID }
        var kinds: [Kind] = []
        var members: [Kind: [JournalRecord]] = [:]
        for record in records {
            guard case .plistPath(_, _, _, _, let strategy, let codec) = record.entry else { continue }
            let kind = Kind(strategy: strategy, codec: codec)
            if members[kind] == nil { kinds.append(kind) }
            members[kind, default: []].append(record)
        }
        var failures: [String: any Error] = [:]
        for kind in kinds {
            let group = members[kind] ?? []
            do {
                let blobCodec = try blobCodec(for: kind.codec)
                let effective = await restoringStrategy(kind.strategy, for: file, grants: grants)
                failures.merge(try await putBack(group, key: key, to: file, strategy: effective, codec: blobCodec)) { first, _ in first }
            } catch {
                for record in group { failures[record.key] = error }
            }
        }
        return failures
    }

    /// One write for the places of `records`, of one strategy and codec. Places nested inside another kept place aren't supported (see
    /// `putBackKept`): the layout table is flat.
    private func putBack(_ records: [JournalRecord], key: String, to file: URL, strategy: PlistWriteStrategy,
                         codec: (any PlistBlobCodec)?) async throws -> [String: any Error] {
        let notes = lastWritten
        return try await withFile(file) { [io] url in
            let fresh = try io.read(url, key, strategy)
            var updated = fresh
            var applied: [(record: JournalRecord, edit: PathEdit)] = []
            var failures: [String: any Error] = [:]
            for record in records {
                guard case .plistPath(_, _, let path, let original, _, _) = record.entry else { continue }
                let edit = PathEdit(path: path, value: original)
                do {
                    updated = try Self.applying(edit, to: updated, codec: codec, key: key)
                    applied.append((record, edit))
                } catch PlistAccessError.path(.noMatch(let step)) where Self.isMatching(path, at: step) {
                    // Its entry is gone, and with it the place: there is nothing to put back.
                    Log.info("plist", "nothing to put back for \(record.key): its entry is gone")
                } catch {
                    failures[record.key] = error
                }
            }
            // The containers a change made around a place that held nothing, once every place is out of them.
            for (record, edit) in applied where edit.value == nil {
                guard let created = record.createdContainers, created > 0 else { continue }
                updated = try Self.removingEmptyContainers(created: created, along: edit.path, in: updated, codec: codec, key: key)
            }
            if updated != fresh { try io.write(updated, key, url, strategy) }
            let after = try io.read(url, key, strategy)
            for (record, edit) in applied {
                let now: PlistValue?
                do {
                    now = try Self.value(at: edit.path, in: after, codec: codec, key: key)
                } catch {
                    failures[record.key] = error
                    continue
                }
                guard now == edit.value else {
                    failures[record.key] = PlistAccessError.notPersisted(key: key)
                    continue
                }
                // What the place holds now is Mantel's, until the file has caught up with it (see `WrittenLedger`).
                notes.note(edit.value.map(WrittenValue.value) ?? .removed, forKey: record.key)
            }
            return failures
        }
    }

    /// Restores one journal entry, through the grant that is for its file, if there is one. The entry stays in the journal; the
    /// caller removes it.
    ///
    /// - `.plistKey` writes its original (or removes the key) with the entry's own strategy, except that `.atomicFile` on one of
    ///   macOS's two files is done through the preferences service: an earlier version's atomic writes to those were refused by
    ///   macOS, so the preferences service is the only way to put them back.
    /// - `.plistPath` is an inverse edit: the key is read as it is now, the place is set to its original (or removed), and the key
    ///   is written and checked. A place that is gone because the entry of a list it was in is gone (a `matching` or `matchingPath`
    ///   step that matches nothing now: the entry, or the list, or the value the list was in) counts as restored. A list that has
    ///   two entries for the app now (`ambiguousMatch`) is not: which one was Mantel's is not known, so nothing is changed and the
    ///   entry stays in the journal. When the place held nothing
    ///   before and the change made containers around it, the ones that are empty now are taken out too (see
    ///   `JournalRecord.createdContainers`): someone else's entry in one keeps it.
    func restore(_ entry: JournalEntry, grants: FileGrantStore?) async throws {
        let grants = grants ?? self.grants
        switch entry {
        case .plistKey(let filePath, let key, let original, let strategy):
            let file = URL(filePath: filePath)
            let effective = await restoringStrategy(strategy, for: file, grants: grants)
            try await apply(original, key: key, to: file, strategy: effective, grants: grants)
        case .plistPath(let filePath, let key, let path, let original, let strategy, let codecID):
            let file = URL(filePath: filePath)
            let blobCodec = try blobCodec(for: codecID)
            let effective = await restoringStrategy(strategy, for: file, grants: grants)
            // Whatever the change made around the place, so that putting back "nothing there" doesn't leave an empty table behind.
            let created = await journal.records().first { $0.key == Journal.key(for: entry) }?.createdContainers ?? 0
            do {
                try await apply([PathEdit(path: path, value: original)], key: key, to: file, strategy: effective, codec: blobCodec,
                                grants: grants, removingEmptyCreated: created)
                // What the place holds now is Mantel's, until the file has caught up with it (see `WrittenLedger`).
                lastWritten.note(original.map(WrittenValue.value) ?? .removed, forKey: Journal.key(for: entry))
            } catch PlistAccessError.path(.noMatch(let step)) where Self.isMatching(path, at: step) {
                Log.info("plist", "nothing to put back for \(Journal.key(for: entry)): its entry is gone")
            }
        case .defaultsKey:
            throw PlistAccessError.unsupportedEntry
        }
    }

    /// Whether the system still holds what Mantel last wrote for `entry`: nil when that can't be told (the value couldn't be
    /// read, or it is an entry this doesn't read).
    func stillHolds(_ written: WrittenValue, for entry: JournalEntry, grants: FileGrantStore?) async -> Bool? {
        let grants = grants ?? self.grants
        do {
            let current: PlistValue?
            switch entry {
            case .plistKey(let filePath, let key, _, let strategy):
                let file = URL(filePath: filePath)
                let effective = await restoringStrategy(strategy, for: file, grants: grants)
                current = try await withFile(file, grants: grants) { [io] url in try io.read(url, key, effective) }
            case .plistPath(let filePath, let key, let path, _, let strategy, let codecID):
                let file = URL(filePath: filePath)
                let blobCodec = try blobCodec(for: codecID)
                let effective = await restoringStrategy(strategy, for: file, grants: grants)
                let top = try await withFile(file, grants: grants) { [io] url in try io.read(url, key, effective) }
                current = try Self.value(at: path, in: top, codec: blobCodec, key: key)
                // Nothing is read from a list that has the entry twice: that is no change of what Mantel wrote, but not knowing which
                // of the two is Mantel's.
                if current == nil, try Self.hasAmbiguousMatch(at: path, in: top, codec: blobCodec, key: key) { return nil }
            case .defaultsKey:
                return nil
            }
            return Self.matches(written, current)
        } catch {
            return nil
        }
    }

    private static func isMatching(_ path: PlistKeyPath, at step: Int) -> Bool {
        path.indices.contains(step) && path[step].findsAnEntry
    }

    /// `.atomicFile` on one of macOS's two files is put back through the preferences service; any other strategy is kept.
    private func restoringStrategy(_ strategy: PlistWriteStrategy, for file: URL, grants: FileGrantStore?) async -> PlistWriteStrategy {
        guard strategy == .atomicFile, await isMacOSMenuBarFile(file, grants: grants) else { return strategy }
        Log.info("plist", "\(file.lastPathComponent) is put back through macOS's preferences service")
        return .cfPreferences
    }

    // MARK: Doing it

    /// Writes, then reads afresh and compares.
    private func apply(_ value: PlistValue?, key: String, to file: URL, strategy: PlistWriteStrategy,
                       grants: FileGrantStore?) async throws {
        try await withFile(file, grants: grants) { [io] url in
            try io.write(value, key, url, strategy)
            guard try io.read(url, key, strategy) == value else { throw PlistAccessError.notPersisted(key: key) }
        }
    }

    /// Applies `edits` to the key as it is now, writes it once (when they changed it), and checks that every place holds what it
    /// was given.
    ///
    /// With `removingEmptyCreated` (the restore of one place that held nothing before, and the containers the change made around
    /// it), the containers that are empty once the place is gone are taken out, deepest first, up to the top-level key.
    private func apply(_ edits: [PathEdit], key: String, to file: URL, strategy: PlistWriteStrategy, codec: (any PlistBlobCodec)?,
                       grants: FileGrantStore?, removingEmptyCreated created: Int = 0) async throws {
        try await withFile(file, grants: grants) { [io] url in
            let fresh = try io.read(url, key, strategy)
            var updated = try Self.applying(edits, to: fresh, codec: codec, key: key)
            if created > 0, let edit = edits.first, edits.count == 1, edit.value == nil {
                updated = try Self.removingEmptyContainers(created: created, along: edit.path, in: updated, codec: codec, key: key)
            }
            if updated != fresh { try io.write(updated, key, url, strategy) }
            let after = try io.read(url, key, strategy)
            for edit in edits {
                guard try Self.value(at: edit.path, in: after, codec: codec, key: key) == edit.value else {
                    throw PlistAccessError.notPersisted(key: key)
                }
            }
        }
    }

    // MARK: Values at paths

    /// The value at `path` in a top-level value, read through the codec when there is one: the top-level value is then the blob.
    private static func value(at path: PlistKeyPath, in top: PlistValue?, codec: (any PlistBlobCodec)?, key: String) throws -> PlistValue? {
        guard let top else { return nil }
        guard let codec else { return top.value(at: path) }
        guard case .data(let blob) = top else { throw PlistAccessError.notRepresentable(key: key) }
        do {
            return try codec.value(at: path, in: blob)
        } catch let error as KeyPathError {
            throw PlistAccessError.path(error)
        }
    }

    /// Whether the path meets an entry that more than one element of a list satisfies (see `PlistValue.hasAmbiguousMatch(at:)`), in a
    /// top-level value that is read through the codec when there is one.
    private static func hasAmbiguousMatch(at path: PlistKeyPath, in top: PlistValue?, codec: (any PlistBlobCodec)?, key: String) throws -> Bool {
        guard let top else { return false }
        guard let codec else { return top.hasAmbiguousMatch(at: path) }
        guard case .data(let blob) = top else { throw PlistAccessError.notRepresentable(key: key) }
        do {
            return try codec.value(at: [], in: blob)?.hasAmbiguousMatch(at: path) ?? false
        } catch let error as KeyPathError {
            throw PlistAccessError.path(error)
        }
    }

    private static func applying(_ edits: [PathEdit], to top: PlistValue?, codec: (any PlistBlobCodec)?, key: String) throws -> PlistValue? {
        var current = top
        for edit in edits { current = try applying(edit, to: current, codec: codec, key: key) }
        return current
    }

    /// The top-level value with one edit made. A key that isn't there is made as a dictionary for a value to be put in; there is
    /// nothing to remove from it.
    ///
    /// A place inside a list (a `matching` or `matchingPath` step) in a key that isn't there is not made up: the list is gone, and
    /// so is the entry in it, which is `noMatch` at that step, as for an entry that is gone from a list that is there.
    private static func applying(_ edit: PathEdit, to top: PlistValue?, codec: (any PlistBlobCodec)?, key: String) throws -> PlistValue? {
        if top == nil, edit.value == nil { return nil }
        if top == nil, let step = edit.path.firstIndex(where: \.findsAnEntry) { throw PlistAccessError.path(.noMatch(step: step)) }
        guard let codec else {
            do throws(KeyPathError) {
                return try (top ?? .dictionary([:])).setting(edit.value, at: edit.path)
            } catch {
                throw PlistAccessError.path(error)
            }
        }
        // A blob can't be made out of nothing.
        guard let top else { throw PlistAccessError.notRepresentable(key: key) }
        guard case .data(let blob) = top else { throw PlistAccessError.notRepresentable(key: key) }
        do {
            return .data(try codec.setting(edit.value, at: edit.path, in: blob))
        } catch let error as KeyPathError {
            throw PlistAccessError.path(error)
        }
    }

    /// How many of the containers on the way to the place `edit` writes the write is about to make (the deepest ones: a chain of
    /// containers that exists is a chain from the top-level value down). None when the place held something, or the edit removes.
    private static func createdContainers(by edit: PathEdit, original: PlistValue?, in top: PlistValue?, codec: (any PlistBlobCodec)?,
                                          key: String) throws -> Int {
        guard original == nil, edit.value != nil else { return 0 }
        var existing = 0
        for depth in 0..<edit.path.count {
            // The top-level value is the container at depth 0; one that is a blob has its root as long as the blob is there.
            let container = depth == 0 ? top : try value(at: Array(edit.path.prefix(depth)), in: top, codec: codec, key: key)
            guard container != nil else { break }
            existing += 1
        }
        return edit.path.count - existing
    }

    /// The top-level value without the empty dictionaries that are left at the end of `path`, the deepest `created` containers of
    /// it at most, from the deepest up; `nil` when that is the top-level value itself (the key goes).
    private static func removingEmptyContainers(created: Int, along path: PlistKeyPath, in top: PlistValue?, codec: (any PlistBlobCodec)?,
                                                key: String) throws -> PlistValue? {
        var current = top
        // A blob is never made by a write, so the top-level value is only ever a container to remove when there is no codec.
        let shallowest = codec == nil ? 0 : 1
        for depth in stride(from: path.count - 1, through: max(shallowest, path.count - created), by: -1) {
            let address = Array(path.prefix(depth))
            let container = depth == 0 ? current : try value(at: address, in: current, codec: codec, key: key)
            guard case .dictionary(let entries)? = container, entries.isEmpty else { break }
            if depth == 0 { return nil }
            current = try applying(PathEdit(path: address, value: nil), to: current, codec: codec, key: key)
        }
        return current
    }

    private func blobCodec(for id: PlistBlobCodecID) throws -> (any PlistBlobCodec)? {
        guard id != .none else { return nil }
        guard let codec = codecs[id] else { throw PlistAccessError.codecMissing(id.rawValue) }
        return codec
    }

    // MARK: Files

    /// Runs `body` with the file's URL: through the grant that is for the file if there is one, otherwise as it is.
    private func withFile<T: Sendable>(_ file: URL, grants: FileGrantStore? = nil,
                                       _ body: @escaping @Sendable (URL) throws -> T) async throws -> T {
        if let store = grants ?? self.grants, let kind = await Self.grantKind(for: file, in: store) {
            return try await store.withAccess(kind, body)
        }
        return try body(file)
    }

    /// `.atomicFile` is for any file but macOS's two (and for putting back what an earlier version did to them).
    private func refuseAtomicReplacement(of target: URL, strategy: PlistWriteStrategy) async throws {
        guard strategy == .atomicFile, await isMacOSMenuBarFile(target, grants: grants) else { return }
        throw PlistAccessError.atomicFileRefused(file: target.lastPathComponent)
    }

    /// Whether the file is one of the two that macOS keeps for the menu bar (`FileGrantKind`): the one a grant is for, or the one
    /// where macOS keeps it for this user (compared as text: nothing is looked up in another app's folders).
    private func isMacOSMenuBarFile(_ file: URL, grants: FileGrantStore?) async -> Bool {
        if let store = grants ?? self.grants, await Self.grantKind(for: file, in: store) != nil { return true }
        let path = file.standardizedFileURL.path(percentEncoded: false)
        let home = FileManager.default.homeDirectoryForCurrentUser
        return FileGrantKind.allCases.contains { ExpectedFile.expected($0, home: home).candidates.contains(path) }
    }

    /// The kind of grant whose file this is, compared by canonical path.
    private static func grantKind(for file: URL, in store: FileGrantStore) async -> FileGrantKind? {
        let wanted = CanonicalPath.of(file)
        for kind in FileGrantKind.allCases {
            if let grant = await store.grant(for: kind), CanonicalPath.of(URL(filePath: grant.path)) == wanted { return kind }
        }
        return nil
    }
}

/// Puts back the places `PlistFileAccess.restoreKept` selected: the first place the journal asks for has all of them put back in one
/// write, and each place then answers for itself, so that the journal removes the records of the places that are back and keeps the
/// others. A place that wasn't known when the batch was read (recorded since) is put back by itself, as a replay would.
private final class KeptPlaces: JournalRestoring {
    private struct State {
        var outcome: [String: any Error]?
        var restored = 0
        /// The places that couldn't be put back, in the order the journal asked for them (newest first), each with why.
        var errors: [(key: String, error: any Error)] = []
    }

    private let access: PlistFileAccess
    private let file: URL
    private let key: String
    private let records: [JournalRecord]
    private let state = Mutex(State())

    init(access: PlistFileAccess, file: URL, key: String, records: [JournalRecord]) {
        self.access = access
        self.file = file
        self.key = key
        self.records = records
    }

    /// How many places were put back.
    var restoredCount: Int { state.withLock { $0.restored } }

    /// The error of the first place (the newest) that couldn't be put back, whether it was in the batch or put back by itself.
    var firstError: (any Error)? {
        state.withLock { $0.errors.first?.error }
    }

    func restore(_ entry: JournalEntry) async throws {
        let journalKey = Journal.key(for: entry)
        do {
            try await putBack(entry, journalKey: journalKey)
        } catch {
            state.withLock { $0.errors.append((journalKey, error)) }
            throw error
        }
        state.withLock { $0.restored += 1 }
    }

    private func putBack(_ entry: JournalEntry, journalKey: String) async throws {
        try Task.checkCancellation()
        guard records.contains(where: { $0.key == journalKey }) else {
            try await access.restore(entry, grants: nil)
            return
        }
        // The journal asks for the places one at a time, never together: the batch is made once, by the first.
        let known = state.withLock { $0.outcome }
        let outcome: [String: any Error]
        if let known {
            outcome = known
        } else {
            do {
                outcome = try await access.putBackKept(records, key: key, in: file)
            } catch {
                outcome = Dictionary(records.map { ($0.key, error) }, uniquingKeysWith: { first, _ in first })
            }
            state.withLock { $0.outcome = outcome }
        }
        if let error = outcome[journalKey] { throw error }
    }
}

/// Restores what the journal says a plist file's key, or a place inside it, was, with the strategy the entry was written with,
/// through the grant that is for the file when there is one.
public struct PlistJournalRestorer: JournalRestoring {
    private let access: PlistFileAccess
    private let grants: FileGrantStore

    public init(access: PlistFileAccess, grants: FileGrantStore) {
        self.access = access
        self.grants = grants
    }

    public func restore(_ entry: JournalEntry) async throws {
        // A replay that was given up on (see `Journal.replay(using:cap:clock:)`) restores nothing more: what is left stays
        // in the journal for the next launch.
        try Task.checkCancellation()
        try await access.restore(entry, grants: grants)
    }

    /// Reads the value at the entry's place, and compares it with what Mantel wrote.
    public func stillHolds(_ written: WrittenValue, for entry: JournalEntry) async -> Bool? {
        await access.stillHolds(written, for: entry, grants: grants)
    }
}
