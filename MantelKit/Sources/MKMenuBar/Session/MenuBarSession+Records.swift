import Foundation
import MKCore
import MKLayout

// Which icons an app has, and what is kept of them. The sections hold a record for each icon an app has been seen with; an app's icons are
// told by what its own list gives (`InventoryMatcher`), and only a read of the app that was whole (`WholeReads`) says which they are. The
// state is kept in `MenuBarSession.swift` (`wholeReads`, `currentIDs`, `recordsChecked`, set when the session is made).
extension MenuBarSession {
    /// Which apps `read` names the icons of for certain, and what each of them has now: the icons of its last whole read. The state of an
    /// app that has quit is dropped.
    func takeInWholeReads(of read: Inventory) -> Set<String> {
        let running = Set(runningBundleIDs())
        let whole = wholeReads.wholeApps(in: read, running: running)
        for bundleID in whole { currentIDs[bundleID] = Set(read.items(ofApp: bundleID).map(\.id)) }
        currentIDs = currentIDs.filter { running.contains($0.key) || read.appProcesses[$0.key] != nil }
        return whole
    }

    /// The icons of `read` to put in the sections: the system's, and the apps' whose read was whole. Not the unchecked apps': their records
    /// are checked against the read (`SectionModel.checkUnchecked`), which puts what they have in the place of what they don't.
    ///
    /// An app that has records is given a new one only for an icon that the app's read before this one listed too (`previous`, the icons
    /// of its last whole read): an app whose menu is rebuilt for a moment, or that adds an icon and takes it away, has more icons in
    /// one read than it has, and a record of one of them would stay for good. A real new icon is recorded one read later. An app that
    /// has no record yet is given its icons at once.
    func iconsToNote(in read: Inventory, wholeApps: Set<String>, previous: [String: Set<ItemID>]) -> [ItemID] {
        read.items.filter { item in
            guard !item.isMantel, item.ownKind == nil, item.id.bundleID != OwnItems.owner else { return false }
            if item.id.isSystem { return true }
            guard wholeApps.contains(item.id.bundleID), !sections.unchecked.contains(item.id.bundleID) else { return false }
            return !isNewRecordOfAnAppWithRecords(item.id) || previous[item.id.bundleID]?.contains(item.id) == true
        }.map(\.id)
    }

    /// Whether `id` has no record, and its app has some. (The save's line in the log says what a record added is, and who it is of.)
    private func isNewRecordOfAnAppWithRecords(_ id: ItemID) -> Bool {
        let records = sections.records(ofApp: id.bundleID)
        return !records.isEmpty && !records.contains(id)
    }

    /// Has the pictures of the records the check of the unchecked apps' saved icons took out dealt with (`ItemImageStore.reconcile`, once, with
    /// the records of every app that was checked), and has the app deal with their settings and say in the log what the check did
    /// (`SectionModel.checkUnchecked`, made on the sections by `ingest`). The settings are moved on a task that `ingest` doesn't wait on.
    func reportChecked(_ checked: [(app: String, done: SectionModel.Reconciled)], in read: Inventory) async {
        guard !checked.isEmpty else { return }
        let dropped = Set(checked.flatMap(\.done.dropped))
        if !dropped.isEmpty { await imageCollector?.reconcile(with: read, droppedRecords: dropped) }
        let recordsChecked = recordsChecked
        let earlier = settingsMoves
        settingsMoves = Task {
            await earlier?.value
            for (bundleID, done) in checked {
                let settings = await recordsChecked(bundleID, done)
                Log.info("layout", Self.checkedLine(app: bundleID, done: done, settings: settings))
            }
        }
    }

    /// Returns when the settings of the records that were taken out so far have been dealt with, those of a check that was made while it
    /// waited too (a read that was in `ingest` chains another task behind the one that was awaited). The tests wait for it.
    public func settingsMovesFinished() async {
        while let task = settingsMoves {
            await task.value
            if settingsMoves == task { break }
        }
    }

    /// The most that the quit waits for the settings moves and for what comes after them: it must fit in the quit timer.
    static let quitSettingsMovesLimit: Duration = .milliseconds(250)

    /// What the quit does before it writes the settings: waits for the moves (`settingsMovesFinished`) and then for `following` (the settings'
    /// own saves, one of which a move can enqueue), within `quitSettingsMovesLimit`. A move that was never made is lost for good, as the app
    /// that was checked isn't checked again; past the limit the quit goes on, and the work carries on by itself.
    public func finishSettingsMovesForQuit(then following: @escaping @Sendable () async -> Void) async {
        _ = await TimeBound.finishes(within: Self.quitSettingsMovesLimit, clock: clock) {
            await self.settingsMovesFinished()
            await following()
        }
    }

    /// What the log says of an app's saved icons being checked: its bundle ID, and what was kept, taken out, added, and what became of the
    /// settings of the ones taken out. Icon IDs and counts, nothing the apps' reads said of what the icons show.
    static func checkedLine(app: String, done: SectionModel.Reconciled, settings: SettingsMoved) -> String {
        func list(_ items: [ItemID]) -> String { items.map(\.string).joined(separator: ", ") }
        var line = "saved icons of \(app) checked: kept \(done.kept.count) (\(list(done.kept))), dropped \(done.dropped.count) (\(list(done.dropped))), added \(done.added.count)"
        if !settings.moved.isEmpty {
            line += ", settings moved \(settings.moved.count) (\(settings.moved.sorted { $0.key.string < $1.key.string }.map { "\($0.key) to \($0.value)" }.joined(separator: ", ")))"
        }
        if !settings.left.isEmpty { line += ", settings left under \(settings.left.count) dropped (\(list(settings.left)))" }
        return line
    }

    /// Whether the app is running, was read whole in this run, and doesn't list this icon: it is a record of an icon that isn't there now.
    /// A click on it reveals nothing and presses nothing.
    public func hasNoSuchIcon(_ item: ItemID) -> Bool {
        guard !item.isSystem, let current = currentIDs[item.bundleID] else { return false }
        return !current.contains(item)
    }
}
