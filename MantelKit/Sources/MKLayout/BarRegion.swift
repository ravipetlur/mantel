import CoreGraphics
import MKCore

/// Which items macOS is not drawing because of where they would be: behind the notch, or under the front app's menus.
///
/// **macOS 27 gives no sign of the « menu.** MenuBarAgent lists a slot for each icon it draws and none for one it doesn't, and the « isn't
/// among them. An item that has been put out of the way says where it would be if it were drawn (`MenuBarItem.strayFrames`: on the bar, in
/// no slot), and that place is in the region that status items are never drawn in:
///
/// - **On a notched display, left of the notch.** The right part of the bar, from the notch's right edge (the left edge of
///   `NSScreen.auxiliaryTopRightArea`, which is where `MenuBarGeometry.notch` ends) to the display's edge, is all there is for status items.
/// - **Under the front app's menus.** The menus are drawn from the left edge of the bar to the right edge of the app's last menu, and an item
///   that overlaps them, or is left of them, isn't drawn. This applies to a bar only where the menus were read for it (they are the front
///   app's, and with "Displays have separate Spaces" each bar shows the menus of its own front app); for a bar with none, only the notch
///   counts.
///
/// An item that is concealed is off every bar, and has no stray frame, so it is never one of these. Nor is a stray frame right of both
/// edges: an item that is drawn but a point or two wider than its slot has one, and it is where it is drawn.
///
/// (The edge that the notch rule uses is the one the display's own geometry gives. The right auxiliary area's left edge is the notch's right
/// edge by definition: the notch is the gap between the two areas.)
public enum BarRegion {
    /// How far an item's left edge may be left of the region's edge and still be in it, in points.
    public static let tolerance: CGFloat = 2

    /// The edge of the region that status items are drawn in, on this bar: the right edge of the notch or of the front app's last menu on
    /// the bar, whichever is further right. Nil when neither is known (not a notched display, and no menus were read for the bar).
    public static func drawnFrom(bar: MenuBarGeometry, menuFrames: [CGRect]) -> CGFloat? {
        let menusRight = menuFrames
            .filter { !$0.isEmpty && bar.rect.contains(CGPoint(x: $0.midX, y: $0.midY)) }
            .map(\.maxX).max()
        return [bar.notch?.maxX, menusRight].compactMap { $0 }.max()
    }

    /// Whether an item that says it is at `frame` on the bar is out of the way: it starts left of the region status items are drawn in.
    public static func isOutOfTheWay(_ frame: CGRect, bar: MenuBarGeometry, menuFrames: [CGRect]) -> Bool {
        guard let edge = drawnFrom(bar: bar, menuFrames: menuFrames) else { return false }
        return frame.minX < edge - tolerance
    }

    /// The inventory with the items that are out of the way marked as overflowed (`MenuBarItem.overflowedByPlace(on:)`), on the displays
    /// where it is so. `draws` says whether the plan has the item on the bar: an item that is hidden by the plan can report a stale place
    /// (an app's own frames often stay where they were when it is hidden), and it isn't overflowed, it is concealed.
    ///
    /// System items are never marked: their places are macOS's own.
    ///
    /// - Parameters:
    ///   - menuFrames: the front app's menus, in CoreGraphics global points.
    ///   - shownBars: the displays whose bar is on screen (`BarVisibility.shownBars`); nil for all. A bar that a full-screen app has hidden
    ///     draws nothing, and what an icon says of its place there says nothing.
    public static func marking(_ inventory: Inventory, menuFrames: [CGRect], shownBars: Set<String>? = nil,
                               draws: (MenuBarItem) -> Bool) -> Inventory {
        guard inventory.items.contains(where: { !$0.strayFrames.isEmpty }) else { return inventory }
        let bars = Dictionary(inventory.bars.map { ($0.displayUUID, $0) }, uniquingKeysWith: { first, _ in first })
        var changed = false
        let items = inventory.items.map { item -> MenuBarItem in
            guard !item.id.isSystem, !item.strayFrames.isEmpty, draws(item) else { return item }
            var found: Set<String> = []
            for (display, frame) in item.strayFrames {
                // An item that has a slot on the bar is drawn there, whatever a frame it reported says.
                guard item.frames[display] == nil, shownBars?.contains(display) ?? true, let bar = bars[display],
                      isOutOfTheWay(frame, bar: bar, menuFrames: menuFrames) else { continue }
                found.insert(display)
            }
            guard !found.subtracting(item.overflowedOn).isEmpty else { return item }
            changed = true
            return item.overflowedByPlace(on: found)
        }
        guard changed else { return inventory }
        return Inventory(capturedAt: inventory.capturedAt, bars: inventory.bars, items: items, chevrons: inventory.chevrons,
                         reach: inventory.reach, problems: inventory.problems, unansweredApps: inventory.unansweredApps,
                         untiedSlots: inventory.untiedSlots)
    }
}
