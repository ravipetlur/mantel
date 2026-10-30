import Foundation
import MKCore

/// Puts back whatever kind of change the journal holds: a change to a plist file (the layout table, the approvals file) goes to the
/// plist restorer, and a change to a preference (`defaults`: icon spacing) to the defaults restorer. The journal takes one restorer, and
/// every replay of it (the launch's, quitting's, Reset's, Replay now) uses this one.
public struct RoutingJournalRestorer: JournalRestoring {
    private let plist: PlistJournalRestorer
    private let defaults: DefaultsJournalRestorer

    public init(plist: PlistJournalRestorer, defaults: DefaultsJournalRestorer) {
        self.plist = plist
        self.defaults = defaults
    }

    public func restore(_ entry: JournalEntry) async throws {
        switch entry {
        case .plistKey, .plistPath: try await plist.restore(entry)
        case .defaultsKey: try await defaults.restore(entry)
        }
    }

    /// Asked of the restorer that knows the kind of entry: the default of the protocol can't tell, which would make a replay put an old
    /// preference back over a change someone else made since.
    public func stillHolds(_ written: WrittenValue, for entry: JournalEntry) async -> Bool? {
        switch entry {
        case .plistKey, .plistPath: await plist.stillHolds(written, for: entry)
        case .defaultsKey: await defaults.stillHolds(written, for: entry)
        }
    }
}
