import Foundation
import MKCore
import MKLayout

/// The applier's view of the writer; the applier's tests give it a fake.
public protocol LayoutTableWriting: Sendable {
    func availability() async -> LayoutWriterAvailability
    func readTable() async throws(LayoutWriteError) -> LayoutTableSnapshot
    /// Writes the distances of `keys`' tokens that are not the table's already. Answers the keys that were written.
    func write(_ arrangement: LayoutArrangement, keys: [LayoutToken: String]) async throws(LayoutWriteError) -> [String]
    /// Puts back every place Mantel wrote, in one write. Answers how many.
    func restoreOriginalLayout() async throws(LayoutWriteError) -> Int
    var hasKeptChanges: Bool { get async }
}

/// Writes macOS's order table (`TrailingItemPreferredPositions` in the menu bar's preferences) through the layout file's grant.
///
/// Every place it writes is `[.key(<table key>)]` inside the table, written through the preferences service, and journaled as one Mantel
/// keeps (`.kept`: it stays across quits and resets, and only `restoreOriginalLayout` puts it back). The writes check the original of
/// a place only the first time it is written (`.newPathsOnly`): macOS rewrites the table after it re-sorts the bar, and waiting for the
/// file to catch up before each write would only delay the next one.
public actor LayoutTableWriter: LayoutTableWriting {
    public static let lifetime: JournalLifetime = .kept
    /// A distance that is this close to the table's is left alone.
    static let tolerance = 0.25

    private let access: PlistFileAccess
    private let reader: LayoutTableReader
    private let grants: FileGrantStore
    private let journal: Journal
    private let home: URL
    private let broken: String?

    /// - Parameters:
    ///   - home: the home folder (a temporary one in tests): where the layout file is expected.
    ///   - broken: why reordering is off on this Mac, when the platform check says so (`LayoutRules.broken`).
    public init(access: PlistFileAccess, reader: LayoutTableReader, grants: FileGrantStore, journal: Journal, home: URL, broken: String?) {
        self.access = access
        self.reader = reader
        self.grants = grants
        self.journal = journal
        self.home = home
        self.broken = broken
    }

    // MARK: Availability

    /// In this order: `broken` when the platform check says so; `needsGrant` without the grant; `broken` when the granted layout file isn't
    /// where macOS keeps it any more, or has no table; `held` while a change to the whole table, left by an earlier version's platform test, is still in the journal (a kept write
    /// under it would be put back with it); otherwise `available`.
    public func availability() async -> LayoutWriterAvailability {
        if let broken { return .broken(broken) }
        guard await grants.grant(for: .menuBarLayout) != nil else { return .needsGrant }
        let url: URL
        do {
            url = try await grants.withAccess(.menuBarLayout) { $0 }
        } catch {
            // A grant that no longer leads to the file: the file is gone from where macOS keeps it (reordering is off), or only the grant
            // is (it is asked for again). Not looked for before there is a grant: an app that hasn't been given the file may not see it.
            return FileManager.default.fileExists(atPath: expectedPath) ? .needsGrant : .broken(LayoutWords.broken)
        }
        do {
            if try await access.value(at: [], key: LayoutKeys.trailingPositions, in: url) == nil { return .broken(LayoutWords.broken) }
        } catch PlistAccessError.notADictionary {
            return .broken(LayoutWords.broken)
        } catch {
            // A read that failed for a moment says nothing of the file: the write that follows says what went wrong.
        }
        if await hasLeftoverWholeKey {
            return .held(JournalError.leftoverWholeKey(key: wholeKey).errorDescription ?? LayoutWords.couldntChange)
        }
        return .available
    }

    // MARK: Reading and writing

    public func readTable() async throws(LayoutWriteError) -> LayoutTableSnapshot {
        guard await grants.grant(for: .menuBarLayout) != nil else { throw .needsGrant }
        do {
            return try await reader.read()
        } catch {
            // The grant is gone (revoked, or the file moved): it is asked for again.
            if let grantError = error as? FileGrantError, case .stale = grantError { throw .needsGrant }
            throw Self.translating(error)
        }
    }

    /// Writes the changed distances in one `PlistFileAccess.write` (`.kept`, `.newPathsOnly`). A token whose key the table doesn't have yet
    /// is written; one whose distance is within 0.25 of the table's is not. Answers the keys written, in the arrangement's order.
    public func write(_ arrangement: LayoutArrangement, keys: [LayoutToken: String]) async throws(LayoutWriteError) -> [String] {
        switch await availability() {
        case .available: break
        case .needsGrant: throw .needsGrant
        case .broken(let text): throw .broken(text)
        case .held(let text): throw .failed(text)
        }
        let table = try await readTable()
        var edits: [PathEdit] = []
        var written: [String] = []
        for token in arrangement.tokens {
            guard let key = keys[token], let distance = arrangement.distances[token] else { continue }
            if let current = table.distances[key], abs(current - distance) <= Self.tolerance { continue }
            let value: PlistValue = distance == distance.rounded() ? .integer(Int(distance)) : .real(distance)
            edits.append(PathEdit(path: [.key(key)], value: value))
            written.append(key)
        }
        guard !edits.isEmpty else { return [] }
        do {
            let url = try await grants.withAccess(.menuBarLayout) { $0 }
            try await access.write(edits, key: LayoutKeys.trailingPositions, in: url, strategy: .cfPreferences, lifetime: Self.lifetime,
                                   originalCheck: .newPathsOnly)
        } catch {
            throw Self.translating(error)
        }
        return written
    }

    // MARK: Putting back

    /// Puts every place Mantel wrote back as it was (removing the entries that didn't exist), in one write, whatever the age of the
    /// records. Answers how many places came back; 0 when nothing was kept.
    public func restoreOriginalLayout() async throws(LayoutWriteError) -> Int {
        guard await grants.grant(for: .menuBarLayout) != nil else { throw .needsGrant }
        do {
            let url = try await grants.withAccess(.menuBarLayout) { $0 }
            return try await access.restoreKept(key: LayoutKeys.trailingPositions, in: url)
        } catch {
            throw Self.translating(error)
        }
    }

    /// Whether Mantel's arrangement is in the table: a place is kept in the journal.
    public var hasKeptChanges: Bool {
        get async {
            let prefix = wholeKey + "/"
            return await journal.keptRecords().contains { $0.key.hasPrefix(prefix) }
        }
    }

    // MARK: Inside

    private var expectedPath: String {
        ExpectedFile.expected(.menuBarLayout, home: home).candidates.first ?? ""
    }

    /// The journal's key for the whole table.
    private var wholeKey: String {
        Journal.key(for: .plistKey(filePath: CanonicalPath.of(URL(filePath: expectedPath)), key: LayoutKeys.trailingPositions, original: nil,
                                   strategy: .cfPreferences))
    }

    private var hasLeftoverWholeKey: Bool {
        get async {
            let key = wholeKey
            return await journal.records().contains { $0.key == key && $0.lifetime == .untilQuit }
        }
    }

    private static func translating(_ error: any Error) -> LayoutWriteError {
        if let error = error as? LayoutWriteError { return error }
        if let error = error as? FileGrantError, case .stale = error { return .failed(error.localizedDescription) }
        let text = error.localizedDescription
        Log.warning("layout", "the order table couldn't be changed: \(text)")
        return .failed(text)
    }
}
