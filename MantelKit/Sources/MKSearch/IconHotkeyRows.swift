import Foundation
import MKCore

/// One row of Settings › Hotkeys › Icons: an icon that has a shortcut of its own, or has just been added to get one.
public struct IconHotkeyRow: Sendable, Equatable, Identifiable {
    public let item: ItemID
    /// What the row calls the icon.
    public let name: String
    /// What the shortcut does: the icon's action, else the one picked for a row that has no shortcut yet, else Show.
    public let action: IconHotkeyAction
    /// Whether `icons.json` holds an action for the icon. A shortcut without one isn't registered.
    public let hasStoredAction: Bool
    /// Whether the icon has a shortcut yet.
    public let hasBinding: Bool

    public var id: String { item.string }
}

/// Which icons Settings › Hotkeys lists, and which it offers to add.
public enum IconHotkeyRows {
    /// The icons with a shortcut, and the ones added that have none yet (`pending`, with the action picked for each), in the order of
    /// `entries`; an icon that isn't there any more (its app has quit and gone from the sections) follows, by ID.
    ///
    /// - Parameter fallbackName: what an icon not in `entries` is called.
    public static func rows(bindings: [HotkeyID: KeyCombo], preferences: IconPreferences, entries: [IconSearchEntry],
                            pending: [ItemID: IconHotkeyAction], fallbackName: (ItemID) -> String) -> [IconHotkeyRow] {
        var wanted: Set<ItemID> = Set(bindings.keys.compactMap(\.iconItem))
        wanted.formUnion(pending.keys)
        func row(_ item: ItemID, name: String) -> IconHotkeyRow {
            let stored = preferences.hotkeyActions[item]
            let hasBinding = bindings[.icon(item)] != nil
            // With a shortcut, what is saved is what it does. Without one, what was picked last is what is shown (an action left behind
            // with no shortcut must not hold the picker to it).
            let action = hasBinding ? (stored ?? pending[item] ?? .show) : (pending[item] ?? stored ?? .show)
            return IconHotkeyRow(item: item, name: name, action: action, hasStoredAction: stored != nil, hasBinding: hasBinding)
        }
        var rows: [IconHotkeyRow] = []
        var listed: Set<ItemID> = []
        let titles = displayNames(for: entries)
        for entry in entries where wanted.contains(entry.item) && listed.insert(entry.item).inserted {
            rows.append(row(entry.item, name: titles[entry.item] ?? entry.title))
        }
        for item in wanted.subtracting(listed).sorted(by: { $0.string < $1.string }) {
            rows.append(row(item, name: fallbackName(item)))
        }
        return rows
    }

    /// What each icon of `entries` is called where the icons are listed: its title, and where it is in brackets when another icon has the
    /// same title (`Weather (Hidden)`), and a number after that when it is still the same (`Weather (Hidden) 2`).
    public static func displayNames(for entries: [IconSearchEntry]) -> [ItemID: String] {
        var each: [IconSearchEntry] = []
        var seen: Set<ItemID> = []
        for entry in entries where seen.insert(entry.item).inserted { each.append(entry) }
        var titleCounts: [String: Int] = [:]
        for entry in each { titleCounts[entry.title, default: 0] += 1 }
        var names: [ItemID: String] = [:]
        var timesUsed: [String: Int] = [:]
        for entry in each {
            var name = entry.title
            if titleCounts[name, default: 0] > 1 {
                if let subtitle = entry.subtitle, !subtitle.isEmpty { name += " (\(subtitle))" }
                timesUsed[name, default: 0] += 1
                if let times = timesUsed[name], times > 1 { name += " \(times)" }
            }
            names[entry.item] = name
        }
        return names
    }

    /// What a clash warning calls each icon: every row's, and every icon that can be added (a shortcut's icon is always a row, so a warning
    /// never has to show an ID). `titles` are the icons' names as `displayNames` gives them; an icon without one is called its title.
    public static func names(rows: [IconHotkeyRow], addable: [IconSearchEntry], titles: [ItemID: String] = [:]) -> [ItemID: String] {
        var names: [ItemID: String] = [:]
        for entry in addable { names[entry.item] = titles[entry.item] ?? entry.title }
        for row in rows { names[row.item] = row.name }
        return names
    }

    /// The icons "Add an icon…" offers: those with no row yet, in the order of `entries`, each once.
    public static func addable(entries: [IconSearchEntry], rows: [IconHotkeyRow]) -> [IconSearchEntry] {
        var taken = Set(rows.map(\.item))
        return entries.filter { taken.insert($0.item).inserted }
    }
}
