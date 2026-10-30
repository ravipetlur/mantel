import Foundation
import MKCore

/// Why a preference couldn't be changed or put back.
public enum DefaultsAccessError: Error, Equatable, LocalizedError {
    /// The preferences service didn't keep the change: what was read back wasn't what was written. `key` is the preference's key.
    case notPersisted(key: String)
    /// A temporary change was asked for at a key Mantel keeps (its own icon spacing), which only a restore of what Mantel keeps puts
    /// back. `key` is the journal's key for the place (`Journal.key(for:)`), as in the journal's own refusal. Nothing is changed.
    case keptByMantel(key: String)

    public var errorDescription: String? {
        switch self {
        case .notPersisted(let key): "macOS didn't keep the change to \(key). Try again."
        // The journal words its refusals, `defaults:` keys included, so there is one sentence for it.
        case .keptByMantel(let key): JournalError.keptByMantel(key: key).errorDescription
        }
    }
}

/// One key and what it is to hold.
public struct DefaultsChange: Sendable, Equatable {
    public let key: String
    /// Nil removes the key.
    public let value: PlistValue?

    public init(key: String, value: PlistValue?) {
        self.key = key
        self.value = value
    }
}

/// Reads and changes preferences (`defaults`), with the journal behind every change, so that a crash in the middle of one never leaves
/// the person's settings altered.
///
/// - **Write.** The key's value now is read, the original is journaled (`.defaultsKey`: the first original wins, so the journal keeps the
///   value from before Mantel's first change), the value is written, it is read back and compared, and what was written is noted in the
///   journal (so that an old record can be told from a setting someone else has changed since). The journal comes first: if it can't
///   record, nothing is written.
/// - **Lifetimes** are the journal's. A `.kept` write to a key that has a temporary record makes the record `.kept` and keeps its
///   original; a temporary write to a key Mantel keeps is refused (`keptByMantel`).
/// - **A change that isn't kept** (the service didn't take it, or holds something else when it is read back) is taken back: the key is set
///   to what it held, and the records this call made go with it. A record some other call made, or that was there already, is never
///   touched. When the key can't be put back either, its record stays, for a restore.
/// - **One at a time.** The calls of an actor interleave at every wait, and two writes to one key must not: every change and every
///   putting back is done before the next one begins.
public actor DefaultsAccess {
    private let journal: Journal
    private let preferences: any PreferencesService
    private let turns = AsyncSerialQueue()

    public init(journal: Journal, preferences: any PreferencesService) {
        self.journal = journal
        self.preferences = preferences
    }

    /// The value now, as the preferences service holds it.
    public func value(forKey key: String, in domain: PreferencesDomain) -> PlistValue? {
        preferences.value(forKey: key, in: domain)
    }

    /// Journals the original first (`.defaultsKey`, first original wins), writes, reads back, notes what was written.
    ///
    /// - Throws: `DefaultsAccessError.notPersisted` when the value read back isn't the one written (the key is put back as it was, and
    ///   what this call recorded is taken out), `.keptByMantel` for a temporary write at a key Mantel keeps, and the journal's own errors
    ///   (`JournalError.replayInProgress`, `.restoreInProgress`, `.unreadable`): nothing is written then.
    public func write(_ value: PlistValue?, forKey key: String, in domain: PreferencesDomain, lifetime: JournalLifetime) async throws {
        let changes = [DefaultsChange(key: key, value: value)]
        try await inTurn { try await $0.write(changes, in: domain, lifetime: lifetime, skippingUnchanged: false) }
    }

    /// Writes several keys of one domain so that they all happen or none does: every record is made before the first write, and a key
    /// that isn't kept puts the ones written before it back. A key that already holds its value and has no record isn't written and
    /// isn't recorded: there is nothing to protect.
    ///
    /// - Throws: as `write`, for the first key that fails.
    public func writeAll(_ changes: [DefaultsChange], in domain: PreferencesDomain, lifetime: JournalLifetime) async throws {
        try await inTurn { try await $0.write(changes, in: domain, lifetime: lifetime, skippingUnchanged: true) }
    }

    /// Puts the key's original back and takes its record out of the journal. A key that isn't recorded is left alone.
    ///
    /// - Throws: `DefaultsAccessError.keptByMantel` when the record is one Mantel keeps: only a restore of what Mantel keeps puts that
    ///   back. `.notPersisted` when the original wasn't kept (the record stays).
    public func undo(key: String, in domain: PreferencesDomain) async throws {
        try await inTurn { try await $0.undoNow(key: key, in: domain) }
    }

    private func undoNow(key: String, in domain: PreferencesDomain) async throws {
        let journalKey = Self.journalKey(key, in: domain)
        guard let record = await journal.records().first(where: { $0.key == journalKey }) else { return }
        guard record.lifetime == .untilQuit else { throw DefaultsAccessError.keptByMantel(key: journalKey) }
        guard case .defaultsKey(_, _, _, let original) = record.entry else { return }
        try putBack(original, key: key, in: domain)
        try await journal.remove(key: journalKey)
    }

    // MARK: Writing

    private struct Step {
        let change: DefaultsChange
        let entry: JournalEntry
        /// What the key held before this call.
        let before: PlistValue?
    }

    private func write(_ changes: [DefaultsChange], in domain: PreferencesDomain, lifetime: JournalLifetime,
                       skippingUnchanged: Bool) async throws {
        let recorded = skippingUnchanged ? Set(await journal.records().map(\.key)) : []
        var steps: [Step] = []
        for change in changes {
            let before = preferences.value(forKey: change.key, in: domain)
            let entry = JournalEntry.defaultsKey(domain: domain.application, key: change.key, currentHost: domain.currentHost, original: before)
            if skippingUnchanged, before == change.value, !recorded.contains(Journal.key(for: entry)) { continue }
            steps.append(Step(change: change, entry: entry, before: before))
        }
        guard !steps.isEmpty else { return }

        // Every record is made before the first write, so that a refusal stops the whole call with nothing changed.
        var receipts: [JournalReceipt] = []
        do {
            for step in steps {
                receipts.append(try await journal.recordWithReceipt(step.entry, lifetime: lifetime))
            }
        } catch {
            for receipt in receipts.reversed() { try? await journal.rollBack(receipt) }
            throw Self.translating(error)
        }

        for (index, step) in steps.enumerated() {
            let accepted = preferences.set(step.change.value, forKey: step.change.key, in: domain)
            guard accepted, preferences.value(forKey: step.change.key, in: domain) == step.change.value else {
                Log.warning("defaults", "the change to \(step.change.key) wasn't kept by the preferences service")
                await takeBack(steps, receipts: receipts, attempted: index + 1, in: domain)
                throw DefaultsAccessError.notPersisted(key: step.change.key)
            }
        }

        for step in steps {
            let written = step.change.value.map(WrittenValue.value) ?? .removed
            do {
                try await journal.noteWritten(written, forKey: Journal.key(for: step.entry))
            } catch {
                // The change is made and journaled; only the note that lets an old record be told from a changed one is missing.
                Log.warning("defaults", "what was written for \(step.change.key) couldn't be noted: \(error.localizedDescription)")
            }
        }
        Log.info("defaults", "changed \(steps.map(\.change.key).joined(separator: ", ")) (\(lifetime.rawValue))")
    }

    /// Puts each of the first `attempted` keys of the steps (the ones written, and the one that wasn't kept) back as it was before the
    /// call, newest first, and takes out the record the call made for a key that is back: a change that isn't there has nothing to put
    /// back. A key that can't be put back keeps its record. A key after those was never written: only its record is taken out, and the
    /// key is left as it is, whoever has changed it since.
    private func takeBack(_ steps: [Step], receipts: [JournalReceipt], attempted: Int, in domain: PreferencesDomain) async {
        for index in steps.indices.reversed() {
            let step = steps[index]
            let key = step.change.key
            var now = preferences.value(forKey: key, in: domain)
            if index < attempted, now != step.before {
                _ = preferences.set(step.before, forKey: key, in: domain)
                now = preferences.value(forKey: key, in: domain)
            }
            guard index >= attempted || now == step.before else {
                Log.warning("defaults", "\(key) couldn't be put back after a change that wasn't kept; its record stays for a restore")
                continue
            }
            do {
                try await journal.rollBack(receipts[index])
            } catch {
                Log.warning("defaults", "the record of \(key) couldn't be taken out after a change that wasn't kept: \(error.localizedDescription)")
            }
        }
    }

    /// The journal's refusals as the errors of this type; anything else is as it was.
    private static func translating(_ error: any Error) -> any Error {
        switch error as? JournalError {
        case .keptByMantel(let key)?: DefaultsAccessError.keptByMantel(key: key)
        default: error
        }
    }

    private static func journalKey(_ key: String, in domain: PreferencesDomain) -> String {
        Journal.key(for: .defaultsKey(domain: domain.application, key: key, currentHost: domain.currentHost, original: nil))
    }

    // MARK: Putting back

    /// Sets the key to `original` (nil removes it), unless it holds that already, and checks that it took.
    private func putBack(_ original: PlistValue?, key: String, in domain: PreferencesDomain) throws {
        guard preferences.value(forKey: key, in: domain) != original else { return }
        let accepted = preferences.set(original, forKey: key, in: domain)
        guard accepted, preferences.value(forKey: key, in: domain) == original else {
            throw DefaultsAccessError.notPersisted(key: key)
        }
    }

    /// Restores one journal entry. The record stays in the journal; the caller takes it out.
    func restore(_ entry: JournalEntry) async throws {
        guard case .defaultsKey(let application, let key, let currentHost, let original) = entry else {
            throw PlistAccessError.unsupportedEntry
        }
        try await inTurn { try $0.putBack(original, key: key, in: PreferencesDomain(application: application, currentHost: currentHost)) }
    }

    /// Whether the key still holds what Mantel last wrote for the entry: nil when that can't be told (an entry of another kind).
    func holds(_ written: WrittenValue, for entry: JournalEntry) -> Bool? {
        guard case .defaultsKey(let application, let key, let currentHost, _) = entry else { return nil }
        let current = preferences.value(forKey: key, in: PreferencesDomain(application: application, currentHost: currentHost))
        return switch written {
        case .value(let value): current == value
        case .removed: current == nil
        }
    }

    // MARK: One at a time

    /// Runs `work` when every call before it has finished, and returns what it comes to.
    private func inTurn(_ work: @escaping @Sendable (isolated DefaultsAccess) async throws -> Void) async throws {
        let outcome: Result<Void, any Error> = await turns.run { [self] in
            do {
                try await work(self)
                return .success(())
            } catch {
                return .failure(error)
            }
        }
        try outcome.get()
    }
}

/// Restores what the journal says a preference was, through `DefaultsAccess`.
public struct DefaultsJournalRestorer: JournalRestoring {
    private let access: DefaultsAccess

    public init(access: DefaultsAccess) {
        self.access = access
    }

    public func restore(_ entry: JournalEntry) async throws {
        // A replay that was given up on restores nothing more: what is left stays in the journal for the next launch.
        try Task.checkCancellation()
        try await access.restore(entry)
    }

    /// Reads the key, and compares it with what Mantel wrote.
    public func stillHolds(_ written: WrittenValue, for entry: JournalEntry) async -> Bool? {
        await access.holds(written, for: entry)
    }
}
