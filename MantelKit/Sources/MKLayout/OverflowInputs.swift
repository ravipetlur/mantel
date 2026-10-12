import CoreGraphics
import MKCore

/// What automatic overflow and the room estimate read from an inventory, worked out in one place so that they are the same wherever
/// they are asked for.
public enum OverflowInputs {
    /// The apps with an icon in the « overflow or behind the notch, on any display: the input of
    /// `AutoOverflowTracker.inventoryArrived`. Mantel's own icons and the system's aren't apps the person sorts, so they aren't
    /// counted; and an icon that is concealed (framed on no display) isn't in the overflow.
    public static func overflowedApps(in inventory: Inventory) -> Set<String> {
        Set(inventory.items.filter { !$0.isMantel && !$0.id.isSystem && $0.isOverflowed }.map(\.ownerBundleID))
    }

    /// The apps in `overflowedApps(in:)` that are there only by where they say they are (`MenuBarItem.inferredOverflowOn`): no slot or « of
    /// a bar says so of any of their icons. What a place says can be out of date, so such an app is moved only on two reads in a row.
    public static func inferredOnlyApps(in inventory: Inventory) -> Set<String> {
        let overflowed = overflowedApps(in: inventory)
        let told = Set(inventory.items.filter { item in
            !item.isMantel && !item.id.isSystem && item.isOverflowed && !item.overflowedOn.isSubset(of: item.inferredOverflowOn)
        }.map(\.ownerBundleID))
        return overflowed.subtracting(told)
    }

    /// The places the items of these apps say they have on a bar where no slot is, by item and display (`MenuBarItem.strayFrames`): what
    /// an app said before it was put on trial, to be told from what it says after.
    public static func strayPlaces(ofApps apps: Set<String>, in inventory: Inventory) -> [ItemID: [String: CGRect]] {
        var places: [ItemID: [String: CGRect]] = [:]
        for item in inventory.items where apps.contains(item.ownerBundleID) && !item.strayFrames.isEmpty { places[item.id] = item.strayFrames }
        return places
    }

    /// Whether two places are the same: to within a point, which is what an app's own frame varies by from one read to the next.
    public static func isSamePlace(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.minX - b.minX) <= 1 && abs(a.minY - b.minY) <= 1 && abs(a.width - b.width) <= 1
    }

    /// Whether two sets of places, by display, are the same on every display (`isSamePlace`).
    public static func isSamePlaces(_ a: [String: CGRect], _ b: [String: CGRect]) -> Bool {
        a.count == b.count && a.allSatisfy { display, place in b[display].map { isSamePlace(place, $0) } ?? false }
    }

    /// `overflowedApps(in:)` without the apps that are in the overflow only by where they say they are, when they say the same as they
    /// did in `known`: an app's own frames often don't change when it is hidden or shown, so a place that is just what it was, from
    /// before the app was put on trial, is no sign of how the trial went.
    public static func overflowedApps(in inventory: Inventory, ignoringUnchangedPlaces known: [ItemID: [String: CGRect]]) -> Set<String> {
        Set(inventory.items.filter { item in
            guard !item.isMantel, !item.id.isSystem, item.isOverflowed else { return false }
            // Told by a slot or a « on some display: that is not a place.
            guard item.overflowedOn.isSubset(of: item.inferredOverflowOn), let before = known[item.id] else { return true }
            return !item.overflowedOn.allSatisfy { display in
                guard let now = item.strayFrames[display], let then = before[display] else { return false }
                return isSamePlace(now, then)
            }
        }.map(\.ownerBundleID))
    }

    /// The frames that take room on one display's bar, in CoreGraphics global points: the input of
    /// `RoomEstimate.freeWidth(bar:appMenusMaxX:visibleItemFrames:)`.
    ///
    /// - Every item that is drawn on that display and isn't in its overflow, whoever draws it: Mantel's own and the system's take
    ///   room as the others do. An item that is in the overflow of another display is still drawn here, so it counts here.
    /// - The slots on that display that no item claimed (`Inventory.untiedSlots`): icons that are really there, though Mantel
    ///   couldn't name them.
    public static func occupiedFrames(in inventory: Inventory, display uuid: String) -> [CGRect] {
        let drawn = inventory.items.compactMap { item -> CGRect? in
            guard !item.overflowedOn.contains(uuid) else { return nil }
            return item.frames[uuid]
        }
        return drawn + (inventory.untiedSlots[uuid] ?? [])
    }

    /// The frames that take room on every display's bar, in CoreGraphics global points (`occupiedFrames(in:display:)` for each bar
    /// the inventory has): what the pointer is told apart from empty space by (`EmptySpace.classify`). The displays' bars don't
    /// overlap, so a frame is only ever looked for on its own display's.
    public static func occupiedFrames(in inventory: Inventory) -> [CGRect] {
        inventory.bars.flatMap { occupiedFrames(in: inventory, display: $0.displayUUID) }
    }
}
