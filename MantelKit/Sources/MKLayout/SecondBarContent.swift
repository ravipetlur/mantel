import CoreGraphics
import MKCore

/// One cell of the second bar, or of a group's panel: an icon that the person can click.
public struct SecondBarEntry: Sendable, Equatable, Identifiable {
    public let id: ItemID
    /// The app's name, or a system item's title.
    public let title: String
    /// The section the icon is in.
    public let section: MenuBarSection
    /// The group the icon's app is in, for the icons the bar lists after Always Hidden's.
    public let group: GroupID?
    /// A thin separator goes before this cell: it is the first of Always Hidden's, or of a group's, and something comes before it.
    public let startsBlock: Bool
    /// How wide the cell is: the icon's slot width, from 30 to 120 points.
    public let width: CGFloat

    public init(id: ItemID, title: String, section: MenuBarSection, group: GroupID?, startsBlock: Bool, width: CGFloat) {
        self.id = id
        self.title = title
        self.section = section
        self.group = group
        self.startsBlock = startsBlock
        self.width = width
    }
}

/// Which icons the second bar and a group's panel list, and in what order.
///
/// - **Only what a click can show.** An app that isn't running has no icon to click, and neither has one that macOS has turned off in
///   System Settings. Nor has a record of an icon the app doesn't list now (`SectionModel.staleRecords`). A system item is listed only when Mantel can hide it by number, and the clock and Control Center only when
///   hiding them is allowed (otherwise they never leave the bar).
/// - **Mantel's own items are never listed:** its dots, its divider, the spacers and the groups' icons.
/// - **In the order of the layout editor** (`SectionModel.order` and `groupItems`). An icon that the model doesn't list yet, whose app
///   the inventory has, comes at the end of its section's block (or its group's), by name.
public enum SecondBarContent {
    /// What the bar lists for a reveal of this level.
    ///
    /// - **Hidden:** the icons in the Hidden section.
    /// - **All:** those, then Always Hidden's, then each group's, in the order of the groups. Grouped apps count as Always Hidden for a
    ///   reveal of everything, and never for one of Hidden alone. Each of the blocks after the first one that has a cell starts a block.
    /// - **Off:** nothing.
    ///
    /// - Parameters:
    ///   - running: the bundle IDs of the apps that are running.
    ///   - turnedOff: the apps that macOS has turned off in System Settings.
    ///   - names: the apps' names, by bundle ID. An app that isn't in it is called what the inventory says, and then its bundle ID.
    ///   - widths: how wide each icon's slot was when it was last on the bar.
    ///   - allowClockAndControlCenter: whether the person allows hiding the clock and Control Center.
    ///   - stale: the records of icons that aren't there now, which have no cell.
    public static func entries(level: RevealLevel, sections: SectionModel, inventory: Inventory, running: Set<String>,
                               turnedOff: Set<String>, names: [String: String], widths: ItemWidthCache,
                               allowClockAndControlCenter: Bool, stale: StaleRecords = .none) -> [SecondBarEntry] {
        let lister = Lister(sections: sections, inventory: inventory, running: running, turnedOff: turnedOff, names: names, widths: widths,
                            allowClockAndControlCenter: allowClockAndControlCenter, stale: stale)
        var blocks: [[SecondBarEntry]] = []
        switch level {
        case .off:
            break
        case .hidden:
            blocks = [lister.entries(in: .hidden)]
        case .all:
            blocks = [lister.entries(in: .hidden), lister.entries(in: .alwaysHidden)]
            for group in lister.groupsInOrder() { blocks.append(lister.entries(inGroup: group)) }
        }
        return joined(blocks)
    }

    /// What a group's panel lists: the icons of the group's apps, in the order of the group, as one block.
    public static func entries(group: GroupID, sections: SectionModel, inventory: Inventory, running: Set<String>,
                               turnedOff: Set<String>, names: [String: String], widths: ItemWidthCache,
                               stale: StaleRecords = .none) -> [SecondBarEntry] {
        Lister(sections: sections, inventory: inventory, running: running, turnedOff: turnedOff, names: names, widths: widths,
               allowClockAndControlCenter: false, stale: stale).entries(inGroup: group)
    }

    /// The blocks one after the other: the first cell of each block that follows another block's cells starts a block.
    private static func joined(_ blocks: [[SecondBarEntry]]) -> [SecondBarEntry] {
        var all: [SecondBarEntry] = []
        for block in blocks where !block.isEmpty {
            for (place, entry) in block.enumerated() {
                all.append(place == 0 && !all.isEmpty ? entry.startingABlock() : entry)
            }
        }
        return all
    }

    /// What the lists are made from, and what is left out of them.
    private struct Lister {
        let sections: SectionModel
        let inventory: Inventory
        let running: Set<String>
        let turnedOff: Set<String>
        let names: [String: String]
        let widths: ItemWidthCache
        let allowClockAndControlCenter: Bool
        let stale: StaleRecords

        /// The icons of the inventory by identity, for what the model's lists don't say of an icon.
        private var inventoryItems: [ItemID: MenuBarItem] {
            Dictionary(inventory.items.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        }

        /// Every icon some list of the model holds.
        private var listed: Set<ItemID> {
            Set(MenuBarSection.allCases.flatMap { sections.order[$0] ?? [] } + sections.groupItems.values.flatMap { $0 })
        }

        func groupsInOrder() -> [GroupID] {
            let others = sections.groupItems.keys.filter { !sections.groupOrder.contains($0) }.sorted { $0.rawValue < $1.rawValue }
            return sections.groupOrder + others
        }

        /// A section's icons: its list, then the icons of apps in it that no list holds.
        func entries(in section: MenuBarSection) -> [SecondBarEntry] {
            let known = sections.items(in: section)
            let unlisted = unlistedItems { id in
                id.isSystem ? sections.section(of: id) == section : sections.section(ofApp: id.bundleID) == section && !isGrouped(id)
            }
            return make(known + unlisted, section: section, group: nil)
        }

        /// A group's icons: the group's list, then the icons of its apps that no list holds.
        func entries(inGroup group: GroupID) -> [SecondBarEntry] {
            let known = sections.groupItems[group] ?? []
            let unlisted = unlistedItems { id in !id.isSystem && sections.apps[id.bundleID]?.group == group }
            return make(known + unlisted, section: .alwaysHidden, group: group)
        }

        /// The icons in the inventory that no list of the model holds and that `belongs` says are here, by name.
        private func unlistedItems(where belongs: (ItemID) -> Bool) -> [ItemID] {
            let already = listed
            let found = inventory.items.filter { !already.contains($0.id) && belongs($0.id) }.map(\.id)
            return found.sorted { a, b in
                let (x, y) = (title(of: a).lowercased(), title(of: b).lowercased())
                return x == y ? a.string < b.string : x < y
            }
        }

        private func isGrouped(_ id: ItemID) -> Bool {
            sections.apps[id.bundleID]?.group != nil
        }

        private func make(_ ids: [ItemID], section: MenuBarSection, group: GroupID?) -> [SecondBarEntry] {
            let items = inventoryItems
            var seen: Set<ItemID> = []
            return ids.compactMap { id in
                guard seen.insert(id).inserted, isListable(id, item: items[id]) else { return nil }
                return SecondBarEntry(id: id, title: title(of: id), section: section, group: group, startsBlock: false,
                                      width: SecondBarGeometry.cellWidth(slotWidth: widths.slotWidth(of: id)))
            }
        }

        /// Whether a click on the icon can show it.
        private func isListable(_ id: ItemID, item: MenuBarItem?) -> Bool {
            if OwnItems.isOwn(id) || item?.isMantel == true || item?.ownKind != nil { return false }
            guard case .system(let module) = id.key else {
                return running.contains(id.bundleID) && !turnedOff.contains(id.bundleID) && !stale.contains(id)
            }
            guard SystemItemTable.number(of: module) != nil else { return false }
            return !SystemItemTable.unmovable.contains(module) || allowClockAndControlCenter
        }

        private func title(of id: ItemID) -> String {
            if case .system(let module) = id.key { return SystemItemTable.title(of: module) ?? module }
            return names[id.bundleID] ?? inventory.items.first { $0.ownerBundleID == id.bundleID && $0.appName != nil }?.appName
                ?? id.bundleID
        }
    }
}

extension SecondBarEntry {
    fileprivate func startingABlock() -> SecondBarEntry {
        SecondBarEntry(id: id, title: title, section: section, group: group, startsBlock: true, width: width)
    }
}
