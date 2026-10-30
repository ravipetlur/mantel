import CoreGraphics
import Foundation
import MKCommands
import MKCore
import MKLayout

/// `layout-map`: how macOS's order table relates to where the icons are. It reads the table through the preferences service, and the
/// inventory, and writes nothing.
///
/// - **`fixtureEntries`:** the test item's and Mantel's own entries, each with its distance and where its slot is on each display (the
///   slot of the item the entry names, when that item is in the inventory).
/// - **`residuals`:** for every icon that is drawn and whose own name gives its key in the table (names only: an icon with none isn't
///   looked at), how far its distance is from where it is: `distance - (bar.maxX - slot.maxX)` (`right`: the distance is measured from the
///   bar's right edge to the icon's right edge) and `distance - (bar.maxX - slot.minX)` (`left`: to its left edge). Each display has the
///   count and the smallest, middle and largest of each. No key and no name is recorded.
/// - **`moduleKeys`:** the system's entries, by the names Apple gave them, with their distances.
/// - **Counts:** `appsWithMoreKeysThanItems` (running apps that have more entries in the table than items in the menu bar),
///   `itemDashNKeys` (entries named `Item-<n>`), `indexItemsMatchedByOrder` (items with no name of their own, in apps that have as many
///   `Item-<n>` entries as items, so that the nth item could be the nth entry), `indexItemsMatchedByRank` (the items with no name of their
///   own that the rule of `KeyMatchRule.byRank` would match on this read: the probe has no plan, so no app counts as concealed, and an
///   app with several items counts only when they are all drawn on one bar, each tied to a slot of its own) and
///   `ownPreferredPositionKeyCount`.
enum LayoutMapProbe {
    static func run(_ context: ProbeContext, _ recorder: inout ProbeRecorder) async {
        guard await GrantedFile.url(of: .menuBarLayout, in: context) != nil else {
            recorder.fail(GrantedFile.missing(.menuBarLayout))
            return
        }
        let table: LayoutTableSnapshot
        do {
            table = try await LayoutTableReader(access: context.plist, grants: context.grants).read()
        } catch {
            recorder.fail("The layout table couldn't be read: \(error.localizedDescription)")
            return
        }
        let own = context.platform.ownBundleID
        let snapshot = await context.snapshot()
        var memory = IndexMemory()
        let inventory = InventoryMatcher.match(snapshot.matchInput(ownBundleID: own), memory: &memory)
        let bars = Dictionary(snapshot.bars().map { ($0.displayUUID, $0) }, uniquingKeysWith: { first, _ in first })
        for problem in snapshot.problems { recorder.note(problem) }

        recorder.measure("tableEntries", table.distances.count)
        recorder.measure("fixtureEntries", fixtureEntries(table, inventory, context))
        recorder.measure("residuals", residuals(table, inventory, bars))
        recorder.measure("moduleKeys", .object(Dictionary(uniqueKeysWithValues: table.moduleKeys.compactMap { key -> (String, JSONValue)? in
            guard case .module(let name)? = LayoutKey.parse(key), let distance = table.distances[key] else { return nil }
            return (name, .number(distance))
        })))
        recorder.measure("appsWithMoreKeysThanItems", appsWithMoreKeysThanItems(table, inventory))
        let dashed = table.distances.keys.filter { dashNumber(ofKey: $0) != nil }.count
        recorder.measure("itemDashNKeys", dashed)
        recorder.measure("indexItemsMatchedByOrder", indexItemsMatchedByOrder(table, inventory))
        recorder.measure("indexItemsMatchedByRank", indexItemsMatchedByRank(table, inventory, ownBundleID: own))
        recorder.measure("ownPreferredPositionKeyCount", context.platform.ownPreferredPositionKeyCount())
        recorder.note("A distance is how far an item is from the bar's trailing edge; the larger it is, the further left the item is.")
    }

    // MARK: The test item's and Mantel's entries

    private static func fixtureEntries(_ table: LayoutTableSnapshot, _ inventory: Inventory, _ context: ProbeContext) -> JSONValue {
        let owners: Set<String> = [context.fixtureBundleID, context.platform.ownBundleID]
        var entries: [String: JSONValue] = [:]
        for (key, distance) in table.distances {
            guard case .status(let bundleID, let name)? = LayoutKey.parse(key), owners.contains(bundleID) else { continue }
            let item = inventory.items.first { $0.id == ItemID(bundleID: bundleID, key: .identifier(name)) }
            let slots = (item?.frames ?? [:]).mapValues(ProbeJSON.rect)
            entries[key] = .object(["distance": .number(distance), "slots": .object(slots)])
        }
        return .object(entries)
    }

    // MARK: Distances against places

    private static func residuals(_ table: LayoutTableSnapshot, _ inventory: Inventory, _ bars: [String: MenuBarGeometry]) -> JSONValue {
        var right: [String: [Double]] = [:]
        var left: [String: [Double]] = [:]
        for item in inventory.items where !item.id.isSystem {
            guard case .identifier(let name) = item.id.key,
                  let distance = table.distances[LayoutKey.status(bundleID: item.id.bundleID, autosaveName: name)] else { continue }
            for (display, slot) in item.frames where !item.overflowedOn.contains(display) {
                guard let bar = bars[display] else { continue }
                right[display, default: []].append(distance - Double(bar.rect.maxX - slot.maxX))
                left[display, default: []].append(distance - Double(bar.rect.maxX - slot.minX))
            }
        }
        var perDisplay: [String: JSONValue] = [:]
        for display in right.keys {
            perDisplay[display] = .object(["count": .number(Double(right[display]?.count ?? 0)),
                                           "barMaxX": ProbeJSON.number(bars[display].map { Double($0.rect.maxX) }),
                                           "right": summary(right[display] ?? []), "left": summary(left[display] ?? [])])
        }
        return .object(perDisplay)
    }

    /// The smallest, middle and largest of the numbers (the middle of an even number of them is the mean of the two in the middle).
    static func summary(_ numbers: [Double]) -> JSONValue {
        let sorted = numbers.sorted()
        guard let first = sorted.first, let last = sorted.last else { return .object(["min": .null, "median": .null, "max": .null]) }
        let middle = sorted.count / 2
        let median = sorted.count.isMultiple(of: 2) ? (sorted[middle - 1] + sorted[middle]) / 2 : sorted[middle]
        return .object(["min": .number(first), "median": .number(median), "max": .number(last)])
    }

    // MARK: Counts

    /// The `<n>` of an entry named `Item-<n>`; nil for any other entry.
    static func dashNumber(ofKey key: String) -> Int? {
        guard case .status(_, let name)? = LayoutKey.parse(key), name.hasPrefix("Item-") else { return nil }
        let digits = name.dropFirst("Item-".count)
        guard !digits.isEmpty, digits.allSatisfy(\.isASCII), digits.allSatisfy(\.isNumber) else { return nil }
        return Int(digits)
    }

    private static func appsWithMoreKeysThanItems(_ table: LayoutTableSnapshot, _ inventory: Inventory) -> Int {
        var count = 0
        for bundleID in inventory.appsWithItems {
            let items = inventory.items.filter { $0.ownerBundleID == bundleID && !$0.id.isSystem }.count
            if table.statusKeys(ofApp: bundleID).count > items { count += 1 }
        }
        return count
    }

    private static func indexItemsMatchedByOrder(_ table: LayoutTableSnapshot, _ inventory: Inventory) -> Int {
        var matched = 0
        for bundleID in inventory.appsWithItems {
            let items = inventory.items.filter { $0.ownerBundleID == bundleID && !$0.id.isSystem }
            let unnamed = items.filter { if case .index = $0.id.key { true } else { false } }
            let dashed = table.statusKeys(ofApp: bundleID).filter { dashNumber(ofKey: $0) != nil }
            if !unnamed.isEmpty, dashed.count == items.count { matched += unnamed.count }
        }
        return matched
    }

    /// The nameless items the resolver gives a key under `.byRank` with this table and this read, and no plan (nothing is concealed, and
    /// no app is counted as sitting among the modules that stay: the probe doesn't look for them).
    private static func indexItemsMatchedByRank(_ table: LayoutTableSnapshot, _ inventory: Inventory, ownBundleID: String) -> Int {
        var rules = LayoutRules.unmeasured
        rules.keyMatch = .byRank
        let tokens = inventory.items.compactMap { LayoutToken.drawn($0) }
        let resolution = LayoutKeyResolver.resolve(tokens: tokens, table: table, inventory: inventory, ownBundleID: ownBundleID,
                                                   rules: rules, memory: [:], concealedApps: [], stayingStart: nil)
        return resolution.keys.keys.filter { token in
            if case .item(let id) = token, case .index = id.key { true } else { false }
        }.count
    }
}
