import Foundation
import MKCore
import MKLayout

/// Hides icons with the "Allow in the Menu Bar" switches of System Settings: an app whose switch is off has its status items concealed
/// by macOS. Mantel turns the switches of the apps the plan conceals off, and turns them back on when the plan shows them again.
///
/// This changes a file of Apple's, so it is careful about every change:
/// - **Each app's flag is a place of its own** in the list (`ApprovalsCodec.flagPath`): its entry found by its bundle ID, wherever
///   System Settings has put it. Every change is journaled for its place before it is made, with the value the place had (the first
///   original wins), and nothing but those places is ever written back: the list is read as it is at that moment, never from an
///   earlier read.
/// - **Only the apps whose flag differs are written**, all of them in one write. A switch the person turned off in System Settings
///   (no record of Mantel's own change for it) is theirs: it isn't turned on again (`turnedOff` lists them).
/// - **An app Mantel can't hide this way stays visible**: it has no entry in the list, or an entry that names it only by the path of a
///   program, or more than one entry (which one is Mantel's is not known), or an entry shared with an app that is to stay. They are
///   counted in the status (`statusNote`).
/// - **Showing an app again puts its flag back** and takes its record out of the journal, so a record exists exactly while Mantel
///   holds the app hidden (`holdsJournalEntries`).
/// - **`tearDown` undoes each place**, newest first, on a fresh read of the list.
public actor ApprovalsEngine: HidingEngine {
    /// What the person is told when the file hasn't been chosen (as a clause: it ends a sentence of Settings' or a status's).
    static let permissionText = "Choose the “Allow in the Menu Bar” file in Settings › Permissions"
    static let changedText = "macOS changed the “Allow in the Menu Bar” list, so Mantel can't edit it"
    /// What the person is told while a platform test's change to this very list is still in the journal.
    static let leftoverText = "A platform test's change to this list hasn't been put back yet. Use Replay now in Settings › Diagnostics."
    static let turnedOffNeedsFile = "Choose the “Allow in the Menu Bar” file in Permissions to see this list."
    static let turnedOffCantRead = "Mantel can't read this list: macOS changed how it keeps it."

    /// How long a write that the preferences service wouldn't agree to waits before it is tried once more.
    static let retryDelay: Duration = .seconds(1)
    /// What the person is told when the preferences service and the file still disagree after the second try (`HidingError.notSettled`):
    /// nothing of which setting it was about.
    static let notSettledText = "macOS hadn't finished saving its menu bar settings, so nothing was changed. Mantel tries again with the next change."
    /// What the person is told when macOS took a write and didn't keep it (`HidingError.failed`): the list by its name in System Settings.
    /// (It has no full stop of its own: the error's sentence adds one.)
    static let notKeptText = "macOS didn't keep the change to its “Allow in the Menu Bar” list. Mantel tries again with the next change"
    /// What the person is told when the preferences service has no value for the list the file has: nothing was changed. (It has no full
    /// stop of its own, for the same reason.)
    static let noValueText = "macOS reported nothing for its “Allow in the Menu Bar” list. Mantel tries again with the next change"

    private let access: PlistFileAccess
    private let grants: FileGrantStore
    private let journal: Journal
    private let clock: any Clock
    private let turnstile = Turnstile()
    /// How many of the apps the last plan concealed this engine couldn't hide.
    private var unlisted = 0

    public init(access: PlistFileAccess, grants: FileGrantStore, journal: Journal) {
        self.init(access: access, grants: grants, journal: journal, clock: SystemClock())
    }

    /// With the clock the retry after a disagreement of the preferences service sleeps on.
    init(access: PlistFileAccess, grants: FileGrantStore, journal: Journal, clock: any Clock) {
        self.access = access
        self.grants = grants
        self.journal = journal
        self.clock = clock
    }

    public nonisolated var kind: HidingEngineKind {
        .approvals
    }

    // MARK: The file and the list

    /// Why the list can't be read: it hasn't been chosen, or it isn't what Mantel knows how to edit.
    private enum ListProblem: Error {
        case needsFile
        case changed
    }

    private func fileURL() async -> URL? {
        await grants.grant(for: .controlCenterApprovals).map { URL(filePath: $0.path) }
    }

    /// The list as it is now, through the preferences service.
    private func readEntries(_ url: URL) async throws(ListProblem) -> [ApprovalsEntry] {
        let value: PlistValue?
        do {
            value = try await access.value(at: [], key: ApprovalsCodec.key, in: url, codec: ApprovalsCodec.id)
        } catch FileGrantError.stale {
            throw .needsFile
        } catch {
            Log.warning("approvals", "the list couldn't be read")
            throw .changed
        }
        guard let entries = ApprovalsList.entries(in: value) else { throw .changed }
        return entries
    }

    public func availability() async -> EngineAvailability {
        guard let url = await fileURL() else { return .needsPermission(Self.permissionText) }
        guard await foreignRecords().isEmpty else { return .broken(Self.leftoverText) }
        do throws(ListProblem) {
            _ = try await readEntries(url)
            return .available
        } catch {
            switch error {
            case .needsFile: return .needsPermission(Self.permissionText)
            case .changed: return .broken(Self.changedText)
            }
        }
    }

    // MARK: The journal's records of this engine's changes

    /// Whether a journal entry is for this list: the key of the controller file's list.
    private static func isThisList(filePath: String, key: String) -> Bool {
        key == ApprovalsCodec.key && URL(filePath: filePath).lastPathComponent == FileGrantKind.controlCenterApprovals.fileName
    }

    /// The records of the places this engine changed, oldest first: the places of the approvals list that were journaled with its codec.
    private func ownRecords() async -> [JournalRecord] {
        await journal.records().filter { record in
            guard case .plistPath(let filePath, let key, _, _, _, let codec) = record.entry else { return false }
            return Self.isThisList(filePath: filePath, key: key) && codec == ApprovalsCodec.id
        }
    }

    /// The records of changes to this same list that aren't this engine's: the whole key (`plistKey`), or a place in it with another
    /// codec (the platform test's). While one is there, a record for a place of this engine would be left out of the journal (the
    /// whole key is recorded already), so its change would be made with nothing to put it back.
    private func foreignRecords() async -> [JournalRecord] {
        await journal.records().filter { record in
            switch record.entry {
            case .plistKey(let filePath, let key, _, _): Self.isThisList(filePath: filePath, key: key)
            case .plistPath(let filePath, let key, _, _, _, let codec): Self.isThisList(filePath: filePath, key: key) && codec != ApprovalsCodec.id
            case .defaultsKey: false
            }
        }
    }

    /// Whether the journal holds changes this engine made.
    public var holdsJournalEntries: Bool {
        get async { await !ownRecords().isEmpty }
    }

    // MARK: Applying a plan

    /// What a plan changes in the list.
    struct Changes: Equatable {
        /// The flags to write: false for an app to hide, and the original for one that is shown again.
        var edits: [PathEdit] = []
        /// The places of the apps that are shown again, whose records go once their flags are back (or, when the person turned the switch
        /// on, at once: there is nothing to write).
        var shownAgain: [PlistKeyPath] = []
        /// How many of the concealed apps can't be hidden this way.
        var unlisted = 0
    }

    /// Works out what the plan needs: the pure part of `apply`.
    ///
    /// - `entries`: the list as it is.
    /// - `records`: what the journal holds for the places of this engine, by place.
    static func changes(for plan: VisibilityPlan, entries: [ApprovalsEntry], records: [PlistKeyPath: JournalRecord]) -> Changes {
        var entriesOf: [String: [Int]] = [:]
        for (position, entry) in entries.enumerated() {
            for id in Set(entry.bundleIDs) { entriesOf[id, default: []].append(position) }
        }
        var changes = Changes()
        var done: Set<Int> = []

        // Apps to hide.
        for id in plan.concealedBundleIDs.sorted() {
            guard let positions = entriesOf[id], positions.count == 1, let position = positions.first,
                  let allowed = entries[position].isAllowed,
                  entries[position].bundleIDs.allSatisfy({ !plan.visibleBundleIDs.contains($0) }) else {
                changes.unlisted += 1
                continue
            }
            guard done.insert(position).inserted else { continue }
            if allowed { changes.edits.append(PathEdit(path: ApprovalsCodec.flagPath(for: id), value: .bool(false))) }
        }

        // Apps that show: the ones Mantel hid (an entry with a record, under whichever of its apps Mantel hid it by).
        // - Its switch is still off: it is turned back on, with the original the record holds.
        // - Its switch is on: the person turned it on in System Settings while Mantel held it hidden. Nothing is written, but Mantel lets
        //   go of the record: a record that stayed would make Replay now refuse for good, would hide the person's own switch from the
        //   turned-off list when they turn it off later, and the next plan that shows the app would write over it.
        // An entry that is off and has no record is the person's, and is left as it is.
        for id in plan.visibleBundleIDs.sorted() {
            guard let positions = entriesOf[id], positions.count == 1, let position = positions.first,
                  let allowed = entries[position].isAllowed, !done.contains(position) else { continue }
            let held = entries[position].bundleIDs.lazy.compactMap { other -> (path: PlistKeyPath, record: JournalRecord)? in
                let path = ApprovalsCodec.flagPath(for: other)
                return records[path].map { (path, $0) }
            }.first
            guard let held, case .plistPath(_, _, _, let original, _, _) = held.record.entry else { continue }
            done.insert(position)
            if !allowed { changes.edits.append(PathEdit(path: held.path, value: original ?? .bool(true))) }
            changes.shownAgain.append(held.path)
        }
        return changes
    }

    /// Records by place, for the changes of this engine: when two are for one place, the older one (the first original wins).
    private func recordsByPlace() async -> [PlistKeyPath: JournalRecord] {
        var byPlace: [PlistKeyPath: JournalRecord] = [:]
        for record in await ownRecords() {
            guard case .plistPath(_, _, let path, _, _, _) = record.entry, byPlace[path] == nil else { continue }
            byPlace[path] = record
        }
        return byPlace
    }

    /// The preferences service and the file wouldn't agree (the file is behind the service, as it can be for a while after a write, a
    /// relaunch included), so nothing was written.
    private struct PreferencesBehind: Error {}

    /// Makes the list what the plan asks for. If the preferences service and the file disagree about a place it is to change, it tries
    /// once more after a second (on its clock); if they still do, `HidingError.notSettled`: the controller shows everything and goes on,
    /// without counting that against the engine. That is the only error that isn't counted: a write that macOS took and didn't keep
    /// (`PlistAccessError.notPersisted`) is a failure like any other, and three in a row make the controller use another engine.
    public func apply(_ plan: VisibilityPlan) async throws {
        await turnstile.enter()
        defer { turnstile.leave() }
        guard await foreignRecords().isEmpty else { throw HidingError.unavailable(.approvals, Self.leftoverText) }
        do {
            try await applyOnce(plan)
        } catch is PreferencesBehind {
            Log.info("approvals", "the preferences service and the file disagree; trying again in a second")
            try await clock.sleep(for: Self.retryDelay)
            do {
                try await applyOnce(plan)
            } catch is PreferencesBehind {
                throw HidingError.notSettled(.approvals, Self.notSettledText)
            }
        }
    }

    /// One pass over the list. Throws `HidingError`, or `PreferencesBehind` for the one case that is worth a second try: a disagreement
    /// between the preferences service and the file, which is a matter of time.
    private func applyOnce(_ plan: VisibilityPlan) async throws {
        guard let url = await fileURL() else { throw HidingError.unavailable(.approvals, Self.permissionText) }
        let entries: [ApprovalsEntry]
        do throws(ListProblem) {
            entries = try await readEntries(url)
        } catch {
            throw HidingError.unavailable(.approvals, error == .needsFile ? Self.permissionText : Self.changedText)
        }

        let changes = Self.changes(for: plan, entries: entries, records: await recordsByPlace())
        if !changes.edits.isEmpty {
            do {
                try await access.write(changes.edits, key: ApprovalsCodec.key, in: url, strategy: .cfPreferences, codec: ApprovalsCodec.id)
            } catch is CancellationError {
                throw CancellationError()
            } catch PlistAccessError.disagree {
                throw PreferencesBehind()
            } catch let error as PlistAccessError {
                throw Self.failure(for: error)
            } catch {
                throw HidingError.failed(.approvals, error.localizedDescription)
            }
        }
        // Whether the flags were written or the person had put them back already, nothing is held for these apps any more.
        await removeRecords(of: changes.shownAgain, in: url)
        unlisted = changes.unlisted
    }

    /// What the person is told of a write that couldn't be made. An error that names a preferences key says which list it was by its
    /// name in System Settings instead: the key is for the log.
    static func failure(for error: PlistAccessError) -> HidingError {
        switch error {
        case .notPersisted(let key):
            Log.warning("approvals", "macOS didn't keep the change to \(key)")
            return .failed(.approvals, notKeptText)
        case .serviceSeesNothing(let key):
            Log.warning("approvals", "macOS reported no value for \(key), but the file has one")
            return .failed(.approvals, noValueText)
        default:
            return .failed(.approvals, error.localizedDescription)
        }
    }

    /// The apps that are shown again have their flags back: nothing is held for them any more. (A crash before this leaves records
    /// that put the same flags back, which does no harm.)
    private func removeRecords(of places: [PlistKeyPath], in url: URL) async {
        let identity = CanonicalPath.of(url)
        for path in places {
            let entry = JournalEntry.plistPath(filePath: identity, key: ApprovalsCodec.key, path: path, original: nil,
                                               strategy: .cfPreferences, codec: ApprovalsCodec.id)
            do {
                try await journal.remove(key: Journal.key(for: entry))
            } catch {
                Log.warning("approvals", "a record of a switch that is back couldn't be taken out of the journal: \(error.localizedDescription)")
            }
        }
    }

    public func statusNote() async -> String? {
        switch unlisted {
        case 0: nil
        case 1: "1 app with an icon can't be hidden with its switch, so it stays visible."
        default: "\(unlisted) apps with icons can't be hidden with their switches, so they stay visible."
        }
    }

    // MARK: Putting back

    /// Puts every switch Mantel turned off back, one place at a time, newest first, each on a fresh read of the list. A place that can't
    /// be put back stays in the journal for the next launch.
    public func tearDown() async {
        await turnstile.enter()
        defer { turnstile.leave() }
        unlisted = 0
        for record in await ownRecords().reversed() {
            guard case .plistPath(let filePath, let key, let path, _, _, _) = record.entry else { continue }
            do {
                try await access.undo(path: path, key: key, in: URL(filePath: filePath))
            } catch {
                Log.warning("approvals", "a switch couldn't be put back: \(error.localizedDescription)")
            }
        }
    }

    // MARK: Apps turned off by the person

    /// The apps whose switch is off and that Mantel didn't turn off, by bundle ID, sorted. Without the file: why it can't be said.
    public func turnedOff() async -> TurnedOffList {
        guard let url = await fileURL() else { return .unavailable(Self.turnedOffNeedsFile) }
        let entries: [ApprovalsEntry]
        do throws(ListProblem) {
            entries = try await readEntries(url)
        } catch {
            return .unavailable(error == .needsFile ? Self.turnedOffNeedsFile : Self.turnedOffCantRead)
        }
        let mine = Set(await ownRecords().compactMap { record -> PlistKeyPath? in
            guard case .plistPath(_, _, let path, _, _, _) = record.entry else { return nil }
            return path
        })
        var apps: Set<String> = []
        for entry in entries where entry.isAllowed == false {
            // An entry that has a record for any of its apps is one Mantel turned off.
            guard !entry.bundleIDs.contains(where: { mine.contains(ApprovalsCodec.flagPath(for: $0)) }) else { continue }
            apps.formUnion(entry.bundleIDs)
        }
        return .apps(apps.sorted())
    }
}
