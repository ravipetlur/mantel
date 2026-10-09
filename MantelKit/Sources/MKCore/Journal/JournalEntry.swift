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
    /// A preferences key (`defaults`), for later versions (icon spacing).
    case defaultsKey(domain: String, key: String, currentHost: Bool, original: PlistValue?)
}

/// One line of the journal: an entry, under the key that says what it changes, and when it was recorded.
public struct JournalRecord: Codable, Sendable, Equatable {
    /// What the entry changes, for "first original wins": `Journal.key(for:)`.
    public let key: String
    public let entry: JournalEntry
    public let recordedAt: Date

    public init(key: String, entry: JournalEntry, recordedAt: Date) {
        self.key = key
        self.entry = entry
        self.recordedAt = recordedAt
    }
}

/// Puts back what an entry says was changed. Mantel's platform layer provides the real one; tests give the journal their own.
public protocol JournalRestoring: Sendable {
    func restore(_ entry: JournalEntry) async throws
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
