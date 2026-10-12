import CoreGraphics
import Foundation
import MKCore

/// Lining up one display's slots with another's, for the items that nothing names.
///
/// Every display draws the same items in the same order. An app lists the frame of an item on one of them, and that is the one
/// display where a slot is matched to the item by where it is. On the others a slot has an item only if it carries a name of its
/// own, and most carry none. What is left is order.
///
/// - **The reference bar** is the one where the most items were matched by the apps' frames.
/// - **Another bar is walked from the right** (the slots macOS draws in order, left to right). The slots whose items are known on
///   both bars (the system's, the ones tied by name, the ones matched by the apps' frames) are the anchors. Between two anchors the
///   slots of the two bars are paired one to one, in order, but only when both have as many and each pair is as wide to within a
///   point. A stretch where they don't is left alone, and counted: one extra item on one display costs that stretch and not the
///   whole bar.
/// - **The overflow is a set, not an order.** The slots that macOS has piled up at the « (or has no frame for, or has put behind the
///   notch) are in no order. What is left of the reference to the left of the first slot that was paired is what is in that bar's
///   overflow, and it is taken as that only when the counts agree. Those piled slots are then accounted for, as a set, and are not
///   among the slots that nothing claimed (`Alignment.accountedSlots`).
/// - **A stretch that contradicts what is known is refused:** two slots known to be different items paired, an item paired onto a
///   bar that already has a slot of its own for it, or, left of the first anchor, an item that is in a pile on one bar and in the
///   part that is lined up on the other.
extension InventoryMatcher {
    /// How much alike the widths of two slots of the same item are, in points.
    private static let widthTolerance: CGFloat = 1

    struct Alignment {
        /// The items that are in the overflow of a bar and have no slot there to say so: `entry` is a position among the entries.
        var overflowMarks: [(entry: Int, bar: Int)] = []
        var segmentsNotAligned = 0
        /// The slots in the overflow of a bar, that a lined-up stretch left of the first anchor accounts for: the items left of the
        /// part that was lined up are the pile's, as many as it has slots, though which slot is which isn't to be known.
        var accountedSlots: Set<SlotRef> = []
    }

    /// What a slot is known to be: an item of an app (by its place among the entries), or a system item.
    private enum SlotIdentity: Hashable {
        case entry(Int)
        case system(String)
    }

    private struct Tie {
        let slot: SlotRef
        let entry: Int
    }

    /// What is known of the slots of the bars when one bar is lined up: which item a slot is.
    private struct Known {
        let bars: [PreparedBar]
        let claimed: [SlotRef: Int]

        func identity(_ slot: SlotRef) -> SlotIdentity? {
            if let module = ItemID.systemModule(ofIdentifier: bars[slot.bar].slots[slot.position].identifier ?? "") { return .system(module) }
            return claimed[slot].map(SlotIdentity.entry)
        }

        func width(_ slot: SlotRef) -> CGFloat {
            bars[slot.bar].slots[slot.position].frame?.width ?? 0
        }

        /// The entry of an item of an app, for the slots that have one.
        func entries(_ slots: [SlotRef]) -> [Int] {
            slots.compactMap { slot in if case .entry(let entry)? = identity(slot) { entry } else { nil } }
        }

        /// What the slots are known to be (a slot that is nothing yet has no part in it).
        func identities(_ slots: [SlotRef]) -> Set<SlotIdentity> {
            Set(slots.compactMap(identity))
        }
    }

    static func align(_ bars: [PreparedBar], claimsOnBar: [Int], claimed: inout [SlotRef: Int]) -> Alignment {
        var alignment = Alignment()
        guard bars.count > 1, let most = claimsOnBar.max(), most > 0 else { return alignment }
        // The bar with the most matches; of those the one that isn't short of room, then the first.
        let reference = bars.indices.filter { claimsOnBar[$0] == most }
            .min { (bars[$0].overflowed.count, $0) < (bars[$1].overflowed.count, $1) } ?? 0
        for index in bars.indices where index != reference {
            alignBar(index, to: reference, bars: bars, claimed: &claimed, alignment: &alignment)
        }
        return alignment
    }

    private static func alignBar(_ other: Int, to reference: Int, bars: [PreparedBar], claimed: inout [SlotRef: Int],
                                 alignment: inout Alignment) {
        let known = Known(bars: bars, claimed: claimed)
        func refs(_ bar: Int, _ positions: [Int]) -> [SlotRef] { positions.map { SlotRef(bar: bar, position: $0) } }
        let theirs = refs(reference, bars[reference].visible)
        let mine = refs(other, bars[other].visible)

        // The slots whose item is known on both bars, and is on each of them once.
        func firsts(_ slots: [SlotRef]) -> [SlotIdentity: Int] {
            var found: [SlotIdentity: Int] = [:]
            var repeated: Set<SlotIdentity> = []
            for (index, slot) in slots.enumerated() {
                guard let item = known.identity(slot) else { continue }
                if found[item] != nil { repeated.insert(item) } else { found[item] = index }
            }
            for item in repeated { found[item] = nil }
            return found
        }
        let theirIndex = firsts(theirs)
        let myIndex = firsts(mine)
        let shared = theirIndex.compactMap { item, index in myIndex[item].map { (their: index, mine: $0) } }.sorted { $0.their < $1.their }
        let anchors = increasing(shared)

        // Between the anchors, and before the first of them, where the overflow is.
        let bounds = [(their: -1, mine: -1)] + anchors + [(their: theirs.count, mine: mine.count)]
        for (position, (before, after)) in zip(bounds, bounds.dropFirst()).enumerated() {
            let theirSegment = Array(theirs[(before.their + 1)..<after.their])
            let mySegment = Array(mine[(before.mine + 1)..<after.mine])
            if position == 0 {
                alignLeft(theirSegment, mySegment, reference: reference, other: other, known: known, claimed: &claimed, alignment: &alignment)
            } else if theirSegment.isEmpty, mySegment.isEmpty {
                continue
            } else if let ties = pairs(theirSegment, mySegment, known: known), apply(ties, to: &claimed) {
                continue
            } else {
                alignment.segmentsNotAligned += 1
            }
        }
    }

    /// The stretch left of the first anchor, where the overflow is: the bar that has overflow shows as many fewer slots in order as
    /// it has in the overflow.
    private static func alignLeft(_ theirs: [SlotRef], _ mine: [SlotRef], reference: Int, other: Int, known: Known,
                                  claimed: inout [SlotRef: Int], alignment: inout Alignment) {
        let bars = known.bars
        let theirOverflow = bars[reference].overflowed.sorted().map { SlotRef(bar: reference, position: $0) }
        let myOverflow = bars[other].overflowed.sorted().map { SlotRef(bar: other, position: $0) }
        if theirs.isEmpty, mine.isEmpty, theirOverflow.isEmpty, myOverflow.isEmpty { return }
        // The same items are left of the first anchor on both bars, in order or in the overflow.
        guard theirs.count + theirOverflow.count == mine.count + myOverflow.count else {
            alignment.segmentsNotAligned += 1
            return
        }
        // What can be put in order is the right-most of each, as many as the shorter shows.
        let paired = min(theirs.count, mine.count)
        let theirPaired = Array(theirs.suffix(paired))
        let myPaired = Array(mine.suffix(paired))
        // An item known to be in a pile can't be among the ones that were lined up: if it is, the bars don't show the same items in
        // the same order, and nothing here can be trusted.
        let inPiles = known.identities(theirOverflow + myOverflow)
        guard inPiles.isDisjoint(with: known.identities(theirPaired + myPaired)),
              let ties = pairs(theirPaired, myPaired, known: known), apply(ties, to: &claimed) else {
            alignment.segmentsNotAligned += 1
            return
        }
        alignment.accountedSlots.formUnion(theirOverflow + myOverflow)

        // What is left over of the bar that shows more is what the other has in its overflow, and where both have as many, the
        // overflow of each is the other's.
        if theirs.count > mine.count {
            for entry in known.entries(Array(theirs.dropLast(paired)) + theirOverflow) { alignment.overflowMarks.append((entry, other)) }
        } else if mine.count > theirs.count {
            for entry in known.entries(Array(mine.dropLast(paired)) + myOverflow) { alignment.overflowMarks.append((entry, reference)) }
        } else {
            for entry in known.entries(theirOverflow) { alignment.overflowMarks.append((entry, other)) }
            for entry in known.entries(myOverflow) { alignment.overflowMarks.append((entry, reference)) }
        }
    }

    /// The ties that pairing these slots one to one would make, or nil when they can't be paired: not as many on one side as the
    /// other, a pair whose widths aren't the same, or a pair of two slots that are known to be different items.
    private static func pairs(_ theirs: [SlotRef], _ mine: [SlotRef], known: Known) -> [Tie]? {
        guard theirs.count == mine.count else { return nil }
        var ties: [Tie] = []
        for (theirSlot, mySlot) in zip(theirs, mine) {
            guard abs(known.width(theirSlot) - known.width(mySlot)) <= widthTolerance else { return nil }
            switch (known.identity(theirSlot), known.identity(mySlot)) {
            case (.entry(let item)?, nil): ties.append(Tie(slot: mySlot, entry: item))
            case (nil, .entry(let item)?): ties.append(Tie(slot: theirSlot, entry: item))
            case (let one?, let two?) where one != two: return nil
            default: break
            }
        }
        return ties
    }

    /// Ties the slots. If one of the ties can't be made, because the item already has a slot on that bar (or the slot already has an
    /// item), none is: false says so, and the stretch they came from is refused.
    private static func apply(_ ties: [Tie], to claimed: inout [SlotRef: Int]) -> Bool {
        struct Placement: Hashable {
            let bar: Int
            let entry: Int
        }
        var placed = Set(claimed.map { Placement(bar: $0.key.bar, entry: $0.value) })
        for tie in ties {
            guard claimed[tie.slot] == nil, placed.insert(Placement(bar: tie.slot.bar, entry: tie.entry)).inserted else { return false }
        }
        for tie in ties { claimed[tie.slot] = tie.entry }
        return true
    }

    /// The longest run of anchors that are in the same order on both bars (the rest are left out).
    private static func increasing(_ anchors: [(their: Int, mine: Int)]) -> [(their: Int, mine: Int)] {
        guard !anchors.isEmpty else { return [] }
        var best = Array(repeating: 1, count: anchors.count)
        var previous = Array(repeating: -1, count: anchors.count)
        for index in anchors.indices {
            for earlier in 0..<index where anchors[earlier].mine < anchors[index].mine && best[earlier] + 1 > best[index] {
                best[index] = best[earlier] + 1
                previous[index] = earlier
            }
        }
        var end = best.indices.max { best[$0] < best[$1] } ?? 0
        var run: [(their: Int, mine: Int)] = []
        while end >= 0 {
            run.append(anchors[end])
            end = previous[end]
        }
        return run.reversed()
    }
}
