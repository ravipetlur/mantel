import CoreGraphics
import MKCore

/// Where a point on the screen is, as far as revealing by the pointer is concerned: whether it is in the empty part of a menu bar.
///
/// Hover, click and scroll reveals act on empty space only, so a click on an icon, on the front app's menus or on the notch is never a
/// request to reveal. And they act on a bar that is on screen: a full-screen app hides its bar, and the pointer pushed against the top
/// of the screen is then at a place that is *not* in a bar, however much it looks like one.
public enum EmptySpace {
    public enum Spot: Sendable, Equatable {
        /// Not on any display's menu bar.
        case outsideBars
        /// On a bar that isn't on screen (a full-screen app has hidden it), so it counts for nothing: it is never empty space, and
        /// the pointer resting there is never "in the bar".
        case hiddenBar
        /// On an icon (or a slot that holds one Mantel can't name).
        case item
        /// On one of Mantel's own items: a dot, the divider, a spacer or a group's icon. It is an icon like any other for revealing, and
        /// the group hover tells which.
        case ownItem(ItemID)
        /// On the menus of the front app.
        case appMenus
        /// On the camera housing.
        case notch
        /// On a bar that is shown, outside everything else. The display is the one the bar is on.
        case empty(displayUUID: String)
    }

    /// Where one of Mantel's own items is on a bar.
    public struct OwnSlot: Sendable, Equatable {
        public let item: ItemID
        public let frame: CGRect

        public init(item: ItemID, frame: CGRect) {
            self.item = item
            self.frame = frame
        }
    }

    /// The slots Mantel's own items hold in a read of the menu bar: every display's frame of each, except where it is out of the way (in the
    /// « menu) and where another item's frame is the same (which of the two is there can't be told).
    public static func ownSlots(in inventory: Inventory) -> [OwnSlot] {
        var slots: [OwnSlot] = []
        for item in inventory.items where item.ownKind != nil {
            for (display, frame) in item.frames.sorted(by: { $0.key < $1.key })
            where frame.width > 0 && !item.overflowedOn.contains(display) && !item.sharesFrameOn.contains(display) {
                // The layout's name for it (`OwnItems.layoutID`); an item told only by its description keeps the read's, which no
                // group or spacer is found by: it is on the bar, and that is all.
                slots.append(OwnSlot(item: OwnItems.layoutID(of: item) ?? item.id, frame: frame))
            }
        }
        return slots
    }

    /// Classifies a point of the screen, in CoreGraphics global points.
    ///
    /// - `bars`: the menu bars, one per display (`Inventory.bars`).
    /// - `shownBars`: the displays whose bar is on screen now (`BarVisibility.shownBars`). A bar that isn't in it is `.hiddenBar`.
    /// - `itemFrames`: what is drawn on the bars and takes room: the frames of the items that aren't in the « overflow, and the slots no
    ///   item was matched to (`OverflowInputs.occupiedFrames(in:display:)`, for each display).
    /// - `appMenuFrames`: the front app's menus (`MenuBarScanner.appMenuFrames`).
    /// - `ownItems`: where Mantel's own items are (`ownSlots(in:)`). A point on one is `.ownItem`, before it is anything else.
    ///
    /// A bar owns its left and top edges and not its right and bottom ones (`CGRect.contains`), so the point a pointer pushed against
    /// the top of the screen is at is on the bar.
    public static func classify(_ point: CGPoint, bars: [MenuBarGeometry], shownBars: Set<String>, itemFrames: [CGRect],
                                appMenuFrames: [CGRect], ownItems: [OwnSlot] = []) -> Spot {
        guard let bar = bars.first(where: { $0.rect.contains(point) }) else { return .outsideBars }
        guard shownBars.contains(bar.displayUUID) else { return .hiddenBar }
        if let notch = bar.notch, notch.contains(point) { return .notch }
        if let own = ownItems.first(where: { $0.frame.contains(point) }) { return .ownItem(own.item) }
        if itemFrames.contains(where: { $0.contains(point) }) { return .item }
        if appMenuFrames.contains(where: { $0.contains(point) }) { return .appMenus }
        return .empty(displayUUID: bar.displayUUID)
    }

    /// Whether the spot is in a menu bar that is on screen: what keeps a reveal from being hidden again while the pointer is there.
    /// A hidden bar isn't one, and nor is anything outside the bars.
    public static func isInBar(_ spot: Spot) -> Bool {
        switch spot {
        case .item, .ownItem, .appMenus, .notch, .empty: true
        case .outsideBars, .hiddenBar: false
        }
    }
}
