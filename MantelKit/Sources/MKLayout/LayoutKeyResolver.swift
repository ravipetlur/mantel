import CoreGraphics
import MKCore

/// The table key of each token that has one.
public struct LayoutKeyResolution: Sendable, Equatable {
    /// Never holds a system item.
    public let keys: [LayoutToken: String]
    /// The items no key was found for: their app's order can't be written.
    public let unresolved: [ItemID]
    /// The keys matched by distance, by item, for the next resolution to start from: an item that is concealed can't be matched again, and
    /// keeps the key it had. The session keeps it.
    public let memory: [ItemID: String]
    /// The apps left alone because a key the resolution gave one of their items is among the modules that stay: every item of such an app
    /// is in `unresolved`, and none has a key.
    public let amongTheStaying: Set<String>
    /// The apps that are right of anything a write can place, so the placer doesn't treat them as obstacles: not written, with at least
    /// one key and every key among the modules that stay, and no item without a key (no named item lacks one, and under `byRank` its
    /// nameless items are as many as its keys that no named item has). Whether the key match found them doesn't matter, nor whether they
    /// are concealed. An app that has a key elsewhere too, or an item no key can be found for, stays an obstacle.
    public let outOfTheWay: Set<String>
    /// The apps of the tokens that weren't running when the read was taken (`Inventory.runningApps`: the running apps' own list, not an app's
    /// absence from the read's items; empty for a read that doesn't have one). They take no room on the bar and a write has no side of
    /// them to keep, whatever keys the table still has for them. An app is in `unresolved` or has keys as it would be if it were there;
    /// this only says it isn't.
    public let notRunning: Set<String>

    public init(keys: [LayoutToken: String], unresolved: [ItemID], memory: [ItemID: String], amongTheStaying: Set<String> = [],
                outOfTheWay: Set<String> = [], notRunning: Set<String> = []) {
        self.keys = keys
        self.unresolved = unresolved
        self.memory = memory
        self.amongTheStaying = amongTheStaying
        self.outOfTheWay = outOfTheWay
        self.notRunning = notRunning
    }
}

/// Finds the key of each token in macOS's order table.
public enum LayoutKeyResolver {
    /// - **Mantel's own tokens** (the dots, the divider, a spacer or a group's icon) are `status:<ownBundleID>::<autosave name>`, whether
    ///   the table has them yet or not: they are the ones the writer adds.
    /// - **An item with a name** is `status:<bundle ID>::<name>` when the table has it.
    /// - **An item that has none** (`.index`) is found by `rules.keyMatch`; see `KeyMatchRule`. With `byDistance`, an item that isn't drawn on
    ///   the widest bar keeps the key `memory` has for it, while the table still holds it; and with a reference of `.orderOnly` there is
    ///   nothing to compare, so no new match is made.
    /// - **With `byRank`**, an app's nameless items (the ones in `tokens` and the ones the inventory lists) are matched only when the app has
    ///   exactly as many keys in the table as nameless items, once the keys of its named items are taken out: a stale key, an item that
    ///   is hidden, or one macOS hasn't placed yet can't be told apart, so none is guessed. The same goes for an app with a named item
    ///   that has no key: which of the keys is its can't be told. One item gets its one key, drawn or not.
    ///   Several are matched by rank (left to right on the bar against the keys from the largest distance down), and only if all of them are
    ///   drawn on one bar, each in a slot of its own, the app isn't in `concealedApps` (an app the plan conceals keeps frames from where it
    ///   was last drawn, inside other icons' slots) or contested, and no two of its keys have one distance. Then each matched item that is
    ///   drawn must be on the bar on the same side of every drawn token that has a key of its own (Mantel's dots and divider, named items,
    ///   apps matched before it) as its key is in the table, or the app's items are left without a key for this resolution. A matched item
    ///   of an app in `concealedApps` or contested isn't drawn, whatever frame it has left. `memory` is not used and comes back empty.
    /// - **An app among the modules that stay** (a key the resolution gave one of its items, named or matched, at or below
    ///   `stayingStart`) is not written, whatever the rule and however its items are named: all its items are unresolved, and it stays where
    ///   macOS has it. Only the keys the resolution gives count: a stale key the app also has elsewhere in the table doesn't. A key at the
    ///   very distance of the module can't be told from either side, and counts as among. The modules that come and go (Now Playing,
    ///   AirDrop, Display, Focus, Screen Mirroring and the camera and microphone indicator, `LayoutKey.comingAndGoingModules`) never make an
    ///   app among them: a write places the apps left of them.
    /// - A system item never has a key, and isn't unresolved either.
    ///
    /// `concealedApps` is the apps the plan in force doesn't draw: the caller knows the plan, and the resolver stays pure. `stayingStart` is
    /// the distance of the left-most drawn module that stays (`LayoutMath.stayingModulesStart`), nil when no app is to be left alone for it.
    /// `earlierKeys` is what an earlier try of the same write matched: under `byRank`, an app whose nameless items all have one keeps it
    /// (the bar may have moved since, and no new match is made from it); the rest of the rule still applies.
    public static func resolve(tokens: [LayoutToken], table: LayoutTableSnapshot, inventory: Inventory, ownBundleID: String,
                               rules: LayoutRules, memory: [ItemID: String], concealedApps: Set<String>, stayingStart: Double?,
                               earlierKeys: [ItemID: String] = [:]) -> LayoutKeyResolution {
        var keys: [LayoutToken: String] = [:]
        var unresolved: [ItemID] = []
        var indexed: [String: [ItemID]] = [:]
        var namedKeys: [String: Set<String>] = [:]
        var namedWithoutKey: Set<String> = []
        var tokensOfApp: [String: [ItemID]] = [:]

        func own(_ name: String) -> String {
            LayoutKey.status(bundleID: ownBundleID, autosaveName: name)
        }
        for token in tokens {
            switch token {
            case .dot(.hidden): keys[token] = own(OwnItems.hiddenDotName)
            case .dot(.always): keys[token] = own(OwnItems.alwaysDotName)
            case .divider: keys[token] = own(OwnItems.dividerName)
            case .item(let id):
                if id.isSystem { continue }
                if let name = OwnItems.autosaveName(of: id) {
                    keys[token] = own(name)
                    continue
                }
                if id.bundleID == OwnItems.owner { continue }
                if case .system = id.key { continue }
                tokensOfApp[id.bundleID, default: []].append(id)
                switch id.key {
                case .identifier(let name):
                    let key = LayoutKey.status(bundleID: id.bundleID, autosaveName: name)
                    namedKeys[id.bundleID, default: []].insert(key)
                    if table.distances[key] != nil {
                        keys[token] = key
                    } else {
                        unresolved.append(id)
                        namedWithoutKey.insert(id.bundleID)
                    }
                case .index:
                    indexed[id.bundleID, default: []].append(id)
                case .system:
                    continue
                }
            }
        }

        var newMemory: [ItemID: String] = [:]
        switch rules.keyMatch {
        case .identifiersOnly:
            unresolved += indexed.values.joined()
        case .autosaveIndex(let prefix):
            for id in indexed.values.joined() {
                guard case .index(let n) = id.key else { continue }
                let key = LayoutKey.status(bundleID: id.bundleID, autosaveName: prefix + String(n))
                if table.distances[key] != nil { keys[.item(id)] = key } else { unresolved.append(id) }
            }
        case .byDistance(let tolerance):
            for (bundleID, ids) in indexed {
                let matched = matchByDistance(app: bundleID, ids: ids, table: table, inventory: inventory, rules: rules,
                                              tolerance: tolerance, memory: memory)
                for id in ids {
                    if let key = matched[id] {
                        keys[.item(id)] = key
                        newMemory[id] = key
                    } else {
                        unresolved.append(id)
                    }
                }
            }
        case .byRank:
            // In the order of the bundle IDs: an app is checked against the apps matched before it.
            for bundleID in indexed.keys.sorted() {
                let ids = indexed[bundleID] ?? []
                let matched = matchByRank(app: bundleID, tokenIDs: ids, namedKeys: namedKeys[bundleID] ?? [],
                                          hasNamedWithoutKey: namedWithoutKey.contains(bundleID), table: table, inventory: inventory,
                                          concealedApps: concealedApps, earlierKeys: earlierKeys, keys: keys)
                for id in ids {
                    if let key = matched?[id] { keys[.item(id)] = key } else { unresolved.append(id) }
                }
            }
        }

        // An app with a key among the modules that stay is left alone, whole: Mantel never moves an icon there. The memory it had stays:
        // that is not a write.
        var among: Set<String> = []
        var outOfTheWay: Set<String> = []
        if let stayingStart {
            func isAmong(_ key: String) -> Bool { table.distances[key].map { $0 <= stayingStart } ?? false }
            for (bundleID, ids) in tokensOfApp {
                if ids.contains(where: { id in keys[.item(id)].map(isAmong) ?? false }) {
                    for id in ids {
                        keys[.item(id)] = nil
                        unresolved.append(id)
                    }
                    among.insert(bundleID)
                }
                // Right of anything a write can place, whether or not the key match found the app's keys: every key it has is among the
                // modules that stay, and every item of it has one (an item with none may be drawn anywhere).
                let appKeys = table.statusKeys(ofApp: bundleID)
                guard !appKeys.isEmpty, appKeys.allSatisfy(isAmong), ids.allSatisfy({ keys[.item($0)] == nil }) else { continue }
                let (nameless, named) = itemsOfApp(bundleID, tokenIDs: ids, namedKeys: namedKeys[bundleID] ?? [], inventory: inventory)
                guard named.allSatisfy({ table.distances[$0] != nil }) else { continue }
                if case .byRank = rules.keyMatch, appKeys.filter({ !named.contains($0) }).count != nameless.count { continue }
                outOfTheWay.insert(bundleID)
            }
        }
        // From the apps that were running when the read was taken; a read that doesn't say (`runningApps` nil) says no app isn't.
        let notRunning = inventory.runningApps.map { running in Set(tokensOfApp.keys.filter { !running.contains($0) }) } ?? []
        return LayoutKeyResolution(keys: keys, unresolved: Array(Set(unresolved)).sorted { $0.string < $1.string }, memory: newMemory,
                                   amongTheStaying: among, outOfTheWay: outOfTheWay, notRunning: notRunning)
    }

    /// How close a frame is to a slot's for the slot to be the one it was tied to: the matcher gives an item the slot's own frame.
    private static let slotTolerance: CGFloat = 0.5

    /// An app's nameless items and the table keys of its named ones, from its tokens and from the inventory's list: the union of both.
    private static func itemsOfApp(_ bundleID: String, tokenIDs: [ItemID], namedKeys: Set<String>,
                                   inventory: Inventory) -> (nameless: Set<ItemID>, named: Set<String>) {
        var nameless = Set(tokenIDs)
        var named = namedKeys
        for item in inventory.items(ofApp: bundleID) {
            switch item.id.key {
            case .index: nameless.insert(item.id)
            case .identifier(let name): named.insert(LayoutKey.status(bundleID: bundleID, autosaveName: name))
            case .system: continue
            }
        }
        return (nameless, named)
    }

    /// The keys of one app's nameless items by count and rank (see `resolve`), or nil when none is matched. `keys` holds what has a key
    /// so far: the tokens the cross-check compares against.
    private static func matchByRank(app bundleID: String, tokenIDs: [ItemID], namedKeys: Set<String>, hasNamedWithoutKey: Bool,
                                    table: LayoutTableSnapshot, inventory: Inventory, concealedApps: Set<String>,
                                    earlierKeys: [ItemID: String], keys: [LayoutToken: String]) -> [ItemID: String]? {
        let items = Dictionary(inventory.items(ofApp: bundleID).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let (nameless, named) = itemsOfApp(bundleID, tokenIDs: tokenIDs, namedKeys: namedKeys, inventory: inventory)
        guard !nameless.isEmpty, !hasNamedWithoutKey else { return nil }
        // An earlier try of this write matched all of them: they keep their keys while the table still has them.
        if nameless.allSatisfy({ earlierKeys[$0].map { table.distances[$0] != nil } ?? false }) {
            return Dictionary(uniqueKeysWithValues: tokenIDs.compactMap { id in earlierKeys[id].map { (id, $0) } })
        }
        let candidates = table.statusKeys(ofApp: bundleID).filter { !named.contains($0) }
        guard candidates.count == nameless.count else { return nil }

        var matched: [ItemID: String] = [:]
        if nameless.count == 1, let id = nameless.first, let key = candidates.first {
            matched[id] = key
        } else {
            guard !concealedApps.contains(bundleID), !inventory.contestedApps.contains(bundleID),
                  let leftToRight = drawnOrder(of: nameless, items: items, inventory: inventory) else { return nil }
            let distances = candidates.compactMap { key in table.distances[key].map { (key: key, distance: $0) } }
            guard distances.count == candidates.count, Set(distances.map(\.distance)).count == distances.count else { return nil }
            let furthestLeftFirst = distances.sorted { $0.distance > $1.distance }
            for (id, entry) in zip(leftToRight, furthestLeftFirst) { matched[id] = entry.key }
        }
        guard sitsOnTheSameSides(matched, items: items, table: table, inventory: inventory, concealedApps: concealedApps, keys: keys) else {
            return nil
        }
        return matched
    }

    /// The items left to right on one bar when every one of them is drawn there: a frame that is a slot of the bar (the one the matcher
    /// tied it to), not in the overflow, each in a slot of its own. Nil when there is no such bar, or when two bars that qualify disagree.
    private static func drawnOrder(of ids: Set<ItemID>, items: [ItemID: MenuBarItem], inventory: Inventory) -> [ItemID]? {
        var order: [ItemID]?
        for display in inventory.barSlots.keys.sorted() {
            var slotOf: [ItemID: Int] = [:]
            for id in ids {
                guard let item = items[id], let index = tiedSlot(of: item, on: display, inventory: inventory) else { break }
                slotOf[id] = index
            }
            guard slotOf.count == ids.count, Set(slotOf.values).count == ids.count else { continue }
            let here = ids.sorted { slotOf[$0]! < slotOf[$1]! }
            if let order, order != here { return nil }
            order = here
        }
        return order
    }

    /// The position in the display's list of slots of the one the item's frame there is tied to; nil when the item has no frame there, is in
    /// the overflow there, or its frame is no slot's.
    private static func tiedSlot(of item: MenuBarItem, on display: String, inventory: Inventory) -> Int? {
        guard !item.overflowedOn.contains(display), let frame = item.frames[display], let slots = inventory.barSlots[display] else { return nil }
        return slots.firstIndex { slot in
            abs(slot.frame.minX - frame.minX) <= slotTolerance && abs(slot.frame.minY - frame.minY) <= slotTolerance
                && abs(slot.frame.width - frame.width) <= slotTolerance && abs(slot.frame.height - frame.height) <= slotTolerance
        }
    }

    /// Whether each matched item that is drawn is on the bar on the same side of every drawn token that has a key (and a distance) as its
    /// key is in the table. A token on the same distance as the key can't be told from either side, and counts against it. A token of an
    /// app the plan conceals, or of a contested app, isn't believed to be where its frame says.
    private static func sitsOnTheSameSides(_ matched: [ItemID: String], items: [ItemID: MenuBarItem], table: LayoutTableSnapshot,
                                           inventory: Inventory, concealedApps: Set<String>, keys: [LayoutToken: String]) -> Bool {
        var anchors: [(item: MenuBarItem, distance: Double)] = []
        for other in inventory.items {
            guard let token = LayoutToken.drawn(other), let key = keys[token], let distance = table.distances[key],
                  !concealedApps.contains(other.ownerBundleID), !inventory.contestedApps.contains(other.ownerBundleID) else { continue }
            anchors.append((other, distance))
        }
        for (id, key) in matched {
            guard let item = items[id], let distance = table.distances[key] else { continue }
            // An app that isn't drawn has no place on the bar to check, whatever frame it was left with.
            guard !concealedApps.contains(item.ownerBundleID), !inventory.contestedApps.contains(item.ownerBundleID) else { continue }
            for display in item.frames.keys {
                guard let frame = item.frames[display], tiedSlot(of: item, on: display, inventory: inventory) != nil else { continue }
                for anchor in anchors {
                    guard let there = anchor.item.frames[display], !anchor.item.overflowedOn.contains(display) else { continue }
                    guard distance != anchor.distance, (distance > anchor.distance) == (frame.midX < there.midX) else { return false }
                }
            }
        }
        return true
    }

    /// The keys of one app's nameless items. The app's keys that no named item has are matched to its slots on the widest bar, the smallest
    /// difference first, each key and each slot once. An item that isn't drawn on that bar keeps its remembered key (every item does
    /// when the rules have no distances to compare).
    private static func matchByDistance(app bundleID: String, ids: [ItemID], table: LayoutTableSnapshot, inventory: Inventory,
                                        rules: LayoutRules, tolerance: CGFloat, memory: [ItemID: String]) -> [ItemID: String] {
        let bar = inventory.bars.max { $0.rect.width < $1.rect.width }
        let items = Dictionary(inventory.items(ofApp: bundleID).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        var drawn: [ItemID: CGFloat] = [:]
        if let bar, rules.reference != .orderOnly {
            for id in ids {
                guard let item = items[id], !item.overflowedOn.contains(bar.displayUUID), let frame = item.frames[bar.displayUUID] else { continue }
                drawn[id] = rules.reference == .leftEdge ? bar.rect.maxX - frame.minX : bar.rect.maxX - frame.maxX
            }
        }
        let drawnHere: Set<ItemID> = bar.map { bar in
            Set(ids.filter { id in
                guard let item = items[id] else { return false }
                return !item.overflowedOn.contains(bar.displayUUID) && item.frames[bar.displayUUID] != nil
            })
        } ?? []

        var result: [ItemID: String] = [:]
        // What the concealed items keep is taken out of what the drawn ones can be matched to. With nothing to compare (`.orderOnly`) no item
        // is matched anew, so every item keeps what it had, drawn or not.
        var taken: Set<String> = []
        for id in ids where rules.reference == .orderOnly || !drawnHere.contains(id) {
            if let key = memory[id], table.distances[key] != nil, taken.insert(key).inserted { result[id] = key }
        }
        let named = Set(inventory.items(ofApp: bundleID).compactMap { item -> String? in
            guard case .identifier(let name) = item.id.key else { return nil }
            return LayoutKey.status(bundleID: bundleID, autosaveName: name)
        })
        let candidates = table.statusKeys(ofApp: bundleID).filter { !named.contains($0) && !taken.contains($0) }
        var pairs: [(id: ItemID, key: String, difference: CGFloat)] = []
        for (id, expected) in drawn {
            for key in candidates {
                guard let distance = table.distances[key] else { continue }
                let difference = abs(CGFloat(distance) - expected)
                if difference <= tolerance { pairs.append((id, key, difference)) }
            }
        }
        pairs.sort { ($0.difference, $0.key, $0.id.string) < ($1.difference, $1.key, $1.id.string) }
        var usedKeys: Set<String> = []
        for pair in pairs where result[pair.id] == nil && usedKeys.insert(pair.key).inserted {
            result[pair.id] = pair.key
        }
        return result
    }
}
