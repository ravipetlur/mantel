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
    /// A journal entry this restorer doesn't restore (a `defaults` key, which a later version adds).
    case unsupportedEntry

    public var errorDescription: String? {
        switch self {
        case .notADictionary: "The file isn't a property list with a dictionary in it."
        case .unreadable(let reason): "The file couldn't be read: \(reason)"
        case .notRepresentable(let key): "The value of \"\(key)\" can't be saved and put back, so Mantel left it alone."
        case .notPersisted(let key): "macOS didn't keep the change to \"\(key)\"."
        case .disagree(let key): "macOS's preferences service and the file disagree about \(key), so nothing was changed."
        case .serviceSeesNothing(let key):
            "macOS's preferences service reports no value for \(key), but the file has one, so nothing was changed."
        case .backupFailed(let file, let reason): "Mantel couldn't make a backup copy of \(file) first, so nothing was changed: \(reason)"
        case .unsupportedEntry: "Mantel can't put this kind of change back yet."
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

    /// The whole file as a dictionary of what a property list holds, so that writing one key back leaves every other key as it
    /// was, whatever its type.
    static func readDictionary(_ url: URL) throws -> [String: Any] {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw PlistAccessError.unreadable(error.localizedDescription)
        }
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
        guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else { return nil }
        guard let raw = try readDictionary(url)[key] else { return nil }
        guard let value = PlistValue(propertyList: raw) else { throw PlistAccessError.notRepresentable(key: key) }
        return value
    }

    /// Reads the file, sets the key, and writes the whole dictionary as a binary plist, atomically. The file is macOS's, not
    /// Mantel's: it keeps the mode, owner, extended attributes and ACL it had, which Mantel's own private files don't need to.
    static func writeFile(_ value: PlistValue?, key: String, to url: URL) throws {
        let exists = FileManager.default.fileExists(atPath: url.path(percentEncoded: false))
        var dictionary = exists ? try readDictionary(url) : [:]
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

/// Copies a file whole into the Backups folder, once per file for as long as the process lives.
///
/// Copies of `PlistFileAccess` share one ledger, and the app makes one `PlistFileAccess`, so "once" is once per run. A copy that
/// couldn't be made isn't counted, so the next write tries again.
final class BackupLedger: Sendable {
    private let done = Mutex<Set<String>>([])

    /// Copies `file`'s bytes to `<folder>/<name without .plist>-<yyyyMMdd-HHmmss>.plist` (privately, and whole or not at all),
    /// unless a copy of `identity` was made already. A file that isn't there has nothing to copy, and counts as copied.
    func backUpOnce(_ file: URL, identity: String, into folder: URL, at date: Date) throws {
        try done.withLock { done in
            guard !done.contains(identity) else { return }
            if FileManager.default.fileExists(atPath: file.path(percentEncoded: false)) {
                do {
                    let bytes = try Data(contentsOf: file)
                    try AtomicFile.ensureFolder(folder)
                    let name = file.pathExtension == "plist" ? file.deletingPathExtension().lastPathComponent : file.lastPathComponent
                    let destination = AtomicFile.unusedURL(in: folder, base: "\(name)-\(AtomicFile.timestamp(for: date))",
                                                           pathExtension: "plist")
                    try AtomicFile.write(bytes, to: destination, synchronize: true)
                } catch {
                    throw PlistAccessError.backupFailed(file: file.lastPathComponent, reason: error.localizedDescription)
                }
            }
            done.insert(identity)
        }
    }
}

/// Reads and changes top-level keys of plist files (the approvals file, the layout file), with the journal behind every
/// change, so that a crash in the middle of one never leaves the person's menu bar altered.
///
/// - **`write`** first checks that the value it would keep as the original is the true one, then copies the file whole to the
///   Backups folder (the first write to it in this run), then records the original in the journal (first original wins),
///   writes, reads the value afresh and compares. The journal comes before the change: if the journal can't record, because
///   it can't be written or because a replay is running (`JournalError.replayInProgress`), nothing is written. Anything that
///   makes the original doubtful, or the backup impossible, refuses the write before the journal is touched.
/// - **Symlinks are resolved** before anything is written. An atomic replace onto a link would replace the link with a
///   regular file.
/// - **A file that has a grant** (see `FileGrantStore`) is opened through it, for exactly as long as the reading or the
///   writing takes.
public struct PlistFileAccess: Sendable {
    private let journal: Journal
    private let grants: FileGrantStore?
    private let backups: URL
    private let clock: any Clock
    private let io: PlistIO
    private let backedUp = BackupLedger()

    /// - Parameters:
    ///   - paths: where Mantel keeps its files; the copies made before a file's first change go to `paths.backups`.
    ///   - grants: a file one of them is for is opened through it.
    public init(journal: Journal, paths: MantelPaths, grants: FileGrantStore? = nil) {
        self.init(journal: journal, paths: paths, grants: grants, io: .system)
    }

    init(journal: Journal, paths: MantelPaths, grants: FileGrantStore? = nil, io: PlistIO, clock: any Clock = SystemClock()) {
        self.journal = journal
        self.grants = grants
        backups = paths.backups
        self.clock = clock
        self.io = io
    }

    /// The top-level keys of the file, with their values. A key whose value isn't a property list type of Mantel's is left
    /// out. It reads the file itself, so a file that needs a grant has to be read inside `FileGrantStore.withAccess`.
    public func readTopLevel(_ url: URL) throws -> [String: PlistValue] {
        var top: [String: PlistValue] = [:]
        for (key, raw) in try PlistIO.readDictionary(url) {
            if let value = PlistValue(propertyList: raw) { top[key] = value }
        }
        return top
    }

    /// Journals the key's current value (first original wins), writes, re-reads, and checks the value on disk.
    ///
    /// Before anything is journaled or changed, inside the same grant: the original is checked (`originalValue`), and the file
    /// is copied whole into the Backups folder if this is the first write to it in this run.
    ///
    /// - Throws: `PlistAccessError.disagree`, `.serviceSeesNothing` or `.notRepresentable` when the original is doubtful, and
    ///   `.backupFailed` when the copy can't be made: nothing is journaled, written or backed up in the first case, and
    ///   nothing is journaled or written in the second. `JournalError.replayInProgress` while a replay runs, and nothing is
    ///   written. `PlistAccessError.notPersisted` when the value that was read back isn't the one written (the journal keeps
    ///   the original, for the restore).
    public func write(_ value: PlistValue?, key: String, in url: URL, strategy: PlistWriteStrategy) async throws {
        let target = url.resolvingSymlinksInPath()
        let identity = target.path(percentEncoded: false)
        let original = try await withFile(target) { [io, backups, ledger = backedUp, now = clock.now()] file in
            let original = try Self.originalValue(of: key, in: file, strategy: strategy, io: io)
            try ledger.backUpOnce(file, identity: identity, into: backups, at: now)
            return original
        }
        try await journal.record(.plistKey(filePath: identity, key: key, original: original, strategy: strategy))
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

    /// Puts the key back as the journal says it was, with the strategy it was changed with, and takes its record out of the
    /// journal. A key that isn't recorded is left alone.
    public func undo(key: String, in url: URL) async throws {
        let path = url.resolvingSymlinksInPath().path(percentEncoded: false)
        let probe = JournalEntry.plistKey(filePath: path, key: key, original: nil, strategy: .atomicFile)
        let journalKey = Journal.key(for: probe)
        guard let record = await journal.records().first(where: { $0.key == journalKey }) else { return }
        try await restore(record.entry, grants: grants)
        try await journal.remove(key: journalKey)
    }

    /// Restores one journal entry: writes its original (or removes the key) with the entry's own strategy, through the grant
    /// that is for its file, if there is one. The entry stays in the journal; the caller removes it.
    func restore(_ entry: JournalEntry, grants: FileGrantStore?) async throws {
        guard case .plistKey(let filePath, let key, let original, let strategy) = entry else {
            throw PlistAccessError.unsupportedEntry
        }
        try await apply(original, key: key, to: URL(filePath: filePath), strategy: strategy, grants: grants ?? self.grants)
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

    /// Runs `body` with the file's URL: through the grant that is for the file if there is one, otherwise as it is.
    private func withFile<T: Sendable>(_ file: URL, grants: FileGrantStore? = nil,
                                       _ body: @escaping @Sendable (URL) throws -> T) async throws -> T {
        if let store = grants ?? self.grants, let kind = await Self.grantKind(for: file, in: store) {
            return try await store.withAccess(kind, body)
        }
        return try body(file)
    }

    /// The kind of grant whose file this is, compared by canonical path.
    private static func grantKind(for file: URL, in store: FileGrantStore) async -> FileGrantKind? {
        let wanted = canonical(file)
        for kind in FileGrantKind.allCases {
            if let grant = await store.grant(for: kind), canonical(URL(filePath: grant.path)) == wanted { return kind }
        }
        return nil
    }

    /// The path with every symlink in it resolved (`/private` included), also for a file that isn't there: the part that
    /// exists is resolved, and the rest is kept as it is. A grant for a file that has gone must still be found, to say so.
    static func canonical(_ url: URL) -> String {
        var existing = url.standardizedFileURL
        var rest: [String] = []
        while existing.path != "/", !FileManager.default.fileExists(atPath: existing.path(percentEncoded: false)) {
            rest.insert(existing.lastPathComponent, at: 0)
            existing = existing.deletingLastPathComponent()
        }
        var base = existing.path(percentEncoded: false)
        if let resolved = realpath(base, nil) {
            base = String(cString: resolved)
            free(resolved)
        }
        return rest.reduce(base) { ($0 as NSString).appendingPathComponent($1) }
    }
}

/// Restores what the journal says a plist file's key was, with the strategy the entry was written with, through the grant that
/// is for the file when there is one.
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
}
