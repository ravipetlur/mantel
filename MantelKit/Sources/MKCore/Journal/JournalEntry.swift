import Foundation

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
    /// A preferences key (`defaults`), for later versions (icon spacing).
    case defaultsKey(domain: String, key: String, currentHost: Bool, original: PlistValue?)
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

    public init(key: String, entry: JournalEntry, recordedAt: Date, lastWritten: WrittenValue? = nil, createdContainers: Int? = nil) {
        self.key = key
        self.entry = entry
        self.recordedAt = recordedAt
        self.lastWritten = lastWritten
        self.createdContainers = createdContainers
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
