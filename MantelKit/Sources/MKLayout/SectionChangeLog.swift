import MKCore

/// What the log says when the sections are saved: one line a save, saying what changed and who changed it, in bundle IDs, section names
/// and counts (never an icon's name). A save that changes nothing has no line.
///
/// A save can hold the work of several: the read that finds a ⌘-drag's follow and a new icon is one save. The session takes the sections
/// after each step (`took(_:by:)`), and the line has a part for each step that changed anything:
/// `sections saved: com.example.a to Hidden (a ⌘-drag); 1 icon record added: com.example.b#1 (icons seen in a read)`.
public struct SectionChangeLog: Sendable, Equatable {
    /// Who changed the sections, in the words of the log.
    public enum Cause: Sendable, Equatable {
        /// A change the person made: a move in Settings or in the layout editor, a forget.
        case person
        /// The read that follows a ⌘-drag.
        case commandDrag
        /// A read whose order of icons is the one the sections now follow (no drag).
        case barOrder
        /// Automatic overflow: apps moved to Hidden for room, and apps back in Shown on trial.
        case overflowTracker
        /// The check of an app's saved icons against what the app lists (`SectionModel.checkUnchecked`).
        case check
        /// Icons that a read lists and no record has.
        case newIcons
        /// Apps seen for the first time.
        case newApps

        public var words: String {
            switch self {
            case .person: "the person"
            case .commandDrag: "a ⌘-drag"
            case .barOrder: "the order on the bar"
            case .overflowTracker: "the overflow tracker"
            case .check: "a check of saved icons"
            case .newIcons: "icons seen in a read"
            case .newApps: "apps seen for the first time"
            }
        }
    }

    /// The most records a part names; after them it says how many more.
    private static let namedRecords = 3

    private struct Part: Sendable, Equatable {
        let cause: Cause
        let changes: [String]
    }

    private var last: SectionModel
    private var parts: [Part] = []

    /// A log of the changes from `start` on.
    public init(from start: SectionModel) {
        last = start
    }

    /// The sections are now `now`, and `cause` made what differs from the last time (or from the start).
    public mutating func took(_ now: SectionModel, by cause: Cause) {
        defer { last = now }
        guard now != last else { return }
        parts.append(Part(cause: cause, changes: Self.changes(from: last, to: now)))
    }

    /// The sections are now `now`, and a change since the last time was made by someone whose own line says it (a person's change is
    /// saved as it is made): this log doesn't say it.
    public mutating func skip(to now: SectionModel) {
        last = now
    }

    /// The line for the save, or nil when nothing changed.
    public var line: String? {
        let told = parts.filter { !$0.changes.isEmpty }
        guard !told.isEmpty else { return nil }
        return "sections saved: " + told.map { "\($0.changes.joined(separator: ", ")) (\($0.cause.words))" }.joined(separator: "; ")
    }

    // MARK: What differs

    /// How many apps' changes a line names before it counts the rest.
    static let appsNamed = 6

    /// What differs between two states of the sections, in order: apps, system items, icon records, own items, the place for new apps. Never
    /// empty for two states that differ.
    static func changes(from before: SectionModel, to after: SectionModel) -> [String] {
        var told: [String] = []
        var apps: [String] = []
        for app in Set(before.apps.keys).union(after.apps.keys).sorted() {
            switch (before.apps[app], after.apps[app]) {
            case (let was?, let now?):
                if was.section != now.section {
                    apps.append("\(app) to \(now.section.title)")
                } else if was.group != now.group {
                    apps.append(now.group == nil ? "\(app) out of its group" : "\(app) in a group")
                } else if was.isAuto != now.isAuto {
                    apps.append(now.isAuto ? "\(app) marked as moved by Mantel" : "\(app) no longer marked as moved by Mantel")
                }
            case (nil, let now?):
                apps.append("\(app) placed in \(now.section.title)")
            case (_?, nil):
                apps.append("\(app) forgotten")
            case (nil, nil):
                break
            }
        }
        // A first save of a fresh profile places every app: the line names six, as the records' part names three, and counts the rest.
        told += apps.prefix(Self.appsNamed)
        if apps.count > Self.appsNamed { told.append("and \(apps.count - Self.appsNamed) more apps") }
        for module in Set(before.systemItems.keys).union(after.systemItems.keys).sorted() {
            let was = before.systemItems[module] ?? .shown
            let now = after.systemItems[module] ?? .shown
            if was != now { told.append("system item \(module) to \(now.title)") }
        }
        let wasRecords = records(in: before)
        let nowRecords = records(in: after)
        let added = nowRecords.subtracting(wasRecords)
        // A record added to an app that had records already (an icon that came back) is always named: it is what the line is there to show.
        let appsWithRecords = Set(wasRecords.map(\.bundleID))
        told += recordsPart(added, "added", alwaysNamed: added.filter { appsWithRecords.contains($0.bundleID) })
        told += recordsPart(wasRecords.subtracting(nowRecords), "dropped")
        told += ownItemsParts(before.spacers, after.spacers, noun: "spacer")
        told += ownItemsParts(before.groups, after.groups, noun: "group")
        if before.newItems != after.newItems {
            told.append("new apps go to \(after.newItems.title)")
        } else if before.newItemsIndex != after.newItemsIndex {
            told.append("the place for new apps moved")
        }
        let checked = before.unchecked.subtracting(after.unchecked).count
        if checked > 0 { told.append("saved icons of \(checked) \(checked == 1 ? "app" : "apps") checked") }
        let unchecked = after.unchecked.subtracting(before.unchecked).count
        if unchecked > 0 { told.append("saved icons of \(unchecked) \(unchecked == 1 ? "app" : "apps") to be checked") }
        if told.isEmpty {
            // Nothing above says what changed: the lists of icons hold the same icons in another order, or something that has no words yet.
            let reordered = before.order != after.order || before.groupOrder != after.groupOrder || before.groupItems != after.groupItems
            told.append(reordered ? "the order of icons changed" : "something else in the sections changed")
        }
        return told
    }

    /// The icons that are listed, apps' and system items': Mantel's own are told apart as spacers and groups.
    private static func records(in model: SectionModel) -> Set<ItemID> {
        var all = Set(model.order.values.joined())
        all.formUnion(model.groupItems.values.joined())
        return all.filter { $0.bundleID != OwnItems.owner }
    }

    /// The part for `ids`: the ones in `alwaysNamed` first, all of them, then the others a few at a time, and how many more.
    private static func recordsPart(_ ids: Set<ItemID>, _ verb: String, alwaysNamed: Set<ItemID> = []) -> [String] {
        guard !ids.isEmpty else { return [] }
        let first = ids.intersection(alwaysNamed).map(\.description).sorted()
        let rest = ids.subtracting(alwaysNamed).map(\.description).sorted()
        var named = (first + rest.prefix(namedRecords)).joined(separator: ", ")
        if rest.count > namedRecords { named += " and \(rest.count - namedRecords) more" }
        return ["\(ids.count) icon \(ids.count == 1 ? "record" : "records") \(verb): \(named)"]
    }

    private static func ownItemsParts<ID: Hashable, Value: Equatable>(_ before: [ID: Value], _ after: [ID: Value], noun: String) -> [String] {
        let added = Set(after.keys).subtracting(before.keys).count
        let removed = Set(before.keys).subtracting(after.keys).count
        let changed = Set(before.keys).intersection(after.keys).filter { before[$0] != after[$0] }.count
        var told: [String] = []
        for (count, verb) in [(added, "added"), (removed, "removed"), (changed, "changed")] where count > 0 {
            told.append("\(count) \(noun)\(count == 1 ? "" : "s") \(verb)")
        }
        return told
    }
}
