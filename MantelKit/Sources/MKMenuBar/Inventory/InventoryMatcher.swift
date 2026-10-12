import CoreGraphics
import Foundation
import MKCore

/// A display's menu bar as MenuBarAgent's chosen window gives it.
struct MatchBar: Sendable, Equatable {
    let displayUUID: String
    /// The window's frame, CoreGraphics global points.
    let rect: CGRect
    let slots: [AgentSlot]
}

/// Everything the matcher needs, read once: the bars, what each app says it has, and what the read itself found out.
struct MatchInput: Sendable {
    var capturedAt: Date
    var layout: DisplayLayout
    var bars: [MatchBar]
    /// The apps that answered. An app that timed out says nothing about its items, so it isn't here.
    var apps: [AppExtras]
    var ownBundleID: String
    var reach: [AppReach] = []
    var problems: [InventoryProblem] = []
    /// The apps the plan in force conceals. What an app that is concealed says of where its icons are is out of date (an app's own
    /// frames often stay where they were when it is hidden, or are the last x at a place that can be on another display's bar): its frames
    /// claim a slot only when no app that isn't concealed has it, and are not judged as places (`BarRegion`).
    var concealedApps: Set<String> = []
}

/// What the matcher remembers between reads, so that an item keeps its ID while it can't be seen.
///
/// - **Order:** an item with no name of its own is told by its place among its app's items from left to right. That is only
///   known while they are all on a bar, so the order is kept by the item's position in its app's list of items, and used while the
///   app is concealed.
/// - **Slot names:** the name an item had on its slot when its app's own list didn't give one.
struct IndexMemory: Sendable, Equatable {
    private var orders: [String: [Int: Int]] = [:]
    private var slotNames: [String: [Int: String]] = [:]

    init() {}

    /// The remembered order of an app's items, when it covers exactly these positions in the app's list.
    func order(ofApp bundleID: String, covering positions: Set<Int>) -> [Int: Int]? {
        guard let order = orders[bundleID], Set(order.keys) == positions else { return nil }
        return order
    }

    mutating func remember(order: [Int: Int], ofApp bundleID: String) {
        orders[bundleID] = order
    }

    func slotName(ofApp bundleID: String, at position: Int) -> String? {
        slotNames[bundleID]?[position]
    }

    mutating func remember(slotName: String, ofApp bundleID: String, at position: Int) {
        slotNames[bundleID, default: [:]][position] = slotName
    }
}

/// Turns what was read into an `Inventory`: one entry for each item, with where it is on every display.
///
/// - **Slots** (MenuBarAgent's, per display) are sorted by where they are; the order Accessibility lists them in means nothing.
/// - **An app's item** belongs to the slot its frame is in (the frame is about 6 points inside the slot, so the center is inside
///   it; a frame can be a few points wider than the slot, `widthTolerance`). The closest pairs of frame and slot are made first, and no
///   app's frame claims the slot of a system module. A frame that is in no slot is concealed, and isn't kept: macOS reports a stale
///   one for an item it isn't drawing.
/// - **System items** are told by their identifier (`com.apple.menuextra.<module>`), on the slot or on the app's own item.
/// - **Every display draws the same items.** The slots on another display are the same item when they carry the same identifier as
///   one that was matched (unless the identifier is AppKit's own, repeats on a bar, or two apps' slots share it); for the rest, by
///   their order (`BarAlignment`), and only where the stretch between two known items has as many slots, as wide, on both. A slot
///   that is none of these (an app's, a name, a place) is left out, counted, and reported in `Inventory.untiedSlots`: it is never
///   guessed. The exception is the slots in a bar's overflow where the alignment has found the pile's items (the items left of the
///   part that was lined up, as many as it has slots), though not which slot is which: they are accounted for, and are neither
///   counted nor reported.
/// - **Concealed is not overflowed.** A slot with no frame is in a display's overflow only if its item has a frame on another display.
/// - **An app that the plan conceals is believed last** (`MatchInput.concealedApps`): its frames are the last it had, and can be
///   anywhere, a bar that is below the main display among them. They claim a slot only when no other app's frame has it (it may be
///   drawn still, as an engine that hasn't hidden it yet leaves it), and what they say is kept as a place only to be told from what they
///   say later (`BarRegion` doesn't judge them).
/// - **An item that says it is where the bar has no slot** (`MenuBarItem.strayFrames`) is not drawn there: MenuBarAgent draws an item in a
///   slot. One that macOS has put out of the way (in the « menu, behind the notch, under the app's menus) reports the place it would have,
///   which is on the bar and in none of its slots. Which of those places are out of the way is `BarRegion`'s to say, with the menus the
///   front app has. A concealed item is off every bar, and so isn't one of these.
/// - **The dots in the « menu.** A dot (`MenuBarItem.isDot`) with such a place on a bar that has a « is in that bar's overflow: a « on the
///   bar says there is a pile, and the dots are never concealed. So is one with such a place in the gap right of a notch, left of the first
///   icon that is drawn, though no « is listed (macOS 27 never lists it); that one is told by a place, and is `inferred`.
enum InventoryMatcher {
    /// How far outside a slot an app's frame may be centered and still belong to it.
    private static let slotOutset: CGFloat = 1

    static func match(_ input: MatchInput, memory: inout IndexMemory) -> Inventory {
        matchCounting(input, memory: &memory).inventory
    }

    /// What `match` made, and what it left out.
    struct MatchResult {
        let inventory: Inventory
        /// How many slots matched no app and were left out (not the ones in a pile that the alignment accounted for).
        let unmatchedSlots: Int
        /// How many stretches of a bar couldn't be lined up with the same stretch of the reference bar, and were left untied.
        let segmentsNotAligned: Int
    }

    static func matchCounting(_ input: MatchInput, memory: inout IndexMemory) -> MatchResult {
        let bars = input.bars.map { prepare($0, layout: input.layout) }
        let entries = entries(of: input.apps)

        // First, an app's frame goes to the slot it is inside, one slot to one frame.
        var claimed: [SlotRef: Int] = [:]  // slot → position in `entries`
        // The frames of the apps that aren't concealed claim first: a concealed app's frame can lie in a slot of someone else's.
        let isConcealed: (Int) -> Bool = { input.concealedApps.contains(entries[$0].bundleID) }
        for group in [entries.indices.filter { !isConcealed($0) }, entries.indices.filter(isConcealed)] {
            claimSlots(for: group, entries: entries, bars: bars, claimed: &claimed)
        }
        var claimsOnBar = Array(repeating: 0, count: bars.count)
        for slot in claimed.keys { claimsOnBar[slot.bar] += 1 }

        // Then the same item on another display, told by the slot's own identifier. A name that is on one bar twice, or that two
        // apps' slots share (AppKit gives every app's first item the same one), says nothing of whose it is, and ties nothing.
        var namesOnBar: [Int: [String: Int]] = [:]
        for (barIndex, bar) in bars.enumerated() {
            for slot in bar.slots {
                if let name = ItemID.usableIdentifier(slot.identifier) { namesOnBar[barIndex, default: [:]][name, default: 0] += 1 }
            }
        }
        let repeatedNames = Set(namesOnBar.values.flatMap { $0.filter { $0.value > 1 }.keys })
        var entryOfSlotName: [String: Int] = [:]
        var sharedNames: Set<String> = []
        for slot in claimed.keys.sorted() {
            guard let name = ItemID.usableIdentifier(bars[slot.bar].slots[slot.position].identifier),
                  ItemID.systemModule(ofIdentifier: name) == nil, !repeatedNames.contains(name), let entryIndex = claimed[slot] else { continue }
            if let known = entryOfSlotName[name], known != entryIndex, entries[known].bundleID != entries[entryIndex].bundleID {
                sharedNames.insert(name)
            } else {
                entryOfSlotName[name] = entryOfSlotName[name] ?? entryIndex
            }
        }
        for name in sharedNames { entryOfSlotName[name] = nil }
        for (barIndex, bar) in bars.enumerated() {
            for (position, slot) in bar.slots.enumerated() {
                let ref = SlotRef(bar: barIndex, position: position)
                guard claimed[ref] == nil, let name = ItemID.usableIdentifier(slot.identifier), let entryIndex = entryOfSlotName[name],
                      !claimed.contains(where: { $0.value == entryIndex && $0.key.bar == barIndex }) else { continue }
                claimed[ref] = entryIndex
            }
        }

        // Last, what is left, by where it is: the same items are in the same order on every display.
        let alignment = align(bars, claimsOnBar: claimsOnBar, claimed: &claimed)

        var systemSlots: [SlotRef] = []
        var unmatched = 0
        var untied: [String: [CGRect]] = [:]
        for (barIndex, bar) in bars.enumerated() {
            for (position, slot) in bar.slots.enumerated() {
                let ref = SlotRef(bar: barIndex, position: position)
                guard claimed[ref] == nil else { continue }
                if let name = slot.identifier, ItemID.systemModule(ofIdentifier: name) != nil {
                    systemSlots.append(ref)
                    continue
                }
                if alignment.accountedSlots.contains(ref) { continue }  // in a pile whose items the alignment named, as a set
                unmatched += 1
                if let frame = slot.frame, frame.width > 0 { untied[bar.geometry.displayUUID, default: []].append(frame) }
            }
        }
        var slotsOfEntry: [Int: [SlotRef]] = [:]
        for (slot, entryIndex) in claimed { slotsOfEntry[entryIndex, default: []].append(slot) }
        for entryIndex in slotsOfEntry.keys { slotsOfEntry[entryIndex]?.sort() }
        var overflowedOnBar: [Int: Set<String>] = [:]  // entry → displays where it is known to be in the overflow, with no slot there
        for mark in alignment.overflowMarks { overflowedOnBar[mark.entry, default: []].insert(bars[mark.bar].geometry.displayUUID) }

        var built: [String: Built] = [:]  // by the text of the ID

        // System items: a slot that names one, and an app's item that names itself as one.
        for ref in systemSlots {
            if let module = ItemID.systemModule(ofIdentifier: bars[ref.bar].slots[ref.position].identifier ?? "") {
                place(ItemID.system(module), at: ref, in: bars, owner: ItemID.systemBundleID, appName: nil, isMantel: false, into: &built)
            }
        }
        var systemEntries: Set<Int> = []
        for (entryIndex, entry) in entries.enumerated() {
            let slots = slotsOfEntry[entryIndex] ?? []
            let module = slots.lazy.compactMap { ItemID.systemModule(ofIdentifier: bars[$0.bar].slots[$0.position].identifier ?? "") }.first
                ?? ItemID.systemModule(ofIdentifier: entry.item.identifier ?? "")
            guard let module else { continue }
            systemEntries.insert(entryIndex)
            let id = ItemID.system(module)
            ensure(id, owner: ItemID.systemBundleID, appName: nil, isMantel: false, into: &built)
            for ref in slots { place(id, at: ref, in: bars, owner: ItemID.systemBundleID, appName: nil, isMantel: false, into: &built) }
        }

        // An app's items: named, or told by their place.
        let appEntries = entries.indices.filter { !systemEntries.contains($0) }
        for (bundleID, group) in Dictionary(grouping: appEntries, by: { entries[$0].bundleID }) {
            addApp(bundleID: bundleID, entryIndices: group.sorted(), entries: entries, slotsOfEntry: slotsOfEntry, bars: bars,
                   overflowedOnBar: overflowedOnBar, ownBundleID: input.ownBundleID, memory: &memory, into: &built)
        }

        // An item that is framed nowhere isn't drawn at all: it is concealed, and not in the overflow of the displays whose slots it
        // has no frame in.
        for (key, item) in built where item.frames.isEmpty && !item.overflowedOn.isEmpty { built[key]?.overflowedOn = [] }
        // An icon of Mantel's that is in the « menu has no frame on that bar either, and is in its overflow all the same.
        // Not on a bar where the icon has a slot (the slot is what the bar shows; a frame that says otherwise is out of date).
        for (key, item) in built where !item.inMenuOn.isEmpty {
            built[key]?.overflowedOn.formUnion(item.inMenuOn.subtracting(item.frames.keys))
        }
        // A dot in the gap between the notch and the first icon that is drawn: told by where it is, and said so.
        for (key, item) in built where !item.inGapOn.isEmpty {
            let displays = item.inGapOn.subtracting(item.frames.keys)
            built[key]?.overflowedOn.formUnion(displays)
            built[key]?.inferredOn.formUnion(displays)
        }

        let mainUUID = input.layout.main?.uuid ?? bars.first?.geometry.displayUUID
        let items = ordered(built.values.map(\.item), mainUUID: mainUUID, displayOrder: bars.map(\.geometry.displayUUID))
        var chevrons: [String: CGRect] = [:]
        for bar in bars { chevrons[bar.geometry.displayUUID] = bar.chevron }
        let unanswered = Set(input.reach.filter { $0.status == .timedOut || $0.status == .skipped }.map(\.bundleID))
        let inventory = Inventory(capturedAt: input.capturedAt, bars: bars.map(\.geometry), items: items, chevrons: chevrons,
                                  reach: input.reach, problems: input.problems, unansweredApps: unanswered, untiedSlots: untied)
        return MatchResult(inventory: inventory, unmatchedSlots: unmatched, segmentsNotAligned: alignment.segmentsNotAligned)
    }

    // MARK: Entries

    /// The apps' items in an order that doesn't depend on how they were read: by bundle ID, then by the order the app lists them.
    /// An app that runs as several processes is one app, and its items follow one another.
    private static func entries(of apps: [AppExtras]) -> [Entry] {
        var entries: [Entry] = []
        for (bundleID, group) in Dictionary(grouping: apps.filter { $0.bundleID != nil }, by: { $0.bundleID ?? "" }) {
            var position = 0
            for app in group.sorted(by: { $0.pid < $1.pid }) {
                for item in app.items.sorted(by: { $0.index < $1.index }) {
                    entries.append(Entry(bundleID: bundleID, appName: app.name, position: position, item: item))
                    position += 1
                }
            }
        }
        return entries.sorted { ($0.bundleID, $0.position) < ($1.bundleID, $1.position) }
    }

    // MARK: Building items

    private static func ensure(_ id: ItemID, owner: String, appName: String?, isMantel: Bool, into built: inout [String: Built]) {
        if built[id.string] == nil { built[id.string] = Built(id: id, ownerBundleID: owner, appName: appName, isMantel: isMantel) }
    }

    /// Puts the item on the bar the slot is on: its frame there, and whether it is overflowed there. The first slot of a display
    /// is the one that counts.
    private static func place(_ id: ItemID, at ref: SlotRef, in bars: [PreparedBar], owner: String, appName: String?, isMantel: Bool,
                              label: String? = nil, into built: inout [String: Built]) {
        ensure(id, owner: owner, appName: appName, isMantel: isMantel, into: &built)
        let bar = bars[ref.bar]
        let uuid = bar.geometry.displayUUID
        guard var item = built[id.string], !item.displays.contains(uuid) else { return }
        item.displays.insert(uuid)
        let slot = bar.slots[ref.position]
        if let frame = slot.frame, frame.width > 0 { item.frames[uuid] = frame }
        if bar.overflowed.contains(ref.position) { item.overflowedOn.insert(uuid) }
        item.label = item.label ?? label ?? nonEmpty(slot.description)
        built[id.string] = item
    }

    private static func addApp(bundleID: String, entryIndices: [Int], entries: [Entry], slotsOfEntry: [Int: [SlotRef]],
                               bars: [PreparedBar], overflowedOnBar: [Int: Set<String>], ownBundleID: String,
                               memory: inout IndexMemory, into built: inout [String: Built]) {
        func isShown(_ entryIndex: Int) -> Bool {
            (slotsOfEntry[entryIndex] ?? []).contains { bars[$0.bar].slots[$0.position].frame != nil }
        }

        // What each item is called: by its app, else by its slot, else by what its slot was called when it was last seen.
        var names: [Int: String] = [:]
        for index in entryIndices {
            let entry = entries[index]
            if let own = ItemID.usableIdentifier(unprefixed(entry.item.identifier, bundleID: bundleID)) {
                names[index] = own
            } else if let slotName = slotName(of: slotsOfEntry[index] ?? [], bundleID: bundleID, in: bars) {
                names[index] = slotName
                memory.remember(slotName: slotName, ofApp: bundleID, at: entry.position)
            } else if let remembered = memory.slotName(ofApp: bundleID, at: entry.position) {
                names[index] = remembered
            }
        }
        // A name that two of an app's items share names neither of them.
        let counts = Dictionary(names.values.map { ($0, 1) }, uniquingKeysWith: +)
        for (index, name) in names where counts[name, default: 0] > 1 { names[index] = nil }

        // The others are told by their place from left to right, which is only known while they are all on a bar.
        let unnamed = entryIndices.filter { names[$0] == nil }
        var indexOf: [Int: Int] = [:]
        if !unnamed.isEmpty {
            let positions = Set(unnamed.map { entries[$0].position })
            if unnamed.allSatisfy(isShown) {
                var order: [Int: Int] = [:]
                let byPlace = unnamed.sorted { placeKey(of: $0, slotsOfEntry, bars, entries) < placeKey(of: $1, slotsOfEntry, bars, entries) }
                for (rank, entryIndex) in byPlace.enumerated() {
                    indexOf[entryIndex] = rank
                    order[entries[entryIndex].position] = rank
                }
                memory.remember(order: order, ofApp: bundleID)
            } else if let remembered = memory.order(ofApp: bundleID, covering: positions) {
                for entryIndex in unnamed { indexOf[entryIndex] = remembered[entries[entryIndex].position] }
            } else {
                for (rank, entryIndex) in unnamed.sorted(by: { entries[$0].position < entries[$1].position }).enumerated() {
                    indexOf[entryIndex] = rank
                }
            }
        }

        // Dots that report one and the same frame: a frame is one icon's, so they are out of date (a display change moves the icons, and
        // what they say of where they are is for a moment what it was). Nothing is made of the places of either.
        let dots = entryIndices.filter { bundleID == ownBundleID && DotsCopy.isDot(name: names[$0], description: entries[$0].item.description) }
        var sharing: Set<Int> = []
        for (offset, first) in dots.enumerated() {
            for second in dots.dropFirst(offset + 1) {
                guard let one = entries[first].item.frame, let two = entries[second].item.frame, !one.isEmpty, sameFrame(one, two) else { continue }
                sharing.formUnion([first, second])
            }
        }

        for entryIndex in entryIndices {
            let entry = entries[entryIndex]
            let key: ItemID.Key = names[entryIndex].map(ItemID.Key.identifier) ?? .index(indexOf[entryIndex] ?? entry.position)
            let id = ItemID(bundleID: bundleID, key: key)
            let label = nonEmpty(entry.item.title) ?? nonEmpty(entry.item.description)
            let isMantel = bundleID == ownBundleID
            ensure(id, owner: bundleID, appName: entry.appName, isMantel: isMantel, into: &built)
            if let label, built[id.string]?.label == nil { built[id.string]?.label = label }
            for ref in slotsOfEntry[entryIndex] ?? [] {
                place(id, at: ref, in: bars, owner: bundleID, appName: entry.appName, isMantel: isMantel, label: label, into: &built)
            }
            if let marked = overflowedOnBar[entryIndex] { built[id.string]?.overflowedOn.formUnion(marked) }
            let isDot = isMantel && DotsCopy.isDot(name: names[entryIndex], description: entry.item.description)
            built[id.string]?.isDot = isDot
            if let frame = entry.item.frame, frame.width > 0 { built[id.string]?.reportedWidth = frame.width }
            if sharing.contains(entryIndex), let frame = entry.item.frame {
                built[id.string]?.sharesFrameOn = Set(bars.filter { $0.geometry.rect.insetBy(dx: -barOutset, dy: -barOutset).contains(frame) }
                    .map(\.geometry.displayUUID))
            } else if let frame = entry.item.frame, !frame.isEmpty {
                for bar in bars where isStray(frame, on: bar) {
                    let uuid = bar.geometry.displayUUID
                    built[id.string]?.strays[uuid] = frame
                    if isDot, bar.chevron != nil {
                        built[id.string]?.inMenuOn.insert(uuid)
                    } else if isDot, isInTheGap(frame, on: bar) {
                        built[id.string]?.inGapOn.insert(uuid)
                    }
                }
            }
        }
    }

    /// A name without the app's layout key in front of it: the layout names an item `<bundle ID>::<name>`, and the name is what
    /// follows. (An identifier that has no such prefix is returned as it is.)
    private static func unprefixed(_ name: String?, bundleID: String) -> String? {
        guard var name else { return nil }
        if name.hasPrefix(bundleID + "::") { name = String(name.dropFirst(bundleID.count + 2)) }
        return name
    }

    /// The name an item has on its slot, when its app's own list gives it none.
    private static func slotName(of slots: [SlotRef], bundleID: String, in bars: [PreparedBar]) -> String? {
        for slot in slots {
            if let usable = ItemID.usableIdentifier(unprefixed(bars[slot.bar].slots[slot.position].identifier, bundleID: bundleID)) {
                return usable
            }
        }
        return nil
    }

    /// Where an item is, for putting an app's items in order: the display it is on (in the order of the bars), then its x, then
    /// where its app lists it.
    private static func placeKey(of entryIndex: Int, _ slotsOfEntry: [Int: [SlotRef]], _ bars: [PreparedBar], _ entries: [Entry])
        -> PlaceKey {
        let framed = (slotsOfEntry[entryIndex] ?? []).filter { bars[$0.bar].slots[$0.position].frame != nil }
        guard let first = framed.min(), let frame = bars[first.bar].slots[first.position].frame else {
            return PlaceKey(display: Int.max, x: 0, position: entries[entryIndex].position)
        }
        return PlaceKey(display: first.bar, x: frame.minX, position: entries[entryIndex].position)
    }

    private struct PlaceKey: Comparable {
        let display: Int
        let x: CGFloat
        let position: Int

        static func < (a: PlaceKey, b: PlaceKey) -> Bool {
            (a.display, a.x, a.position) < (b.display, b.x, b.position)
        }
    }

    // MARK: Ordering

    /// The items on the main display by x; then those that are only on another display; then the concealed ones, by app.
    private static func ordered(_ items: [MenuBarItem], mainUUID: String?, displayOrder: [String]) -> [MenuBarItem] {
        func firstPlace(_ item: MenuBarItem) -> (Int, CGFloat, String) {
            for (rank, uuid) in displayOrder.enumerated() {
                if let frame = item.frames[uuid] { return (rank, frame.minX, item.id.string) }
            }
            return (Int.max, 0, item.id.string)
        }
        func concealedKey(_ item: MenuBarItem) -> (String, Int, Int, String) {
            switch item.id.key {
            case .identifier: (item.ownerBundleID, 0, 0, item.id.string)
            case .index(let index): (item.ownerBundleID, 1, index, item.id.string)
            case .system: (item.ownerBundleID, 2, 0, item.id.string)
            }
        }
        var onMain: [MenuBarItem] = []
        var elsewhere: [MenuBarItem] = []
        var concealed: [MenuBarItem] = []
        for item in items {
            if let mainUUID, item.frames[mainUUID] != nil {
                onMain.append(item)
            } else if item.frames.isEmpty {
                concealed.append(item)
            } else {
                elsewhere.append(item)
            }
        }
        onMain.sort { firstPlace($0) < firstPlace($1) }
        elsewhere.sort { firstPlace($0) < firstPlace($1) }
        concealed.sort { concealedKey($0) < concealedKey($1) }
        return onMain + elsewhere + concealed
    }

    // MARK: Slots

    /// A slot's place among the slots of every bar.
    struct SlotRef: Hashable, Comparable {
        let bar: Int
        /// The position among the bar's slots, sorted, with the « left out.
        let position: Int

        static func < (a: SlotRef, b: SlotRef) -> Bool {
            (a.bar, a.position) < (b.bar, b.position)
        }
    }

    struct PreparedBar {
        let geometry: MenuBarGeometry
        /// Sorted by where they are, without the «.
        let slots: [AgentSlot]
        let overflowed: Set<Int>
        let chevron: CGRect?

        /// The slots macOS draws in order: they have a frame and aren't overflowed, left to right.
        var visible: [Int] {
            slots.indices.filter { position in
                !overflowed.contains(position) && (slots[position].frame.map { $0.width > 0 } ?? false)
            }
        }
    }

    private struct Entry {
        let bundleID: String
        let appName: String?
        /// The position among all the items the app lists.
        let position: Int
        let item: ExtraItem
    }

    private struct Built {
        let id: ItemID
        let ownerBundleID: String
        let appName: String?
        let isMantel: Bool
        var label: String?
        var frames: [String: CGRect] = [:]
        var overflowedOn: Set<String> = []
        /// The displays that have been looked at, with or without a frame there.
        var displays: Set<String> = []
        /// Where the item says it is on a bar where none of the slots is (`isStray`).
        var strays: [String: CGRect] = [:]
        /// Whether the item is one of Mantel's two dots.
        var isDot = false
        /// The width of the frame its app reports for it.
        var reportedWidth: CGFloat?
        /// The displays whose bar holds the frame that the item reports and another dot reports too.
        var sharesFrameOn: Set<String> = []
        /// The displays whose « menu the item reports itself to be in: a dot with a stray place on a bar that has a «.
        var inMenuOn: Set<String> = []
        /// The displays where a dot says it is in the gap right of the notch (`isInTheGap`), with no « to say so.
        var inGapOn: Set<String> = []
        /// The displays in `overflowedOn` that are told by a place.
        var inferredOn: Set<String> = []

        init(id: ItemID, ownerBundleID: String, appName: String?, isMantel: Bool) {
            self.id = id
            self.ownerBundleID = ownerBundleID
            self.appName = appName
            self.isMantel = isMantel
        }

        var item: MenuBarItem {
            MenuBarItem(id: id, ownerBundleID: ownerBundleID, appName: appName, label: label, frames: frames,
                        overflowedOn: overflowedOn, isMantel: isMantel, isDot: isDot, strayFrames: strays, inferredOverflowOn: inferredOn, sharesFrameOn: sharesFrameOn,
                        reportedWidth: reportedWidth)
        }
    }

    private static func prepare(_ bar: MatchBar, layout: DisplayLayout) -> PreparedBar {
        let sorted = bar.slots.sorted(by: slotOrder)
        let chevron = sorted.first(where: OverflowDetector.isChevron)?.frame.flatMap { $0.isEmpty ? nil : $0 }
        let slots = sorted.filter { !OverflowDetector.isChevron($0) }
        let notch = layout.display(uuid: bar.displayUUID)?.notch.map(layout.cgRect(fromAppKit:))
        return PreparedBar(geometry: MenuBarGeometry(displayUUID: bar.displayUUID, rect: bar.rect, notch: notch), slots: slots,
                           overflowed: OverflowDetector.overflowed(slots: slots, chevron: chevron, notch: notch), chevron: chevron)
    }

    /// Left to right, the ones with no frame last. Slots that are in the same place are told apart by what they say of
    /// themselves, so that the order never depends on the one they were listed in.
    private static func slotOrder(_ a: AgentSlot, _ b: AgentSlot) -> Bool {
        func key(_ slot: AgentSlot) -> (Int, CGFloat, CGFloat, String, String, String) {
            (slot.frame == nil ? 1 : 0, slot.frame?.minX ?? 0, slot.frame?.width ?? 0, slot.identifier ?? "", slot.description ?? "",
             slot.subrole ?? "")
        }
        return key(a) < key(b)
    }

    /// How much wider than its slot an icon's frame may be and still be the slot's. A frame is the icon's own size (the app draws it, and
    /// the slot is the bar's room for it): real ones are two to five points wider than the slot (40 in 38, 91 in 89, 34 in 29).
    private static let widthTolerance: CGFloat = 6

    /// The slots an app's frame could be in, with how far the frame's center is from each slot's: the ones that are no one else's yet,
    /// hold the frame's center (a point or so outside will do) and are no more than `widthTolerance` narrower than the frame. A slot that
    /// names a system module is the system's: no app's frame is its (the clock and Control Center are where their clicks are replayed, and
    /// an app that hides in the place of one is not it).
    private static func slotsHolding(_ frame: CGRect, in bars: [PreparedBar], excluding claimed: [SlotRef: Int])
        -> [(slot: SlotRef, distance: CGFloat)] {
        let center = CGPoint(x: frame.midX, y: frame.midY)
        var found: [(slot: SlotRef, distance: CGFloat)] = []
        for (barIndex, bar) in bars.enumerated() {
            for (position, slot) in bar.slots.enumerated() {
                let ref = SlotRef(bar: barIndex, position: position)
                guard claimed[ref] == nil, let slotFrame = slot.frame, !slotFrame.isEmpty,
                      ItemID.systemModule(ofIdentifier: slot.identifier ?? "") == nil,
                      slotFrame.insetBy(dx: -slotOutset, dy: -slotOutset).contains(center),
                      frame.width <= slotFrame.width + widthTolerance
                else { continue }
                found.append((ref, abs(slotFrame.midX - center.x)))
            }
        }
        return found
    }

    /// Gives each of these entries' frames the slot that fits it best. Every (frame, slot) pair is looked at, the closest first, and a pair
    /// is made when neither has been given: so a frame that is nearly in a slot doesn't take it from the one whose slot it is, whatever
    /// order the apps are listed in.
    private static func claimSlots(for indices: [Int], entries: [Entry], bars: [PreparedBar], claimed: inout [SlotRef: Int]) {
        var pairs: [(distance: CGFloat, entry: Int, slot: SlotRef)] = []
        for entryIndex in indices {
            guard let frame = entries[entryIndex].item.frame, !frame.isEmpty else { continue }
            for candidate in slotsHolding(frame, in: bars, excluding: claimed) { pairs.append((candidate.distance, entryIndex, candidate.slot)) }
        }
        pairs.sort { ($0.distance, $0.entry, $0.slot) < ($1.distance, $1.entry, $1.slot) }
        var placed: Set<Int> = []
        for pair in pairs where !placed.contains(pair.entry) && claimed[pair.slot] == nil {
            claimed[pair.slot] = pair.entry
            placed.insert(pair.entry)
        }
    }

    /// Whether a dot's place is in the gap on a notched display between the notch's right edge and the left-most icon that is drawn: where
    /// the « sits when something has overflowed, and where nothing is drawn. The dots are never concealed and never hide themselves, so a
    /// place there is the dot's being out of the way; an app's place there says nothing (a Hidden app's stale place has the same
    /// signature), and nothing is made of it.
    private static func isInTheGap(_ frame: CGRect, on bar: PreparedBar) -> Bool {
        guard let notch = bar.geometry.notch,
              let firstDrawn = bar.slots.compactMap(\.frame).filter({ $0.width > 0 }).map(\.minX).min() else { return false }
        return frame.minX >= notch.maxX - barOutset && frame.minX < firstDrawn - 4
    }

    /// Whether two frames are one and the same, to within half a point.
    private static func sameFrame(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.minX - b.minX) <= 0.5 && abs(a.minY - b.minY) <= 0.5 && abs(a.width - b.width) <= 0.5 && abs(a.height - b.height) <= 0.5
    }

    /// How far outside a bar's rectangle an item's frame may be and still be on the bar.
    private static let barOutset: CGFloat = 2

    /// Whether `frame` is on the bar, all of it, and in none of its slots: where an item that isn't drawn says it is, in the place it
    /// would have. (An item that is concealed says it is off every bar: at the bottom edge of the main display, which only touches a bar
    /// that is below it, and one that is drawn is in a slot, though its frame may be a point or two wider than the slot's.)
    private static func isStray(_ frame: CGRect, on bar: PreparedBar) -> Bool {
        guard bar.geometry.rect.insetBy(dx: -barOutset, dy: -barOutset).contains(frame) else { return false }
        let center = CGPoint(x: frame.midX, y: frame.midY)
        return !bar.slots.contains { slot in slot.frame?.insetBy(dx: -slotOutset, dy: -slotOutset).contains(center) ?? false }
    }

    private static func nonEmpty(_ text: String?) -> String? {
        guard let text, !text.isEmpty else { return nil }
        return text
    }
}
