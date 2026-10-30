import CoreGraphics
import Foundation
import MKCore

/// The slots one of MenuBarAgent's windows draws on a display at one moment: what a later read is compared with, to tell which slots are
/// new.
public struct SlotSnapshot: Sendable, Equatable {
    public let displayUUID: String
    /// The frames of the slots that are drawn (on the bar, with an area), by x. The « is not one.
    public let slots: [CGRect]
    /// The name each of the slots carries (`names[index]` is the name of `slots[index]`), nil for one with none. A name counts when it names
    /// an item (not one AppKit makes up) and no other slot of the bar has it: a window of a Space that isn't on screen gives every slot of an
    /// app its first item's name, and such a name tells nothing. Empty when the snapshot doesn't say.
    public let names: [String?]
    /// Every name the slots carried, the ones that repeat among them too (`names` leaves those out): a slot whose name was on the bar at the
    /// snapshot is never one that appeared since, whether or not the name told it from another slot then.
    public let identifiers: Set<String>
    /// The window of MenuBarAgent's the slots were read from (its place among the agent's windows). A later `locate` reads that window, and
    /// says nothing of the slots that appeared when it settles on another: the slots and the names of two windows are not comparable (a
    /// window of a Space that isn't on screen can keep old slots).
    public let window: Int?

    /// The app (by bundle ID) that had its icon in each of the slots when the snapshot was taken (`owners[index]` is the owner of
    /// `slots[index]`): the one app whose items' frames were in that slot, by the scans' own rules; nil for a slot that no app was in, or that
    /// more than one was. Empty when the snapshot doesn't say.
    public let owners: [String?]

    /// The slots of the apps that were taken out of the snapshot (`removing(apps:)`), as they were, not moved. An app that is on its way
    /// off the bar is drawn still for a while after its plan is applied, and its slot, in the place it was, is no slot that appeared.
    public let removed: [CGRect]

    /// Every read of the window the slots came from was answered. False when one timed out or was cut by the read's budget: a slot that
    /// lacks its frame isn't in `slots`, so they may be short of what the bar draws, and a snapshot that is short says nothing of the bar.
    public let isComplete: Bool

    public init(displayUUID: String, slots: [CGRect], names: [String?] = [], identifiers: Set<String>? = nil, window: Int? = nil,
                owners: [String?] = [], removed: [CGRect] = [], isComplete: Bool = true) {
        self.displayUUID = displayUUID
        self.slots = slots
        self.names = names.count == slots.count ? names : []
        self.identifiers = identifiers ?? Set(self.names.compactMap { $0 })
        self.window = window
        self.owners = owners.count == slots.count ? owners : []
        self.removed = removed
        self.isComplete = isComplete
    }

    /// The snapshot as the bar is once the apps in `apps` (the Shown apps that were concealed to make room) have gone from it: their slots
    /// are left out, and every slot left of them is moved right by what they took (the bar is right-aligned, and a slot that goes lets the
    /// ones left of it close up against the ones right of it). What a later look finds is then compared with what the bar should be, so
    /// that the slots that *appeared* can be told by their widths and order as they are when nothing was taken away.
    ///
    /// Nil when `owners` isn't known: which slots went is never guessed, since the slots that are new are what is left. A slot that went and
    /// wasn't attributed to an app stays in the snapshot, and the look then finds a slot of the baseline that isn't there (no answer).
    ///
    /// The slots that went are kept, as they were (`removed`): the apps are drawn on their way off the bar for some time after their plan
    /// is applied (up to over a second), and a slot that is still drawn in the place one was is never one that appeared.
    func removing(apps: Set<String>) -> SlotSnapshot? {
        guard !apps.isEmpty else { return self }
        guard !owners.isEmpty else { return nil }
        let order = slots.indices.sorted { slots[$0].minX < slots[$1].minX }
        let gone = Set(order.filter { owners[$0].map(apps.contains) ?? false })
        guard !gone.isEmpty else { return self }
        // What each run of removed slots takes: from the edge of the slot left of it to its own right edge.
        var shifts: [(from: Int, by: CGFloat)] = []
        var position = 0
        while position < order.count {
            guard gone.contains(order[position]) else {
                position += 1
                continue
            }
            let first = position
            while position < order.count, gone.contains(order[position]) { position += 1 }
            // A run at the left end of the bar has no slot left of it to move.
            if first > 0 { shifts.append((first, slots[order[position - 1]].maxX - slots[order[first - 1]].maxX)) }
        }
        var kept: [(frame: CGRect, name: String?, owner: String?)] = []
        for (place, index) in order.enumerated() where !gone.contains(index) {
            let by = shifts.filter { $0.from > place }.reduce(CGFloat(0)) { $0 + $1.by }
            kept.append((slots[index].offsetBy(dx: by, dy: 0), names.isEmpty ? nil : names[index], owners[index]))
        }
        return SlotSnapshot(displayUUID: displayUUID, slots: kept.map(\.frame), names: names.isEmpty ? [] : kept.map(\.name),
                            identifiers: identifiers, window: window, owners: kept.map(\.owner),
                            removed: removed + gone.map { slots[$0] }, isComplete: isComplete)
    }
}

/// Where one item is now, and how that was told.
public struct ItemLocation: Sendable, Equatable {
    public enum TiedBy: String, Codable, Sendable {
        /// The item's app says it is in this slot (its frame is in it, by the inventory's rules).
        case tie
        /// A slot appeared that the snapshot didn't have: exactly as many as the item's app has items, and this is the item's.
        case newSlots
        /// Both say this slot.
        case tieAndNewSlots
    }

    public let item: ItemID
    public let displayUUID: String
    /// The slot, in CoreGraphics global points.
    public let slotFrame: CGRect
    public let tiedBy: TiedBy
    /// The slot is one of the snapshot's slots, where it was or moved to (every slot left of one that appears is pushed further left, so a
    /// slot is no new one for being somewhere else). It is false only when the slots that appeared since the snapshot were told from the
    /// old ones without a doubt and this is one of them; and when there is no snapshot of this display to ask. It is true when the slot was
    /// there, and also when that can't be told (the new slots can't be told from the old ones). An item that was concealed at the snapshot
    /// can't be in a slot that was there: what ties it to one is the frame its app left behind (a stale one), unless a slot appeared for it.
    public let slotWasInBaseline: Bool
    /// The item's own frame, as its app reports it, agrees with the slot: it is from 16 points narrower to 6 points wider than the slot (on
    /// macOS 27 an icon's frame is 14 points narrower than its slot, which has seven either side; on earlier ones it was two to five wider),
    /// and the app doesn't put the item in another slot. False when the app reports no frame for it. It is only recorded, and is
    /// no ground for a click (`isPostable`): a neighbour that changes width by a few points as an icon appears leaves a new slot that is not
    /// the icon's and has about its width.
    public let widthAgrees: Bool
    /// The width of the item's own frame, as its app reports it, minus the slot's width: what `widthAgrees` is a judgment of (-16 to 6
    /// agrees). Nil when the app reports no frame for the item. It is only recorded, and is no ground for a click.
    public let frameMinusSlotWidth: CGFloat?

    /// How much wider than its slot an item's frame may be and still be its.
    static let widthSlack: CGFloat = 6
    /// How much narrower than its slot an item's frame may be and still be its.
    static let widthShortfall: CGFloat = 16

    public init(item: ItemID, displayUUID: String, slotFrame: CGRect, tiedBy: TiedBy, slotWasInBaseline: Bool, widthAgrees: Bool,
                frameMinusSlotWidth: CGFloat? = nil) {
        self.item = item
        self.displayUUID = displayUUID
        self.slotFrame = slotFrame
        self.tiedBy = tiedBy
        self.slotWasInBaseline = slotWasInBaseline
        self.widthAgrees = widthAgrees
        self.frameMinusSlotWidth = frameMinusSlotWidth
    }

    /// Whether a click may be posted at this slot. **This is the one place the rule lives**: the click driver asks it, and
    /// nothing else decides for itself. A posted click lands on whatever icon is there, so it needs two signals that agree, except where one is
    /// already known.
    ///
    /// - **Drawn at the snapshot** (`drawnAtSnapshot`: the item was on the bar when the snapshot was taken): its app's frame ties it to its
    ///   slot, and that is enough (`tie`, or `tieAndNewSlots`).
    /// - **Concealed at the snapshot:** its frame is one it left behind, and a slot that merely isn't in the snapshot says only that
    ///   something appeared. So the app's frame and the slot that appeared have to say the same slot (`tieAndNewSlots`), and nothing else is
    ///   enough: not a tie alone, not a location found with no snapshot (it can only be a tie), and not a slot that appeared with the
    ///   item's own width (`newSlots` with `widthAgrees`), which a neighbour that changes by a few points as an icon appears gets right
    ///   about as often as the icon does.
    public func isPostable(drawnAtSnapshot: Bool) -> Bool {
        switch tiedBy {
        case .tieAndNewSlots: true
        case .tie: drawnAtSnapshot
        case .newSlots: false
        }
    }
}

public enum ItemPressError: Error, Equatable, LocalizedError {
    /// The item isn't there: its app isn't running or doesn't list it (any more).
    case notFound
    /// Accessibility isn't granted to Mantel.
    case notTrusted
    /// The item doesn't offer `AXShowMenu`.
    case noShowMenu
    /// The app, or macOS, didn't do it; the text says why, in a few words.
    case refused(String)
    /// The item's app didn't answer the action in time. An action that opens a menu doesn't return until the menu closes, so this says that
    /// the action may have been sent and had its effect, not that it failed.
    case noAnswer

    public var errorDescription: String? {
        switch self {
        case .notFound: "That icon isn't in the menu bar right now."
        case .notTrusted: "Mantel needs Device control and data access to click for you. Turn it on in Settings › Permissions."
        case .noShowMenu: "That icon doesn't open a menu that way."
        case .refused(let reason): "The icon didn't respond: \(reason)"
        case .noAnswer: "The icon didn't answer in time."
        }
    }
}

/// Finds where an item is in the menu bar now. The click driver locates items through it; the real one is the scanner, and a
/// test gives its own.
public protocol ItemLocating: Sendable {
    /// The slots drawn on `display` (the main display's when nil) now; nil when they can't be read.
    func slotSnapshot(on display: String?) async -> SlotSnapshot?
    /// Where the item is on `display` (the main display's when nil) now: nil when it isn't in a slot that can be told to be its.
    func locate(_ item: ItemID, on display: String?, since baseline: SlotSnapshot?) async -> ItemLocation?
}

/// Presses an item, or opens its menu, through Accessibility.
public protocol ItemPressing: Sendable {
    func press(_ item: ItemID) async throws(ItemPressError)
    /// `AXShowMenu`, where the item offers it.
    func showMenu(_ item: ItemID) async throws(ItemPressError)
    /// `press`, which calls `issued` at the moment the action is sent: after the item has been found in its app's list (that is a read of the
    /// app, which can take a while), and before the action itself (which, when it opens a menu, doesn't return until the menu closes).
    /// What waits for a press to have been sent starts its clock there. A conformer that has nothing to find first needn't implement it.
    func press(_ item: ItemID, issued: @Sendable () -> Void) async throws(ItemPressError)
    /// `showMenu`, calling `issued` as `press(_:issued:)` does.
    func showMenu(_ item: ItemID, issued: @Sendable () -> Void) async throws(ItemPressError)
}

extension ItemPressing {
    public func press(_ item: ItemID, issued: @Sendable () -> Void) async throws(ItemPressError) {
        issued()
        try await press(item)
    }

    public func showMenu(_ item: ItemID, issued: @Sendable () -> Void) async throws(ItemPressError) {
        issued()
        try await showMenu(item)
    }
}

/// What is worked out of the slots and the frames, apart from reading them.
enum ItemLocator {
    /// Frames this close (in points, in every edge that is compared) are the same.
    static let tolerance: CGFloat = 1

    static func sameFrame(_ one: CGRect, _ other: CGRect) -> Bool {
        abs(one.minX - other.minX) <= tolerance && abs(one.minY - other.minY) <= tolerance
            && abs(one.width - other.width) <= tolerance && abs(one.height - other.height) <= tolerance
    }

    /// The slots of the bar that are drawn, by x: those that have a frame with an area that is on the bar. The « isn't one, and neither
    /// is a slot macOS has parked off the bar.
    static func drawnSlots(of bar: MatchBar) -> [CGRect] {
        drawnSlotsNamed(of: bar).map(\.frame)
    }

    /// Every name a drawn slot of the bar carries, the ones that repeat on the bar too (`drawnSlotsNamed` leaves those out).
    static func drawnIdentifiers(of bar: MatchBar) -> Set<String> {
        Set(bar.slots.compactMap { slot -> String? in
            guard !slot.isOverflowChevron, let frame = slot.frame, frame.width > 0, frame.height > 0, frame.intersects(bar.rect) else { return nil }
            return ItemID.usableIdentifier(slot.identifier)
        })
    }

    /// The drawn slots (`drawnSlots`) with the name each carries: a name that names an item, and that no other slot of the bar has.
    static func drawnSlotsNamed(of bar: MatchBar) -> [(frame: CGRect, name: String?)] {
        var counts: [String: Int] = [:]
        for slot in bar.slots {
            if let name = ItemID.usableIdentifier(slot.identifier) { counts[name, default: 0] += 1 }
        }
        return bar.slots.compactMap { slot -> (frame: CGRect, name: String?)? in
            guard !slot.isOverflowChevron, let frame = slot.frame, frame.width > 0, frame.height > 0, frame.intersects(bar.rect) else { return nil }
            let name = ItemID.usableIdentifier(slot.identifier).flatMap { counts[$0] == 1 ? $0 : nil }
            return (frame, name)
        }.sorted { $0.frame.minX < $1.frame.minX }
    }

    /// The slots that appeared since a snapshot was taken.
    struct Appeared: Equatable {
        /// Every slot that appeared, by x. Nil unless they can all be told from the old ones.
        let all: [CGRect]?
        /// The slots that appeared with a name the snapshot didn't have, by that name: these are told whatever the other slots did.
        let named: [String: CGRect]

        /// Whether the slot is one that appeared, as far as that can be told.
        func includes(_ slot: CGRect) -> Bool {
            named.values.contains { sameFrame($0, slot) } || (all?.contains { sameFrame($0, slot) } ?? false)
        }
    }

    /// The slots in `bar` that `snapshot` didn't have.
    ///
    /// **Slots with names are told by name.** Where the snapshot has names, a slot of the bar is new when its name wasn't among them, and
    /// an old one when it was, whatever the slots round it did (a neighbour with live text changes width every few seconds). The slots
    /// that have none are told by their widths and order (`appearedSlots`).
    ///
    /// **The named slots both looks have stay fixed.** They are the anchors that keep the order: the slots with no name are split at them,
    /// and each run between two anchors is told on its own, so a slot can't be matched across an anchor. A run's end that lies next to an
    /// anchor has a neighbour that is known (the anchor), where the end of the bar has none. Every name the snapshot had has to be on the
    /// bar still and in the same order, or something else changed between the two looks, and the new slots as a whole (`all`) can't be
    /// told; those that carry a new name still are.
    static func appeared(since snapshot: SlotSnapshot, in bar: MatchBar) -> Appeared {
        let knownNames = Set(snapshot.names.compactMap { $0 })
        // A name the bar had at the snapshot, though it told nothing then (it repeated), is no new name: the slot is one of the old ones, with
        // none (its place is told by its width and order, as a slot with none is). Such a slot is **never** one that appeared, whatever its
        // width and place say, and whether or not its name repeats now (`appeared.all` leaves it out, and the slots that appeared are then
        // fewer than they would be: no answer).
        // The slots of the apps that were taken out of the snapshot are the same: where one is still drawn, an app is on its way off the bar.
        let oldOnes: [CGRect] = snapshot.removed + bar.slots.compactMap { slot in
            guard !slot.isOverflowChevron, let frame = slot.frame, frame.width > 0, frame.height > 0, frame.intersects(bar.rect),
                  let name = ItemID.usableIdentifier(slot.identifier), snapshot.identifiers.contains(name) else { return nil }
            return frame
        }
        let current = drawnSlotsNamed(of: bar).map { slot -> (frame: CGRect, name: String?) in
            guard let name = slot.name, !knownNames.contains(name), snapshot.identifiers.contains(name) else { return slot }
            return (slot.frame, nil)
        }
        func newOnly(_ slots: [CGRect]?) -> [CGRect]? {
            slots?.filter { slot in !oldOnes.contains { sameFrame($0, slot) } }
        }
        guard !knownNames.isEmpty else {
            return Appeared(all: newOnly(appearedSlots(since: snapshot.slots, in: current.map(\.frame))), named: [:])
        }
        var named: [String: CGRect] = [:]
        for slot in current { if let name = slot.name, !knownNames.contains(name) { named[name] = slot.frame } }
        let before = zip(snapshot.slots, snapshot.names).map { (frame: $0, name: $1) }.sorted { $0.frame.minX < $1.frame.minX }
        guard knownNames.isSubset(of: Set(current.compactMap(\.name))),
              before.compactMap(\.name) == current.compactMap(\.name).filter(knownNames.contains) else { return Appeared(all: nil, named: named) }

        // The runs of slots with no name, between the anchors (the slots whose name both looks have). A slot that has a new name is not in
        // one: it is told already.
        func runs(_ slots: [(frame: CGRect, name: String?)]) -> [[CGRect]] {
            var runs: [[CGRect]] = [[]]
            for slot in slots {
                if let name = slot.name {
                    if knownNames.contains(name) { runs.append([]) }
                } else {
                    runs[runs.count - 1].append(slot.frame)
                }
            }
            return runs
        }
        let oldRuns = runs(before), newRuns = runs(current)
        guard oldRuns.count == newRuns.count else { return Appeared(all: nil, named: named) }
        var appeared: [CGRect] = Array(named.values)
        for run in oldRuns.indices {
            guard let told = appearedSlots(since: oldRuns[run], in: newRuns[run], anchoredLeft: run > 0, anchoredRight: run < oldRuns.count - 1) else {
                return Appeared(all: nil, named: named)
            }
            appeared += told
        }
        return Appeared(all: newOnly(appeared.sorted { $0.minX < $1.minX }), named: named)
    }

    /// The slots in `current` that the baseline didn't have, by x. Nil unless they can be told from the old ones without a doubt.
    ///
    /// The bar is right-aligned, so a slot that appears pushes every slot left of it further left, and the old slots can't be told by where
    /// they were. They are told by their widths, in order: an old slot is a current slot of its width that is no further right than it
    /// was. That leaves a choice when a slot's width is also another's (a new slot as wide as the old one beside it, or a new slot as wide
    /// as an old one that went left of it), and nothing in the frames says which is the new one. So the old slots are matched twice, from
    /// the right (each takes the right-most slot that fits, left of the one the old slot after it took) and from the left (each takes the
    /// left-most, right of the one before), and an old slot that nothing fits is left out. The two ways have to leave the same: then no
    /// other way of matching them exists.
    ///
    /// An old slot that nothing fits is one that changed width (an icon with live text) when both of its neighbours matched, and the
    /// slots between theirs are as many as the old slots between them: no slot appeared there, and they are the same ones in the same
    /// order. A neighbour that is an anchor (`anchoredLeft`, `anchoredRight`: the slots are a run between two slots that are known to be
    /// the same in both looks) counts as matched. A slot left out at an end of the bar, or one with another slot beside it that could be
    /// new, has no such answer. Anything else, and a slot of the baseline that isn't there any more, is nil: which slot is new is never
    /// guessed, since a click lands on the one that is picked.
    ///
    /// **A limit, which gives nil.** A slot that shrank pushes the slots left of it right, and a slot is never taken for one that moved
    /// right: when nothing appeared right of the shrunk slot to push them back (a slot appears left of the bar's slots, or none does),
    /// the slots left of it find no match. The shrunk slot itself is matched when its neighbours are, and so are the slots left of it when
    /// a slot that appeared right of it pushed them back.
    static func appearedSlots(since baseline: [CGRect], in current: [CGRect], anchoredLeft: Bool = false,
                              anchoredRight: Bool = false) -> [CGRect]? {
        let old = baseline.sorted { $0.minX < $1.minX }
        let slots = current.sorted { $0.minX < $1.minX }
        func fits(_ known: CGRect, _ slot: CGRect) -> Bool {
            abs(slot.width - known.width) <= tolerance && slot.maxX - known.maxX <= tolerance
        }

        var fromRight = [Int](repeating: -1, count: old.count)
        var limit = slots.count
        for position in old.indices.reversed() {
            guard let index = (0..<limit).last(where: { fits(old[position], slots[$0]) }) else { continue }
            fromRight[position] = index
            limit = index
        }
        var matched = [Int](repeating: -1, count: old.count)
        var start = 0
        for position in old.indices {
            guard let index = (start..<slots.count).first(where: { fits(old[position], slots[$0]) }) else { continue }
            matched[position] = index
            start = index + 1
        }
        guard fromRight == matched else { return nil }

        var changedWidth: Set<Int> = []
        var position = 0
        while position < old.count {
            guard matched[position] < 0 else {
                position += 1
                continue
            }
            let first = position
            while position < old.count, matched[position] < 0 { position += 1 }
            guard first > 0 || anchoredLeft, position < old.count || anchoredRight else { return nil }
            let between = (first > 0 ? matched[first - 1] + 1 : 0)..<(position < old.count ? matched[position] : slots.count)
            guard between.count == position - first else { return nil }
            for (offset, index) in between.enumerated() {
                guard slots[index].maxX - old[first + offset].maxX <= tolerance else { return nil }
                matched[first + offset] = index
                changedWidth.insert(first + offset)
            }
        }

        // How far each old slot has moved (left is negative) can't be less than that of the one right of it, and two that are side by side
        // now were side by side before: the same move. It is the move of the edge they share (a slot that changed width moved its left
        // edge, not its right), and a slot's right edge can't have moved right of that edge of the one beside it. A match that breaks that
        // isn't a bar with slots that appeared.
        for position in old.indices.dropLast() {
            let here = slots[matched[position]].maxX - old[position].maxX
            let next = matched[position + 1]
            let shared = changedWidth.contains(position + 1) ? slots[next].minX - old[position + 1].minX : slots[next].maxX - old[position + 1].maxX
            guard here <= shared + tolerance else { return nil }
            if next == matched[position] + 1, abs(here - shared) > tolerance { return nil }
        }
        let taken = Set(matched)
        return slots.indices.filter { !taken.contains($0) }.map { slots[$0] }
    }

    /// How the slot tied to the item and the one that appeared for it come to one answer: both when they are the same slot; the new one
    /// when they aren't (a slot that appeared when it was expected is more to be trusted than a frame an app reports, which can be left
    /// over); whichever there is when there is one; nothing when there is none.
    static func answer(tie: CGRect?, appeared: CGRect?) -> (frame: CGRect, tiedBy: ItemLocation.TiedBy)? {
        switch (tie, appeared) {
        case (let tie?, let appeared?):
            return sameFrame(tie, appeared) ? (appeared, .tieAndNewSlots) : (appeared, .newSlots)
        case (let tie?, nil):
            return (tie, .tie)
        case (nil, let appeared?):
            return (appeared, .newSlots)
        case (nil, nil):
            return nil
        }
    }
}

// MARK: The scanner

/// Where an item's app is asked about it, and what that came to.
private struct OwnerRead: Sendable {
    let app: RunningApp
    let outcome: ExtrasOutcome
    let elements: [AXElementRef]
}

extension MenuBarScanner: ItemLocating, ItemPressing {
    /// The apps that list a system item: Control Center and the system's UI server.
    private static let systemOwners: Set<String> = ["com.apple.controlcenter", "com.apple.systemuiserver"]
    private static let showMenuAction = "AXShowMenu"

    // MARK: Locating

    public func slotSnapshot(on display: String?) async -> SlotSnapshot? {
        guard isTrusted() else { return nil }
        let displays = layout()
        guard let uuid = Self.displayUUID(display, in: displays) else { return nil }
        // The apps that have an icon on this bar are asked as the bar is read, to say whose each slot is (`SlotSnapshot.owners`): the ones the
        // plan conceals have no slot of their own, and their frames are stale.
        let onBar = appsOnBar[uuid] ?? []
        let asked = runningApps().filter { app in app.bundleID.map { onBar.contains($0) && !concealedApps.contains($0) } ?? false }
            .sorted { $0.pid < $1.pid }
        // They are asked to name the owners of slots and nothing waits for them: they get the first wait only.
        let (barRead, reads) = await inScope(AXPatience.checkBudget, quick: Set(asked.map(\.pid))) {
            async let barRead = readBar(on: uuid, in: displays, preferring: nil)
            async let reads = Self.read(asked, with: elementReader, gate: readGate)
            return await (barRead, reads)
        }
        guard let read = barRead else { return nil }
        let drawn = ItemLocator.drawnSlotsNamed(of: read.bar)
        let identifiers = ItemLocator.drawnIdentifiers(of: read.bar)

        var scratch = memory
        let input = MatchInput(capturedAt: clock.now(), layout: displays, bars: [read.bar], apps: Self.answered(reads).map(\.extras),
                               ownBundleID: ownBundleID, concealedApps: concealedApps)
        let items = InventoryMatcher.matchCounting(input, memory: &scratch).inventory.items.filter { !$0.id.isSystem }
        let owners = drawn.map { slot -> String? in
            let apps = Set(items.filter { $0.frames[uuid].map { ItemLocator.sameFrame($0, slot.frame) } == true }.map(\.id.bundleID))
            return apps.count == 1 ? apps.first : nil
        }
        return SlotSnapshot(displayUUID: uuid, slots: drawn.map(\.frame), names: drawn.map(\.name), identifiers: identifiers, window: read.index,
                            owners: owners, isComplete: read.isComplete)
    }

    /// The item's slot on `display` now: tied by the inventory's rules (an app's frame is the slot it is in, to within six points of width,
    /// and no system slot is an app's; the frames of an app the plan conceals claim a slot only after every other app's, so one that was
    /// left behind in another app's slot ties nothing); and, when `baseline` is given, the slot that appeared for it. A slot that carries
    /// the item's own name and that the baseline's names didn't have is that slot, with no more to tell (`ItemLocator.appeared`). Otherwise
    /// the answer is there when exactly as many slots appeared as the item's app has items (and they are told from the old ones without a
    /// doubt), the new slot at the item's place among its app's items from left to right. That place is what the scans learned of the app
    /// when all its items were drawn (an app lists its items in an order of its own, and this read doesn't learn it: ties that are stale
    /// would teach it wrong); an app with one item needs none, and for any other whose place isn't known there is no such answer. Nor is
    /// there when a tie of any of the app's items that lies in a new slot isn't the slot that item's place gives it: the place, or the tie,
    /// is wrong, and which isn't known. When both say something they have to agree (`tieAndNewSlots`); when they don't, the new slot wins,
    /// and `tiedBy` says so (`newSlots`, though the app said a slot).
    /// An item is what the scans call it: if this read, from its own ties, would name the app's items other than the scans did (an item
    /// with no name of its own is told by its place, and a frame left behind in another's slot swaps two), there is no answer.
    /// Whether to click there is `ItemLocation.isPostable`.
    ///
    /// One window of MenuBarAgent's is read, and the items of the item's app and of the apps with an item on this display at the last scan (for the slots
    /// they claim); nothing is kept. The window is the one that had the most identifiers at the last scan. The apps that are concealed are
    /// those of the last scan that was asked for: an app that has been revealed since is still among them, and its fresh frames, in
    /// slots no other app has, tie all the same.
    public func locate(_ item: ItemID, on display: String?, since baseline: SlotSnapshot?) async -> ItemLocation? {
        guard isTrusted() else { return nil }
        let displays = layout()
        guard let uuid = Self.displayUUID(display, in: displays) else { return nil }
        let running = runningApps()
        let owners = Self.owners(of: item, in: running)
        // The apps that had an item on this display's bar at the last scan, except those the plan conceals (their frames claim last, and so
        // lose to the item's own in any slot they share), are asked as well: a frame left behind in one of their slots has to lose it to
        // theirs. They are asked together, as the scan asks.
        let ownerPIDs = Set(owners.map(\.pid))
        let onBar = appsOnBar[uuid] ?? []
        let claimants = running.filter { app in
            guard let bundleID = app.bundleID else { return false }
            return onBar.contains(bundleID) && !ownerPIDs.contains(app.pid) && !concealedApps.contains(bundleID)
        }
        let snapshot = baseline.flatMap { $0.displayUUID == uuid ? $0 : nil }
        // The claimants are bystanders, asked so that a frame left behind in one of their slots loses it: they get the first wait only.
        let (barRead, reads) = await inScope(AXPatience.checkBudget, quick: Set(claimants.map(\.pid))) {
            async let barRead = readBar(on: uuid, in: displays, preferring: snapshot?.window)
            async let reads = Self.read((owners + claimants).sorted { $0.pid < $1.pid }, with: elementReader, gate: readGate)
            return await (barRead, reads)
        }
        guard let read = barRead else { return nil }
        let bar = read.bar
        let allAnswered = Self.answered(reads)
        let answered = allAnswered.filter { ownerPIDs.contains($0.extras.pid) }

        // What the matcher makes of this one bar and this one app is what the scan would have made of them: the same ties, the same IDs.
        // Whatever it learns goes with the copy.
        var scratch = memory
        // The item's own app claims last whatever the scan's set says: a frame it left behind lies in a slot that is someone else's, and must
        // lose it to whoever answers for it. A fresh frame in a slot of its own is alone there and ties all the same.
        let input = MatchInput(capturedAt: clock.now(), layout: displays, bars: [bar], apps: allAnswered.map(\.extras), ownBundleID: ownBundleID,
                               concealedApps: concealedApps.union(owners.compactMap(\.bundleID)))
        let result = InventoryMatcher.matchCounting(input, memory: &scratch)
        let mine = result.inventory.items.first { $0.id == item }
        let tie = mine?.frames[uuid]

        // What the scans would call the app's items, with nothing read from the bar: the order and the slot names they learned (and none of a
        // run of the app that has gone). The read above names them from its own ties, and a tie that is stale can give an item another's name
        // (`.index(0)` is the left one as the scans saw them, and the read may put the right one's frame there). The item is what the scans
        // call it, or nobody.
        var learned = memory
        if !item.isSystem {
            let namedByTheScans = MatchInput(capturedAt: input.capturedAt, layout: displays, bars: [], apps: input.apps, ownBundleID: ownBundleID)
            guard InventoryMatcher.matchCounting(namedByTheScans, memory: &learned).listed[item] == result.listed[item] else { return nil }
        }

        // The slots that appeared since the snapshot, when they can be told: a snapshot of another display says nothing of this one's, and
        // neither does one from another window of MenuBarAgent's than this read settled on (the slots of two windows are not comparable).
        let sameWindow = snapshot.flatMap(\.window).map { $0 == read.index } ?? true
        let appeared = sameWindow ? snapshot.map { ItemLocator.appeared(since: $0, in: bar) } : nil

        var appearedForTheItem: CGRect?
        if let appeared, !item.isSystem, let listed = result.listed[item] {
            if case .identifier(let name) = item.key, let slot = Self.slot(named: name, ofApp: item.bundleID, in: appeared.named) {
                // Its own name is on a slot the snapshot didn't have, unless another app lists an item of that name: the name is then not
                // the item's alone (a concealed app's slot isn't drawn, so the slot is that other app's).
                let others = allAnswered.filter { !ownerPIDs.contains($0.extras.pid) }
                let shared = others.contains { $0.extras.items.contains { ItemID.usableIdentifier($0.identifier) == name } }
                if !shared { appearedForTheItem = slot }
            } else if let all = appeared.all {
                let listing = answered.flatMap { owner in owner.extras.items.map { (pid: owner.extras.pid, index: $0.index, frame: $0.frame) } }
                    .sorted { ($0.pid, $0.index) < ($1.pid, $1.index) }
                let items = listing.map { (pid: $0.pid, index: $0.index) }
                if let position = items.firstIndex(where: { $0.pid == listed.pid && $0.index == listed.index }), all.count == items.count {
                    if items.count == 1 {
                        appearedForTheItem = all[0]
                    } else if let places = learned.places(ofApp: item.bundleID, covering: Set(items.indices)), let place = places[position],
                              Self.tiesAgree(withPlaces: places, of: items, appeared: all, in: result, on: uuid, reported: listing.map(\.frame)) {
                        // Left to right, as the scans saw them: not the order the app lists them in.
                        appearedForTheItem = all[place]
                    }
                }
            }
        }

        // A slot that another app's own frame is in is that app's: it isn't the item's, however the slots were told.
        if let slot = appearedForTheItem,
           result.inventory.items.contains(where: { $0.id != item && $0.id.bundleID != item.bundleID && $0.frames[uuid].map { ItemLocator.sameFrame($0, slot) } == true }) {
            appearedForTheItem = nil
        }

        guard let found = ItemLocator.answer(tie: tie, appeared: appearedForTheItem) else { return nil }
        // **A concealed app's frames are never tied on their own, on any display:** what it says of where its icons are is what it said when
        // they were last drawn, and may lie in any slot of any bar (one that is nobody's, on a display that isn't the active one, among them).
        // A slot that appeared for the item and that its frame is in is what shows it is drawn again (`tieAndNewSlots`).
        if found.tiedBy == .tie, concealedApps.contains(item.bundleID) { return nil }
        // A slot is new only when the new slots were told and it is one of them: it may be an old one that moved, and when that can't be
        // told it is taken to be one.
        let wasThere = snapshot != nil && !(appeared?.includes(found.frame) ?? false)
        // The item's own width against the slot, and the app not saying the item is somewhere else: its own frame, as it reports it (not the
        // tie, which another app's claim on the slot takes away), is not in another slot of the bar. A frame that is in none (one the app
        // left where macOS parks icons) says nothing of where the item is.
        let wider = mine?.reportedWidth.map { $0 - found.frame.width }
        let reported = answered.first { $0.extras.pid == result.listed[item]?.pid }?.extras.items.first { $0.index == result.listed[item]?.index }?.frame
        let inAnotherSlot = reported.map { frame in
            let centre = CGPoint(x: frame.midX, y: frame.midY)
            return ItemLocator.drawnSlots(of: bar).contains { !ItemLocator.sameFrame($0, found.frame) && $0.contains(centre) }
        } ?? false
        let widthAgrees = (wider.map { $0 >= -ItemLocation.widthShortfall && $0 <= ItemLocation.widthSlack } ?? false) && !inAnotherSlot
        return ItemLocation(item: item, displayUUID: uuid, slotFrame: found.frame, tiedBy: found.tiedBy, slotWasInBaseline: wasThere,
                            widthAgrees: widthAgrees, frameMinusSlotWidth: wider)
    }

    /// The slot among `named` (by name) that is the one of the app's item with this name: the name as it is, or with the app's layout key in
    /// front (`<bundle ID>::<name>`).
    private static func slot(named name: String, ofApp bundleID: String, in named: [String: CGRect]) -> CGRect? {
        named[name] ?? named[bundleID + "::" + name]
    }

    /// Whether every item of the app that the app puts in a slot that appeared is put in the one its place gives it. A tie in a slot that
    /// was already there is no evidence either way (an item that was concealed has a frame it left behind), and an item with no tie says
    /// nothing; but one that is tied to a new slot is where it is, and if that isn't where its place says, the places are out of date (the
    /// order of the app's items changed while they were concealed), or the tie is wrong.
    ///
    /// **Any frame the app reports counts, claimed or not** (`reported`, by the item's position): a frame that lies in a slot that appeared and
    /// isn't the slot its item's place gives it says the places are out of date, or that the app's frames are from another moment, whether
    /// or not the matcher gave that frame the slot (another app's frame may have won it).
    private static func tiesAgree(withPlaces places: [Int: Int], of items: [(pid: pid_t, index: Int)], appeared: [CGRect],
                                  in result: InventoryMatcher.MatchResult, on uuid: String, reported: [CGRect?]) -> Bool {
        for (position, frame) in reported.enumerated() {
            guard let frame, let place = places[position] else { continue }
            let centre = CGPoint(x: frame.midX, y: frame.midY)
            for (index, slot) in appeared.enumerated()
            where index != place && slot.insetBy(dx: -InventoryMatcher.slotOutset, dy: -InventoryMatcher.slotOutset).contains(centre) {
                return false
            }
        }
        for sibling in result.inventory.items where result.listed[sibling.id] != nil {
            guard let tie = sibling.frames[uuid], appeared.contains(where: { ItemLocator.sameFrame($0, tie) }),
                  let listed = result.listed[sibling.id],
                  let position = items.firstIndex(where: { $0.pid == listed.pid && $0.index == listed.index }) else { continue }
            guard let place = places[position], ItemLocator.sameFrame(appeared[place], tie) else { return false }
        }
        return true
    }

    /// The display asked for, or the main display's (the first's when none is main). Nil when there is none.
    private static func displayUUID(_ display: String?, in layout: DisplayLayout) -> String? {
        display ?? (layout.main ?? layout.displays.first)?.uuid
    }

    /// The bar of the display as one window of MenuBarAgent's has it, and which window that is. The window asked for (`preferring`; the one
    /// the last read settled on when nil) is read first.
    private func readBar(on uuid: String, in displays: DisplayLayout, preferring window: Int?) async
        -> (bar: MatchBar, index: Int, isComplete: Bool)? {
        guard let agent = menuBarAgent(in: runningApps()) else { return nil }
        let reader = agentReader, gate = readGate, preferred = window ?? windowMemory[uuid]?.best
        let readOfBar = await gate.run(ifCancelled: nil) {
            await reader.readBar(agent: agent, layout: displays, display: uuid, preferring: preferred)
        }
        guard let read = readOfBar else { return nil }
        // The window this read settled on is the one the next read tries first.
        windowMemory[uuid]?.best = read.index
        return (read.bar, read.index, read.isComplete)
    }

    // MARK: Pressing

    public func press(_ item: ItemID) async throws(ItemPressError) {
        try await press(item, issued: {})
    }

    public func press(_ item: ItemID, issued: @Sendable () -> Void) async throws(ItemPressError) {
        let element = try await element(of: item)
        issued()
        try await Self.call(on: ax, timeout: .noAnswer, notTrusted: refusal()) { ax throws(AXReadError) in try ax.press(element) }
    }

    public func showMenu(_ item: ItemID) async throws(ItemPressError) {
        try await showMenu(item, issued: {})
    }

    public func showMenu(_ item: ItemID, issued: @Sendable () -> Void) async throws(ItemPressError) {
        let element = try await element(of: item)
        // Reading the actions sends nothing: a timeout there is an app that didn't answer, not an action that was sent.
        let offered = try await Self.call(on: ax, notTrusted: refusal()) { ax throws(AXReadError) in try ax.actionNames(of: element) }
        guard offered.contains(Self.showMenuAction) else { throw .noShowMenu }
        issued()
        try await Self.call(on: ax, timeout: .noAnswer, notTrusted: refusal()) { ax throws(AXReadError) in try ax.perform(Self.showMenuAction, on: element) }
    }

    /// What an app's "not trusted" is while Mantel's own grant holds: the app refuses Accessibility (some do, to every process).
    private func refusal() -> ItemPressError {
        isTrusted() ? .refused("the app refuses to be controlled by other apps") : .notTrusted
    }

    /// What an item is answered by: its element in the app's own list, found again now. An item is told by the name its app gives it, or by
    /// its place among the app's unnamed items, as in the inventory (`InventoryMatcher` does the naming): an item that is no longer in the
    /// list, or whose place no longer exists, is `notFound`, and never another item.
    private func element(of item: ItemID) async throws(ItemPressError) -> AXElementRef {
        guard isTrusted() else { throw .notTrusted }
        let owners = Self.owners(of: item, in: runningApps())
        guard !owners.isEmpty else { throw .notFound }
        let reads = await inScope(AXPatience.checkBudget) { await Self.read(owners, with: elementReader, gate: readGate) }
        let answered = Self.answered(reads)
        guard !answered.isEmpty else {
            // Mantel is trusted (checked above), so an app that answers "not trusted" is refusing Accessibility itself: its grant isn't
            // what is missing.
            if reads.contains(where: { if case .notTrusted = $0.outcome { true } else { false } }) { throw refusal() }
            if reads.contains(where: { if case .timedOut = $0.outcome { true } else { false } }) { throw .refused("the app didn't answer in time") }
            throw .notFound
        }
        var scratch = memory
        let input = MatchInput(capturedAt: clock.now(), layout: layout(), bars: [], apps: answered.map(\.extras), ownBundleID: ownBundleID)
        let result = InventoryMatcher.matchCounting(input, memory: &scratch)
        guard let listed = result.listed[item], let read = answered.first(where: { $0.extras.pid == listed.pid }),
              read.elements.indices.contains(listed.index) else { throw .notFound }
        return read.elements[listed.index]
    }

    /// Runs one call of Accessibility off the actor (it waits for another app), and says how it failed as an `ItemPressError`. A timeout is
    /// `timeout`: `.noAnswer` only for the calls that send the action (a press or `AXShowMenu` that opens a menu doesn't return until the
    /// menu closes), and a read that didn't answer in time otherwise.
    ///
    /// `notTrusted` is what an Accessibility call that says so comes to: Mantel's own grant is checked before any call (`isTrusted`), so
    /// when it holds, the app is the one that refuses (`refusal()`).
    @concurrent
    private static func call<T: Sendable>(on ax: any AXReading, timeout: ItemPressError = .refused("the app didn't answer in time"),
                                          notTrusted: ItemPressError = .notTrusted,
                                          _ body: @Sendable (any AXReading) throws(AXReadError) -> T) async throws(ItemPressError) -> T {
        do {
            return try body(ax)
        } catch {
            switch error {
            case .notTrusted: throw notTrusted
            case .timeout: throw timeout
            case .noValue: throw .refused("the icon doesn't take that")
            case .failure(let code): throw .refused("macOS said \(code)")
            }
        }
    }

    // MARK: Reading the item's app

    /// The processes that list the item: its app's, or for a system item the apps that list the system's.
    private static func owners(of item: ItemID, in running: [RunningApp]) -> [RunningApp] {
        running.filter { app in
            guard let bundleID = app.bundleID else { return false }
            return item.isSystem ? systemOwners.contains(bundleID) : bundleID == item.bundleID
        }.sorted { $0.pid < $1.pid }
    }

    /// The apps asked together, as many at a time as a scan asks (`MenuBarReader.concurrency`), in the order of `apps`.
    private static func read(_ apps: [RunningApp], with reader: AppExtrasReader, gate: ReadGate) async -> [OwnerRead] {
        await ConcurrentMap.map(apps, limit: MenuBarReader.concurrency, gate: gate) { app in
            let read = reader.readWithElements(app)
            return OwnerRead(app: app, outcome: read.outcome, elements: read.elements)
        }
    }

    private struct Answered {
        let extras: AppExtras
        let elements: [AXElementRef]
    }

    /// The apps that gave their items, whole: an app that timed out half way says nothing of the items it didn't get to.
    private static func answered(_ reads: [OwnerRead]) -> [Answered] {
        reads.compactMap { read in
            guard case .items(let extras) = read.outcome, !extras.timedOut else { return nil }
            return Answered(extras: extras, elements: read.elements)
        }
    }
}
