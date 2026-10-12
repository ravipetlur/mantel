import CoreGraphics
import MKCore

/// How many slots a menu bar should draw for a plan, worked out from the last read of it: what a reveal is looked for on the bar by.
///
/// A reveal is on the bar when every icon the plan draws has a slot there, so the look at the bar is a count: how many of MenuBarAgent's
/// slots have a place on it, against how many the plan asks for. The apps' own frames can't say (they often stay where they were
/// when an icon is shown or hidden), and the slots can't say whose they are, so nothing is told apart: only counted.
///
/// - **What the plan draws.** Every icon of an app that stays on the bar, Mantel's own, and the system's that stay. A system icon
///   Mantel has no number for stays too: the plan only takes away what it can name.
/// - **Less what macOS isn't drawing anyway.** Icons of an app whose switch is off in System Settings, icons in the « overflow of
///   that bar (they are drawn, but not where they can be counted), and any icon that a read found with no place on the bar while the
///   plan then in force asked for it to be drawn (`learn`). Waiting for those would wait for ever.
/// - **Plus the slots nothing claimed** (`Inventory.untiedSlots`): they are drawn too, though Mantel can't say by whom.
/// - **A frame that isn't on the bar is no frame.** The look counts only the slots that are on the bar, so an icon whose frame is
///   somewhere else (parked off the bar by macOS) is counted here as one with none, and an unclaimed slot there isn't counted.
///
/// Wrong either way costs little: a count that is too high only makes the look take its whole wait, and one that is too low only
/// ends it early. Nothing depends on it being right.
public struct BarExpectation: Sendable, Equatable {
    /// The icons macOS was found not to draw although the plan asked for them.
    private var notDrawn: Set<ItemID> = []

    public init() {}

    /// Notes what a read shows, taken while `plan` was the one in force (the plan the engines had applied, and no other).
    ///
    /// An icon with a place on some bar is drawn, whatever it was thought of before. An icon with none that the plan asked for is not
    /// being drawn by macOS: it stays out of the count until a read shows it on a bar. A frame that isn't on its display's bar is no
    /// place on it: macOS parks an icon it isn't drawing off the bar (AirDrop is one under any allowlist), and the look at the bar
    /// doesn't count a slot there either. An icon the read doesn't hold is left as it was: its app may not have answered.
    public mutating func learn(from read: Inventory, plan: VisibilityPlan) {
        for item in read.items {
            if !Self.framesOnABar(of: item, in: read).isEmpty {
                notDrawn.remove(item.id)
            } else if Self.draws(plan, item) {
                notDrawn.insert(item.id)
            }
        }
    }

    /// How many slots the bar of `display` should have a place for under `plan`.
    ///
    /// - Parameters:
    ///   - inventory: the last read, which says what each app has.
    ///   - turnedOff: the apps macOS has turned off in System Settings (none when that isn't known).
    public func slotCount(drawnBy plan: VisibilityPlan, in inventory: Inventory, on display: String, turnedOff: Set<String>) -> Int {
        let items = inventory.items.filter { item in
            guard Self.draws(plan, item), !notDrawn.contains(item.id), !turnedOff.contains(item.ownerBundleID) else { return false }
            // On this bar: framed here, or framed on no bar (a slot with no place on a bar is still a slot of every bar). An icon that
            // is piled in this bar's overflow is not counted, and one that is only on another display isn't on this one.
            guard !item.overflowedOn.contains(display) else { return false }
            let framed = Self.framesOnABar(of: item, in: inventory)
            return framed.isEmpty || framed[display] != nil
        }
        let untied = (inventory.untiedSlots[display] ?? []).count { Self.isOnBar($0, of: display, in: inventory) }
        return items.count + untied
    }

    /// The item's frames that are on the bar of their display. A frame on a display whose bar the read doesn't give is taken to be on it.
    private static func framesOnABar(of item: MenuBarItem, in inventory: Inventory) -> [String: CGRect] {
        item.frames.filter { isOnBar($0.value, of: $0.key, in: inventory) }
    }

    private static func isOnBar(_ frame: CGRect, of display: String, in inventory: Inventory) -> Bool {
        guard let bar = inventory.bars.first(where: { $0.displayUUID == display }) else { return true }
        return frame.intersects(bar.rect)
    }

    /// Whether the plan leaves the item on the bar.
    private static func draws(_ plan: VisibilityPlan, _ item: MenuBarItem) -> Bool {
        if case .system(let module) = item.id.key {
            guard let number = SystemItemTable.number(of: module) else { return true }
            return plan.visibleSystemItems.contains(number)
        }
        return plan.visibleBundleIDs.contains(item.ownerBundleID)
    }
}
