import CoreGraphics
import Foundation
import MKCore
import MKLayout

/// Whether a bar is still the one a read was of: the test a picture has to pass before it is kept.
enum BarSlotCheck {
    /// Frames this close (in points, in every edge) are the same: the matcher's and the window chooser's.
    static let tolerance: CGFloat = 0.5

    /// The whole ordered list of slots the read had is the list the bar has now: the same count, each frame the same to within
    /// `tolerance`, and each name the same where both have one (a window of MenuBarAgent's can lack the names another has, and a slot that
    /// has a name in one and none in the other says nothing against it), except a system module's: every window names those, so a
    /// module's name on one side only is a module that traded places with a nameless icon of its width. A slot inserted anywhere, taken
    /// away or moved, or one that changed width, fails it: every slot to the left of it has slid, and a crop of a slot from before would
    /// hold part of another icon. Comparing only the slots that are cropped isn't enough: an item inserted to the right of one, as wide as
    /// it, sits exactly in the old slot's frame.
    ///
    /// Two icons of one width that trade places (a ⌘-drag, an app that removes its item and adds it again) leave every frame where it was,
    /// and this doesn't see them unless the slots carry names (most third-party slots have none on macOS 27). The apps' own frames show
    /// them (`ItemFrameCheck`).
    static func isSame(read: [BarSlot], now: SlotSnapshot) -> Bool {
        guard read.count == now.slots.count else { return false }
        for (index, slot) in read.enumerated() {
            let frame = now.slots[index]
            guard abs(slot.frame.minX - frame.minX) <= tolerance, abs(slot.frame.minY - frame.minY) <= tolerance,
                  abs(slot.frame.width - frame.width) <= tolerance, abs(slot.frame.height - frame.height) <= tolerance else { return false }
            let nowName = now.names.indices.contains(index) ? now.names[index] : nil
            if let name = slot.name, let nowName, name != nowName { return false }
            if isModule(slot.name) != isModule(nowName) { return false }
        }
        return true
    }

    private static func isModule(_ name: String?) -> Bool {
        name.flatMap(ItemID.systemModule(ofIdentifier:)) != nil
    }

    // MARK: What moved

    /// What the bar's slots now have in common with the read's, and how they differ.
    struct Difference: Equatable {
        /// Whether the run of slots from the right that are the same can be taken for slots that didn't move (`difference`).
        let isTrusted: Bool
        /// The places (in the read's list) of the slots that are still on the bar as they were: none unless `isTrusted`.
        let unmoved: Set<Int>
        /// The slots that are not, in words for the log: where the first difference is, how many slots were left of it and are, how far the
        /// bar's left end moved, and whose slots came or went.
        let summary: String
    }

    /// Which of the read's slots are still as they were, when the bar's slots differ from the read's.
    ///
    /// The bar is right-aligned, so a slot that came, went or changed its width slides the slots left of it and none right of it. Counted
    /// from the right edge, the run of slots that are the same as the read's (to within `tolerance`, with no name that says otherwise: the
    /// rule of `isSame`, and a slot named as one of Mantel's items on one side only ends the run too) is where nothing slid, **if the walk
    /// stopped where the bar really changed.** It doesn't always: a run of slots of one width with no names (most third-party slots on
    /// macOS 27) looks the same after one of them came or went, each icon having slid into its neighbour's frame, and the walk passes all
    /// of it. So the run is trusted only when it can't have been fooled that way. Left of where the walk stopped, the slots that aren't
    /// Mantel's own (told by their names, `OwnItems`: the dots, the divider, a spacer, a group) must be
    /// - **as many on each side** (no slot of anyone else's came or went; Mantel's own may, and the Hidden icons' slide their arrival
    ///   makes is the commonest change at launch), **and of the same widths in order, except the one nearest the stop,** which may have
    ///   changed its width (that is the change the walk stopped at: a width change among the same slots slides what is left of it).
    ///
    /// A Mantel name is the one thing that can't lookalike: the walk never pairs one of Mantel's slots with a nameless slot of an app's
    /// (a name on one side only is how `isSame` treats a window that lacks names, and there it is no difference; here it ends the run), so
    /// a dot that came or went is never traded for a nameless icon of its width. A dot that only slid to where the walk stops (its name is
    /// on the other side too, or the look says no names) is no such stop: what the walk passed slid with it, and the run isn't trusted.
    ///
    /// Any other slot that came or went, anywhere on the bar, is all or nothing, as it was before: nothing is known to be where it was.
    /// What no rule on unnamed slots can tell apart, and what is therefore left to the apps' own frames (`ItemFrameCheck`, the second
    /// check in every case, the trusted run included):
    /// - a swap of two icons of one width with no names leaves every frame where it was and is no difference at all, as it never was to the
    ///   whole-list test (`isSame`);
    /// - an icon that arrives just left of a run of one width, while an icon of the run's width leaves right of it, reads as a width change of
    ///   the run's leftmost slot: the slot lists are the same, each icon of the run having slid into its neighbour's frame;
    /// - its mirror: an icon of the run's width comes inside the run while the app's icon just left of the run, of another width, goes; it
    ///   reads as that icon's width change;
    /// - on a bar piled at the «, an icon that comes or goes right of it moves every icon between it and the « by one slot, and the « makes
    ///   up the count: with icons of one width the slot list is unchanged (as it always was to `isSame`).
    static func difference(read: [BarSlot], now: SlotSnapshot) -> Difference {
        var unmoved: Set<Int> = []
        var one = read.count - 1, other = now.slots.count - 1
        while one >= 0, other >= 0, isStill(read[one], at: other, in: now) {
            unmoved.insert(one)
            one -= 1
            other -= 1
        }
        // What is left on each side of where the walk stopped (the slots left of it, in the read and now): whether the slots that aren't
        // Mantel's own are the same ones (by count and width), and which of Mantel's came or went.
        let before = one + 1, after = other + 1
        let readLeft = read[..<before].map(\.name)
        let nowLeft = (0..<after).map { now.names.indices.contains($0) ? now.names[$0] : nil }
        let isTrusted = sameOthers(read[..<before].filter { !isMantels($0.name) }.map(\.frame.width),
                                   (0..<after).filter { !isMantels(nowLeft[$0]) }.map { now.slots[$0].width })
            && !slidAtTheStop(read: read, one: one, now: now, other: other)

        var summary = "slots \(read.count) -> \(now.slots.count): "
        if before == 0 {
            let first = now.slots[0]
            summary += "\(after) came at the left end (the first at x \(Int(first.minX.rounded())), \(Int(first.width.rounded())) pt wide)"
        } else {
            summary += "\(before) left of x \(Int(read[one].frame.maxX.rounded())) differ ("
            if after == 0 {
                summary += "none there now"
            } else {
                summary += "\(after) there now"
                let by = Int((now.slots[0].minX - read[0].frame.minX).rounded())
                if by != 0 { summary += "; the left end moved \(abs(by)) pt \(by < 0 ? "left" : "right")" }
            }
            summary += ")"
        }
        summary += whoseSlotsCameOrWent(readLeft: readLeft, nowLeft: nowLeft, isTrusted: isTrusted)
        return Difference(isTrusted: isTrusted, unmoved: isTrusted ? unmoved : [], summary: summary)
    }

    /// Whether the walk stopped at one of Mantel's slots facing an app's because that slot slid there, not because it came or went: its name
    /// is on the other side too (in the read's names, or among the look's `identifiers`, which keep names that repeat), or the look says no
    /// names at all. Then what the walk passed slid with it, and the count left of the stop is out of step by that slot.
    private static func slidAtTheStop(read: [BarSlot], one: Int, now: SlotSnapshot, other: Int) -> Bool {
        guard one >= 0, other >= 0 else { return false }
        let readName = read[one].name
        let nowName = now.names.indices.contains(other) ? now.names[other] : nil
        guard isMantels(readName) != isMantels(nowName) else { return false }
        if let nowName, isMantels(nowName) { return read.contains { $0.name == nowName } }
        if let readName { return now.names.isEmpty || now.identifiers.contains(readName) }
        return false
    }

    /// Whether the widths of the slots that aren't Mantel's own, left of where the walk stopped, say that none came or went: as many, and
    /// the same widths in order but for the one nearest the stop (the last of each), which may have changed.
    private static func sameOthers(_ read: [CGFloat], _ now: [CGFloat]) -> Bool {
        guard read.count == now.count else { return false }
        return zip(read, now).dropLast().allSatisfy { abs($0 - $1) <= tolerance }
    }

    /// For the log: Mantel's own slots that came or went (by name), or that slots that aren't Mantel's did, and so nothing is kept.
    private static func whoseSlotsCameOrWent(readLeft: [String?], nowLeft: [String?], isTrusted: Bool) -> String {
        var remaining = readLeft.compactMap { $0 }.filter { isMantels($0) }
        var came: [String] = []
        for name in nowLeft.compactMap({ $0 }).filter({ isMantels($0) }) {
            if let index = remaining.firstIndex(of: name) { remaining.remove(at: index) } else { came.append(name) }
        }
        var words: [String] = []
        if !came.isEmpty { words.append("Mantel's own came: \(came.joined(separator: ", "))") }
        if !remaining.isEmpty { words.append("Mantel's own went: \(remaining.joined(separator: ", "))") }
        if !isTrusted { words.append("slots that aren't Mantel's came or went: no icon is known to be where it was") }
        return words.isEmpty ? "" : "; " + words.joined(separator: "; ")
    }

    /// Whether a slot's name is one of Mantel's own items' (the dots', the divider's, a spacer's or a group's).
    private static func isMantels(_ name: String?) -> Bool {
        name.map { OwnItems.kind(name: $0, description: nil) != nil } ?? false
    }

    /// The apps (of `apps`) one of whose icons' slots, as the read gave them on the display, is not among the slots that are as they were.
    /// A frame of an app's that is in none of the read's slots (a system module macOS has parked off the bar) says nothing.
    static func appsWithMovedSlots(_ apps: Set<String>, read: Inventory, display: String, slots: [BarSlot], unmoved: Set<Int>) -> Set<String> {
        apps.filter { app in
            read.items(ofApp: app).compactMap { $0.frames[display] }.contains { frame in
                guard let index = slots.firstIndex(where: { same($0.frame, frame) }) else { return false }
                return !unmoved.contains(index)
            }
        }
    }

    private static func isStill(_ slot: BarSlot, at index: Int, in now: SlotSnapshot) -> Bool {
        guard same(slot.frame, now.slots[index]) else { return false }
        let nowName = now.names.indices.contains(index) ? now.names[index] : nil
        if let name = slot.name, let nowName, name != nowName { return false }
        // Mantel's own slot on one side only is never paired with an app's nameless one: it is a slot that came or went.
        if isMantels(slot.name) != isMantels(nowName) { return false }
        return isModule(slot.name) == isModule(nowName)
    }

    private static func same(_ one: CGRect, _ other: CGRect) -> Bool {
        abs(one.minX - other.minX) <= tolerance && abs(one.minY - other.minY) <= tolerance
            && abs(one.width - other.width) <= tolerance && abs(one.height - other.height) <= tolerance
    }
}
