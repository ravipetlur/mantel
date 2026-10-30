import Foundation
import MKCore
import MKLayout

/// One icon, with what it is found by and where it is.
public struct IconSearchEntry: Sendable, Equatable {
    public let item: ItemID
    /// The name of the app that draws it (for a system item, the module's title).
    public let appName: String?
    /// The item's own label (its Accessibility title or description). It can hold a network's name or a battery level, so it is only
    /// ever matched against and shown in Mantel's own windows, never logged.
    public let label: String?
    /// The names the person gave it to find it by.
    public let customNames: [String]
    /// The section the icon is in; nil for one in a group.
    public let section: MenuBarSection?
    /// The title of the group the icon is in; nil for one that isn't in a group, and empty for a group with no title.
    public let groupTitle: String?

    public init(item: ItemID, appName: String?, label: String? = nil, customNames: [String] = [], section: MenuBarSection? = nil,
                groupTitle: String? = nil) {
        self.item = item
        self.appName = appName
        self.label = label
        self.customNames = customNames
        self.section = section
        self.groupTitle = groupTitle
    }

    /// What the icon is called in the list: its app's name, or when that is missing the name the item's ID gives (the module of a system
    /// item, the bundle ID of any other).
    public var title: String {
        if let name = appName?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty { return name }
        if case .system(let module) = item.key { return module }
        return item.bundleID
    }

    /// Where the icon is, in words: its section, or its group.
    public var subtitle: String? {
        if let groupTitle { return OwnItems.groupDescription(title: groupTitle) }
        return section?.title
    }
}

/// What the command bar and the `mantel icon` verbs can find, built from what Mantel knows of the menu bar.
public enum IconSearchEntries {
    /// One entry per icon the inventory or the sections know, Mantel's own left out, in the order the layout lists them: each section's
    /// icons in turn (Shown, Hidden, Always Hidden), then the groups', then what the inventory has that no list holds yet.
    ///
    /// - **The name** is the app's from `names` (by bundle ID), else the inventory's, else the bundle ID. A system item is named by
    ///   `SystemItemTable.title`; one the table doesn't know, by the inventory's name, else its module.
    /// - **The label** is the inventory's, when the icon is in it.
    /// - **The custom names** are the person's (`preferences`).
    /// - **An icon in a group** has the group's title and no section.
    /// - **A running app** has an entry for each icon it has now, not for the records the sections hold of icons that aren't there
    ///   (`stale`). **An app that isn't running** has one entry, its first record's: a click on it answers that it isn't running.
    ///   With `running` nil every app counts as running.
    public static func build(inventory: Inventory, sections: SectionModel, preferences: IconPreferences, names: [String: String],
                             running: Set<String>? = nil, stale: StaleRecords = .none) -> [IconSearchEntry] {
        var drawn: [ItemID: MenuBarItem] = [:]
        var drawnOrder: [ItemID] = []
        for item in inventory.items where !item.isMantel && item.ownKind == nil && !OwnItems.isOwn(item.id) {
            if drawn[item.id] == nil {
                drawn[item.id] = item
                drawnOrder.append(item.id)
            }
        }

        let groupKeys = sections.groupOrder + sections.groupItems.keys.filter { !sections.groupOrder.contains($0) }.sorted { $0.rawValue < $1.rawValue }
        var groupOfListed: [ItemID: GroupID] = [:]
        for group in groupKeys {
            for item in sections.groupItems[group] ?? [] where groupOfListed[item] == nil {
                groupOfListed[item] = group
            }
        }

        var ordered: [ItemID] = []
        var seen: Set<ItemID> = []
        func list(_ item: ItemID) {
            if !OwnItems.isOwn(item), seen.insert(item).inserted { ordered.append(item) }
        }
        for section in MenuBarSection.allCases {
            sections.items(in: section).forEach(list)
        }
        for group in groupKeys {
            (sections.groupItems[group] ?? []).forEach(list)
        }
        drawnOrder.forEach(list)

        var appsNotRunning: Set<String> = []
        ordered = ordered.filter { item in
            guard !item.isSystem, item.bundleID != OwnItems.owner else { return true }
            if let running, !running.contains(item.bundleID) { return appsNotRunning.insert(item.bundleID).inserted }
            return !stale.contains(item)
        }

        return ordered.map { item in
            let group = groupOfListed[item] ?? placedGroup(of: item, in: sections)
            return IconSearchEntry(
                item: item,
                appName: appName(of: item, drawn: drawn[item], names: names),
                label: trimmed(drawn[item]?.label),
                customNames: preferences.searchNames[item] ?? [],
                section: group == nil ? sections.section(of: item) : nil,
                groupTitle: group.map { trimmed(sections.groups[$0]?.title) ?? "" })
        }
    }

    /// The group an app is in, for an icon that no group's list holds yet; nil for a system item and for an app in none.
    private static func placedGroup(of item: ItemID, in sections: SectionModel) -> GroupID? {
        guard !item.isSystem, let group = sections.apps[item.bundleID]?.group, sections.groups[group] != nil else { return nil }
        return group
    }

    private static func appName(of item: ItemID, drawn: MenuBarItem?, names: [String: String]) -> String {
        if case .system(let module) = item.key {
            return SystemItemTable.title(of: module) ?? trimmed(drawn?.appName) ?? module
        }
        return trimmed(names[item.bundleID]) ?? trimmed(drawn?.appName) ?? item.bundleID
    }

    private static func trimmed(_ text: String?) -> String? {
        guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        return text
    }
}
