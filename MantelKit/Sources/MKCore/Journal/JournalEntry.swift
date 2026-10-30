import Foundation
import Synchronization

/// How a plist file is written; the restorer must undo a change the same way (cfprefsd caches CFPreferences domains).
public enum PlistWriteStrategy: String, Codable, Sendable {
    /// Through `CFPreferences`, so that `cfprefsd`, which caches the domain, sees the change.
    case cfPreferences
    /// The file itself, read and written whole, atomically.
    case atomicFile
}

/// What Mantel changed in the system, with what is needed to put it back.
public enum JournalEntry: Codable, Sendable, Equatable {
    /// A top-level key in a plist file (the approvals file, the layout table) and its value before Mantel changed it.
    /// `original == nil` means the key didn't exist.
    case plistKey(filePath: String, key: String, original: PlistValue?, strategy: PlistWriteStrategy)
    /// A place inside a top-level key of a plist file, and its value before Mantel changed it: only that place is put back, so
    /// what the person or macOS changed elsewhere in the key meanwhile is left alone. `original == nil` means there was nothing
    /// at the path. `codec` says how the value of `key` is read for the path to be followed (`.none`: as it is).
    case plistPath(filePath: String, key: String, path: PlistKeyPath, original: PlistValue?,
                   strategy: PlistWriteStrategy, codec: PlistBlobCodecID)
    /// A preferences key (`defaults`) and its value before Mantel changed it: the icon spacing. `original == nil` means the key wasn't there.
    case defaultsKey(domain: String, key: String, currentHost: Bool, original: PlistValue?)
}

/// How long a journal record holds its change: whether quitting puts it back.
public enum JournalLifetime: String, Codable, Sendable, CaseIterable {
    /// A temporary change: put back on quit, at the next launch after a crash, by Reset and by Replay now.
    case untilQuit
    /// Mantel's own arrangement, which stays across quits and resets: put back only when the person asks for it (Restore
    /// original layout, Restore original spacing).
    case kept
}

/// One line of the journal: an entry, under the key that says what it changes, and when it was recorded.
public struct JournalRecord: Codable, Sendable, Equatable {
    /// What the entry changes, for "first original wins": `Journal.key(for:)`.
    public let key: String
    public let entry: JournalEntry
    public let recordedAt: Date
    /// What Mantel last wrote at this entry's place (`Journal.noteWritten`); nil when it isn't known, which is every record
    /// an earlier version made. Optional in the file, so that a journal an earlier version wrote still reads.
    public var lastWritten: WrittenValue?
    /// For a place inside a key that held nothing before Mantel wrote it: how many of the containers on the way to it, counted
    /// from the top-level value, the change made (they weren't there before it). Putting the place back takes out the ones it
    /// leaves empty, so that an absent table doesn't come back as `{}`. nil is none, and is every record an earlier version made.
    public var createdContainers: Int?
    /// Whether quitting puts the change back. A record an earlier version made has no lifetime in the file, and is `.untilQuit`;
    /// so is one whose lifetime this version doesn't know (`JournalDecodingNotes`).
    public var lifetime: JournalLifetime

    public init(key: String, entry: JournalEntry, recordedAt: Date, lastWritten: WrittenValue? = nil, createdContainers: Int? = nil,
                lifetime: JournalLifetime = .untilQuit) {
        self.key = key
        self.entry = entry
        self.recordedAt = recordedAt
        self.lastWritten = lastWritten
        self.createdContainers = createdContainers
        self.lifetime = lifetime
    }

    private enum CodingKeys: String, CodingKey {
        case key, entry, recordedAt, lastWritten, createdContainers, lifetime
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        key = try container.decode(String.self, forKey: .key)
        entry = try container.decode(JournalEntry.self, forKey: .entry)
        recordedAt = try container.decode(Date.self, forKey: .recordedAt)
        lastWritten = try container.decodeIfPresent(WrittenValue.self, forKey: .lastWritten)
        createdContainers = try container.decodeIfPresent(Int.self, forKey: .createdContainers)
        // A lifetime that is missing (an earlier version's record) or that this version doesn't know (a later one's) is
        // "until quit": the cautious reading, since what is put back on quit is only ever the system as it was.
        if container.contains(.lifetime), (try? container.decodeNil(forKey: .lifetime)) != true {
            if let raw = try? container.decode(String.self, forKey: .lifetime), let known = JournalLifetime(rawValue: raw) {
                lifetime = known
            } else {
                lifetime = .untilQuit
                if let notes = decoder.userInfo[.journalDecodingNotes] as? JournalDecodingNotes {
                    notes.noteUnknownLifetime()
                } else {
                    Log.warning("journal", "a journal record has a lifetime this version doesn't know; it is treated as one to put back on quit")
                }
            }
        } else {
            lifetime = .untilQuit
        }
    }
}

extension CodingUserInfoKey {
    /// Where `Journal` gives a decoder the `JournalDecodingNotes` it wants filled in while it reads the file.
    static let journalDecodingNotes = CodingUserInfoKey(rawValue: "mantel.journalDecodingNotes")!
}

/// What reading a journal file turned up that is worth a log line, counted while the records are decoded so that a file with
/// many such records says it once (`Journal` logs it when the file has been read).
final class JournalDecodingNotes: Sendable {
    private let unknownLifetimes = Mutex(0)

    func noteUnknownLifetime() {
        unknownLifetimes.withLock { $0 += 1 }
    }

    /// How many records had a lifetime this version doesn't know.
    var unknownLifetimeCount: Int {
        unknownLifetimes.withLock { $0 }
    }
}

/// An entry `Journal.replay` couldn't restore: its key and what went wrong, in words for Diagnostics.
public struct ReplayFailure: Sendable, Equatable {
    public let key: String
    public let message: String

    public init(key: String, message: String) {
        self.key = key
        self.message = message
    }
}
